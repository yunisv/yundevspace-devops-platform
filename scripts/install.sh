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
# Run this AFTER installing NetBird and joining this host to it as a peer
# (docs/vpn-netbird.md) — BIND_ADDRESS below only exists once that's done.
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

# IPv4-адреса этой машины, по одному в строке. iproute2 ставится ниже, но
# на минимальных образах его может не быть в момент первого запуска.
host_addrs() {
  if command -v ip >/dev/null 2>&1; then
    ip -4 -o addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1] "\t(" $2 ")"}'
  else
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true
  fi
}

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
log "Базовые пакеты (curl, openssl, apache2-utils, iproute2)"
apt-get update -y
apt-get install -y --no-install-recommends \
  curl ca-certificates openssl apache2-utils iproute2

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
# Сеть создаётся самим compose (в docker-compose.yml у неё закреплена
# подсеть DOCKER_SUBNET) — вручную здесь не создаём, иначе она получит
# случайную подсеть и разойдётся с ip-фильтром Traefik.
log "Docker-сеть devops_edge"
if docker network inspect devops_edge >/dev/null 2>&1; then
  echo "Уже существует (проверьте, что её подсеть совпадает с DOCKER_SUBNET в .env)"
else
  echo "Будет создана автоматически при старте compose"
fi

# --- 6. Firewall -----------------------------------------------------------
# Порты здесь не открываются: сервисы биндятся только на интерфейс NetBird
# (BIND_ADDRESS), снаружи слушать нечего. Итоговую блокировку публичного
# интерфейса накатывает ./scripts/harden.sh — отдельно, после того как
# NetBird установлен и доступ через него проверен.
warn "Правила фаервола не трогаю. Сначала установите NetBird (docs/vpn-netbird.md), затем запустите ./scripts/harden.sh."

# --- 7. .env + секреты ------------------------------------------------------
mkdir -p secrets

if [ ! -f .env ]; then
  log ".env не найден — создаю и генерирую секреты"
  cp .env.example .env
  chmod 600 .env # содержит пароли GitLab/Keycloak и токен Hetzner — не для чужих глаз

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

# Значения, которые нельзя угадать за пользователя. Собираем все проблемы
# разом и печатаем одним списком — иначе получается «поправил, запустил,
# упало на следующем» по кругу.
problems=()

# Сертификаты выпускаются через DNS-01 у Hetzner: без токена Traefik не
# получит ни одного сертификата.
if [ -z "${HETZNER_API_TOKEN:-}" ]; then
  problems+=("HETZNER_API_TOKEN — токен из console.hetzner.com -> Security -> API Tokens (НЕ старая dns.hetzner.com — без него не будет сертификатов)")
fi

# Платформа слушает только интерфейс NetBird (wt0) — он появляется после
# `netbird up` (см. docs/vpn-netbird.md). -F, потому что точки в IP иначе
# трактуются как любой символ.
if [ -z "${BIND_ADDRESS:-}" ] || ! host_addrs | grep -qFw "${BIND_ADDRESS}"; then
  problems+=("BIND_ADDRESS=${BIND_ADDRESS:-<пусто>} — такого адреса нет на этой машине. Установлен ли NetBird и выполнен ли 'netbird up'? См. docs/vpn-netbird.md")
fi

if [ ${#problems[@]} -gt 0 ]; then
  echo >&2
  echo "Заполните в .env перед установкой:" >&2
  for p in "${problems[@]}"; do echo "  - $p" >&2; done
  echo >&2
  echo "Адреса этой машины:" >&2
  host_addrs | sed 's/^/  /' >&2
  echo >&2
  echo "Затем запустите ./scripts/install.sh снова (уже созданный .env не перезапишется)." >&2
  exit 1
fi

# Эти подсети определяют, кого пустит ip-фильтр. Ошибка здесь не ломает
# установку, но потом даёт 403 на ровном месте — поэтому показываем явно.
log "Сетевые параметры (проверьте, что совпадают с реальностью)"
cat <<EOF
  IP сервера в сети NetBird : ${BIND_ADDRESS}
  Подсеть NetBird           : ${VPN_SUBNET}
  Сеть контейнеров          : ${DOCKER_SUBNET}
EOF

# Подсеть docker-сети закреплена в compose. Если сеть уже существует с
# другой — compose откажется стартовать с невнятной ошибкой.
if docker network inspect devops_edge >/dev/null 2>&1; then
  existing_subnet="$(docker network inspect devops_edge \
    --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
  if [ -n "$existing_subnet" ] && [ "$existing_subnet" != "${DOCKER_SUBNET}" ]; then
    echo >&2
    echo "Сеть devops_edge уже существует с подсетью ${existing_subnet}," >&2
    echo "а в .env указана ${DOCKER_SUBNET}. Совместите их: либо впишите" >&2
    echo "${existing_subnet} в DOCKER_SUBNET, либо пересоздайте сеть:" >&2
    echo "  docker compose down && docker network rm devops_edge" >&2
    exit 1
  fi
fi

# Traefik-овский file provider не умеет переменные, поэтому подсети для
# ip-фильтра рендерим из шаблона. (Wildcard-сертификат задаётся флагами
# entrypoint в docker-compose.yml — там подстановка работает.)
if [ ! -f config/traefik/dynamic/access.yml ]; then
  log "Генерирую config/traefik/dynamic/access.yml (разрешённые подсети)"
  sed -e "s#__VPN_SUBNET__#${VPN_SUBNET}#g" \
      -e "s#__DOCKER_SUBNET__#${DOCKER_SUBNET}#g" \
    config/traefik/dynamic/access.yml.template > config/traefik/dynamic/access.yml
fi

# Traefik dashboard basic-auth — отдельным файлом (htpasswd), не через .env:
# передача hash-а через переменную окружения ломается на `$`-экранировании
# при подстановке docker compose (проверено на практике).
if [ ! -f secrets/dashboard.htpasswd ]; then
  log "Генерирую пароль для Traefik dashboard"
  dash_pass="$(openssl rand -base64 18)"
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -Bbn admin "$dash_pass" > secrets/dashboard.htpasswd
  else
    # apache2-utils не поставился — apr1 через openssl. Traefik понимает
    # оба формата, bcrypt из htpasswd просто предпочтительнее.
    warn "htpasswd не найден, использую openssl (apr1 вместо bcrypt)."
    printf 'admin:%s\n' "$(openssl passwd -apr1 "$dash_pass")" > secrets/dashboard.htpasswd
  fi
  chmod 600 secrets/dashboard.htpasswd
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

DNS: поддомены должны резолвиться в адрес ${BASE_DOMAIN} этого сервера В
СЕТИ NETBIRD (${BIND_ADDRESS}), не в публичный IP. Проще всего wildcard
*.${BASE_DOMAIN} A ${BIND_ADDRESS}. Нужны:
  git, registry, sso, traefik, grafana, prometheus, alerts, automation, dash

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
  5. Проверить, что через NetBird открывается https://git.${BASE_DOMAIN}, и
     только ПОСЛЕ этого закрыть публичный интерфейс (docs/vpn-netbird.md):
     sudo ./scripts/harden.sh
  6. Plane / DefectDojo / Harbor ставятся отдельно официальными установщиками —
     см. docs/adding-plane.md и docs/adding-defectdojo-harbor.md.
EOF
