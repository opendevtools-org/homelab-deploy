<#
.SYNOPSIS
  Pulls the latest site data from origin and safely publishes local standby changes.

.DESCRIPTION
  For backup/standby site instances. Commits local site data changes if needed,
  syncs with origin, archives local conflict copies when the same file changed
  on both servers, pushes the synchronized branch, then updates submodules.
  After a successful sync, restarts PKM and imports pages/files/PDFs/bookmarks
  from disk (same as Import from disk in the UI). Stops pkm-backend and
  home-hub-platform before Git updates SQLite files, then starts them again.

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
$backupPaths = @("data", "docker-compose.custom.yml", "docker-compose.apps.yml", "README.md", "overrides")
$excludePathspec = ":(exclude)data/pkm/scripts/**/.uploads/**"
$sqliteMergeHelper = Join-Path $PSScriptRoot "Merge-SqliteGitConflict.py"
$pkmDupHelper = Join-Path $PSScriptRoot "Normalize-PkmDuplicatePaths.py"
$script:gitExtraArgs = @()
$script:pkmPositionSnapshot = $null
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

$script:stoppedForSync = @()

function Stop-DataLockContainers {
  $script:stoppedForSync = @()
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return }
  foreach ($name in @("pkm-backend", "home-hub-platform")) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $running = & docker inspect -f "{{.State.Running}}" $name 2>$null
    $ErrorActionPreference = $prev
    if ("$running".Trim() -ne "true") { continue }
    Write-Host ("Stopping {0} so Git can update SQLite files." -f $name)
    $ErrorActionPreference = "Continue"
    & docker stop $name 2>&1 | Out-Null
    $ErrorActionPreference = $prev
    $script:stoppedForSync += $name
  }
  if ($script:stoppedForSync.Count -gt 0) {
    Start-Sleep -Seconds 2
  }
}

function Start-DataLockContainers {
  if (-not $script:stoppedForSync -or $script:stoppedForSync.Count -eq 0) { return }
  foreach ($name in $script:stoppedForSync) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & docker start $name 2>&1 | Out-Null
    $ErrorActionPreference = $prev
  }
  $script:stoppedForSync = @()
}

function Export-GitBlob {
  param(
    [string]$ObjectSpec,
    [string]$Destination
  )

  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = "git"
  $startInfo.Arguments = 'cat-file blob "{0}"' -f ($ObjectSpec -replace '"', '\"')
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  if (-not $process.Start()) {
    throw "Failed to start git cat-file."
  }

  try {
    $file = [System.IO.File]::Create($Destination)
    try {
      $process.StandardOutput.BaseStream.CopyTo($file)
    } finally {
      $file.Dispose()
    }
    $errorText = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
      throw ("git cat-file failed for {0}: {1}" -f $ObjectSpec, $errorText.Trim())
    }
  } finally {
    $process.Dispose()
  }
}

