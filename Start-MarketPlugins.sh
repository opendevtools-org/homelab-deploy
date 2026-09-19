#!/usr/bin/env bash
# Attach Market plugins to homelab-backend / homelab-frontend (not a separate Compose project).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="$HERE"
if [[ "$(basename "$HERE")" == "upstream" && -d "$HERE/../data" ]]; then
  SITE_ROOT="$(cd "$HERE/.." && pwd)"
fi
ROOT="$SITE_ROOT/data/hub/plugins"
[[ -d "$ROOT" ]] || exit 0
command -v docker >/dev/null 2>&1 || exit 0

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
    return
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
}

APPS="$SITE_ROOT/docker-compose.apps.yml"
FE_APPS="$SITE_ROOT/docker-compose.frontend.apps.yml"
want_be=0
want_fe=0

shopt -s nullglob
for dir in "$ROOT"/*/; do
  [[ -d "$dir" ]] || continue
  id="$(basename "$dir")"
  [[ "$id" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || continue
  docker compose --project-name "homelab-plugin-${id}" down >/dev/null 2>&1 || true

  backend=""
  for f in docker-compose.backend.yml docker-compose.yml; do
    if [[ -f "$dir$f" ]]; then
      backend="$dir$f"
      break
    fi
  done
  frontend="${dir}docker-compose.frontend.yml"
  if [[ -n "$backend" ]]; then
    add_include "$APPS" "$backend" "${dir%/}"
    want_be=1
    echo "Plugin ${id}: backend attached to homelab-backend."
  fi
  if [[ -f "$frontend" ]]; then
    add_include "$FE_APPS" "$frontend" "${dir%/}"
    want_fe=1
    echo "Plugin ${id}: frontend attached to homelab-frontend."
  fi
done

cd "$SITE_ROOT"

if [[ "$want_be" -eq 1 ]]; then
  if [[ -f upstream/docker-compose.backend.yml ]]; then
    docker compose --project-directory . \
      -f upstream/docker-compose.backend.yml \
      -f "upstream/$PORTS_FILE" \
      -f docker-compose.config.yml \
      -f docker-compose.custom.yml \
      -f docker-compose.apps.yml up -d
  else
    docker compose \
      -f docker-compose.backend.yml \
      -f "$PORTS_FILE" \
      -f docker-compose.config.yml \
      -f docker-compose.custom.yml \
      -f docker-compose.apps.yml up -d
  fi
fi

if [[ "$want_fe" -eq 1 ]]; then
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
  "${args[@]}" up -d
fi
