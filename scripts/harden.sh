#!/usr/bin/env bash
# Locks the server down to the minimum public surface: only what NetBird
# needs to let people in, plus HTTPS (which additionally filters by source
# IP at the Traefik level — see config/traefik/dynamic/middlewares.yml).
#
# Run this ONLY after NetBird is installed and you have verified you can
# reach the server over the VPN. It closes SSH.
#
#   sudo ./scripts/harden.sh            # apply
#   sudo ./scripts/harden.sh --dry-run  # print the rules without applying
#
# Recovery if you lock yourself out: use the hosting provider's console
# (Hetzner Cloud -> Server -> Console) and run `ufw disable`.
set -euo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

if [ "$(id -u)" -ne 0 ] && [ "$DRY_RUN" = false ]; then
  echo "Запускать от root: sudo ./scripts/harden.sh" >&2
  exit 1
fi

run() {
  if [ "$DRY_RUN" = true ]; then
    echo "  $*"
  else
    "$@"
  fi
}

cat <<'WARN'
Будет открыто наружу ТОЛЬКО:
  443/tcp            HTTPS (внутренние сервисы дополнительно закрыты
                     ip-фильтром Traefik — публично отдаются лишь sso. и netbird.)
  3478/udp           NetBird STUN/TURN
  49152-65535/udp    NetBird TURN relay

Будет ЗАКРЫТО: 22/tcp (SSH), 80/tcp, 2222/tcp (git SSH), всё остальное.
Доступ к SSH и сервисам — только через VPN.

WARN

if [ "$DRY_RUN" = false ]; then
  if [ ! -t 0 ]; then
    echo "Нужен интерактивный запуск (или используйте --dry-run)." >&2
    exit 1
  fi
  read -rp "NetBird уже работает и вы проверили доступ через VPN? [yes/NO]: " confirm
  if [ "$confirm" != "yes" ]; then
    echo "Отменено. Сначала поднимите VPN — см. docs/vpn-netbird.md" >&2
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

# Публичный минимум — то, без чего не войти в VPN.
run ufw allow 443/tcp comment 'HTTPS (sso/netbird public, rest ip-filtered)'
run ufw allow 3478/udp comment 'NetBird STUN/TURN'
run ufw allow 49152:65535/udp comment 'NetBird TURN relay'

# Доступ из VPN-сети: SSH, git по SSH и всё остальное.
run ufw allow from 100.64.0.0/10 comment 'NetBird VPN peers'

run ufw --force enable
[ "$DRY_RUN" = false ] && ufw status verbose

cat <<'DONE'

Готово. Дальше стоит закрыть и сам SSH-демон:
  - в /etc/ssh/sshd_config: PermitRootLogin no, PasswordAuthentication no
  - systemctl restart ssh
Пароли к серверу больше не нужны — только ключи и только через VPN.
DONE
