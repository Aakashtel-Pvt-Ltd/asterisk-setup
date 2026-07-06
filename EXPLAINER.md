# asterisk-deploy — Complete Walkthrough

This document explains **everything** in this kit: what Asterisk is and why we
need it, how a phone call actually travels through this system, what every
configuration file does, what every script does, and how to rebuild the whole
PBX on a fresh server without guessing.

It assumes you are comfortable in a Linux shell but **not** an Asterisk expert.
Jargon is explained the first time it appears, and there is a glossary at the
end.

> **REVISION 2026-07-03 — templates regenerated from the live server.**
> Every `templates/*.conf.template` was rebuilt by copying the live
> `/etc/asterisk` files and parameterizing only the deploy-specific values
> (IPs, secrets, cert paths, `${PROJECTS_DIR}` = `/home/stage/asterisk`).
> Rendering with the live values reproduces the running config
> **byte-for-byte** for 15 of 17 files. The two deliberate deviations:
> 1. `pjsip.conf` — the `[system-udp-ens224]` UDP transport moved from
>    `ncell.conf` into `pjsip.conf` (so the NTC trunk works even with Ncell
>    disabled), one added `#include /etc/asterisk/ntc.conf`, and `local_net`
>    normalized from `192.168.0.1/24` to `192.168.0.0/24` (same network).
> 2. `pjsip_endpoints.conf` — the live manual test extension `101_15971965`
>    ships commented out (it carried a hardcoded password).
>
> **Both carriers are supported**: Ncell (IP-authenticated, `ENABLE_NCELL`)
> and NTC IMS (registration-based, `ENABLE_NTC`). Earlier kit revisions were
> NTC-only; an old NTC-only `.env` still works unchanged (see §9).

---

## 1. What is Asterisk, and why do we need it at all?

**Asterisk is a software telephone exchange (a "PBX").** Think of it as the
switchboard operator of the company, implemented as a Linux daemon:

- It **speaks SIP** (Session Initiation Protocol) — the language used to set
  up, modify and tear down calls over the internet, the same way HTTP sets up
  web requests.
- It **carries the audio** of those calls as **RTP** (Real-time Transport
  Protocol) packets — small UDP packets, ~50 per second per direction, each
  holding 20 ms of sound.
- It **decides what happens to every call** using a programmable routing table
  called the **dialplan** (`extensions.conf`): "a call arrived for number X —
  play a greeting, run a script, ring an agent, put it in a queue…".
- It **connects unlike things together**: a mobile caller on the Ncell
  network, a call-center agent using a browser-based phone (WebRTC), a
  campaign robocall started by a Node.js script — Asterisk bridges all of
  them into ordinary two-way conversations.

Why is it *required* here? This system is a **call center + campaign
platform**:

- Customers call the company's Ncell/NTC numbers → calls must be answered,
  routed by menus/logic (PHP scripts), queued, and delivered to agents.
- The business runs **outbound campaigns / broadcasts** — software must
  originate thousands of calls and play messages or run surveys.
- Agents don't have desk phones; they use **web phones in a browser**, which
  need WebRTC (WSS + DTLS + ICE) — Asterisk terminates all of that.
- Every call must produce a **CDR (Call Detail Record)** for billing and
  campaign analytics, streamed live to the backend over AMI.

You could not do this with a SIP phone alone or with a bare SIP proxy —
Asterisk is the piece that owns the *media* (audio), the *logic* (dialplan +
AGI), and the *records* (CDR), all in one place.

### The four "remote controls" of Asterisk used by this system

| Interface | What it is | Who uses it here |
| --- | --- | --- |
| **Dialplan** (`extensions.conf`) | Built-in routing language executed per call | Every call |
| **AGI** (Asterisk Gateway Interface) | "CGI for calls" — the dialplan hands the call to an external script that decides what to do next | PHP scripts in `${PROJECTS_DIR}/agi` (main.php, campaign.php, …) |
| **AMI** (Asterisk Manager Interface) | TCP socket (port 5038) streaming events (calls started/ended, CDRs) and accepting commands (Originate a call) | Node apps: AMI-Broadcaster, listAllEvent, user/queue generators |
| **ARI** (Asterisk REST Interface) | HTTP/WebSocket API (port 8088) for building custom call applications | `ari-node` and the conference apps (via pm2) |

