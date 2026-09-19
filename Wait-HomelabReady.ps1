<#
.SYNOPSIS
  Bring Hub/PKM Compose stacks up, wait for the PKM API, restart nginx so the UI is not 502.

.DESCRIPTION
  Backend first (creates homelab_default), then frontend, remove exited init jobs,
  wait until pkm-backend /api/health answers, restart pkm-frontend and home-hub
  so nginx re-resolves Docker DNS, then confirm the frontend can reach the API.
#>
[CmdletBinding()]
param(
  [ValidateSet("lan", "local")]
  [string]$Ports = "lan"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
if ([string]::IsNullOrWhiteSpace($fromEnv) -eq $false) { $Ports = $fromEnv }

$portsFile = if ($Ports -eq "local") { "docker-compose.local.yml" } else { "docker-compose.lan.yml" }
$frontendPortsFile = if ($Ports -eq "local") { "docker-compose.frontend.local.yml" } else { "docker-compose.frontend.lan.yml" }

function Invoke-Docker {
  param([string[]]$DockerArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker @DockerArgs
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return $code
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Host "Wait-HomelabReady skipped (docker not found)."
  exit 0
}

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

Write-Host "Ensuring homelab-backend is up (API before nginx)..."
$code = Invoke-Docker ($backendArgs + @("up", "-d"))
if ($code -ne 0) { throw "docker compose backend up failed" }
$null = Invoke-Docker ($backendArgs + @("rm", "--force"))

Write-Host "Ensuring homelab-frontend is up..."
$code = Invoke-Docker ($frontendArgs + @("up", "-d"))
if ($code -ne 0) { throw "docker compose frontend up failed (is homelab_default present? start backend first)." }

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

Write-Host "Waiting for PKM API on pkm-backend..."
$ok = $false
for ($i = 0; $i -lt 90; $i++) {
  if (Test-PkmApi) { $ok = $true; break }
  Start-Sleep -Seconds 1
}
if (-not $ok) {
  throw "PKM API did not become healthy on pkm-backend. Check: docker logs pkm-backend"
}

Write-Host "Restarting Hub/PKM nginx so they resolve pkm-backend / hub-platform..."
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

Write-Host "Waiting until pkm-frontend can reach pkm-backend..."
$ok = $false
for ($i = 0; $i -lt 30; $i++) {
  if (Test-PkmViaNginx) { $ok = $true; break }
  Start-Sleep -Seconds 1
}
if (-not $ok) {
  throw "pkm-frontend still cannot reach pkm-backend:8000 (502). Check Docker networks: both must be on homelab_default."
}

Write-Host "Hub/PKM ready (API healthy, nginx can proxy)."
exit 0
