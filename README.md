# 3x-ui + Tor on Railway

Deploys 3x-ui with 8 independent Tor exit-country instances behind a single
public nginx port, and auto-provisions the location inbounds + clients +
Tor outbounds + routing rules through the panel API on boot.

## 🌟 Features

- ✅ Panel + VLESS inbounds + Tor, all in one container
- ✅ Single public port (nginx handles routing)
- ✅ **8 real, independent exit countries** — each Tor SocksPort is its own
  Tor process with its own `ExitNodes` + `StrictNodes 1`, so locations
  actually pin correctly and never silently fall back to a random exit
- ✅ **Automatic IP rotation** — every `ROTATE_SECONDS` (default **60s**),
  each location's Tor process is sent `SIGNAL NEWNYM` over its own
  loopback-only ControlPort, forcing a brand-new circuit/exit IP. Every
  rotation is verified live (fetches the new exit IP and pings through it)
  before being trusted, and the result is written to
  `/tor-status/<location>.json`
- ✅ **Real-IP location included** — a plain, non-Tor VLESS inbound (`/`,
  port 8080) is auto-provisioned alongside the 8 Tor locations, so you
  always have a "use the server's actual IP" option too, and its
  reachability is checked the same way (`/tor-status/direct.json`)
- ✅ **Auto-provisioning**: on boot, a script logs into the panel API,
  auto-detects the deployment's public domain, creates all 9 location
  inbounds (8 Tor + 1 real-IP), creates a client on each through the
  panel's own Clients API, and auto-imports a routing rule wiring each
  Tor inbound to its matching Tor outbound — no manual panel clicking
  required
- ✅ Tor runs fully in the background — it can never block or crash the panel
- ✅ nginx tuned correctly for VLESS-over-WebSocket on every path

## 🔁 Automatic IP rotation (new)

Each of the 8 Tor instances gets its own **loopback-only** `ControlPort`
(9150-9157) with cookie authentication. A background loop in `start.sh`:

1. Waits 30s after boot for Tor to finish bootstrapping and write its
   control-auth cookie.
2. Every `ROTATE_SECONDS` (default `60`, override via an env var on the
   Railway service), for each location: authenticates on its ControlPort
   using the cookie Tor itself wrote to disk, sends `SIGNAL NEWNYM` (Tor's
   official "give me a new circuit/identity" command), waits a few
   seconds for the new circuit to build, then **actually verifies it** by
   fetching the new exit IP through that instance's SocksPort and
   checking `https://check.torproject.org/api/ip` returns `200` through
   it.
3. Writes the result to `/var/www/tor-status/<location>.json`, which
   nginx serves read-only at:
   ```
   https://your-domain.up.railway.app/tor-status/us.json
   https://your-domain.up.railway.app/tor-status/de.json
   ...
   https://your-domain.up.railway.app/tor-status/direct.json   ← real server IP
   ```
   Example contents: `{"location":"us","exit_ip":"1.2.3.4","reachable":true,"checked_at":"2026-07-28T12:00:00Z"}`

If a rotation's verification fails (exit didn't respond in time), the
existing circuit is left in place rather than traffic being dropped —
`reachable:false` just tells you that particular cycle's check didn't
confirm, and it retries again next cycle. The ControlPort itself is never
bound to `0.0.0.0` and is not in the Dockerfile's `EXPOSE` list, so it's
never reachable from outside the container.

## 🐛 Bug fixed in this version: the shared "random" exit removed, outbound/routing JSON corrected

**Symptom:** a 9th "random" (no pinned country) Tor instance existed
alongside the 8 real countries, and the outbound JSON the bootstrap script
generated didn't fully match what Xray expects (missing `users: []` on
SOCKS servers, no `sockopt` tuning, routing rules without an explicit
`enabled: true`).

**Fix:**
1. The `random`/`rand9` Tor instance, its `/in9` nginx location, its
   SOCKS outbound, and its routing rule have all been removed. Only the 8
   strictly-pinned countries remain (us/de/fr/nl/ca/jp/sg/gb).
2. Each generated Tor outbound now includes `"users": []` on its server
   entry and a `streamSettings.sockopt` block (`tcpFastOpen`,
   `tcpKeepAlive`).
3. Each generated routing rule explicitly sets `"enabled": true`.
4. The script never touches or duplicates the `direct`/`blocked`
   outbounds that already exist in the panel's base Xray template — it
   only ever adds/looks for `tor-<cc>` entries, so re-running it can't
   produce duplicate-tag configs (which Xray rejects at load time).
5. As a safety net, on every run the script also strips out any leftover
   `tor-rand9` outbound or `rand9`-tagged routing rule from a previous
   deploy of this container, so upgrading in place cleans itself up.

## 🐛 Bug fixed earlier: "Copy config" / "QR code" unavailable in the panel

