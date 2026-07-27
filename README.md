# 3x-ui + Tor on Railway

Deploys 3x-ui with 9 independent Tor exit-country instances behind a single
public nginx port, and auto-provisions the location inbounds + Tor outbounds
+ routing rules through the panel API on boot.

## 🌟 Features

- ✅ Panel + VLESS inbounds + Tor, all in one container
- ✅ Single public port (nginx handles routing)
- ✅ **9 real, independent exit countries** — each Tor SocksPort is now its
  own Tor process with its own `ExitNodes`, so locations actually pin
  correctly (see bug fix below)
- ✅ **Auto-provisioning**: on boot, a script logs into the panel API,
  auto-detects the deployment's public domain, creates the 9 location
  inbounds, and wires each one to its matching Tor outbound via a routing
  rule — no manual panel clicking required
- ✅ Tor runs fully in the background — it can never block or crash the panel
- ✅ nginx tuned correctly for VLESS-over-WebSocket on every path

## 🐛 Bug fixed in this version: locations weren't actually pinning

The previous `torrc` had **one shared `ExitNodes` setting for all 10
SocksPorts**. Tor only supports one global exit-country setting per process
— it has no way to say "port 9050 exits in the US, port 9051 exits in
Germany" inside a single `torrc`. So every port was exiting from wherever
Tor felt like, regardless of the country table, even though the panel and
proxy themselves worked fine.

**Fix:** `start.sh` now generates and launches **9 separate Tor processes**
at container start — one per country, each with its own `DataDirectory`,
its own `SocksPort`, and its own `ExitNodes {cc}` + `StrictNodes 1`. Because
they're fully separate processes, they genuinely cannot bleed into each
other. A 9th "random" instance covers the two ports that intentionally have
no country restriction. The static `torrc` file is no longer used by the
Dockerfile for this reason — the real per-instance configs are generated at
runtime by `start.sh`. You can delete the old `torrc` from your repo, or
keep it around as a reference (it isn't `COPY`'d into the image anymore).

## 🐛 The nginx bug this version also fixes

nginx buffers proxied responses by default. VLESS-over-WebSocket is a
long-lived, bidirectional binary stream, not a normal request/response —
with buffering on, nginx can stall or corrupt that stream even though the
panel (plain HTTP) works perfectly. On top of that, nginx's default
60-second `proxy_read_timeout` silently kills a WS tunnel meant to stay
open indefinitely. Every VLESS location sets:
```
proxy_buffering off;
proxy_request_buffering off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
```
This version also adds the `X-Real-IP` / `X-Forwarded-For` /
`X-Forwarded-Proto` headers to `/in1`-`/in9` (they were previously only on
`/` and `/managepanel/`) — without them, per-IP limiting/fail2ban on the
location paths sees every connection as coming from nginx itself.

## 🤖 New: automatic inbound + outbound provisioning

`panel-bootstrap.sh` runs once in the background after x-ui comes up. It:

1. **Detects your public domain** automatically from Railway's
   `RAILWAY_PUBLIC_DOMAIN` (or `RAILWAY_STATIC_URL`) env var — set a
   `PUBLIC_DOMAIN` env var yourself to override this if needed.
2. Logs into the panel API (`XUI_USERNAME` / `XUI_PASSWORD` env vars,
   default `admin`/`admin` — **set these** if you've changed the panel
   password, or the script's login will simply fail harmlessly and skip
   provisioning).
3. Creates 9 VLESS/WebSocket inbounds (`in1`..`in9`) matching the nginx
   path/port table below, each already carrying its Tor country as its tag.
4. Adds a SOCKS5 outbound per Tor instance and a routing rule pinning each
   inbound's traffic to its matching outbound.
5. Is safe to re-run (checks for existing tags/outbounds/rules first) — it
   runs on every boot but won't duplicate anything.

**Please verify this once after your first deploy.** The panel's public
API endpoints are documented with one-line descriptions, not full JSON
schemas, so step 4 (splicing outbounds/routing into the Xray config) is
built from the well-established 3x-ui API conventions but hasn't been
tested against your exact panel build. Check `/var/log/panel-bootstrap.log`
inside the container (Railway → your service → logs, or `railway logs`) —
if step 4 fails, it prints the exact API response and never overwrites your
existing config, so nothing breaks even if a field name needs a tweak.

## 🚀 Deployment Steps

### 1. Repository
Add these files to your GitHub repo root:
- `Dockerfile`
- `nginx.conf.template`
- `start.sh`
- `panel-bootstrap.sh`

(`torrc` is no longer needed by the Dockerfile — safe to remove or keep as
reference.)

