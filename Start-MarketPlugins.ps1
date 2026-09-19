<#
.SYNOPSIS
  Start Market plugin Compose stacks from data/hub/plugins/ after a git pull.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$siteRoot = $here
if ((Split-Path -Leaf $here) -eq "upstream" -and (Test-Path (Join-Path (Split-Path $here) "data"))) {
  $siteRoot = Split-Path $here
}
$root = Join-Path $siteRoot "data\hub\plugins"
if (-not (Test-Path $root)) { return }

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }

$hubNet = $null
foreach ($n in @("homelab_default", "hub_default")) {
  docker network inspect $n 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $hubNet = $n; break }
}

$started = $false
Get-ChildItem -Directory $root | ForEach-Object {
  $id = $_.Name
  if ($id -notmatch '^[a-z0-9][a-z0-9_-]*$') { return }
  $compose = $null
  foreach ($f in @("docker-compose.backend.yml", "docker-compose.yml")) {
    $candidate = Join-Path $_.FullName $f
    if (Test-Path -LiteralPath $candidate) { $compose = $candidate; break }
  }
  if (-not $compose) { return }
  $cmd = @(
    "compose", "--project-directory", $_.FullName,
    "--project-name", "homelab-plugin-$id", "-f", $compose
  )
  $ov = Join-Path $_.FullName "docker-compose.hub-override.yml"
  if (Test-Path -LiteralPath $ov) { $cmd += @("-f", $ov) }
  $cmd += @("up", "-d")
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker @cmd
  $ok = $LASTEXITCODE -eq 0
  $ErrorActionPreference = $prev
  if (-not $ok) {
    Write-Host "Could not start market plugin $id."
    return
  }
  $started = $true
  Write-Host "Started market plugin $id."
  if ($hubNet) {
    $ErrorActionPreference = "Continue"
    docker network connect $hubNet "homelab-$id" 2>$null | Out-Null
    $ErrorActionPreference = $prev
  }
}

if ($started) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  docker restart home-hub-platform 2>$null | Out-Null
  $ErrorActionPreference = $prev
}
