#!/usr/bin/env bash
# Prints a troubleshooting dump for Hub/PKM/Guacamole. No document bodies, no .env secrets.
# Run from the site root or from upstream/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
is_site_root() {
  local dir="$1"
  [[ -f "$dir/docker-compose.apps.yml" || -f "$dir/docker-compose.custom.yml" || -f "$dir/.env" ]] && return 0
  [[ -d "$dir/data" ]] && return 0
  return 1
}
if [[ "$(basename "$SCRIPT_DIR")" == "upstream" ]] && is_site_root "$(dirname "$SCRIPT_DIR")"; then
  ROOT="$(dirname "$SCRIPT_DIR")"
elif is_site_root "$SCRIPT_DIR"; then
  ROOT="$SCRIPT_DIR"
else
  echo "Run from site root or upstream/." >&2
  exit 1
fi
cd "$ROOT"

mkdir -p "$ROOT/logs"
OUT="$ROOT/logs/homelab-diag-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1
echo "Writing $OUT"

redact_url() {
  python3 -c 'import re,sys; print(re.sub(r"://[^/@]+@", "://***@", sys.argv[1] if len(sys.argv)>1 else ""))' "${1:-}" 2>/dev/null || echo "(url hidden)"
}

section() { printf '\n== %s ==\n' "$1"; }

section "host"
uname -a 2>/dev/null || true
echo "site_root=$ROOT"
date -Iseconds 2>/dev/null || date

section "git"
if [[ -d "$ROOT/.git" || -f "$ROOT/.git" ]]; then
  git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true
  origin="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  echo -n "origin="
  redact_url "$origin"
  git -C "$ROOT" status --porcelain -- data/pkm data/hub 2>/dev/null | head -n 40 || true
else
  echo "NO_SITE_GIT"
fi

section "env_keys"
if [[ -f "$ROOT/.env" ]]; then
  grep -E '^(PUID|PGID|HUB_DEFAULT_MARKET_PLUGINS|HUB_BUILTIN_PLUGINS|HOMELAB_VERSION|PKM_VERSION)=' "$ROOT/.env" | sed 's/\r$//' || true
else
  echo "NO_DOTENV"
fi

section "pull_script"
if [[ -f "$ROOT/Pull-PkmDataKeepScripts.sh" ]]; then
  grep -E 'restore|checkout|data/pkm|data/hub' "$ROOT/Pull-PkmDataKeepScripts.sh" | head -n 20
else
  echo "NO_PULL_SCRIPT"
fi

section "compose_guacamole_mentions"
grep -n -i guacamole docker-compose*.yml upstream/docker-compose*.yml 2>/dev/null | grep -v Binary || echo "(none)"

section "data_tree"
echo -n "pkm.db "; if [[ -f data/pkm/pkm.db ]]; then wc -c < data/pkm/pkm.db; else echo MISSING; fi
echo -n "platform.db "; if [[ -f data/hub/platform.db ]]; then wc -c < data/hub/platform.db; else echo MISSING; fi
echo "pkm top:"
ls -la data/pkm 2>/dev/null || echo MISSING
echo "docs dirs:"
ls -1 data/pkm/docs 2>/dev/null | head -n 40 || true
echo "hub top:"
ls -la data/hub 2>/dev/null || echo MISSING
echo "guacamole plugin files:"
ls -la data/hub/plugins/guacamole 2>/dev/null || echo MISSING

section "sqlite_pkm_pages"
DUMP_PY="$ROOT/Dump-PkmSidebar.py"
[[ -f "$DUMP_PY" ]] || DUMP_PY="$ROOT/upstream/Dump-PkmSidebar.py"
ORIGIN_DB=""
section "pkm_order_remote_vs_local"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
if [[ -n "$BRANCH" && "$BRANCH" != "HEAD" ]]; then
  SRC="origin/${BRANCH}"
  export SRC ROOT
  git fetch origin "$BRANCH" >/dev/null 2>&1 || echo "git fetch failed"
  if git cat-file -e "${SRC}:data/pkm/pkm.db" 2>/dev/null; then
    ORIGIN_DB="$(mktemp "${TMPDIR:-/tmp}/pkm-origin.XXXXXX.db")"
    git show "${SRC}:data/pkm/pkm.db" > "$ORIGIN_DB"
    echo "origin pkm.db bytes=$(wc -c < "$ORIGIN_DB")"
  else
    echo "NO_ORIGIN_PKM_DB"
  fi
  echo "origin docs dirs:"
  git ls-tree --name-only "${SRC}:data/pkm/docs" 2>/dev/null | sed 's|^|data/pkm/docs/|' || echo "(ls-tree failed)"
  echo "docs_dir_compare:"
  python3 - <<PY 2>/dev/null || python - <<PY 2>/dev/null || true
