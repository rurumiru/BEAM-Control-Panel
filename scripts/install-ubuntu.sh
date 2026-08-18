#!/usr/bin/env bash
#
# BEAM Control Panel — установка на чистый сервер Ubuntu 24.04 / 26.04
# ---------------------------------------------------------------------------
# Ставит все зависимости (Erlang/OTP, Elixir, Node.js, PostgreSQL, nginx),
# собирает OTP-релиз, создаёт системного пользователя и systemd-юнит,
# накатывает миграции и создаёт администратора.
#
# Запуск:
#
#     sudo bash scripts/install-ubuntu.sh
#     sudo bash scripts/install-ubuntu.sh --domain panel.example.com --letsencrypt
#
# Скрипт идемпотентен: повторный запуск обновляет установку.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LC_ALL=C.UTF-8

# ------------------------------------------------------------------ defaults

APP_NAME="beam_panel"
APP_USER="${BEAM_PANEL_USER:-beampanel}"
APP_HOME="${BEAM_PANEL_HOME:-/opt/beam-panel}"
CONFIG_DIR="/etc/beam-panel"
ENV_FILE="$CONFIG_DIR/beam-panel.env"
SERVICE_NAME="beam-panel"

OTP_VERSION="${OTP_VERSION:-27}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.4}"
NODE_VERSION="${NODE_VERSION:-22}"

DB_NAME="${DB_NAME:-beam_panel_prod}"
DB_USER="${DB_USER:-beam_panel}"
DB_PASSWORD="${DB_PASSWORD:-}"

HTTP_PORT="${PORT:-4000}"
DOMAIN="${DOMAIN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

INSTALL_NGINX=1
INSTALL_LETSENCRYPT=0
SOURCE_DIR=""

# ------------------------------------------------------------------- helpers

step()  { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
info()  { printf '    %s\n' "$1"; }
warn()  { printf '\033[1;33m    ! %s\033[0m\n' "$1"; }
fail()  { printf '\033[1;31m!! %s\033[0m\n' "$1" >&2; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }
rand()  { head -c "${1:-24}" /dev/urandom | base64 | tr -d '\n=+/' | cut -c1-"${1:-24}"; }

usage() {
  cat <<'USAGE'
BEAM Control Panel — установщик

  --domain <host>        доменное имя для nginx (иначе доступ по IP:порту)
  --port <port>          порт приложения (по умолчанию 4000)
  --admin-email <email>  e-mail администратора
  --admin-password <pw>  пароль администратора (иначе будет сгенерирован)
  --db-password <pw>     пароль пользователя PostgreSQL
  --source <dir>         каталог с исходниками (по умолчанию — текущий репозиторий)
  --no-nginx             не устанавливать и не настраивать nginx
  --letsencrypt          выпустить сертификат Let's Encrypt (нужен --domain)
  --otp <ver>            версия Erlang/OTP (по умолчанию 27)
  --elixir <ver>         версия Elixir (по умолчанию 1.18.4)
  -h, --help             показать эту справку
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)         DOMAIN="$2"; shift 2 ;;
    --port)           HTTP_PORT="$2"; shift 2 ;;
    --admin-email)    ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --db-password)    DB_PASSWORD="$2"; shift 2 ;;
    --source)         SOURCE_DIR="$2"; shift 2 ;;
    --no-nginx)       INSTALL_NGINX=0; shift ;;
    --letsencrypt)    INSTALL_LETSENCRYPT=1; shift ;;
    --otp)            OTP_VERSION="$2"; shift 2 ;;
    --elixir)         ELIXIR_VERSION="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                fail "неизвестный параметр: $1 (см. --help)" ;;
  esac
done

trap 'echo; fail "ошибка на строке $LINENO"' ERR

[ "$(id -u)" -eq 0 ] || fail "запустите скрипт от root: sudo bash $0"

if [ -z "$SOURCE_DIR" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SOURCE_DIR="$(dirname "$SCRIPT_DIR")"
fi

[ -f "$SOURCE_DIR/mix.exs" ] || fail "не найден mix.exs в $SOURCE_DIR — укажите --source"

# ------------------------------------------------------------------- system

step "Проверка системы"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
  info "${PRETTY_NAME:-unknown}"
  case "${VERSION_ID:-}" in
    24.04|24.10|25.04|25.10|26.04) : ;;
    *) warn "скрипт рассчитан на Ubuntu 24.04+; продолжаем на свой риск" ;;
  esac
else
  UBUNTU_CODENAME="noble"
  warn "/etc/os-release не найден"
fi

ARCH="$(dpkg --print-architecture)"
info "архитектура: $ARCH"

