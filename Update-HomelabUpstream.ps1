<#
.SYNOPSIS
  Updates the upstream/ submodule (opendevtools-org/homelab-deploy) and redeploys.

.DESCRIPTION
  Run from the site instance root (folder with upstream/, data/, .env),
  or from upstream/ itself.

  After pull, refreshes site-root launchers from upstream/:
    Update-HomelabUpstream.*, Backup-DataGit.*, Pull-DataGit.*,
    Register-DataGitBackup*, Register-DataGitPull*, Reindex-PkmFromDisk.*,
    docker-compose.config.yml, .gitignore.

.PARAMETER Ports
  lan | local. Default: lan

.PARAMETER Commit
  git add upstream + commit on the site repo.

.PARAMETER Push
  git push after integrating origin (rebase, then merge fallback). Implies commit.

.PARAMETER Start
  docker compose pull && up -d after updating the submodule, then import
  PKM pages/files/PDFs/bookmarks from disk without restarting PKM again.

.EXAMPLE
  cd C:\Projects\homelab-deploy
  .\Update-HomelabUpstream.ps1 -Commit -Push -Start

.EXAMPLE
  # If site-root copy is stale, run the one inside upstream once:
  .\upstream\Update-HomelabUpstream.ps1 -Commit -Push -Start
#>
[CmdletBinding()]
param(
  [ValidateSet("lan", "local")]
  [string]$Ports = "lan",

  [switch]$Commit,
  [switch]$Push,
  [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Push) { $Commit = $true }

$here = $PSScriptRoot
if ((Split-Path -Leaf $here) -eq "upstream" -and (Test-Path (Join-Path (Split-Path -Parent $here) "docker-compose.apps.yml"))) {
  $siteRoot = Split-Path -Parent $here
  $upstream = $here
} elseif ((Test-Path (Join-Path $here "upstream\docker-compose.yml")) -or
          (Test-Path (Join-Path $here "upstream\docker-compose.backend.yml"))) {
  $siteRoot = $here
  $upstream = Join-Path $here "upstream"
} else {
  throw "Run from site root (has upstream/) or from upstream/ inside a site instance."
}

$portsFile = if ($Ports -eq "local") { "docker-compose.local.yml" } else { "docker-compose.lan.yml" }
$frontendPortsFile = if ($Ports -eq "local") { "docker-compose.frontend.local.yml" } else { "docker-compose.frontend.lan.yml" }

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

Write-Host ("Site root : {0}" -f $siteRoot)
Write-Host ("Updating  : {0}" -f $upstream)

Set-Location $upstream
Invoke-Git fetch origin | Out-Null
Invoke-Git checkout main | Out-Null
# Prefer hard reset: upstream may be force-pushed (orphan/history rewrite).
Invoke-Git reset --hard origin/main | Out-Null
$rev = (Invoke-Git rev-parse --short HEAD | Select-Object -Last 1).ToString().Trim()
Write-Host ("Upstream  : {0}" -f $rev)

# Keep site-root launchers in sync with product package
$launcherNames = @(
  "Update-HomelabUpstream.ps1",
  "Update-HomelabUpstream.sh",
  "Backup-DataGit.ps1",
  "Backup-DataGit.sh",
  "Register-DataGitBackupTask.ps1",
  "Register-DataGitBackup.sh",
  "Pull-DataGit.ps1",
  "Pull-DataGit.sh",
  "Register-DataGitPullTask.ps1",
  "Register-DataGitPull.sh",
  "Reindex-PkmFromDisk.ps1",
  "Reindex-PkmFromDisk.sh",
  "docker-compose.config.yml",
  ".gitignore"
)
$refreshed = @()
foreach ($name in $launcherNames) {
  $src = Join-Path $upstream $name
  $dst = Join-Path $siteRoot $name
  if (Test-Path $src) {
    Copy-Item $src $dst -Force
    $refreshed += $name
  }
}
if ($refreshed.Count -gt 0) {
  Write-Host ("Refreshed site-root {0}" -f ($refreshed -join ", "))
}

Set-Location $siteRoot

if ($Commit) {
  if (-not (Test-Path (Join-Path $siteRoot ".git"))) {
    throw "No .git in site root; cannot commit submodule pointer."
  }
  Invoke-Git add upstream | Out-Null
  foreach ($name in $launcherNames) {
    if (Test-Path (Join-Path $siteRoot $name)) {
      Invoke-Git add $name | Out-Null
    }
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $statusArgs = @("status", "--porcelain", "--", "upstream") + $launcherNames
  $porcelain = & git @statusArgs 2>&1
  $ErrorActionPreference = $prev
  if ($porcelain) {
    Invoke-Git commit -m ("Bump homelab-deploy upstream ({0})." -f $rev) | Out-Null
    Write-Host "Committed submodule pointer."
  } else {
    Write-Host "Upstream pointer unchanged; nothing to commit."
  }
}

if ($Push) {
  $branch = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -Last 1).ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq "HEAD") {
    throw "Detached HEAD is not supported for -Push."
  }
  Invoke-Git fetch origin | Out-Null
  try {
    Invoke-Git pull --rebase --autostash origin $branch | Out-Null
  } catch {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git rebase --abort 2>&1 | Out-Null
    $ErrorActionPreference = $prev
    try {
      Invoke-Git merge --no-edit ("origin/{0}" -f $branch) | Out-Null
    } catch {
      throw ("Could not integrate origin/{0} (rebase and merge failed). Resolve conflicts, then git push and re-run with -Start." -f $branch)
    }
  }
  Invoke-Git push origin $branch | Out-Null
  Write-Host "Pushed."
}