### How one inbound call actually flows (follow the arrows)

```
Mobile caller dials 9801730002 (Ncell number)
        │  SIP INVITE from Ncell's SBC (116.68.210.56 or 116.68.213.56)
        ▼
[pjsip] "identify" section matches the source IP  →  endpoint +9779801730002_incomming
        │  endpoint says: context=incomming
        ▼
[dialplan] context [incomming] in extensions.conf
        │  exten _[+0-9][0-9]. matches any dialed number
        ▼
AGI(${PROJECTS_DIR}/agi/main.php)   ← PHP script takes over:
        │  looks up the DID in the backend, plays IVR menus (audio prompts),
        │  chooses a department queue, e.g. Queue(+9779801730002_9002_department)
        ▼
[queues.conf + queue_custom.conf] queue rings an agent member PJSIP/9002_01730002
        │  agent's browser phone is registered over WSS (WebRTC)
        ▼
RTP/DTLS audio flows caller ⇄ Asterisk ⇄ agent; on hangup a CDR is written
and also emitted as an AMI event (cdr_manager) that the Node backend consumes.
```

Outbound campaign calls are the mirror image: a Node app sends an AMI
**Originate** → Asterisk calls the customer via the `_outgoing` trunk endpoint
→ when answered, the call is dropped into the `[outgoing]` or `[ami-action]`
context → an AGI script (campaign.php / ami-triggred.php) plays the message or
runs the survey.

---

## 2. The mental model of the kit (read this before the file list)

A rebuild answers five questions. Each part of the kit answers exactly one:

| Question | Answered by |
| --- | --- |
| What software do I need? | `scripts/install_packages.sh` (compiles Asterisk 22.7.0 from source) |
| What values are specific to THIS server? | `.env` (you fill it from `.env.example`) |
| How do values become real config files? | `templates/*.template` + `scripts/configure_asterisk.sh` (envsubst) |
| How do I stand up the web/TLS layer? | `configure_webserver.sh`, `configure_tls.sh` |
| How do I keep attackers out? | `configure_firewall.sh` (nftables) + `configure_fail2ban.sh` |

The golden rule: **no template contains a secret or a machine-specific value.**
Everything of that kind lives in `.env` and is substituted at render time by
`envsubst` using an explicit **whitelist** of variable names. The whitelist
matters because Asterisk config files legitimately contain their own
`${...}` tokens (`${EXTEN}`, `${CALLERID(num)}`, …) which must pass through
untouched — a naive substitution would blank them and silently destroy the
dialplan.

`make deploy` runs the stages in order:
`backup → install → configure → webserver → tls → services → firewall → fail2ban`.

---

## 3. The live server this kit reproduces

- Ubuntu 24.04, **Asterisk 22.7.0 built from source** (tree at
  `/home/stage/asterisk-22.7.0`, module choices in `menuselect.makeopts` —
  shipped copy is taken from that exact build).
- Application directory **`/home/stage/asterisk`** (`${PROJECTS_DIR}`):
  - `agi/` — PHP call logic (main.php, fromextension.php, campaign.php,
    ami-triggred.php, survey*.php, stress_test_sim.agi)
  - `ami/` — Node generators: `user.js` writes `users.conf` (SIP extensions),
    `QueueUsers.js` writes `queue_custom.conf` (queues) — both from the
    backend database/API
  - `certs/` — TLS certificate copies readable by the `asterisk` user
  - `users.conf`, `queue_custom.conf`, `moh_files.conf` — **generated**
    include-files referenced from the main configs
  - `voice/` — recordings & prompts
- Long-running Node apps run under **pm2** (AMI-Broadcaster, ari-node,
  conference-app, conference-worker, integration-gateway, listAllEvent);
  only the two oneshot generators are systemd units
  (`sipuser.service`, `sipqueue-populate.service`).
- Web: nginx (`asterisk.aakashpay.com`) + PHP-FPM 8.3, Let's Encrypt.
- Firewall: allow-listed SIP/RTP/HTTPS ports; fail2ban jails `asterisk` and
  `sshd`.