APT_UPDATED=0
apt_update_once() { [ "$APT_UPDATED" -eq 1 ] || { apt-get update -qq; APT_UPDATED=1; }; }
apt_install() {
  apt_update_once
  apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

step "Базовые пакеты"
apt_install ca-certificates curl wget gnupg lsb-release apt-transport-https \
  build-essential git unzip zip xz-utils pkg-config make automake autoconf \
  libssl-dev libncurses-dev locales tzdata rsync jq
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
info "готово"

# -------------------------------------------------------------------- erlang

step "Erlang/OTP $OTP_VERSION"

current_otp() {
  erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().' 2>/dev/null || true
}

if [ "$(current_otp)" = "$OTP_VERSION" ]; then
  info "уже установлен"
else
  ESL_KEY=/usr/share/keyrings/erlang-solutions.gpg
  ESL_LIST=/etc/apt/sources.list.d/erlang-solutions.list
  INSTALLED=0

  if curl -fsSL https://binaries2.erlang-solutions.com/GPG-KEY-pmanager.asc 2>/dev/null \
      | gpg --dearmor -o "$ESL_KEY" 2>/dev/null; then
    echo "deb [signed-by=$ESL_KEY] https://binaries2.erlang-solutions.com/ubuntu/ ${UBUNTU_CODENAME}-esl-erlang-${OTP_VERSION} contrib" \
      > "$ESL_LIST"
    APT_UPDATED=0
    if apt_install esl-erlang 2>/dev/null; then
      INSTALLED=1
      info "установлен из Erlang Solutions"
    else
      warn "репозиторий Erlang Solutions недоступен для ${UBUNTU_CODENAME}"
      rm -f "$ESL_LIST"
      APT_UPDATED=0
    fi
  fi

  if [ "$INSTALLED" -eq 0 ]; then
    apt_install erlang-nox erlang-dev erlang-parsetools erlang-xmerl erlang-ssh erlang-crypto
    info "установлен из репозитория Ubuntu"
  fi
fi

have erl || fail "Erlang не установился"
info "OTP $(current_otp)"

# -------------------------------------------------------------------- elixir

step "Elixir $ELIXIR_VERSION"

OTP_MAJOR="$(current_otp)"

if [ "$(elixir --short-version 2>/dev/null || true)" = "$ELIXIR_VERSION" ]; then
  info "уже установлен"
else
  TMP="$(mktemp -d)"
  URL="https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${OTP_MAJOR}.zip"

  if curl -fsSL -o "$TMP/elixir.zip" "$URL"; then
    rm -rf /usr/local/elixir
    mkdir -p /usr/local/elixir
    unzip -qo "$TMP/elixir.zip" -d /usr/local/elixir
    for b in elixir elixirc iex mix; do ln -sf "/usr/local/elixir/bin/$b" "/usr/local/bin/$b"; done
    info "установлен из официальной сборки под OTP $OTP_MAJOR"
  else
    warn "сборка под OTP $OTP_MAJOR недоступна — ставим elixir из репозитория Ubuntu"
    apt_install elixir
  fi
  rm -rf "$TMP"
fi

have mix || fail "Elixir не установился"
info "Elixir $(elixir --short-version)"

# ------------------------------------------------------------------- node.js

step "Node.js $NODE_VERSION (сборка ассетов)"

if node --version 2>/dev/null | grep -q "^v${NODE_VERSION}\."; then
  info "уже установлен"
else
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - >/dev/null 2>&1 \
    || warn "NodeSource недоступен — ставим nodejs из Ubuntu"
  APT_UPDATED=0
  apt_install nodejs || apt_install nodejs npm
fi
info "Node $(node --version 2>/dev/null || echo '—')"

# ---------------------------------------------------------------- postgresql

step "PostgreSQL"

have psql || apt_install postgresql postgresql-contrib libpq-dev
systemctl enable --now postgresql
info "$(psql --version)"

if [ -z "$DB_PASSWORD" ]; then
  if [ -f "$ENV_FILE" ] && grep -q '^DATABASE_URL=' "$ENV_FILE"; then
    DB_PASSWORD="$(sed -n 's|^DATABASE_URL=ecto://[^:]*:\([^@]*\)@.*|\1|p' "$ENV_FILE")"
  fi
  [ -n "$DB_PASSWORD" ] || DB_PASSWORD="$(rand 32)"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  sudo -u postgres psql -c "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';" >/dev/null
  info "роль ${DB_USER} обновлена"
else
  sudo -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}' CREATEDB;" >/dev/null
  info "роль ${DB_USER} создана"
fi

