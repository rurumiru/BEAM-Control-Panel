#!/usr/bin/env bash
#
# BEAM Control Panel — проверка установки.
#
#     sudo bash scripts/doctor.sh
#
# Проверяет всё, что должно работать после установки, и печатает отчёт.
# Код возврата: 0 — всё в порядке, 1 — есть ошибки.
# ---------------------------------------------------------------------------
set -uo pipefail

APP_NAME="beam_panel"
APP_USER="${BEAM_PANEL_USER:-beampanel}"
APP_HOME="${BEAM_PANEL_HOME:-/opt/beam-panel}"
ENV_FILE="/etc/beam-panel/beam-panel.env"
SERVICE_NAME="beam-panel"

OK=0
WARN=0
BAD=0

ok()   { printf '  \033[1;32m✓\033[0m %-38s %s\n' "$1" "${2:-}"; OK=$((OK + 1)); }
warn() { printf '  \033[1;33m!\033[0m %-38s %s\n' "$1" "${2:-}"; WARN=$((WARN + 1)); }
bad()  { printf '  \033[1;31m✗\033[0m %-38s %s\n' "$1" "${2:-}"; BAD=$((BAD + 1)); }
head_() { printf '\n\033[1;36m%s\033[0m\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || { echo "запустите от root: sudo bash $0"; exit 1; }

printf '\n\033[1mBEAM Control Panel — проверка установки\033[0m\n'

# ------------------------------------------------------------------ конфиг

head_ "Конфигурация"

if [ -f "$ENV_FILE" ]; then
  ok "файл окружения" "$ENV_FILE"
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a

  [ -n "${DATABASE_URL:-}" ] && ok "DATABASE_URL" "задан" || bad "DATABASE_URL" "не задан"
  [ -n "${SECRET_KEY_BASE:-}" ] && ok "SECRET_KEY_BASE" "задан" || bad "SECRET_KEY_BASE" "не задан"

  if [ -n "${BEAM_PANEL_CLOAK_KEY:-}" ]; then
    ok "BEAM_PANEL_CLOAK_KEY" "задан — сохраните его вместе с бэкапами"
  else
    bad "BEAM_PANEL_CLOAK_KEY" "не задан: секреты не расшифруются"
  fi

  perms="$(stat -c '%a' "$ENV_FILE")"
  case "$perms" in
    600|640) ok "права на файл окружения" "$perms" ;;
    *) warn "права на файл окружения" "$perms — ожидается 640" ;;
  esac
else
  bad "файл окружения" "$ENV_FILE не найден — панель не установлена"
fi

PORT_EFFECTIVE="${PORT:-4000}"

# ------------------------------------------------------------------- релиз

head_ "Релиз"

if [ -L "$APP_HOME/current" ]; then
  ok "current" "-> $(readlink -f "$APP_HOME/current")"
elif [ -d "$APP_HOME/current" ]; then
  warn "current" "обычный каталог, а не симлинк — обновите: scripts/update.sh"
else
  bad "current" "не найден в $APP_HOME"
fi

if [ -x "$APP_HOME/current/bin/$APP_NAME" ]; then
  ok "управляющий скрипт" "$APP_HOME/current/bin/$APP_NAME"
else
  bad "управляющий скрипт" "не найден"
fi

releases=$(ls -1d "$APP_HOME"/releases/*/ 2>/dev/null | wc -l)
[ "$releases" -gt 0 ] && ok "релизов на диске" "$releases" || warn "релизов на диске" "0"

free_kb=$(df -Pk "$APP_HOME" 2>/dev/null | tail -1 | awk '{print $4}')
free_gb=$(( ${free_kb:-0} / 1024 / 1024 ))
if [ "$free_gb" -ge 5 ]; then
  ok "свободно на диске" "${free_gb} GB"
elif [ "$free_gb" -ge 2 ]; then
  warn "свободно на диске" "${free_gb} GB — для сборки нужно ~2 GB"
else
  bad "свободно на диске" "${free_gb} GB — сборка не пройдёт"
fi

# ------------------------------------------------------------------ служба

head_ "Служба"

if systemctl is-active --quiet "$SERVICE_NAME"; then
  since=$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE_NAME" 2>/dev/null)
  ok "beam-panel" "работает с ${since:-?}"
else
  bad "beam-panel" "не работает — journalctl -xeu $SERVICE_NAME"
fi

systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null \
  && ok "автозапуск" "включён" \
  || warn "автозапуск" "выключен: systemctl enable $SERVICE_NAME"

restarts=$(systemctl show -p NRestarts --value "$SERVICE_NAME" 2>/dev/null || echo 0)
if [ "${restarts:-0}" -le 3 ]; then
  ok "перезапусков" "${restarts:-0}"
else
  warn "перезапусков" "$restarts — служба нестабильна, смотрите журнал"
fi

# ------------------------------------------------------------------- HTTP

head_ "HTTP"

if have curl; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT_EFFECTIVE}/login" || echo 000)
  case "$code" in
    200|302) ok "панель отвечает" "127.0.0.1:${PORT_EFFECTIVE} → HTTP $code" ;;
    000) bad "панель отвечает" "нет ответа на порту ${PORT_EFFECTIVE}" ;;
    *) warn "панель отвечает" "HTTP $code" ;;
  esac
else
  warn "панель отвечает" "curl не установлен, проверка пропущена"
fi

if have nginx; then
  systemctl is-active --quiet nginx && ok "nginx" "работает" || warn "nginx" "не работает"
  nginx -t >/dev/null 2>&1 && ok "конфигурация nginx" "корректна" || bad "конфигурация nginx" "nginx -t падает"

  site=/etc/nginx/sites-enabled/beam-panel
  [ -e "$site" ] && ok "сайт панели" "$site" || warn "сайт панели" "не подключён"
else
  warn "nginx" "не установлен — панель доступна только по порту ${PORT_EFFECTIVE}"
fi

# --------------------------------------------------------------------- TLS

head_ "TLS"

cert_dir=$(ls -1d /etc/letsencrypt/live/*/ 2>/dev/null | head -1)