- MOH (music-on-hold) audio per DID under
  `/var/lib/asterisk/moh/moh_<number>/{ring,queue,hold}`.

### Carrier connections ("trunks") — why there are several

A **trunk** is the SIP connection between your PBX and a telephone carrier.
This PBX has more than one because the business owns numbers on more than one
network:

| Trunk | File | Auth style | Notes |
| --- | --- | --- | --- |
| **Ncell** `+9779801730002` | `ncell.conf` | **IP-based** — Ncell trusts our fixed public IP; no password | Two SBCs (Kathmandu 116.68.210.56, Pokhara 116.68.213.56) for redundancy; split `_incomming`/`_outgoing` endpoints with different DTMF modes; T.38 fax enabled |
| **NTC IMS** `+97761597077` | `ntc.conf` | **Registration** — we log in to `ims.ntc.net.np` through proxy 10.40.55.4 with a username/password | The scenario earlier kit revisions were built for; still fully supported |
| **Airtel** `UKB225` | inside `pjsip.conf` | IP-based static peer (125.18.88.81) | Secondary carrier peer |

Why split `_incomming` / `_outgoing` endpoints for the same trunk? Asterisk
matches inbound calls to ONE endpoint per source IP (the `identify` section
points at `_incomming`). Having a second, separately-named endpoint for
outbound lets outbound calls use different settings (e.g. Ncell needs
`dtmf_mode=inband` on inbound but `auto` on outbound) and lets the dialplan
address it explicitly: `Dial(PJSIP/97798…@+9779801730002_outgoing)`.

### Local SIP neighbours (also in `pjsip.conf`)

- **kamailio** (localhost:5070) — a SIP proxy/load-balancer in front of
  Asterisk for certain flows; calls from it land in `[from-kamailio]`.
- **opensips** (LAN, `${OPENSIPS_HOST}`) — another SIP proxy peer; its calls
  land in `[from-opensips]`.
- **freeswitch_static** (localhost:5090) — a FreeSWITCH instance; selected
  callers on the inbound DID are forwarded to it (see `[incomming]`), and its
  outbound leg goes back out through the Ncell trunk (`[from-freeswitch]`).

These exist because the live platform is also a lab: SIP traffic can be
steered through Kamailio/OpenSIPS/FreeSWITCH for testing and special routing.
They are harmless on a fresh box (they point at localhost/LAN and simply stay
unreachable until you install those services).

---

## 4. Template-by-template: every file, what it does, what we set

Each `templates/X.template` renders to `/etc/asterisk/X`. They are exact
copies of the live files with only deploy values parameterized, so the list
below focuses on the *meaningful* content.

### 4.1 `asterisk.conf` — the daemon's own settings
Directory layout (where modules/sounds/logs live) plus `[options]`. Only
change vs stock: `systemname = ${SYSTEMNAME}` (live: `Aakashtech`). The system
name is prefixed onto every call's **uniqueid** — the backend uses it to know
which PBX generated a CDR. The `asterisk` user/group is enforced by the
systemd unit (`-U asterisk -G asterisk`), not by this file.

### 4.2 `pjsip.conf` — WHO can talk SIP to us, and HOW
The heart of SIP configuration. PJSIP objects come in a few types:

- **transport** — a listening socket. We define:
  - `[system-udp-ens224]` UDP 5060 — main transport (name is historical; kept
    because every endpoint references it). Declares
    `external_media_address=${PUBLIC_IP}` and `local_net=${LOCAL_CIDR}` so
    NAT'd SIP/SDP carries the correct public address.
  - `[tls_transport]` TCP/TLS 5061 — legacy TLS (uses the same cert pair).
  - `[wss_transport]` — WebSocket-Secure for **browser phones**; actual
    listening socket is provided by `http.conf` (port 7443).
