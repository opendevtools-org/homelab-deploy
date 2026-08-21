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
FRONTEND_PORTS_FILE="docker-compose.frontend.${PORTS}.yml"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$HERE")" == "upstream" && -f "$HERE/../docker-compose.apps.yml" ]]; then
  SITE_ROOT="$(cd "$HERE/.." && pwd)"
  UPSTREAM="$HERE"
elif [[ -f "$HERE/upstream/docker-compose.yml" || -f "$HERE/upstream/docker-compose.backend.yml" ]]; then
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
LAUNCHERS=(
  Update-HomelabUpstream.sh
  Update-HomelabUpstream.ps1
  Backup-DataGit.sh
  Backup-DataGit.ps1
  Register-DataGitBackup.sh
  Register-DataGitBackupTask.ps1
  Pull-DataGit.sh
  Pull-DataGit.ps1
  Register-DataGitPull.sh
  Register-DataGitPullTask.ps1
  Reindex-PkmFromDisk.sh
  Reindex-PkmFromDisk.ps1
  docker-compose.config.yml
  .gitignore
)
REFRESHED=()
for s in "${LAUNCHERS[@]}"; do
  if [[ -f "$UPSTREAM/$s" ]]; then
    cp -a "$UPSTREAM/$s" "$SITE_ROOT/$s"
    [[ "$s" == *.sh ]] && chmod +x "$SITE_ROOT/$s"
    REFRESHED+=("$s")
  fi
done
if [[ ${#REFRESHED[@]} -gt 0 ]]; then
  echo "Refreshed site-root: ${REFRESHED[*]}"
fi

cd "$SITE_ROOT"

if [[ "$COMMIT" -eq 1 ]]; then
  [[ -d "$SITE_ROOT/.git" ]] || { echo "No .git in site root" >&2; exit 1; }
  git add upstream
  for s in "${LAUNCHERS[@]}"; do
    [[ -f "$s" ]] && git add "$s" || true
  done
  if [[ -n "$(git status --porcelain -- upstream "${LAUNCHERS[@]}" 2>/dev/null || true)" ]]; then
    git commit -m "Bump homelab-deploy upstream (${REV})."
    echo "Committed submodule pointer."
  else
    echo "Upstream pointer unchanged; nothing to commit."
  fi
fi

if [[ "$PUSH" -eq 1 ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || { echo "Detached HEAD is not supported for --push." >&2; exit 1; }
  git fetch origin
  if ! git pull --rebase --autostash origin "$branch"; then
    git rebase --abort >/dev/null 2>&1 || true
    git merge --no-edit "origin/$branch"
  fi
  git push origin "$branch"
  echo "Pushed."
fi

if [[ "$START" -eq 1 ]]; then
  [[ -f .env ]] || { echo "Missing .env in site root" >&2; exit 1; }
  echo "Starting Compose (stop old containers if names conflict)..."
  for n in pkm-backend pkm-frontend home-hub home-hub-platform; do
    docker rm -f "$n" >/dev/null 2>&1 || true
  done
  docker compose --project-directory . \
    -f upstream/docker-compose.backend.yml \
    -f "upstream/$PORTS_FILE" \
    -f docker-compose.config.yml \
    -f docker-compose.apps.yml pull
  docker compose --project-directory . \
    -f upstream/docker-compose.backend.yml \
    -f "upstream/$PORTS_FILE" \
    -f docker-compose.config.yml \
    -f docker-compose.apps.yml up -d
  docker compose --project-directory . \
    -f upstream/docker-compose.backend.yml \
    -f "upstream/$PORTS_FILE" \
    -f docker-compose.config.yml \
    -f docker-compose.apps.yml \
    rm --force --stop pkm-data-permissions >/dev/null 2>&1 || true
  docker compose --project-directory . \
    -f upstream/docker-compose.frontend.yml \
    -f "upstream/$FRONTEND_PORTS_FILE" pull
  docker compose --project-directory . \
    -f upstream/docker-compose.frontend.yml \
    -f "upstream/$FRONTEND_PORTS_FILE" up -d
  echo "Compose up done."

  helper="$SITE_ROOT/Reindex-PkmFromDisk.sh"
  if [[ ! -f "$helper" ]]; then
    echo "PKM disk reindex skipped (Reindex-PkmFromDisk.sh not found)."
  else
    echo "Importing PKM pages, files, PDFs, and bookmarks from disk..."
    chmod +x "$helper" 2>/dev/null || true
    set +e
    /bin/bash "$helper"
    reindex_code=$?
    set -e
    if [[ "$reindex_code" -ne 0 ]]; then
      echo "PKM disk reindex failed after Compose up. Use Import from disk in the PKM UI if items are missing." >&2
    fi
  fi
fi

echo "Done."
