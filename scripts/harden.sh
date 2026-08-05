#!/usr/bin/env bash
# Closes the platform server's public interface. Access comes in over the
# company firewall's OpenVPN and the Hetzner private network instead.
#
# The services already bind only to BIND_ADDRESS (the private IP), so this
# is defence in depth rather than the only thing standing in the way.
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
: "${PRIVATE_SUBNET:?PRIVATE_SUBNET не задан в .env}"

run() {
  if [ "$DRY_RUN" = true ]; then echo "  $*"; else "$@"; fi
}

cat <<EOF
Топология: клиент -> OpenVPN на фаерволе (${VPN_SUBNET}) -> приватная сеть
(${PRIVATE_SUBNET}) -> этот сервер. Публичный интерфейс не используется.

Будет разрешено:
  всё с ${PRIVATE_SUBNET}   (фаервол и внутренние хосты)
  всё с ${VPN_SUBNET}       (клиенты OpenVPN)
Будет закрыто:
  весь входящий трафик с публичного интерфейса, включая SSH.

EOF

if [ "$DRY_RUN" = false ]; then
  if [ ! -t 0 ]; then
    echo "Нужен интерактивный запуск (или --dry-run)." >&2
    exit 1
  fi
  echo "ПРОВЕРЬТЕ ПЕРЕД ЗАПУСКОМ: вы подключены по VPN и SSH на приватный IP работает."
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

run ufw allow from "${PRIVATE_SUBNET}" comment 'Hetzner private network'
run ufw allow from "${VPN_SUBNET}" comment 'OpenVPN clients via firewall'

run ufw --force enable
[ "$DRY_RUN" = false ] && ufw status verbose

cat <<'DONE'

Готово. Публичных портов на этом сервере больше нет.

Дальше стоит закрыть и сам SSH-демон:
  - в /etc/ssh/sshd_config: PermitRootLogin no, PasswordAuthentication no
  - ListenAddress <приватный IP>   (чтобы sshd вообще не слушал публичный)
  - systemctl restart ssh

Проверка снаружи (с машины БЕЗ VPN) — всё должно быть закрыто:
  nc -z -w5 <публичный-IP> 443 ; echo $?   # ожидаем ненулевой код
  nc -z -w5 <публичный-IP> 22  ; echo $?   # ожидаем ненулевой код
DONE
