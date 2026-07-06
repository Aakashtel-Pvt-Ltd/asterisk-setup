#!/usr/bin/env bash
# Render parameterized templates -> /etc/asterisk using envsubst, with correct
# ownership/permissions. Does NOT reload the running Asterisk (safe on fresh host).
#
# Templates were regenerated 2026-07 from the live server's /etc/asterisk, so a
# render with the live values reproduces the live config. Both carriers are
# supported: Ncell (IP-auth, ncell.conf) and NTC (registration, ntc.conf) —
# toggle with ENABLE_NCELL / ENABLE_NTC.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] || { echo "ERROR: $HERE/.env missing"; exit 1; }
set -a && source "$HERE/.env" && set +a

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

# --- legacy .env compatibility (NTC-only kit revisions used SIP_* names) ------
# An old .env written for the NTC/IMS scenario keeps working unchanged.
: "${NTC_TRUNK_NAME:=${SIP_TRUNK_NAME:-}}"
: "${NTC_PROVIDER_HOST:=${SIP_PROVIDER_HOST:-}}"
: "${NTC_PROXY:=${SIP_PROXY:-}}"
: "${NTC_USERNAME:=${SIP_USERNAME:-}}"
: "${NTC_SECRET:=${SIP_SECRET:-}}"
: "${NTC_CODEC:=${TRUNK_CODEC:-alaw}}"
export NTC_TRUNK_NAME NTC_PROVIDER_HOST NTC_PROXY NTC_USERNAME NTC_SECRET NTC_CODEC
# Legacy .env has no ENABLE_NTC/ENABLE_NCELL — infer from the trunks configured.
if [[ -z "${ENABLE_NTC:-}" ]]; then
  [[ -n "$NTC_TRUNK_NAME" ]] && ENABLE_NTC=yes || ENABLE_NTC=no
fi
if [[ -z "${ENABLE_NCELL:-}" ]]; then
  [[ -n "${NCELL_TRUNK_NAME:-}" ]] && ENABLE_NCELL=yes || ENABLE_NCELL=no
fi
export ENABLE_NTC ENABLE_NCELL

# Non-secret site constants — default to the live server's values so an older
# (NTC-only) .env still renders a complete config.
export OPENSIPS_HOST="${OPENSIPS_HOST:-192.168.0.154}"
export AI_GATEWAY_WS_URL="${AI_GATEWAY_WS_URL:-wss://gateway.aakashpay.com/realtime/}"

# --- validate required vars ---------------------------------------------------
req=(PUBLIC_IP LOCAL_CIDR RTP_START RTP_END AMI_USER AMI_SECRET AMI_BIND \
     ARI_USER ARI_SECRET TLS_CERT TLS_KEY HTTP_BIND HTTPS_BIND PROJECTS_DIR \
     SYSTEMNAME)
[[ "$ENABLE_NCELL" == "yes" ]] && \
  req+=(NCELL_TRUNK_NAME NCELL_FROM_USER NCELL_SBC_KTM NCELL_SBC_POK)
[[ "$ENABLE_NTC" == "yes" ]] && \
  req+=(NTC_TRUNK_NAME NTC_PROVIDER_HOST NTC_PROXY NTC_USERNAME NTC_SECRET NTC_CODEC)
