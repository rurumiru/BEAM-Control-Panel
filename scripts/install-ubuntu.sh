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
LE_EMAIL="${LE_EMAIL:-}"

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
  --email <email>        e-mail для Let's Encrypt (по умолчанию --admin-email)
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
    --email)          LE_EMAIL="$2"; shift 2 ;;
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

# Проверяем параметры до установки пакетов и сборки релиза: узнать про
# неправильный e-mail через десять минут работы скрипта — плохой сценарий.
valid_email() {
  printf '%s' "$1" | grep -qE '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$'
}

if [ "$INSTALL_LETSENCRYPT" -eq 1 ]; then
  [ -n "$DOMAIN" ] || fail "--letsencrypt требует --domain"

  LE_EMAIL="${LE_EMAIL:-$ADMIN_EMAIL}"

  if ! valid_email "$LE_EMAIL"; then
    fail "Let's Encrypt отклонит адрес «$LE_EMAIL».
Укажите настоящий e-mail: --email you@example.com
(или запустите без --letsencrypt и выпустите сертификат позже:
 certbot --nginx -d $DOMAIN -m you@example.com --agree-tos)"
  fi
fi

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

# Ubuntu запускает unattended-upgrades в фоне и держит блокировку dpkg —
# без ожидания установка падает с "Could not get lock /var/lib/dpkg/lock-frontend".
apt_locked() {
  if have fuser; then
    fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock \
      >/dev/null 2>&1
  else
    # psmisc may not be installed yet on a truly minimal image
    pgrep -f '(unattended-upgrade|apt-get|aptitude|/usr/bin/dpkg)' >/dev/null 2>&1
  fi
}

wait_for_apt() {
  local waited=0 limit=300

  while apt_locked; do
    [ "$waited" -eq 0 ] && warn "apt занят другим процессом (обычно unattended-upgrades), ждём…"

    sleep 5
    waited=$((waited + 5))

    if [ "$waited" -ge "$limit" ]; then
      warn "ждём уже ${limit}с — продолжаем; если apt-get упадёт по блокировке, выполните:"
      warn "  sudo systemctl stop unattended-upgrades && sudo dpkg --configure -a"
      break
    fi
  done

  [ "$waited" -eq 0 ] || info "apt освободился через ${waited}с"
}

