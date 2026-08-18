#!/usr/bin/env bash
#
# BEAM Control Panel — подготовка узла (Ubuntu 24.04 / 26.04)
# Скрипт идемпотентен: повторный запуск безопасен.
#
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export LC_ALL=C.UTF-8

OTP_VERSION="27"
ELIXIR_VERSION="1.18.4"
NODE_VERSION="22"
PG_VERSION="16"
DEPLOY_USER="deploy"
DEPLOY_ROOT="/opt/beam"
DB_NAME="beam_app"
DB_USER="beam_app"
DB_PASSWORD="$(openssl rand -base64 24 | tr -d '\n=+/')"
SWAP_SIZE="2G"
SSH_PORT="22"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

trap 'echo; echo "!! Ошибка на строке $LINENO"; exit 1' ERR

if [ "$(id -u)" -ne 0 ]; then
  if have sudo; then SUDO="sudo -n"; else echo "Нужны права root"; exit 1; fi
else
  SUDO=""
fi

if [ -r /etc/os-release ]; then
  . /etc/os-release
  UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}}"
  info "Обнаружено: ${PRETTY_NAME:-unknown}"
  case "${VERSION_ID:-}" in
    24.04|24.10|25.04|25.10|26.04) : ;;
    *) warn "Ожидается Ubuntu 24.04+; продолжаем на свой риск." ;;
  esac
else
  UBUNTU_CODENAME="noble"
  warn "/etc/os-release не найден"
fi

APT_UPDATED=0
apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    $SUDO apt-get update -qq
    APT_UPDATED=1
  fi
}

apt_install() {
  apt_update_once
  $SUDO apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

step "Базовые пакеты"
apt_install ca-certificates curl wget gnupg lsb-release apt-transport-https \
  build-essential git unzip zip xz-utils pkg-config make automake autoconf \
  libssl-dev libncurses-dev libsctp1 libwxgtk3.2-1t64 || \
  apt_install ca-certificates curl wget gnupg lsb-release apt-transport-https \
  build-essential git unzip zip xz-utils pkg-config make libssl-dev libncurses-dev
apt_install locales tzdata rsync htop jq net-tools
$SUDO locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
info "базовые пакеты установлены"


step "Тюнинг ядра"
$SUDO tee /etc/sysctl.d/99-beam.conf >/dev/null <<'SYSCTL'
# BEAM Control Panel — сетевые и файловые лимиты
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
vm.swappiness = 10
vm.overcommit_memory = 1
SYSCTL
$SUDO sysctl --system >/dev/null 2>&1 || true

$SUDO tee /etc/security/limits.d/99-beam.conf >/dev/null <<'LIMITS'
*    soft  nofile  1048576
*    hard  nofile  1048576
root soft  nofile  1048576
root hard  nofile  1048576
LIMITS

$SUDO mkdir -p /etc/systemd/system.conf.d
$SUDO tee /etc/systemd/system.conf.d/99-beam.conf >/dev/null <<'SYSTEMD'
[Manager]
DefaultLimitNOFILE=1048576
SYSTEMD
$SUDO systemctl daemon-reexec 2>/dev/null || true
info "лимиты и sysctl применены"


step "Swap"
if swapon --show | grep -q .; then
  info "swap уже включён"
else
  $SUDO fallocate -l "$SWAP_SIZE" /swapfile || $SUDO dd if=/dev/zero of=/swapfile bs=1M count=2048
  $SUDO chmod 600 /swapfile
  $SUDO mkswap /swapfile >/dev/null
  $SUDO swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null
  info "swap $SWAP_SIZE создан"
fi


step "Erlang/OTP"
if have erl && [ "$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().')" = "$OTP_VERSION" ]; then
  info "Erlang/OTP $OTP_VERSION уже установлен"
else
  ESL_LIST=/etc/apt/sources.list.d/erlang-solutions.list
  ESL_KEY=/usr/share/keyrings/erlang-solutions.gpg

  if curl -fsSL https://binaries2.erlang-solutions.com/GPG-KEY-pmanager.asc 2>/dev/null | $SUDO gpg --dearmor -o "$ESL_KEY" 2>/dev/null; then
    echo "deb [signed-by=$ESL_KEY] https://binaries2.erlang-solutions.com/ubuntu/ ${UBUNTU_CODENAME}-esl-erlang-${OTP_VERSION} contrib" \
      | $SUDO tee "$ESL_LIST" >/dev/null
    APT_UPDATED=0
    if apt_update_once && apt_install esl-erlang; then
      info "Erlang/OTP $OTP_VERSION установлен из Erlang Solutions"
    else
      warn "репозиторий Erlang Solutions недоступен для ${UBUNTU_CODENAME}, откат на пакеты Ubuntu"
      $SUDO rm -f "$ESL_LIST"
      APT_UPDATED=0
      apt_install erlang-nox erlang-dev erlang-parsetools erlang-xmerl
    fi
  else
    warn "не удалось получить ключ Erlang Solutions, ставим пакеты Ubuntu"
    apt_install erlang-nox erlang-dev erlang-parsetools erlang-xmerl
  fi
fi
erl -noshell -eval 'io:format("    OTP ~s / erts ~s~n",[erlang:system_info(otp_release), erlang:system_info(version)]), halt().'


step "Elixir"
OTP_MAJOR="$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo "$OTP_VERSION")"

if have elixir && [ "$(elixir --short-version 2>/dev/null)" = "$ELIXIR_VERSION" ]; then
  info "Elixir $ELIXIR_VERSION уже установлен"
else
  TMP="$(mktemp -d)"
  ARCHIVE="elixir-otp-${OTP_MAJOR}.zip"
  URL="https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/${ARCHIVE}"

  if curl -fsSL -o "$TMP/elixir.zip" "$URL"; then
    $SUDO rm -rf /usr/local/elixir
    $SUDO mkdir -p /usr/local/elixir
    $SUDO unzip -qo "$TMP/elixir.zip" -d /usr/local/elixir
    for b in elixir elixirc iex mix; do
      $SUDO ln -sf "/usr/local/elixir/bin/$b" "/usr/local/bin/$b"
    done
    info "Elixir $ELIXIR_VERSION установлен (сборка под OTP $OTP_MAJOR)"
  else
    warn "precompiled-сборка под OTP $OTP_MAJOR недоступна, ставим elixir из репозитория Ubuntu"
    apt_install elixir
  fi
  rm -rf "$TMP"
fi

export HOME="${HOME:-/root}"
mix local.hex --force >/dev/null 2>&1 || true
mix local.rebar --force >/dev/null 2>&1 || true
info "Elixir: $(elixir --short-version 2>/dev/null || echo '—')"


step "Node.js"
if have node && node --version | grep -q "^v${NODE_VERSION}\."; then
  info "Node.js ${NODE_VERSION} уже установлен"
else
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | $SUDO -E bash - >/dev/null 2>&1 || \
    warn "NodeSource недоступен, ставим nodejs из Ubuntu"
  APT_UPDATED=0
  apt_install nodejs || apt_install nodejs npm
  info "Node: $(node --version 2>/dev/null || echo '—')"
fi


step "PostgreSQL"
if have psql; then
  info "PostgreSQL уже установлен: $(psql --version | awk '{print $3}')"
else
  apt_install postgresql postgresql-contrib libpq-dev
fi

$SUDO systemctl enable --now postgresql

if $SUDO -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  info "роль ${DB_USER} уже существует"
else
  $SUDO -u postgres psql -c "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASSWORD}' CREATEDB;"
  info "создана роль ${DB_USER}"
fi

if $SUDO -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  info "база ${DB_NAME} уже существует"
else
  $SUDO -u postgres createdb -O "${DB_USER}" "${DB_NAME}"
  info "создана база ${DB_NAME}"
fi

echo "    DATABASE_URL=ecto://${DB_USER}:${DB_PASSWORD}@localhost/${DB_NAME}"


step "nginx"
have nginx || apt_install nginx
$SUDO systemctl enable --now nginx
$SUDO mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

$SUDO tee /etc/nginx/conf.d/beam-panel-defaults.conf >/dev/null <<'NGINX'
# BEAM Control Panel — общие настройки проксирования
proxy_buffering off;
client_max_body_size 50m;
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}
NGINX
$SUDO nginx -t && $SUDO systemctl reload nginx
info "nginx настроен"


