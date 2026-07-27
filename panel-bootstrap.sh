#!/bin/bash
# ============================================================
# panel-bootstrap.sh
#
# Runs once, after x-ui and nginx are already up. It:
#   1. Auto-detects this deployment's public domain (Railway
#      env vars, with manual override support).
#   2. Authenticates to the panel API — either via an API token
#      (Authorization: Bearer, set as the XUI_API_TOKEN env var
#      on Railway — never paste tokens in chat or commit them to
#      the repo) or, if no token is set, via username/password
#      cookie login (+ CSRF token if the panel returns one).
#   3. Creates 9 VLESS/WebSocket inbounds (in1..in9), one per
#      Tor exit country, matching the nginx path/port table.
#   4. Adds a SOCKS5 outbound for each Tor instance and a
#      routing rule that pins each inbound's traffic to its
#      matching country's Tor outbound — this is the actual
#      "location" wiring; nginx/torrc alone can't do it.
#
# IMPORTANT / HONESTY NOTE ON STEP 4:
# The 3x-ui OpenAPI list you gave me documents endpoints and
# one-line descriptions, not full JSON schemas. There is no
# dedicated "add outbound" endpoint — outbounds + routing live
# inside the single Xray config blob saved via
# POST /panel/api/xray/update. I build that blob by reading
# back /panel/api/server/getConfigJson (documented as "the
# assembled Xray config currently running"), splicing in the
# Tor outbounds + routing rules with jq, and posting the whole
# thing back. This is the correct approach in every 3x-ui
# version I'm aware of, but panel forks occasionally rename a
# field. If step 4 fails, this script prints the exact curl
# response so you (or I, if you paste it back to me) can see
# which field name needs adjusting — it will NOT silently
# corrupt your config; it always fetches-then-merges instead of
# writing a config from scratch.
# ============================================================

set -u
LOG() { echo "[panel-bootstrap] $*"; }

PANEL_BASE_PATH="${PANEL_BASE_PATH:-/managepanel}"
PANEL_INTERNAL="http://127.0.0.1:2053${PANEL_BASE_PATH}"
PANEL_USER="${XUI_USERNAME:-admin}"
PANEL_PASS="${XUI_PASSWORD:-admin}"
COOKIE_JAR="/tmp/xui-cookies.txt"
CSRF_TOKEN=""
# If XUI_API_TOKEN is set (as a Railway service env var — never hardcode
# it in this file or paste it in chat), we use it as a Bearer token and
# skip username/password login + the cookie jar entirely. Token auth is
# the more robust option since it isn't invalidated by a panel restart
# the way session cookies are.
API_TOKEN="${XUI_API_TOKEN:-}"

# ------------------------------------------------------------
# 1. Auto-detect the public domain
#    Railway injects RAILWAY_PUBLIC_DOMAIN for services with a
#    generated/custom domain, and (on some plan types)
#    RAILWAY_STATIC_URL as a fallback. PUBLIC_DOMAIN lets you
#    override manually if neither is present or you're on a
#    custom domain Railway doesn't know about yet.
# ------------------------------------------------------------
detect_domain() {
    if [ -n "${PUBLIC_DOMAIN:-}" ]; then
        echo "$PUBLIC_DOMAIN"
    elif [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
        echo "$RAILWAY_PUBLIC_DOMAIN"
    elif [ -n "${RAILWAY_STATIC_URL:-}" ]; then
        echo "$RAILWAY_STATIC_URL" | sed -E 's~^https?://~~'
    else
        echo "localhost:${NGINX_PORT:-3000}"
    fi
}

DOMAIN="$(detect_domain)"
LOG "Detected public domain: $DOMAIN"
if [ "$DOMAIN" = "localhost:${NGINX_PORT:-3000}" ]; then
    LOG "⚠️  Could not find RAILWAY_PUBLIC_DOMAIN/RAILWAY_STATIC_URL."
    LOG "    Set a PUBLIC_DOMAIN env var manually if links look wrong."
fi

# ------------------------------------------------------------
# 2. Wait for the panel to actually answer, then log in
# ------------------------------------------------------------
wait_for_panel() {
    for i in $(seq 1 30); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "${PANEL_INTERNAL}/login")
        if [ "$code" != "000" ]; then
            LOG "Panel is responding (http $code)."
            return 0
        fi
        sleep 2
    done
    LOG "❌ Panel never responded on ${PANEL_INTERNAL}. Aborting bootstrap."
    return 1
}

