<#
.SYNOPSIS
  Attach Market plugins to the homelab-backend and homelab-frontend Compose projects.

.PARAMETER LogFile
  Append all console and docker output here. Default: logs/start-market-plugins.log
#>
[CmdletBinding()]
param(
  [ValidateSet("lan", "local")]
  [string]$Ports = "lan",
  [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$siteRoot = $here
if ((Split-Path -Leaf $here) -eq "upstream" -and (Test-Path (Join-Path (Split-Path $here) "data"))) {
  $siteRoot = Split-Path $here
}
if ([string]::IsNullOrWhiteSpace($LogFile)) {
  $fromEnv = [Environment]::GetEnvironmentVariable("HOMELAB_START_PLUGINS_LOG")
  if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
    $LogFile = $fromEnv
  } else {
    $LogFile = Join-Path $siteRoot "logs\start-market-plugins.log"
  }
}

function Write-PluginLog {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Write-Host $line
  try {
    $dir = Split-Path -Parent $LogFile
    if ($dir -and -not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
  } catch {
    Write-Warning ("Cannot write log file: {0}" -f $_.Exception.Message)
  }
}

function Invoke-LoggedDocker {
  param([string[]]$DockerArgs)
  Write-PluginLog ("docker " + ($DockerArgs -join " "))
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & docker @DockerArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  foreach ($row in @($output)) {
    if ($null -eq $row) { continue }
    Write-PluginLog ([string]$row)
  }
  return $code
}

$root = Join-Path $siteRoot "data\hub\plugins"
Write-PluginLog ("Start-MarketPlugins Ports={0} LogFile={1}" -f $Ports, $LogFile)
if (-not (Test-Path $root)) {
  Write-PluginLog "No data/hub/plugins directory; nothing to start."
  return
}
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-PluginLog "docker not found; skip."
  return
}

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
    Write-PluginLog ("Created {0}" -f $OverlayPath)
    return $true
  }
  $text = [IO.File]::ReadAllText($OverlayPath)
  if ($text.Contains($composeRel)) { return $false }
  $item = "  - path: $composeRel`n    project_directory: $projectRel`n"
  if ($text -match '(?m)^include:\s*\r?\n') {
    $text = [regex]::Replace($text, '(?m)^include:\s*\r?\n', "include:`n$item", 1)
  } else {
    $text = "include:`n$item`n$text"
  }
  [IO.File]::WriteAllText($OverlayPath, $text)
  Write-PluginLog ("Updated include in {0}: {1}" -f $OverlayPath, $composeRel)
  return $true
}

$appsOverlay = Join-Path $siteRoot "docker-compose.apps.yml"
$feAppsOverlay = Join-Path $siteRoot "docker-compose.frontend.apps.yml"
$wantBackend = $false
$wantFrontend = $false
$backendDirty = $false
$frontendDirty = $false
$skipCompose = $env:HOMELAB_SKIP_MARKET_COMPOSE -eq "1"

Get-ChildItem -Directory $root | ForEach-Object {
  $id = $_.Name
  if ($id -notmatch '^[a-z0-9][a-z0-9_-]*$') { return }

  $null = Invoke-LoggedDocker @("compose", "--project-name", ("homelab-plugin-{0}" -f $id), "down")

  $backend = $null
  foreach ($f in @("docker-compose.backend.yml", "docker-compose.yml")) {
    $candidate = Join-Path $_.FullName $f
    if (Test-Path -LiteralPath $candidate) { $backend = $candidate; break }
  }
  $frontend = Join-Path $_.FullName "docker-compose.frontend.yml"
  if ($backend) {
    if (Add-ComposeInclude -OverlayPath $appsOverlay -ComposeFile $backend -ProjectDir $_.FullName) {
      $script:backendDirty = $true
    }
    $script:wantBackend = $true
    Write-PluginLog ("Plugin {0}: backend attached to homelab-backend." -f $id)
  }
  if (Test-Path -LiteralPath $frontend) {
    if (Add-ComposeInclude -OverlayPath $feAppsOverlay -ComposeFile $frontend -ProjectDir $_.FullName) {
      $script:frontendDirty = $true
    }
    $script:wantFrontend = $true
    Write-PluginLog ("Plugin {0}: frontend attached to homelab-frontend." -f $id)
  }
}

Set-Location $siteRoot

function Test-NamedRunning([string]$Name) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $state = & docker inspect -f "{{.State.Running}}" $Name 2>$null
  $ErrorActionPreference = $prev
  return $state -eq "true"
}

$needBackendUp = $false
if ($wantBackend -and -not $skipCompose) {
  $needBackendUp = $backendDirty -or -not (Test-NamedRunning "homelab-guacamole")
}

if ($needBackendUp) {
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
  $plugin = Join-Path $siteRoot "data\hub\plugins\guacamole\docker-compose.backend.yml"
  if (Test-Path -LiteralPath $plugin) {
    if (Test-Path (Join-Path $siteRoot "upstream\docker-compose.guacamole-volume.yml")) {
      $backendArgs += @("-f", "upstream/docker-compose.guacamole-volume.yml")
    } elseif (Test-Path (Join-Path $siteRoot "docker-compose.guacamole-volume.yml")) {
      $backendArgs += @("-f", "docker-compose.guacamole-volume.yml")
    }
  }
  $code = Invoke-LoggedDocker ($backendArgs + @("up", "-d"))
  if ($code -ne 0) {
    Write-PluginLog "Could not start homelab-backend with market plugins."
  } else {
    $null = Invoke-LoggedDocker ($backendArgs + @("rm", "--force"))
    $gone = & docker ps -aq --filter "label=homelab.config-job=true" --filter "status=exited" 2>$null
    if ($gone) {
      $null = Invoke-LoggedDocker (@("rm", "-f") + @($gone))
    }
  }
}

$needFrontendUp = $false
if (-not $skipCompose) {
  $needFrontendUp = $frontendDirty -or -not (Test-NamedRunning "home-hub")
}
if (-not $needFrontendUp) {
  if ($skipCompose) {
    Write-PluginLog "Skip plugin Compose up (includes already applied; stack starts next)."
  } else {
    Write-PluginLog "Plugin includes unchanged; skip extra Compose up."
  }
  Write-PluginLog "Start-MarketPlugins finished."
  return
}

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
$code = Invoke-LoggedDocker ($frontendArgs + @("up", "-d"))
if ($code -ne 0) {
  Write-PluginLog "Could not start homelab-frontend with market plugins."
}

Write-PluginLog "Start-MarketPlugins finished."
