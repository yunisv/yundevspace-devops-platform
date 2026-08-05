#!/usr/bin/env bash
# Convenience wrapper to bring up chosen layers of the platform together.
# Usage: ./scripts/up.sh gitlab monitoring automation dashboard
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "Missing .env — run ./scripts/install.sh first (or copy .env.example manually)." >&2
  exit 1
fi

if [ ! -f secrets/dashboard.htpasswd ]; then
  echo "Missing secrets/dashboard.htpasswd — run ./scripts/install.sh first (Traefik needs it to start)." >&2
  exit 1
fi

# Rendered from access.yml.template by install.sh. Without it there is no
# `internal-only` middleware, and routers referencing a missing middleware
# refuse to serve — safe, but baffling to debug.
if [ ! -f config/traefik/dynamic/access.yml ]; then
  echo "Missing config/traefik/dynamic/access.yml — run ./scripts/install.sh first (it renders this from the .template)." >&2
  exit 1
fi

files=(-f docker-compose.yml)
for layer in "$@"; do
  case "$layer" in
    core) ;; # already included
    dashboard)
      # oauth2-proxy can't start without a Keycloak client, and the failure
      # mode otherwise is an unhelpful restart loop.
      if ! grep -q '^OAUTH2_PROXY_CLIENT_SECRET=.\+' .env; then
        echo "Слой dashboard требует настроенного Keycloak: создайте realm и клиент," >&2
        echo "затем впишите OAUTH2_PROXY_CLIENT_SECRET в .env — см. docs/dashboard-sso.md" >&2
        exit 1
      fi
      files+=(-f "docker-compose.${layer}.yml")
      ;;
    gitlab|monitoring|automation)
      files+=(-f "docker-compose.${layer}.yml")
      ;;
    *)
      echo "Unknown layer: $layer" >&2
      exit 1
      ;;
  esac
done

docker compose "${files[@]}" up -d
