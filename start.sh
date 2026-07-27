#!/bin/bash
# NOTE: no "set -e" here on purpose. This script controls long-lived
# background services (Tor x9, panel bootstrap) and a foreground
# service (nginx). A single transient failure in any background
# step must NEVER be allowed to kill the whole container, or the
# panel goes down with it.

echo "🚀 Starting X-UI + Tor(x9) + nginx reverse proxy..."

# ============================================
# USE RAILWAY'S PORT - CRITICAL FIX
# ============================================
export NGINX_PORT=${PORT:-3000}

cd /usr/local/x-ui || { echo "❌ /usr/local/x-ui not found, aborting"; exit 1; }

echo "🔧 Applying panel settings via x-ui CLI..."
./x-ui setting -port 2053 -webBasePath /managepanel/ || echo "⚠️  x-ui setting command failed, continuing with existing config"

# ============================================
# GENERATE + START 9 SEPARATE TOR INSTANCES
#
# THE ACTUAL FIX for "location doesn't get set
# correctly": a single Tor process only has ONE
# global ExitNodes setting — you cannot pin
# different SocksPorts on the same process to
# different countries. Every port was silently
# exiting wherever Tor felt like. The fix is to
# run one fully independent Tor process (own
# DataDirectory, own SocksPort, own ExitNodes,
# own PID) per country. They can never bleed
# into each other because they're not the same
# process.
#
# 8 pinned countries + 1 shared "random" instance
# (which serves both the 9058 and 9059 ports, since
# "random" means no ExitNodes restriction at all —
# they can safely share one process).
# ============================================
echo "🔧 Generating per-country Tor instances..."
mkdir -p /var/log/tor /etc/tor/instances /var/lib/tor-instances

TOR_TAGS=(us de fr nl ca jp sg gb)
TOR_PORTS=(9050 9051 9052 9053 9054 9055 9056 9057)

render_instance() {
    # $1=name  $2=socksport(s), space-separated  $3=exitnodes-cc or "" for random
    local name="$1" ports="$2" cc="$3"
    local datadir="/var/lib/tor-instances/${name}"
    local logdir="/var/log/tor/${name}"
    local conf="/etc/tor/instances/torrc.${name}"
    mkdir -p "$datadir" "$logdir"
    chmod 700 "$datadir"

    {
        echo "DataDirectory ${datadir}"
        echo "PidFile /var/run/tor-${name}.pid"
        for p in $ports; do
            echo "SocksPort 0.0.0.0:${p}"
        done
        if [ -n "$cc" ]; then
            echo "ExitNodes {${cc}}"
            echo "StrictNodes 1"
        fi
        cat <<EOF
NumEntryGuards 4
NumDirectoryGuards 3
CircuitBuildTimeout 60
KeepalivePeriod 600
ExcludeExitNodes {ir},{kp},{cn},{ru},{sy},{cu},{ve}
Log notice file ${logdir}/notices.log
Log warn file ${logdir}/warnings.log
LogTimeGranularity 1
EOF
    } > "$conf"
}

# 8 country-pinned instances
for i in "${!TOR_TAGS[@]}"; do
    render_instance "${TOR_TAGS[$i]}" "${TOR_PORTS[$i]}" "${TOR_TAGS[$i]}"
done
# 1 shared random instance covering both remaining ports
render_instance "random" "9058 9059" ""

echo "▶️  Launching Tor instances (background, non-blocking, staggered)..."
TOR_PIDS=()
for name in "${TOR_TAGS[@]}" random; do
    tor -f "/etc/tor/instances/torrc.${name}" > "/var/log/tor/${name}-stdout.log" 2>&1 &
    TOR_PIDS+=($!)
    echo "  • ${name} → PID $!"
    # Small stagger: launching all 9 at the exact same instant makes them
    # fight each other (and nginx/x-ui, which are also starting) for CPU
    # and outbound bandwidth during directory bootstrap — the ones
    # launched last (ca, random) were the ones that timed out in testing.
    sleep 1
done

# Background watcher: reports bootstrap status per instance but
# never affects the main script's control flow or exit status.
(
    TIMEOUT=180
    for name in "${TOR_TAGS[@]}" random; do
        (
            ELAPSED=0
            LOGFILE="/var/log/tor/${name}/notices.log"
            while [ $ELAPSED -lt $TIMEOUT ]; do
                if grep -q "Bootstrapped 100%" "$LOGFILE" 2>/dev/null; then
                    echo "✅ [tor-watcher:${name}] bootstrapped."
                    exit 0
                fi
                sleep 5
                ELAPSED=$((ELAPSED+5))
            done
            echo "❌ [tor-watcher:${name}] did not bootstrap within ${TIMEOUT}s."
            echo "    Likely cause: Railway throttling/blocking outbound Tor"
            echo "    directory traffic from this datacenter IP range. Panel"
            echo "    and VLESS inbounds are unaffected — only this instance's"
            echo "    exit country is impacted."
        ) &
    done
    wait
) &

# ============================================
# BUILD NGINX CONFIG AND START THE PANEL STACK
# This is the part Railway's edge actually needs
# to see respond on $PORT — it must not wait on
# anything above.
# ============================================
echo "🔧 Building nginx.conf for Railway PORT: $NGINX_PORT"
envsubst '${NGINX_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "📄 Generated nginx config (listen directives):"
grep -A1 "listen" /etc/nginx/nginx.conf | head -20

echo "▶️  Starting x-ui in background..."
./x-ui &
X_UI_PID=$!

# Give x-ui a moment to bind its ports before nginx starts proxying to them
sleep 3

if ! kill -0 "$X_UI_PID" 2>/dev/null; then
    echo "❌ x-ui process died immediately after starting — check /usr/local/x-ui logs above."
fi

# ============================================
# AUTO-CREATE LOCATION INBOUNDS + CLIENTS + TOR
# OUTBOUNDS
# Runs in the background so it can never delay
# nginx from binding $PORT. Waits for x-ui itself
# internally before doing anything.
# ============================================
if [ -x /panel-bootstrap.sh ]; then
    echo "▶️  Launching panel-bootstrap.sh (background, logs shown below)..."
    /panel-bootstrap.sh 2>&1 | tee /var/log/panel-bootstrap.log &
else
    echo "⚠️  /panel-bootstrap.sh not found or not executable — skipping auto inbound/outbound setup."
fi

echo "▶️  Validating nginx config..."
if ! nginx -t; then
    echo "❌ nginx config test FAILED. Dumping generated config for debugging:"
    cat /etc/nginx/nginx.conf
    echo "❌ Cannot start nginx with invalid config. Exiting."
    exit 1
fi

echo "▶️  Starting nginx in foreground on port $NGINX_PORT..."
exec nginx -g "daemon off;"
