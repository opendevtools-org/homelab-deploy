#!/usr/bin/env bash
# After git sync of data/, restart PKM and import pages/files/PDFs/bookmarks from disk.
# Same role as Reindex-PkmFromDisk.ps1. Safe to run on its own from the site root.
#
# Usage:
#   ./Reindex-PkmFromDisk.sh
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${HOMELAB_PKM_CONTAINER:-pkm-backend}"
FLAG="${HOMELAB_PKM_REINDEX_AFTER_SYNC:-true}"

export_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  set +a
}

flag_disabled() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    0|false|no|off) return 0 ;;
    *) return 1 ;;
  esac
}

skip() {
  echo "$1"
  exit 0
}

fail() {
  echo "$1" >&2
  exit 1
}

export_env_file "$SCRIPT_ROOT/.env"
CONTAINER="${HOMELAB_PKM_CONTAINER:-$CONTAINER}"
FLAG="${HOMELAB_PKM_REINDEX_AFTER_SYNC:-$FLAG}"

if flag_disabled "$FLAG"; then
  skip "PKM disk reindex skipped (HOMELAB_PKM_REINDEX_AFTER_SYNC=${FLAG})."
fi

command -v docker >/dev/null 2>&1 || skip "PKM disk reindex skipped (docker not found)."

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  skip "PKM disk reindex skipped (container '${CONTAINER}' not found)."
fi

RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)"
if [[ "$RUNNING" == "true" ]]; then
  docker restart "$CONTAINER" >/dev/null || fail "Failed to restart container '${CONTAINER}'."
  echo "Restarted ${CONTAINER} so SQLite reopens after git sync."
else
  docker start "$CONTAINER" >/dev/null || fail "Failed to start container '${CONTAINER}'."
  echo "Started ${CONTAINER}."
fi

PY=$(cat <<'PY'
import json, os, time, urllib.error, urllib.parse, urllib.request

BASE = "http://127.0.0.1:8000/api"
USER = os.environ.get("ADMIN_USERNAME") or "admin"
PASSWORD = os.environ.get("ADMIN_PASSWORD") or ""
ENDPOINTS = (
    "/system/reindex",
    "/system/reindex-files",
    "/system/reindex-pdfs",
    "/system/reindex-bookmarks",
)


def request(method, path, data=None, token=None, timeout=300, content_type=None, raw=None):
    headers = {}
    body = raw
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if content_type:
        headers["Content-Type"] = content_type
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(BASE + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read().decode("utf-8")
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:300]
        raise RuntimeError("%s %s -> HTTP %s %s" % (method, path, exc.code, detail)) from exc


def wait_health():
    last = "timeout"
    for _ in range(60):
        try:
            request("GET", "/health", timeout=5)
            return
        except Exception as exc:
            last = str(exc)
            time.sleep(1)
    raise RuntimeError("PKM API not healthy: %s" % last)


def login():
    try:
        payload = request("POST", "/auth/login", {"username": USER, "password": PASSWORD}, timeout=30)
    except Exception:
        body = urllib.parse.urlencode({"username": USER, "password": PASSWORD}).encode("utf-8")
        payload = request(
            "POST",
            "/auth/login",
            token=None,
            timeout=30,
            content_type="application/x-www-form-urlencoded",
            raw=body,
        )
    token = payload.get("access_token") or payload.get("token")
    if not token:
        raise RuntimeError("login returned no access_token")
    return token


wait_health()
token = login()
errors = []
for path in ENDPOINTS:
    try:
        result = request("POST", path, token=token)
        summary = {key: result.get(key) for key in ("indexed", "created", "updated", "removed", "moved") if key in result}
        print("%s %s" % (path, json.dumps(summary, sort_keys=True) if summary else "ok"))
    except Exception as exc:
        errors.append("%s: %s" % (path, exc))
        print("WARN %s" % errors[-1])
if errors:
    raise SystemExit("PKM disk reindex incomplete (%s)" % "; ".join(errors))
print("PKM disk reindex completed.")
PY
)

encode_python() {
  if command -v base64 >/dev/null 2>&1; then
    printf '%s' "$PY" | base64 | tr -d '\n'
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import base64,sys; print(base64.b64encode(sys.argv[1].encode()).decode())' "$PY"
    return 0
  fi
  fail "base64 or python3 is required to run PKM disk reindex."
}

PY_B64="$(encode_python)"
RUNNER="import base64; exec(base64.b64decode('${PY_B64}').decode())"

run_in_container() {
  local bin="$1"
  docker exec "$CONTAINER" "$bin" -c "$RUNNER"
}

set +e
OUT="$(run_in_container python 2>&1)"
CODE=$?
if [[ "$CODE" -eq 127 || "$CODE" -eq 126 ]]; then
  OUT="$(run_in_container python3 2>&1)"
  CODE=$?
fi
set -e

printf '%s\n' "$OUT"
[[ "$CODE" -eq 0 ]] || fail "PKM disk reindex failed (exit ${CODE})."
