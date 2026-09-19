#!/usr/bin/env bash
# Wait for PKM API and restart nginx so the UI is not 502.
# Does not rebuild images. Compose up only if a container is missing.
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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

command -v docker >/dev/null 2>&1 || { log "Wait-HomelabReady skipped (docker not found)."; exit 0; }

exists() { docker inspect "$1" >/dev/null 2>&1; }
running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]; }
start_named() {
  exists "$1" || return 0
  running "$1" && return 0
  log "Starting $1..."
  docker start "$1" >/dev/null 2>&1 || true
}

backend_up() {
  local why="$1"
  log "$why"
  local guac_profile=()
  if [[ -f data/hub/plugins/guacamole/docker-compose.backend.yml ]]; then
    guac_profile+=(--profile guacamole)
  fi
  if [[ -f upstream/docker-compose.backend.yml ]]; then
    docker compose --project-directory . "${guac_profile[@]}" \
      -f upstream/docker-compose.backend.yml \
      -f "upstream/$PORTS_FILE" \
      -f docker-compose.custom.yml \
      -f docker-compose.apps.yml \
      -f docker-compose.config.yml up -d || true
  else
    docker compose "${guac_profile[@]}" \
      -f docker-compose.backend.yml \
      -f "$PORTS_FILE" \
      -f docker-compose.custom.yml \
      -f docker-compose.apps.yml \
      -f docker-compose.config.yml up -d || true
  fi
}

if ! exists pkm-backend; then
  backend_up "pkm-backend missing; running Compose backend up..."
elif [[ -f data/hub/plugins/guacamole/docker-compose.backend.yml ]] && ! exists homelab-guacamole; then
  backend_up "homelab-guacamole missing; running Compose backend up..."
fi

if ! exists pkm-frontend; then
  log "pkm-frontend missing; running Compose frontend up..."
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

running pkm-backend || { log "pkm-backend is not running. Check: docker logs pkm-backend"; exit 1; }
running pkm-frontend || { log "pkm-frontend is not running. Check: docker logs pkm-frontend"; exit 1; }

probe='import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/api/health", timeout=5).read()'

pkm_ok() {
  docker exec pkm-backend python -c "$probe" >/dev/null 2>&1 \
    || docker exec pkm-backend python3 -c "$probe" >/dev/null 2>&1
}

log "Waiting for PKM API on pkm-backend..."
ok=0
for i in $(seq 1 90); do
  if pkm_ok; then ok=1; break; fi
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  log "PKM API did not become healthy on pkm-backend. Check: docker logs pkm-backend"
  exit 1
fi

log "Restarting Hub/PKM nginx so they resolve pkm-backend / hub-platform..."
docker restart pkm-frontend home-hub >/dev/null 2>&1 || true
sleep 2

nginx_ok() {
  docker exec pkm-frontend wget -q -T 5 -O /dev/null http://pkm-backend:8000/api/health >/dev/null 2>&1
}

log "Waiting until pkm-frontend can reach pkm-backend..."
ok=0
for i in $(seq 1 30); do
  if nginx_ok; then ok=1; break; fi
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  log "pkm-frontend still cannot reach pkm-backend:8000 (502). Both must be on homelab_default."
  exit 1
fi

log "Hub/PKM ready (API healthy, nginx can proxy)."

if exists homelab-guacamole; then
  start_named homelab-guacamole
  docker network connect homelab_default homelab-guacamole >/dev/null 2>&1 || true
  http_up() {
    local code
    code="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$1" || true)"
    [[ "$code" =~ ^[1-4][0-9][0-9]$ ]]
  }
  guac_ok() {
    docker exec home-hub-platform python -c "import socket; socket.create_connection(('homelab-guacamole', 8080), 2).close()" >/dev/null 2>&1 && return 0
    local ip
    ip="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}} {{end}}' homelab-guacamole 2>/dev/null | awk '{print $1}')"
    if [[ -n "$ip" ]]; then
      docker exec home-hub-platform python -c "import socket; socket.create_connection(('$ip', 8080), 2).close()" >/dev/null 2>&1 \
        && return 0
    fi
    http_up http://127.0.0.1:8080/guacamole/ && return 0
    http_up http://127.0.0.1:8080/ && return 0
    return 1
  }
  log "Waiting until Guacamole answers on the Docker network (:8080 in-container)..."
  elapsed=0
  restarted_db=0
  until guac_ok; do
    elapsed=$((elapsed + 5))
    tail="$(docker logs --tail 8 homelab-guacamole 2>&1 || true)"
    if [[ "$restarted_db" -eq 0 && "$elapsed" -ge 30 && "$tail" == *"waiting for DB"* ]]; then
      log "Guacamole is waiting for embedded Postgres; restarting the container once..."
      docker restart homelab-guacamole >/dev/null 2>&1 || true
      sleep 3
      docker network connect homelab_default homelab-guacamole >/dev/null 2>&1 || true
      restarted_db=1
      log "If it stays on waiting for DB, /config must be a Docker named volume (not a Windows bind mount)."
    fi
    if (( elapsed % 30 == 0 )); then
      ips="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}} {{end}}' homelab-guacamole 2>/dev/null || true)"
      log "  still starting (${elapsed}s) ips=${ips}"
      printf '%s\n' "$tail" | while IFS= read -r line; do
        [[ -n "$line" ]] && log "    log: $line"
      done
    else
      log "  still starting (${elapsed}s)"
    fi
    sleep 5
  done
  log "Guacamole is up."
  sso_out="$(docker exec homelab-guacamole sh -c 'PROP=/config/guacamole/guacamole.properties; if [ ! -f "$PROP" ]; then exit 0; fi; c=0; grep -q "^postgresql-auto-create-accounts:" "$PROP" || { echo "postgresql-auto-create-accounts: true" >> "$PROP"; c=1; }; grep -q "^http-auth-header:" "$PROP" || { echo "http-auth-header: REMOTE_USER" >> "$PROP"; c=1; }; grep -q "^guacd-hostname:" "$PROP" || { echo "guacd-hostname: 127.0.0.1" >> "$PROP"; c=1; }; [ "$c" -eq 1 ] && echo SSO_PROPS_UPDATED' 2>/dev/null || true)"
  if [[ "$sso_out" == *SSO_PROPS_UPDATED* ]]; then
    log "Enabled Guacamole Hub SSO (auth-header); restarting the container..."
    docker restart homelab-guacamole >/dev/null 2>&1 || true
    sleep 3
    docker network connect homelab_default homelab-guacamole >/dev/null 2>&1 || true
    elapsed=0
    until guac_ok; do
      elapsed=$((elapsed + 5))
      log "  waiting after SSO restart (${elapsed}s)"
      sleep 5
    done
    log "Guacamole is up with Hub SSO."
  fi
  log "Syncing Hub users and admin rights into Guacamole..."
  docker exec home-hub-platform python -c "from app.agent import _apply_guacamole_hub_acl; _apply_guacamole_hub_acl()" >/dev/null 2>&1 || true
fi

ids="$(docker ps -aq --filter label=com.docker.compose.project=homelab-backend --filter status=exited 2>/dev/null || true)"
if [[ -n "$ids" ]]; then
  log "Removing exited backend init jobs..."
  # shellcheck disable=SC2086
  docker rm -f $ids >/dev/null 2>&1 || true
fi
