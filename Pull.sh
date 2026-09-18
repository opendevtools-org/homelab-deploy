#!/usr/bin/env bash
# Daily site pull: commit local data, fetch origin, auto-merge (SQLite + file
# conflicts via Pull-DataGit), push, reindex PKM.
#
# Usage (site root or upstream/):
#   ./Pull.sh
#   ./Pull.sh --product              # also refresh upstream/ first
#   ./Pull.sh --product --start      # then compose pull + up
set -euo pipefail

PRODUCT=0
START=0
COMMIT=0
PUSH=0
PORTS="lan"
DATA_ARGS=()

usage() {
  echo "Usage: $0 [--product] [--start] [--commit] [--push] [--ports lan|local]"
  echo "  default     Pull-DataGit (automatic Git + SQLite merge)"
  echo "  --product   Update-HomelabUpstream first, then Pull-DataGit"
  echo "  --start     with --product: compose pull + up after product update"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --product) PRODUCT=1; shift ;;
    --start) START=1; PRODUCT=1; shift ;;
    --commit) COMMIT=1; PRODUCT=1; shift ;;
    --push) PUSH=1; COMMIT=1; PRODUCT=1; shift ;;
    --ports) PORTS="$2"; PRODUCT=1; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

is_site_root() {
  local d="$1"
  [[ -f "$d/docker-compose.apps.yml" || -f "$d/docker-compose.custom.yml" || -f "$d/.env" || -d "$d/data" ]]
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$HERE")" == "upstream" ]] && is_site_root "$(cd "$HERE/.." && pwd)"; then
  SITE_ROOT="$(cd "$HERE/.." && pwd)"
elif [[ -d "$HERE/upstream" ]] || is_site_root "$HERE"; then
  SITE_ROOT="$HERE"
else
  echo "Run from the site root or from upstream/." >&2
  exit 1
fi

cd "$SITE_ROOT"

if [[ "$PRODUCT" -eq 1 ]]; then
  upd="$SITE_ROOT/Update-HomelabUpstream.sh"
  [[ -f "$upd" ]] || upd="$SITE_ROOT/upstream/Update-HomelabUpstream.sh"
  [[ -f "$upd" ]] || { echo "Update-HomelabUpstream.sh not found" >&2; exit 1; }
  args=(--ports "$PORTS")
  [[ "$COMMIT" -eq 1 ]] && args+=(--commit)
  [[ "$PUSH" -eq 1 ]] && args+=(--push)
  [[ "$START" -eq 1 ]] && args+=(--start)
  /bin/bash "$upd" "${args[@]}"
fi

pull="$SITE_ROOT/Pull-DataGit.sh"
[[ -f "$pull" ]] || pull="$SITE_ROOT/upstream/Pull-DataGit.sh"
[[ -f "$pull" ]] || { echo "Pull-DataGit.sh not found (automatic merge helper)." >&2; exit 1; }
exec /bin/bash "$pull" "${DATA_ARGS[@]}"
