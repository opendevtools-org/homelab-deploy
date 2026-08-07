#!/usr/bin/env bash
# Update upstream/ submodule and optionally commit, push, redeploy.
# Same behaviour as Update-HomelabUpstream.ps1.
#
# Usage (from site root or from upstream/):
#   ./Update-HomelabUpstream.sh
#   ./Update-HomelabUpstream.sh --commit --push --start
set -euo pipefail

PORTS="lan"
COMMIT=0
PUSH=0
START=0

usage() {
  echo "Usage: $0 [--ports lan|local] [--commit] [--push] [--start]"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports) PORTS="$2"; shift 2 ;;
    --commit) COMMIT=1; shift ;;
    --push) PUSH=1; COMMIT=1; shift ;;
    --start) START=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ "$PORTS" == "lan" || "$PORTS" == "local" ]] || { echo "--ports must be lan or local" >&2; exit 1; }
PORTS_FILE="docker-compose.${PORTS}.yml"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$HERE")" == "upstream" && -f "$HERE/../docker-compose.apps.yml" ]]; then
  SITE_ROOT="$(cd "$HERE/.." && pwd)"
  UPSTREAM="$HERE"
elif [[ -f "$HERE/upstream/docker-compose.yml" ]]; then
  SITE_ROOT="$HERE"
  UPSTREAM="$HERE/upstream"
else
  echo "Run from site root (has upstream/) or from upstream/ inside a site instance." >&2
  exit 1
fi

command -v git >/dev/null || { echo "git required" >&2; exit 1; }
[[ "$START" -eq 1 ]] && command -v docker >/dev/null || true
[[ "$START" -eq 1 ]] && { command -v docker >/dev/null || { echo "docker required" >&2; exit 1; }; }

echo "Site root : $SITE_ROOT"
echo "Updating  : $UPSTREAM"

cd "$UPSTREAM"
git fetch origin
git checkout main
# Prefer hard reset: upstream may be force-pushed (orphan/history rewrite).
git reset --hard origin/main
REV="$(git rev-parse --short HEAD)"
echo "Upstream  : $REV"

# Refresh site-root launchers from product package
for s in Update-HomelabUpstream.sh Update-HomelabUpstream.ps1; do
  if [[ -f "$UPSTREAM/$s" ]]; then
    cp -a "$UPSTREAM/$s" "$SITE_ROOT/$s"
    [[ "$s" == *.sh ]] && chmod +x "$SITE_ROOT/$s"
  fi
done
echo "Refreshed site-root Update-HomelabUpstream.{sh,ps1}"

cd "$SITE_ROOT"

if [[ "$COMMIT" -eq 1 ]]; then
  [[ -d "$SITE_ROOT/.git" ]] || { echo "No .git in site root" >&2; exit 1; }
  git add upstream
  [[ -f Update-HomelabUpstream.sh ]] && git add Update-HomelabUpstream.sh || true
  [[ -f Update-HomelabUpstream.ps1 ]] && git add Update-HomelabUpstream.ps1 || true
  if [[ -n "$(git status --porcelain -- upstream Update-HomelabUpstream.sh Update-HomelabUpstream.ps1 2>/dev/null || true)" ]]; then
    git commit -m "Bump homelab-deploy upstream (${REV})."
    echo "Committed submodule pointer."
  else
    echo "Upstream pointer unchanged; nothing to commit."
  fi
fi

if [[ "$PUSH" -eq 1 ]]; then
  git push
  echo "Pushed."
fi

if [[ "$START" -eq 1 ]]; then
  [[ -f .env ]] || { echo "Missing .env in site root" >&2; exit 1; }
  docker compose --project-directory . \
    -f upstream/docker-compose.yml \
    -f "upstream/$PORTS_FILE" \
    -f docker-compose.apps.yml pull
  docker compose --project-directory . \
    -f upstream/docker-compose.yml \
    -f "upstream/$PORTS_FILE" \
    -f docker-compose.apps.yml up -d
  echo "Compose up done."
fi

echo "Done."
