#!/usr/bin/env bash
# Render parameterized templates -> /etc/asterisk using envsubst, with correct
# ownership/permissions. Does NOT reload the running Asterisk (safe on fresh host).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] || { echo "ERROR: $HERE/.env missing"; exit 1; }
set -a && source "$HERE/.env" && set +a

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

# --- validate required vars ---------------------------------------------------
req=(PUBLIC_IP LOCAL_IP LOCAL_CIDR RTP_START RTP_END SIP_PROVIDER_HOST SIP_PROXY \
     SIP_TRUNK_NAME SIP_USERNAME SIP_SECRET DID_NUMBER OUTBOUND_CID TRUNK_CODEC \
     AMI_USER AMI_SECRET AMI_BIND ARI_USER TLS_CERT TLS_KEY HTTP_BIND HTTPS_BIND)
missing=()
for v in "${req[@]}"; do [[ -n "${!v:-}" ]] || missing+=("$v"); done
if ((${#missing[@]})); then echo "ERROR: unset .env vars: ${missing[*]}"; exit 1; fi
case "$SIP_SECRET" in *ASK_USER*|"") echo "ERROR: set a real SIP_SECRET"; exit 1;; esac

TPL="$HERE/templates"
DST=/etc/asterisk
mkdir -p "$DST"

# Split SIP_PROXY host:port for templates that need them separately
export SIP_PROXY_HOST="${SIP_PROXY%%:*}"
export SIP_PROXY_PORT="${SIP_PROXY##*:}"
export CARRIER_CIDR="${CARRIER_CIDR:-$LOCAL_CIDR}"
export SYSTEMNAME="${SYSTEMNAME:-Aakashtel}"

# IMPORTANT: only substitute OUR deploy variables. Asterisk configs contain their
# own ${...} tokens (${EXTEN}, ${CALLERID(num)}, ${CUT(...)}, ${last_part}) that
# must be left untouched. A bare `envsubst` would blank them out and break the
# dialplan, so we pass an explicit whitelist.
SUBST_VARS='${PUBLIC_IP} ${LOCAL_IP} ${LOCAL_CIDR} ${CARRIER_CIDR} \
${RTP_START} ${RTP_END} ${SIP_PROVIDER_HOST} ${SIP_PROXY} ${SIP_PROXY_HOST} \
${SIP_PROXY_PORT} ${SIP_TRUNK_NAME} ${SIP_USERNAME} ${SIP_SECRET} ${DID_NUMBER} \
${OUTBOUND_CID} ${TRUNK_CODEC} ${AMI_USER} ${AMI_SECRET} ${AMI_BIND} ${ENABLE_AMI} \
${ARI_USER} ${ARI_SECRET} ${ENABLE_ARI} ${TLS_CERT} ${TLS_KEY} ${HTTP_BIND} \
${HTTPS_BIND} ${SYSTEMNAME} ${PROJECTS_DIR}'

echo "==> Rendering templates -> $DST"
for base in pjsip.conf extensions.conf rtp.conf modules.conf manager.conf logger.conf; do
  t="$TPL/${base}.template"
  [[ -f "$t" ]] || { echo "    MISSING template: $t"; exit 1; }
  envsubst "$SUBST_VARS" < "$t" > "$DST/$base"
  echo "    $base"
done

# Install the logrotate rule the reference server was MISSING (its messages.log
# had grown to ~1GB). Rendered here so the rebuild never has that problem.
if [[ -f "$TPL/logrotate-asterisk.template" ]]; then
  envsubst '${PROJECTS_DIR}' < "$TPL/logrotate-asterisk.template" > /etc/logrotate.d/asterisk
  chmod 0644 /etc/logrotate.d/asterisk
  echo "    -> /etc/logrotate.d/asterisk"
fi

# Preserve the #include targets for the generated app configs
mkdir -p "${PROJECTS_DIR:-/home/projects}"
touch "${PROJECTS_DIR:-/home/projects}/user.conf" \
      "${PROJECTS_DIR:-/home/projects}/queue_custom.conf"

# --- ownership / permissions (match reference: asterisk:asterisk 0750) -------
chown -R asterisk:asterisk "$DST"
chmod 0750 "$DST"
find "$DST" -type f -exec chmod 0640 {} \;

echo "==> Config rendered. NOT reloading Asterisk (do that explicitly)."
echo "    Review: ls -l $DST ; then: systemctl enable --now asterisk"
