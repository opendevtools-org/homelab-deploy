#!/usr/bin/env bash
# Wait for PKM API and restart nginx so the UI is not 502.
# Does not rebuild images. Compose up only if a container is missing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="$HERE"
if [[ "$(basename "$HERE")" == "upstream" && ( -f "$HERE/../docker-compose.custom.yml" || -f "$HERE/../.env" || -d "$HERE/../data" ) ]]; then
  SITE_ROOT="$(cd "$HERE/.." && pwd)"
fi
cd "$SITE_ROOT"

PORTS="${HOMELAB_PORTS:-lan}"
if [[ "$PORTS" == "local" ]]; then
  PORTS_FILE="docker-compose.local.yml"
  FRONTEND_PORTS_FILE="docker-compose.frontend.local.yml"
else
  PORTS_FILE="docker-compose.lan.yml"
  FRONTEND_PORTS_FILE="docker-compose.frontend.lan.yml"
fi

command -v docker >/dev/null 2>&1 || { echo "Wait-HomelabReady skipped (docker not found)."; exit 0; }

exists() { docker inspect "$1" >/dev/null 2>&1; }
running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]; }
start_named() {
  exists "$1" || return 0
  running "$1" && return 0
  echo "Starting $1..."
  docker start "$1" >/dev/null 2>&1 || true
}

if ! exists pkm-backend; then
  echo "pkm-backend missing; running Compose backend up..."
  if [[ -f upstream/docker-compose.backend.yml ]]; then
    docker compose --project-directory . \
      -f upstream/docker-compose.backend.yml \
      -f "upstream/$PORTS_FILE" \
      -f docker-compose.config.yml \
      -f docker-compose.custom.yml \
      -f docker-compose.apps.yml up -d || true
  else
    docker compose \
      -f docker-compose.backend.yml \
      -f "$PORTS_FILE" \
      -f docker-compose.config.yml \
      -f docker-compose.custom.yml \
      -f docker-compose.apps.yml up -d || true
  fi
fi

if ! exists pkm-frontend; then
  echo "pkm-frontend missing; running Compose frontend up..."
  extra_fe=()
  [[ -f docker-compose.frontend.apps.yml ]] && extra_fe+=(-f docker-compose.frontend.apps.yml)
  if [[ -f upstream/docker-compose.frontend.yml ]]; then
    docker compose --project-directory . \
      -f upstream/docker-compose.frontend.yml \
      -f "upstream/$FRONTEND_PORTS_FILE" \
      "${extra_fe[@]}" up -d || true
  else
    docker compose -f docker-compose.frontend.yml -f "$FRONTEND_PORTS_FILE" \
      "${extra_fe[@]}" up -d || true
  fi
fi

for n in pkm-backend home-hub-platform homelab-guacamole pkm-frontend home-hub; do
  start_named "$n"
done

running pkm-backend || { echo "pkm-backend is not running. Check: docker logs pkm-backend" >&2; exit 1; }
running pkm-frontend || { echo "pkm-frontend is not running. Check: docker logs pkm-frontend" >&2; exit 1; }

probe='import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/api/health", timeout=5).read()'

pkm_ok() {
  docker exec pkm-backend python -c "$probe" >/dev/null 2>&1 \
    || docker exec pkm-backend python3 -c "$probe" >/dev/null 2>&1
}

echo "Waiting for PKM API on pkm-backend..."
ok=0
for i in $(seq 1 90); do
  if pkm_ok; then ok=1; break; fi
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  echo "PKM API did not become healthy on pkm-backend. Check: docker logs pkm-backend" >&2
  exit 1
fi

echo "Restarting Hub/PKM nginx so they resolve pkm-backend / hub-platform..."
docker restart pkm-frontend home-hub >/dev/null 2>&1 || true
sleep 2

nginx_ok() {
  docker exec pkm-frontend wget -q -T 5 -O /dev/null http://pkm-backend:8000/api/health >/dev/null 2>&1
}

echo "Waiting until pkm-frontend can reach pkm-backend..."
ok=0
for i in $(seq 1 30); do
  if nginx_ok; then ok=1; break; fi
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  echo "pkm-frontend still cannot reach pkm-backend:8000 (502). Both must be on homelab_default." >&2
  exit 1
fi

echo "Hub/PKM ready (API healthy, nginx can proxy)."

if exists homelab-guacamole; then
  start_named homelab-guacamole
  docker network connect homelab_default homelab-guacamole >/dev/null 2>&1 || true
  guac_probe='import urllib.error, urllib.request
try:
    urllib.request.urlopen("http://homelab-guacamole:8080/", timeout=5)
except urllib.error.HTTPError:
    pass
'
  guac_ok() {
    docker exec home-hub-platform python -c "$guac_probe" >/dev/null 2>&1
  }
  echo "Waiting for Guacamole (Tomcat can take a minute)..."
  ok=0
  for i in $(seq 1 90); do
    if guac_ok; then ok=1; break; fi
    sleep 2
  done
  if [[ "$ok" -ne 1 ]]; then
    echo "Guacamole is not answering yet; Hub /p/guacamole/ may 502 until Tomcat finishes starting."
  else
    echo "Guacamole is reachable from Hub."
  fi
fi
