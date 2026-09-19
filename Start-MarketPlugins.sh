#!/usr/bin/env bash
# Start Market plugin Compose stacks found under data/hub/plugins/ (git-synced).
# Same role as Start-MarketPlugins.ps1. For site instances.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITE_ROOT="$HERE"
if [[ "$(basename "$HERE")" == "upstream" && -d "$HERE/../data" ]]; then
  SITE_ROOT="$(cd "$HERE/.." && pwd)"
fi
ROOT="$SITE_ROOT/data/hub/plugins"
[[ -d "$ROOT" ]] || exit 0

command -v docker >/dev/null 2>&1 || exit 0

hub_net=""
for n in homelab_default hub_default; do
  if docker network inspect "$n" >/dev/null 2>&1; then
    hub_net="$n"
    break
  fi
done

started=0
for dir in "$ROOT"/*/; do
  [[ -d "$dir" ]] || continue
  id="$(basename "$dir")"
  [[ "$id" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || continue
  compose=""
  for f in docker-compose.backend.yml docker-compose.yml; do
    if [[ -f "$dir$f" ]]; then
      compose="$dir$f"
      break
    fi
  done
  [[ -n "$compose" ]] || continue
  cmd=(docker compose --project-directory "$dir" --project-name "homelab-plugin-${id}" -f "$compose")
  if [[ -f "$dir/docker-compose.hub-override.yml" ]]; then
    cmd+=(-f "$dir/docker-compose.hub-override.yml")
  fi
  if "${cmd[@]}" up -d; then
    started=1
    echo "Started market plugin ${id}."
  else
    echo "Could not start market plugin ${id}." >&2
    continue
  fi
  if [[ -n "$hub_net" ]]; then
    docker network connect "$hub_net" "homelab-${id}" >/dev/null 2>&1 || true
  fi
done

if [[ "$started" -eq 1 ]]; then
  docker restart home-hub-platform >/dev/null 2>&1 || true
fi
