# asterisk-deploy — Complete Walkthrough

This document explains **everything** the `asterisk-deploy` kit does, file by file,
line by line (conceptually). It assumes you're comfortable in a Linux shell but not
necessarily an Asterisk or `make`/`nftables` expert.

The kit's job: **take a bare, fresh Ubuntu server and turn it into a working copy of
the "Aakashtel" call-center PBX** — same Asterisk version, same trunk, same NAT/RTP
behaviour, same firewall posture — using repeatable scripts instead of manual typing.

---

## 1. The mental model (read this first)

Think of a rebuild as five questions. Each script answers exactly one:

| Question | Answered by |
| --- | --- |
| What software do I need, and how do I install it? | `scripts/install_packages.sh` |
| What are the *values* specific to THIS server? | `.env` (you fill it) |
| How do those values turn into real Asterisk config files? | `templates/*.template` + `scripts/configure_asterisk.sh` |
| How do I stand up the web/API front-end? | `scripts/configure_webserver.sh` (nginx + PHP-FPM) |
| How do I get + auto-renew a TLS certificate? | `scripts/configure_tls.sh` (certbot + deploy hook) |
| How do I install the call-center apps + background services? | `scripts/deploy_app.sh` (npm + systemd units) |
| How do I keep attackers out? | `scripts/configure_firewall.sh` + `scripts/configure_fail2ban.sh` |
| How do I prove it actually works? | `scripts/verify.sh` |