import os, subprocess
src = os.environ.get("SRC", "")
root = os.environ.get("ROOT", ".")
try:
    origin = subprocess.check_output(["git", "ls-tree", "--name-only", src + ":data/pkm/docs"], text=True, cwd=root)
except Exception:
    origin = ""
origin_set = {"data/pkm/docs/" + n.strip() for n in origin.splitlines() if n.strip()}
docs = os.path.join(root, "data", "pkm", "docs")
local_set = set()
if os.path.isdir(docs):
    local_set = {"data/pkm/docs/" + n for n in os.listdir(docs)}
extra = sorted(local_set - origin_set)
missing = sorted(origin_set - local_set)
for d in extra:
    print("local_not_on_origin", d)
for d in missing:
    print("origin_not_local", d)
if origin_set and origin_set == local_set:
    print("DOCS_DIRS_MATCH")
elif not origin_set:
    print("origin_docs_empty_or_failed")
PY
else
  echo "NO_BRANCH"
fi

if [[ -f "$DUMP_PY" && -f data/pkm/pkm.db ]]; then
  if command -v python3 >/dev/null 2>&1; then PY=python3; else PY=python; fi
  if [[ -n "$ORIGIN_DB" && -f "$ORIGIN_DB" ]]; then
    "$PY" "$DUMP_PY" data/pkm/pkm.db "$ORIGIN_DB"
  else
    "$PY" "$DUMP_PY" data/pkm/pkm.db
  fi
else
  echo "Dump-PkmSidebar.py/python/pkm.db unavailable"
fi
[[ -n "$ORIGIN_DB" && -f "$ORIGIN_DB" ]] && rm -f -- "$ORIGIN_DB"

section "sqlite_hub_plugins"
python3 - <<'PY' 2>/dev/null || python - <<'PY' 2>/dev/null || echo "python unavailable"
import os, sqlite3
p = "data/hub/platform.db"
if not os.path.isfile(p):
    print("NO_HUB_DB")
else:
    c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
    try:
        for r in c.execute("SELECT id, enabled, local_port, install_path FROM plugins"):
            print("|".join("" if x is None else str(x) for x in r))
    except Exception as e:
        print("query_failed", e)
    try:
        print("opt_out", [x[0] for x in c.execute("SELECT id FROM plugin_opt_out")])
    except Exception:
        pass
PY

section "docker"
if command -v docker >/dev/null 2>&1; then
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  for c in pkm-backend home-hub-platform home-hub homelab-guacamole; do
    echo "-- $c --"
    docker inspect "$c" --format '{{.Name}} status={{.State.Status}} user={{.Config.User}}
labels.project={{index .Config.Labels "com.docker.compose.project"}}
labels.workdir={{index .Config.Labels "com.docker.compose.project.working_dir"}}
labels.files={{index .Config.Labels "com.docker.compose.project.config_files"}}
{{range .Mounts}}{{.Source}} -> {{.Destination}}
{{end}}' 2>/dev/null || echo "missing"
  done
  echo "-- pkm-backend last logs --"
  docker logs --tail 15 pkm-backend 2>&1 | tail -n 15 || true
  echo "-- hub-platform guacamole/market lines --"
  docker logs home-hub-platform 2>&1 | grep -iE 'guacamole|market plugin|ERROR' | tail -n 20 || true
else
  echo "NO_DOCKER"
fi

echo
echo "Wrote $OUT"
echo "Done. Paste this output (it has no file contents and no passwords)."
