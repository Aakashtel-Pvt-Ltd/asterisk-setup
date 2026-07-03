#!/usr/bin/env bash
# Snapshot /etc/asterisk (and generated app configs) before any change.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="/var/backups/asterisk-config-$STAMP"

echo "==> Backing up existing Asterisk config to $DEST"
mkdir -p "$DEST"

if [[ -d /etc/asterisk ]]; then
  tar -czf "$DEST/etc-asterisk.tar.gz" -C /etc asterisk
  echo "    saved /etc/asterisk"
else
  echo "    (no existing /etc/asterisk — fresh host)"
fi

# Generated app-layer configs, if this is a re-run on an existing box
for f in "${PROJECTS_DIR:-/home/stage/asterisk}/users.conf" \
         "${PROJECTS_DIR:-/home/stage/asterisk}/queue_custom.conf" \
         "${PROJECTS_DIR:-/home/stage/asterisk}/moh_files.conf"; do
  [[ -f "$f" ]] && cp -a "$f" "$DEST/" && echo "    saved $f"
done

echo "==> Backup complete: $DEST"
echo "    Rollback: tar -xzf $DEST/etc-asterisk.tar.gz -C /etc"
