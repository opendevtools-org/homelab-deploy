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
$script:gitExtraArgs = @()

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

function Initialize-GitAuth {
  $pat = [Environment]::GetEnvironmentVariable("HOMELAB_GIT_PAT")
  if ([string]::IsNullOrWhiteSpace($pat)) { return }
  $originUrl = (& git remote get-url origin 2>$null | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($originUrl) -or -not $originUrl.ToString().Trim().StartsWith("https")) { return }
  $username = [Environment]::GetEnvironmentVariable("HOMELAB_GIT_USERNAME")
  if ([string]::IsNullOrWhiteSpace($username)) { $username = "git" }
  $authBytes = [System.Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username, $pat))
  $authB64 = [Convert]::ToBase64String($authBytes)
  $script:gitExtraArgs = @(
    "-c", "credential.helper=",
    "-c", "core.askPass=",
    "-c", ("http.extraHeader=AUTHORIZATION: basic {0}" -f $authB64)
  )
}

function Invoke-GitSoft {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  $allArgs = @($script:gitExtraArgs + $GitArgs)
  $output = & git @allArgs 2>&1
  return @{ Code = $LASTEXITCODE; Text = $output }
}

Set-Location $root
Import-DotEnv -Path (Join-Path $root ".env")
Initialize-GitAuth

$logDir = Join-Path $root "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$diagFile = Join-Path $logDir ("homelab-diag-{0}.txt" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
Start-Transcript -Path $diagFile -Force | Out-Null
try {

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
$dumpPy = Join-Path $root "Dump-PkmSidebar.py"
if (-not (Test-Path $dumpPy)) { $dumpPy = Join-Path $root "upstream\Dump-PkmSidebar.py" }
$originDb = $null
Write-Section "pkm_order_remote_vs_local"
$branch = (git -C $root rev-parse --abbrev-ref HEAD 2>$null | Select-Object -Last 1)
if ($branch -and $branch -ne "HEAD") {
  $fetch = Invoke-GitSoft fetch origin $branch
  Write-Host ("git fetch origin {0} exit={1}" -f $branch, $fetch.Code)
  $source = "origin/{0}" -f $branch
  $blob = Invoke-GitSoft rev-parse ("{0}:data/pkm/pkm.db" -f $source)
  if ($blob.Code -eq 0) {
    $sha = ($blob.Text | Select-Object -Last 1).ToString().Trim()
    $originDb = Join-Path ([System.IO.Path]::GetTempPath()) ("pkm-origin-{0}.db" -f $sha.Substring(0, [Math]::Min(12, $sha.Length)))
    $errFile = "$originDb.err"
    $gitArgs = @($script:gitExtraArgs) + @("cat-file", "blob", $sha)
    $proc = Start-Process -FilePath "git" -ArgumentList $gitArgs -WorkingDirectory $root -RedirectStandardOutput $originDb -RedirectStandardError $errFile -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0 -or -not (Test-Path $originDb) -or (Get-Item $originDb).Length -lt 100) {
      Write-Host "ORIGIN_DB_EXTRACT_FAILED"
      if (Test-Path $errFile) { Get-Content $errFile | Select-Object -First 5 }
      $originDb = $null
    } else {
      Write-Host ("origin pkm.db blob={0} bytes={1}" -f $sha, (Get-Item $originDb).Length)
    }
    if (Test-Path $errFile) { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
  } else {
    Write-Host "NO_ORIGIN_PKM_DB (path data/pkm/pkm.db not on origin)"
  }
  Write-Host "origin docs dirs:"
  $tree = Invoke-GitSoft ls-tree --name-only ("{0}:data/pkm/docs" -f $source)
  if ($tree.Code -eq 0) {
    $originDocs = @($tree.Text | ForEach-Object { $n = "$_".Trim(); if ($n) { "data/pkm/docs/$n" } })
    $originDocs | ForEach-Object { Write-Host $_ }
  } else {
    $originDocs = @()
    Write-Host "(ls-tree failed)"
  }
  $localDocs = @()
  $docsPath = Join-Path $root "data\pkm\docs"
  if (Test-Path $docsPath) {
    $localDocs = @(Get-ChildItem $docsPath -Force | ForEach-Object { ("data/pkm/docs/" + $_.Name).Replace('\','/') })
  }
  Write-Host "docs_dir_compare:"
  $oSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$originDocs)
  $lSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$localDocs)
  foreach ($d in $localDocs) { if (-not $oSet.Contains($d)) { Write-Host ("local_not_on_origin {0}" -f $d) } }
  foreach ($d in $originDocs) { if (-not $lSet.Contains($d)) { Write-Host ("origin_not_local {0}" -f $d) } }
  if ($oSet.SetEquals($lSet)) { Write-Host "DOCS_DIRS_MATCH" }
} else {
  Write-Host "NO_BRANCH"
}

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
if ($py -and (Test-Path $dumpPy) -and (Test-Path $pkmDb)) {
  if ($originDb) {
    & $py.Source $dumpPy $pkmDb $originDb
  } else {
    & $py.Source $dumpPy $pkmDb
  }
} else {
  Write-Host "Dump-PkmSidebar.py/python/pkm.db unavailable"
}
if ($originDb -and (Test-Path $originDb)) {
  Remove-Item $originDb -Force -ErrorAction SilentlyContinue
}

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
Write-Host ("Wrote {0}" -f $diagFile)
Write-Host "Done. Paste this output (it has no file contents and no passwords)."

} finally {
  Stop-Transcript | Out-Null
}