function Merge-SqliteConflict {
  param([string]$Path)

  $databaseType = switch ($Path) {
    "data/hub/platform.db" { "platform" }
    "data/pkm/pkm.db" { "pkm" }
    default { return $false }
  }

  $python = Get-Command python3 -ErrorAction SilentlyContinue
  if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
  if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
  if (-not $python -or -not (Test-Path $sqliteMergeHelper)) {
    Send-Notification -Level "WARN" -Message ("SQLite merge unavailable for {0}; Python 3 and Merge-SqliteGitConflict.py are required." -f $Path)
    return $false
  }

  $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("homelab-sqlite-merge-{0}" -f [Guid]::NewGuid())
  New-Item -ItemType Directory -Path $tempDir | Out-Null
  try {
    $basePath = Join-Path $tempDir "base.db"
    $localPath = Join-Path $tempDir "local.db"
    $remotePath = Join-Path $tempDir "remote.db"
    $mergedPath = Join-Path $tempDir "merged.db"
    Export-GitBlob -ObjectSpec (":1:{0}" -f $Path) -Destination $basePath
    Export-GitBlob -ObjectSpec (":2:{0}" -f $Path) -Destination $localPath
    Export-GitBlob -ObjectSpec (":3:{0}" -f $Path) -Destination $remotePath

    $helperArgs = @(
      $sqliteMergeHelper, "--type", $databaseType,
      "--base", $basePath, "--local", $localPath,
      "--remote", $remotePath, "--output", $mergedPath
    )
    if ($python.Name -eq "py.exe" -or $python.Name -eq "py") {
      $helperArgs = @("-3") + $helperArgs
    }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $python.Source @helperArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $summary = ($output | Out-String).Trim()
    if ($code -ne 0) {
      Send-Notification -Level "WARN" -Message ("SQLite merge failed for {0}: {1}" -f $Path, $summary)
      return $false
    }

    Copy-Item -LiteralPath $mergedPath -Destination $Path -Force
    Invoke-Git add -- $Path | Out-Null
    Send-Notification -Level "INFO" -Message ("Conflict in {0}: SQLite rows merged successfully ({1})." -f $Path, $summary)
    return $true
  } catch {
    Send-Notification -Level "WARN" -Message ("SQLite merge skipped for {0}: {1}" -f $Path, $_.Exception.Message)
    return $false
  } finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
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
  param([string]$SyncError)

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
    $prevStatus = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $status = (& git status --short --untracked-files=no 2>&1 | Out-String).Trim()
    $ErrorActionPreference = $prevStatus
    & git merge --abort 2>&1 | Out-Null
    if ($SyncError -match "Access is denied|Permission denied|unable to unlink|unable to write|unable to create") {
      throw ("Git could not update working files (often SQLite held open by Docker). Original error: {0}" -f $SyncError)
    }
    throw ("Automatic sync failed, but no conflicted files were detected. {0} Status: {1}" -f $SyncError, $status)
  }

  foreach ($path in $conflictedPaths) {
    if (Merge-SqliteConflict -Path $path) {
      continue
    }

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
    $rebaseError = $_.Exception.Message
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git rebase --abort 2>&1 | Out-Null
    $ErrorActionPreference = $prev

    try {
      Invoke-Git merge --no-edit ("origin/{0}" -f $Branch) | Out-Null
    } catch {
      Resolve-GitConflictsWithRemote -SyncError ("{0} | merge: {1}" -f $rebaseError, $_.Exception.Message)
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

  if (-not [string]::IsNullOrWhiteSpace($NotifyWebhookUrl)) {
    try {
      $payload = @{ text = $line } | ConvertTo-Json -Compress
      Invoke-RestMethod -Method Post -Uri $NotifyWebhookUrl -ContentType "application/json" -Body $payload | Out-Null
    } catch {
      Write-Warning ("Cannot send webhook notification: {0}" -f $_.Exception.Message)
    }
  }
}

function Get-Python {
  foreach ($name in @("python3", "python")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Invoke-PkmDupHelper {
  param([string[]]$HelperArgs)
  if (-not (Test-Path $pkmDupHelper)) { return $null }
  $py = Get-Python
  if (-not $py) { return $null }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & $py $pkmDupHelper @HelperArgs 2>&1
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
}

function Repair-PkmDuplicatePaths {
  $docs = Join-Path $repoRoot "data\pkm\docs"
  if (-not (Test-Path $docs)) { return }
  $text = Invoke-PkmDupHelper -HelperArgs @(
    "apply-fs", "--docs", $docs, "--repo", $repoRoot,
    "--host", $script:hostId, "--stamp", $script:conflictTimestamp
  )
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  foreach ($line in ($text -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $level = if ($line -match "^(Duplicate|Conflicting)") { "WARN" } else { "INFO" }
    Send-Notification -Level $level -Message $line
  }
}

function Restore-PkmPositions {
  $db = Join-Path $repoRoot "data\pkm\pkm.db"
  if ([string]::IsNullOrWhiteSpace($script:pkmPositionSnapshot) -or -not (Test-Path $script:pkmPositionSnapshot)) {
    return
  }
  $out = Invoke-PkmDupHelper -HelperArgs @("restore", "--db", $db, "--from-json", $script:pkmPositionSnapshot)
  Remove-Item $script:pkmPositionSnapshot -Force -ErrorAction SilentlyContinue
  $script:pkmPositionSnapshot = $null
  if ([string]::IsNullOrWhiteSpace($out) -or $out -match "^restored 0 ") { return }
  Send-Notification -Level "INFO" -Message "Restored PKM page ordering after automatic merge."
  $container = [Environment]::GetEnvironmentVariable("HOMELAB_PKM_CONTAINER")
  if ([string]::IsNullOrWhiteSpace($container)) { $container = "pkm-backend" }
  docker restart $container 2>$null | Out-Null
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
Write-Host "Pull-DataGit: stopping pkm-backend and home-hub-platform before git sync when they are running."
Import-DotEnv -Path (Join-Path $repoRoot ".env")
Initialize-GitAuth

try {
  $branch = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -Last 1).ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq "HEAD") {
    throw "Detached HEAD is not supported for automatic pulls."
  }

  Save-PkmPositions
  try {
    Stop-DataLockContainers
    Commit-LocalChanges
    Sync-WithOrigin -Branch $branch
    Repair-PkmDuplicatePaths
    Commit-LocalChanges
    Invoke-Git push origin $branch | Out-Null
    Invoke-Git submodule update --init --recursive | Out-Null
  } finally {
    Start-DataLockContainers
  }

  $ok = "Pull/sync completed with origin/{0}." -f $branch
  Write-Host $ok
  Send-Notification -Level "INFO" -Message $ok
  Invoke-PkmDiskReindex
  Restore-PkmPositions
  $startPlugins = Join-Path $repoRoot "Start-MarketPlugins.ps1"
  if (Test-Path $startPlugins) {
    & $startPlugins
  }
} catch {
  $err = "Pull failed: {0}" -f $_.Exception.Message
  Send-Notification -Level "ERROR" -Message $err
  Write-Error $err
  throw
}