> This server is **not just Asterisk**. It's a full call-center stack: Asterisk (SIP
> engine) + **nginx & PHP-FPM** (the web/API front-end serving `/home/projects`) +
> **certbot** (Let's Encrypt TLS) + **four Node.js background services** + **fail2ban**.
> The kit reproduces all of it, so `make deploy` covers the whole box, not just the PBX.

The **Makefile** is just a "remote control" that runs those scripts in the right
order. The **backup** script is a safety net that runs first.

The single most important idea is the **template + .env split**:

```
templates/pjsip.conf.template   (structure, with ${PLACEHOLDERS})
        +
.env                            (the real values: IPs, passwords, DID…)
        │  envsubst
        ▼
/etc/asterisk/pjsip.conf        (final config Asterisk actually reads)
```

Why do it this way? Because the *structure* of the config (which sections exist,
what NAT flags are set, codec order, etc.) is identical on every rebuild, but the
*values* (public IP, trunk password) change per server. Templates capture the part
that never changes; `.env` captures the part that does. You never hand-edit
`/etc/asterisk` — you edit `.env` and re-render.

---

## 2. Directory layout

```
asterisk-deploy/
├── Makefile                 # orchestrator: `make <target>`
├── .env.example             # blank form of all per-server values (copy to .env)
├── menuselect.makeopts      # EXACT Asterisk build options captured from the server
├── README.md                # quick-start
├── EXPLAINER.md             # this file
├── scripts/                 # the actual work, one concern per script
│   ├── backup_existing_config.sh
│   ├── install_packages.sh       # Asterisk (source) + PHP-FPM + nginx + certbot + Node
│   ├── configure_asterisk.sh     # render /etc/asterisk + logrotate
│   ├── configure_webserver.sh    # nginx site + php-fpm
│   ├── configure_tls.sh          # certbot cert + copy-to-asterisk deploy hook
│   ├── deploy_app.sh             # npm install + companion systemd services
│   ├── configure_firewall.sh
│   ├── configure_fail2ban.sh
│   └── verify.sh
└── templates/               # parameterized configs, one file per concern
    ├── asterisk.conf.template       # -> core: runuser=asterisk, systemname, dirs
    ├── pjsip.conf.template          # -> SIP: trunk, transports, NAT, endpoints
    ├── extensions.conf.template     # -> dialplan (the 4 custom contexts)
    ├── rtp.conf.template            # -> RTP range + NAT media + ICE
    ├── modules.conf.template        # -> module loading
    ├── manager.conf.template        # -> AMI (hardened to loopback)
    ├── http.conf.template           # -> HTTP 8088 + HTTPS 7443 (carries ARI + WSS)
    ├── ari.conf.template            # -> ARI user (password stored crypted)
    ├── queues.conf.template         # -> queue engine + #include queue_custom.conf
    ├── cdr.conf.template            # -> CSV call records (+unanswered)
    ├── cdr_manager.conf.template    # -> CDR-as-AMI-events (consumed by ami.service)
    ├── logger.conf.template         # -> logging
    ├── logrotate-asterisk.template  # -> /etc/logrotate.d/asterisk
    ├── nginx-site.conf.template     # -> /etc/nginx/sites-available/aakashtel
    └── systemd/                     # -> /etc/systemd/system/*.service
        ├── ami.service.template
        ├── broadcast.service.template
        ├── sipuser.service.template
        └── sipqueue-populate.service.template
```

All **12 Asterisk config files that were customized on the reference server** are
templated — the render list in `configure_asterisk.sh` matches the audit exactly.

---

## 3. `.env` — the one file you edit

You never edit scripts or templates. You copy `.env.example` to `.env` and fill in
real values:

```bash
cp .env.example .env
nano .env
```

Every variable, grouped:

**Asterisk version**
- `ASTERISK_VERSION=22.10.0` — must match the reference box so behaviour is identical.

**Networking / NAT** (this box lives behind a router doing NAT)
- `PUBLIC_IP` — the *public* IP the outside world / carrier sees. Asterisk advertises
  this in SIP/SDP so remote parties send audio to the right place. **Wrong value =
  one-way or no audio.**
- `LOCAL_IP` — the server's private IP (e.g. `172.16.176.6`).
- `LOCAL_CIDR` — the LAN subnet (`172.16.176.0/24`). Asterisk treats these as "local"
  and does *not* apply NAT rewriting to them.
- `CARRIER_CIDR` — the carrier/IMS network (`10.40.55.0/24`), also treated as local.

**RTP media**
- `RTP_START` / `RTP_END` (`10000`/`30000`) — the UDP port range voice audio uses.
  This range must be open on the firewall and forwarded by the router.

**SIP trunk (the carrier line)**
- `SIP_PROVIDER_HOST` — carrier SIP domain (`ims.ntc.net.np`).
- `SIP_PROXY` — the carrier's SBC `host:port` (`10.40.55.4:5060`) — where we register
  and send calls.
- `SIP_TRUNK_NAME` — the label for the trunk in `pjsip.conf` (`+97761597077`).
- `SIP_USERNAME` / `SIP_SECRET` — trunk login. `SIP_SECRET` starts as `<ASK_USER>`;
  the configure script **refuses to run** until you replace it with the real password.
- `DID_NUMBER` — your inbound phone number (calls to it arrive from the carrier).
- `OUTBOUND_CID` — the caller ID shown on outbound calls.
- `TRUNK_CODEC` — audio codec the carrier expects (`alaw`).

**Firewall allow-lists**
- `PROVIDER_ALLOW_IPS` — carrier IPs allowed to reach SIP.
- `ADMIN_ALLOW_IPS` — your admin IPs allowed to reach SSH / AMI / HTTP.

**System**
- `TIMEZONE` (`Asia/Kathmandu`) — matters for call records and TLS validity.
- `SYSTEMNAME` (`Aakashtel`) — cosmetic name shown in the Asterisk CLI.

**TLS / WebRTC**
- `ENABLE_TLS`, `TLS_CERT`, `TLS_KEY` — certificate + private key for SIP-TLS and
  WebRTC. Reissue for the new hostname on a rebuild.

**HTTP / ARI / AMI** (the management interfaces)
- `HTTP_BIND` defaults to `127.0.0.1:8088` — **hardened**: only reachable from the
  server itself. (The reference box had this open to the world.)
- `HTTPS_BIND=0.0.0.0:7443` — the non-standard TLS port the app uses for WebRTC.
- `AMI_BIND` defaults to `127.0.0.1` — AMI is powerful (can originate calls, run CLI),
  so we lock it to loopback by default.
- `AMI_USER`/`AMI_SECRET`, `ARI_USER`/`ARI_SECRET` — management credentials.

**App layer**
- `PROJECTS_DIR=/home/projects` — where the PHP/Node apps live.
- `APP_BACKEND_BASE_URL` — the backend API those apps call.
- `NODE_VERSION=v24.16.0` — Node version for the companion services.

> **Key safety detail:** placeholders look like `<ASK_USER>` and `<CHANGE_ME>`. They
> are deliberately invalid so you can't accidentally deploy with fake values —
> scripts check for them and stop.

---

## 4. `Makefile` — the orchestrator

You don't strictly need `make`; it just saves you from remembering the script order.

**How it loads your values (top of the file):**
```makefile
ifneq (,$(wildcard ./$(ENV_FILE)))
include $(ENV_FILE)     # read .env
export                  # make its variables visible to the scripts make calls
endif
```
This means every `make` target automatically has your `.env` values in its
environment.

**The targets** (`make help` prints them):

| Target | What it does | Depends on |
| --- | --- | --- |
| `help` | Lists targets (the default if you just type `make`) | — |
| `check` | **Preflight**: are you root? does `.env` exist? is this Ubuntu/Debian? is `envsubst` installed? | — |
| `backup` | Snapshot the existing `/etc/asterisk` before touching anything | `check` |
| `install` | Build & install Asterisk + PHP + Node | `check` |
| `configure` | Render templates into `/etc/asterisk` | `check` |
| `firewall` | Apply the nftables rules | `check` |
| `fail2ban` | Install the ban jails | `check` |
| `deploy` | **The whole thing in order**: backup → install → configure → firewall → fail2ban | all the above |
| `verify` | Check registration, ports, logs | `check` |
| `all` | `deploy` then `verify` | — |

Because `deploy` lists its prerequisites (`deploy: backup install configure firewall
fail2ban`), typing `sudo make deploy` runs those five in that exact order. That's the
"right order" encoded so you can't get it wrong.

**The `check` target in plain English:**
- `test "$(id -u)" = "0"` → must be root (installing packages / writing `/etc` needs it).
- `test -f .env` → you must have created your `.env`.
- reads `/etc/os-release` and warns if you're not on Ubuntu/Debian (the scripts use `apt`).
- confirms `envsubst` exists (it's what renders the templates).

---

## 5. The scripts (in the order `deploy` runs them)

Every script starts with the same two safety lines:
```bash
#!/usr/bin/env bash
set -euo pipefail
```
- `set -e` — stop immediately if any command fails (no plowing ahead after an error).
- `set -u` — error if you use an unset variable (catches typos in `.env`).
- `set -o pipefail` — a failure anywhere in a pipe (`a | b | c`) fails the whole line.

And they load your `.env`:
```bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the kit's root dir
[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a
```
`set -a` means "every variable I define from now on is automatically exported," so
sourcing `.env` makes all its values available to commands the script runs.

### 5.1 `backup_existing_config.sh` — the safety net (runs first)

Purpose: never destroy an existing config without a copy.

- Builds a timestamped folder: `/var/backups/asterisk-config-YYYYMMDD-HHMMSS`.
- If `/etc/asterisk` exists, `tar -czf` it into that folder (`etc-asterisk.tar.gz`).
- Also copies the two **generated** app configs if present (`user.conf`,
  `queue_custom.conf`).
- Prints the exact **rollback command** so you can undo everything:
  `tar -xzf .../etc-asterisk.tar.gz -C /etc`.

On a truly fresh host there's nothing to back up — it just says so and continues.

### 5.2 `install_packages.sh` — get the software

This is the biggest script. It reproduces the reference server's install method,
which is **build-from-source** (not the Ubuntu package, because Ubuntu only ships
Asterisk 20 and this box runs 22.10.0).

Step by step:
1. **Timezone** — `timedatectl set-timezone` so CDR timestamps and TLS are correct.
2. **Build dependencies** — `apt-get install` the compilers and dev libraries
   Asterisk needs (`libjansson-dev`, `libxml2-dev`, `libssl-dev`, `libsrtp2-dev`,
   etc.) plus `php-cli` and friends for the AGI scripts, and `gettext-base` (that's
   where `envsubst` comes from).
3. **Create the `asterisk` user/group** if missing — a non-login system account,
   added to `audio` and `dialout` groups (matches the reference box).
4. **Build Asterisk** — *idempotent*: if `asterisk -V` already reports the target
   version, it **skips** the whole build. Otherwise it:
   - downloads the matching source tarball into `/usr/src`,
   - runs `contrib/scripts/install_prereq install` (pulls remaining OS deps),
   - `./configure --with-pjproject-bundled --with-jansson-bundled`,
   - uses `menuselect` to enable the modules we actually use (`chan_pjsip`,
     `res_pjsip`, `app_queue`, `res_agi`, `res_ari`, `codec_alaw`, `codec_ulaw`, …),
   - `make -j$(nproc)` (compile using all CPU cores), `make install`,
   - `make samples` (drops the stock sample configs — our templates overwrite the
     ones that matter),
   - `make config` — **installs the service itself** (`/etc/init.d/asterisk` + rc
     links; systemd picks it up via its sysv-generator, exactly like the reference
     box). Without this, `systemctl enable asterisk` would fail,
   - `ldconfig` (refresh the shared-library cache),
   - `chown -R asterisk:asterisk` on `/var/lib|log|spool|run|cache/asterisk` —
     `make install` leaves them root-owned and Asterisk (running as `asterisk`)
     couldn't write logs/CDR/astdb.
   - If the kit ships `menuselect.makeopts` (captured from the reference server),
     the build uses it for an **exact module match** instead of guessing.
5. **Write `/etc/default/asterisk`** — sets `AST_USER`/`AST_GROUP=asterisk` so the
   daemon runs as the right identity.
6. **Install Node.js via nvm** — for the companion `ami`/`broadcast` services. Also
   idempotent (skips if the version is already present).

At the end it reminds you that the `/home/projects` app code and its `npm install`
are a **separate manual step** (see §7) — the kit doesn't ship your application.

### 5.3 `configure_asterisk.sh` — turn templates into real config

This is where the template + `.env` merge happens.

1. **Load and validate `.env`** — it has a `req=(…)` list of variables that MUST be
   set (IPs, RTP range, trunk details, AMI creds, cert paths…). If any are empty it
   prints exactly which ones and exits. It also explicitly rejects a `SIP_SECRET`
   still set to `<ASK_USER>` — you can't deploy with a placeholder password.
2. **Derive helper values** — e.g. it splits `SIP_PROXY` (`10.40.55.4:5060`) into
   `SIP_PROXY_HOST` and `SIP_PROXY_PORT` because some templates need just the host
   (the `identify`/`match` line uses the bare IP).
3. **Render each Asterisk template** with a **restricted** `envsubst`:
   ```bash
   envsubst "$SUBST_VARS" < "$t" > "/etc/asterisk/$base"
   ```
   ⚠️ **Critical subtlety:** Asterisk's *dialplan* is full of its own `${...}` tokens
   — `${EXTEN}`, `${CALLERID(num)}`, `${CUT(...)}`, `${last_part}`. A bare
   `envsubst` (no argument) would try to substitute **those too**, find them empty,
   and **blank them out — destroying the dialplan**. So the script passes an explicit
   whitelist (`$SUBST_VARS` = only our deploy variables like `${PUBLIC_IP}`,
   `${SIP_SECRET}`, `${DID_NUMBER}`…). `envsubst` then replaces only those and leaves
   every Asterisk `${EXTEN}` untouched. (This was a real bug fixed during review.)
   It renders **all 12 customized configs**: `asterisk.conf` (runuser — Asterisk
   never runs as root), `pjsip.conf`, `extensions.conf`, `rtp.conf`, `modules.conf`,
   `manager.conf`, `logger.conf`, `http.conf` (without it the stock sample leaves
   HTTP **disabled** → no ARI, no WSS/WebRTC), `ari.conf`, `queues.conf`,
   `cdr.conf`, `cdr_manager.conf`.
4. **Crypts the ARI password** — `openssl passwd -6 "$ARI_SECRET"` → the template
   stores only the sha-512 hash (`password_format = crypt`), never plaintext.
5. **Install the logrotate rule** the reference server was missing (its `messages.log`
   had reached ~1 GB) → `/etc/logrotate.d/asterisk`.
6. **Create the `#include` targets** — `touch`es `/home/projects/user.conf` and
   `queue_custom.conf` (owned `asterisk`, `0664`) so Asterisk doesn't error on the
   `#include` lines before the Node generators have run.
7. **Self-signed cert fallback** — if `${TLS_CERT}` doesn't exist yet (certbot runs
   later in the sequence), it generates a temporary 30-day self-signed pair so the
   TLS/WSS transports can bind and Asterisk starts cleanly; `make tls` replaces it
   with the real Let's Encrypt cert.
8. **Fix ownership/permissions** — `chown -R asterisk:asterisk /etc/asterisk`, dir
   `0750`, files `0640` (matches the reference box; keeps secrets non-world-readable).
9. **Does NOT reload Asterisk** — deliberately. On a fresh host you start Asterisk
   yourself afterwards; the script won't touch a running service.

### 5.4 `configure_webserver.sh` — the nginx + PHP-FPM front-end

The `/home/projects` app has a **web/API side** served by nginx with PHP-FPM. This
script reproduces that vhost.

- Installs `nginx` + `php${PHP_VERSION}-fpm` if missing.
- Renders `templates/nginx-site.conf.template` (again with a **restricted**
  `envsubst` so nginx's own `$uri`, `$document_root`, `$fastcgi_script_name` survive)
  into `/etc/nginx/sites-available/aakashtel` and symlinks it into `sites-enabled`.
- The site: document root `${WEB_ROOT}` (`/home/projects`), a `/service` location
  handled by PHP-FPM (the app's API), a `/voice/` location that lists call
  recordings, PHP handling, and a dotfile deny.
- Removes the stock `default` site (so port 80 doesn't clash), runs `nginx -t` to
  validate, then enables + reloads nginx and php-fpm.
- Leaves TLS to the next script (certbot rewrites this vhost to add the 443 block).

### 5.5 `configure_tls.sh` — Let's Encrypt certificate + auto-renew

Asterisk runs as the unprivileged `asterisk` user and **cannot read** the root-only
`/etc/letsencrypt` tree — which is exactly why the reference box keeps a **copy** of
the certs in `/home/certs`. This script reproduces that safely:

1. **Installs a certbot deploy-hook first** at
   `/etc/letsencrypt/renewal-hooks/deploy/copy-to-asterisk.sh`. On every issuance
   *and* every future auto-renewal, this hook copies `fullchain.pem`/`privkey.pem`
   into `${CERT_DEST}` (`/home/certs`), `chown`s them to `asterisk`, and reloads
   Asterisk's TLS (`module reload res_pjsip.so`) + nginx — **without dropping calls**.
2. **Obtains the certificate** with `certbot --nginx -d ${DOMAIN}` (or `certbot renew`
   if it already exists). The nginx plugin does the HTTP-01 challenge and adds the
   443 server block + HTTP→HTTPS redirect.
3. **Runs the hook once now** so `/home/certs` is populated immediately.
4. Enables `certbot.timer` for hands-off renewal every ~60 days.

This closes the gap where Asterisk's TLS would otherwise silently expire.

### 5.6 `deploy_app.sh` — the call-center apps + background services

Asterisk is only the engine; the actual dialer logic is the `/home/projects` apps
plus four Node.js services. This script wires them up.

- **Guard:** if `/home/projects/ami/listAllEvent.js` isn't present, it prints
  instructions and exits cleanly — the **application code is not shipped in this kit**
  (it contains API tokens + AWS keys), so you copy it from your own repo first.
- Runs `npm install --omit=dev` in `ami/` and `broadcast/` (deps: `ari-client`,
  `asterisk-ami-client`, `asterisk-manager`, `axios`, `express`, `form-data`).
- Renders the four systemd unit templates (injecting the real Node binary path
  `/root/.nvm/.../node` and `PROJECTS_DIR`) into `/etc/systemd/system/`, then
  `daemon-reload` + `enable`s them:
  - `ami.service` — the AMI listener/originator (always-on).
  - `broadcast.service` — the outbound broadcast dialer.
  - `sipuser.service` — regenerates `user.conf` from the backend API.
  - `sipqueue-populate.service` — regenerates `queue_custom.conf`.
- `chown`s the app tree to `asterisk`.

### 5.7 `configure_firewall.sh` — lock the doors (nftables)

The reference server had an essentially **open** firewall (only fail2ban protected
it). This script **hardens** the rebuild with a default-deny policy.

- Ensures `nft` (nftables) is installed.
- Builds two allow-list "sets" from your `.env`:
  - `sip_src` = LAN + carrier network + provider IPs + admin IPs → who may talk SIP.
  - `admin_src` = LAN + admin IPs → who may reach SSH/AMI/HTTP.
- Writes a ruleset file `/etc/nftables-asterisk.nft`:
  ```
  chain input { policy drop;              # deny everything by default
      iif lo accept                        # allow loopback
      ct state established,related accept  # allow replies to our own connections
      ip protocol icmp accept              # allow ping
      tcp dport 22   ip saddr @admin_src accept   # SSH — admins only
      tcp dport 5038 ip saddr @admin_src accept   # AMI — admins only
      tcp dport 8088 ip saddr @admin_src accept   # HTTP/ARI — admins only
      tcp dport 7443 ip saddr @admin_src accept   # HTTPS/WSS — admins only
      udp dport 5060 ip saddr @sip_src accept     # SIP — carrier + LAN
      tcp dport 5060 ip saddr @sip_src accept
      tcp dport 5061 ip saddr @sip_src accept     # SIP-TLS
      udp dport 10000-30000 accept                # RTP audio (range open)
  }
  ```
- Loads it with `nft -f`, enables the service, and copies it so it survives reboot.
- **Note it prints:** if you serve WebRTC to the public internet, you must relax the
  `7443` rule (otherwise only admins can reach the web phone).

The logic: SIP signalling is restricted to people who should be sending it (carrier +
your phones); management ports are restricted to admins; RTP audio must be broadly
open because the carrier's media comes from a pool of addresses.

### 5.8 `configure_fail2ban.sh` — auto-ban brute-forcers

Reproduces the reference server's **exact** fail2ban jail (which had already banned
400+ IPs), not a generic one.

- Installs `fail2ban` if missing.
- Writes `/etc/fail2ban/jail.d/defaults.local` — sets the global ban action to
  `nftables` (matches the reference box).
- Writes `/etc/fail2ban/jail.d/asterisk.conf` with two jails:
  - `sshd` — bans IPs hammering SSH.
  - `asterisk` — reads `/var/log/asterisk/messages.log`; after **3** failed SIP auth
    attempts within 600 s it bans the IP for **24 h** (`bantime=86400`) on ports
    5060/5061/5062.
- Builds an `ignoreip` allow-list — `127.0.0.1/8 ::1` + your `LOCAL_CIDR` + every
  `ADMIN_ALLOW_IPS` — **so you can never lock yourself out**.
- Enables and restarts fail2ban (safe here — fresh host, not the live PBX).

Defense-in-depth: even with the firewall, fail2ban catches credential-guessing from
otherwise-allowed sources.

### 5.9 `verify.sh` — prove it works (read-only, safe to re-run)

Runs a checklist and prints `[OK]` / `[WARN]` / `[FAIL]`:
- `core show version` → Asterisk reachable and correct version.
- `pjsip show registrations` → the trunk says **Registered** (the single most
  important health check).
- `pjsip show transports` → udp/tcp/tls/wss present.
- `ss -tulpn` → 5060, 5061, 5038, 8088, 7443 and the RTP start port are listening.
- `dialplan show <context>` → the four custom contexts exist (`incomming`,
  `from-extensions`, `outgoing`, `ami-action`).
- `fail2ban-client status asterisk` → jail active.
- **Web/TLS layer** → nginx + php-fpm active, the cert exists in `/home/certs` (and
  its expiry date), and `certbot.timer` is enabled for auto-renew.
- **Log health** → warns if `messages.log` is over 500 MB (the reference box hit
  ~1 GB with no rotation) and shows recent errors/warnings.
- `systemctl is-active ami broadcast sipqueue-populate` → companion apps running.

It exits non-zero if anything critical failed, so you can use it in automation.

---

## 6. The templates (what each Asterisk file does)

Remember: `${VAR}` gets replaced by your `.env` value during `configure`.

### 6.1 `pjsip.conf.template` — SIP: the trunk, transports, endpoints
The heart of the phone system. Rendered, it produces four kinds of objects:

- **`[global]`** — NAT behaviour for the whole server: `nat=yes`, `force_rport=yes`,
  `rewrite_contact=yes`, `rtp_symmetric=yes`, `icesupport=yes`. These are the flags
  that make audio work through NAT.
- **Transports** — how SIP is carried:
  - `system-udp` (UDP 5060) — primary, used by the trunk; carries the `local_net`
    and `external_media_address=${PUBLIC_IP}` NAT hints.
  - `tcp_transport` (TCP 5060), `tls_transport` (TLS 5061, uses your cert),
    `wss_transport` (WebRTC over secure WebSocket).
- **The trunk** — five objects that together define the carrier line, all named
  `${SIP_TRUNK_NAME}`:
  - `type=auth` — username/password (`${SIP_SECRET}` injected here).
  - `type=registration` — logs into the carrier's SBC and keeps the line alive.
  - `type=aor` — where to send calls (the SBC contact).
  - two `type=endpoint`s — `_incomming` (inbound, context `incomming`) and
    `_outgoing` (outbound, context `from-extension`), codec `${TRUNK_CODEC}`,
    `direct_media=no` (audio flows through the PBX — required behind NAT).
  - `type=identify` — "any SIP from `${SIP_PROXY_HOST}` is this trunk" (so inbound
    calls are trusted without a password).
- **Endpoint templates** — `basic_endpoint` (desk phones/softphones) and
  `webrtc_endpoint` (browser phones with DTLS-SRTP), plus `single_aor` and
  `userpass_auth` helpers. The generated `user.conf` uses these.
- **`#include ${PROJECTS_DIR}/user.conf`** — pulls in the machine-generated SIP users.

### 6.2 `extensions.conf.template` — the dialplan (call routing)
Only the **live** custom contexts (all real logic is in the PHP AGI apps):
- `[incomming]` — inbound calls from the carrier. Strips a leading `+`, matches your
  `${DID_NUMBER}`, then hands the call to `agi/main.php`.
- `[from-extensions]` — calls made *by* your phones; enables noise reduction, then
  `agi/fromextension.php`.
- `[outgoing]` — outbound campaign calls → `agi/campaign.php`.
- `[ami-action]` — calls launched by the Node AMI app (`Originate`) →
  `stageagi/ami-triggred.php`, with an `h` (hangup) handler for post-call logging.

### 6.3 `rtp.conf.template` — audio ports & NAT media (the one-way-audio file)
- `rtpstart`/`rtpend` — the media port range.
- `media_address`/`external_media_address=${PUBLIC_IP}` — the address Asterisk puts
  in SDP so the far end sends audio to your public IP.
- `[ice_host_candidates] ${LOCAL_IP} => ${PUBLIC_IP}` — maps the private IP to the
  public one for ICE (WebRTC/NAT).
- `strictrtp=no`, `probation=2`, `rtp_keepalive=10` — tolerate NAT port/SSRC flips;
  these are the exact anti-one-way-audio tweaks from the reference server.

### 6.4 `modules.conf.template` — which modules load
`autoload=yes` (load everything) except a few `noload` lines (HEP monitoring and the
IMAP/ODBC voicemail variants). Confirms **chan_pjsip** is the SIP stack (not the old
chan_sip).

### 6.5 `manager.conf.template` — AMI (the control API), hardened
AMI lets external programs run CLI commands and originate calls — very powerful. The
reference box left it open to the world; this template binds it to `${AMI_BIND}`
(loopback by default) and sets `deny=0.0.0.0/0` + `permit=127.0.0.1` so only local
apps connect. There's a commented `permit = ${LOCAL_CIDR}` line to widen it *only if*
you deliberately need remote AMI (and you'd pair that with the firewall admin list).

### 6.6 `logger.conf.template` — logging
Sends `notice,warning,error` to the console and to `messages.log`. Paired with the
`logrotate-asterisk.template` (installed at `/etc/logrotate.d/asterisk`) so the log
can't grow to gigabytes like it did on the reference server.

### 6.7 `logrotate-asterisk.template` — log rotation
Rotates `messages.log`, `queue_log`, and the CDR CSVs weekly (keep 8, compressed),
and runs `asterisk -rx 'logger reload'` after rotation so Asterisk reopens its files.
This is the fix for the missing rotation on the reference box.

### 6.8 `nginx-site.conf.template` — the web/API vhost
Rendered to `/etc/nginx/sites-available/aakashtel`. Document root `${WEB_ROOT}`,
PHP-FPM for `.php` and the `/service` API, and a `/voice/` directory listing for call
recordings. Rendered with a restricted `envsubst` so nginx's own `$uri` etc. are
preserved. certbot later rewrites this file to add the TLS (443) block.

### 6.9 `systemd/*.service.template` — the four companion services
One unit per background app (`ami`, `broadcast`, `sipuser`, `sipqueue-populate`).
The `${NODE_BIN}` (the exact nvm Node path) and `${PROJECTS_DIR}` are injected at
render time by `deploy_app.sh`. `sipuser`/`sipqueue-populate` regenerate the SIP
`user.conf`/`queue_custom.conf` from the backend API; `ami`/`broadcast` drive calls.

---

## 7. The manual step: the application code

The kit builds **Asterisk**, but the actual call-center behaviour lives in the
`/home/projects` apps, which are **not** shipped here (they contain app secrets):

- **PHP AGI** (`/home/projects/agi`, `/home/projects/stageagi`) — `main.php`,
  `campaign.php`, `fromextension.php`, `ami-triggred.php`. The dialplan calls these.
- **Node.js services** (systemd units): `ami` (`listAllEvent.js` — listens to AMI
  events / originates calls), `broadcast` (`broadcast.js` — the outbound dialer),
  `sipuser` (`user.js` — **generates** `user.conf` from the backend API),
  `sipqueue-populate` (`QueueUsers.js` — **generates** `queue_custom.conf`).

The kit now **automates steps 3–4** (`deploy_app.sh` does npm install + installs and
enables the four systemd units). What only *you* can provide is the code + secrets:
1. Copy `/home/projects` from your app repo (`agi/`, `stageagi/`, `ami/`,
   `broadcast/`, `service/`, `voice/`).
2. Fill each app's `.env` (`APP_BACKEND_BASE_URL`, AMI creds, AWS S3 keys).
3. Run `sudo make services` — it does the rest (or prints instructions if the code
   isn't there yet).

That's why `user.conf`/`queue_custom.conf` are `#include`d but empty until the
`sipuser`/`sipqueue-populate` services run — they're generated at runtime.

---

## 8. Full deploy — start to finish

```bash
# 0. Get the kit onto the fresh server; put your app code in /home/projects; then:
cd asterisk-deploy
cp .env.example .env
nano .env          # fill PUBLIC_IP, LOCAL_IP, DOMAIN, SIP_SECRET, AMI_SECRET, CERTBOT_EMAIL…

# 1. Preflight
sudo make check

# 2. Everything, in order:
#    backup -> install -> configure -> webserver -> tls -> services -> firewall -> fail2ban
sudo make deploy

# 3. Start Asterisk and the companion services
sudo systemctl enable --now asterisk
sudo systemctl start ami broadcast sipuser sipqueue-populate

# 4. Prove it
sudo make verify   # expect: trunk Registered, ports listening, nginx+TLS ok, VERIFY: PASS
```

You can also run any single stage, e.g. `sudo make tls` to (re)issue the certificate
or `sudo make webserver` to re-render the nginx site.

**What happens under the hood during `make deploy`:**
1. `backup` tars any existing `/etc/asterisk` to `/var/backups/…`.
2. `install` compiles Asterisk 22.10.0 (using the shipped `menuselect.makeopts` for
   an exact module match) and installs PHP-FPM, nginx, certbot, and Node.
3. `configure` renders the six Asterisk templates into `/etc/asterisk`, installs the
   logrotate rule, fixes ownership, and prepares the `#include` files.
4. `webserver` renders + enables the nginx vhost and php-fpm.
5. `tls` obtains the Let's Encrypt cert and installs the copy-to-asterisk deploy hook.
6. `services` npm-installs and enables the four companion systemd units (if the app
   code is present).
7. `firewall` applies the default-deny nftables ruleset (incl. public 80/443).
8. `fail2ban` installs the SSH + Asterisk ban jails with your ignore-list.

Then you start the daemon + services and verify.

---

## 9. If something breaks — rollback

The backup script printed a command. To undo the config:
```bash
sudo tar -xzf /var/backups/asterisk-config-<timestamp>/etc-asterisk.tar.gz -C /etc
sudo systemctl restart asterisk
```
Firewall: `sudo nft flush ruleset` (then reload your previous rules). fail2ban:
`sudo systemctl disable --now fail2ban`.

---

## 10. Design decisions worth knowing

- **Idempotent by design** — re-running `install`/`configure` is safe; the build is
  skipped if the right version is present, and rendering just overwrites the config.
- **Hardened vs. the original** — AMI and HTTP default to loopback, and the firewall
  is default-deny. The reference box was more open; the kit fixes that on the rebuild
  without changing the live server.
- **Never touches a running PBX** — `configure` does not reload Asterisk; you control
  when the service starts.
- **Secrets stay out of git** — only `.env.example` (placeholders) is committed; add
  a `.gitignore` with `.env` and `*.pem` so real secrets can't be pushed.

---

### One-line summary

> Fill `.env` → `sudo make deploy` compiles Asterisk, renders your config from
> templates, and locks down the firewall → deploy the `/home/projects` apps → `make
> verify` confirms the trunk is registered and audio ports are open.