if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  info "база ${DB_NAME} уже существует"
else
  sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
  info "база ${DB_NAME} создана"
fi

# ------------------------------------------------------------------ app user

step "Системный пользователь и каталоги"

if id "$APP_USER" >/dev/null 2>&1; then
  info "пользователь $APP_USER уже существует"
else
  useradd --system --create-home --home-dir "/home/$APP_USER" --shell /bin/bash "$APP_USER"
  info "создан пользователь $APP_USER"
fi

mkdir -p "$APP_HOME" "$CONFIG_DIR" "/var/log/beam-panel"
chown -R "$APP_USER:$APP_USER" "$APP_HOME" "/var/log/beam-panel"
chmod 750 "$CONFIG_DIR"

# SSH-ключ, которым панель будет ходить на дополнительные серверы
if [ ! -f "/home/$APP_USER/.ssh/id_ed25519" ]; then
  sudo -u "$APP_USER" mkdir -p "/home/$APP_USER/.ssh"
  sudo -u "$APP_USER" chmod 700 "/home/$APP_USER/.ssh"
  sudo -u "$APP_USER" ssh-keygen -t ed25519 -N '' -C "beam-control-panel" \
    -f "/home/$APP_USER/.ssh/id_ed25519" >/dev/null
  info "сгенерирован SSH-ключ для доступа к управляемым серверам"
fi

# ---------------------------------------------------------------- app config

step "Конфигурация"

if [ -f "$ENV_FILE" ]; then
  info "используем существующий $ENV_FILE"
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
else
  SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')"
  CLOAK_KEY="$(openssl rand -base64 32 | tr -d '\n')"

  cat > "$ENV_FILE" <<ENVEOF
# BEAM Control Panel — конфигурация окружения
# Сгенерировано установщиком $(date -u +%Y-%m-%dT%H:%M:%SZ)

DATABASE_URL=ecto://${DB_USER}:${DB_PASSWORD}@localhost/${DB_NAME}
POOL_SIZE=10

SECRET_KEY_BASE=${SECRET_KEY_BASE}
BEAM_PANEL_CLOAK_KEY=${CLOAK_KEY}

PHX_SERVER=true
PHX_HOST=${DOMAIN:-localhost}
PORT=${HTTP_PORT}

BEAM_PANEL_METRIC_RETENTION_DAYS=14

MIX_ENV=prod
LANG=en_US.UTF-8
RELEASE_DISTRIBUTION=none
ENVEOF

  chmod 640 "$ENV_FILE"
  chown root:"$APP_USER" "$ENV_FILE"
  info "создан $ENV_FILE"
fi

# --------------------------------------------------------------------- build

step "Сборка релиза"

BUILD_DIR="$APP_HOME/build"
mkdir -p "$BUILD_DIR"
rsync -a --delete \
  --exclude '.git' --exclude '_build' --exclude 'deps' --exclude 'node_modules' \
  --exclude 'priv/static/assets' \
  "$SOURCE_DIR"/ "$BUILD_DIR"/
chown -R "$APP_USER:$APP_USER" "$BUILD_DIR"

sudo -u "$APP_USER" env \
  HOME="/home/$APP_USER" \
  MIX_ENV=prod \
  SECRET_KEY_BASE="$(grep '^SECRET_KEY_BASE=' "$ENV_FILE" | cut -d= -f2-)" \
  DATABASE_URL="$(grep '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)" \
  bash -lc "
    set -e
    cd '$BUILD_DIR'
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    mix deps.get --only prod
    mix compile
    mix assets.setup
    mix assets.deploy
    mix release --overwrite --path '$APP_HOME/current'
  "

info "релиз собран в $APP_HOME/current"

# ------------------------------------------------------------------- systemd

step "systemd"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<UNITEOF
# Managed by BEAM Control Panel installer
[Unit]
Description=BEAM Control Panel
Documentation=https://github.com/rurumiru/BEAM-Control-Panel
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=exec
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_HOME}/current
EnvironmentFile=${ENV_FILE}
Environment=HOME=/home/${APP_USER}
ExecStartPre=${APP_HOME}/current/bin/${APP_NAME} eval BeamPanel.Release.setup
ExecStart=${APP_HOME}/current/bin/${APP_NAME} start
ExecStop=${APP_HOME}/current/bin/${APP_NAME} stop
Restart=on-failure
RestartSec=5
TimeoutStartSec=180
LimitNOFILE=65535
SyslogIdentifier=beam-panel
NoNewPrivileges=false
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${APP_HOME} /var/log/beam-panel

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
info "юнит /etc/systemd/system/${SERVICE_NAME}.service"

