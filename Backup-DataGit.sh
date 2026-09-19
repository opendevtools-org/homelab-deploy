#!/usr/bin/env bash
# Commits and pushes changes under data/ plus selected site files as a daily backup.
# Same behaviour as Backup-DataGit.ps1. For site instances only.
#
# Usage (from site root):
#   ./Backup-DataGit.sh
set -euo pipefail

export_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

NOTIFY_WEBHOOK_URL="${HOMELAB_BACKUP_NOTIFY_WEBHOOK_URL:-}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFICATION_LOG="${HOMELAB_BACKUP_LOG:-$SCRIPT_ROOT/logs/backup-data-git.log}"
BACKUP_PATHS=(
  data docker-compose.custom.yml docker-compose.apps.yml docker-compose.frontend.apps.yml README.md overrides
  upstream
  .gitignore .gitignore.custom .gitignore.upstream
  scriptkit agent-context docker
  docker-compose.custom.example.yml docker-compose.apps.example.yml
  Update-HomelabUpstream.ps1 Update-HomelabUpstream.sh
  Backup-DataGit.ps1 Backup-DataGit.sh
  Register-DataGitBackupTask.ps1 Register-DataGitBackup.sh
  Pull-DataGit.ps1 Pull-DataGit.sh
  Pull.ps1 Pull.sh
  Start-MarketPlugins.ps1 Start-MarketPlugins.sh
  Run-HomelabSite.ps1 Run-HomelabSite.sh
  Pull-PkmDataKeepScripts.ps1 Pull-PkmDataKeepScripts.sh
  Collect-HomelabDiag.ps1 Collect-HomelabDiag.sh
  Dump-PkmSidebar.py
  Register-DataGitPullTask.ps1 Register-DataGitPull.sh
  Reindex-PkmFromDisk.ps1 Reindex-PkmFromDisk.sh
  Merge-SqliteGitConflict.py Normalize-PkmDuplicatePaths.py
  Refresh-SiteProductTrees.ps1 Refresh-SiteProductTrees.sh
  docker-compose.config.yml docker-compose.https.yml
  Caddyfile README.site.md
)
SQLITE_MERGE_HELPER="$SCRIPT_ROOT/Merge-SqliteGitConflict.py"
GIT_AUTH_ARGS=()
HOST_ID="$(hostname 2>/dev/null || printf 'unknown-host')"
HOST_ID="${HOST_ID//[^A-Za-z0-9._-]/-}"
[[ -n "$HOST_ID" ]] || HOST_ID="unknown-host"
CONFLICT_TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

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

reindex_pkm_after_sync() {
  local helper="$SCRIPT_ROOT/Reindex-PkmFromDisk.sh"
  local out code
  if [[ ! -f "$helper" ]]; then
    notify "INFO" "PKM disk reindex skipped (Reindex-PkmFromDisk.sh not found)."
    return 0
  fi
  chmod +x "$helper" 2>/dev/null || true
  set +e
  out="$(/bin/bash "$helper" 2>&1)"
  code=$?
  set -e
  [[ -n "$out" ]] && printf '%s\n' "$out"
  if [[ "$code" -ne 0 ]]; then
    notify "WARN" "PKM disk reindex failed after git sync. Use Import from disk in the PKM UI if items are missing."
    return 0
  fi
  if printf '%s' "$out" | grep -q "skipped"; then
    notify "INFO" "$(printf '%s\n' "$out" | tail -n 1)"
    return 0
  fi
  notify "INFO" "PKM imported pages, files, PDFs, and bookmarks from disk."
}