login() {
    if [ -n "$API_TOKEN" ]; then
        LOG "✅ Using XUI_API_TOKEN (Bearer auth) — skipping username/password login."
        return 0
    fi

    resp=$(curl -s -c "$COOKIE_JAR" -X POST "${PANEL_INTERNAL}/login" \
        -d "username=${PANEL_USER}" -d "password=${PANEL_PASS}")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" != "true" ]; then
        LOG "❌ Login failed. Response: $resp"
        return 1
    fi
    LOG "✅ Logged into panel API."

    # CSRF token is optional depending on version — best effort.
    csrf_resp=$(curl -s -b "$COOKIE_JAR" "${PANEL_INTERNAL}/csrf-token")
    CSRF_TOKEN=$(echo "$csrf_resp" | jq -r '.token // .obj // empty' 2>/dev/null)
    if [ -n "$CSRF_TOKEN" ] && [ "$CSRF_TOKEN" != "null" ]; then
        LOG "Got CSRF token."
    else
        CSRF_TOKEN=""
        LOG "No CSRF token returned (fine on older panel versions)."
    fi
}

api_post() {
    local path="$1" data="$2"
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Content-Type: application/json" -H "Authorization: Bearer ${API_TOKEN}" \
            -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    elif [ -n "$CSRF_TOKEN" ]; then
        curl -s -b "$COOKIE_JAR" -H "Content-Type: application/json" \
            -H "X-CSRF-Token: ${CSRF_TOKEN}" -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    else
        curl -s -b "$COOKIE_JAR" -H "Content-Type: application/json" \
            -X POST "${PANEL_INTERNAL}${path}" -d "$data"
    fi
}

api_get() {
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Authorization: Bearer ${API_TOKEN}" "${PANEL_INTERNAL}$1"
    else
        curl -s -b "$COOKIE_JAR" "${PANEL_INTERNAL}$1"
    fi
}

new_uuid() {
    api_get "/panel/api/server/getNewUUID" | jq -r '.obj // empty'
}

# ------------------------------------------------------------
# 3. Location table — matches the nginx path/port map exactly.
#    tag        = inbound tag AND outbound tag prefix (unique)
#    label      = human-readable remark shown in the panel
#    listenport = internal xray listen port (nginx proxies here)
#    path       = WS path (must equal the nginx location block)
#    torport    = Tor SOCKS5 port for that country's instance
# ------------------------------------------------------------
TAGS=(us de fr nl ca jp sg gb rand9)
LABELS=("United States" "Germany" "France" "Netherlands" "Canada" "Japan" "Singapore" "United Kingdom" "Random")
LISTEN_PORTS=(8081 8082 8083 8084 8085 8086 8087 8088 8089)
WS_PATHS=(/in1 /in2 /in3 /in4 /in5 /in6 /in7 /in8 /in9)
TOR_PORTS=(9050 9051 9052 9053 9054 9055 9056 9057 9058)

existing_tags() {
    api_get "/panel/api/inbounds/list" | jq -r '.obj[]?.tag // empty' 2>/dev/null
}

