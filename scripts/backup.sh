#!/usr/bin/env bash
# Backs up everything that isn't trivially recreatable: GitLab (repos, DB,
# wiki, CI config — via GitLab's own backup command, not a raw volume copy,
# since copying a live Postgres data directory risks an inconsistent
# snapshot), Keycloak's database, Traefik's TLS state, and .env/secrets.
#
# Usage: ./scripts/backup.sh [destination-dir]   (default: ./backups)
#
# This writes to a directory ON THIS SERVER. That is not a backup by
# itself — copy the resulting archive off this machine (rsync/rclone/scp to
# another host, or object storage) or it doesn't survive the server dying.
# Restore procedure: docs/backups.md
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DEST="${1:-./backups}"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if [ ! -f .env ]; then
  echo "Нет .env в текущей директории — запускайте из корня devops-platform." >&2
  exit 1
fi
# shellcheck disable=SC1091
source .env

mkdir -p "$DEST"
log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }

CORE=(-f docker-compose.yml)
GITLAB=("${CORE[@]}" -f docker-compose.gitlab.yml)

log "GitLab: gitlab-backup create (SKIP=artifacts,registry — см. docs/backups.md, чтобы включить их)"
docker compose "${GITLAB[@]}" exec -T gitlab gitlab-backup create SKIP=artifacts,registry 2>&1 | tail -20

latest="$(docker compose "${GITLAB[@]}" exec -T gitlab sh -c 'ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar 2>/dev/null | head -1' | tr -d '\r')"
if [ -n "$latest" ]; then
  docker compose "${GITLAB[@]}" cp "gitlab:${latest}" "$WORKDIR/gitlab_backup.tar"
else
  echo "WARNING: не нашёл файл бэкапа GitLab — смотрите вывод gitlab-backup create выше." >&2
fi

# gitlab-backup create намеренно НЕ включает секреты — без них восстановить
# бэкап на другом сервере невозможно (расшифровка CI-переменных и т.п.).
docker compose "${GITLAB[@]}" cp gitlab:/etc/gitlab/gitlab-secrets.json "$WORKDIR/gitlab-secrets.json" 2>/dev/null || true
docker compose "${GITLAB[@]}" cp gitlab:/etc/gitlab/gitlab.rb "$WORKDIR/gitlab.rb" 2>/dev/null || true

log "Keycloak: дамп базы"
docker compose "${CORE[@]}" exec -T -e PGPASSWORD="${KEYCLOAK_DB_PASSWORD}" keycloak-db \
  pg_dump -U keycloak keycloak > "$WORKDIR/keycloak-db.sql"

log "Traefik: TLS-состояние (acme.json — сертификат и его приватный ключ)"
docker compose "${CORE[@]}" cp traefik:/acme/acme.json "$WORKDIR/acme.json" 2>/dev/null || true

log "Конфигурация платформы (.env, secrets/)"
cp .env "$WORKDIR/.env"
[ -d secrets ] && cp -r secrets "$WORKDIR/secrets"

log "Собираю архив"
archive="$DEST/devops-platform-backup-$STAMP.tar.gz"
tar -C "$WORKDIR" -czf "$archive" .
chmod 600 "$archive"

echo
echo "Готово: $archive ($(du -h "$archive" | cut -f1))"
echo "Это резервная копия НА ЭТОМ ЖЕ сервере — скопируйте её куда-то ещё"
echo "(rsync/rclone/scp на другую машину, объектное хранилище). Копия, которая"
echo "никогда не покидает сервер, не переживёт его потерю."

# Локально держим последние 7 — расчёт на то, что настоящая копия уже унесена.
find "$DEST" -maxdepth 1 -name 'devops-platform-backup-*.tar.gz' -mtime +7 -delete
