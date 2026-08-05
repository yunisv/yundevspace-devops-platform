#!/usr/bin/env bash
# One-shot bootstrap for a fresh server: checks/installs Docker, prepares
# the devops_edge network and sysctl settings, generates .env with random
# secrets, and brings the platform up. Idempotent — safe to re-run (skips
# steps that are already done, never overwrites an existing .env).
#
# Usage (as root):
#   ./scripts/install.sh                                # gitlab + monitoring + automation
#   ./scripts/install.sh --minimal                       # core + gitlab only
#   ./scripts/install.sh --layers="gitlab automation"    # pick specific layers
#
# Non-interactive: export BASE_DOMAIN and ACME_EMAIL before running.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LAYERS="gitlab monitoring automation"
for arg in "$@"; do
  case "$arg" in
    --minimal) LAYERS="gitlab" ;;
    --layers=*) LAYERS="${arg#--layers=}" ;;
    -h|--help)
      echo "Usage: $0 [--minimal] [--layers=\"gitlab monitoring automation\"]"
      exit 0
      ;;
    *)
      echo "Неизвестный аргумент: $arg" >&2
      exit 1
      ;;
  esac
done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$1" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Запускать от root (sudo ./scripts/install.sh) — нужно ставить пакеты и sysctl." >&2
  exit 1
fi

# --- 1. OS check ---------------------------------------------------------
if [ ! -f /etc/os-release ]; then
  echo "Не удалось определить ОС (/etc/os-release отсутствует)." >&2
  exit 1
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *)
    echo "ОС '${ID:-unknown}' не поддерживается этим скриптом (только Ubuntu/Debian)." >&2
    echo "Поставьте Docker Engine + Compose plugin вручную и запустите ./scripts/up.sh напрямую." >&2
    exit 1
    ;;
esac

# --- 2. Base packages -----------------------------------------------------
log "Базовые пакеты (curl, openssl, apache2-utils)"
apt-get update -y
apt-get install -y --no-install-recommends curl ca-certificates openssl apache2-utils

# --- 3. Docker + Compose plugin -------------------------------------------
log "Проверка Docker"
if ! command -v docker >/dev/null 2>&1; then
  log "Docker не найден — устанавливаю (официальный скрипт get.docker.com)"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  echo "Docker уже установлен: $(docker --version)"
fi

if ! docker compose version >/dev/null 2>&1; then
  log "Docker Compose plugin не найден — устанавливаю"
  apt-get install -y docker-compose-plugin
fi

# --- 4. sysctl (нужно для будущих OpenSearch/Elasticsearch-компонентов, --
#        например если позже подключите Plane с полнотекстовым поиском) ---
log "Настройка vm.max_map_count"
current_map_count="$(sysctl -n vm.max_map_count)"
if [ "$current_map_count" -lt 262144 ]; then
  echo "vm.max_map_count=262144" > /etc/sysctl.d/99-devops-platform.conf
  sysctl --system >/dev/null
  echo "Выставлено 262144 (было ${current_map_count})"
else
  echo "Уже ${current_map_count} (>= 262144) — пропускаю"
fi

# --- 5. Docker-сеть --------------------------------------------------------
log "Docker-сеть devops_edge"
if docker network inspect devops_edge >/dev/null 2>&1; then
  echo "Уже существует"
else
  docker network create devops_edge
  echo "Создана"
fi

# --- 6. Firewall -----------------------------------------------------------
# Порты намеренно НЕ открываются здесь: цель — закрытый наружу сервер с
# доступом через VPN. Ограничения накатываются отдельно ./scripts/harden.sh,
# уже после того как VPN поднят и проверен (иначе легко запереть себя).
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "ufw активен — проверяю, что 443 открыт (нужен для выдачи доступа в VPN)"
  ufw allow 443/tcp >/dev/null
else
  warn "ufw не активен. Итоговую блокировку портов накатите ./scripts/harden.sh после установки VPN (docs/vpn-netbird.md)."
fi

# --- 7. .env + секреты ------------------------------------------------------
mkdir -p secrets

