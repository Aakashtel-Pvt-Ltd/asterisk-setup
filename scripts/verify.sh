#!/usr/bin/env bash
# Post-install verification: trunk registration, listening ports, log health.
# Read-only — safe to run repeatedly.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a

: "${RTP_START:=10000}"
rc=0
say() { printf '  [%s] %s\n' "$1" "$2"; }

echo "==> Asterisk version"
asterisk -rx "core show version" 2>/dev/null || { echo "  Asterisk not reachable"; exit 1; }

echo "==> Trunk registration"
if asterisk -rx "pjsip show registrations" 2>/dev/null | grep -qi "Registered"; then
  say OK "SIP trunk Registered"
else
  say FAIL "trunk NOT registered"; rc=1
fi

echo "==> Transports"
asterisk -rx "pjsip show transports" 2>/dev/null | grep -E "udp|tcp|tls|wss" || { say WARN "no transports"; rc=1; }

echo "==> Listening ports"
for p in 5060 5061 5038 8088 7443 "$RTP_START"; do
  if ss -tulpnH 2>/dev/null | grep -q ":$p "; then say OK "port $p listening"; else say WARN "port $p not listening"; fi
done

echo "==> Dialplan contexts"
for c in incomming from-extensions outgoing ami-action; do
  if asterisk -rx "dialplan show $c" 2>/dev/null | grep -q "Context '$c'"; then
    say OK "context $c present"
  else
    say WARN "context $c missing"; rc=1
  fi
done

echo "==> fail2ban"
fail2ban-client status asterisk 2>/dev/null | grep -E "Banned|Total" || say WARN "asterisk jail not active"

echo "==> Log health"
LOG=/var/log/asterisk/messages.log
if [[ -f "$LOG" ]]; then
  sz=$(du -m "$LOG" | cut -f1)
  (( sz > 500 )) && say WARN "messages.log is ${sz}MB — check logrotate" || say OK "messages.log ${sz}MB"
  tail -n 20 "$LOG" | grep -iE "error|warning" && say WARN "recent errors/warnings above" || true
fi

echo "==> Companion services"
for u in ami broadcast; do
  systemctl is-active --quiet "$u" && say OK "$u.service active" || say WARN "$u.service not active"
done

echo
[[ $rc -eq 0 ]] && echo "VERIFY: PASS" || echo "VERIFY: issues found (see WARN/FAIL above)"
exit $rc