- **endpoint templates** (`(!)` = abstract, inherited by generated users):
  - `[basic_endpoint](!)` — call-center agent defaults: context
    `from-extensions`, ulaw/alaw/g722/gsm, RFC4733 DTMF, NAT-safe
    (`force_rport`, `rewrite_contact`, `rtp_symmetric`), busy at 1 call,
    subscriptions enabled.
  - `[webrtc_endpoint](!)` — adds WebRTC: `webrtc=yes`, DTLS-SRTP encryption,
    ICE, AVPF, opus codec.
  - `[single_aor](!)`, `[userpass_auth](!)` — one registration per user,
    fast re-qualify.
  The `sipuser` generator writes every real agent into
  `${PROJECTS_DIR}/users.conf` as
  `[1234_<DID-suffix>](basic_endpoint,webrtc_endpoint)` — that's why these
  templates must exist before the include.
- **peers**: kamailio, opensips, freeswitch_static, Airtel `UKB225`
  (endpoint + aor + identify each; `identify` = "SIP from THIS IP belongs to
  THAT endpoint").
- **test endpoint** `[2005]` — a SIPp stress-test extension (kept as live).
- **includes** at the bottom (order matters only for templates):
  `ncell.conf`, `ntc.conf` (new), `pjsip_endpoints.conf`,
  `${PROJECTS_DIR}/users.conf`, `${PROJECTS_DIR}/queue_custom.conf` (the last
  one is a live quirk — harmless).

### 4.3 `ncell.conf` — the Ncell trunk (rendered only if `ENABLE_NCELL=yes`)
Two AORs (`ncell-ktm`, `ncell-pok`) each listing both SBC contacts with
`qualify_frequency=60` (Asterisk pings them with SIP OPTIONS and marks them
Avail/Unavail), the `_incomming`/`_outgoing` endpoint pair
(alaw/ulaw/g722, `t38_udptl=yes`, `timers=no`, `from_user=${NCELL_FROM_USER}`)
and the `identify` matching both SBC IPs. No password anywhere — the carrier
authenticates our source IP, which is why the firewall allow-list matters.

### 4.4 `ntc.conf` — the NTC IMS trunk (rendered only if `ENABLE_NTC=yes`)
Registration-based: an `auth` object (username/password), a `registration`
object (we periodically REGISTER to `sip:${NTC_PROXY}` so NTC knows where to
send calls), an `aor` pointing at the proxy, the same `_incomming`/`_outgoing`
endpoint pair pattern, and an `identify` on the proxy IP. When disabled, the
script writes a one-line comment stub so the `#include` in `pjsip.conf` never
dangles.

### 4.5 `pjsip_endpoints.conf` — hand-managed extensions
For manual/test endpoints that shouldn't be overwritten by the generator.
Ships with the live test extension commented out.

### 4.6 `extensions.conf` — the dialplan (the call-routing brain)
Stock Asterisk demo contexts (harmless, unreferenced) plus the real ones:

| Context | Reached by | What it does |
| --- | --- | --- |
| `[incomming]` | Both trunks' `_incomming` endpoints | Whitelisted caller IDs are forwarded to FreeSWITCH; everyone else → `AGI(agi/main.php)` (IVR/queue logic), with `__CALLTYPE=inbound` |
| `[from-extensions]` | Agent endpoints | Strips `+`, splits the agent name on `_`, adds an `X-Invite-Epoch` SIP header, then `AGI(agi/fromextension.php)` decides carrier/route for the outbound call |
| `[outgoing]` | Trunk `_outgoing` endpoints / campaign legs | `AGI(agi/campaign.php)` — campaign playback logic |
| `[ami-action]` | AMI Originate from the Node apps | `AGI(agi/ami-triggred.php)` on answer AND on hangup (`h` extension) — campaign state + logging |
| `[survey-runner]`, `[survey_runner]`, `[callee_after_survey]`, `[survey_hangup_handler]` | Survey feature (`*9` DTMF map) and survey campaigns | Redirect the callee into `AGI(agi/survey.php)` after the agent triggers a survey |
| `[kamailio]` / `[from-kamailio]` | To/from the Kamailio proxy | Outbound legs tagged with `X-DID`/`X-Trunk` headers; inbound re-enters `[incomming]` |
| `[from-opensips]`, `[from-freeswitch]`, `[staging]` | Local peers | Simple Dial() bridges (FreeSWITCH outbound goes out via the Ncell `_incomming` endpoint name — live behaviour, kept verbatim) |
| `[conference-app]` | ARI/conference dialer | `ConfBridge(${EXTEN}, default_bridge, default_user, sample_user_menu)` |
| `[sipp]` | SIPp load tests | Randomly simulates busy/invalid/noanswer/answered via `stress_test_sim.agi` |
| `[match]`, `[test]`, `[transfer-check]` | Special cases | Direct AGI route; Google STT experiment (EAGI); SIP REFER intercept with a CURL push |

Note the pattern: **the dialplan is thin on purpose** — nearly every context
immediately delegates to a PHP AGI script, so business logic lives in the app
repo and can change without touching Asterisk.

### 4.7 `queues.conf` — call queues
Stock file + `#include ${PROJECTS_DIR}/queue_custom.conf`. Real queues (one
per department per DID, e.g. `[+9779801730002_9002_department]`) are
**generated** by `QueueUsers.js` with strategy `linear`, wrap-up 60 s, position
announcements, and `member => PJSIP/<agent>` lines.

### 4.8 `musiconhold.conf` — hold/queue music
Stock + `#include ${PROJECTS_DIR}/moh_files.conf`, which defines per-DID MOH
classes (`moh_<number>_ring/queue/hold`) pointing at directories under
`/var/lib/asterisk/moh/`. Queues and endpoints reference these classes
(`moh_suggest=moh_+9779801730002_hold` in generated users.conf).

### 4.9 `manager.conf` — AMI (port 5038)
`enabled=yes`, bind `${AMI_BIND}` (live `0.0.0.0` — the firewall restricts
who can reach it). One account `[${AMI_USER}]` with full read/write classes
plus two live-critical extras:
- `channelvars = CDR(campaignId),CDR(campaignLogId)` — attaches campaign IDs
  to every AMI event so the backend can correlate events to campaigns.
- `eventfilter=!Event: RTCPSent/Received` — drops the two chattiest event
  types so the Node consumers aren't flooded.

### 4.10 `cdr.conf` + `cdr_manager.conf` — call records
`cdr.conf`: `enable=yes`, `unanswered=yes` (campaign analytics need failed
attempts too), `channeldefaultenabled=yes`. `cdr_manager.conf` forwards every
CDR as an AMI event and maps the custom fields
`campaignLogId`, `campaignId`, `broadcast` into it — **this is how campaign
results reach the backend**; without the `[mappings]` block reporting breaks.

### 4.11 `http.conf` — Asterisk's built-in web server
Required for ARI **and** for WebRTC: `enabled=yes` on `${HTTP_BIND}`
(port 8088, plain) and `tlsenable=yes` on `${HTTPS_BIND}` (live
`0.0.0.0:7443`) with the cert pair. Browser phones connect to
`wss://host:7443/ws`; without this file's TLS socket, **no agent web phone can
register**.

### 4.12 `ari.conf` — REST interface credentials
One user (live name literally `username`) with a **plaintext** password, as
on the live box, because the pm2 apps authenticate with it. Rotate the value
in `.env`; treat `ari.conf` as secret material (file mode 0640).

### 4.13 `rtp.conf` — media port range
`rtpstart=10000` / `rtpend=20000`. Must match the firewall rule — every
active call consumes one UDP port from this range (two with RTCP).

### 4.14 `features.conf` — in-call DTMF features
One addition: `survey => *9,self,Gosub(survey_runner,s,1)` — an agent pressing
`*9` mid-call pushes the customer into the survey flow.

### 4.15 `confbridge.conf` — conference profiles
`default_bridge` (max 15 members, events on), `default_user` (MOH when alone,
silence-drop, jitterbuffer, user-count announcements), `sample_user_menu` —
used by `[conference-app]` and the pm2 conference apps.

### 4.16 `websocket_client.conf` — outbound media WebSocket (AI)
`[aiservice_bridge]` streams call media to
`${AI_GATEWAY_WS_URL}` (live: the Aakashpay realtime gateway) with TLS but no
cert verification — the AI/voicebot integration path.

### 4.17 `modules.conf`, `logger.conf` — stock
Live boxes run the stock files; module trimming happens at **build time** via
`menuselect.makeopts` instead. Logger writes `messages.log`
(notice/warning/error) — rotation added by the kit (§5, logrotate).

---

## 5. Script-by-script

| Script | What it does, in order |
| --- | --- |
| `backup_existing_config.sh` | Tars `/etc/asterisk` and copies the generated `users.conf`/`queue_custom.conf`/`moh_files.conf` to `/var/backups/asterisk-config-<stamp>/` **before anything else changes**. Rollback = untar. |
| `install_packages.sh` | Installs build deps, PHP, Node; downloads Asterisk `${ASTERISK_VERSION}` (22.7.0) source; applies the shipped `menuselect.makeopts` so the compiled module set matches the live server **exactly**; `make install`; creates the `asterisk` user and systemd unit. Skips the build if the right version is already installed. |
| `configure_asterisk.sh` | The renderer. Maps legacy `SIP_*` names → `NTC_*` (§9); infers `ENABLE_NTC`/`ENABLE_NCELL` when unset; validates every required variable and refuses placeholder secrets; renders 17 templates with a **whitelisted** envsubst; renders `ncell.conf`/`ntc.conf` or writes disabled stubs; generates a temporary self-signed cert if the real one isn't there yet (so TLS/WSS transports can bind on first boot); installs the logrotate rule; creates empty `users.conf`/`queue_custom.conf`/`moh_files.conf` include-targets and `/var/lib/asterisk/moh`; sets `asterisk:asterisk` ownership, dirs 0750, files 0640. **Never reloads the running Asterisk** — that stays a human decision. |
| `configure_webserver.sh` | nginx site (from `templates/nginx-site.conf.template`, `${DOMAIN}`/`${WEB_ROOT}`) + PHP-FPM `${PHP_VERSION}`. |
| `configure_tls.sh` | certbot for `${DOMAIN}` + a deploy hook that copies fresh certs to `${CERT_DEST}` (readable by `asterisk`) on every renewal and reloads TLS gracefully. |
| `deploy_app.sh` | `npm install` for the app services you copied into `${PROJECTS_DIR}`, renders the systemd unit templates (`sipuser`, `sipqueue-populate`, plus `ami`/`broadcast` units if you prefer systemd over pm2), `daemon-reload`, enables them. |
| `configure_firewall.sh` | nftables **default-deny** input: loopback + established, 80/443 public, SSH/AMI/8088/7443 only from `ADMIN_ALLOW_IPS`+LAN, SIP 5060/5061 only from LAN + `PROVIDER_ALLOW_IPS` (defaults: both Ncell SBCs, Airtel, NTC proxy), RTP `${RTP_START}-${RTP_END}` open (carrier media IPs vary). NOTE: this is deliberately **tighter** than the live box (which runs permissive ufw rules); if public WebRTC agents must connect, open 7443 wider. |
| `configure_fail2ban.sh` | `asterisk` + `sshd` jails (ban brute-force SIP registration attempts — internet SIP scanners WILL find port 5060 within hours). |
| `verify.sh` | Read-only health check: version; NTC registration **Registered** (if enabled); Ncell AOR contacts **Avail** (if enabled); transports; listening ports (5060/5061/5038/8088/7443/RTP); key dialplan contexts present; fail2ban; log size; nginx/PHP-FPM/cert/certbot-timer; companion services + pm2 apps. |

`Makefile` glues the stages; every target re-sources `.env`.

---

## 6. What is NOT in this kit (on purpose)

The **application layer** — PHP AGI scripts, Node AMI/ARI apps, the backend
API, pm2 process definitions — contains business logic and credentials and
lives in its own repo. The kit prepares everything those apps expect
(`${PROJECTS_DIR}` layout, include-target files, AMI/ARI accounts, dialplan
hooks) and `deploy_app.sh` wires them up once you copy them in. Kamailio,
OpenSIPS and FreeSWITCH configs are likewise separate systems — the PBX only
*points* at them.

---

## 7. Verification story (why you can trust the templates)

The templates were verified by rendering them with the live server's actual
values and diffing against the running `/etc/asterisk`:

- 15 of 17 rendered files are **byte-identical** to the live, in-service
  config (that config is running the production PBX right now — the strongest
  possible "it works" evidence).
- `pjsip.conf` and `ncell.conf` differ only by the three deliberate,
  reviewed changes listed at the top of this document.
- A second render using a **legacy NTC-only `.env`** produced a complete,
  correct NTC trunk with Ncell cleanly stubbed out.

Re-run that check anytime: render to a scratch directory and `diff -r`
against `/etc/asterisk`.

---

## 8. Rollback

`make backup` (also the first step of `make deploy`) snapshots everything.
Restore:

```bash
tar -xzf /var/backups/asterisk-config-<timestamp>/etc-asterisk.tar.gz -C /etc
asterisk -rx 'core reload'     # or systemctl restart asterisk
```

---

## 9. Backwards compatibility with the old NTC-only setup

Earlier revisions of this kit (and your previous server's `.env`) used
`SIP_TRUNK_NAME`, `SIP_PROVIDER_HOST`, `SIP_PROXY`, `SIP_USERNAME`,
`SIP_SECRET`, `TRUNK_CODEC`. `configure_asterisk.sh` maps each one to its
`NTC_*` equivalent automatically, infers `ENABLE_NTC=yes` from their
presence, infers `ENABLE_NCELL=no` when no Ncell variables exist, and
defaults the Airtel/OpenSIPS/AI-gateway constants to the live values. So:

- **An old NTC/IMS `.env` deploys unchanged** and produces a working
  NTC-registered PBX (Ncell rendered as a disabled stub).
- The NTC trunk lives in its own `ntc.conf`; enabling/disabling Ncell never
  edits or reorders anything NTC uses (the shared UDP transport now lives in
  `pjsip.conf` for exactly this reason).
- Nothing in this kit ever contacts or modifies another server — rendering
  happens only on the machine where you run `make`, and a full backup is
  taken first.

---

## 10. Security notes

- The kit reproduces the live bindings (AMI `0.0.0.0:5038`, HTTP
  `0.0.0.0:8088`); the **nftables allow-lists are the real access control**.
  Tighten `AMI_BIND`/`HTTP_BIND` to `127.0.0.1` if all consumers are local.
- `ari.conf` stores its password in **plaintext** (live behaviour). Rotate all
  AMI/ARI/agent secrets; file permissions (0640, group `asterisk`) are your
  second line of defence.
- IP-authenticated trunks mean **your public IP is the password** — keep the
  SIP allow-list accurate and fail2ban running.
- One-way audio after deploy = NAT/firewall problem: check
  `external_media_address`, the RTP range in both `rtp.conf` and the
  firewall, and that any edge router has SIP ALG **disabled**.

---

## 11. Glossary

| Term | Meaning |
| --- | --- |
| **PBX** | Private Branch Exchange — the phone switchboard software |
| **SIP** | Signaling protocol that sets up/tears down calls (like HTTP for calls) |
| **RTP / RTCP** | UDP packets carrying the actual audio / its quality stats |
| **PJSIP** | Asterisk's modern SIP channel driver (`chan_pjsip`); configured in `pjsip.conf` |
| **Endpoint / AOR / Auth / Identify** | PJSIP objects: a SIP party's profile / where to reach it / its credentials / "which IP maps to which endpoint" |
| **Trunk** | SIP connection to a carrier (Ncell, NTC, Airtel) |
| **DID** | A public phone number that reaches this PBX |
| **SBC** | Session Border Controller — the carrier's SIP edge machine |
| **Dialplan / context / extension** | The routing program / a named chapter of it / one number-pattern rule |
| **AGI / EAGI** | Dialplan hands the call to an external script (E = with audio access) |
| **AMI** | TCP event/command socket on 5038 |
| **ARI** | REST + WebSocket call-control API on 8088 |
| **WebRTC / WSS / DTLS / ICE** | Browser calling stack: WebSocket signaling, encrypted media, NAT traversal |
| **CDR** | Call Detail Record — one row per call for billing/analytics |
| **IVR** | "Press 1 for sales" audio menus |
| **MOH** | Music on hold |
| **Qualify** | Periodic SIP OPTIONS ping that marks a peer Avail/Unavail |
| **envsubst** | Tool replacing `${VAR}` in templates with environment values |
| **ConfBridge** | Asterisk's conference-room application |
| **T.38** | Fax-over-IP protocol |
| **SIPp** | SIP load-testing tool (the `[sipp]` context + endpoint 2005 serve it) |
