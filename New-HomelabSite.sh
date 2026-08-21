#!/usr/bin/env bash
# Convert a flat homelab-deploy install into a site instance (in place).
# Same behaviour as New-HomelabSite.ps1.
#
# Usage:
#   ./New-HomelabSite.sh --site-repo https://github.com/ORG/REPO.git --push --start
set -euo pipefail

SITE_REPO=""
BRANCH="homelab"
TARGET_DIR=""
UPSTREAM_URL="https://github.com/opendevtools-org/homelab-deploy.git"
PORTS="lan"
SKIP_GIT=0
PUSH=0
START=0
SKIP_COMMIT=0

usage() {
  sed -n '2,8p' "$0" | sed 's/^# //'
  echo "Options: --site-repo URL  --branch NAME  --target-dir PATH  --upstream-url URL"
  echo "         --ports lan|local  --skip-git  --push  --start  --skip-commit"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-repo) SITE_REPO="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --target-dir) TARGET_DIR="$2"; shift 2 ;;
    --upstream-url) UPSTREAM_URL="$2"; shift 2 ;;
    --ports) PORTS="$2"; shift 2 ;;
    --skip-git) SKIP_GIT=1; shift ;;
    --push) PUSH=1; shift ;;
    --start) START=1; shift ;;
    --skip-commit) SKIP_COMMIT=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Required command not found: $1" >&2; exit 1; }; }
need git
[[ "$START" -eq 1 ]] && need docker
if [[ "$SKIP_GIT" -eq 0 && -z "$SITE_REPO" ]]; then
  echo "Pass --site-repo URL or --skip-git" >&2
  exit 1
fi
if [[ "$PORTS" != "lan" && "$PORTS" != "local" ]]; then
  echo "--ports must be lan or local" >&2
  exit 1
fi
PORTS_FILE="docker-compose.${PORTS}.yml"
FRONTEND_PORTS_FILE="docker-compose.frontend.${PORTS}.yml"

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$(cd "${TARGET_DIR:-$SCRIPT_ROOT}" && pwd)"
[[ -d "$TARGET_DIR" ]] || { echo "Target dir not found: $TARGET_DIR" >&2; exit 1; }

already_site=0
is_flat=0
[[ -f "$TARGET_DIR/upstream/docker-compose.yml" || -f "$TARGET_DIR/upstream/docker-compose.backend.yml" ]] && already_site=1
[[ -f "$TARGET_DIR/docker-compose.yml" || -f "$TARGET_DIR/docker-compose.backend.yml" ]] && is_flat=1
if [[ "$already_site" -eq 0 && "$is_flat" -eq 0 ]]; then
  echo "Neither flat install nor site instance: $TARGET_DIR" >&2
  exit 1
fi

echo "Mode       : in-place convert"
echo "TargetDir  : $TARGET_DIR"
echo "SiteRepo   : ${SITE_REPO:-(skip git remote)}"
echo "Branch     : $BRANCH"
echo "Upstream   : $UPSTREAM_URL"
echo "Ports      : $PORTS_FILE"

BAK="$(mktemp -d "${TMPDIR:-/tmp}/homelab-inplace.XXXXXX")"
echo "Backup     : $BAK"
cleanup_bak() { rm -rf "$BAK"; }
trap cleanup_bak EXIT

if [[ -d "$TARGET_DIR/data" ]]; then
  mkdir -p "$BAK/data"
  cp -a "$TARGET_DIR/data/." "$BAK/data/"
fi
for name in .env docker-compose.apps.yml .env.example; do
  [[ -f "$TARGET_DIR/$name" ]] && cp -a "$TARGET_DIR/$name" "$BAK/$name"
done

cd "$TARGET_DIR"

if [[ -d "$TARGET_DIR/.git" ]]; then
  remotes="$(git remote -v 2>/dev/null || true)"
  if [[ "$already_site" -eq 0 && "$remotes" == *homelab-deploy* ]]; then
    echo "Detaching product .git (was a homelab-deploy clone)..."
    rm -rf "$TARGET_DIR/.git"
  elif [[ "$already_site" -eq 1 && "$SKIP_GIT" -eq 0 && -n "$SITE_REPO" ]]; then
    git remote remove origin 2>/dev/null || true
    git remote add origin "$SITE_REPO"
  fi
fi

if [[ "$already_site" -eq 0 ]]; then
  for f in \
    docker-compose.yml docker-compose.backend.yml docker-compose.frontend.yml \
    docker-compose.lan.yml docker-compose.local.yml \
    docker-compose.frontend.lan.yml docker-compose.frontend.local.yml \
    docker-compose.frontend.remote.yml \
    docker-compose.apps.yml docker-compose.apps.example.yml \
    LICENSE README.md \
    New-HomelabSite.ps1 New-HomelabSite.sh \
    Update-HomelabUpstream.ps1 Update-HomelabUpstream.sh \
    Backup-DataGit.ps1 Backup-DataGit.sh \
    Register-DataGitBackupTask.ps1 Register-DataGitBackup.sh \
    Pull-DataGit.ps1 Pull-DataGit.sh \
    Register-DataGitPullTask.ps1 Register-DataGitPull.sh \
    docker-compose.config.yml
  do
    # keep apps.yml content via backup; remove product copy from root
    [[ "$f" == "docker-compose.apps.yml" ]] && continue
    rm -f "$TARGET_DIR/$f"
  done
  # product apps.yml will be restored from backup or upstream
  rm -f "$TARGET_DIR/docker-compose.apps.yml"
