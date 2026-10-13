#!/bin/sh
# Actualiza el motor tras copiar una versión nueva de la carpeta engine/ al servidor (conserva .env).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
docker compose -f "$HERE/docker-compose.vps.yml" up -d --build
docker image prune -f >/dev/null 2>&1 || true
docker compose -f "$HERE/docker-compose.vps.yml" ps
