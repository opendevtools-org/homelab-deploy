<#
.SYNOPSIS
  Updates the upstream/ submodule (opendevtools-org/homelab-deploy) and redeploys.

.DESCRIPTION
  Run from the site instance root (folder with upstream/, data/, .env),
  or from upstream/ itself.

  After pull, refreshes Update-HomelabUpstream.ps1/.sh at the site root from upstream/.

.PARAMETER Ports
  lan | local. Default: lan

.PARAMETER Commit
  git add upstream + commit on the site repo.

.PARAMETER Push
  git push after commit (implies -Commit).

.PARAMETER Start
  docker compose pull && up -d after updating the submodule.

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
} elseif (Test-Path (Join-Path $here "upstream\docker-compose.yml")) {
  $siteRoot = $here
  $upstream = Join-Path $here "upstream"
} else {
  throw "Run from site root (has upstream/) or from upstream/ inside a site instance."
}

$portsFile = if ($Ports -eq "local") { "docker-compose.local.yml" } else { "docker-compose.lan.yml" }

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
$refreshed = @()
foreach ($name in @("Update-HomelabUpstream.ps1", "Update-HomelabUpstream.sh")) {
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
  foreach ($name in @("Update-HomelabUpstream.ps1", "Update-HomelabUpstream.sh")) {
    if (Test-Path (Join-Path $siteRoot $name)) {
      Invoke-Git add $name | Out-Null
    }
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $porcelain = & git status --porcelain -- upstream Update-HomelabUpstream.ps1 Update-HomelabUpstream.sh 2>&1
  $ErrorActionPreference = $prev
  if ($porcelain) {
    Invoke-Git commit -m ("Bump homelab-deploy upstream ({0})." -f $rev) | Out-Null
    Write-Host "Committed submodule pointer."
  } else {
    Write-Host "Upstream pointer unchanged; nothing to commit."
  }
}

if ($Push) {
  Invoke-Git push | Out-Null
  Write-Host "Pushed."
}

if ($Start) {
  if (-not (Test-Path (Join-Path $siteRoot ".env"))) {
    throw "Missing .env in site root."
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
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
  Write-Host "Compose up done."
}

Write-Host "Done."
