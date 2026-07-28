#!/bin/bash
# NOTE: no "set -e" here on purpose. This script controls long-lived
# background services (Tor x8, IP rotator, panel bootstrap) and a
# foreground service (nginx). A single transient failure in any
# background step must NEVER be allowed to kill the whole container,
# or the panel goes down with it.

echo "🚀 Starting X-UI + Tor(x8, auto-rotating) + nginx reverse proxy..."

# ============================================
# USE RAILWAY'S PORT - CRITICAL FIX
# ============================================
export NGINX_PORT=${PORT:-3000}

# How often (seconds) each location's Tor circuit is forced to rotate
# to a brand new exit IP. Override with the ROTATE_SECONDS env var if
# you want a different interval.
ROTATE_SECONDS="${ROTATE_SECONDS:-60}"

cd /usr/local/x-ui || { echo "❌ /usr/local/x-ui not found, aborting"; exit 1; }

echo "🔧 Applying panel settings via x-ui CLI..."
./x-ui setting -port 2053 -webBasePath /managepanel/ || echo "⚠️  x-ui setting command failed, continuing with existing config"

# ============================================
# GENERATE + START 8 SEPARATE TOR INSTANCES
#
# Each instance is its own process (own DataDirectory, own
# SocksPort, own ExitNodes/StrictNodes) so pinned countries can
# never bleed into each other.
#
# NEW: each instance also gets its own loopback-only ControlPort
# with cookie authentication, so a background rotator can send it
# `SIGNAL NEWNYM` (force a brand-new circuit / exit IP) on a timer,
# without ever exposing that control channel outside the container.
# ============================================
echo "🔧 Generating per-country Tor instances..."
mkdir -p /var/log/tor /etc/tor/instances /var/lib/tor-instances /var/www/tor-status

TOR_TAGS=(us de fr nl ca jp sg gb)
TOR_PORTS=(9050 9051 9052 9053 9054 9055 9056 9057)
CONTROL_PORTS=(9150 9151 9152 9153 9154 9155 9156 9157)

render_instance() {
    # $1=name  $2=socksport  $3=exitnodes-cc  $4=controlport
    local name="$1" port="$2" cc="$3" controlport="$4"
    local datadir="/var/lib/tor-instances/${name}"
    local logdir="/var/log/tor/${name}"
    local conf="/etc/tor/instances/torrc.${name}"
    mkdir -p "$datadir" "$logdir"
    chmod 700 "$datadir"

    {
        echo "DataDirectory ${datadir}"
        echo "PidFile /var/run/tor-${name}.pid"
        echo "SocksPort 0.0.0.0:${port}"
        # Loopback-only control channel for the IP rotator. Never
        # bound to 0.0.0.0 — it never leaves the container.
        echo "ControlPort 127.0.0.1:${controlport}"
        echo "CookieAuthentication 1"
        echo "CookieAuthFile ${datadir}/control_auth_cookie"
        # Strict per-country exit circuit pin — the "circuit finder"
        # fix. ExitNodes restricts which relays are even eligible for
        # the last hop; StrictNodes 1 makes that mandatory instead of
        # a soft preference Tor can quietly abandon.
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

for i in "${!TOR_TAGS[@]}"; do
    render_instance "${TOR_TAGS[$i]}" "${TOR_PORTS[$i]}" "${TOR_TAGS[$i]}" "${CONTROL_PORTS[$i]}"
done

echo "▶️  Launching Tor instances (background, non-blocking, staggered)..."
for name in "${TOR_TAGS[@]}"; do
    tor -f "/etc/tor/instances/torrc.${name}" > "/var/log/tor/${name}-stdout.log" 2>&1 &
    echo "  • ${name} → PID $!"
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
            echo "    directory traffic, or the pinned country currently has"
            echo "    too few usable exits for StrictNodes 1. Other instances"
            echo "    are unaffected since they're separate processes."
        ) &
    done
    wait
) &

