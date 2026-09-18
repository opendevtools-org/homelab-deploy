<#
.SYNOPSIS
  Daily site pull with automatic Git and SQLite merge (Pull-DataGit).

.PARAMETER Product
  Run Update-HomelabUpstream first.

.PARAMETER Start
  With -Product: compose pull + up after the product update.

.EXAMPLE
  .\Pull.ps1
  .\Pull.ps1 -Product -Start
#>
[CmdletBinding()]
param(
  [switch]$Product,
  [switch]$Start,
  [switch]$Commit,
  [switch]$Push,
  [ValidateSet("lan", "local")]
  [string]$Ports = "lan"
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

if ($Start -or $Commit -or $Push) {
  $Product = $true
}

if ($Product) {
  $upd = Join-Path $siteRoot "Update-HomelabUpstream.ps1"
  if (-not (Test-Path $upd)) {
    $upd = Join-Path $siteRoot "upstream\Update-HomelabUpstream.ps1"
  }
  if (-not (Test-Path $upd)) {
    throw "Update-HomelabUpstream.ps1 not found"
  }
  $reArgs = @{ Ports = $Ports }
  if ($Commit) { $reArgs["Commit"] = $true }
  if ($Push) { $reArgs["Push"] = $true }
  if ($Start) { $reArgs["Start"] = $true }
  & $upd @reArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$pull = Join-Path $siteRoot "Pull-DataGit.ps1"
if (-not (Test-Path $pull)) {
  $pull = Join-Path $siteRoot "upstream\Pull-DataGit.ps1"
}
if (-not (Test-Path $pull)) {
  throw "Pull-DataGit.ps1 not found (automatic merge helper)."
}
& $pull
exit $LASTEXITCODE