if ($Start) {
  if (-not (Test-Path (Join-Path $siteRoot ".env"))) {
    throw "Missing .env in site root."
  }
  Write-Host "Starting Compose (stop old containers if names conflict)..."
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  foreach ($n in @("pkm-backend", "pkm-frontend", "home-hub", "home-hub-platform")) {
    & docker rm -f $n 2>&1 | Out-Null
  }
  & docker compose --project-directory . `
    -f upstream/docker-compose.backend.yml `
    -f ("upstream/{0}" -f $portsFile) `
    -f docker-compose.config.yml `
    -f docker-compose.apps.yml `
    pull
  if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = $prev; throw "docker compose pull failed" }
  & docker compose --project-directory . `
    -f upstream/docker-compose.backend.yml `
    -f ("upstream/{0}" -f $portsFile) `
    -f docker-compose.config.yml `
    -f docker-compose.apps.yml `
    up -d
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) { throw "docker compose up failed" }
  $ErrorActionPreference = "Continue"
  & docker compose --project-directory . `
    -f upstream/docker-compose.backend.yml `
    -f ("upstream/{0}" -f $portsFile) `
    -f docker-compose.config.yml `
    -f docker-compose.apps.yml `
    rm --force --stop pkm-data-permissions 2>&1 | Out-Null
  & docker compose --project-directory . `
    -f upstream/docker-compose.frontend.yml `
    -f ("upstream/{0}" -f $frontendPortsFile) `
    pull
  if ($LASTEXITCODE -ne 0) { $ErrorActionPreference = $prev; throw "docker compose frontend pull failed" }
  & docker compose --project-directory . `
    -f upstream/docker-compose.frontend.yml `
    -f ("upstream/{0}" -f $frontendPortsFile) `
    up -d
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) { throw "docker compose frontend up failed" }
  Write-Host "Compose up done."

  $helper = Join-Path $siteRoot "Reindex-PkmFromDisk.ps1"
  if (-not (Test-Path $helper)) {
    Write-Host "PKM disk reindex skipped (Reindex-PkmFromDisk.ps1 not found)."
  } else {
    Write-Host "Importing PKM pages, files, PDFs, and bookmarks from disk..."
    $shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $ErrorActionPreference = "Continue"
    & $shell -NoProfile -ExecutionPolicy Bypass -File $helper -SkipRestart
    $reindexCode = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($reindexCode -ne 0) {
      Write-Warning "PKM disk reindex failed after Compose up. Use Import from disk in the PKM UI if items are missing."
    }
  }
}

Write-Host "Done."