if [ -n "$cert_dir" ] && [ -f "${cert_dir}fullchain.pem" ]; then
  end=$(openssl x509 -enddate -noout -in "${cert_dir}fullchain.pem" 2>/dev/null | cut -d= -f2)
  end_ts=$(date -d "$end" +%s 2>/dev/null || echo 0)
  days=$(( (end_ts - $(date +%s)) / 86400 ))

  if [ "$days" -gt 20 ]; then
    ok "сертификат" "действителен ещё $days дн."
  elif [ "$days" -gt 0 ]; then
    warn "сертификат" "истекает через $days дн."
  else
    bad "сертификат" "истёк"
  fi

  systemctl is-enabled --quiet certbot.timer 2>/dev/null \
    && ok "автопродление" "certbot.timer включён" \
    || warn "автопродление" "certbot.timer выключен"
else
  warn "сертификат" "не выпущен — работаете по HTTP"
fi

# --------------------------------------------------------------- база данных

head_ "База данных"

if systemctl is-active --quiet postgresql; then
  ok "postgresql" "работает"
else
  bad "postgresql" "не работает"
fi

if [ -x "$APP_HOME/current/bin/$APP_NAME" ] && [ -n "${DATABASE_URL:-}" ]; then
  users=$(sudo -u "$APP_USER" \
    DATABASE_URL="$DATABASE_URL" \
    SECRET_KEY_BASE="${SECRET_KEY_BASE:-}" \
    BEAM_PANEL_CLOAK_KEY="${BEAM_PANEL_CLOAK_KEY:-}" \
    RELEASE_DISTRIBUTION=none HOME="/home/$APP_USER" \
    "$APP_HOME/current/bin/$APP_NAME" eval \
    'BeamPanel.Release.count_users() |> IO.puts()' 2>/dev/null | tail -1)

  if [[ "$users" =~ ^[0-9]+$ ]]; then
    ok "подключение к базе" "работает"

    if [ "$users" -gt 0 ]; then
      ok "администратор" "пользователей: $users"
    else
      warn "администратор" "нет ни одного — откройте /setup"
    fi
  else
    bad "подключение к базе" "release-задача не отработала"
  fi
fi

backups=$(ls -1 /var/backups/beam-panel-*.sql.gz 2>/dev/null | wc -l)
[ "$backups" -gt 0 ] && ok "резервные копии" "$backups шт. в /var/backups" \
  || warn "резервные копии" "нет ни одной"

systemctl is-enabled --quiet beam-panel-backup.timer 2>/dev/null \
  && ok "автобэкап" "beam-panel-backup.timer включён" \
  || warn "автобэкап" "таймер не настроен — обновите установку"

# ------------------------------------------------------------------- права

head_ "Права и доступы"

if id "$APP_USER" >/dev/null 2>&1; then
  ok "пользователь панели" "$APP_USER"
else
  bad "пользователь панели" "$APP_USER не существует"
fi

if sudo -u "$APP_USER" sudo -n true 2>/dev/null; then
  ok "беспарольный sudo" "работает — деплой и провижининг доступны"
else
  bad "беспарольный sudo" "не работает: деплой на основной сервер будет падать"
fi

key="/home/$APP_USER/.ssh/id_ed25519"
if [ -f "$key" ]; then
  ok "SSH-ключ панели" "$key"
  printf '      публичный: %s\n' "$(cat "$key.pub" 2>/dev/null || echo '—')"
else
  warn "SSH-ключ панели" "не создан — управляемые серверы придётся подключать своим ключом"
fi

# ------------------------------------------------------------------- итоги

printf '\n\033[1mИтого:\033[0m \033[1;32m%d в порядке\033[0m, \033[1;33m%d предупреждений\033[0m, \033[1;31m%d ошибок\033[0m\n\n' \
  "$OK" "$WARN" "$BAD"

if [ "$BAD" -gt 0 ]; then
  echo "Есть ошибки. Подробности в журнале: journalctl -xeu $SERVICE_NAME"
  exit 1
fi

echo "Установка исправна."
exit 0
