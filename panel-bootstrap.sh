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
#      Tor exit country, matching the nginx path/port table —
#      created EMPTY of clients (settings.clients: []).
#   4. Creates one client per inbound through the dedicated
#      Clients API (POST /panel/api/clients/add) instead of
#      hand-writing the client JSON inline in the inbound's
#      settings. This is the actual bug fix — see below.
#   5. Adds a SOCKS5 outbound for each Tor instance and a
#      routing rule that pins each inbound's traffic to its
#      matching country's Tor outbound.
#   6. Reads back the real client link from the panel itself
#      (GET /panel/api/clients/links/{email}) instead of
#      constructing the vless:// URI by hand in bash, and logs
#      that.
#
# ============================================================
# WHY "COPY CONFIG" / "QR CODE" WERE UNAVAILABLE IN THE PANEL
# ============================================================
# The previous version of this script embedded the client
# directly inside the inbound's settings JSON on creation:
#   settings.clients: [{ id: <uuid>, email: <email>, enable: true }]
# That's only 3 fields. The panel's own client-creation code
# (and its frontend "Copy"/"QR" buttons) expect a full client
# record — subId, flow, limitIp, totalGB, expiryTime, reset,
# tgId, comment, etc. When a client is missing subId in
# particular, the panel's link-builder has nothing to key a
# subscription/copy link off of, and the UI silently disables
# or fails to render those buttons.
#
# The fix used here is to never hand-write the client JSON at
# all. Instead:
#   - The inbound is created with settings.clients: [] (no
#     clients baked in).
#   - The client is created afterwards via the panel's own
#     POST /panel/api/clients/add endpoint, sending only the
#     "universal" fields (email, totalGB, expiryTime, tgId,
#     limitIp, enable). Per-protocol secrets (the VLESS UUID)
#     and internal fields like subId are generated server-side
#     by the panel itself when omitted.
#   - The actual client link is then fetched via
#     GET /panel/api/clients/links/{email} instead of being
#     hand-assembled in bash.
# ============================================================
# WHY OUTBOUNDS + ROUTING RULES WERE NEVER ACTUALLY CREATED
# ============================================================
# The previous version pulled the config from
# GET /panel/api/server/getConfigJson (a READ-ONLY snapshot of
# whatever Xray is currently running — not the panel's editable
# template) and then wrote it back with
# POST /panel/api/xray/update sending the raw JSON blob as an
# `application/json` body.
#
# Per the panel's own API docs, /panel/api/xray/update "Save[s]
# the Xray JSON config template ... Both are sent as form
# fields" — i.e. it expects a normal form POST with a field
# named `xraySetting` (the same key GET /panel/api/xray/
# returns), NOT a raw JSON request body. Posting JSON there
# means the panel never sees a populated `xraySetting` field,
# so the save is a silent no-op — outbounds/routing rules never
# actually land, even though the script logs "success" (because
# the endpoint still returns 200/success, it just didn't get
# any data to save).
#
# Fixed here by:
#   - Reading the editable template from POST /panel/api/xray/
#     (its `obj.xraySetting` field — the config as a JSON
#     *string*), not from getConfigJson.
#   - Writing back with a real x-www-form-urlencoded POST to
#     /panel/api/xray/update, field name `xraySetting`, using
#     curl --data-urlencode so the embedded JSON survives
#     encoding intact. outboundTestUrl is round-tripped too so
#     it isn't accidentally cleared.
#   - Verifying the write actually applied by re-fetching the
#     template afterward and checking the tor outbounds are
#     present, instead of trusting a bare "success" flag.
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

    # CSRF must be fetched BEFORE logging in — 3x-ui 3.5.0 protects
    # /login itself, so a login POST sent without a token can be
    # silently rejected before it ever reaches the auth handler. -c
    # here seeds the cookie jar with whatever pre-session cookie the
    # panel sets, which then gets carried into the login POST via -b.
    csrf_resp=$(curl -s -c "$COOKIE_JAR" "${PANEL_INTERNAL}/csrf-token")
    CSRF_TOKEN=$(echo "$csrf_resp" | jq -r '.obj // .token // empty' 2>/dev/null)
    if [ -n "$CSRF_TOKEN" ] && [ "$CSRF_TOKEN" != "null" ]; then
        LOG "Got CSRF token before login."
    else
        CSRF_TOKEN=""
        LOG "No CSRF token available yet (may not be required on your version)."
    fi

    _attempt_login() {
        local content_type="$1" data="$2"
        if [ -n "$CSRF_TOKEN" ]; then
            curl -s -w "\nHTTP_STATUS:%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
                -H "Content-Type: ${content_type}" -H "X-CSRF-Token: ${CSRF_TOKEN}" \
                -X POST "${PANEL_INTERNAL}/login" -d "$data"
        else
            curl -s -w "\nHTTP_STATUS:%{http_code}" -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
                -H "Content-Type: ${content_type}" \
                -X POST "${PANEL_INTERNAL}/login" -d "$data"
        fi
    }

    # Attempt 1: JSON body (matches the documented /login schema exactly:
    # {"username":..., "password":..., "twoFactorCode":...})
    json_data=$(jq -n --arg u "$PANEL_USER" --arg p "$PANEL_PASS" '{username:$u,password:$p}')
    raw=$(_attempt_login "application/json" "$json_data")
    status=$(echo "$raw" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
    resp=$(echo "$raw" | sed '$ d')
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)

    if [ "$ok" != "true" ]; then
        # Attempt 2: form-encoded, in case this build expects that instead
        LOG "JSON login didn't succeed (http ${status:-?}), retrying with form body..."
        raw=$(_attempt_login "application/x-www-form-urlencoded" "username=${PANEL_USER}&password=${PANEL_PASS}")
        status=$(echo "$raw" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
        resp=$(echo "$raw" | sed '$ d')
        ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    fi

    if [ "$ok" != "true" ]; then
        LOG "❌ Login failed (http ${status:-unknown}). Response body: '${resp}'"
        LOG "    If the body is empty, this is very likely CSRF/anti-bot middleware"
        LOG "    rejecting the request rather than a wrong password — check that"
        LOG "    XUI_USERNAME/XUI_PASSWORD are correct, then paste this log back"
        LOG "    if it still fails so the request shape can be adjusted."
        return 1
    fi
    LOG "✅ Logged into panel API (http ${status})."

    # Re-fetch CSRF post-login too — some panel versions rotate the
    # token once a session exists.
    csrf_resp=$(curl -s -b "$COOKIE_JAR" -c "$COOKIE_JAR" "${PANEL_INTERNAL}/csrf-token")
    fresh_token=$(echo "$csrf_resp" | jq -r '.obj // .token // empty' 2>/dev/null)
    if [ -n "$fresh_token" ] && [ "$fresh_token" != "null" ]; then
        CSRF_TOKEN="$fresh_token"
    fi
}

