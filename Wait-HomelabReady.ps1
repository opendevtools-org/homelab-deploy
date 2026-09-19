<#
.SYNOPSIS
  Wait for PKM API and restart nginx so the Hub/PKM UI is not 502.

.DESCRIPTION
  Starts Hub/PKM containers if they exist and are stopped. Does not rebuild
  images. Waits for pkm-backend /api/health, restarts pkm-frontend and home-hub
  so nginx re-resolves Docker DNS, then checks that nginx can reach the API.
  Compose up is used only when pkm-backend is missing.
#>
[CmdletBinding()]
param(
  [ValidateSet("lan", "local")]
  [string]$Ports = "lan"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Ts {
  param($Message)
  Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
}

function Test-SiteRoot([string]$d) {
  return (Test-Path (Join-Path $d "docker-compose.custom.yml")) `
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
$fromEnv = [Environment]::GetEnvironmentVariable("HOMELAB_PORTS")
if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { $Ports = $fromEnv }

$portsFile = if ($Ports -eq "local") { "docker-compose.local.yml" } else { "docker-compose.lan.yml" }
$frontendPortsFile = if ($Ports -eq "local") { "docker-compose.frontend.local.yml" } else { "docker-compose.frontend.lan.yml" }

function Test-ContainerRunning([string]$Name) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $state = (& docker inspect -f "{{.State.Running}}" $Name 2>$null | Select-Object -Last 1)
  $ErrorActionPreference = $prev
  return ($null -ne $state -and $state.ToString().Trim() -eq "true")
}

function Test-ContainerExists([string]$Name) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $null = & docker inspect $Name 2>$null
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return ($code -eq 0)
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Ts "Wait-HomelabReady skipped (docker not found)."
  exit 0
}

function Start-Named([string]$Name) {
  if (-not (Test-ContainerExists $Name)) { return }
  if (Test-ContainerRunning $Name) { return }
  Write-Ts ("Starting {0}..." -f $Name)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker start $Name | Out-Null
  $ErrorActionPreference = $prev
}

if (-not (Test-ContainerExists "pkm-backend")) {
  Write-Ts "pkm-backend missing; running Compose backend up..."
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
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker @($backendArgs + @("up", "-d")) | Out-Null
  $ErrorActionPreference = $prev
}

if (-not (Test-ContainerExists "pkm-frontend")) {
  Write-Ts "pkm-frontend missing; running Compose frontend up..."
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
  if (Test-Path (Join-Path $siteRoot "docker-compose.frontend.apps.yml")) {
    $frontendArgs += @("-f", "docker-compose.frontend.apps.yml")
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker @($frontendArgs + @("up", "-d")) | Out-Null
  $ErrorActionPreference = $prev
}

foreach ($n in @("pkm-backend", "home-hub-platform", "homelab-guacamole", "pkm-frontend", "home-hub")) {
  Start-Named $n
}

if (-not (Test-ContainerRunning "pkm-backend")) {
  throw "pkm-backend is not running. Check: docker logs pkm-backend"
}
if (-not (Test-ContainerRunning "pkm-frontend")) {
  throw "pkm-frontend is not running. Check: docker logs pkm-frontend"
}

$probe = @'
import urllib.request
urllib.request.urlopen("http://127.0.0.1:8000/api/health", timeout=5).read()
'@

function Test-PkmApi {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker exec pkm-backend python -c $probe 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $ErrorActionPreference = $prev; return $true }
  & docker exec pkm-backend python3 -c $probe 2>$null | Out-Null
  $ok = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $prev
  return $ok
}

Write-Ts "Waiting for PKM API on pkm-backend..."
$ok = $false
for ($i = 0; $i -lt 90; $i++) {
  if (Test-PkmApi) { $ok = $true; break }
  Start-Sleep -Seconds 1
}
if (-not $ok) {
  throw "PKM API did not become healthy on pkm-backend. Check: docker logs pkm-backend"
}

Write-Ts "Restarting Hub/PKM nginx so they resolve pkm-backend / hub-platform..."
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
foreach ($n in @("pkm-frontend", "home-hub")) {
  & docker restart $n 2>$null | Out-Null
}
$ErrorActionPreference = $prev
Start-Sleep -Seconds 2

function Test-PkmViaNginx {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker exec pkm-frontend wget -q -T 5 -O /dev/null http://pkm-backend:8000/api/health 2>$null
  $ok = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $prev
  return $ok
}

Write-Ts "Waiting until pkm-frontend can reach pkm-backend..."
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
  if (Test-PkmViaNginx) { $ok = $true; break }
  Start-Sleep -Seconds 1
}
if (-not $ok) {
  throw "pkm-frontend still cannot reach pkm-backend:8000 (502). Both must be on homelab_default."
}

Write-Ts "Hub/PKM ready (API healthy, nginx can proxy)."

if (Test-ContainerExists "homelab-guacamole") {
  Start-Named "homelab-guacamole"
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker network connect homelab_default homelab-guacamole 2>$null | Out-Null
  $ErrorActionPreference = $prev
  function Test-HttpUrl([string]$Url) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $oldProg = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
      Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3 | Out-Null
      return $true
    } catch {
      $resp = $_.Exception.Response
      if ($resp -and $resp.StatusCode) {
        return ([int]$resp.StatusCode -lt 500)
      }
      return $false
    } finally {
      $ProgressPreference = $oldProg
      $ErrorActionPreference = $prev
    }
  }

  function Test-GuacamoleTcp([string]$HostName, [int]$Port) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $py = "import socket; socket.create_connection(('$HostName',$Port),2).close()"
    & docker exec home-hub-platform python -c $py 2>$null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $ok
  }

  function Test-Guacamole {
    if (Test-HttpUrl "http://127.0.0.1:8080/guacamole/") { return $true }
    if (Test-HttpUrl "http://127.0.0.1:8080/") { return $true }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $raw = (& docker inspect -f "{{range.NetworkSettings.Networks}}{{.IPAddress}} {{end}}" homelab-guacamole 2>$null | Select-Object -Last 1)
    $ErrorActionPreference = $prev
    $ips = @()
    if ($raw) { $ips = @($raw.ToString().Trim() -split "\s+" | Where-Object { $_ }) }
    foreach ($ip in $ips) {
      if (Test-GuacamoleTcp $ip 8080) { return $true }
    }
    if (Test-GuacamoleTcp "homelab-guacamole" 8080) { return $true }
    return $false
  }

  Write-Ts "Waiting until Guacamole answers on :8080..."
  $elapsed = 0
  while (-not (Test-Guacamole)) {
    $elapsed += 5
    if (($elapsed % 30) -eq 0) {
      $prev = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      $ips = (& docker inspect -f "{{range.NetworkSettings.Networks}}{{.IPAddress}}({{.NetworkID}}) {{end}}" homelab-guacamole 2>$null)
      $tail = (& docker logs --tail 6 homelab-guacamole 2>&1 | Out-String)
      $ErrorActionPreference = $prev
      Write-Ts ("  still starting ({0}s) ips={1}" -f $elapsed, ([string]$ips).Trim())
      foreach ($line in ($tail -split "`r?`n")) {
        if ($line.Trim()) { Write-Ts ("    log: {0}" -f $line.Trim()) }
      }
    } else {
      Write-Ts ("  still starting ({0}s)" -f $elapsed)
    }
    Start-Sleep -Seconds 5
  }
  Write-Ts "Guacamole is up."
}

$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$gone = @(
  & docker ps -aq --filter "label=com.docker.compose.project=homelab-backend" --filter "status=exited" 2>$null
)
if ($gone -and $gone.Count -gt 0) {
  Write-Ts "Removing exited backend init jobs..."
  $null = & docker rm -f @gone 2>$null
}
$ErrorActionPreference = $prev

exit 0
