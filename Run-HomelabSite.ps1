<#
.SYNOPSIS
  Full site refresh: product update, Compose, market plugins, then data Git pull.

.DESCRIPTION
  1. Update-HomelabUpstream -Start (refreshes upstream/, compose up, PKM import)
     which also runs Start-MarketPlugins
  2. Pull-DataGit (commit/sync site data with origin)

.EXAMPLE
  .\Run-HomelabSite.ps1
  .\Run-HomelabSite.ps1 -Commit -Push
#>
[CmdletBinding()]
param(
  [ValidateSet("lan", "local")]
  [string]$Ports = "lan",
  [switch]$Commit,
  [switch]$Push,
  [switch]$NoStart,
  [switch]$SkipDataPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-SiteRoot([string]$d) {
  return (Test-Path (Join-Path $d "docker-compose.apps.yml")) `
    -or (Test-Path (Join-Path $d "docker-compose.custom.yml")) `
    -or (Test-Path (Join-Path $d ".env")) `
    -or (Test-Path (Join-Path $d "data"))
}

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$parent = Split-Path -Parent $here
if ((Split-Path -Leaf $here) -eq "upstream" -and (Test-SiteRoot $parent)) {
  $siteRoot = $parent
} elseif ((Test-Path (Join-Path $here "upstream")) -or (Test-SiteRoot $here)) {
  $siteRoot = $here
} else {
  throw "Run from the site root or from upstream/."
}

Set-Location $siteRoot

$upd = Join-Path $siteRoot "Update-HomelabUpstream.ps1"
if (-not (Test-Path $upd)) {
  $upd = Join-Path $siteRoot "upstream\Update-HomelabUpstream.ps1"
}
if (-not (Test-Path $upd)) {
  throw "Update-HomelabUpstream.ps1 not found."
}

$upArgs = @{ Ports = $Ports }
if ($Commit) { $upArgs["Commit"] = $true }
if ($Push) { $upArgs["Push"] = $true }
if (-not $NoStart) { $upArgs["Start"] = $true }

Write-Host "=== 1/2 Update-HomelabUpstream (includes Start-MarketPlugins) ==="
& $upd @upArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($SkipDataPull) {
  Write-Host "SkipDataPull: not running Pull-DataGit."
  exit 0
}

$pull = Join-Path $siteRoot "Pull-DataGit.ps1"
if (-not (Test-Path $pull)) {
  $pull = Join-Path $siteRoot "upstream\Pull-DataGit.ps1"
}
if (-not (Test-Path $pull)) {
  throw "Pull-DataGit.ps1 not found."
}

Write-Host "=== 2/2 Pull-DataGit ==="
& $pull
exit $LASTEXITCODE
