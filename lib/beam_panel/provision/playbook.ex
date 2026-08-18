defmodule BeamPanel.Provision.Playbook do
  @moduledoc """
  Generates idempotent bash for preparing a clean **Ubuntu 24.04 / 26.04** server
  to build and run BEAM applications.

  Every component is a self-contained function that can be re-run safely. The
  produced script is executed over SSH with streaming output, and is also written
  to `scripts/bootstrap-node.sh` so it can be run by hand.
  """

  @components [
    %{
      key: "base",
      name: "Базовые пакеты",
      description: "apt update, build-essential, git, curl, locales, ca-certificates",
      default: true
    },
    %{key: "tuning", name: "Тюнинг ядра", description: "sysctl и лимиты под BEAM", default: true},
    %{key: "swap", name: "Swap", description: "swapfile, если swap отсутствует", default: false},
    %{
      key: "erlang",
      name: "Erlang/OTP",
      description: "Erlang Solutions repo с откатом на репозиторий Ubuntu",
      default: true
    },
    %{
      key: "elixir",
      name: "Elixir",
      description: "официальные precompiled-сборки под нужный OTP",
      default: true
    },
    %{
      key: "nodejs",
      name: "Node.js",
      description: "NodeSource LTS для сборки ассетов",
      default: true
    },
    %{
      key: "postgres",
      name: "PostgreSQL",
      description: "сервер БД + роль и база",
      default: false
    },
    %{key: "nginx", name: "nginx", description: "reverse proxy", default: false},
    %{
      key: "certbot",
      name: "Certbot",
      description: "Let's Encrypt + плагин nginx",
      default: false
    },
    %{key: "docker", name: "Docker", description: "Docker CE + compose plugin", default: false},
    %{
      key: "deploy_user",
      name: "Пользователь деплоя",
      description: "системный пользователь и каталоги",
      default: true
    },
    %{key: "firewall", name: "Firewall", description: "ufw: 22, 80, 443", default: false},
    %{key: "fail2ban", name: "Fail2Ban", description: "защита SSH от перебора", default: false},
    %{
      key: "unattended",
      name: "Автообновления",
      description: "unattended-upgrades для security",
      default: false
    }
  ]

  @doc "All available components with metadata."
  def components, do: @components

  @doc "Keys enabled by default."
  def default_components, do: @components |> Enum.filter(& &1.default) |> Enum.map(& &1.key)

  @doc "Metadata for a single component."
  def component(key), do: Enum.find(@components, &(&1.key == key))

  @doc """
  Renders the full script.

  Options:

    * `:otp_version`      — OTP major, default `"27"`
    * `:elixir_version`   — default `"1.18.4"`
    * `:node_version`     — default `"22"`
    * `:postgres_version` — default `"16"`
    * `:deploy_user`      — default `"deploy"`
    * `:deploy_root`      — default `"/opt/beam"`
    * `:db_name`, `:db_user`, `:db_password`
    * `:swap_size`        — default `"2G"`
    * `:ssh_port`         — default `22`
  """
  def render(components, opts \\ %{}) do
    opts = normalize(opts)
    selected = Enum.filter(@components, &(&1.key in components))

    body =
      selected
      |> Enum.map_join("\n", fn %{key: key, name: name} ->
        """
        step "#{name}"
        #{render_component(key, opts)}
        """
      end)

    header(opts) <> body <> footer(opts)
  end

  defp normalize(opts) do
    opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)

    %{
      "otp_version" => blank(opts["otp_version"], "27"),
      "elixir_version" => blank(opts["elixir_version"], "1.18.4"),
      "node_version" => blank(opts["node_version"], "22"),
      "postgres_version" => blank(opts["postgres_version"], "16"),
      "deploy_user" => blank(opts["deploy_user"], "deploy"),
      "deploy_root" => blank(opts["deploy_root"], "/opt/beam"),
      "db_name" => blank(opts["db_name"], "beam_app"),
      "db_user" => blank(opts["db_user"], "beam_app"),
      "db_password" => blank(opts["db_password"], random_password()),
      "swap_size" => blank(opts["swap_size"], "2G"),
      "ssh_port" => blank(opts["ssh_port"], "22")
    }
  end

  defp blank(nil, default), do: default
  defp blank("", default), do: default
  defp blank(value, _default), do: to_string(value)

  defp random_password,
    do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)

  ## ------------------------------------------------------------------ header

  defp header(opts) do
    """
    #!/usr/bin/env bash
    #
    # BEAM Control Panel — подготовка узла (Ubuntu 24.04 / 26.04)
    # Скрипт идемпотентен: повторный запуск безопасен.
    #
    set -Eeuo pipefail

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export LC_ALL=C.UTF-8

    OTP_VERSION="#{opts["otp_version"]}"
    ELIXIR_VERSION="#{opts["elixir_version"]}"
    NODE_VERSION="#{opts["node_version"]}"
    PG_VERSION="#{opts["postgres_version"]}"
    DEPLOY_USER="#{opts["deploy_user"]}"
    DEPLOY_ROOT="#{opts["deploy_root"]}"
    DB_NAME="#{opts["db_name"]}"
    DB_USER="#{opts["db_user"]}"
    DB_PASSWORD="#{opts["db_password"]}"
    SWAP_SIZE="#{opts["swap_size"]}"
    SSH_PORT="#{opts["ssh_port"]}"

    step() { printf '\\n\\033[1;36m==> %s\\033[0m\\n' "$1"; }
    info() { printf '    %s\\n' "$1"; }
    warn() { printf '\\033[1;33m    ! %s\\033[0m\\n' "$1"; }
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

    """
  end

  defp footer(_opts) do
    """

    step "Готово"
    info "Erlang:  $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo 'не установлен')"
    info "Elixir:  $(elixir --short-version 2>/dev/null || echo 'не установлен')"
    info "Node:    $(node --version 2>/dev/null || echo 'не установлен')"
    info "Docker:  $(docker --version 2>/dev/null || echo 'не установлен')"
    info "nginx:   $(nginx -v 2>&1 | awk -F/ '{print $2}' || echo 'не установлен')"
    echo
    echo "Узел готов к развёртыванию BEAM-приложений."
    """
  end

  ## -------------------------------------------------------------- components

  defp render_component("base", _opts) do
    """
    apt_install ca-certificates curl wget gnupg lsb-release apt-transport-https \\
      build-essential git unzip zip xz-utils pkg-config make automake autoconf \\
      libssl-dev libncurses-dev libsctp1 libwxgtk3.2-1t64 || \\
      apt_install ca-certificates curl wget gnupg lsb-release apt-transport-https \\
      build-essential git unzip zip xz-utils pkg-config make libssl-dev libncurses-dev
    apt_install locales tzdata rsync htop jq net-tools
    $SUDO locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
    info "базовые пакеты установлены"
    """
  end

  defp render_component("tuning", _opts) do
    """
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
    """
  end

  defp render_component("swap", _opts) do
    """
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
    """
  end

  defp render_component("erlang", _opts) do
    """
    if have erl && [ "$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]), halt().')" = "$OTP_VERSION" ]; then
      info "Erlang/OTP $OTP_VERSION уже установлен"
    else
      ESL_LIST=/etc/apt/sources.list.d/erlang-solutions.list
      ESL_KEY=/usr/share/keyrings/erlang-solutions.gpg

      if curl -fsSL https://binaries2.erlang-solutions.com/GPG-KEY-pmanager.asc 2>/dev/null | $SUDO gpg --dearmor -o "$ESL_KEY" 2>/dev/null; then
        echo "deb [signed-by=$ESL_KEY] https://binaries2.erlang-solutions.com/ubuntu/ ${UBUNTU_CODENAME}-esl-erlang-${OTP_VERSION} contrib" \\
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
    """
  end

  defp render_component("elixir", _opts) do
    """
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
    """
  end

  defp render_component("nodejs", _opts) do
    """
    if have node && node --version | grep -q "^v${NODE_VERSION}\\."; then
      info "Node.js ${NODE_VERSION} уже установлен"
    else
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | $SUDO -E bash - >/dev/null 2>&1 || \\
        warn "NodeSource недоступен, ставим nodejs из Ubuntu"
      APT_UPDATED=0
      apt_install nodejs || apt_install nodejs npm
      info "Node: $(node --version 2>/dev/null || echo '—')"
    fi
    """
  end

  defp render_component("postgres", _opts) do
    """
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
    """
  end

  defp render_component("nginx", _opts) do
    """
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
    """
  end

  defp render_component("certbot", _opts) do
    """
    have certbot || apt_install certbot python3-certbot-nginx
    $SUDO systemctl enable --now certbot.timer 2>/dev/null || true
    info "certbot готов: certbot --nginx -d example.com"
    """
  end

  defp render_component("docker", _opts) do
    """
    if have docker; then
      info "Docker уже установлен: $(docker --version)"
    else
      $SUDO install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \\
        | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
      APT_UPDATED=0
      apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      $SUDO systemctl enable --now docker
    fi
    id -nG "$DEPLOY_USER" 2>/dev/null | grep -qw docker || $SUDO usermod -aG docker "$DEPLOY_USER" 2>/dev/null || true
    """
  end

  defp render_component("deploy_user", _opts) do
    """
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
    """
  end

  defp render_component("firewall", _opts) do
    """
    have ufw || apt_install ufw
    $SUDO ufw --force default deny incoming
    $SUDO ufw --force default allow outgoing
    $SUDO ufw allow "${SSH_PORT}/tcp" comment 'SSH'
    $SUDO ufw allow 80/tcp comment 'HTTP'
    $SUDO ufw allow 443/tcp comment 'HTTPS'
    $SUDO ufw --force enable
    $SUDO ufw status numbered | sed 's/^/    /'
    """
  end

  defp render_component("fail2ban", _opts) do
    """
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
    """
  end

  defp render_component("unattended", _opts) do
    """
    apt_install unattended-upgrades
    $SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'AUTO'
    APT::Periodic::Update-Package-Lists "1";
    APT::Periodic::Unattended-Upgrade "1";
    AUTO
    $SUDO systemctl enable --now unattended-upgrades
    info "автообновления безопасности включены"
    """
  end

  defp render_component(unknown, _opts), do: "info \"неизвестный компонент: #{unknown}\""
end
