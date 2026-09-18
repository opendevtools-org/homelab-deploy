<#
.SYNOPSIS
  Copies site data from origin into the local working tree, keeping local PKM scripts.
  Page folder order comes from origin (pkm.db pages.position). Does not touch data/hub.

.DESCRIPTION
  Run from the site instance root (folder with data/, .git), or from upstream/.
  Fetches origin and restores data/ from the current branch. data/pkm/scripts is
  copied aside and put back. After restore, origin pages.position is snapshotted
  and reapplied after reindex so the sidebar matches remote.
  Stops PKM before replacing pkm.db so SQLite WAL cannot keep a stale order.
  Does not commit or push.

.EXAMPLE
  .\Pull-PkmDataKeepScripts.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:gitExtraArgs = @()
$script:pkmPositionSnapshot = $null

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

function Get-Python {
  foreach ($name in @("python3", "python")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Get-PkmDupHelper {
  foreach ($rel in @("Normalize-PkmDuplicatePaths.py", "upstream\Normalize-PkmDuplicatePaths.py")) {
    $p = Join-Path $repoRoot $rel
    if (Test-Path $p) { return $p }
  }
  return $null
}

function Invoke-PkmDupHelper {
  param([string[]]$HelperArgs)
  $helper = Get-PkmDupHelper
  if ([string]::IsNullOrWhiteSpace($helper)) { return $null }
  $py = Get-Python
  if (-not $py) { return $null }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & $py $helper @HelperArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) { return $null }
  return ($output | Out-String).Trim()
}

function Save-PkmPositions {
  $db = Join-Path $repoRoot "data\pkm\pkm.db"
  $script:pkmPositionSnapshot = $null
  if (-not (Test-Path $db)) { return }
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("homelab-pkm-positions-{0}.json" -f [guid]::NewGuid().ToString("n"))
  $out = Invoke-PkmDupHelper -HelperArgs @("snapshot", "--db", $db, "--out", $tmp)
  if ($null -eq $out) {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    return
  }
  $script:pkmPositionSnapshot = $tmp
  Write-Host "Saved origin PKM page order."
}

function Restore-PkmPositions {
  $db = Join-Path $repoRoot "data\pkm\pkm.db"
  if ([string]::IsNullOrWhiteSpace($script:pkmPositionSnapshot) -or -not (Test-Path $script:pkmPositionSnapshot)) {
    return
  }
  $out = Invoke-PkmDupHelper -HelperArgs @("restore", "--db", $db, "--from-json", $script:pkmPositionSnapshot)
  if ([string]::IsNullOrWhiteSpace($out) -or $out -match "^restored 0 ") { return }
  Write-Host "Restored origin PKM page order."
}

function Clear-PkmSqliteSidecars {
  $db = Join-Path $repoRoot "data\pkm\pkm.db"
  foreach ($ext in @("-wal", "-shm")) {
    $side = $db + $ext
    if (Test-Path $side) {
      Remove-Item -LiteralPath $side -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-PkmContainer {
  $container = [Environment]::GetEnvironmentVariable("HOMELAB_PKM_CONTAINER")
  if ([string]::IsNullOrWhiteSpace($container)) { return "pkm-backend" }
  return $container
}

function Remove-PkmFilesNotOnOrigin {
  param([string]$Source)
  $raw = Invoke-Git ls-tree -r --name-only $Source -- "data/pkm"
  $want = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $text = ($raw | Out-String)
  foreach ($line in ($text -split "[\r\n]+")) {
    $p = [string]$line
    $p = $p.Trim().Replace('\', '/')
    if ($p -notlike "data/pkm/*") { continue }
    [void]$want.Add($p)
  }
  if ($want.Count -lt 1) {
    Write-Host "Skip extra-file cleanup: origin ls-tree for data/pkm was empty."
    return
  }
  Write-Host ("Origin data/pkm file count: {0}" -f $want.Count)
  $pkmRoot = Join-Path $repoRoot "data\pkm"
  if (-not (Test-Path $pkmRoot)) { return }
  $files = Get-ChildItem -LiteralPath $pkmRoot -Recurse -Force -File -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    if ($rel -like "data/pkm/scripts" -or $rel -like "data/pkm/scripts/*") { continue }
    if (-not $want.Contains($rel)) {
      Remove-Item -LiteralPath $f.FullName -Force
    }
  }
  $dirs = Get-ChildItem -LiteralPath $pkmRoot -Recurse -Force -Directory -ErrorAction SilentlyContinue |
    Sort-Object { $_.FullName.Length } -Descending
  foreach ($d in $dirs) {
    $rel = $d.FullName.Substring($repoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    if ($rel -like "data/pkm/scripts" -or $rel -like "data/pkm/scripts/*") { continue }
    if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
      Remove-Item -LiteralPath $d.FullName -Force
    }
  }
}

function Stop-PkmIfPresent {
  $container = Get-PkmContainer
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker inspect $container 2>&1 | Out-Null
  $exists = $LASTEXITCODE -eq 0
  $ErrorActionPreference = $prev
  if (-not $exists) { return }
  Write-Host ("Stopping {0} before replacing pkm.db." -f $container)
  $ErrorActionPreference = "Continue"
  & docker stop $container 2>&1 | Out-Null
  $ErrorActionPreference = $prev
}

function Start-PkmIfPresent {
  $container = Get-PkmContainer
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  & docker start $container 2>&1 | Out-Null
  $ErrorActionPreference = $prev
}

function Invoke-PkmDiskReindex {
  $helper = Join-Path $repoRoot "Reindex-PkmFromDisk.ps1"
  if (-not (Test-Path $helper)) {
    $helper = Join-Path $repoRoot "upstream\Reindex-PkmFromDisk.ps1"
  }
  if (-not (Test-Path $helper)) { return }
  $shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & $shell -NoProfile -ExecutionPolicy Bypass -File $helper 2>&1
  $ErrorActionPreference = $prev
  $text = ($output | Out-String).Trim()
  if ($text) { Write-Host $text }
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

Stop-PkmIfPresent

try {
  Invoke-Git fetch origin $branch | Out-Null
  $source = "origin/{0}" -f $branch
  Invoke-Git checkout $source -- "data/pkm"
  Invoke-Git restore --staged -- "data/pkm" | Out-Null
  Remove-PkmFilesNotOnOrigin -Source $source
  Clear-PkmSqliteSidecars
  Write-Host ("Restored data/pkm from {0} (Hub data/ left untouched)." -f $source)

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

  # Origin pkm.db already has page order. Disk reindex would re-import extra
  # local folders and reset positions to 1.0.
  Start-PkmIfPresent
}
finally {
  if ($script:pkmPositionSnapshot -and (Test-Path $script:pkmPositionSnapshot)) {
    Remove-Item $script:pkmPositionSnapshot -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $keepDir) {
    Remove-Item -LiteralPath $keepDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host "Done. Local scripts kept; PKM tree/order match origin. Hub/Guacamole were not overwritten."