create_inbound() {
    local tag="$1" label="$2" port="$3" path="$4"
    local uuid; uuid=$(new_uuid)
    if [ -z "$uuid" ] || [ "$uuid" = "null" ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
        LOG "⚠️  Panel UUID endpoint didn't answer, generated one locally instead."
    fi

    local settings streamSettings sniffing
    settings=$(jq -n --arg id "$uuid" --arg email "${tag}-client" '{
        clients: [{ id: $id, email: $email, enable: true }],
        decryption: "none"
    }' -c)

    streamSettings=$(jq -n --arg path "$path" '{
        network: "ws",
        security: "none",
        wsSettings: { path: $path, headers: {} }
    }' -c)

    sniffing='{"enabled":true,"destOverride":["http","tls"]}'

    local body
    body=$(jq -n \
        --arg remark "Tor-${label}" \
        --arg tag "$tag" \
        --argjson port "$port" \
        --arg settings "$settings" \
        --arg streamSettings "$streamSettings" \
        --arg sniffing "$sniffing" '{
            up: 0, down: 0, total: 0,
            remark: $remark,
            enable: true,
            expiryTime: 0,
            listen: "0.0.0.0",
            port: $port,
            protocol: "vless",
            settings: $settings,
            streamSettings: $streamSettings,
            sniffing: $sniffing,
            tag: $tag
        }')

    resp=$(api_post "/panel/api/inbounds/add" "$body")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        LOG "✅ Inbound created: ${label} (port ${port}, path ${path})"
    else
        LOG "❌ Inbound for ${label} failed: $resp"
    fi
}

# ------------------------------------------------------------
# 4. Splice Tor SOCKS5 outbounds + per-tag routing rules into
#    the running Xray config, then save it back.
# ------------------------------------------------------------
setup_outbounds_and_routing() {
    local current; current=$(api_get "/panel/api/server/getConfigJson")
    if ! echo "$current" | jq -e . >/dev/null 2>&1; then
        LOG "❌ Could not read current Xray config — skipping outbound/routing setup."
        LOG "    Raw response: $current"
        return 1
    fi

    local new_config="$current"
    for i in "${!TAGS[@]}"; do
        local tag="${TAGS[$i]}" torport="${TOR_PORTS[$i]}"
        local outbound_tag="tor-${tag}"

        # Skip if this outbound tag already exists (idempotent re-runs)
        local already
        already=$(echo "$new_config" | jq --arg t "$outbound_tag" '[.outbounds[]? | select(.tag==$t)] | length')
        if [ "$already" != "0" ]; then
            LOG "Outbound ${outbound_tag} already exists, skipping."
        else
            new_config=$(echo "$new_config" | jq --arg t "$outbound_tag" --argjson p "$torport" '
                .outbounds += [{
                    tag: $t,
                    protocol: "socks",
                    settings: { servers: [{ address: "127.0.0.1", port: $p }] }
                }]')
        fi

        # Routing rule: traffic entering via this inbound tag exits via this outbound tag
        local rule_exists
        rule_exists=$(echo "$new_config" | jq --arg t "$tag" '
            [.routing.rules[]? | select(.inboundTag != null and (.inboundTag | index($t)) != null)] | length')
        if [ "$rule_exists" != "0" ]; then
            LOG "Routing rule for ${tag} already exists, skipping."
        else
            new_config=$(echo "$new_config" | jq --arg t "$tag" --arg ot "$outbound_tag" '
                .routing.rules = ((.routing.rules // []) + [{
                    type: "field",
                    inboundTag: [$t],
                    outboundTag: $ot
                }])')
        fi
    done

    resp=$(api_post "/panel/api/xray/update" "$new_config")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        LOG "✅ Outbounds + routing saved. Restarting Xray to apply..."
        api_post "/panel/api/server/restartXrayService" "{}" >/dev/null
    else
        LOG "❌ Saving outbounds/routing failed. Response: $resp"
        LOG "    Nothing was corrupted — the panel still has its old config."
        LOG "    Open the panel UI → check Settings → Xray Configs to add"
        LOG "    the SOCKS5 outbounds (127.0.0.1:9050-9057) and routing rules"
        LOG "    by hand as a fallback, or paste this response back so the"
        LOG "    script can be adjusted to your exact panel version."
    fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
wait_for_panel || exit 0
login || exit 0

existing=$(existing_tags)
for i in "${!TAGS[@]}"; do
    tag="${TAGS[$i]}"
    if echo "$existing" | grep -qx "$tag"; then
        LOG "Inbound tag '${tag}' already exists, skipping creation."
        continue
    fi
    create_inbound "${TAGS[$i]}" "${LABELS[$i]}" "${LISTEN_PORTS[$i]}" "${WS_PATHS[$i]}"
done

setup_outbounds_and_routing

LOG "Done. Client links use domain: ${DOMAIN}"
LOG "Example (in1 / United States):"
LOG "vless://<uuid>@${DOMAIN}:443?encryption=none&security=tls&sni=${DOMAIN}&fp=chrome&type=ws&host=${DOMAIN}&path=%2Fin1#Tor-US"