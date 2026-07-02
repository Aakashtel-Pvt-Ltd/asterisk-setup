#!/usr/bin/env bash
# Install the nginx + PHP-FPM web/API front-end that serves ${WEB_ROOT}
# (the /home/projects app: PHP API under /service, recordings under /voice).
# Mirrors the reference server's nginx site. TLS is added separately by
# configure_tls.sh (certbot rewrites this site to add the 443 block).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] || { echo "ERROR: $HERE/.env missing"; exit 1; }
set -a && source "$HERE/.env" && set +a

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

if [[ "${ENABLE_NGINX:-yes}" != "yes" ]]; then echo "ENABLE_NGINX!=yes — skipping"; exit 0; fi

: "${DOMAIN:?set DOMAIN in .env}"
: "${WEB_ROOT:=/home/projects}"
: "${PHP_VERSION:=8.3}"
: "${RECORDINGS_DIR:=$WEB_ROOT/voice/records}"

command -v nginx >/dev/null || { echo "Installing nginx + php-fpm"; \
  apt-get install -y nginx "php${PHP_VERSION}-fpm"; }

mkdir -p "$WEB_ROOT/logs" "$RECORDINGS_DIR"

# Render the nginx site (only OUR vars; nginx's own $uri/$document_root are preserved)
SUBST='${DOMAIN} ${WEB_ROOT} ${PHP_VERSION} ${RECORDINGS_DIR}'
envsubst "$SUBST" < "$HERE/templates/nginx-site.conf.template" > /etc/nginx/sites-available/aakashtel

ln -sf /etc/nginx/sites-available/aakashtel /etc/nginx/sites-enabled/aakashtel
# Remove the stock default site if it would clash on port 80
[[ -e /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

echo "==> Testing nginx config"
nginx -t

systemctl enable "php${PHP_VERSION}-fpm" nginx
systemctl restart "php${PHP_VERSION}-fpm"
systemctl reload nginx 2>/dev/null || systemctl restart nginx

echo "==> Web front-end configured for ${DOMAIN} (HTTP). Run 'make tls' to add HTTPS."
