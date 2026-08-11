#!/usr/bin/env bash
# Commits and pushes changes under data/ as a daily backup.
# Same behaviour as Backup-DataGit.ps1. For site instances only.
#
# Usage (from site root):
#   ./Backup-DataGit.sh
set -euo pipefail

NOTIFY_WEBHOOK_URL="${HOMELAB_BACKUP_NOTIFY_WEBHOOK_URL:-}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFICATION_LOG="${HOMELAB_BACKUP_LOG:-$SCRIPT_ROOT/logs/backup-data-git.log}"

notify() {
  local level="$1"
  local message="$2"
  local timestamp line
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  line="[${timestamp}] [${level}] ${message}"

  mkdir -p "$(dirname "$NOTIFICATION_LOG")"
  printf '%s\n' "$line" >>"$NOTIFICATION_LOG" || true
  printf '%s\n' "$line"

  if [[ -n "$NOTIFY_WEBHOOK_URL" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$NOTIFY_WEBHOOK_URL" "$line" <<'PY' || true
import json, sys, urllib.request
url, text = sys.argv[1], sys.argv[2]
req = urllib.request.Request(
    url,
    data=json.dumps({"text": text}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=15).read()
except Exception:
    pass
PY
  fi
}

die() {
  notify "ERROR" "Backup failed: $1"
  echo "Backup failed: $1" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die "git is required"

REPO_ROOT="$SCRIPT_ROOT"
[[ -d "$REPO_ROOT/.git" ]] || die "Run this script from the site instance root (folder with .git and data/)."
[[ -d "$REPO_ROOT/data" ]] || die "Missing data/ under site root. This backup is for site instances only."

cd "$REPO_ROOT"

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -n "$BRANCH" && "$BRANCH" != "HEAD" ]] || die "Detached HEAD is not supported for automatic backup pushes."

git add data

if [[ -z "$(git diff --cached --name-only -- data)" ]]; then
  notify "INFO" "No changes under data/. Nothing to commit."
  exit 0
fi

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
git commit -m "backup(data): ${TIMESTAMP}"

if ! git pull --rebase origin "$BRANCH"; then
  git rebase --abort 2>/dev/null || true
  if ! git pull --no-rebase --no-edit origin "$BRANCH"; then
    git merge --abort 2>/dev/null || true
    die "Automatic sync failed (rebase then merge). Resolve conflicts manually."
  fi
fi

git push origin "$BRANCH"

notify "INFO" "Backup committed and pushed on branch '${BRANCH}'."