**Root cause:** `panel-bootstrap.sh` used to hand-write the client
directly inside the inbound's `settings.clients[]` JSON on creation, with
only three fields (`id`, `email`, `enable`). The panel's own client model
— and the frontend code behind the "Copy"/"QR" buttons — expects a full
client record (`subId`, `flow`, `limitIp`, `totalGB`, `expiryTime`,
`reset`, `tgId`, etc). With `subId` in particular missing, the panel's
link-builder has nothing to key a link off, so those buttons silently
fail to render or do nothing.

**Fix:** the script no longer hand-writes client JSON at all.
1. Each inbound is created with `settings.clients: []` — empty.
2. The client is created afterwards through the panel's own
   `POST /panel/api/clients/add` endpoint, sending only the "universal"
   fields (`email`, `totalGB`, `expiryTime`, `tgId`, `limitIp`, `enable`).
   Per-protocol secrets (the VLESS UUID) and internal fields like `subId`
   are generated **server-side** by the panel itself when omitted.
3. Instead of hand-assembling a `vless://` URI in bash, the script calls
   `GET /panel/api/clients/links/{email}` and logs back the link the
   panel itself generated.

If you deployed an earlier version and already have clients stuck in the
broken state, open that client's edit modal in the panel UI once and hit
**Save** — that forces the panel to recompute its cached client/link
state.

## 🐛 Bug fixed earlier: locations weren't actually pinning

Tor only supports one global exit-country setting per process — it has no
way to say "port 9050 exits in the US, port 9051 exits in Germany" inside
a single `torrc`. `start.sh` generates and launches **8 separate Tor
processes** at container start — one per country, each with its own
`DataDirectory`, its own `SocksPort`, and its own `ExitNodes {cc}` +
`StrictNodes 1`. Because they're fully separate processes, they genuinely
cannot bleed into each other. The static `torrc` file is no longer used
by the Dockerfile for this reason — the real per-instance configs are
generated at runtime by `start.sh` (`torrc.reference` is documentation
only, safe to omit).

## 🐛 Bug fixed earlier: nginx buffering/timeouts breaking VLESS-over-WS

Every VLESS location sets:
```
proxy_buffering off;
proxy_request_buffering off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
```
plus `X-Real-IP` / `X-Forwarded-For` / `X-Forwarded-Proto` headers on
`/in1`-`/in8` (not just `/` and `/managepanel/`).

## 🤖 Automatic inbound + client + outbound provisioning

`panel-bootstrap.sh` runs once in the background after x-ui comes up. It:

1. **Detects your public domain** automatically from Railway's
   `RAILWAY_PUBLIC_DOMAIN` (or `RAILWAY_STATIC_URL`) env var — set a
   `PUBLIC_DOMAIN` env var yourself to override this if needed.
2. Authenticates to the panel API. Two options:
   - **Recommended:** create an API token in the panel (Settings → API
     Tokens → Create) and set it as the `XUI_API_TOKEN` env var on the
     Railway service.
   - **Fallback:** if `XUI_API_TOKEN` isn't set, the script logs in with
     `XUI_USERNAME` / `XUI_PASSWORD` env vars (default `admin`/`admin`).

   ⚠️ **Never paste a real token or password into chat, a commit, or this
   README.** Set it only as a Railway environment variable.
3. Creates 8 VLESS/WebSocket inbounds (`in1`..`in8`) matching the nginx
   path/port table below, empty of clients, each tagged with its Tor
   country.
4. Creates one client per inbound through the panel's own Clients API.
5. Adds a SOCKS5 outbound per Tor instance and **automatically imports an
   enabled routing rule** pinning each inbound's traffic to its matching
   outbound.
6. Reads back each client's real link via `/panel/api/clients/links/{email}`
   and logs it.
7. Is safe to re-run (checks for existing tags/clients/outbounds/rules
   first, and strips any leftover `rand9` entries) — it runs on every boot
   but won't duplicate anything.

## 🚀 Deployment Steps

### 1. Repository
Add these files to your GitHub repo root:
- `Dockerfile`
- `nginx.conf.template`
- `start.sh`
- `panel-bootstrap.sh`

(`torrc.reference` is documentation only — safe to omit.)

