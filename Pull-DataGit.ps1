<#
.SYNOPSIS
  Pulls the latest site data from origin and safely publishes local standby changes.

.DESCRIPTION
  For backup/standby site instances. Commits local site data changes if needed,
  syncs with origin, archives local conflict copies when the same file changed
  on both servers, pushes the synchronized branch, then updates submodules.
  After a successful sync, restarts PKM and imports pages/files/PDFs/bookmarks
  from disk (same as Import from disk in the UI).

.EXAMPLE
  .\Pull-DataGit.ps1
#>
[CmdletBinding()]
param(
  [string]$NotifyWebhookUrl = $env:HOMELAB_BACKUP_NOTIFY_WEBHOOK_URL,
  [string]$NotificationLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$backupPaths = @("data", "docker-compose.apps.yml", "README.md")
$excludePathspec = ":(exclude)data/pkm/scripts/**/.uploads/**"
$script:gitExtraArgs = @()
$script:hostId = ([System.Net.Dns]::GetHostName() -replace '[^A-Za-z0-9._-]', '-')
if ([string]::IsNullOrWhiteSpace($script:hostId)) { $script:hostId = "unknown-host" }
$script:conflictTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"

function Import-DotEnv {
  param([string]$Path)

  if (-not (Test-Path $Path)) {
    return
  }

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
  if ([string]::IsNullOrWhiteSpace($pat)) {
    return
  }

  $originUrl = (& git remote get-url origin 2>$null | Select-Object -Last 1)
  if ([string]::IsNullOrWhiteSpace($originUrl) -or -not $originUrl.ToString().Trim().StartsWith("https")) {
    throw "HOMELAB_GIT_PAT requires an HTTPS origin remote."
  }

  $username = [Environment]::GetEnvironmentVariable("HOMELAB_GIT_USERNAME")
  if ([string]::IsNullOrWhiteSpace($username)) {
    $username = "git"
  }

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

function New-ConflictArchivePath {
  param([string]$Path)

  $directory = Split-Path -Parent $Path
  $leaf = Split-Path -Leaf $Path
  $extension = [System.IO.Path]::GetExtension($leaf)
  $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
  if ([string]::IsNullOrWhiteSpace($stem)) {
    $stem = $leaf
    $extension = ""
  }

  if ([string]::IsNullOrWhiteSpace($directory)) {
    $candidate = "{0}.local-conflict.{1}.{2}{3}" -f $stem, $script:hostId, $script:conflictTimestamp, $extension
  } else {
    $candidate = Join-Path $directory ("{0}.local-conflict.{1}.{2}{3}" -f $stem, $script:hostId, $script:conflictTimestamp, $extension)
  }

  $counter = 1
  while (Test-Path $candidate) {
    if ([string]::IsNullOrWhiteSpace($directory)) {
      $candidate = "{0}.local-conflict.{1}.{2}.{3}{4}" -f $stem, $script:hostId, $script:conflictTimestamp, $counter, $extension
    } else {
      $candidate = Join-Path $directory ("{0}.local-conflict.{1}.{2}.{3}{4}" -f $stem, $script:hostId, $script:conflictTimestamp, $counter, $extension)
    }
    $counter++
  }

  return $candidate
}

function Resolve-GitConflictsWithRemote {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $rawPaths = & git diff --name-only -z --diff-filter=U 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    & git merge --abort 2>&1 | Out-Null
    throw ("git diff --name-only --diff-filter=U failed: {0}" -f (($rawPaths | Out-String).Trim()))
  }

  $conflictedPaths = (($rawPaths -join "") -split [char]0) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  if (-not $conflictedPaths) {
    & git merge --abort 2>&1 | Out-Null
    throw "Automatic sync failed, but no conflicted files were detected. Check Git status manually."
  }

  foreach ($path in $conflictedPaths) {
    $archive = New-ConflictArchivePath -Path $path
    $archiveDir = Split-Path -Parent $archive

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git checkout --ours -- $path 2>&1 | Out-Null
    $oursCode = $LASTEXITCODE
    $ErrorActionPreference = $prev

    if ($oursCode -eq 0 -and (Test-Path $path)) {
      if ($archiveDir -and -not (Test-Path $archiveDir)) {
        New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
      }
      Copy-Item -LiteralPath $path -Destination $archive -Force
      Invoke-Git add -- $archive | Out-Null
      Send-Notification -Level "INFO" -Message ("Conflict in {0}: local version saved as {1}; remote version kept as canonical." -f $path, $archive)
    } else {
      Send-Notification -Level "INFO" -Message ("Conflict in {0}: no local file version could be archived; remote version kept as canonical." -f $path)
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git checkout --theirs -- $path 2>&1 | Out-Null
    $theirsCode = $LASTEXITCODE
    $ErrorActionPreference = $prev

    if ($theirsCode -eq 0) {
      Invoke-Git add -- $path | Out-Null
    } else {
      $prev = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      & git rm -f -- $path 2>&1 | Out-Null
      $ErrorActionPreference = $prev
    }
  }

  Invoke-Git commit --no-edit | Out-Null
}

function Commit-LocalChanges {
  $backupPathspecs = @($backupPaths + $excludePathspec)
  $addArgs = @("add", "-A", "--") + $backupPathspecs
  Invoke-Git @addArgs | Out-Null

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $diffArgs = @("diff", "--cached", "--name-only", "--") + $backupPathspecs
  $staged = & git @diffArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    throw ("git diff --cached failed: {0}" -f (($staged | Out-String).Trim()))
  }

  if (-not $staged) {
    return
  }

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Invoke-Git commit -m "backup(site): $timestamp" | Out-Null
}

function Sync-WithOrigin {
  param([string]$Branch)

  try {
    Invoke-Git pull --rebase --autostash origin $Branch | Out-Null
  } catch {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git rebase --abort 2>&1 | Out-Null
    $ErrorActionPreference = $prev

    try {
      Invoke-Git merge --no-edit ("origin/{0}" -f $Branch) | Out-Null
    } catch {
      Resolve-GitConflictsWithRemote
    }
  }
}

function Send-Notification {
  param(
    [ValidateSet("INFO", "WARN", "ERROR")]
    [string]$Level,
    [string]$Message
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message

  try {
    $logDir = Split-Path -Parent $NotificationLog
    if ($logDir -and -not (Test-Path $logDir)) {
      New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -Path $NotificationLog -Value $line
  } catch {
    Write-Warning ("Cannot write notification log: {0}" -f $_.Exception.Message)
  }

  if ($Level -eq "ERROR") {
    try {
      & eventcreate /T ERROR /ID 1000 /L APPLICATION /SO "HomelabDataGitPull" /D $Message | Out-Null
    } catch {
      Write-Warning ("Cannot write Windows Event Log notification: {0}" -f $_.Exception.Message)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($NotifyWebhookUrl)) {
    try {
      $payload = @{ text = $line } | ConvertTo-Json -Compress
      Invoke-RestMethod -Method Post -Uri $NotifyWebhookUrl -ContentType "application/json" -Body $payload | Out-Null
    } catch {
      Write-Warning ("Cannot send webhook notification: {0}" -f $_.Exception.Message)
    }
  }
}

function Invoke-PkmDiskReindex {
  $helper = Join-Path $repoRoot "Reindex-PkmFromDisk.ps1"
  if (-not (Test-Path $helper)) {
    Send-Notification -Level "INFO" -Message "PKM disk reindex skipped (Reindex-PkmFromDisk.ps1 not found)."
    return
  }

  $shell = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & $shell -NoProfile -ExecutionPolicy Bypass -File $helper 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev

  $text = ($output | Out-String).Trim()
  if ($text) { Write-Host $text }

  if ($code -ne 0) {
    Send-Notification -Level "WARN" -Message "PKM disk reindex failed after git sync. Use Import from disk in the PKM UI if items are missing."
    return
  }
  if ($text -match "skipped") {
    $last = ($text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
    Send-Notification -Level "INFO" -Message $last
    return
  }
  Send-Notification -Level "INFO" -Message "PKM imported pages, files, PDFs, and bookmarks from disk."
}

$repoRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($NotificationLog)) {
  $NotificationLog = Join-Path $repoRoot "logs\pull-data-git.log"
}
if (-not (Test-Path (Join-Path $repoRoot ".git"))) {
  throw "Run this script from the standby site root (folder with .git and data/)."
}
if (-not (Test-Path (Join-Path $repoRoot "data"))) {
  throw "Missing data/ under site root. This pull is for standby site instances only."
}

Set-Location $repoRoot
Import-DotEnv -Path (Join-Path $repoRoot ".env")
Initialize-GitAuth

try {
  $branch = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -Last 1).ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq "HEAD") {
    throw "Detached HEAD is not supported for automatic pulls."
  }

  Commit-LocalChanges
  Sync-WithOrigin -Branch $branch
  Invoke-Git push origin $branch | Out-Null
  Invoke-Git submodule update --init --recursive | Out-Null

  $ok = "Pull/sync completed with origin/{0}." -f $branch
  Write-Host $ok
  Send-Notification -Level "INFO" -Message $ok
  Invoke-PkmDiskReindex
} catch {
  $err = "Pull failed: {0}" -f $_.Exception.Message
  Send-Notification -Level "ERROR" -Message $err
  Write-Error $err
  throw
}
