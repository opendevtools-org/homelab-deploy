#!/usr/bin/env bash
# Attach Market plugins to homelab-backend / homelab-frontend (not a separate Compose project).
# Logs console + docker output to logs/start-market-plugins.log (or HOMELAB_START_PLUGINS_LOG).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="$HERE"
if [[ "$(basename "$HERE")" == "upstream" && -d "$HERE/../data" ]]; then
  SITE_ROOT="$(cd "$HERE/.." && pwd)"
fi

LOG="${HOMELAB_START_PLUGINS_LOG:-$SITE_ROOT/logs/start-market-plugins.log}"
mkdir -p "$(dirname "$LOG")"

log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >>"$LOG"
}

run_logged() {
  log "$*"
  set +e
  "$@" 2>&1 | while IFS= read -r row || [[ -n "$row" ]]; do
    log "$row"
  done
  local code="${PIPESTATUS[0]}"
  set -e
  return "$code"
}

ROOT="$SITE_ROOT/data/hub/plugins"
log "Start-MarketPlugins Ports=${HOMELAB_PORTS:-lan} LogFile=${LOG}"
[[ -d "$ROOT" ]] || { log "No data/hub/plugins directory; nothing to start."; exit 0; }
command -v docker >/dev/null 2>&1 || { log "docker not found; skip."; exit 0; }

PORTS="${HOMELAB_PORTS:-lan}"
if [[ "$PORTS" == "local" ]]; then
  PORTS_FILE="docker-compose.local.yml"
  FRONTEND_PORTS_FILE="docker-compose.frontend.local.yml"
else
  PORTS_FILE="docker-compose.lan.yml"
  FRONTEND_PORTS_FILE="docker-compose.frontend.lan.yml"
fi

compose_rel() {
  local full="$1"
  local prefix="${SITE_ROOT}/"
  printf '%s\n' "${full#"$prefix"}"
}

add_include() {
  local overlay="$1"
  local compose_file="$2"
  local project_dir="$3"
  local compose_rel project_rel
  compose_rel="$(compose_rel "$compose_file")"
  project_rel="$(compose_rel "$project_dir")"
  if [[ ! -f "$overlay" ]]; then
    cat >"$overlay" <<EOF
include:
  - path: ${compose_rel}
    project_directory: ${project_rel}

services: {}
EOF
    log "Created ${overlay}"
    INCLUDE_CHANGED=1
    return 0
  fi
  grep -Fq "$compose_rel" "$overlay" && return 0
  local item
  item=$(printf '  - path: %s\n    project_directory: %s\n' "$compose_rel" "$project_rel")
  if grep -q '^include:' "$overlay"; then
    local tmp
    tmp="$(mktemp)"
    awk -v item="$item" '
      BEGIN { added=0 }
      /^include:/ && !added { print; print item; added=1; next }
      { print }
    ' "$overlay" >"$tmp"
    mv "$tmp" "$overlay"
  else
    printf 'include:\n%s\n%s\n' "$item" "$(cat "$overlay")" >"${overlay}.tmp"
    mv "${overlay}.tmp" "$overlay"
  fi
  log "Updated include in ${overlay}: ${compose_rel}"
  INCLUDE_CHANGED=1
}

APPS="$SITE_ROOT/docker-compose.apps.yml"
FE_APPS="$SITE_ROOT/docker-compose.frontend.apps.yml"
want_be=0
want_fe=0
be_dirty=0
fe_dirty=0
skip_compose=0
[[ "${HOMELAB_SKIP_MARKET_COMPOSE:-}" == "1" ]] && skip_compose=1

shopt -s nullglob
for dir in "$ROOT"/*/; do
  [[ -d "$dir" ]] || continue
  id="$(basename "$dir")"
  [[ "$id" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || continue
  run_logged docker compose --project-name "homelab-plugin-${id}" down || true

  backend=""
  for f in docker-compose.backend.yml docker-compose.yml; do
    if [[ -f "$dir$f" ]]; then
      backend="$dir$f"
      break
    fi
  done
  frontend="${dir}docker-compose.frontend.yml"
  if [[ -n "$backend" ]]; then
    INCLUDE_CHANGED=0
    add_include "$APPS" "$backend" "${dir%/}"
    [[ "$INCLUDE_CHANGED" -eq 1 ]] && be_dirty=1
    want_be=1
    log "Plugin ${id}: backend attached to homelab-backend."
  fi
  if [[ -f "$frontend" ]]; then
    INCLUDE_CHANGED=0
    add_include "$FE_APPS" "$frontend" "${dir%/}"
    [[ "$INCLUDE_CHANGED" -eq 1 ]] && fe_dirty=1
    want_fe=1
    log "Plugin ${id}: frontend attached to homelab-frontend."
  fi
done

cd "$SITE_ROOT"

named_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

need_be=0
if [[ "$want_be" -eq 1 && "$skip_compose" -eq 0 ]]; then
  if [[ "$be_dirty" -eq 1 ]] || ! named_running homelab-guacamole; then
    need_be=1
  fi
fi

if [[ "$need_be" -eq 1 ]]; then
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
  if ! run_logged "${be[@]}" up -d; then
    log "Could not start homelab-backend with market plugins."
  else
    run_logged "${be[@]}" rm --force || true
    ids="$(docker ps -aq --filter label=homelab.config-job=true --filter status=exited 2>/dev/null || true)"
    if [[ -n "$ids" ]]; then
      # shellcheck disable=SC2086
      run_logged docker rm -f $ids || true
    fi
  fi
fi

need_fe=0
if [[ "$skip_compose" -eq 0 ]]; then
  if [[ "$fe_dirty" -eq 1 ]] || ! named_running home-hub; then
    need_fe=1
  fi
fi
if [[ "$need_fe" -eq 0 ]]; then
  if [[ "$skip_compose" -eq 1 ]]; then
    log "Skip plugin Compose up (includes already applied; stack starts next)."
  else
    log "Plugin includes unchanged; skip extra Compose up."
  fi
  log "Start-MarketPlugins finished."
  exit 0
fi

if [[ -f upstream/docker-compose.frontend.yml ]]; then
  args=(docker compose --project-directory . \
    -f upstream/docker-compose.frontend.yml \
    -f "upstream/$FRONTEND_PORTS_FILE")
else
  args=(docker compose -f docker-compose.frontend.yml -f "$FRONTEND_PORTS_FILE")
fi
if [[ -f "$FE_APPS" ]]; then
  args+=(-f docker-compose.frontend.apps.yml)
fi
if ! run_logged "${args[@]}" up -d; then
  log "Could not start homelab-frontend with market plugins."
fi

log "Start-MarketPlugins finished."
