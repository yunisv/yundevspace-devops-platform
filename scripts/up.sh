#!/usr/bin/env bash
# Convenience wrapper to bring up chosen layers of the platform together.
# Usage: ./scripts/up.sh gitlab monitoring automation
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

files=(-f docker-compose.yml)
for layer in "$@"; do
  case "$layer" in
    core) ;; # already included
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
