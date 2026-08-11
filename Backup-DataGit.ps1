<#
.SYNOPSIS
  Commits and pushes changes under data/ as a daily backup.

.DESCRIPTION
  For site instances (data/ is versioned). Stages only data/, creates a
  timestamped commit if needed, syncs with origin (rebase then merge
  fallback), then pushes the current branch.

.EXAMPLE
  .\Backup-DataGit.ps1
#>
[CmdletBinding()]
param(
  [string]$NotifyWebhookUrl = $env:HOMELAB_BACKUP_NOTIFY_WEBHOOK_URL,
  [string]$NotificationLog = (Join-Path $PSScriptRoot "logs\backup-data-git.log")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $output = & git @GitArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    throw ("git {0} failed (exit {1}): {2}" -f ($GitArgs -join " "), $code, (($output | Out-String).Trim()))
  }
  return $output
}

function Send-Notification {
  param(
    [ValidateSet("INFO", "ERROR")]
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
      & eventcreate /T ERROR /ID 1000 /L APPLICATION /SO "HomelabDataGitBackup" /D $Message | Out-Null
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

$repoRoot = $PSScriptRoot
if (-not (Test-Path (Join-Path $repoRoot ".git"))) {
  throw "Run this script from the site instance root (folder with .git and data/)."
}
if (-not (Test-Path (Join-Path $repoRoot "data"))) {
  throw "Missing data/ under site root. This backup is for site instances only."
}

Set-Location $repoRoot

try {
  $branch = (Invoke-Git rev-parse --abbrev-ref HEAD | Select-Object -Last 1).ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($branch) -or $branch -eq "HEAD") {
    throw "Detached HEAD is not supported for automatic backup pushes."
  }

  Invoke-Git add data | Out-Null

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $staged = & git diff --cached --name-only -- data 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -ne 0) {
    throw ("git diff --cached failed: {0}" -f (($staged | Out-String).Trim()))
  }

  if (-not $staged) {
    $msg = "No changes under data/. Nothing to commit."
    Write-Host $msg
    Send-Notification -Level "INFO" -Message $msg
    exit 0
  }

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $message = "backup(data): $timestamp"
  Invoke-Git commit -m $message | Out-Null

  try {
    Invoke-Git pull --rebase origin $branch | Out-Null
  } catch {
    $rebaseError = $_.Exception.Message

    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & git rebase --abort 2>&1 | Out-Null
    $ErrorActionPreference = $prev

    try {
      Invoke-Git pull --no-rebase --no-edit origin $branch | Out-Null
    } catch {
      $mergeError = $_.Exception.Message

      $prev = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      & git merge --abort 2>&1 | Out-Null
      $ErrorActionPreference = $prev

      throw ("Automatic sync failed. Rebase error: {0} | Merge fallback error: {1}" -f $rebaseError, $mergeError)
    }
  }

  Invoke-Git push origin $branch | Out-Null

  $ok = "Backup committed and pushed on branch '{0}'." -f $branch
  Write-Host $ok
  Send-Notification -Level "INFO" -Message $ok
} catch {
  $err = "Backup failed: {0}" -f $_.Exception.Message
  Write-Error $err
  Send-Notification -Level "ERROR" -Message $err
  throw
}
