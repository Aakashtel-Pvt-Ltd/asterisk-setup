# asterisk-deploy

Rebuild the **Aakashtel** call-center PBX (Asterisk **22.10.0**, source build,
behind NAT) on a **fresh** Ubuntu 24.04 host. Generated from a read-only audit of
the reference server `mth-callcenter` — see `../asterisk_setup_analysis.md`.

> ⚠️ This kit targets a **fresh host only**. It never modifies the reference
> production server. Every secret is a placeholder — fill `.env` yourself.

## What it builds

- Asterisk 22.10.0 compiled from source (exact module set via shipped
  `menuselect.makeopts`), running as `asterisk:asterisk`.
- One **NTC IMS** SIP trunk (register-based, codec `alaw`), NAT/RTP tuned for
  behind-NAT media (`external_media_address`, ICE host candidate, RTP 10000–30000).
- Transports: UDP/TCP 5060, TLS 5061, WSS (WebRTC).
- AMI + ARI + HTTP(S), **hardened to loopback by default**.
- **nginx + PHP-FPM** web/API front-end for `/home/projects` (API + recordings).
- **Let's Encrypt / certbot** TLS with auto-renewal + a hook that copies certs to
  `/home/certs` (asterisk-readable) and reloads TLS without dropping calls.
- **Four companion systemd services** (`ami`, `broadcast`, `sipuser`,
  `sipqueue-populate`) + `npm install`.
- nftables firewall (default-deny, public 80/443) + fail2ban (asterisk + sshd,
  matching the reference jail) + Asterisk logrotate.

## Prerequisites

- Fresh Ubuntu 24.04 (or Debian-like) host, root/sudo.
- Public + private IPs known; NAT device able to forward SIP 5060/5061 and
  UDP 10000–30000 to this host, with **SIP ALG disabled**.
- Fresh NTC trunk credentials and a TLS cert for the new hostname.

## Quick start

```bash
cp .env.example .env
$EDITOR .env                 # PUBLIC_IP, LOCAL_IP, DOMAIN, SIP_SECRET, AMI_SECRET, CERTBOT_EMAIL, ...
# (put your /home/projects app code in place for the 'services' stage)
sudo make check              # preflight
sudo make deploy             # backup->install->configure->webserver->tls->services->firewall->fail2ban
sudo systemctl enable --now asterisk
sudo systemctl start ami broadcast sipuser sipqueue-populate
sudo make verify             # registration + ports + nginx/TLS + logs
```

Run individual stages with `sudo make <target>` (`make help` lists them):
`backup install configure webserver tls services firewall fail2ban verify`.

## Filling `.env`

Every host-specific / secret value lives in `.env` (see inline comments in
`.env.example`). Required before `configure`: `PUBLIC_IP`, `LOCAL_IP`,
`LOCAL_CIDR`, `RTP_START/END`, `SIP_*`, `DID_NUMBER`, `OUTBOUND_CID`,
`AMI_USER/SECRET`, `ARI_USER/SECRET`, `TLS_CERT/KEY`. `configure_asterisk.sh`
refuses to run if `SIP_SECRET` is still `<ASK_USER>`.

## App layer (manual step)

The dialplan calls PHP AGI scripts and the Node services (`ami`, `broadcast`,
`sipuser`, `sipqueue-populate`) regenerate `user.conf` / `queue_custom.conf` from a
backend API. Deploy `/home/projects` from your app repo, set each `.env`
(`APP_BACKEND_BASE_URL`, AMI creds, AWS S3 keys), run `npm install` in `ami/` and
`broadcast/`, and install the systemd units. These are **not** shipped here because
they contain application secrets.

## Recommended extra: log rotation

The reference box had a ~1 GB unrotated `messages.log`. Add:

```
# /etc/logrotate.d/asterisk
/var/log/asterisk/messages.log /var/log/asterisk/queue_log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    postrotate
        /usr/sbin/asterisk -rx 'logger reload' > /dev/null 2>&1 || true
    endscript
}
```

## Rollback

`backup_existing_config.sh` snapshots `/etc/asterisk` to
`/var/backups/asterisk-config-<timestamp>/etc-asterisk.tar.gz` before changes.
Restore with:

```bash
tar -xzf /var/backups/asterisk-config-<timestamp>/etc-asterisk.tar.gz -C /etc
```

## Security notes (apply on the NEW box)

- Keep AMI/HTTP on loopback (defaults here) unless remote access is required;
  if so, widen `permit` **and** the firewall admin allow-list together.
- Rotate all endpoint/AMI/ARI secrets to strong values.
- Confirm the router forwards RTP and disables SIP ALG, or you'll get one-way audio.
