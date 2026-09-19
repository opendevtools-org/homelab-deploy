#!/usr/bin/env bash
# Full site refresh: Update-HomelabUpstream --start (includes Start-MarketPlugins),
# then Pull-DataGit.
#
# Usage (site root or upstream/):
#   ./Run-HomelabSite.sh
#   ./Run-HomelabSite.sh --commit --push
#   ./Run-HomelabSite.sh --no-start --skip-data-pull
set -euo pipefail

PORTS="lan"
COMMIT=0
PUSH=0
START=1
SKIP_DATA=0

usage() {
  echo "Usage: $0 [--ports lan|local] [--commit] [--push] [--no-start] [--skip-data-pull]"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports) PORTS="$2"; shift 2 ;;
    --commit) COMMIT=1; shift ;;
    --push) PUSH=1; COMMIT=1; shift ;;
    --no-start) START=0; shift ;;
    --skip-data-pull) SKIP_DATA=1; shift ;;
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

upd="$SITE_ROOT/Update-HomelabUpstream.sh"
[[ -f "$upd" ]] || upd="$SITE_ROOT/upstream/Update-HomelabUpstream.sh"
[[ -f "$upd" ]] || { echo "Update-HomelabUpstream.sh not found" >&2; exit 1; }

args=(--ports "$PORTS")
[[ "$COMMIT" -eq 1 ]] && args+=(--commit)
[[ "$PUSH" -eq 1 ]] && args+=(--push)
[[ "$START" -eq 1 ]] && args+=(--start)

echo "=== 1/2 Update-HomelabUpstream (includes Start-MarketPlugins) ==="
chmod +x "$upd" 2>/dev/null || true
/bin/bash "$upd" "${args[@]}"

if [[ "$SKIP_DATA" -eq 1 ]]; then
  echo "skip-data-pull: not running Pull-DataGit."
  exit 0
fi

pull="$SITE_ROOT/Pull-DataGit.sh"
[[ -f "$pull" ]] || pull="$SITE_ROOT/upstream/Pull-DataGit.sh"
[[ -f "$pull" ]] || { echo "Pull-DataGit.sh not found" >&2; exit 1; }

echo "=== 2/2 Pull-DataGit ==="
chmod +x "$pull" 2>/dev/null || true
exec /bin/bash "$pull"
