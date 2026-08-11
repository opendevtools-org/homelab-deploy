<#
.SYNOPSIS
  Converts a flat homelab-deploy install into a site instance (in place).

.DESCRIPTION
  Default: transform THIS folder (where the script lives) into:

    ./upstream/                 # git submodule → opendevtools-org/homelab-deploy
    ./data/                     # your volumes (kept)
    ./.env                      # your secrets (kept, never committed)
    ./docker-compose.apps.yml   # your apps overlay
    ./.gitignore
    ./README.md

  The old flat product files at the root (docker-compose.yml, etc.) are removed
  because they now live inside upstream/. Optionally links the folder to -SiteRepo
  on an orphan branch and pushes.

.PARAMETER SiteRepo
  Your git remote (e.g. company repo). Required unless -SkipGit.

.PARAMETER Branch
  Orphan branch name on SiteRepo. Default: homelab

.PARAMETER TargetDir
  Folder to convert. Default: directory containing this script (the flat install).

.PARAMETER UpstreamUrl
  Product submodule URL.

.PARAMETER Ports
  lan | local. Default: lan

.PARAMETER SkipGit
  Only restructure files + submodule; do not rebind remotes / push.

.PARAMETER Push
  Push the orphan branch to SiteRepo.

.PARAMETER Start
  docker compose up -d after conversion.

.EXAMPLE
  cd C:\Projects\homelab-deploy
  .\New-HomelabSite.ps1 -SiteRepo https://github.com/org/tools.git -Push -Start
#>
[CmdletBinding()]
param(
  [string]$SiteRepo = "",
  [string]$Branch = "homelab",
  [string]$TargetDir = "",
  [string]$UpstreamUrl = "https://github.com/opendevtools-org/homelab-deploy.git",

  [ValidateSet("lan", "local")]
  [string]$Ports = "lan",

  [switch]$SkipGit,
  [switch]$Push,
  [switch]$Start,
  [switch]$SkipCommit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $Name"
  }
}

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & git @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    throw ("git {0} failed (exit {1}): {2}" -f ($GitArgs -join " "), $code, (($output | Out-String).Trim()))
  }
  return $output
}

