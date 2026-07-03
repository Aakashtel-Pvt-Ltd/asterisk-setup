# asterisk-deploy

Rebuild the **Aakashtech** call-center PBX (Asterisk **22.7.0**, source build)
on a **fresh** Ubuntu 24.04 host. Templates were **regenerated 2026-07 directly
from the live server's `/etc/asterisk`** — a render with the live values is
byte-identical to the running config (see `EXPLAINER.md` for the two deliberate
exceptions).

> ⚠️ This kit targets a **fresh host only**. It never modifies the live
> production server. Every secret is a placeholder — fill `.env` yourself.

## What it builds

- Asterisk 22.7.0 compiled from source (exact module set via shipped
  `menuselect.makeopts`, copied from the live build tree), running as
  `asterisk:asterisk`.
- **Two carrier trunks, both supported and independently toggled in `.env`:**
  - **Ncell** (`ENABLE_NCELL`, default yes): IP-authenticated, dual SBC
    (KTM 116.68.210.56 / POK 116.68.213.56), split
    `_incomming`/`_outgoing` endpoints, T.38, `dtmf_mode` per direction —
    rendered to `ncell.conf`.
  - **NTC IMS** (`ENABLE_NTC`): registration-based (`ims.ntc.net.np`),
    codec `alaw` — rendered to `ntc.conf`. Earlier deployments were
    NTC-only; both files are always `#include`d from `pjsip.conf` (a disabled
    trunk renders as a comment-only stub).
- **Airtel** static IP peer (`UKB225`) + local **Kamailio / OpenSIPS /
  FreeSWITCH** peers and their dialplan contexts, exactly as live.
- Transports: shared UDP (`system-udp-ens224`), TLS 5061, WSS (WebRTC);
  HTTP 8088 + HTTPS/WSS on **7443**.
- AMI (`stage-ami`, with CDR `channelvars` + RTCP event filters the Node apps
  rely on), ARI, `cdr_manager` with the `campaignId`/`campaignLogId`/`broadcast`
  mappings, ConfBridge profiles, survey feature map (`*9`), AI media gateway
  (`websocket_client.conf`).
- **nginx + PHP-FPM** front-end, **Let's Encrypt / certbot** with a hook that
  copies certs to `${PROJECTS_DIR}/certs` (asterisk-readable).
- Companion systemd oneshots **`sipuser`** (generates `users.conf`) and
  **`sipqueue-populate`** (generates `queue_custom.conf`). The long-running
  Node apps (AMI-Broadcaster, ari-node, conference-app, …) run under **pm2**
  on the live box — deploy them from your app repo.
- nftables firewall (default-deny; RTP 10000–20000 matches `rtp.conf`),
  fail2ban (asterisk + sshd), Asterisk logrotate (live box's `messages.log`
  once hit ~1 GB unrotated).

## Quick start

```bash
cp .env.example .env
$EDITOR .env                 # PUBLIC_IP, LOCAL_CIDR, trunk toggles/secrets, AMI/ARI secrets, DOMAIN, ...
# (put your app code in ${PROJECTS_DIR} — default /home/stage/asterisk — for the 'services' stage)
sudo make check              # preflight
sudo make deploy             # backup->install->configure->webserver->tls->services->firewall->fail2ban
sudo systemctl enable --now asterisk
sudo systemctl start sipuser sipqueue-populate    # oneshot config generators
sudo make verify             # trunk status + ports + contexts + nginx/TLS + logs
```

Run individual stages with `sudo make <target>` (`make help` lists them).

## Filling `.env`

Every host-specific / secret value lives in `.env` (see inline comments in
`.env.example`). `configure_asterisk.sh` validates the variable set for
whichever trunks you enable and refuses to run while any secret is still
`<ASK_USER>`. Trunk numbers (`NCELL_TRUNK_NAME` / `NTC_TRUNK_NAME`) double as
the PJSIP section names — the AGI/AMI apps address endpoints as
`<number>_incomming` / `<number>_outgoing`.

**Backwards compatible:** a `.env` written for the earlier NTC-only kit keeps
working — the legacy names (`SIP_TRUNK_NAME`, `SIP_PROVIDER_HOST`, `SIP_PROXY`,
`SIP_USERNAME`, `SIP_SECRET`, `TRUNK_CODEC`) are mapped to their `NTC_*`
equivalents automatically, `ENABLE_NTC`/`ENABLE_NCELL` are inferred from which
trunk variables are present, and the Airtel/OpenSIPS/AI-gateway constants
default to the live server's values.

## App layer (manual step)

The dialplan calls PHP AGI scripts in `${PROJECTS_DIR}/agi` (main.php,
fromextension.php, campaign.php, ami-triggred.php, survey*.php) and the
generated includes `users.conf` / `queue_custom.conf` / `moh_files.conf` come
from the Node apps in `${PROJECTS_DIR}/ami`. Deploy those from your app repo,
set `APP_BACKEND_BASE_URL` + AMI creds, `npm install`, then
`make services`. MOH audio lives under `/var/lib/asterisk/moh/moh_<number>/…`.

## Rollback

`backup_existing_config.sh` snapshots `/etc/asterisk` (plus the generated
`users.conf` / `queue_custom.conf` / `moh_files.conf`) to
`/var/backups/asterisk-config-<timestamp>/` before changes. Restore with:

```bash
tar -xzf /var/backups/asterisk-config-<timestamp>/etc-asterisk.tar.gz -C /etc
```

## Security notes (apply on the NEW box)

- The kit reproduces the live bindings (`AMI 0.0.0.0:5038`, HTTP `0.0.0.0:8088`)
  — the nftables allow-lists are what actually restrict access. Tighten
  `AMI_BIND`/`HTTP_BIND` to `127.0.0.1` if the consumers are local.
- ARI password is stored **plaintext** in `ari.conf` (as live). Rotate all
  AMI/ARI/endpoint secrets to strong values.
- Confirm the edge forwards RTP 10000–20000/udp and disables SIP ALG, or
  you'll get one-way audio.