# JSON-body POST helper — used for every endpoint that genuinely
# expects a JSON request body (inbounds/add, clients/add, etc).
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

# Form-encoded POST helper — required for /panel/api/xray/update,
# which (per the panel's own API docs) takes form fields, not a
# raw JSON body. Extra args are passed straight through to curl,
# so callers use --data-urlencode "field=value" for each field.
api_post_form() {
    local path="$1"; shift
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Authorization: Bearer ${API_TOKEN}" \
            -X POST "${PANEL_INTERNAL}${path}" "$@"
    elif [ -n "$CSRF_TOKEN" ]; then
        curl -s -b "$COOKIE_JAR" -H "X-CSRF-Token: ${CSRF_TOKEN}" \
            -X POST "${PANEL_INTERNAL}${path}" "$@"
    else
        curl -s -b "$COOKIE_JAR" \
            -X POST "${PANEL_INTERNAL}${path}" "$@"
    fi
}

api_get() {
    if [ -n "$API_TOKEN" ]; then
        curl -s -H "Authorization: Bearer ${API_TOKEN}" "${PANEL_INTERNAL}$1"
    else
        curl -s -b "$COOKIE_JAR" "${PANEL_INTERNAL}$1"
    fi
}

# ------------------------------------------------------------
# 3. Location table — matches the nginx path/port map exactly.
# ------------------------------------------------------------
TAGS=(us de fr nl ca jp sg gb rand9)
LABELS=("United States" "Germany" "France" "Netherlands" "Canada" "Japan" "Singapore" "United Kingdom" "Random")
LISTEN_PORTS=(8081 8082 8083 8084 8085 8086 8087 8088 8089)
WS_PATHS=(/in1 /in2 /in3 /in4 /in5 /in6 /in7 /in8 /in9)
TOR_PORTS=(9050 9051 9052 9053 9054 9055 9056 9057 9058)

existing_inbound_tags() {
    api_get "/panel/api/inbounds/list/slim" | jq -r '.obj[]?.tag // empty' 2>/dev/null
}

inbound_id_by_tag() {
    local tag="$1"
    api_get "/panel/api/inbounds/list/slim" | jq -r --arg t "$tag" '.obj[]? | select(.tag==$t) | .id' 2>/dev/null | head -n1
}

