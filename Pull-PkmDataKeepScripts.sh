#!/usr/bin/env bash
# Copies PKM data from origin, keeping local scripts. Does not touch data/hub. Page order comes from origin.
# Run from the site instance root or from upstream/.
#
# Usage:
#   ./Pull-PkmDataKeepScripts.sh
#   ./upstream/Pull-PkmDataKeepScripts.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_AUTH_ARGS=()
PKM_POSITION_SNAPSHOT=""

is_site_root() {
  local dir="$1"
  [[ -f "$dir/docker-compose.apps.yml" || -f "$dir/docker-compose.custom.yml" || -f "$dir/.env" ]] && return 0
  [[ -d "$dir/data" && -d "$dir/.git" ]] && return 0
  return 1
}

if [[ "$(basename "$SCRIPT_DIR")" == "upstream" ]] && is_site_root "$(dirname "$SCRIPT_DIR")"; then
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
elif is_site_root "$SCRIPT_DIR"; then
  REPO_ROOT="$SCRIPT_DIR"
else
  echo "Run from site root (folder with .git and data/) or from upstream/ inside a site instance." >&2
  exit 1
fi

export_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

die() {
  echo "$1" >&2
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

pkm_dup_helper() {
  if [[ -f "$REPO_ROOT/Normalize-PkmDuplicatePaths.py" ]]; then
    printf '%s\n' "$REPO_ROOT/Normalize-PkmDuplicatePaths.py"
  elif [[ -f "$REPO_ROOT/upstream/Normalize-PkmDuplicatePaths.py" ]]; then
    printf '%s\n' "$REPO_ROOT/upstream/Normalize-PkmDuplicatePaths.py"
  fi
}

pkm_dup_py() {
  local helper
  helper="$(pkm_dup_helper)"
  [[ -n "$helper" ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 "$helper" "$@"
  elif command -v python >/dev/null 2>&1; then
    python "$helper" "$@"
  else
    return 1
  fi
}

snapshot_pkm_positions() {
  local db="$REPO_ROOT/data/pkm/pkm.db"
  PKM_POSITION_SNAPSHOT=""
  [[ -f "$db" ]] || return 0
  PKM_POSITION_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/homelab-pkm-positions.XXXXXX.json")"
  if pkm_dup_py snapshot --db "$db" --out "$PKM_POSITION_SNAPSHOT" >/dev/null; then
    echo "Saved origin PKM page order."
  else
    rm -f -- "$PKM_POSITION_SNAPSHOT"
    PKM_POSITION_SNAPSHOT=""
  fi
}

restore_pkm_positions() {
  local db="$REPO_ROOT/data/pkm/pkm.db" out
  [[ -n "$PKM_POSITION_SNAPSHOT" && -f "$PKM_POSITION_SNAPSHOT" && -f "$db" ]] || return 0
  out="$(pkm_dup_py restore --db "$db" --from-json "$PKM_POSITION_SNAPSHOT" || true)"
  [[ "$out" == restored\ 0\ * || -z "$out" ]] && return 0
  echo "Restored origin PKM page order."
}

clear_pkm_sqlite_sidecars() {
  rm -f -- "$REPO_ROOT/data/pkm/pkm.db-wal" "$REPO_ROOT/data/pkm/pkm.db-shm"
}

remove_pkm_files_not_on_origin() {
  local source="$1" pkm_root="$REPO_ROOT/data/pkm" rel
  [[ -d "$pkm_root" ]] || return 0
  local -A want=()
  while IFS= read -r rel; do
    [[ -n "$rel" ]] && want["$rel"]=1
  done < <(git_auth ls-tree -r --name-only "$source" -- data/pkm)
  while IFS= read -r -d '' file; do
    rel="${file#"$REPO_ROOT"/}"
    rel="${rel#/}"
    case "$rel" in
      data/pkm/scripts|data/pkm/scripts/*) continue ;;
    esac
    [[ -n "${want[$rel]:-}" ]] || rm -f -- "$file"
  done < <(find "$pkm_root" -type f -print0)
  find "$pkm_root" -depth -type d -empty ! -path "$pkm_root/scripts" ! -path "$pkm_root/scripts/*" -delete 2>/dev/null || true
}

stop_pkm_if_present() {
  local container="${HOMELAB_PKM_CONTAINER:-pkm-backend}"
  command -v docker >/dev/null 2>&1 || return 0
  docker inspect "$container" >/dev/null 2>&1 || return 0
  echo "Stopping ${container} before replacing pkm.db."
  docker stop "$container" >/dev/null 2>&1 || true
}

reindex_pkm() {
  local helper="$REPO_ROOT/Reindex-PkmFromDisk.sh"
  [[ -f "$helper" ]] || helper="$REPO_ROOT/upstream/Reindex-PkmFromDisk.sh"
  [[ -f "$helper" ]] || return 0
  chmod +x "$helper" 2>/dev/null || true
  /bin/bash "$helper" || true
}

command -v git >/dev/null 2>&1 || die "git is required"
[[ -d "$REPO_ROOT/.git" ]] || die "Site root has no .git. This script updates the site data repo, not the product submodule."
[[ -d "$REPO_ROOT/data" ]] || die "Missing data/ under site root."

export_env_file "$REPO_ROOT/.env"
cd "$REPO_ROOT"
build_git_auth_args

BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[[ -n "$BRANCH" && "$BRANCH" != "HEAD" ]] || die "Detached HEAD is not supported. Check out the site branch first."

SCRIPTS_REL="data/pkm/scripts"
KEEP_DIR=""
HAD_SCRIPTS=0
if [[ -d "$SCRIPTS_REL" ]]; then
  HAD_SCRIPTS=1
  KEEP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pkm-scripts-keep.XXXXXX")"
  cp -a -- "$SCRIPTS_REL" "$KEEP_DIR/scripts"
  echo "Saved local data/pkm/scripts aside."
fi

cleanup() {
  [[ -n "$PKM_POSITION_SNAPSHOT" && -f "$PKM_POSITION_SNAPSHOT" ]] && rm -f -- "$PKM_POSITION_SNAPSHOT"
  [[ -n "$KEEP_DIR" && -d "$KEEP_DIR" ]] && rm -rf -- "$KEEP_DIR"
}
trap cleanup EXIT

stop_pkm_if_present

git_auth fetch origin "$BRANCH"
git_auth checkout "origin/${BRANCH}" -- data/pkm
git_auth restore --staged -- data/pkm || true
remove_pkm_files_not_on_origin "origin/${BRANCH}"
clear_pkm_sqlite_sidecars
echo "Restored data/pkm from origin/${BRANCH} (Hub data/ left untouched)."

if [[ "$HAD_SCRIPTS" -eq 1 ]]; then
  rm -rf -- "$SCRIPTS_REL"
  mkdir -p "$(dirname "$SCRIPTS_REL")"
  cp -a -- "$KEEP_DIR/scripts" "$SCRIPTS_REL"
  echo "Restored local data/pkm/scripts (not overwritten from origin)."
fi

snapshot_pkm_positions
restore_pkm_positions
reindex_pkm
restore_pkm_positions

echo "Done. Local scripts kept; PKM tree/order match origin. Hub/Guacamole were not overwritten."
