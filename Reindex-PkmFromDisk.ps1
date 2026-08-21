<#
.SYNOPSIS
  After git sync of data/, restart PKM and import pages/files/PDFs/bookmarks from disk.

.DESCRIPTION
  Same role as Reindex-PkmFromDisk.sh. Safe to run on its own from the site root.
  Skips when docker/PKM is missing, or when HOMELAB_PKM_REINDEX_AFTER_SYNC is 0/false/no/off.

.EXAMPLE
  .\Reindex-PkmFromDisk.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = $PSScriptRoot
$container = [Environment]::GetEnvironmentVariable("HOMELAB_PKM_CONTAINER")
if ([string]::IsNullOrWhiteSpace($container)) { $container = "pkm-backend" }
$flag = [Environment]::GetEnvironmentVariable("HOMELAB_PKM_REINDEX_AFTER_SYNC")
if ([string]::IsNullOrWhiteSpace($flag)) { $flag = "true" }

function Import-DotEnv {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return }
  foreach ($line in Get-Content -Path $Path) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith("#")) { continue }
    $pair = $line -split '=', 2
    if ($pair.Count -ne 2) { continue }
    $name = $pair[0].Trim()
    $value = $pair[1].Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
      [Environment]::SetEnvironmentVariable($name, $value)
    }
  }
}

function Test-DisabledFlag {
  param([string]$Value)
  switch -Regex ($Value.Trim().ToLowerInvariant()) {
    '^(0|false|no|off)$' { return $true }
    default { return $false }
  }
}

Import-DotEnv -Path (Join-Path $repoRoot ".env")
$fromEnvContainer = [Environment]::GetEnvironmentVariable("HOMELAB_PKM_CONTAINER")
if (-not [string]::IsNullOrWhiteSpace($fromEnvContainer)) { $container = $fromEnvContainer }
$fromEnvFlag = [Environment]::GetEnvironmentVariable("HOMELAB_PKM_REINDEX_AFTER_SYNC")
if (-not [string]::IsNullOrWhiteSpace($fromEnvFlag)) { $flag = $fromEnvFlag }

if (Test-DisabledFlag $flag) {
  Write-Host ("PKM disk reindex skipped (HOMELAB_PKM_REINDEX_AFTER_SYNC={0})." -f $flag)
  exit 0
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Host "PKM disk reindex skipped (docker not found)."
  exit 0
}

$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$inspect = & docker inspect $container 2>&1
$inspectCode = $LASTEXITCODE
$ErrorActionPreference = $prev
if ($inspectCode -ne 0) {
  Write-Host ("PKM disk reindex skipped (container '{0}' not found)." -f $container)
  exit 0
}

$ErrorActionPreference = "Continue"
$running = (& docker inspect -f "{{.State.Running}}" $container 2>&1 | Select-Object -Last 1).ToString().Trim()
$ErrorActionPreference = "Stop"

if ($running -eq "true") {
  & docker restart $container | Out-Null
  if ($LASTEXITCODE -ne 0) { throw ("Failed to restart container '{0}'." -f $container) }
  Write-Host ("Restarted {0} so SQLite reopens after git sync." -f $container)
} else {
  & docker start $container | Out-Null
  if ($LASTEXITCODE -ne 0) { throw ("Failed to start container '{0}'." -f $container) }
  Write-Host ("Started {0}." -f $container)
}

$py = @'
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
'@

$pyB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($py))
$runner = "import base64; exec(base64.b64decode('{0}').decode())" -f $pyB64

function Invoke-PkmPython {
  param([string]$Binary)
  $prevInner = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & docker exec $container $Binary -c $runner 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prevInner
  return @{ Code = $code; Output = $output }
}

$result = Invoke-PkmPython -Binary "python"
if ($result.Code -eq 127 -or $result.Code -eq 126) {
  $result = Invoke-PkmPython -Binary "python3"
}

if ($result.Output) {
  Write-Host ($result.Output | Out-String).TrimEnd()
}
if ($result.Code -ne 0) {
  throw ("PKM disk reindex failed (exit {0})." -f $result.Code)
}