function Invoke-GitQuiet {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $null = & git @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return $code
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $text = $Content.TrimEnd() + "`n"
  [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

Assert-Command git
if ($Start) { Assert-Command docker }
if (-not $SkipGit -and -not $SiteRepo) {
  throw "Pass -SiteRepo <url> (your repo) or -SkipGit for local-only conversion."
}

$scriptRoot = $PSScriptRoot
if (-not $TargetDir) { $TargetDir = $scriptRoot }
$TargetDir = [System.IO.Path]::GetFullPath($TargetDir)
$portsFile = if ($Ports -eq "local") { "docker-compose.local.yml" } else { "docker-compose.lan.yml" }

if (-not (Test-Path $TargetDir)) {
  throw ("TargetDir not found: {0}" -f $TargetDir)
}

$alreadySite = Test-Path (Join-Path $TargetDir "upstream\docker-compose.yml")
$isFlat = Test-Path (Join-Path $TargetDir "docker-compose.yml")
if (-not $alreadySite -and -not $isFlat) {
  throw "TargetDir is neither a flat homelab-deploy install nor an existing site (missing docker-compose.yml and upstream/)."
}

Write-Host ("Mode       : in-place convert")
Write-Host ("TargetDir  : {0}" -f $TargetDir)
Write-Host ("SiteRepo   : {0}" -f $(if ($SiteRepo) { $SiteRepo } else { "(skip git remote)" }))
Write-Host ("Branch     : {0}" -f $Branch)
Write-Host ("Upstream   : {0}" -f $UpstreamUrl)
Write-Host ("Ports      : {0}" -f $portsFile)

# --- backup site-owned files ---
$bak = Join-Path $env:TEMP ("homelab-inplace-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $bak | Out-Null
Write-Host ("Backup     : {0}" -f $bak)

$dataSrc = Join-Path $TargetDir "data"
if (Test-Path $dataSrc) {
  robocopy $dataSrc (Join-Path $bak "data") /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  if ($LASTEXITCODE -ge 8) { throw ("robocopy data backup failed (exit {0})" -f $LASTEXITCODE) }
}
foreach ($name in @(".env", "docker-compose.apps.yml", ".env.example")) {
  $p = Join-Path $TargetDir $name
  if (Test-Path $p) { Copy-Item $p (Join-Path $bak $name) -Force }
}

Set-Location $TargetDir

# --- detach product git (flat clone of homelab-deploy) ---
$gitDir = Join-Path $TargetDir ".git"
if (Test-Path $gitDir) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $remotes = @(& git remote -v 2>&1)
  $ErrorActionPreference = $prev
  $isProductClone = ($remotes -join "`n") -match "homelab-deploy"
  $hasUpstreamSub = Test-Path (Join-Path $TargetDir ".gitmodules")

  if ($isProductClone -and -not $alreadySite) {
    Write-Host "Detaching product .git (was a homelab-deploy clone)..."
    Remove-Item $gitDir -Recurse -Force
  } elseif ($alreadySite -and -not $SkipGit -and $SiteRepo) {
    # Re-bind site remote if needed
    $null = Invoke-GitQuiet remote remove origin
    Invoke-Git remote add origin $SiteRepo | Out-Null
  }
}

# --- remove flat product files from root (they will live under upstream/) ---
if (-not $alreadySite) {
  $productFiles = @(
    "docker-compose.yml",
    "docker-compose.lan.yml",
    "docker-compose.local.yml",
    "docker-compose.apps.example.yml",
    "LICENSE",
    "README.md",
    "New-HomelabSite.ps1",
    "New-HomelabSite.sh",
    "Update-HomelabUpstream.ps1",
    "Update-HomelabUpstream.sh",
    "Backup-DataGit.ps1",
    "Backup-DataGit.sh",
    "Register-DataGitBackupTask.ps1",
    "Register-DataGitBackup.sh"
  )
  foreach ($f in $productFiles) {
    $p = Join-Path $TargetDir $f
    if (Test-Path $p) {
      Remove-Item $p -Force
    }
  }
  # keep data/, .env for now; will refresh from backup after submodule
}

# --- git site repo (orphan branch) ---
if (-not $SkipGit) {
  if (-not (Test-Path (Join-Path $TargetDir ".git"))) {
    Write-Host "Initializing site git repo..."
    Invoke-Git init -b main | Out-Null
    Invoke-Git remote add origin $SiteRepo | Out-Null
    if ((Invoke-GitQuiet config user.name) -ne 0) { Invoke-Git config user.name "Homelab Setup" | Out-Null }
    if ((Invoke-GitQuiet config user.email) -ne 0) { Invoke-Git config user.email "homelab@localhost" | Out-Null }
  } else {
    $null = Invoke-GitQuiet remote remove origin
    $null = Invoke-GitQuiet remote add origin $SiteRepo
  }

  $null = Invoke-GitQuiet fetch origin

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $existsRemote = @(& git ls-remote --heads origin $Branch 2>&1)
  $ErrorActionPreference = $prev
  $branchExists = ($existsRemote -join "`n") -match ("refs/heads/{0}\b" -f [regex]::Escape($Branch))

  $cur = ""
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $curOut = & git rev-parse --abbrev-ref HEAD 2>&1
  if ($LASTEXITCODE -eq 0) { $cur = "$curOut".Trim() }
  $ErrorActionPreference = $prev

  if ($branchExists) {
    Write-Host ("Checking out site branch {0}" -f $Branch)
    Invoke-Git fetch origin $Branch | Out-Null
    # Don't wipe data: we already backed up. Reset index to branch then rebuild files.
    Invoke-Git checkout -B $Branch ("origin/{0}" -f $Branch) | Out-Null
  } elseif ($cur -eq $Branch) {
    Write-Host ("Already on orphan/site branch {0}" -f $Branch)
  } else {
    Write-Host ("Creating orphan branch {0}" -f $Branch)
    # Ensure at least one commit exists for orphan, or checkout --orphan on unborn repo
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $null = & git rev-parse HEAD 2>&1
    $hasHead = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if ($hasHead) {
      Invoke-Git checkout --orphan $Branch | Out-Null
    } else {
      Invoke-Git checkout -B $Branch | Out-Null
    }
    $null = Invoke-GitQuiet rm -rf --ignore-unmatch .
  }
}

# --- ensure submodule upstream ---
Set-Location $TargetDir
if (Test-Path (Join-Path $TargetDir "upstream\.git")) {
  Write-Host "upstream/ submodule already present."
} elseif (Test-Path (Join-Path $TargetDir "upstream")) {
  Remove-Item (Join-Path $TargetDir "upstream") -Recurse -Force
  Write-Host "Adding upstream submodule..."
  if (-not $SkipGit -and (Test-Path (Join-Path $TargetDir ".git"))) {
    Invoke-Git submodule add --force $UpstreamUrl upstream | Out-Null
  } else {
    Invoke-Git clone $UpstreamUrl (Join-Path $TargetDir "upstream") | Out-Null
  }
} else {
  Write-Host "Adding upstream submodule..."
  if (-not $SkipGit -and (Test-Path (Join-Path $TargetDir ".git"))) {
    # Clear stale gitmodule entries
    $null = Invoke-GitQuiet submodule deinit -f upstream
    $null = Invoke-GitQuiet rm -f upstream
    if (Test-Path (Join-Path $TargetDir ".gitmodules")) {
      Remove-Item (Join-Path $TargetDir ".gitmodules") -Force -ErrorAction SilentlyContinue
    }
    Invoke-Git submodule add --force $UpstreamUrl upstream | Out-Null
  } else {
    Invoke-Git clone $UpstreamUrl (Join-Path $TargetDir "upstream") | Out-Null
  }
}

# --- restore site files ---
Write-Host "Restoring data/ and site overlay..."
if (Test-Path (Join-Path $bak "data")) {
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir "data") | Out-Null
  robocopy (Join-Path $bak "data") (Join-Path $TargetDir "data") /E /XD .git /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  if ($LASTEXITCODE -ge 8) { throw ("robocopy data restore failed (exit {0})" -f $LASTEXITCODE) }
} else {
  New-Item -ItemType Directory -Force -Path (Join-Path $TargetDir "data\hub"), (Join-Path $TargetDir "data\pkm") | Out-Null
}

if (Test-Path (Join-Path $bak ".env")) {
  Copy-Item (Join-Path $bak ".env") (Join-Path $TargetDir ".env") -Force
} elseif (Test-Path (Join-Path $TargetDir "upstream\.env.example")) {
  Copy-Item (Join-Path $TargetDir "upstream\.env.example") (Join-Path $TargetDir ".env") -Force
  Write-Host "Created .env from upstream/.env.example - edit secrets if needed."
}

if (Test-Path (Join-Path $bak "docker-compose.apps.yml")) {
  Copy-Item (Join-Path $bak "docker-compose.apps.yml") (Join-Path $TargetDir "docker-compose.apps.yml") -Force
} elseif (Test-Path (Join-Path $TargetDir "upstream\docker-compose.apps.yml")) {
  Copy-Item (Join-Path $TargetDir "upstream\docker-compose.apps.yml") (Join-Path $TargetDir "docker-compose.apps.yml") -Force
} else {
  Write-Utf8NoBom (Join-Path $TargetDir "docker-compose.apps.yml") @"
# Optional services for this host.
services: {}
"@
}

if (Test-Path (Join-Path $TargetDir "upstream\.env.example")) {
  Copy-Item (Join-Path $TargetDir "upstream\.env.example") (Join-Path $TargetDir ".env.example") -Force
}

Write-Utf8NoBom (Join-Path $TargetDir ".gitignore") @"
.env
*.tar
logs/
upstream/data/
"@

$readme = @"
# Homelab site instance

Converted from a flat ``homelab-deploy`` install.

- ``upstream/`` — git submodule ($UpstreamUrl) — product package
- ``data/`` — your Hub + PKM volumes
- ``docker-compose.apps.yml`` — your extra services
- ``.env`` — secrets (not committed)
- ``Update-HomelabUpstream.ps1`` / ``.sh`` — pull product updates
- ``Backup-DataGit.ps1`` / ``.sh`` — daily commit/push of ``data/``
- ``Register-DataGitBackupTask.ps1`` / ``Register-DataGitBackup.sh`` — schedule that backup

## Start

``````bash
docker compose --project-directory . \\
  -f upstream/docker-compose.yml \\
  -f upstream/$portsFile \\
  -f docker-compose.apps.yml up -d
``````

## Update product

``````bash
./Update-HomelabUpstream.sh --commit --push --start
# Windows: .\\Update-HomelabUpstream.ps1 -Commit -Push -Start
``````

## Daily data backup

Commits and pushes only ``data/``. If origin advanced, tries rebase then merge; real conflicts need manual fix.

``````powershell
.\Register-DataGitBackupTask.ps1 -Time 00:05
.\Backup-DataGit.ps1
``````

``````bash
./Register-DataGitBackup.sh --time 00:05
./Backup-DataGit.sh
``````
"@
Write-Utf8NoBom (Join-Path $TargetDir "README.md") $readme

# Launchers at site root (from upstream product package)
foreach ($name in @(
  "Update-HomelabUpstream.ps1",
  "Update-HomelabUpstream.sh",
  "Backup-DataGit.ps1",
  "Backup-DataGit.sh",
  "Register-DataGitBackupTask.ps1",
  "Register-DataGitBackup.sh"
)) {
  $src = Join-Path $TargetDir ("upstream\{0}" -f $name)
  if (Test-Path $src) {
    Copy-Item $src (Join-Path $TargetDir $name) -Force
  } else {
    Write-Host ("Warning: upstream/{0} missing; skip copy to site root." -f $name)
  }
}

Remove-Item $bak -Recurse -Force -ErrorAction SilentlyContinue

# --- commit / push ---
if (-not $SkipGit -and -not $SkipCommit -and (Test-Path (Join-Path $TargetDir ".git"))) {
  Set-Location $TargetDir
  $null = Invoke-GitQuiet rm --cached -f --ignore-unmatch .env
  Invoke-Git add -A | Out-Null
  $null = Invoke-GitQuiet rm --cached -f --ignore-unmatch .env

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $staged = @(& git diff --cached --name-only 2>&1)
  $ErrorActionPreference = $prev
  foreach ($f in $staged) {
    if ($f -eq ".env" -or "$f".EndsWith("/.env")) {
      throw ("Refusing to commit: .env is staged ({0})." -f $f)
    }
  }

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $porcelain = & git status --porcelain 2>&1
  $ErrorActionPreference = $prev
  if ($porcelain) {
    Invoke-Git commit -m "Homelab site instance: upstream submodule + local data/apps." | Out-Null
  } else {
    Write-Host "Nothing new to commit."
  }
}

if ($Push) {
  if ($SkipGit -or -not $SiteRepo) { throw "-Push requires -SiteRepo (and not -SkipGit)." }
  Set-Location $TargetDir
  Write-Host ("Pushing {0} ..." -f $Branch)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & git push -u origin $Branch 2>&1 | Out-Null
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    Write-Host "Push failed; retrying with --force-with-lease ..."
    Invoke-Git push --force-with-lease -u origin $Branch | Out-Null
  }
}