# ----------------------------------------------------------------- sudo prava

step "Права на управление сервером"

cat > "/etc/sudoers.d/90-beam-panel" <<SUDOEOF
# Панель управляет службами и читает журналы на локальном сервере
${APP_USER} ALL=(ALL) NOPASSWD: /bin/systemctl, /usr/bin/systemctl, /bin/journalctl, /usr/bin/journalctl, /usr/bin/apt-get, /usr/bin/install, /bin/mkdir, /bin/chown, /bin/ln
SUDOEOF
chmod 440 /etc/sudoers.d/90-beam-panel
info "выданы права sudo (systemctl, journalctl, apt-get)"

# --------------------------------------------------------------------- start

step "Запуск"

systemctl restart "${SERVICE_NAME}"
sleep 3

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  info "служба запущена"
else
  journalctl -u "${SERVICE_NAME}" -n 40 --no-pager || true
  fail "служба не запустилась — см. журнал выше"
fi

# --------------------------------------------------------------------- admin

step "Администратор"

if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(rand 20)"
  GENERATED_PASSWORD=1
else
  GENERATED_PASSWORD=0
fi

sudo -u "$APP_USER" env $(grep -v '^#' "$ENV_FILE" | xargs -d '\n') \
  "$APP_HOME/current/bin/$APP_NAME" eval \
  "BeamPanel.Release.create_admin(\"${ADMIN_EMAIL}\", \"${ADMIN_PASSWORD}\")" || \
  warn "не удалось создать администратора автоматически — воспользуйтесь мастером /setup"

# --------------------------------------------------------------------- nginx

if [ "$INSTALL_NGINX" -eq 1 ]; then
  step "nginx"

  have nginx || apt_install nginx
  systemctl enable --now nginx

  SERVER_NAME="${DOMAIN:-_}"

  cat > /etc/nginx/sites-available/beam-panel <<NGINXEOF
# Managed by BEAM Control Panel installer
map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

upstream beam_panel_upstream {
  server 127.0.0.1:${HTTP_PORT} fail_timeout=0;
}

server {
  listen 80;
  listen [::]:80;
  server_name ${SERVER_NAME};

  client_max_body_size 50m;

  location / {
    proxy_pass http://beam_panel_upstream;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
  }
}
NGINXEOF

  ln -sf /etc/nginx/sites-available/beam-panel /etc/nginx/sites-enabled/beam-panel
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx
  info "nginx настроен на порт 80 → 127.0.0.1:${HTTP_PORT}"

  if [ "$INSTALL_LETSENCRYPT" -eq 1 ]; then
    [ -n "$DOMAIN" ] || fail "--letsencrypt требует --domain"
    have certbot || apt_install certbot python3-certbot-nginx
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect \
      || warn "не удалось выпустить сертификат — проверьте DNS и повторите: certbot --nginx -d $DOMAIN"
  fi
fi

# ------------------------------------------------------------------ firewall

if have ufw; then
  step "Firewall"
  ufw allow 22/tcp   >/dev/null 2>&1 || true
  ufw allow 80/tcp   >/dev/null 2>&1 || true
  ufw allow 443/tcp  >/dev/null 2>&1 || true
  info "открыты порты 22, 80, 443"
fi

# -------------------------------------------------------------------- итоги

PUBLIC_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):${HTTP_PORT}"
[ -n "$DOMAIN" ] && PUBLIC_URL="http://${DOMAIN}"
[ "$INSTALL_LETSENCRYPT" -eq 1 ] && PUBLIC_URL="https://${DOMAIN}"

cat <<SUMMARY

╭──────────────────────────────────────────────────────────────────────────╮
│  BEAM Control Panel установлена                                          │
╰──────────────────────────────────────────────────────────────────────────╯

  URL              ${PUBLIC_URL}
  Администратор    ${ADMIN_EMAIL}
$( [ "$GENERATED_PASSWORD" -eq 1 ] && echo "  Пароль           ${ADMIN_PASSWORD}" )

  Служба           systemctl status ${SERVICE_NAME}
  Журнал           journalctl -u ${SERVICE_NAME} -f
  Конфигурация     ${ENV_FILE}
  Каталог          ${APP_HOME}/current

  Публичный SSH-ключ панели (добавьте на управляемые серверы):
$(cat "/home/$APP_USER/.ssh/id_ed25519.pub" 2>/dev/null | sed 's/^/    /')

  Приватный ключ для добавления сервера в панель:
    sudo cat /home/${APP_USER}/.ssh/id_ed25519

  Обновление:      sudo bash scripts/update.sh

SUMMARY