### 2. Deploy on Railway
1. [Railway.app](https://railway.app) → **New Project → Deploy from GitHub repo**
2. Railway auto-detects the `Dockerfile` and builds it
3. After deploy, go to **Settings → Networking** → **Generate Domain**
4. (Optional) set env vars `XUI_USERNAME` / `XUI_PASSWORD` and
   `PUBLIC_DOMAIN` if needed

### 3. First Login
```
https://your-domain.up.railway.app/managepanel/
```
Default: `admin` / `admin` — **change immediately** in Settings, then set
`XUI_USERNAME`/`XUI_PASSWORD` on the Railway service.

### 4. Inbounds + clients are created automatically

| Path | Internal Port | Tor Exit Country | Tor Port | Rotates? |
|------|---------------|-------------------|----------|----------|
| `/` | 8080 | (direct, real server IP — no Tor) | — | no |
| `/in1` | 8081 | United States | 9050 | every 60s |
| `/in2` | 8082 | Germany | 9051 | every 60s |
| `/in3` | 8083 | France | 9052 | every 60s |
| `/in4` | 8084 | Netherlands | 9053 | every 60s |
| `/in5` | 8085 | Canada | 9054 | every 60s |
| `/in6` | 8086 | Japan | 9055 | every 60s |
| `/in7` | 8087 | Singapore | 9056 | every 60s |
| `/in8` | 8088 | United Kingdom | 9057 | every 60s |

`/` (the real-IP location) is now auto-provisioned by `panel-bootstrap.sh`
just like the 8 Tor locations — you don't need to create it by hand.

If you'd rather build inbounds by hand: Protocol `VLESS`, Listen IP
`0.0.0.0`, Network `ws`, Security `none`, Path matching the table above
exactly, Listen Port matching the table above exactly — then add the
client through the panel UI's own "Add client" button.

### 5. Client Config
The bootstrap script logs the panel-generated client link to
`/var/log/panel-bootstrap.log` for each inbound.

### Quick sanity check
Open in a browser:
```
https://your-domain.up.railway.app/in1
```
You should see **"Bad Request"** — that means the request reached Xray.

## 🌐 Assigning Tor outbounds manually (if you skip the auto script)

1. Panel → **Settings → Outbounds** → Add
2. Protocol `SOCKS5`, Address `127.0.0.1`, Port `9050`-`9057`
3. Assign the outbound to specific users when creating/editing them

To change a pinned country, edit the `TOR_TAGS`/`TOR_PORTS` mapping in
`start.sh` (and the matching `TAGS`/`TOR_PORTS` in `panel-bootstrap.sh`)
and redeploy.

## 🔓 Exposing a Tor SOCKS port publicly (optional)

1. Railway dashboard → your service → **Settings → Networking**
2. Under **TCP Proxy**, click **Add TCP Proxy**
3. Point it at internal port `9050` (or whichever exit you want public)
4. Railway gives you a `host:port` pair — that's your public SOCKS5 endpoint

**Security note:** an openly exposed SOCKS5 proxy with no auth can be
abused by anyone who finds it. Consider adding a username/password to the
relevant instance in `start.sh`'s `render_instance` function if you do
this.

## ✅ Testing Tor Directly

```bash
curl --socks5-hostname 127.0.0.1:9050 https://api.ipify.org
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
```
Repeat with 9051-9057 to confirm each instance really is exiting from its
assigned country.

## 🛠️ Troubleshooting

**Copy config / QR code still unavailable for a client** → open that
client's edit modal in the panel UI once and hit Save. If still broken,
check whether the client has a `subId` set via
`GET /panel/api/clients/get/<email>`; if not, delete and recreate it
(`POST /panel/api/clients/del/<email>`, then restart the container).

**A location's traffic doesn't match the expected country** → confirm
with the `curl --socks5-hostname` test above for that instance's port. If
that direct test already shows the wrong country, check
`/var/log/tor/<name>/notices.log`. If the direct test is correct but
proxying through the panel isn't, check the routing rule for that inbound
tag in Settings → Xray Configs — it must have `"enabled": true`.

**Inbounds/clients/outbounds weren't auto-created** → look for
`[panel-bootstrap]` lines in your Railway logs. Most common cause:
`XUI_USERNAME`/`XUI_PASSWORD` (or `XUI_API_TOKEN`) don't match a changed
panel password/token.

**"Application failed to respond"** → nginx isn't listening on `$PORT`.
Check deploy logs for a failed `nginx -t` or a crashed x-ui process.

**A specific country's Tor instance never bootstraps** → each instance
logs to its own `/var/log/tor/<name>/notices.log`. Datacenter hosts
sometimes throttle outbound Tor directory traffic, or the pinned country
temporarily has too few usable exits for `StrictNodes 1` to complete a
circuit — other instances are unaffected since they're separate
processes.

**Slow speeds over a Tor outbound** → expected; Tor is inherently slower
than a direct connection.

**Checking whether rotation is actually working** → hit
`/tor-status/<location>.json` (e.g. `/tor-status/us.json`) — the
`exit_ip` field should change roughly every `ROTATE_SECONDS`, and
`checked_at` should always be recent. `/var/log/tor/rotate.log` inside
the container has the full rotation history if you need more detail.

**A location's `reachable` flag is often `false`** → that cycle's live
verification (fetch + ping through the new circuit) didn't complete in
time, usually because the freshly-built circuit through a strictly
pinned country is briefly slow. Traffic through the location isn't
necessarily broken — check the next cycle's status, and if it's
consistently `false` for one country, check
`/var/log/tor/<name>/notices.log` for that instance.

## ⚠️ Notes

- The panel/inbound stack starts immediately and independently of Tor.
- X-UI's database (`/etc/x-ui`) lives on the container's ephemeral
  filesystem. Add a Railway **Volume** mounted at `/etc/x-ui` if you don't
  want users/inbounds wiped on every redeploy.
- Restarting the container gives you fresh Tor exit IPs (all 8 instances).
- This project is for educational purposes — use responsibly.
