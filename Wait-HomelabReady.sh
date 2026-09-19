#!/usr/bin/env bash
# Bring Hub/PKM stacks up, wait for PKM API, restart nginx so the UI is not 502.
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

if [[ -f upstream/docker-compose.backend.yml ]]; then
  be=(docker compose --project-directory .
    -f upstream/docker-compose.backend.yml
    -f "upstream/$PORTS_FILE"
    -f docker-compose.config.yml
    -f docker-compose.custom.yml
    -f docker-compose.apps.yml)
else
  be=(docker compose
    -f docker-compose.backend.yml
    -f "$PORTS_FILE"
    -f docker-compose.config.yml
    -f docker-compose.custom.yml
    -f docker-compose.apps.yml)
fi

if [[ -f upstream/docker-compose.frontend.yml ]]; then
  fe=(docker compose --project-directory .
    -f upstream/docker-compose.frontend.yml
    -f "upstream/$FRONTEND_PORTS_FILE")
else
  fe=(docker compose -f docker-compose.frontend.yml -f "$FRONTEND_PORTS_FILE")
fi
[[ -f docker-compose.frontend.apps.yml ]] && fe+=(-f docker-compose.frontend.apps.yml)

echo "Ensuring homelab-backend is up (API before nginx)..."
"${be[@]}" up -d
"${be[@]}" rm --force >/dev/null 2>&1 || true

echo "Ensuring homelab-frontend is up..."
"${fe[@]}" up -d

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