APT_UPDATED=0
apt_update_once() {
  [ "$APT_UPDATED" -eq 1 ] && return 0
  wait_for_apt
  apt-get update -qq
  APT_UPDATED=1
}
apt_install() {
  apt_update_once
  wait_for_apt
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
      | gpg --batch --yes --dearmor -o "$ESL_KEY" 2>/dev/null; then
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

ACTUAL_OTP="$(current_otp)"
info "установлен OTP $ACTUAL_OTP"

if [ -n "$ACTUAL_OTP" ] && [ "$ACTUAL_OTP" != "$OTP_VERSION" ]; then
  warn "запрошен OTP $OTP_VERSION, доступен только $ACTUAL_OTP"
  warn "Elixir будет поставлен в сборке под OTP $ACTUAL_OTP — это рабочая конфигурация"
  OTP_VERSION="$ACTUAL_OTP"
fi

# -------------------------------------------------------------------- elixir

step "Elixir $ELIXIR_VERSION"

OTP_MAJOR="$(current_otp)"
MARKER="/usr/local/elixir/.beam-panel-build"
WANT="${ELIXIR_VERSION}-otp-${OTP_MAJOR}"

# Elixir ships one build per OTP major; a build made for another OTP produces
# .beam files the running VM refuses to load. The marker records which pair is
# installed so a changed OTP always triggers a reinstall.
elixir_healthy() {
  [ "$(cat "$MARKER" 2>/dev/null)" = "$WANT" ] || return 1
  elixir -e 'IO.puts(:erlang.system_info(:otp_release))' >/dev/null 2>&1
}

if elixir_healthy; then
  info "уже установлен ($WANT)"
else
  TMP="$(mktemp -d)"
  URL="https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${OTP_MAJOR}.zip"
  info "качаем elixir-otp-${OTP_MAJOR}.zip (v${ELIXIR_VERSION})"

  if curl -fsSL -o "$TMP/elixir.zip" "$URL"; then
    rm -rf /usr/local/elixir
    mkdir -p /usr/local/elixir
    unzip -qo "$TMP/elixir.zip" -d /usr/local/elixir
    for b in elixir elixirc iex mix; do ln -sf "/usr/local/elixir/bin/$b" "/usr/local/bin/$b"; done
    printf '%s' "$WANT" > "$MARKER"
    info "установлен из официальной сборки под OTP $OTP_MAJOR"
  else
    warn "сборка Elixir ${ELIXIR_VERSION} под OTP ${OTP_MAJOR} недоступна"
    warn "ставим elixir из репозитория Ubuntu (версия может быть старее)"
    apt_install elixir
  fi
  rm -rf "$TMP"
fi

have mix || fail "Elixir не установился"

# Проверяем, что связка Elixir+OTP действительно рабочая, до долгой сборки.
if ! elixir -e 'IO.puts(:erlang.system_info(:otp_release))' >/dev/null 2>&1; then
  fail "Elixir не запускается на установленном OTP ${OTP_MAJOR}.
Удалите /usr/local/elixir и запустите установщик снова, либо укажите
подходящую версию: --elixir <версия> --otp ${OTP_MAJOR}"
fi

ELIXIR_MINOR="$(elixir --short-version | cut -d. -f1,2)"
case "$ELIXIR_MINOR" in
  1.1[89]|1.2*) : ;;
  *) fail "нужен Elixir 1.18 или новее, установлен $(elixir --short-version)" ;;
esac

info "Elixir $(elixir --short-version) на OTP $OTP_MAJOR"

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

# На PostgreSQL 15+ схема public закрыта для всех, кроме владельца БД, а база
# могла быть создана раньше с другим владельцем — выравниваем права явно.
sudo -u postgres psql -q -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};" >/dev/null
sudo -u postgres psql -q -d "${DB_NAME}" -c "GRANT ALL ON SCHEMA public TO ${DB_USER};" >/dev/null
sudo -u postgres psql -q -d "${DB_NAME}" -c "ALTER SCHEMA public OWNER TO ${DB_USER};" >/dev/null 2>&1 || true
info "права на базу выданы роли ${DB_USER}"

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
RELEASE_DIR="$APP_HOME/releases/$(date -u +%Y%m%d%H%M%S)"

mkdir -p "$BUILD_DIR" "$APP_HOME/releases"

rsync -a --delete \
  --exclude '.git' --exclude '_build' --exclude 'deps' --exclude 'node_modules' \
  --exclude 'priv/static/assets' \
  "$SOURCE_DIR"/ "$BUILD_DIR"/

# Сборка идёт от имени пользователя панели, а mix release сам создаёт подкаталоги
# внутри releases/<версия>. Каталоги, созданные здесь под root, обязательно
# передаём ему, иначе сборка падает на mkdir.
chown -R "$APP_USER:$APP_USER" "$BUILD_DIR" "$APP_HOME/releases"

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
    mix release --overwrite --path '$RELEASE_DIR'
  "

# Установки прежнего формата держали в current настоящий каталог. `ln -s` в
# такой каталог создал бы ссылку ВНУТРИ него, и служба молча осталась бы на
# старом коде — поэтому убираем его в сторону.
if [ -e "$APP_HOME/current" ] && [ ! -L "$APP_HOME/current" ]; then
  LEGACY_DIR="$APP_HOME/current.replaced.$(date -u +%Y%m%d%H%M%S)"
  mv "$APP_HOME/current" "$LEGACY_DIR"
  info "прежний каталог current сохранён как $LEGACY_DIR"
fi