# ============================================
# AUTOMATIC IP ROTATION (every ROTATE_SECONDS)
#
# For each Tor instance: authenticate on its loopback ControlPort
# using the cookie Tor itself writes to disk (hex-encoded, sent as
# the plain "AUTHENTICATE <hex>" cookie method — no extra tools
# needed beyond bash's built-in /dev/tcp and coreutils `od`), send
# `SIGNAL NEWNYM` to force a brand-new circuit/exit IP, then verify
# the new exit really works by fetching it through that instance's
# own SocksPort. Results are written to /var/www/tor-status/<name>.json
# so nginx can serve them at /tor-status/<name>.json for a quick
# sanity check.
# ============================================
rotate_and_verify() {
    local name="$1" socksport="$2" controlport="$3"
    local cookie_file="/var/lib/tor-instances/${name}/control_auth_cookie"
    local status_file="/var/www/tor-status/${name}.json"

    if [ ! -f "$cookie_file" ]; then
        echo "⚠️  [rotate:${name}] control cookie not written yet, skipping this cycle."
        return 1
    fi

    local hex
    hex=$(od -An -tx1 "$cookie_file" 2>/dev/null | tr -d ' \n')
    if [ -z "$hex" ]; then
        echo "⚠️  [rotate:${name}] could not read control cookie, skipping this cycle."
        return 1
    fi

    # Talk to the ControlPort over a raw TCP fd (bash's /dev/tcp
    # device — no socat/nc dependency needed).
    local ctrl_reply
    ctrl_reply=$(
        exec 3<>"/dev/tcp/127.0.0.1/${controlport}" 2>/dev/null || exit 1
        printf 'AUTHENTICATE %s\r\n' "$hex" >&3
        read -r -t 5 auth_line <&3
        printf 'SIGNAL NEWNYM\r\n' >&3
        read -r -t 5 signal_line <&3
        printf 'QUIT\r\n' >&3
        exec 3<&- 3>&-
        echo "${auth_line}|${signal_line}"
    )

    if [[ "$ctrl_reply" != *"250 OK"*"250 OK"* ]]; then
        echo "⚠️  [rotate:${name}] control command didn't confirm cleanly (${ctrl_reply:-no reply}) — will retry next cycle."
        return 1
    fi

    # New circuits build lazily on next use — give Tor a moment
    # before checking the exit IP through this instance.
    sleep 3

    local exit_ip http_code
    exit_ip=$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:${socksport}" https://api.ipify.org 2>/dev/null)
    http_code=$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' --socks5-hostname "127.0.0.1:${socksport}" https://check.torproject.org/api/ip 2>/dev/null)

    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [ -n "$exit_ip" ] && [ "$http_code" = "200" ]; then
        printf '{"location":"%s","exit_ip":"%s","reachable":true,"checked_at":"%s"}\n' \
            "$name" "$exit_ip" "$now" > "$status_file"
        echo "✅ [rotate:${name}] new exit IP ${exit_ip} (reachable, http ${http_code})"
    else
        printf '{"location":"%s","exit_ip":"%s","reachable":false,"checked_at":"%s"}\n' \
            "$name" "${exit_ip:-unknown}" "$now" > "$status_file"
        echo "⚠️  [rotate:${name}] rotated but exit check failed (ip='${exit_ip:-none}', http='${http_code:-none}') — traffic may still work, this is just the verification ping."
    fi
}

echo "▶️  Starting IP rotator (every ${ROTATE_SECONDS}s per location, background)..."
(
    # Give Tor instances time to fully bootstrap and write their
    # control cookies before the first rotation attempt.
    sleep 30
    while true; do
        for i in "${!TOR_TAGS[@]}"; do
            rotate_and_verify "${TOR_TAGS[$i]}" "${TOR_PORTS[$i]}" "${CONTROL_PORTS[$i]}" &
            sleep 2
        done
        wait
        sleep "$ROTATE_SECONDS"
    done
) > /var/log/tor/rotate.log 2>&1 &

# ============================================
# REAL-IP (DIRECT, NO TOR) SANITY CHECK
# Confirms outbound network access itself works before nginx comes
# up, so a broken network doesn't get silently masked by "the panel
# loaded fine". This is the "/" location's real server IP path.
# ============================================
(
    sleep 5
    real_ip=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null)
    if [ -n "$real_ip" ]; then
        echo "✅ [real-ip] direct (non-Tor) outbound works — server's real IP: ${real_ip}"
        mkdir -p /var/www/tor-status
        printf '{"location":"direct","exit_ip":"%s","reachable":true,"checked_at":"%s"}\n' \
            "$real_ip" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > /var/www/tor-status/direct.json
    else
        echo "⚠️  [real-ip] could not reach api.ipify.org directly — check container network egress."
    fi
) &

# ============================================
# BUILD NGINX CONFIG AND START THE PANEL STACK
# This is the part Railway's edge actually needs to see respond on
# $PORT — it must not wait on anything above.
# ============================================
echo "🔧 Building nginx.conf for Railway PORT: $NGINX_PORT"
envsubst '${NGINX_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "📄 Generated nginx config (listen directives):"
grep -A1 "listen" /etc/nginx/nginx.conf | head -20

echo "▶️  Starting x-ui in background..."
./x-ui &
X_UI_PID=$!

sleep 3

if ! kill -0 "$X_UI_PID" 2>/dev/null; then
    echo "❌ x-ui process died immediately after starting — check /usr/local/x-ui logs above."
fi

# ============================================
# AUTO-CREATE LOCATION INBOUNDS + CLIENTS + TOR OUTBOUNDS
# Runs in the background so it can never delay nginx from binding
# $PORT. Waits for x-ui itself internally before doing anything.
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