client_exists() {
    local email="$1"
    resp=$(api_get "/panel/api/clients/get/${email}")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    [ "$ok" = "true" ]
}

# ------------------------------------------------------------
# 4. Create the inbound — WITHOUT any client baked in.
#    Clients are added afterwards through the Clients API so
#    the panel itself generates every field its own UI needs
#    (uuid, subId, flow, etc.) in the exact shape it expects.
# ------------------------------------------------------------
create_inbound() {
    local tag="$1" label="$2" port="$3" path="$4"

    local settings streamSettings sniffing
    settings=$(jq -n '{
        clients: [],
        decryption: "none",
        fallbacks: []
    }')

    streamSettings=$(jq -n --arg path "$path" '{
        network: "ws",
        security: "none",
        wsSettings: { path: $path, headers: {} }
    }')

    sniffing='{"enabled":true,"destOverride":["http","tls"],"metadataOnly":false,"routeOnly":false}'

    local body
    body=$(jq -n \
        --arg remark "Tor-${label}" \
        --arg tag "$tag" \
        --argjson port "$port" \
        --argjson settings "$settings" \
        --argjson streamSettings "$streamSettings" \
        --argjson sniffing "$sniffing" '{
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
        return 1
    fi
}

# ------------------------------------------------------------
# 5. Create the client through the dedicated Clients API and
#    attach it to the inbound in one call. Only universal
#    fields are sent — uuid/subId/etc. are generated by the
#    panel itself, so the client is guaranteed to be shaped
#    exactly the way the panel's own "Copy"/"QR" buttons expect.
# ------------------------------------------------------------
create_client() {
    local tag="$1" label="$2" inbound_id="$3"
    local email="${tag}-client"

    if client_exists "$email"; then
        LOG "Client '${email}' already exists, skipping creation."
        return 0
    fi

    local client_body body
    client_body=$(jq -n --arg email "$email" '{
        email: $email,
        totalGB: 0,
        expiryTime: 0,
        tgId: 0,
        limitIp: 0,
        enable: true
    }')

    body=$(jq -n --argjson client "$client_body" --argjson id "$inbound_id" '{
        client: $client,
        inboundIds: [$id]
    }')

    resp=$(api_post "/panel/api/clients/add" "$body")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        LOG "✅ Client created: ${email} (attached to inbound #${inbound_id})"
    else
        LOG "❌ Client creation for ${email} failed: $resp"
        return 1
    fi
}

# ------------------------------------------------------------
# 6. Fetch the panel-generated link for a client — the exact
#    string the "Copy" button in the UI would copy — instead
#    of hand-assembling a vless:// URI in bash.
# ------------------------------------------------------------
log_client_link() {
    local email="$1" label="$2"
    resp=$(api_get "/panel/api/clients/links/${email}")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" = "true" ]; then
        link=$(echo "$resp" | jq -r '.obj[0] // empty')
        if [ -n "$link" ]; then
            LOG "🔗 ${label}: ${link}"
        else
            LOG "⚠️  ${label}: panel returned no link yet (Xray may still be reloading) — check the panel UI directly."
        fi
    else
        LOG "⚠️  Could not fetch link for ${email}: $resp"
    fi
}

# ------------------------------------------------------------
# 7. Splice Tor SOCKS5 outbounds + per-tag routing rules into
#    the panel's Xray config TEMPLATE, then save it back the
#    way the panel's own Settings → Xray Configs page does.
#
#    IMPORTANT: this reads/writes POST /panel/api/xray/ and
#    /panel/api/xray/update — NOT /panel/api/server/getConfigJson.
#    getConfigJson is a read-only snapshot of whatever's
#    currently running; it is not a valid target to write back
#    to, and /update itself needs form fields, not a raw JSON
#    body. See the big comment block at the top of this file.
# ------------------------------------------------------------
setup_outbounds_and_routing() {
    local tpl_resp current_json new_config

    tpl_resp=$(api_post "/panel/api/xray/" "{}")
    ok=$(echo "$tpl_resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" != "true" ]; then
        LOG "❌ Could not fetch the Xray config template from /panel/api/xray/ — skipping outbound/routing setup."
        LOG "    Raw response: $tpl_resp"
        return 1
    fi

    # obj.xraySetting is itself a JSON *string* (the raw template),
    # not a nested object — pull it out as text.
    current_json=$(echo "$tpl_resp" | jq -r '.obj.xraySetting // empty')
    local outbound_test_url
    outbound_test_url=$(echo "$tpl_resp" | jq -r '.obj.outboundTestUrl // empty')

    if [ -z "$current_json" ] || ! echo "$current_json" | jq -e . >/dev/null 2>&1; then
        LOG "❌ xraySetting from the panel wasn't valid JSON — aborting outbound/routing setup."
        LOG "    Raw obj.xraySetting: $current_json"
        return 1
    fi

    new_config="$current_json"
    for i in "${!TAGS[@]}"; do
        local tag="${TAGS[$i]}" torport="${TOR_PORTS[$i]}"
        local outbound_tag="tor-${tag}"

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

    if [ "$new_config" = "$current_json" ]; then
        LOG "Outbounds + routing already up to date, nothing to save."
        return 0
    fi

    # Real fix: form-encoded POST with field name "xraySetting",
    # matching what GET/POST /panel/api/xray/ itself returns and
    # what the docs say /update actually consumes. --data-urlencode
    # keeps the embedded JSON (quotes, braces, newlines) intact.
    local update_args=(--data-urlencode "xraySetting=${new_config}")
    if [ -n "$outbound_test_url" ] && [ "$outbound_test_url" != "null" ]; then
        update_args+=(--data-urlencode "outboundTestUrl=${outbound_test_url}")
    fi

    resp=$(api_post_form "/panel/api/xray/update" "${update_args[@]}")
    ok=$(echo "$resp" | jq -r '.success // empty' 2>/dev/null)
    if [ "$ok" != "true" ]; then
        LOG "❌ Saving outbounds/routing failed. Response: $resp"
        LOG "    Nothing was corrupted — the panel still has its old config."
        LOG "    Open the panel UI → check Settings → Xray Configs to add"
        LOG "    the SOCKS5 outbounds (127.0.0.1:9050-9057) and routing rules"
        LOG "    by hand as a fallback, or paste this response back so the"
        LOG "    script can be adjusted to your exact panel version."
        return 1
    fi

    # Verify the write actually took — the endpoint returning
    # success:true doesn't guarantee the template was rewritten;
    # this closes the loop the old script left open.
    sleep 1
    local verify_resp verify_json missing=0
    verify_resp=$(api_post "/panel/api/xray/" "{}")
    verify_json=$(echo "$verify_resp" | jq -r '.obj.xraySetting // empty')
    for i in "${!TAGS[@]}"; do
        local outbound_tag="tor-${TAGS[$i]}"
        local found
        found=$(echo "$verify_json" | jq --arg t "$outbound_tag" '[.outbounds[]? | select(.tag==$t)] | length' 2>/dev/null)
        if [ "${found:-0}" = "0" ]; then
            missing=$((missing+1))
        fi
    done

    if [ "$missing" -gt 0 ]; then
        LOG "❌ Save reported success but ${missing} Tor outbound(s) are still missing after verification."
        LOG "    Check Settings → Xray Configs in the panel UI and compare against this response: $resp"
        return 1
    fi

    LOG "✅ Outbounds + routing saved and verified. Restarting Xray to apply..."
    api_post "/panel/api/server/restartXrayService" "{}" >/dev/null
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
wait_for_panel || exit 0
login || exit 0

existing=$(existing_inbound_tags)
for i in "${!TAGS[@]}"; do
    tag="${TAGS[$i]}"
    if ! echo "$existing" | grep -qx "$tag"; then
        create_inbound "${TAGS[$i]}" "${LABELS[$i]}" "${LISTEN_PORTS[$i]}" "${WS_PATHS[$i]}"
    else
        LOG "Inbound tag '${tag}' already exists, skipping creation."
    fi
done

# Give the panel a moment to commit the new inbounds before we
# look their IDs back up for client attachment.
sleep 1

for i in "${!TAGS[@]}"; do
    tag="${TAGS[$i]}"
    id=$(inbound_id_by_tag "$tag")
    if [ -z "$id" ] || [ "$id" = "null" ]; then
        LOG "❌ Could not find inbound id for tag '${tag}' — skipping client creation for it."
        continue
    fi
    create_client "$tag" "${LABELS[$i]}" "$id"
done

setup_outbounds_and_routing

LOG "Fetching panel-generated client links..."
for i in "${!TAGS[@]}"; do
    tag="${TAGS[$i]}"
    email="${tag}-client"
    log_client_link "$email" "${LABELS[$i]}"
done

LOG "Done. Domain: ${DOMAIN}"
LOG "If a location's Copy/QR still looks empty in the panel UI, open that"
LOG "client's edit modal once and hit Save — this forces the panel to"
LOG "recompute its cached link state — then it should render normally."