ln -sfn "$RELEASE_DIR" "$APP_HOME/current"
chown -h "$APP_USER:$APP_USER" "$APP_HOME/current"

# держим последние пять релизов
ls -1dt "$APP_HOME"/releases/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf

info "релиз собран: $RELEASE_DIR"
info "current -> $(readlink -f "$APP_HOME/current")"

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

# Панель — это средство администрирования сервера: она создаёт каталоги
# деплоя, ставит пакеты, пишет systemd-юниты, управляет службами и читает
# журналы. Все эти действия выполняются как `sudo -n bash -lc '<команда>'`,
# поэтому список отдельных бинарников не работает — нужен полный NOPASSWD.
# Права внутри панели ограничены ролями (viewer / operator / admin), каждое
# действие пишется в аудит.
cat > "/etc/sudoers.d/90-beam-panel" <<SUDOEOF
# BEAM Control Panel — управление локальным сервером без запроса пароля.
# Удалите этот файл, если панель не должна администрировать основной сервер;
# управление удалёнными узлами по SSH продолжит работать.
${APP_USER} ALL=(ALL) NOPASSWD: ALL
SUDOEOF
chmod 440 /etc/sudoers.d/90-beam-panel
visudo -cf /etc/sudoers.d/90-beam-panel >/dev/null || fail "sudoers-файл получился некорректным"

# Проверяем, что беспарольный sudo действительно работает — именно на этом
# спотыкались деплой и провижининг основного сервера.
if sudo -u "$APP_USER" sudo -n true 2>/dev/null; then
  info "беспарольный sudo для ${APP_USER} работает"
else
  warn "sudo -n для ${APP_USER} не работает — деплой на основной сервер будет падать"
  warn "проверьте /etc/sudoers.d/90-beam-panel и что в /etc/sudoers есть #includedir /etc/sudoers.d"
fi

# ------------------------------------------------------------- автобэкап БД

step "Автоматические резервные копии"

cat > /usr/local/bin/beam-panel-backup <<'BACKUPEOF'
#!/usr/bin/env bash
# Ночной дамп базы панели. Хранится 14 дней.
set -euo pipefail

ENV_FILE=/etc/beam-panel/beam-panel.env
DEST=/var/backups
KEEP_DAYS=14

[ -f "$ENV_FILE" ] || exit 0
DB_URL="$(grep '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)"
DB_NAME="${DB_URL##*/}"

mkdir -p "$DEST"
sudo -u postgres pg_dump "$DB_NAME" | gzip > "$DEST/beam-panel-$(date -u +%Y%m%d%H%M%S).sql.gz"
find "$DEST" -name 'beam-panel-*.sql.gz' -mtime +$KEEP_DAYS -delete
BACKUPEOF
chmod 755 /usr/local/bin/beam-panel-backup

cat > /etc/systemd/system/beam-panel-backup.service <<'UNITEOF'
[Unit]
Description=BEAM Control Panel — резервная копия базы
After=postgresql.service
Requires=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/beam-panel-backup
UNITEOF

cat > /etc/systemd/system/beam-panel-backup.timer <<'TIMEREOF'
[Unit]
Description=Ежедневная резервная копия базы BEAM Control Panel

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable --now beam-panel-backup.timer >/dev/null 2>&1 || true
info "ежедневный дамп в /var/backups, хранение 14 дней"

# --------------------------------------------------------------------- start

step "Запуск"

# `|| true`: без этого ERR-trap срабатывает раньше, чем мы покажем журнал,
# и оператор видит только "ошибка на строке N".
systemctl restart "${SERVICE_NAME}" || true
sleep 4

if systemctl is-active --quiet "${SERVICE_NAME}"; then
  info "служба запущена"
else
  echo
  warn "служба не запустилась, последние 60 строк журнала:"
  echo "------------------------------------------------------------------"
  journalctl -u "${SERVICE_NAME}" -n 60 --no-pager 2>&1 | sed 's/^/  /' || true
  echo "------------------------------------------------------------------"
  echo
  fail "запуск не удался — журнал выше. Полный вывод: journalctl -xeu ${SERVICE_NAME}"