if [ ! -f .env ]; then
  log ".env не найден — создаю и генерирую секреты"
  cp .env.example .env

  domain="${BASE_DOMAIN:-}"
  email="${ACME_EMAIL:-}"
  if [ -z "$domain" ] && [ -t 0 ]; then
    read -rp "Домен для платформы (BASE_DOMAIN, напр. devops.company.com): " domain
  fi
  if [ -z "$email" ] && [ -t 0 ]; then
    read -rp "Email для Let's Encrypt (ACME_EMAIL): " email
  fi
  if [ -z "$domain" ] || [ -z "$email" ]; then
    echo "BASE_DOMAIN и ACME_EMAIL обязательны (передайте как env-переменные для неинтерактивного запуска)." >&2
    exit 1
  fi

  sed -i "s#^BASE_DOMAIN=.*#BASE_DOMAIN=${domain}#" .env
  sed -i "s#^ACME_EMAIL=.*#ACME_EMAIL=${email}#" .env

  # Все "change-me..." значения из .env.example заменяются на случайные секреты.
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    if [[ "$value" == change-me* ]]; then
      secret="$(openssl rand -hex 24)"
      sed -i "s#^${key}=.*#${key}=${secret}#" .env
    fi
  done < .env.example

  # oauth2-proxy требует cookie secret ровно 16/24/32 байта в base64 —
  # обычный hex-секрет тут не подойдёт.
  cookie_secret="$(openssl rand -base64 32 | tr -- '+/' '-_')"
  sed -i "s#^OAUTH2_PROXY_COOKIE_SECRET=.*#OAUTH2_PROXY_COOKIE_SECRET=${cookie_secret}#" .env

  echo "Секреты сгенерированы в .env. Сохраните файл в надёжном месте (или подключите Vault позже)."
else
  echo ".env уже существует — не трогаю (удалите файл, если хотите пересоздать с нуля)."
fi

# shellcheck disable=SC1091
source .env

# Сертификаты выпускаются через DNS-01 у Hetzner — без токена Traefik не
# получит ни одного сертификата, и это лучше поймать здесь, а не в логах.
if [ -z "${HETZNER_API_KEY:-}" ]; then
  echo "HETZNER_API_KEY не заполнен в .env." >&2
  echo "Создайте токен в dns.hetzner.com -> API tokens и впишите его — без этого" >&2
  echo "Let's Encrypt не выдаст сертификаты (challenge идёт через DNS, а не порт 80)." >&2
  exit 1
fi

# Traefik-овский file provider не умеет переменные, поэтому wildcard-конфиг
# рендерим из шаблона с подставленным доменом.
if [ ! -f config/traefik/dynamic/tls.yml ]; then
  log "Генерирую config/traefik/dynamic/tls.yml (wildcard-сертификат)"
  sed "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
    config/traefik/dynamic/tls.yml.template > config/traefik/dynamic/tls.yml
fi

# Traefik dashboard basic-auth — отдельным файлом (htpasswd), не через .env:
# передача hash-а через переменную окружения ломается на `$`-экранировании
# при подстановке docker compose (проверено на практике).
if [ ! -f secrets/dashboard.htpasswd ]; then
  log "Генерирую пароль для Traefik dashboard"
  dash_pass="$(openssl rand -base64 18)"
  htpasswd -Bbn admin "$dash_pass" > secrets/dashboard.htpasswd
  echo "Traefik dashboard (https://traefik.${BASE_DOMAIN:-<домен>}): admin / ${dash_pass}"
  echo "^ сохраните этот пароль — он больше нигде не выводится и не хранится в открытом виде."
else
  echo "secrets/dashboard.htpasswd уже существует — пропускаю."
fi

# --- 8. Поднимаем сервисы ---------------------------------------------------
log "Поднимаю слои: core ${LAYERS}"
chmod +x scripts/up.sh
./scripts/up.sh $LAYERS

log "Готово"
cat <<EOF

Проверьте, что DNS указывает на этот сервер (A-записи или wildcard *.${BASE_DOMAIN}):
  git, registry, sso, traefik, grafana, prometheus, alerts, automation

Дальше руками (подробности в README.md):
  1. https://git.${BASE_DOMAIN} — войти как root, пароль в .env (GITLAB_ROOT_PASSWORD).
     Первый старт GitLab занимает 3-5 минут: docker compose logs -f gitlab
  2. Admin Area -> CI/CD -> Runners -> New instance runner -> скопировать токен
     (glrt-...) -> вписать в .env как GITLAB_RUNNER_TOKEN, затем поднять раннер:
     docker compose -f docker-compose.yml -f docker-compose.gitlab.yml --profile runner up -d
  3. https://automation.${BASE_DOMAIN} — сразу создать owner-аккаунт в n8n
     (до этого момента любой, кто откроет адрес, может занять его первым).
  4. https://sso.${BASE_DOMAIN} — создать realm и клиент для oauth2-proxy,
     затем поднять стартовую страницу со всеми сервисами:
     ./scripts/up.sh dashboard        (инструкция: docs/dashboard-sso.md)
  5. VPN: поставить NetBird (docs/vpn-netbird.md), проверить доступ, и только
     ПОСЛЕ этого закрыть сервер наружу:
     sudo ./scripts/harden.sh
  6. Plane / DefectDojo / Harbor ставятся отдельно официальными установщиками —
     см. docs/adding-plane.md и docs/adding-defectdojo-harbor.md.
EOF