step "Certbot"
have certbot || apt_install certbot python3-certbot-nginx
$SUDO systemctl enable --now certbot.timer 2>/dev/null || true
info "certbot готов: certbot --nginx -d example.com"


step "Docker"
if have docker; then
  info "Docker уже установлен: $(docker --version)"
else
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  APT_UPDATED=0
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker
fi
id -nG "$DEPLOY_USER" 2>/dev/null | grep -qw docker || $SUDO usermod -aG docker "$DEPLOY_USER" 2>/dev/null || true


step "Пользователь деплоя"
if id "$DEPLOY_USER" >/dev/null 2>&1; then
  info "пользователь $DEPLOY_USER уже существует"
else
  $SUDO useradd --system --create-home --shell /bin/bash --home-dir "/home/$DEPLOY_USER" "$DEPLOY_USER"
  info "создан пользователь $DEPLOY_USER"
fi

$SUDO mkdir -p "$DEPLOY_ROOT"
$SUDO chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_ROOT"
$SUDO mkdir -p "/home/$DEPLOY_USER/.ssh"
$SUDO chmod 700 "/home/$DEPLOY_USER/.ssh"
$SUDO touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
$SUDO chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
$SUDO chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"

$SUDO tee "/etc/sudoers.d/90-$DEPLOY_USER" >/dev/null <<SUDOERS
$DEPLOY_USER ALL=(ALL) NOPASSWD: /bin/systemctl, /usr/bin/systemctl, /bin/journalctl, /usr/bin/journalctl
SUDOERS
$SUDO chmod 440 "/etc/sudoers.d/90-$DEPLOY_USER"
info "каталог деплоя: $DEPLOY_ROOT"


step "Firewall"
have ufw || apt_install ufw
$SUDO ufw --force default deny incoming
$SUDO ufw --force default allow outgoing
$SUDO ufw allow "${SSH_PORT}/tcp" comment 'SSH'
$SUDO ufw allow 80/tcp comment 'HTTP'
$SUDO ufw allow 443/tcp comment 'HTTPS'
$SUDO ufw --force enable
$SUDO ufw status numbered | sed 's/^/    /'


step "Fail2Ban"
have fail2ban-client || apt_install fail2ban
$SUDO tee /etc/fail2ban/jail.d/sshd.local >/dev/null <<JAIL
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
JAIL
$SUDO systemctl enable --now fail2ban
$SUDO systemctl restart fail2ban
info "fail2ban активен"


step "Автообновления"
apt_install unattended-upgrades
$SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'AUTO'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUTO
$SUDO systemctl enable --now unattended-upgrades
info "автообновления безопасности включены"


step "Готово"
info "Erlang:  $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo 'не установлен')"
info "Elixir:  $(elixir --short-version 2>/dev/null || echo 'не установлен')"
info "Node:    $(node --version 2>/dev/null || echo 'не установлен')"
info "Docker:  $(docker --version 2>/dev/null || echo 'не установлен')"
info "nginx:   $(nginx -v 2>&1 | awk -F/ '{print $2}' || echo 'не установлен')"
echo
echo "Узел готов к развёртыванию BEAM-приложений."
