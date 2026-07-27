#!/bin/bash
# NOTE: no "set -e" here on purpose. This script controls long-lived
# background services (Tor x8, panel bootstrap) and a foreground
# service (nginx). A single transient failure in any background
# step must NEVER be allowed to kill the whole container, or the
# panel goes down with it.

echo "🚀 Starting X-UI + Tor(x8) + nginx reverse proxy..."

# ============================================
# USE RAILWAY'S PORT - CRITICAL FIX
# ============================================
export NGINX_PORT=${PORT:-3000}

cd /usr/local/x-ui || { echo "❌ /usr/local/x-ui not found, aborting"; exit 1; }

echo "🔧 Applying panel settings via x-ui CLI..."
./x-ui setting -port 2053 -webBasePath /managepanel/ || echo "⚠️  x-ui setting command failed, continuing with existing config"

# ============================================
# GENERATE + START 8 SEPARATE TOR INSTANCES
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
# The "random" (no ExitNodes) instance has been
# removed entirely per request — every exit is now
# a strictly-pinned country circuit. If a pinned
# country's guard/exit set is briefly unavailable,
# Tor will retry within that same country rather
# than silently falling back to a random exit,
# because StrictNodes 1 is set below.
# ============================================
echo "🔧 Generating per-country Tor instances..."
mkdir -p /var/log/tor /etc/tor/instances /var/lib/tor-instances

TOR_TAGS=(us de fr nl ca jp sg gb)
TOR_PORTS=(9050 9051 9052 9053 9054 9055 9056 9057)

render_instance() {
    # $1=name  $2=socksport  $3=exitnodes-cc (required now — no more "" random case)
    local name="$1" port="$2" cc="$3"
    local datadir="/var/lib/tor-instances/${name}"
    local logdir="/var/log/tor/${name}"
    local conf="/etc/tor/instances/torrc.${name}"
    mkdir -p "$datadir" "$logdir"
    chmod 700 "$datadir"

    {
        echo "DataDirectory ${datadir}"
        echo "PidFile /var/run/tor-${name}.pid"
        echo "SocksPort 0.0.0.0:${port}"
        # Strict per-country exit circuit pin. This is the actual
        # "circuit finder" fix: ExitNodes restricts which relays Tor is
        # even allowed to consider for the last hop, and StrictNodes 1
        # makes that restriction mandatory instead of a soft preference
        # (without StrictNodes, Tor is allowed to silently fall back to
        # ANY exit country if it has trouble finding one in {cc}).
        echo "ExitNodes {${cc}}"
        echo "StrictNodes 1"
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

# 8 country-pinned instances only — no shared random instance anymore
for i in "${!TOR_TAGS[@]}"; do
    render_instance "${TOR_TAGS[$i]}" "${TOR_PORTS[$i]}" "${TOR_TAGS[$i]}"
done

echo "▶️  Launching Tor instances (background, non-blocking, staggered)..."
TOR_PIDS=()
for name in "${TOR_TAGS[@]}"; do
    tor -f "/etc/tor/instances/torrc.${name}" > "/var/log/tor/${name}-stdout.log" 2>&1 &
    TOR_PIDS+=($!)
    echo "  • ${name} → PID $!"
    # Small stagger: launching all 8 at the exact same instant makes them
    # fight each other (and nginx/x-ui, which are also starting) for CPU
    # and outbound bandwidth during directory bootstrap.
    sleep 1
done

# Background watcher: reports bootstrap status per instance but
# never affects the main script's control flow or exit status.
(
    TIMEOUT=180
    for name in "${TOR_TAGS[@]}"; do
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
            echo "    directory traffic from this datacenter IP range, OR the"
            echo "    pinned country {${name}} currently has too few usable"
            echo "    exit relays for StrictNodes 1 to complete a circuit."
            echo "    Panel and VLESS inbounds are unaffected — only this"
            echo "    instance's exit country is impacted."
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
