#!/usr/bin/env bash
# Build & install Asterisk from source (matching the reference server, which is a
# source build — NOT the Ubuntu package), plus PHP 8.3 and Node (via nvm) for the
# /home/projects app layer. Idempotent: skips steps already satisfied.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$HERE/.env" ]] && set -a && source "$HERE/.env" && set +a

: "${ASTERISK_VERSION:=22.10.0}"
: "${NODE_VERSION:=v24.16.0}"
: "${TIMEZONE:=Asia/Kathmandu}"

require_root() { [[ "$(id -u)" == "0" ]] || { echo "Run as root"; exit 1; }; }
require_root

echo "==> Detected install method on reference server: SOURCE BUILD (Asterisk $ASTERISK_VERSION)"

# --- 1. System / timezone -----------------------------------------------------
timedatectl set-timezone "$TIMEZONE" || true

# --- 2. Build dependencies + runtime stack (Ubuntu/Debian) -------------------
# Reference server also runs nginx + PHP-FPM (web/API front-end) and certbot (TLS).
export DEBIAN_FRONTEND=noninteractive
: "${PHP_VERSION:=8.3}"
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential git curl wget subversion pkg-config \
  libjansson-dev libxml2-dev libsqlite3-dev uuid-dev libedit-dev \
  libssl-dev libsrtp2-dev libcurl4-openssl-dev libncurses5-dev \
  gettext-base ca-certificates nftables fail2ban \
  nginx certbot python3-certbot-nginx \
  "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-curl" \
  "php${PHP_VERSION}-xml" "php${PHP_VERSION}-mbstring"

# --- 3. Asterisk user/group ---------------------------------------------------
if ! id asterisk &>/dev/null; then
  groupadd -r asterisk
  useradd -r -d /var/lib/asterisk -g asterisk -s /usr/sbin/nologin asterisk
  usermod -aG audio,dialout asterisk
fi

# --- 4. Fetch + build Asterisk (skip if already installed at this version) ---
if asterisk -V 2>/dev/null | grep -q "$ASTERISK_VERSION"; then
  echo "==> Asterisk $ASTERISK_VERSION already installed — skipping build."
else
  SRC=/usr/src/asterisk-${ASTERISK_VERSION}
  if [[ ! -d "$SRC" ]]; then
    echo "==> Downloading Asterisk $ASTERISK_VERSION source"
    cd /usr/src
    wget -q "https://downloads.asterisk.org/pub/telephony/asterisk/releases/asterisk-${ASTERISK_VERSION}.tar.gz"
    tar -xzf "asterisk-${ASTERISK_VERSION}.tar.gz"
  fi
  cd "$SRC"
  # Fetch bundled pjproject + sounds; install any remaining OS deps.
  contrib/scripts/install_prereq install || true
  ./configure --with-pjproject-bundled --with-jansson-bundled
  # Use the EXACT build options captured from the reference server if shipped
  # with the kit; otherwise fall back to enabling the modules we know we use.
  if [[ -f "$HERE/menuselect.makeopts" ]]; then
    echo "==> Using reference menuselect.makeopts (exact module match)"
    cp "$HERE/menuselect.makeopts" ./menuselect.makeopts
  else
    make menuselect.makeopts
    menuselect/menuselect --enable chan_pjsip --enable res_pjsip \
      --enable app_queue --enable res_agi --enable res_ari \
      --enable format_wav --enable codec_alaw --enable codec_ulaw \
      --disable chan_dahdi \
      menuselect.makeopts || true
  fi
  make -j"$(nproc)"
  make install
  make samples          # stock sample configs (our templates overwrite the live ones)
  make config           # installs /etc/init.d/asterisk + rc links (the service itself!)
  ldconfig
  systemctl daemon-reload
fi

# --- 4b. Data-directory ownership (make install leaves them root-owned) -------
for d in /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk /var/cache/asterisk; do
  [[ -d "$d" ]] && chown -R asterisk:asterisk "$d"
done

# --- 5. Runtime identity file -------------------------------------------------
cat > /etc/default/asterisk <<'EOF'
AST_USER="asterisk"
AST_GROUP="asterisk"
COLOR=yes
EOF

# --- 6. Node.js via nvm (for /home/projects AMI + broadcast apps) ------------
if [[ ! -x "/root/.nvm/versions/node/${NODE_VERSION}/bin/node" ]]; then
  echo "==> Installing Node ${NODE_VERSION} via nvm"
  export NVM_DIR=/root/.nvm
  if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm install "${NODE_VERSION}"
fi

echo "==> Package/build step complete."
echo "    NEXT: deploy /home/projects app stack and run 'npm install' in ami/ and broadcast/."