### 2. Deploy on Railway
1. [Railway.app](https://railway.app) → **New Project → Deploy from GitHub repo**
2. Railway auto-detects the `Dockerfile` and builds it
3. After deploy, go to **Settings → Networking** → **Generate Domain**
   (nginx listens directly on `$PORT`, so no target port config is needed)
4. (Optional but recommended) set env vars `XUI_USERNAME` / `XUI_PASSWORD`
   if you change the panel login from the default, and `PUBLIC_DOMAIN` if
   Railway's auto-detected domain env vars aren't present in your plan

### 3. First Login
```
https://your-domain.up.railway.app/managepanel/
```
Default: `admin` / `admin` — **change immediately** in Settings, then set
`XUI_USERNAME`/`XUI_PASSWORD` on the Railway service so the bootstrap
script can still log in on the next restart.

### 4. Inbounds are created automatically

Give `panel-bootstrap.sh` a minute after the panel comes up, then refresh
the panel UI — `in1`..`in9` should already exist, tagged by country, wired
to their matching Tor outbound.

| Path | Internal Port | Tor Exit Country | Tor Port |
|------|---------------|-------------------|----------|
| `/` | 8080 | (direct, no Tor) | — |
| `/in1` | 8081 | United States | 9050 |
| `/in2` | 8082 | Germany | 9051 |
| `/in3` | 8083 | France | 9052 |
| `/in4` | 8084 | Netherlands | 9053 |
| `/in5` | 8085 | Canada | 9054 |
| `/in6` | 8086 | Japan | 9055 |
| `/in7` | 8087 | Singapore | 9056 |
| `/in8` | 8088 | United Kingdom | 9057 |
| `/in9` | 8089 | Random | 9058 |
| — | — | Random (spare, unassigned) | 9059 |

If you'd rather build inbounds by hand instead of relying on the script:
Protocol `VLESS`, Listen IP `0.0.0.0`, Network `ws`, Security `none`, Path
matching the table above exactly, Listen Port matching the table above
exactly.

### 5. Client Config
The bootstrap script logs a ready-to-use client link (with your
auto-detected domain filled in) to `/var/log/panel-bootstrap.log` for each
inbound. It looks like:
```
vless://UUID@your-domain.up.railway.app:443?encryption=none&security=tls&sni=your-domain.up.railway.app&fp=chrome&type=ws&host=your-domain.up.railway.app&path=%2Fin1#Tor-US
```

### Quick sanity check before testing with a real client
Open in a browser:
```
https://your-domain.up.railway.app/in1
```
You should see **"Bad Request"** — that means the request reached Xray
(good sign). If you get Railway's "Application failed to respond" instead,
nginx itself isn't up — check deploy logs.

## 🌐 Assigning Tor outbounds manually (if you skip the auto script)

1. Panel → **Settings → Outbounds** → Add
2. Protocol `SOCKS5`, Address `127.0.0.1`, Port `9050`-`9059`
3. Assign the outbound to specific users when creating/editing them

To change a pinned country, edit the `TOR_TAGS`/`TOR_PORTS` country-code
mapping in `start.sh` and redeploy.

## 🔓 Exposing a Tor SOCKS port publicly (optional)

Railway's generated domain is HTTP(S)-only and routes to a single port via
nginx — raw SOCKS5 traffic can't ride along that same domain, since SOCKS5
isn't HTTP. If you actually want an externally reachable Tor SOCKS proxy
(not just X-UI using it internally as an outbound), you need Railway's
**TCP Proxy** feature, which is separate from the HTTP domain:

1. Railway dashboard → your service → **Settings → Networking**
2. Under **TCP Proxy**, click **Add TCP Proxy**
3. Point it at internal port `9050` (or whichever exit you want public)
4. Railway gives you a `host:port` pair — that's your public SOCKS5 endpoint

Every instance's `SocksPort` already binds to `0.0.0.0` (not just
`127.0.0.1`) specifically so this works without further changes.

**Security note:** an openly exposed SOCKS5 proxy with no auth can be
abused by anyone who finds it. If you do this, consider adding a
username/password to the relevant instance config in `start.sh`'s
`render_instance` function (`SocksPort ... IsolateSOCKSAuth` +
`Socks5ProxyUsername`/`Password`) so it's not fully open to the internet.

## ✅ Testing Tor Directly

```bash
curl --socks5-hostname 127.0.0.1:9050 https://api.ipify.org
curl --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip
```
Repeat with 9051-9059 to confirm each instance really is exiting from its
assigned country.

## 🛠️ Troubleshooting

**A location's traffic doesn't match the expected country** → confirm
with the `curl --socks5-hostname` test above for that instance's port. If
that direct test already shows the wrong country, check
`/var/log/tor/<name>/notices.log` for that instance — it may still be
bootstrapping or Railway may be throttling directory traffic for it
specifically (see below). If the direct test is correct but proxying
through the panel isn't, check the routing rule for that inbound tag in
Settings → Xray Configs.

**Inbounds/outbounds weren't auto-created** → check
`/var/log/panel-bootstrap.log`. Most common cause: `XUI_USERNAME`/
`XUI_PASSWORD` env vars don't match a changed panel password.

**Panel loads, config doesn't work** → covered above (buffering/timeouts);
also double check Listen Port/Path match exactly.

**"Application failed to respond"** → nginx isn't listening on `$PORT` at
all. Check deploy logs for a failed `nginx -t` (config syntax) or a
crashed x-ui process — `start.sh` exits loudly with the bad config dumped
if this happens, instead of failing silently.

**A specific country's Tor instance never bootstraps** → each instance
logs to its own `/var/log/tor/<name>/notices.log`; the watcher reports
`[tor-watcher:<name>]` lines per instance. Datacenter hosts (Railway
included) sometimes throttle or block outbound Tor directory traffic —
if an instance never reaches `Bootstrapped 100%` within 90s, that's the
likely cause, and it's outside this container's control. Other instances
are unaffected since they're separate processes.

**Slow speeds over a Tor outbound** → expected; Tor is inherently slower
than a direct connection. Use it for specific users only, not all traffic.

## ⚠️ Notes

- The panel/inbound stack starts immediately and independently of Tor —
  Tor bootstrapping (or failing to, per instance) never delays or breaks
  the panel.
- X-UI's database (`/etc/x-ui`) lives on the container's ephemeral
  filesystem. Add a Railway **Volume** mounted at `/etc/x-ui` if you don't
  want users/inbounds wiped on every redeploy (the bootstrap script is
  idempotent either way, so a redeploy without a volume just re-creates
  the same 9 inbounds instead of erroring).
- Restarting the container gives you fresh Tor exit IPs (all 9 instances).
- This project is for educational purposes — use responsibly.
