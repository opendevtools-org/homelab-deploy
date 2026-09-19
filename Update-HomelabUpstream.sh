#!/usr/bin/env bash
# Update upstream/ submodule and optionally commit, push, redeploy.
# Same behaviour as Update-HomelabUpstream.ps1.
#
# Usage (from site root or from upstream/):
#   ./Update-HomelabUpstream.sh
#   ./Update-HomelabUpstream.sh --commit --push --start
set -euo pipefail

log() { printf '%s\n' "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

PORTS="lan"
COMMIT=0
PUSH=0
START=0

usage() {
  log "Usage: $0 [--ports lan|local] [--commit] [--push] [--start]"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ports) PORTS="$2"; shift 2 ;;
    --commit) COMMIT=1; shift ;;
    --push) PUSH=1; COMMIT=1; shift ;;
    --start) START=1; shift ;;
    -h|--help) usage 0 ;;
    *) log "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ "$PORTS" == "lan" || "$PORTS" == "local" ]] || { log "--ports must be lan or local" >&2; exit 1; }
PORTS_FILE="docker-compose.${PORTS}.yml"
FRONTEND_PORTS_FILE="docker-compose.frontend.${PORTS}.yml"

is_site_root() {
  local d="$1"
  [[ -f "$d/docker-compose.apps.yml" || -f "$d/docker-compose.custom.yml" || -f "$d/.env" || -d "$d/data" ]]
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(basename "$HERE")" == "upstream" ]] && is_site_root "$(cd "$HERE/.." && pwd)"; then
  SITE_ROOT="$(cd "$HERE/.." && pwd)"
  UPSTREAM="$HERE"
elif [[ -f "$HERE/upstream/docker-compose.yml" || -f "$HERE/upstream/docker-compose.backend.yml" ]]; then
  SITE_ROOT="$HERE"
  UPSTREAM="$HERE/upstream"
else
  log "Run from site root (has upstream/) or from upstream/ inside a site instance." >&2
  exit 1
fi

command -v git >/dev/null || { log "git required" >&2; exit 1; }
[[ "$START" -eq 1 ]] && command -v docker >/dev/null || true
[[ "$START" -eq 1 ]] && { command -v docker >/dev/null || { log "docker required" >&2; exit 1; }; }

log "Site root : $SITE_ROOT"
log "Updating  : $UPSTREAM"

cd "$UPSTREAM"
git fetch origin
git checkout main
# Prefer hard reset: upstream may be force-pushed (orphan/history rewrite).
git reset --hard origin/main
REV="$(git rev-parse --short HEAD)"
log "Upstream  : $REV"

for n in Collect-HomelabDiag.sh Collect-HomelabDiag.ps1 Dump-PkmSidebar.py; do
  if [[ -f "$UPSTREAM/$n" ]]; then
    cp -a "$UPSTREAM/$n" "$SITE_ROOT/$n"
    [[ "$n" == *.sh ]] && chmod +x "$SITE_ROOT/$n"
    log "Copied $n to site root."
  fi
done
uf="Upstream files:"
for n in docker-compose.backend.yml Collect-HomelabDiag.sh Update-HomelabUpstream.sh; do
  if [[ -f "$UPSTREAM/$n" ]]; then uf="$uf $n=yes"; else uf="$uf $n=NO"; fi
done
log "$uf"

# Site-root copies can predate new product trees (scriptkit/, agent-context/, …).
# After pull, re-enter the updater that just landed in upstream/.
if [[ -z "${HOMELAB_UPSTREAM_REEXEC:-}" ]]; then
  canonical="$UPSTREAM/Update-HomelabUpstream.sh"
  if [[ -f "$canonical" ]]; then
    this="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    can="$(cd "$(dirname "$canonical")" && pwd)/$(basename "$canonical")"
    if [[ "$this" != "$can" ]]; then
      log "Re-running updater from upstream/ so new product files are copied onto the site root."
      export HOMELAB_UPSTREAM_REEXEC=1
      reexec_args=()
      [[ "$PORTS" != "lan" ]] && reexec_args+=(--ports "$PORTS")
      [[ "$PUSH" -eq 1 ]] && reexec_args+=(--push)
      [[ "$PUSH" -eq 0 && "$COMMIT" -eq 1 ]] && reexec_args+=(--commit)
      [[ "$START" -eq 1 ]] && reexec_args+=(--start)
      exec /bin/bash "$canonical" "${reexec_args[@]}"
    fi
  fi
fi

# Refresh site-root launchers from product package.
# Also refreshes scriptkit/, agent-context/ (not site/), docker/*.example,
# and overrides/hub-platform/sitecustomize.py.
# Never overwrites docker-compose.custom.yml, docker-compose.apps.yml,
# README.md, docker/**/Dockerfile, or cli/.
LAUNCHERS=(
  Update-HomelabUpstream.sh
  Update-HomelabUpstream.ps1
  Backup-DataGit.sh
  Backup-DataGit.ps1
  Register-DataGitBackup.sh
  Register-DataGitBackupTask.ps1
  Pull-DataGit.sh
  Pull-DataGit.ps1
  Pull.sh
  Pull.ps1
  Start-MarketPlugins.sh
  Start-MarketPlugins.ps1
  Wait-HomelabReady.sh
  Wait-HomelabReady.ps1
  Run-HomelabSite.sh
  Run-HomelabSite.ps1
  Pull.sh
  Pull.ps1
  Pull-PkmDataKeepScripts.sh
  Pull-PkmDataKeepScripts.ps1
  Collect-HomelabDiag.sh
  Collect-HomelabDiag.ps1
  Dump-PkmSidebar.py
  Register-DataGitPull.sh
  Register-DataGitPullTask.ps1
  Reindex-PkmFromDisk.sh
  Reindex-PkmFromDisk.ps1
  Merge-SqliteGitConflict.py
  Normalize-PkmDuplicatePaths.py
  Refresh-SiteProductTrees.sh
  Refresh-SiteProductTrees.ps1
  docker-compose.config.yml
  docker-compose.https.yml
  Caddyfile
  README.site.md
)
REFRESHED=()
for s in "${LAUNCHERS[@]}"; do
  if [[ -f "$UPSTREAM/$s" ]]; then
    # Copy via temp + mv so a running bash script keeps its old inode.
    tmp="$(mktemp "$SITE_ROOT/tmp-launcher.XXXXXX")"
    cp -a "$UPSTREAM/$s" "$tmp"
    [[ "$s" == *.sh ]] && chmod +x "$tmp"
    mv -f "$tmp" "$SITE_ROOT/$s"
    REFRESHED+=("$s")
  fi
done
if [[ ${#REFRESHED[@]} -gt 0 ]]; then
  log "Refreshed site-root: ${REFRESHED[*]}"
fi

OVERRIDE_REL="overrides/hub-platform/sitecustomize.py"
if [[ -f "$UPSTREAM/$OVERRIDE_REL" ]]; then
  mkdir -p "$SITE_ROOT/overrides/hub-platform"
  cp -a "$UPSTREAM/$OVERRIDE_REL" "$SITE_ROOT/$OVERRIDE_REL"
  log "Refreshed $OVERRIDE_REL"
fi

GITIGNORE_PLACEHOLDER='# Site-specific ignore rules go here. Product rules are in .gitignore.upstream.'

gitignore_extras() {
  local existing="$1" product="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" ]] && continue
    [[ "$line" == "# Generated"* ]] && continue
    [[ "$line" == "# Site-specific"* ]] && continue
    [[ "$line" == "# Site extras"* ]] && continue
    [[ "$line" == "# Product rules:"* ]] && continue
    grep -qxF "$line" <(tr -d '\r' < "$product") 2>/dev/null && continue
    printf '%s\n' "$line"
  done < "$existing"
}

UPSTREAM_GITIGNORE="$UPSTREAM/.gitignore"
SITE_GITIGNORE_UPSTREAM="$SITE_ROOT/.gitignore.upstream"
SITE_GITIGNORE_CUSTOM="$SITE_ROOT/.gitignore.custom"
SITE_GITIGNORE="$SITE_ROOT/.gitignore"
if [[ -f "$UPSTREAM_GITIGNORE" ]]; then
  if [[ ! -f "$SITE_GITIGNORE_CUSTOM" ]]; then
    extras=""
    if [[ -f "$SITE_GITIGNORE" ]]; then
      extras="$(gitignore_extras "$SITE_GITIGNORE" "$UPSTREAM_GITIGNORE" || true)"
    fi
    if [[ -n "${extras:-}" ]]; then
      printf '%s\n' "$extras" >"$SITE_GITIGNORE_CUSTOM"
    else
      printf '%s\n' "$GITIGNORE_PLACEHOLDER" >"$SITE_GITIGNORE_CUSTOM"
    fi
  fi
  cp -a "$UPSTREAM_GITIGNORE" "$SITE_GITIGNORE_UPSTREAM"
  {
    printf '%s\n' \
      '# Generated. Do not edit this file.' \
      '# Product rules: .gitignore.upstream (refreshed by Update-HomelabUpstream).' \
      '# Site extras: .gitignore.custom'
    cat "$UPSTREAM_GITIGNORE"
    printf '\n%s\n' '# Site extras from .gitignore.custom.'
    cat "$SITE_GITIGNORE_CUSTOM"
  } >"$SITE_GITIGNORE"
fi

if [[ -f "$UPSTREAM/Refresh-SiteProductTrees.sh" ]]; then
  chmod +x "$UPSTREAM/Refresh-SiteProductTrees.sh" 2>/dev/null || true
  /bin/bash "$UPSTREAM/Refresh-SiteProductTrees.sh" "$UPSTREAM" "$SITE_ROOT"
  log "Copied scriptkit/, agent-context/, docker examples onto the site root."
else
  log "Refresh-SiteProductTrees.sh missing in upstream/; site-root scriptkit/ was not refreshed." >&2
fi

cd "$SITE_ROOT"

env_val() {
  local key="$1" file="$2"
  grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//'
}

https_overlay_enabled() {
  local envf="$SITE_ROOT/.env"
  local overlay="$SITE_ROOT/docker-compose.https.yml"
  [[ -f "$overlay" && -f "$envf" ]] || return 1
  local hub pkm
  hub="$(env_val HUB_HOSTNAME "$envf")"
  pkm="$(env_val PKM_HOSTNAME "$envf")"
  [[ -n "$hub" && -n "$pkm" ]]
}

if [[ "$COMMIT" -eq 1 ]]; then
  [[ -d "$SITE_ROOT/.git" ]] || { log "No .git in site root" >&2; exit 1; }
  git add upstream
  for s in "${LAUNCHERS[@]}"; do
    [[ -f "$s" ]] && git add "$s" || true
  done
  git add .gitignore .gitignore.custom .gitignore.upstream 2>/dev/null || true
  git add scriptkit agent-context docker docker-compose.custom.example.yml docker-compose.apps.example.yml 2>/dev/null || true
  if [[ -n "$(git status --porcelain -- upstream .gitignore .gitignore.custom .gitignore.upstream scriptkit agent-context docker docker-compose.custom.example.yml docker-compose.apps.example.yml "${LAUNCHERS[@]}" 2>/dev/null || true)" ]]; then
    git commit -m "Bump homelab-deploy upstream (${REV})."
    log "Committed submodule pointer."
  else
    log "Upstream pointer unchanged; nothing to commit."
  fi
fi

if [[ "$PUSH" -eq 1 ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [[ -n "$branch" && "$branch" != "HEAD" ]] || { log "Detached HEAD is not supported for --push." >&2; exit 1; }
  git fetch origin
  if ! git pull --rebase --autostash origin "$branch"; then
    git rebase --abort >/dev/null 2>&1 || true
    git merge --no-edit "origin/$branch"
  fi
  git push origin "$branch"
  log "Pushed."
fi

if [[ "$START" -eq 1 ]]; then
  [[ -f .env ]] || { log "Missing .env in site root" >&2; exit 1; }
  plugins="$SITE_ROOT/Start-MarketPlugins.sh"
  if [[ -f "$plugins" ]]; then
    log "Attaching market plugin compose includes..."
    chmod +x "$plugins" 2>/dev/null || true
    HOMELAB_SKIP_MARKET_COMPOSE=1 HOMELAB_PORTS="$PORTS" /bin/bash "$plugins" || log "Start-MarketPlugins did not fully succeed." >&2
  fi
  log "Starting Compose (stop old containers if names conflict)..."
  for n in pkm-backend pkm-frontend home-hub home-hub-platform pkm-https; do
    docker rm -f "$n" >/dev/null 2>&1 || true
  done
  docker compose --project-directory . \
    -f upstream/docker-compose.backend.yml \
    -f "upstream/$PORTS_FILE" \
    -f docker-compose.config.yml \
    -f docker-compose.custom.yml \
    -f docker-compose.apps.yml pull
  docker compose --project-directory . \
    -f upstream/docker-compose.backend.yml \
    -f "upstream/$PORTS_FILE" \
    -f docker-compose.config.yml \
    -f docker-compose.custom.yml \
    -f docker-compose.apps.yml up -d
  docker compose --project-directory . \
    -f upstream/docker-compose.backend.yml \
    -f "upstream/$PORTS_FILE" \
    -f docker-compose.config.yml \
    -f docker-compose.custom.yml \
    -f docker-compose.apps.yml \
    rm --force >/dev/null 2>&1 || true
  ids="$(docker ps -aq --filter label=homelab.config-job=true --filter status=exited 2>/dev/null || true)"
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
  if https_overlay_enabled; then
    log "LAN HTTPS overlay (Caddy) enabled."
    extra_fe=()
    [[ -f docker-compose.frontend.apps.yml ]] && extra_fe+=(-f docker-compose.frontend.apps.yml)
    docker compose --project-directory . \
      -f upstream/docker-compose.frontend.yml \
      -f "upstream/$FRONTEND_PORTS_FILE" \
      "${extra_fe[@]}" \
      -f docker-compose.https.yml pull
    docker compose --project-directory . \
      -f upstream/docker-compose.frontend.yml \
      -f "upstream/$FRONTEND_PORTS_FILE" \
      "${extra_fe[@]}" \
      -f docker-compose.https.yml up -d
  else
    extra_fe=()
    [[ -f docker-compose.frontend.apps.yml ]] && extra_fe+=(-f docker-compose.frontend.apps.yml)
    docker compose --project-directory . \
      -f upstream/docker-compose.frontend.yml \
      -f "upstream/$FRONTEND_PORTS_FILE" \
      "${extra_fe[@]}" pull
    docker compose --project-directory . \
      -f upstream/docker-compose.frontend.yml \
      -f "upstream/$FRONTEND_PORTS_FILE" \
      "${extra_fe[@]}" up -d
  fi
  log "Compose up done."

  helper="$SITE_ROOT/Reindex-PkmFromDisk.sh"
  if [[ ! -f "$helper" ]]; then
    log "PKM disk reindex skipped (Reindex-PkmFromDisk.sh not found)."
  else
    log "Importing PKM pages, files, PDFs, and bookmarks from disk..."
    chmod +x "$helper" 2>/dev/null || true
    set +e
    /bin/bash "$helper" --skip-restart
    reindex_code=$?
    set -e
    if [[ "$reindex_code" -ne 0 ]]; then
      log "PKM disk reindex failed after Compose up. Use Import from disk in the PKM UI if items are missing." >&2
    fi
  fi
fi

if [[ "$START" -ne 1 ]]; then
  plugins="$SITE_ROOT/Start-MarketPlugins.sh"
  if [[ -f "$plugins" ]]; then
    log "Starting market plugins on homelab-backend / homelab-frontend..."
    chmod +x "$plugins" 2>/dev/null || true
    HOMELAB_PORTS="$PORTS" /bin/bash "$plugins" || log "Start-MarketPlugins did not fully succeed." >&2
  fi
fi

wait_ready="$SITE_ROOT/Wait-HomelabReady.sh"
if [[ -f "$wait_ready" ]]; then
  log "Waiting until PKM API and web UI are ready..."
  chmod +x "$wait_ready" 2>/dev/null || true
  HOMELAB_PORTS="$PORTS" /bin/bash "$wait_ready"
fi

log "Done."
