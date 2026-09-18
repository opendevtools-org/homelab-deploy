<#
.SYNOPSIS
  Prints a troubleshooting dump for Hub/PKM/Guacamole. No document bodies, no .env secrets.

.EXAMPLE
  .\Collect-HomelabDiag.ps1
  .\upstream\Collect-HomelabDiag.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Test-HomelabSiteRoot([string]$Dir) {
  foreach ($name in @("docker-compose.apps.yml", "docker-compose.custom.yml", ".env")) {
    if (Test-Path -LiteralPath (Join-Path $Dir $name)) { return $true }
  }
  return (Test-Path -LiteralPath (Join-Path $Dir "data"))
}

$here = $PSScriptRoot
if ((Split-Path -Leaf $here) -eq "upstream" -and (Test-HomelabSiteRoot (Split-Path -Parent $here))) {
  $root = Split-Path -Parent $here
} elseif (Test-HomelabSiteRoot $here) {
  $root = $here
} else {
  throw "Run from site root or from upstream/."
}
Set-Location $root

function Write-Section([string]$Name) { Write-Host ""; Write-Host ("== {0} ==" -f $Name) }

Write-Section "host"
Write-Host ("site_root={0}" -f $root)
Write-Host (Get-Date -Format o)

Write-Section "git"
if (Test-Path (Join-Path $root ".git")) {
  git -C $root rev-parse --abbrev-ref HEAD 2>$null
  $origin = git -C $root remote get-url origin 2>$null
  if ($origin) { Write-Host ("origin={0}" -f ($origin -replace "://[^/@]+@", "://***@")) }
  git -C $root status --porcelain -- data/pkm data/hub 2>$null | Select-Object -First 40
} else {
  Write-Host "NO_SITE_GIT"
}

Write-Section "env_keys"
$envFile = Join-Path $root ".env"
if (Test-Path $envFile) {
  Get-Content $envFile | Where-Object { $_ -match '^(PUID|PGID|HUB_DEFAULT_MARKET_PLUGINS|HUB_BUILTIN_PLUGINS|HOMELAB_VERSION|PKM_VERSION)=' }
} else {
  Write-Host "NO_DOTENV"
}

Write-Section "pull_script"
$pull = Join-Path $root "Pull-PkmDataKeepScripts.ps1"
if (Test-Path $pull) {
  Select-String -Path $pull -Pattern "restore|checkout|data/pkm|data/hub" | Select-Object -First 20 | ForEach-Object { $_.Line.Trim() }
} else {
  Write-Host "NO_PULL_SCRIPT"
}

Write-Section "compose_guacamole_mentions"
Get-ChildItem -Path $root, (Join-Path $root "upstream") -Filter "docker-compose*.yml" -ErrorAction SilentlyContinue |
  Select-String -Pattern "guacamole" -SimpleMatch | ForEach-Object { "{0}:{1}:{2}" -f $_.Path, $_.LineNumber, $_.Line.Trim() }

Write-Section "data_tree"
$pkmDb = Join-Path $root "data\pkm\pkm.db"
$hubDb = Join-Path $root "data\hub\platform.db"
Write-Host ("pkm.db {0}" -f $(if (Test-Path $pkmDb) { (Get-Item $pkmDb).Length } else { "MISSING" }))
Write-Host ("platform.db {0}" -f $(if (Test-Path $hubDb) { (Get-Item $hubDb).Length } else { "MISSING" }))
Write-Host "pkm top:"
Get-ChildItem (Join-Path $root "data\pkm") -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
Write-Host "docs dirs:"
Get-ChildItem (Join-Path $root "data\pkm\docs") -Force -ErrorAction SilentlyContinue | Select-Object -First 40 | ForEach-Object { $_.Name }
Write-Host "hub top:"
Get-ChildItem (Join-Path $root "data\hub") -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
Write-Host "guacamole plugin files:"
Get-ChildItem (Join-Path $root "data\hub\plugins\guacamole") -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }

function Invoke-SqlitePreview {
  param([string]$Code)
  $py = Get-Command python -ErrorAction SilentlyContinue
  if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
  if (-not $py) { Write-Host "python unavailable"; return }
  $tmp = [System.IO.Path]::GetTempFileName() + ".py"
  Set-Content -Path $tmp -Value $Code -Encoding utf8
  & $py.Source $tmp
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

Write-Section "sqlite_pkm_pages"
Invoke-SqlitePreview @"
import os, sqlite3
p = r'$pkmDb'
if not os.path.isfile(p):
    print('NO_PKM_DB')
else:
    c = sqlite3.connect(p)
    cols = [r[1] for r in c.execute('PRAGMA table_info(pages)')]
    print('cols', ','.join(cols))
    title = 'title' if 'title' in cols else ('name' if 'name' in cols else None)
    path = 'path' if 'path' in cols else None
    pos = 'position' if 'position' in cols else None
    if title and pos:
        sel = ', '.join(x for x in (title, path, pos) if x)
        rows = c.execute(f'SELECT {sel} FROM pages ORDER BY {pos}, {title} LIMIT 50').fetchall()
        print('count_preview', len(rows))
        for r in rows:
            print('|'.join('' if x is None else str(x) for x in r))
    else:
        print('unexpected schema')
"@

Write-Section "sqlite_hub_plugins"
Invoke-SqlitePreview @"
import os, sqlite3
p = r'$hubDb'
if not os.path.isfile(p):
    print('NO_HUB_DB')
else:
    c = sqlite3.connect(p)
    try:
        for r in c.execute('SELECT id, enabled, local_port, install_path FROM plugins'):
            print('|'.join('' if x is None else str(x) for x in r))
    except Exception as e:
        print('query_failed', e)
    try:
        print('opt_out', [x[0] for x in c.execute('SELECT id FROM plugin_opt_out')])
    except Exception:
        pass
"@

Write-Section "docker"
if (Get-Command docker -ErrorAction SilentlyContinue) {
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  foreach ($c in @("pkm-backend", "home-hub-platform", "home-hub", "homelab-guacamole")) {
    Write-Host ("-- {0} --" -f $c)
    docker inspect $c --format "{{.Name}} status={{.State.Status}} user={{.Config.User}}{{println}}labels.project={{index .Config.Labels `"com.docker.compose.project`"}}{{println}}labels.workdir={{index .Config.Labels `"com.docker.compose.project.working_dir`"}}{{println}}labels.files={{index .Config.Labels `"com.docker.compose.project.config_files`"}}{{println}}{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}" 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "missing" }
  }
  Write-Host "-- pkm-backend last logs --"
  docker logs --tail 15 pkm-backend 2>&1 | Select-Object -Last 15
  Write-Host "-- hub-platform guacamole/market lines --"
  docker logs home-hub-platform 2>&1 | Select-String -Pattern "guacamole|market plugin|ERROR" | Select-Object -Last 20
} else {
  Write-Host "NO_DOCKER"
}

Write-Host ""
Write-Host "Done. Paste this output (it has no file contents and no passwords)."
