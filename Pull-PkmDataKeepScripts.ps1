<#
.SYNOPSIS
  Copies site data from origin into the local working tree, keeping local PKM scripts.

.DESCRIPTION
  Run from the site instance root (folder with data/, .git), or from upstream/.
  Always targets the site root: fetches origin and restores data/ from the
  current branch (docs, files, PDFs, bookmarks, SQLite, Hub DB, etc.).
  data/pkm/scripts is copied aside first and put back so local script edits
  are not overwritten. Does not commit or push.

.EXAMPLE
  .\Pull-PkmDataKeepScripts.ps1

.EXAMPLE
  .\upstream\Pull-PkmDataKeepScripts.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:gitExtraArgs = @()

function Test-HomelabSiteRoot([string]$Dir) {
  foreach ($name in @("docker-compose.apps.yml", "docker-compose.custom.yml", ".env")) {
    if (Test-Path -LiteralPath (Join-Path $Dir $name)) { return $true }
  }
  return (Test-Path -LiteralPath (Join-Path $Dir "data")) -and (Test-Path -LiteralPath (Join-Path $Dir ".git"))
}

function Import-DotEnv {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return }
  foreach ($line in Get-Content -Path $Path) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line.TrimStart().StartsWith("#")) { continue }
    $pair = $line -split '=', 2
    if ($pair.Count -ne 2) { continue }
    $name = $pair[0].Trim()
    $value = $pair[1].Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
      [Environment]::SetEnvironmentVariable($name, $value)
    }
  }
}

function Initialize-GitAuth {
  $pat = [Environment]::GetEnvironmentVariable("HOMELAB_GIT_PAT")
  if ([string]::IsNullOrWhiteSpace($pat)) { return }
  $originUrl = (& git remote get-url origin 2>$null | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($originUrl) -or -not $originUrl.ToString().Trim().StartsWith("https")) {
    throw "HOMELAB_GIT_PAT requires an HTTPS origin remote."
  }
  $username = [Environment]::GetEnvironmentVariable("HOMELAB_GIT_USERNAME")
  if ([string]::IsNullOrWhiteSpace($username)) { $username = "git" }
  $authBytes = [System.Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $username, $pat))
  $authB64 = [Convert]::ToBase64String($authBytes)
  $script:gitExtraArgs = @(
    "-c", "credential.helper=",
    "-c", "core.askPass=",
    "-c", ("http.extraHeader=AUTHORIZATION: basic {0}" -f $authB64)
  )
}

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $allArgs = @($script:gitExtraArgs + $GitArgs)
  $output = & git @allArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    throw ("git {0} failed (exit {1}): {2}" -f ($GitArgs -join " "), $code, (($output | Out-String).Trim()))
  }
  return $output
}

$here = $PSScriptRoot
if ((Split-Path -Leaf $here) -eq "upstream" -and (Test-HomelabSiteRoot (Split-Path -Parent $here))) {
  $repoRoot = Split-Path -Parent $here
} elseif (Test-HomelabSiteRoot $here) {
  $repoRoot = $here
} else {
  throw "Run from site root (folder with .git and data/) or from upstream/ inside a site instance."
}

if (-not (Test-Path (Join-Path $repoRoot ".git"))) {
  throw "Site root has no .git. This script updates the site data repo, not the product submodule."
}
if (-not (Test-Path (Join-Path $repoRoot "data"))) {
  throw "Missing data/ under site root."
}

Set-Location $repoRoot
Import-DotEnv -Path (Join-Path $repoRoot ".env")
Initialize-GitAuth

$branch = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -Last 1).ToString().Trim()
if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq "HEAD") {
  throw "Detached HEAD is not supported. Check out the site branch first."
}

$scriptsRel = "data\pkm\scripts"
$scriptsAbs = Join-Path $repoRoot $scriptsRel
$keepDir = Join-Path ([System.IO.Path]::GetTempPath()) ("pkm-scripts-keep-{0}" -f [Guid]::NewGuid().ToString("n"))
$hadScripts = Test-Path $scriptsAbs
if ($hadScripts) {
  New-Item -ItemType Directory -Path $keepDir | Out-Null
  Copy-Item -LiteralPath $scriptsAbs -Destination (Join-Path $keepDir "scripts") -Recurse -Force
  Write-Host "Saved local data/pkm/scripts aside."
}

try {
  Invoke-Git fetch origin $branch | Out-Null
  $source = "origin/{0}" -f $branch
  Invoke-Git restore --source $source --worktree -- "data" | Out-Null
  Write-Host ("Restored data/ from {0} (working tree only, site root {1})." -f $source, $repoRoot)

  if ($hadScripts) {
    $restored = Join-Path $repoRoot $scriptsRel
    if (Test-Path $restored) {
      Remove-Item -LiteralPath $restored -Recurse -Force
    }
    $parent = Split-Path -Parent $restored
    if (-not (Test-Path $parent)) {
      New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $keepDir "scripts") -Destination $restored -Recurse -Force
    Write-Host "Restored local data/pkm/scripts (not overwritten from origin)."
  }
}
finally {
  if (Test-Path $keepDir) {
    Remove-Item -LiteralPath $keepDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "Done. Local scripts kept; other data/ matches origin. Nothing was committed or pushed."