missing=()
for v in "${req[@]}"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
if ((${#missing[@]})); then echo "ERROR: unset .env vars: ${missing[*]}"; exit 1; fi
secrets=(AMI_SECRET ARI_SECRET)
[[ "$ENABLE_NTC" == "yes" ]] && secrets+=(NTC_SECRET)
for s in "${secrets[@]}"; do
  case "${!s}" in *ASK_USER*|"") echo "ERROR: set a real $s in .env"; exit 1;; esac
done

TPL="$HERE/templates"
DST=/etc/asterisk
mkdir -p "$DST"

# Split NTC_PROXY host:port for the identify match (empty when NTC disabled)
NTC_PROXY="${NTC_PROXY:-}"
export NTC_PROXY_HOST="${NTC_PROXY%%:*}"
export SYSTEMNAME="${SYSTEMNAME:-Aakashtech}"
# extensions.conf references the Ncell trunk name (from-freeswitch context) even
# when the trunk is disabled — keep the rendered text sane with the live default.
export NCELL_TRUNK_NAME="${NCELL_TRUNK_NAME:-+9779801730002}"

# IMPORTANT: only substitute OUR deploy variables. Asterisk configs contain their
# own ${...} tokens (${EXTEN}, ${CALLERID(num)}, ${CUT(...)}, ${last_part}) that
# must be left untouched. A bare `envsubst` would blank them out and break the
# dialplan, so we pass an explicit whitelist.
SUBST_VARS='${PUBLIC_IP} ${LOCAL_CIDR} ${RTP_START} ${RTP_END} \
${NCELL_TRUNK_NAME} ${NCELL_FROM_USER} ${NCELL_SBC_KTM} ${NCELL_SBC_POK} \
${NTC_TRUNK_NAME} ${NTC_PROVIDER_HOST} ${NTC_PROXY} ${NTC_PROXY_HOST} \
${NTC_USERNAME} ${NTC_SECRET} ${NTC_CODEC} \
${OPENSIPS_HOST} \
${AMI_USER} ${AMI_SECRET} ${AMI_BIND} ${ARI_USER} ${ARI_SECRET} \
${TLS_CERT} ${TLS_KEY} ${HTTP_BIND} ${HTTPS_BIND} ${SYSTEMNAME} \
${AI_GATEWAY_WS_URL} ${PROJECTS_DIR}'

echo "==> Rendering templates -> $DST"
for base in asterisk.conf pjsip.conf pjsip_endpoints.conf extensions.conf \
            rtp.conf modules.conf manager.conf logger.conf http.conf ari.conf \
            queues.conf cdr.conf cdr_manager.conf features.conf \
            musiconhold.conf confbridge.conf websocket_client.conf; do
  t="$TPL/${base}.template"
  [[ -f "$t" ]] || { echo "    MISSING template: $t"; exit 1; }
  envsubst "$SUBST_VARS" < "$t" > "$DST/$base"
  echo "    $base"
done

# --- carrier trunks (each rendered or stubbed so pjsip.conf includes resolve) --
if [[ "$ENABLE_NCELL" == "yes" ]]; then
  envsubst "$SUBST_VARS" < "$TPL/ncell.conf.template" > "$DST/ncell.conf"
  echo "    ncell.conf (enabled)"
else
  echo "; ncell.conf — Ncell trunk disabled (ENABLE_NCELL=no in .env)" > "$DST/ncell.conf"
  echo "    ncell.conf (disabled stub)"
fi
if [[ "$ENABLE_NTC" == "yes" ]]; then
  envsubst "$SUBST_VARS" < "$TPL/ntc.conf.template" > "$DST/ntc.conf"
  echo "    ntc.conf (enabled)"
else
  echo "; ntc.conf — NTC trunk disabled (ENABLE_NTC=no in .env)" > "$DST/ntc.conf"
  echo "    ntc.conf (disabled stub)"
fi

# --- Self-signed cert fallback -------------------------------------------------
# pjsip.conf/http.conf reference ${TLS_CERT}/${TLS_KEY}. If certbot ('make tls')
# hasn't run yet, generate a temporary self-signed pair so Asterisk can still
# start (TLS/WSS transports bind). certbot's deploy hook replaces these later.
if [[ ! -f "$TLS_CERT" || ! -f "$TLS_KEY" ]]; then
  echo "==> TLS cert not found — generating temporary self-signed cert at $TLS_CERT"
  mkdir -p "$(dirname "$TLS_CERT")"
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
    -subj "/CN=${DOMAIN:-asterisk.local}" \
    -keyout "$TLS_KEY" -out "$TLS_CERT" 2>/dev/null
  chown asterisk:asterisk "$TLS_CERT" "$TLS_KEY"
  chmod 0644 "$TLS_CERT"; chmod 0640 "$TLS_KEY"
  echo "    (temporary — run 'make tls' for a real Let's Encrypt cert)"
fi

# Install the logrotate rule the reference server was MISSING (its messages.log
# had grown to ~1GB). Rendered here so the rebuild never has that problem.
if [[ -f "$TPL/logrotate-asterisk.template" ]]; then
  envsubst '${PROJECTS_DIR}' < "$TPL/logrotate-asterisk.template" > /etc/logrotate.d/asterisk
  chmod 0644 /etc/logrotate.d/asterisk
  echo "    -> /etc/logrotate.d/asterisk"
fi

# Preserve the #include targets for the generated app configs (asterisk must
# read them): users.conf (sipuser service), queue_custom.conf (sipqueue),
# moh_files.conf (per-DID music-on-hold classes).
mkdir -p "${PROJECTS_DIR:-/home/stage/asterisk}"
for f in users.conf queue_custom.conf moh_files.conf; do
  p="${PROJECTS_DIR:-/home/stage/asterisk}/$f"
  [[ -f "$p" ]] || touch "$p"
  chown asterisk:asterisk "$p"
  chmod 0664 "$p"
done
# MOH class directories referenced by moh_files.conf live here
mkdir -p /var/lib/asterisk/moh
chown asterisk:asterisk /var/lib/asterisk/moh

# --- ownership / permissions (match live: asterisk-readable, group asterisk) ---
chown -R asterisk:asterisk "$DST"
chmod 0750 "$DST"
find "$DST" -type f -exec chmod 0640 {} \;

echo "==> Config rendered. NOT reloading Asterisk (do that explicitly)."
echo "    Review: ls -l $DST ; then: systemctl enable --now asterisk"
