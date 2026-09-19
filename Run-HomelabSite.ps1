<#
.SYNOPSIS
  Full site refresh: product update, Compose, plugins, then Git commit/pull/merge/push of site data.

.DESCRIPTION
  1. Update-HomelabUpstream -Start -Commit -Push
     (upstream/, Compose, Start-MarketPlugins, commit pointer, pull/merge origin, push)
  2. Pull-DataGit
     (commit data + launchers, pull --rebase then merge, SQLite/file conflicts, push)

.EXAMPLE
  .\Run-HomelabSite.ps1
  .\Run-HomelabSite.ps1 -NoStart
  .\Run-HomelabSite.ps1 -NoGit
#>
[CmdletBinding()]
param(
  [ValidateSet("lan", "local")]
  [string]$Ports = "lan",
  [switch]$NoStart,
  [switch]$NoGit,
  [switch]$SkipDataPull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Ts {
  param($Message)
  Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
}

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
if (-not $NoStart) { $upArgs["Start"] = $true }
if (-not $NoGit) {
  $upArgs["Commit"] = $true
  $upArgs["Push"] = $true
}

Write-Ts "=== 1/2 Update-HomelabUpstream (Compose, plugins, git commit/pull/merge/push) ==="
& $upd @upArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($SkipDataPull) {
  Write-Ts "SkipDataPull: not running Pull-DataGit."
  exit 0
}

$pull = Join-Path $siteRoot "Pull-DataGit.ps1"
if (-not (Test-Path $pull)) {
  $pull = Join-Path $siteRoot "upstream\Pull-DataGit.ps1"
}
if (-not (Test-Path $pull)) {
  throw "Pull-DataGit.ps1 not found."
}

Write-Ts "=== 2/2 Pull-DataGit (commit data, pull, merge conflicts, push) ==="
$env:HOMELAB_SKIP_MARKET_PLUGINS = "1"
try {
  & $pull
  exit $LASTEXITCODE
} finally {
  Remove-Item Env:HOMELAB_SKIP_MARKET_PLUGINS -ErrorAction SilentlyContinue
}