fi

if [[ "$SKIP_GIT" -eq 0 ]]; then
  if [[ ! -d "$TARGET_DIR/.git" ]]; then
    echo "Initializing site git repo..."
    git init -b main
    git remote add origin "$SITE_REPO"
    git config user.name >/dev/null 2>&1 || git config user.name "Homelab Setup"
    git config user.email >/dev/null 2>&1 || git config user.email "homelab@localhost"
  else
    git remote remove origin 2>/dev/null || true
    git remote add origin "$SITE_REPO"
  fi

  git fetch origin 2>/dev/null || true
  if git ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q .; then
    echo "Checking out site branch $BRANCH"
    git fetch origin "$BRANCH"
    git checkout -B "$BRANCH" "origin/$BRANCH"
  else
    cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$cur" == "$BRANCH" ]]; then
      echo "Already on site branch $BRANCH"
    else
      echo "Creating orphan branch $BRANCH"
      if git rev-parse HEAD >/dev/null 2>&1; then
        git checkout --orphan "$BRANCH"
      else
        git checkout -B "$BRANCH"
      fi
      git rm -rf --ignore-unmatch . >/dev/null 2>&1 || true
    fi
  fi
fi

cd "$TARGET_DIR"
if [[ -e "$TARGET_DIR/upstream/.git" ]]; then
  echo "upstream/ submodule already present."
elif [[ -e "$TARGET_DIR/upstream" ]]; then
  rm -rf "$TARGET_DIR/upstream"
  echo "Adding upstream submodule..."
  if [[ "$SKIP_GIT" -eq 0 && -d "$TARGET_DIR/.git" ]]; then
    git submodule add --force "$UPSTREAM_URL" upstream
  else
    git clone "$UPSTREAM_URL" "$TARGET_DIR/upstream"
  fi
else
  echo "Adding upstream submodule..."
  if [[ "$SKIP_GIT" -eq 0 && -d "$TARGET_DIR/.git" ]]; then
    git submodule deinit -f upstream 2>/dev/null || true
    git rm -f upstream 2>/dev/null || true
    rm -f "$TARGET_DIR/.gitmodules"
    git submodule add --force "$UPSTREAM_URL" upstream
  else
    git clone "$UPSTREAM_URL" "$TARGET_DIR/upstream"
  fi
fi

echo "Restoring data/ and site overlay..."
if [[ -d "$BAK/data" ]]; then
  mkdir -p "$TARGET_DIR/data"
  cp -a "$BAK/data/." "$TARGET_DIR/data/"
else
  mkdir -p "$TARGET_DIR/data/hub" "$TARGET_DIR/data/pkm"
fi

if [[ -f "$BAK/.env" ]]; then
  cp -a "$BAK/.env" "$TARGET_DIR/.env"
elif [[ -f "$TARGET_DIR/upstream/.env.example" ]]; then
  cp -a "$TARGET_DIR/upstream/.env.example" "$TARGET_DIR/.env"
  echo "Created .env from upstream/.env.example — edit secrets if needed."
fi

if [[ -f "$BAK/docker-compose.apps.yml" ]]; then
  cp -a "$BAK/docker-compose.apps.yml" "$TARGET_DIR/docker-compose.apps.yml"
elif [[ -f "$TARGET_DIR/upstream/docker-compose.apps.yml" ]]; then
  cp -a "$TARGET_DIR/upstream/docker-compose.apps.yml" "$TARGET_DIR/docker-compose.apps.yml"
else
  printf '%s\n' '# Optional services for this host.' 'services: {}' >"$TARGET_DIR/docker-compose.apps.yml"
fi

[[ -f "$TARGET_DIR/upstream/.env.example" ]] && cp -a "$TARGET_DIR/upstream/.env.example" "$TARGET_DIR/.env.example"

cat >"$TARGET_DIR/.gitignore" <<'EOF'
.env
*.tar
logs/
upstream/data/
**/__pycache__/
data/pkm/scripts/**/.uploads/
EOF

cat >"$TARGET_DIR/README.md" <<EOF
# Homelab site instance

