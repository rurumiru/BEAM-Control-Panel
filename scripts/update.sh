#!/usr/bin/env bash
#
# BEAM Control Panel — обновление установленной панели.
#
#     sudo bash scripts/update.sh                    # пересобрать из текущего каталога
#     sudo bash scripts/update.sh --pull             # сначала подтянуть изменения
#     sudo bash scripts/update.sh --pull --stash-local  # спрятать свои правки и обновиться
#
set -Eeuo pipefail

APP_NAME="beam_panel"
APP_USER="${BEAM_PANEL_USER:-beampanel}"
APP_HOME="${BEAM_PANEL_HOME:-/opt/beam-panel}"
ENV_FILE="/etc/beam-panel/beam-panel.env"
SERVICE_NAME="beam-panel"
PULL=0
STASH_LOCAL=0

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m!! %s\033[0m\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE'
BEAM Control Panel — обновление установленной панели

  --pull           подтянуть изменения из git перед сборкой
  --stash-local    спрятать локальные правки в git stash и продолжить
  -h, --help       показать эту справку
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pull)        PULL=1; shift ;;
    --stash-local) STASH_LOCAL=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) fail "неизвестный параметр: $1 (см. --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || fail "запустите от root"
[ -f "$ENV_FILE" ] || fail "$ENV_FILE не найден — сначала выполните scripts/install-ubuntu.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(dirname "$SCRIPT_DIR")"

if [ "$PULL" -eq 1 ]; then
  step "Обновление исходников"

  git -C "$SOURCE_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || fail "$SOURCE_DIR не является git-репозиторием — обновите исходники вручную"

  # `git pull` откажется работать при незакоммиченных правках. Молча выбрасывать
  # чужие изменения нельзя, поэтому по умолчанию останавливаемся и показываем,
  # что именно изменено и какие есть варианты.
  DIRTY="$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=no)"

  if [ -n "$DIRTY" ]; then
    if [ "$STASH_LOCAL" -eq 1 ]; then
      git -C "$SOURCE_DIR" stash push -u \
        -m "beam-panel update $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
      warn "локальные правки спрятаны, вернуть: git -C $SOURCE_DIR stash pop"
    else
      echo
      warn "в $SOURCE_DIR есть незакоммиченные изменения:"
      printf '%s\n' "$DIRTY" | sed 's/^/      /'
      echo
      warn "посмотреть их:  git -C $SOURCE_DIR diff"
      warn "сохранить:      sudo bash scripts/update.sh --pull --stash-local"
      warn "выбросить:      git -C $SOURCE_DIR checkout -- . && sudo bash $0 --pull"
      echo
      fail "обновление остановлено, чтобы не потерять ваши правки"
    fi
  fi

  git -C "$SOURCE_DIR" pull --ff-only
  info "исходники на коммите $(git -C "$SOURCE_DIR" rev-parse --short HEAD)"
fi

step "Резервная копия базы"
BACKUP="/var/backups/beam-panel-$(date -u +%Y%m%d%H%M%S).sql.gz"
mkdir -p /var/backups
DB_URL="$(grep '^DATABASE_URL=' "$ENV_FILE" | cut -d= -f2-)"
if command -v pg_dump >/dev/null 2>&1; then
  DB_NAME="${DB_URL##*/}"
  sudo -u postgres pg_dump "$DB_NAME" | gzip > "$BACKUP" && info "$BACKUP" || info "резервная копия пропущена"
fi

step "Сборка новой версии"
BUILD_DIR="$APP_HOME/build"
mkdir -p "$BUILD_DIR"
rsync -a --delete \
  --exclude '.git' --exclude '_build' --exclude 'deps' --exclude 'node_modules' \
  --exclude 'priv/static/assets' \
  "$SOURCE_DIR"/ "$BUILD_DIR"/
chown -R "$APP_USER:$APP_USER" "$BUILD_DIR"

NEW_RELEASE="$APP_HOME/releases/$(date -u +%Y%m%d%H%M%S)"
mkdir -p "$(dirname "$NEW_RELEASE")"

sudo -u "$APP_USER" env \
  HOME="/home/$APP_USER" \
  MIX_ENV=prod \
  SECRET_KEY_BASE="$(grep '^SECRET_KEY_BASE=' "$ENV_FILE" | cut -d= -f2-)" \
  DATABASE_URL="$DB_URL" \
  bash -lc "
    set -e
    cd '$BUILD_DIR'
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    mix deps.get --only prod
    mix compile
    mix assets.setup
    mix assets.deploy
    mix release --overwrite --path '$NEW_RELEASE'
  "

step "Права на управление сервером"

# Обновляем правило sudo: старые установки выдавали доступ к списку бинарников,
# из-за чего деплой и провижининг основного сервера падали с
# "sudo: no password was provided".
cat > "/etc/sudoers.d/90-beam-panel" <<SUDOEOF
# BEAM Control Panel — управление локальным сервером без запроса пароля.
${APP_USER} ALL=(ALL) NOPASSWD: ALL
SUDOEOF
chmod 440 /etc/sudoers.d/90-beam-panel
visudo -cf /etc/sudoers.d/90-beam-panel >/dev/null || fail "sudoers-файл некорректен"

if sudo -u "$APP_USER" sudo -n true 2>/dev/null; then
  info "беспарольный sudo для ${APP_USER} работает"
else
  warn "sudo -n для ${APP_USER} не работает — деплой на основной сервер будет падать"
fi

step "Переключение"
PREVIOUS="$(readlink -f "$APP_HOME/current" 2>/dev/null || true)"
ln -sfn "$NEW_RELEASE" "$APP_HOME/current"
chown -h "$APP_USER:$APP_USER" "$APP_HOME/current"

# `|| true`: иначе set -e прервёт скрипт до того, как мы покажем журнал и откатимся
systemctl restart "$SERVICE_NAME" || true
sleep 4

if systemctl is-active --quiet "$SERVICE_NAME"; then
  info "обновление применено: $NEW_RELEASE"
  ls -1dt "$APP_HOME"/releases/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf
else
  printf '\033[1;33m!! служба не поднялась — откат\033[0m\n'
  if [ -n "$PREVIOUS" ] && [ -d "$PREVIOUS" ]; then
    ln -sfn "$PREVIOUS" "$APP_HOME/current"
    systemctl restart "$SERVICE_NAME"
    info "откат на $PREVIOUS выполнен"
  fi
  journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
  exit 1
fi
