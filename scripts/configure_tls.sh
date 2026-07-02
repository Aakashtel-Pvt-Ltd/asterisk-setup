#!/usr/bin/env bash
# Obtain/renew a Let's Encrypt certificate for ${DOMAIN} via certbot, then install
# a deploy-hook that copies the cert to ${CERT_DEST} (asterisk-readable) and reloads
# Asterisk's TLS. This reproduces the reference server, where Asterisk reads
# /home/certs/* (a copy) because it cannot read the root-only /etc/letsencrypt tree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] || { echo "ERROR: $HERE/.env missing"; exit 1; }
set -a && source "$HERE/.env" && set +a

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

if [[ "${ENABLE_TLS:-yes}" != "yes" ]]; then echo "ENABLE_TLS!=yes — skipping"; exit 0; fi

: "${DOMAIN:?set DOMAIN in .env}"
: "${CERTBOT_EMAIL:?set CERTBOT_EMAIL in .env}"
: "${CERT_DEST:=/home/certs}"
CERT_LIVE_DIR="${CERT_LIVE_DIR:-/etc/letsencrypt/live/$DOMAIN}"
case "$CERTBOT_EMAIL" in *ASK_USER*|"") echo "ERROR: set a real CERTBOT_EMAIL"; exit 1;; esac

command -v certbot >/dev/null || { echo "Installing certbot"; apt-get install -y certbot python3-certbot-nginx; }

# --- 1. Install the deploy hook FIRST so it runs on issuance and every renewal ---
mkdir -p /etc/letsencrypt/renewal-hooks/deploy "$CERT_DEST"
cat > /etc/letsencrypt/renewal-hooks/deploy/copy-to-asterisk.sh <<EOF
#!/usr/bin/env bash
# Auto-installed by asterisk-deploy. Copies renewed certs to ${CERT_DEST} for
# Asterisk (which runs as 'asterisk' and can't read /etc/letsencrypt), then
# reloads Asterisk's TLS without dropping calls.
set -euo pipefail
SRC="${CERT_LIVE_DIR}"
DEST="${CERT_DEST}"
install -o asterisk -g asterisk -m 0644 "\$SRC/fullchain.pem" "\$DEST/fullchain.pem"
install -o asterisk -g asterisk -m 0644 "\$SRC/cert.pem"      "\$DEST/cert.pem"      2>/dev/null || true
install -o asterisk -g asterisk -m 0644 "\$SRC/chain.pem"     "\$DEST/chain.pem"     2>/dev/null || true
install -o asterisk -g asterisk -m 0640 "\$SRC/privkey.pem"   "\$DEST/privkey.pem"
# Reload TLS transports + HTTP (safe; does not drop active calls)
/usr/sbin/asterisk -rx 'module reload res_pjsip.so' >/dev/null 2>&1 || true
/usr/sbin/asterisk -rx 'module reload res_http_websocket.so' >/dev/null 2>&1 || true
systemctl reload nginx >/dev/null 2>&1 || true
EOF
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/copy-to-asterisk.sh

# --- 2. Obtain the certificate (nginx plugin does HTTP-01 + rewrites the vhost) --
if [[ -d "$CERT_LIVE_DIR" ]]; then
  echo "==> Certificate for $DOMAIN already exists — running renew (deploy hook will copy)"
  certbot renew --deploy-hook /etc/letsencrypt/renewal-hooks/deploy/copy-to-asterisk.sh || true
else
  echo "==> Requesting new certificate for $DOMAIN"
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$CERTBOT_EMAIL" --redirect
fi

# --- 3. Run the copy once now so /home/certs is populated immediately ------------
bash /etc/letsencrypt/renewal-hooks/deploy/copy-to-asterisk.sh || {
  echo "WARN: initial cert copy failed — check that $CERT_LIVE_DIR exists"; }

# certbot.timer handles auto-renewal (installed with the package)
systemctl enable certbot.timer 2>/dev/null || true

echo "==> TLS ready. Asterisk reads ${CERT_DEST}/fullchain.pem + privkey.pem."
echo "    Auto-renewal: certbot.timer -> deploy hook copies + reloads."