if ($Start) {
  Set-Location $TargetDir
  if (-not (Test-Path (Join-Path $TargetDir ".env"))) {
    throw "Missing .env"
  }
  # Stop old flat project containers if names conflict
  Write-Host "Starting Compose (stop conflicting old containers if any)..."
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  foreach ($n in @("pkm-backend", "pkm-frontend", "home-hub", "home-hub-platform")) {
    & docker rm -f $n 2>&1 | Out-Null
  }
  & docker compose --project-directory . `
    -f upstream/docker-compose.yml `
    -f ("upstream/{0}" -f $portsFile) `
    -f docker-compose.apps.yml `
    pull
  if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = $prev; throw "docker compose pull failed" }
  & docker compose --project-directory . `
    -f upstream/docker-compose.yml `
    -f ("upstream/{0}" -f $portsFile) `
    -f docker-compose.apps.yml `
    up -d
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) { throw "docker compose up failed" }
}

Write-Host ""
Write-Host "Done. Flat install converted in place:"
Write-Host ("  {0}" -f $TargetDir)
Write-Host "  upstream/  = product submodule (git pull inside to update)"
Write-Host "  data/      = your volumes"
Write-Host ("  Start     : cd `"{0}`"; docker compose --project-directory . -f upstream/docker-compose.yml -f upstream/{1} -f docker-compose.apps.yml up -d" -f $TargetDir, $portsFile)
