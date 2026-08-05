#!/usr/bin/env bash
# Closes this server's public interface entirely. Access comes in over
# NetBird (docs/vpn-netbird.md) instead — a separate, dedicated server runs
# NetBird's control plane; this host is just a peer in that mesh.
#
# Services already bind only to BIND_ADDRESS (this host's NetBird IP), so
# this is defence in depth rather than the only thing standing in the way.
#
#   sudo ./scripts/harden.sh --dry-run  # print rules without applying
#   sudo ./scripts/harden.sh            # apply
#
# Recovery if you lock yourself out: Hetzner console (Server -> Console),
# then `ufw disable`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = false ]; then
  echo "Запускать от root: sudo ./scripts/harden.sh" >&2
  exit 1
fi

if [ ! -f .env ]; then
  echo "Нет .env — сначала ./scripts/install.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
source .env

: "${VPN_SUBNET:?VPN_SUBNET не задан в .env}"
: "${BIND_ADDRESS:?BIND_ADDRESS не задан в .env}"

# Тот же способ, что и install.sh: если BIND_ADDRESS не висит ни на одном
# интерфейсе, значит NetBird не поднят — закрывать порты сейчас нельзя,
# иначе сюда нельзя будет попасть вообще ничем, кроме консоли Hetzner.
if ! command -v ip >/dev/null 2>&1; then
  echo "Команда 'ip' не найдена — запустите ./scripts/install.sh хотя бы раз (ставит iproute2)." >&2
  exit 1
fi
if ! ip -4 -o addr show 2>/dev/null | grep -qFw "${BIND_ADDRESS}"; then
  echo "BIND_ADDRESS=${BIND_ADDRESS} не найден среди адресов этой машины." >&2
  echo "NetBird не установлен или не подключён — см. docs/vpn-netbird.md." >&2
  exit 1
fi

run() {
  if [ "$DRY_RUN" = true ]; then echo "  $*"; else "$@"; fi
}

cat <<EOF
Топология: клиент -> NetBird (control plane на отдельном сервере) -> этот
хост как peer. Публичный интерфейс после этого скрипта не используется —
включая SSH.

Будет разрешено:
  всё с ${VPN_SUBNET}   (пиры сети NetBird)
Будет закрыто:
  весь входящий трафик с публичного интерфейса, включая SSH по публичному IP.

EOF

if [ "$DRY_RUN" = false ]; then
  if [ ! -t 0 ]; then
    echo "Нужен интерактивный запуск (или --dry-run)." >&2
    exit 1
  fi
  echo "ПРОВЕРЬТЕ ПЕРЕД ЗАПУСКОМ: с другой машины, подключённой к NetBird,"
  echo "работает 'ssh -p 2222 <IP-этого-хоста-в-NetBird>' или https://git.\${BASE_DOMAIN}."
  read -rp "Продолжить? [yes/NO]: " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Отменено." >&2
    exit 1
  fi
fi

if ! command -v ufw >/dev/null 2>&1; then
  echo "Устанавливаю ufw"
  run apt-get update -y
  run apt-get install -y --no-install-recommends ufw
fi

echo "Применяю правила:"
run ufw --force reset
run ufw default deny incoming
run ufw default allow outgoing

run ufw allow from "${VPN_SUBNET}" comment 'NetBird peers'

run ufw --force enable
[ "$DRY_RUN" = false ] && ufw status verbose

cat <<EOF

Готово. Публичных портов на этом сервере больше нет.

ВАЖНО: дальнейший вход по SSH — только через адрес этого хоста в сети
NetBird (${BIND_ADDRESS:-см. .env}), не через публичный IP. Если сейчас
подключены по публичному IP — эта сессия останется жива, но следующая
должна идти уже через NetBird.

Дальше стоит закрыть и сам SSH-демон:
  - в /etc/ssh/sshd_config: PermitRootLogin no, PasswordAuthentication no
  - ListenAddress ${BIND_ADDRESS:-<netbird-ip>}   (чтобы sshd вообще не слушал публичный)
  - systemctl restart ssh

Проверка снаружи (с машины БЕЗ NetBird) — всё должно быть закрыто:
  nc -z -w5 <публичный-IP> 443 ; echo \$?   # ожидаем ненулевой код
  nc -z -w5 <публичный-IP> 22  ; echo \$?   # ожидаем ненулевой код
EOF
