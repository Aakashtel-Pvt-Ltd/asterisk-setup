#!/usr/bin/env bash
# Install fail2ban with asterisk + sshd jails (mirrors the reference server, whose
# asterisk jail reads /var/log/asterisk/messages.log and had 400+ bans).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

command -v fail2ban-client >/dev/null || { echo "Installing fail2ban"; apt-get install -y fail2ban; }

cat > /etc/fail2ban/jail.d/asterisk.local <<'EOF'
[DEFAULT]
banaction = nftables-multiport
bantime   = 3600
findtime  = 600
maxretry  = 5

[sshd]
enabled = true

[asterisk]
enabled  = true
port     = 5060,5061,5062
protocol = udp
filter   = asterisk
logpath  = /var/log/asterisk/messages.log
maxretry = 5
EOF

systemctl enable fail2ban
systemctl restart fail2ban    # (fresh host; not the live PBX)

echo "==> fail2ban configured. Verify: fail2ban-client status asterisk"
