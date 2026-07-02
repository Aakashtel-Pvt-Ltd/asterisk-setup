#!/usr/bin/env bash
# Install fail2ban with asterisk + sshd jails, matching the reference server's
# actual jail (/etc/fail2ban/jail.d/asterisk.conf): maxretry=3, 24h ban,
# nftables ban action, and an ignoreip allow-list of trusted IPs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

: "${LOCAL_CIDR:=172.16.176.0/24}" "${ADMIN_ALLOW_IPS:=}"

command -v fail2ban-client >/dev/null || { echo "Installing fail2ban"; apt-get install -y fail2ban; }

# Build the ignoreip list: loopback + LAN + any admin IPs (so you never ban yourself)
IGNORE="127.0.0.1/8 ::1 ${LOCAL_CIDR}"
for ip in $ADMIN_ALLOW_IPS; do IGNORE="$IGNORE $ip"; done

# Global defaults — nftables ban action (matches reference DEFAULT section)
cat > /etc/fail2ban/jail.d/defaults.local <<'EOF'
[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]
backend = systemd
EOF

# The asterisk jail — reads Asterisk's log, bans SIP brute-force for 24h
cat > /etc/fail2ban/jail.d/asterisk.conf <<EOF
[asterisk]
enabled  = true
port     = 5060,5061,5062
protocol = udp
filter   = asterisk
logpath  = /var/log/asterisk/messages.log
maxretry = 3
findtime = 600
bantime  = 86400
backend  = auto
ignoreip = ${IGNORE}

[sshd]
enabled = true
EOF

systemctl enable fail2ban
systemctl restart fail2ban    # (fresh host; not the live PBX)

echo "==> fail2ban configured (asterisk 24h ban, ignoreip: ${IGNORE})."
echo "    Verify: fail2ban-client status asterisk"