fi

# --------------------------------------------------------------------- admin

step "Администратор"

if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(rand 20)"
  GENERATED_PASSWORD=1
else
  GENERATED_PASSWORD=0
fi

# Значения в env-файле содержат base64 с +/= и могут содержать пробелы —
# читаем их через `source`, а не через `xargs`, и передаём поимённо.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

ADMIN_CREATED=0

if sudo -u "$APP_USER" \
     DATABASE_URL="$DATABASE_URL" \
     SECRET_KEY_BASE="$SECRET_KEY_BASE" \
     BEAM_PANEL_CLOAK_KEY="$BEAM_PANEL_CLOAK_KEY" \
     PHX_HOST="${PHX_HOST:-localhost}" \
     PORT="${PORT:-$HTTP_PORT}" \
     RELEASE_DISTRIBUTION=none \
     HOME="/home/$APP_USER" \
     "$APP_HOME/current/bin/$APP_NAME" eval \
     "BeamPanel.Release.create_admin(\"${ADMIN_EMAIL}\", \"${ADMIN_PASSWORD}\")"; then
  ADMIN_CREATED=1
else
  GENERATED_PASSWORD=0
  warn "не удалось создать администратора автоматически"
  warn "создайте его через мастер первого запуска: /setup"
fi

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
    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
         -m "$LE_EMAIL" --no-eff-email --redirect; then
      info "сертификат выпущен, HTTPS включён"
      CERT_ISSUED=1
    else
      warn "не удалось выпустить сертификат"
      warn "убедитесь, что A-запись $DOMAIN указывает на этот сервер, затем повторите:"
      warn "  certbot --nginx -d $DOMAIN -m $LE_EMAIL --agree-tos --no-eff-email --redirect"
    fi
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

CERT_ISSUED="${CERT_ISSUED:-0}"

PUBLIC_URL="http://$(hostname -I 2>/dev/null | awk '{print $1}'):${HTTP_PORT}"
[ -n "$DOMAIN" ] && PUBLIC_URL="http://${DOMAIN}"
[ "$CERT_ISSUED" -eq 1 ] && PUBLIC_URL="https://${DOMAIN}"

cat <<SUMMARY

╭──────────────────────────────────────────────────────────────────────────╮
│  BEAM Control Panel установлена                                          │
╰──────────────────────────────────────────────────────────────────────────╯

  URL              ${PUBLIC_URL}
  Администратор    ${ADMIN_EMAIL}
$( [ "$GENERATED_PASSWORD" -eq 1 ] && [ "$ADMIN_CREATED" -eq 1 ] && echo "  Пароль           ${ADMIN_PASSWORD}" )
$( [ "$ADMIN_CREATED" -eq 0 ] && echo "  Первый вход      откройте ${PUBLIC_URL}/setup и создайте администратора" )

  Служба           systemctl status ${SERVICE_NAME}
  Журнал           journalctl -u ${SERVICE_NAME} -f
  Конфигурация     ${ENV_FILE}
  Каталог          ${APP_HOME}/current

  Публичный SSH-ключ панели (добавьте на управляемые серверы):
$(cat "/home/$APP_USER/.ssh/id_ed25519.pub" 2>/dev/null | sed 's/^/    /')

  Приватный ключ для добавления сервера в панель:
    sudo cat /home/${APP_USER}/.ssh/id_ed25519

  Обновление:      sudo bash scripts/update.sh
  Проверка:        sudo bash scripts/doctor.sh

SUMMARY

# Финальная самопроверка: лучше узнать о проблеме сейчас, чем через неделю.
if [ -f "$SOURCE_DIR/scripts/doctor.sh" ]; then
  bash "$SOURCE_DIR/scripts/doctor.sh" || true
fi
