<#
.SYNOPSIS
  Attach Market plugins to the homelab-backend and homelab-frontend Compose projects.
#>
[CmdletBinding()]
param(
  [ValidateSet("lan", "local")]
  [string]$Ports = "lan"
)

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

$portsFile = if ($Ports -eq "local") { "docker-compose.local.yml" } else { "docker-compose.lan.yml" }
$frontendPortsFile = if ($Ports -eq "local") { "docker-compose.frontend.local.yml" } else { "docker-compose.frontend.lan.yml" }

function ConvertTo-ComposeRel([string]$Full) {
  $rel = $Full.Substring($siteRoot.Length).TrimStart('\', '/')
  return ($rel -replace '\\', '/')
}

function Add-ComposeInclude {
  param([string]$OverlayPath, [string]$ComposeFile, [string]$ProjectDir)
  $composeRel = ConvertTo-ComposeRel $ComposeFile
  $projectRel = ConvertTo-ComposeRel $ProjectDir
  if (-not (Test-Path -LiteralPath $OverlayPath)) {
    $dir = Split-Path -Parent $OverlayPath
    if ($dir -and -not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $seed = @"
include:
  - path: $composeRel
    project_directory: $projectRel

services: {}
"@
    [IO.File]::WriteAllText($OverlayPath, $seed.Replace("`n", "`n"))
    return
  }
  $text = [IO.File]::ReadAllText($OverlayPath)
  if ($text.Contains($composeRel)) { return }
  $item = "  - path: $composeRel`n    project_directory: $projectRel`n"
  if ($text -match '(?m)^include:\s*\r?\n') {
    $text = [regex]::Replace($text, '(?m)^include:\s*\r?\n', "include:`n$item", 1)
  } else {
    $text = "include:`n$item`n$text"
  }
  [IO.File]::WriteAllText($OverlayPath, $text)
}

$appsOverlay = Join-Path $siteRoot "docker-compose.apps.yml"
$feAppsOverlay = Join-Path $siteRoot "docker-compose.frontend.apps.yml"
$wantBackend = $false
$wantFrontend = $false

Get-ChildItem -Directory $root | ForEach-Object {
  $id = $_.Name
  if ($id -notmatch '^[a-z0-9][a-z0-9_-]*$') { return }

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker compose --project-name ("homelab-plugin-{0}" -f $id) down 2>$null | Out-Null
  $ErrorActionPreference = $prev

  $backend = $null
  foreach ($f in @("docker-compose.backend.yml", "docker-compose.yml")) {
    $candidate = Join-Path $_.FullName $f
    if (Test-Path -LiteralPath $candidate) { $backend = $candidate; break }
  }
  $frontend = Join-Path $_.FullName "docker-compose.frontend.yml"
  if ($backend) {
    Add-ComposeInclude -OverlayPath $appsOverlay -ComposeFile $backend -ProjectDir $_.FullName
    $wantBackend = $true
    Write-Host ("Plugin {0}: backend attached to homelab-backend." -f $id)
  }
  if (Test-Path -LiteralPath $frontend) {
    Add-ComposeInclude -OverlayPath $feAppsOverlay -ComposeFile $frontend -ProjectDir $_.FullName
    $wantFrontend = $true
    Write-Host ("Plugin {0}: frontend attached to homelab-frontend." -f $id)
  }
}

Set-Location $siteRoot
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"

if ($wantBackend) {
  $backendArgs = @("compose", "--project-directory", $siteRoot)
  $upstreamBe = Join-Path $siteRoot "upstream\docker-compose.backend.yml"
  if (Test-Path $upstreamBe) {
    $backendArgs += @(
      "-f", "upstream/docker-compose.backend.yml",
      "-f", ("upstream/{0}" -f $portsFile),
      "-f", "docker-compose.config.yml",
      "-f", "docker-compose.custom.yml",
      "-f", "docker-compose.apps.yml"
    )
  } else {
    $backendArgs += @(
      "-f", "docker-compose.backend.yml",
      "-f", $portsFile,
      "-f", "docker-compose.config.yml",
      "-f", "docker-compose.custom.yml",
      "-f", "docker-compose.apps.yml"
    )
  }
  $cmd = $backendArgs + @("up", "-d")
  & docker @cmd
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not start homelab-backend with market plugins."
  } else {
    $rm = $backendArgs + @("rm", "--force", "--stop", "pkm-data-permissions", "site-cli-volumes-permissions")
    & docker @rm 2>$null | Out-Null
    $gone = & docker ps -aq --filter "label=homelab.config-job=true" --filter "status=exited" 2>$null
    if ($gone) { & docker rm -f @gone 2>$null | Out-Null }
  }
}

if ($wantFrontend) {
  $frontendArgs = @("compose", "--project-directory", $siteRoot)
  $upstreamFe = Join-Path $siteRoot "upstream\docker-compose.frontend.yml"
  if (Test-Path $upstreamFe) {
    $frontendArgs += @(
      "-f", "upstream/docker-compose.frontend.yml",
      "-f", ("upstream/{0}" -f $frontendPortsFile)
    )
  } else {
    $frontendArgs += @("-f", "docker-compose.frontend.yml", "-f", $frontendPortsFile)
  }
  if (Test-Path $feAppsOverlay) {
    $frontendArgs += @("-f", "docker-compose.frontend.apps.yml")
  }
  $cmd = $frontendArgs + @("up", "-d")
  & docker @cmd
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not start homelab-frontend with market plugins."
  }
}

$ErrorActionPreference = $prev
