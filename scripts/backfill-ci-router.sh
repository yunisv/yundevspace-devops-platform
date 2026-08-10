#!/usr/bin/env bash
# Одноразово проставляет ci_config_path на ВСЕ уже существующие проекты,
# чтобы они начали использовать SSDLC-пайплайн
# (config/gitlab-ci/ssdlc/ssdlc.yml, см. docs/ssdlc-pipeline.md) без
# ручного добавления include в каждый .gitlab-ci.yml.
#
# Новые проекты, созданные ПОСЛЕ того, как в Admin Area -> Settings ->
# CI/CD -> Continuous Integration and Deployment -> "Default CI/CD
# configuration file" вписано то же значение (доступно в Free
# self-managed, n8n/хуки для этого не нужны) — получают это
# автоматически при создании. Этот скрипт нужен только один раз, для
# проектов, которые уже существовали до того, как эта настройка была
# вписана.
#
# Использование:
#   GITLAB_TOKEN=<personal access token, права api, Owner/Admin на проекты> \
#     ./scripts/backfill-ci-router.sh [namespace/ci-templates-project] [файл]
#
# По умолчанию: devops/ssdlc и ssdlc.yml — поменять аргументами, если
# общий проект с policy-шлюзом называется иначе (или, если нужно
# вернуться к старому билд-роутеру: ./scripts/backfill-ci-router.sh
# devops/ci-templates universal-pipeline.yml).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

: "${GITLAB_TOKEN:?Нужен GITLAB_TOKEN (personal access token с правами api)}"

if [ ! -f .env ]; then
  echo "Нет .env — сначала ./scripts/install.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
source .env
: "${BASE_DOMAIN:?BASE_DOMAIN не задан в .env}"

CI_TEMPLATES_PROJECT="${1:-devops/ssdlc}"
CI_FILE="${2:-ssdlc.yml}"
API="https://git.${BASE_DOMAIN}/api/v4"
CI_CONFIG_PATH="${CI_FILE}@${CI_TEMPLATES_PROJECT}"

echo "Проставляю ci_config_path=${CI_CONFIG_PATH} на все существующие проекты..."

page=1
while :; do
  resp="$(curl -sS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${API}/projects?membership=true&per_page=100&page=${page}")"
  n="$(echo "$resp" | jq 'length')"
  [ "$n" -eq 0 ] && break

  echo "$resp" | jq -c '.[] | {id, path_with_namespace}' | while read -r row; do
    id="$(echo "$row" | jq -r .id)"
    path="$(echo "$row" | jq -r .path_with_namespace)"
    # Не трогаем сам проект с шаблонами — ему указывать на себя незачем.
    if [ "$path" = "$CI_TEMPLATES_PROJECT" ]; then
      echo "  пропуск $path (это сам ci-templates)"
      continue
    fi
    curl -sS -X PUT -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"ci_config_path\": \"${CI_CONFIG_PATH}\"}" \
      "${API}/projects/${id}" > /dev/null
    echo "  готово: $path (id=$id)"
  done

  page=$((page + 1))
done

echo "Готово."
