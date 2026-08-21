#!/usr/bin/env bash
# Pulls the latest site data from origin and safely publishes local standby changes.
# Same role as Pull-DataGit.ps1. For site instances only.
#
# Usage (from standby site root):
#   ./Pull-DataGit.sh
set -euo pipefail

NOTIFY_WEBHOOK_URL="${HOMELAB_BACKUP_NOTIFY_WEBHOOK_URL:-}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFICATION_LOG="${HOMELAB_PULL_LOG:-$SCRIPT_ROOT/logs/pull-data-git.log}"
BACKUP_PATHS=(data docker-compose.apps.yml README.md)
EXCLUDE_PATHSPEC=':(exclude)data/pkm/scripts/**/.uploads/**'
GIT_AUTH_ARGS=()
HOST_ID="$(hostname 2>/dev/null || printf 'unknown-host')"
HOST_ID="${HOST_ID//[^A-Za-z0-9._-]/-}"
[[ -n "$HOST_ID" ]] || HOST_ID="unknown-host"
CONFLICT_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

export_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

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
  notify "ERROR" "Pull failed: $1"
  echo "Pull failed: $1" >&2
  exit 1
}

build_git_auth_args() {
  local origin_url username auth_token auth_raw auth_b64

  auth_token="${HOMELAB_GIT_PAT:-}"
  [[ -n "$auth_token" ]] || return 0

  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  [[ "$origin_url" =~ ^https?:// ]] || die "HOMELAB_GIT_PAT requires an HTTPS origin remote."

  username="${HOMELAB_GIT_USERNAME:-git}"
  auth_raw="${username}:${auth_token}"
  if command -v base64 >/dev/null 2>&1; then
    auth_b64="$(printf '%s' "$auth_raw" | base64 | tr -d '\n')"
  elif command -v python3 >/dev/null 2>&1; then
    auth_b64="$(python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode()).decode())' "$auth_raw")"
  else
    die "base64 or python3 is required when HOMELAB_GIT_PAT is set."
  fi

  GIT_AUTH_ARGS=(
    -c "credential.helper="
    -c "core.askPass="
    -c "http.extraHeader=AUTHORIZATION: basic ${auth_b64}"
  )
}

git_auth() {
  git "${GIT_AUTH_ARGS[@]}" "$@"
}

conflict_archive_path() {
  local path="$1"
  local dir base stem ext candidate counter

  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [[ "$base" == *.* ]]; then
    stem="${base%.*}"
    ext=".${base##*.}"
  else
    stem="$base"
    ext=""
  fi

  if [[ "$dir" == "." ]]; then
    candidate="${stem}.local-conflict.${HOST_ID}.${CONFLICT_TIMESTAMP}${ext}"
  else
    candidate="${dir}/${stem}.local-conflict.${HOST_ID}.${CONFLICT_TIMESTAMP}${ext}"
  fi

  counter=1
  while [[ -e "$candidate" ]]; do
    if [[ "$dir" == "." ]]; then
      candidate="${stem}.local-conflict.${HOST_ID}.${CONFLICT_TIMESTAMP}.${counter}${ext}"
    else
      candidate="${dir}/${stem}.local-conflict.${HOST_ID}.${CONFLICT_TIMESTAMP}.${counter}${ext}"
    fi
    counter=$((counter + 1))
  done

  printf '%s\n' "$candidate"
}

resolve_conflicts_with_remote() {
  local -a conflicted_paths
  local path archive archive_dir
  mapfile -d '' conflicted_paths < <(git diff --name-only -z --diff-filter=U)

  if (( ${#conflicted_paths[@]} == 0 )); then
    git_auth merge --abort 2>/dev/null || true
    die "Automatic sync failed, but no conflicted files were detected. Check Git status manually."
  fi

  for path in "${conflicted_paths[@]}"; do
    archive="$(conflict_archive_path "$path")"
    archive_dir="$(dirname "$archive")"

    if git checkout --ours -- "$path" 2>/dev/null && [[ -e "$path" ]]; then
      mkdir -p "$archive_dir"
      cp -a -- "$path" "$archive"
      git add -- "$archive"
      notify "INFO" "Conflict in ${path}: local version saved as ${archive}; remote version kept as canonical."
    else
      notify "INFO" "Conflict in ${path}: no local file version could be archived; remote version kept as canonical."
    fi

    if git checkout --theirs -- "$path" 2>/dev/null; then
      git add -- "$path"
    else
      git rm -f -- "$path" >/dev/null 2>&1 || true
    fi
  done

  git_auth commit --no-edit
}

commit_local_changes() {
  git add -A -- "${BACKUP_PATHS[@]}" "$EXCLUDE_PATHSPEC"

  if [[ -z "$(git diff --cached --name-only -- "${BACKUP_PATHS[@]}" "$EXCLUDE_PATHSPEC")" ]]; then
    return 0
  fi

  git commit -m "backup(site): $(date '+%Y-%m-%d %H:%M:%S')"
}

sync_with_origin() {
  if ! git_auth pull --rebase --autostash origin "$BRANCH"; then
    git_auth rebase --abort 2>/dev/null || true
    if ! git_auth merge --no-edit "origin/$BRANCH"; then
      resolve_conflicts_with_remote
    fi
  fi
}

command -v git >/dev/null 2>&1 || die "git is required"

REPO_ROOT="$SCRIPT_ROOT"
[[ -d "$REPO_ROOT/.git" ]] || die "Run this script from the standby site root (folder with .git and data/)."
[[ -d "$REPO_ROOT/data" ]] || die "Missing data/ under site root. This pull is for standby site instances only."

export_env_file "$REPO_ROOT/.env"

cd "$REPO_ROOT"
build_git_auth_args

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -n "$BRANCH" && "$BRANCH" != "HEAD" ]] || die "Detached HEAD is not supported for automatic pulls."

commit_local_changes
sync_with_origin
git_auth push origin "$BRANCH" || die "git push origin $BRANCH failed. Run the script again after checking the network/remote status."
git submodule update --init --recursive || die "git submodule update failed."

notify "INFO" "Pull/sync completed with origin/${BRANCH}."