restore_pkm_data_ownership() {
  local owner="${PUID:-1000}:${PGID:-1000}"
  local data_dir="$REPO_ROOT/data/pkm"

  [[ -d "$data_dir" ]] || return 0
  mkdir -p "$data_dir/bookmarks"
  if [[ "$(id -u)" -ne 0 ]]; then
    notify "WARN" "PKM data ownership was not reset (script is not running as root). If pkm-backend hits PermissionError, chown ${owner} on data/pkm."
    return 0
  fi
  chown -R "$owner" "$data_dir"
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

STOPPED_FOR_SYNC=()

stop_data_lock_containers() {
  local name running
  STOPPED_FOR_SYNC=()
  command -v docker >/dev/null 2>&1 || return 0
  for name in pkm-backend home-hub-platform; do
    running="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
    [[ "$running" == "true" ]] || continue
    echo "Stopping ${name} so Git can update SQLite files."
    docker stop "$name" >/dev/null 2>&1 || true
    STOPPED_FOR_SYNC+=("$name")
  done
  if (( ${#STOPPED_FOR_SYNC[@]} > 0 )); then
    sleep 2
  fi
}

start_data_lock_containers() {
  local name
  (( ${#STOPPED_FOR_SYNC[@]} > 0 )) || return 0
  for name in "${STOPPED_FOR_SYNC[@]}"; do
    docker start "$name" >/dev/null 2>&1 || true
  done
  STOPPED_FOR_SYNC=()
}

set_sqlite_skip_worktree() {
  local enable="$1"
  local flag p
  if [[ "$enable" == "1" ]]; then
    flag="--skip-worktree"
  else
    flag="--no-skip-worktree"
  fi
  for p in data/hub/platform.db data/pkm/pkm.db; do
    git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || continue
    git update-index "$flag" -- "$p" >/dev/null 2>&1 || true
  done
}

merge_sqlite_conflict() {
  local path="$1"
  local database_type temp_dir summary py

  case "$path" in
    data/hub/platform.db) database_type="platform" ;;
    data/pkm/pkm.db) database_type="pkm" ;;
    *) return 1 ;;
  esac

  if command -v python3 >/dev/null 2>&1; then
    py=python3
  elif command -v python >/dev/null 2>&1; then
    py=python
  else
    notify "WARN" "SQLite merge unavailable for ${path}; python3 and Merge-SqliteGitConflict.py are required."
    return 1
  fi
  if [[ ! -f "$SQLITE_MERGE_HELPER" ]]; then
    notify "WARN" "SQLite merge unavailable for ${path}; python3 and Merge-SqliteGitConflict.py are required."
    return 1
  fi

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-sqlite-merge.XXXXXX")"
  if ! git show ":1:${path}" >"$temp_dir/base.db" \
    || ! git show ":2:${path}" >"$temp_dir/local.db" \
    || ! git show ":3:${path}" >"$temp_dir/remote.db"; then
    rm -rf -- "$temp_dir"
    notify "WARN" "SQLite merge skipped for ${path}: the Git base, local, or remote version is missing."
    return 1
  fi

  if summary="$("$py" "$SQLITE_MERGE_HELPER" \
    --type "$database_type" \
    --base "$temp_dir/base.db" \
    --local "$temp_dir/local.db" \
    --remote "$temp_dir/remote.db" \
    --output "$temp_dir/merged.db" 2>&1)"; then
    cp -- "$temp_dir/merged.db" "$path"
    git add -- "$path"
    rm -rf -- "$temp_dir"
    notify "INFO" "Conflict in ${path}: SQLite rows merged successfully (${summary})."
    return 0
  fi

  rm -rf -- "$temp_dir"
  notify "WARN" "SQLite merge failed for ${path}: ${summary}"
  return 1
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
  local sync_error="${1:-}"
  local -a conflicted_paths
  local path archive archive_dir
  mapfile -d '' conflicted_paths < <(git diff --name-only -z --diff-filter=U)

  if (( ${#conflicted_paths[@]} == 0 )); then
    git_auth merge --abort 2>/dev/null || true
    if echo "$sync_error" | grep -qiE 'Access is denied|Permission denied|unable to unlink|unable to write|unable to create'; then
      die "Git could not update working files (often SQLite held open by Docker). Original error: ${sync_error}"
    fi
    die "Automatic sync failed, but no conflicted files were detected. ${sync_error}"
  fi

  for path in "${conflicted_paths[@]}"; do
    if merge_sqlite_conflict "$path"; then
      continue
    fi

    if [[ -d "$path" ]]; then
      notify "INFO" "Conflict in ${path}: directory/submodule; remote version kept as canonical."
      if git checkout --theirs -- "$path" 2>/dev/null; then
        git add -- "$path"
      fi
      continue
    fi

    archive="$(conflict_archive_path "$path")"
    archive_dir="$(dirname "$archive")"

    if git checkout --ours -- "$path" 2>/dev/null && [[ -e "$path" ]]; then
      mkdir -p "$archive_dir"
      cp -a -- "$path" "$archive"
      git add -f -- "$archive"
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

command -v git >/dev/null 2>&1 || die "git is required"

REPO_ROOT="$SCRIPT_ROOT"
[[ -d "$REPO_ROOT/.git" ]] || die "Run this script from the site instance root (folder with .git and data/)."
[[ -d "$REPO_ROOT/data" ]] || die "Missing data/ under site root. This backup is for site instances only."

export_env_file "$REPO_ROOT/.env"

cd "$REPO_ROOT"
build_git_auth_args

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -n "$BRANCH" && "$BRANCH" != "HEAD" ]] || die "Detached HEAD is not supported for automatic backup pushes."

stop_data_lock_containers
trap start_data_lock_containers EXIT
set_sqlite_skip_worktree 0

EXISTING_BACKUP_PATHS=()
for p in "${BACKUP_PATHS[@]}"; do
  [[ -e "$p" ]] && EXISTING_BACKUP_PATHS+=("$p")
done

git add -u -- "${EXISTING_BACKUP_PATHS[@]}"
mapfile -d '' NEW_BACKUP_FILES < <(git ls-files -z -o --exclude-standard -- "${EXISTING_BACKUP_PATHS[@]}")
if (( ${#NEW_BACKUP_FILES[@]} > 0 )); then
  git add -- "${NEW_BACKUP_FILES[@]}"
fi

if [[ -n "$(git diff --cached --name-only -- "${EXISTING_BACKUP_PATHS[@]}")" ]]; then
  TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
  git commit -m "backup(site): ${TIMESTAMP}"
else
  notify "INFO" "No changes in backup paths (data/, docker-compose.custom.yml, docker-compose.apps.yml, README.md). Continuing with remote sync."
fi

if ! rebase_err="$(git_auth pull --rebase --autostash origin "$BRANCH" 2>&1)"; then
  git_auth rebase --abort 2>/dev/null || true
  if ! merge_err="$(git_auth merge --no-edit "origin/$BRANCH" 2>&1)"; then
    resolve_conflicts_with_remote "${rebase_err} | merge: ${merge_err}"
  fi
fi

git_auth push origin "$BRANCH"
start_data_lock_containers
trap - EXIT

notify "INFO" "Backup/sync of data/, docker-compose.custom.yml, docker-compose.apps.yml, and README.md completed on branch '${BRANCH}'."
restore_pkm_data_ownership
reindex_pkm_after_sync
if [[ -f "$SCRIPT_ROOT/Start-MarketPlugins.sh" ]]; then
  chmod +x "$SCRIPT_ROOT/Start-MarketPlugins.sh" 2>/dev/null || true
  /bin/bash "$SCRIPT_ROOT/Start-MarketPlugins.sh" || notify "WARN" "Market plugin start after backup did not fully succeed."
fi
set_sqlite_skip_worktree 1
