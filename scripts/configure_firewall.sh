#!/usr/bin/env bash
# Apply an nftables default-deny INPUT policy with allow-lists.
# Matches the reference server's backend (nftables; UFW not used) but HARDENS it:
# the reference box had an open INPUT policy — here we default-deny.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

: "${RTP_START:=10000}" "${RTP_END:=30000}"
: "${LOCAL_CIDR:=172.16.176.0/24}" "${CARRIER_CIDR:=10.40.55.0/24}"
: "${PROVIDER_ALLOW_IPS:=}" "${ADMIN_ALLOW_IPS:=}"

command -v nft >/dev/null || { echo "Installing nftables"; apt-get install -y nftables; }

# Build set elements for SIP source allow-list (carrier + LAN + provider IPs + admin IPs)
sip_srcs="$LOCAL_CIDR, $CARRIER_CIDR"
for ip in $PROVIDER_ALLOW_IPS $ADMIN_ALLOW_IPS; do sip_srcs+=", $ip"; done
admin_srcs="$LOCAL_CIDR"
for ip in $ADMIN_ALLOW_IPS; do admin_srcs+=", $ip"; done

NFT=/etc/nftables-asterisk.nft
cat > "$NFT" <<EOF
#!/usr/sbin/nft -f
# Managed by asterisk-deploy. Default-deny INPUT with SIP/RTP/admin allow-lists.
table inet asterisk_fw {
    set sip_src   { type ipv4_addr; flags interval; elements = { $sip_srcs } }
    set admin_src { type ipv4_addr; flags interval; elements = { $admin_srcs } }

    chain input {
        type filter hook input priority 0; policy drop;

        iif "lo" accept
        ct state established,related accept
        ip protocol icmp accept

        # Web front-end (nginx) — public, needed for the app + Let's Encrypt HTTP-01
        tcp dport 80  accept
        tcp dport 443 accept

        # SSH / AMI / ARI(8088) — admin sources only
        tcp dport 22   ip saddr @admin_src accept
        tcp dport 5038 ip saddr @admin_src accept   # AMI
        tcp dport 8088 ip saddr @admin_src accept   # ARI/HTTP (loopback+admin)
        tcp dport 7443 ip saddr @admin_src accept   # Asterisk HTTPS/WSS (relax if public WebRTC)

        # SIP signaling — carrier + LAN
        udp dport 5060 ip saddr @sip_src accept
        tcp dport 5060 ip saddr @sip_src accept
        tcp dport 5061 ip saddr @sip_src accept     # TLS

        # RTP media — open range (carrier IP is dynamic within SBC pools)
        udp dport ${RTP_START}-${RTP_END} accept
    }
}
EOF

echo "==> Loading nftables ruleset from $NFT"
nft -f "$NFT"
systemctl enable nftables 2>/dev/null || true
# Persist across reboot
cp "$NFT" /etc/nftables.conf.d/asterisk.nft 2>/dev/null || \
  { mkdir -p /etc/nftables.conf.d && cp "$NFT" /etc/nftables.conf.d/asterisk.nft; }

echo "==> Firewall applied. Verify: nft list table inet asterisk_fw"
echo "    NOTE: if WebRTC is served to the public internet, relax the 7443 rule."
