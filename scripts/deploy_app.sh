#!/usr/bin/env bash
# Deploy the /home/projects application layer: npm install for the Node services,
# render + install their systemd units, and enable them. The application CODE
# itself (PHP AGI + Node JS + each app .env with its API tokens/AWS keys) is NOT
# shipped in this kit — you must place it in ${PROJECTS_DIR} first (from your repo).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] || { echo "ERROR: $HERE/.env missing"; exit 1; }
set -a && source "$HERE/.env" && set +a

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

: "${PROJECTS_DIR:=/home/projects}"
: "${NODE_VERSION:=v24.16.0}"
: "${APP_SERVICES:=ami broadcast sipuser sipqueue-populate}"
NODE_BIN="/root/.nvm/versions/node/${NODE_VERSION}/bin/node"
export NODE_BIN PROJECTS_DIR

# --- Guard: the app code must be present -------------------------------------
if [[ ! -d "$PROJECTS_DIR/ami" || ! -f "$PROJECTS_DIR/ami/listAllEvent.js" ]]; then
  cat <<EOF
WARNING: $PROJECTS_DIR/ami/listAllEvent.js not found.
The application code is not part of this kit. Before running 'make services':
  1. Copy your app into $PROJECTS_DIR (agi/, stageagi/, ami/, broadcast/, service/, voice/)
  2. Populate each app .env (APP_BACKEND_BASE_URL, AMI creds, AWS S3 keys)
Skipping service install.
EOF
  exit 0
fi
[[ -x "$NODE_BIN" ]] || { echo "ERROR: node not found at $NODE_BIN — run 'make install' first"; exit 1; }

# --- npm install for each Node app that has a package.json -------------------
for d in ami broadcast; do
  if [[ -f "$PROJECTS_DIR/$d/package.json" ]]; then
    echo "==> npm install in $PROJECTS_DIR/$d"
    ( cd "$PROJECTS_DIR/$d" && "$(dirname "$NODE_BIN")/npm" install --omit=dev )
  fi
done

# --- Render + install systemd units ------------------------------------------
for svc in $APP_SERVICES; do
  tpl="$HERE/templates/systemd/${svc}.service.template"
  [[ -f "$tpl" ]] || { echo "    no template for $svc — skipping"; continue; }
  envsubst '${NODE_BIN} ${PROJECTS_DIR}' < "$tpl" > "/etc/systemd/system/${svc}.service"
  echo "    installed ${svc}.service"
done

systemctl daemon-reload
for svc in $APP_SERVICES; do
  systemctl enable "$svc" 2>/dev/null || true
done

# Ownership of the app tree (matches reference: asterisk owns /home/projects apps)
chown -R asterisk:asterisk "$PROJECTS_DIR"/{agi,ami,broadcast,service,voice,stageagi} 2>/dev/null || true

echo "==> App services installed & enabled: $APP_SERVICES"
echo "    Start them with: systemctl start $APP_SERVICES"
echo "    (start Asterisk first: systemctl start asterisk)"