- \`upstream/\` — submodule ($UPSTREAM_URL)
- \`data/\` — volumes
- \`docker-compose.config.yml\` — one-time PKM data ownership
- \`docker-compose.apps.yml\` — extra services
- \`.env\` — secrets (not committed)
- \`Update-HomelabUpstream.*\` — pull product updates
- \`Backup-DataGit.*\` / \`Register-DataGitBackup*\` — primary server commit/push
- \`Pull-DataGit.*\` / \`Register-DataGitPull*\` — standby server sync

## Start

\`\`\`bash
docker compose --project-directory . \\
  -f upstream/docker-compose.backend.yml \\
  -f upstream/$PORTS_FILE \\
  -f docker-compose.config.yml \\
  -f docker-compose.apps.yml up -d
docker compose --project-directory . \\
  -f upstream/docker-compose.frontend.yml \\
  -f upstream/$FRONTEND_PORTS_FILE up -d
\`\`\`

## Update product

\`\`\`bash
./Update-HomelabUpstream.sh --commit --push --start
# or: ./Update-HomelabUpstream.ps1 -Commit -Push -Start
\`\`\`

## Git sync

Optional HTTPS auth in \`.env\`: \`HOMELAB_GIT_USERNAME\` and \`HOMELAB_GIT_PAT\`.

Two servers with the same data: primary runs Backup (00:05), standby runs Pull (00:10).
Conflicts keep the remote file and save the local copy as \`name.local-conflict.HOST.TIMESTAMP.ext\`.

\`\`\`bash
./Register-DataGitBackup.sh --time 00:05
./Backup-DataGit.sh
./Register-DataGitPull.sh --time 00:10
./Pull-DataGit.sh
\`\`\`

\`\`\`powershell
.\\Register-DataGitBackupTask.ps1 -Time 00:05
.\\Backup-DataGit.ps1
.\\Register-DataGitPullTask.ps1 -Time 00:10
.\\Pull-DataGit.ps1
\`\`\`
EOF

for s in \
  Update-HomelabUpstream.sh Update-HomelabUpstream.ps1 \
  Backup-DataGit.sh Backup-DataGit.ps1 \
  Register-DataGitBackup.sh Register-DataGitBackupTask.ps1 \
  Pull-DataGit.sh Pull-DataGit.ps1 \
  Register-DataGitPull.sh Register-DataGitPullTask.ps1 \
  docker-compose.config.yml
do
  if [[ -f "$TARGET_DIR/upstream/$s" ]]; then
    cp -a "$TARGET_DIR/upstream/$s" "$TARGET_DIR/$s"
    [[ "$s" == *.sh ]] && chmod +x "$TARGET_DIR/$s"
  fi
done
[[ -f "$TARGET_DIR/upstream/New-HomelabSite.sh" ]] && chmod +x "$TARGET_DIR/upstream/New-HomelabSite.sh" || true
[[ -f "$TARGET_DIR/upstream/Backup-DataGit.sh" ]] && chmod +x "$TARGET_DIR/upstream/Backup-DataGit.sh" || true
[[ -f "$TARGET_DIR/upstream/Register-DataGitBackup.sh" ]] && chmod +x "$TARGET_DIR/upstream/Register-DataGitBackup.sh" || true
[[ -f "$TARGET_DIR/upstream/Pull-DataGit.sh" ]] && chmod +x "$TARGET_DIR/upstream/Pull-DataGit.sh" || true
[[ -f "$TARGET_DIR/upstream/Register-DataGitPull.sh" ]] && chmod +x "$TARGET_DIR/upstream/Register-DataGitPull.sh" || true

if [[ "$SKIP_GIT" -eq 0 && "$SKIP_COMMIT" -eq 0 && -d "$TARGET_DIR/.git" ]]; then
  cd "$TARGET_DIR"
  git rm --cached -f --ignore-unmatch .env >/dev/null 2>&1 || true
  git add -A
  git rm --cached -f --ignore-unmatch .env >/dev/null 2>&1 || true
  if git diff --cached --name-only | grep -E '(^|/)\.env$' >/dev/null; then
    echo "Refusing to commit: .env is staged" >&2
    exit 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    git commit -m "Homelab site instance: upstream submodule + local data/apps."
  else
    echo "Nothing new to commit."
  fi
fi

if [[ "$PUSH" -eq 1 ]]; then
  [[ "$SKIP_GIT" -eq 1 || -z "$SITE_REPO" ]] && { echo "--push requires --site-repo" >&2; exit 1; }
  cd "$TARGET_DIR"
  echo "Pushing $BRANCH ..."
  if ! git push -u origin "$BRANCH"; then
    echo "Push failed; retrying with --force-with-lease ..."
    git push --force-with-lease -u origin "$BRANCH"
  fi
fi

if [[ "$START" -eq 1 ]]; then
  cd "$TARGET_DIR"
  [[ -f .env ]] || { echo "Missing .env" >&2; exit 1; }
  echo "Starting Compose (backend then frontend)..."
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
fi

echo
echo "Done. Flat install converted in place:"
echo "  $TARGET_DIR"
echo "  Backend:  docker compose --project-directory . -f upstream/docker-compose.backend.yml -f upstream/$PORTS_FILE -f docker-compose.config.yml -f docker-compose.apps.yml up -d"
echo "  Frontend: docker compose --project-directory . -f upstream/docker-compose.frontend.yml -f upstream/$FRONTEND_PORTS_FILE up -d"
