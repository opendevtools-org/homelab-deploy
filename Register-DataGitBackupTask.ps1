<#
.SYNOPSIS
  Registers a Windows Scheduled Task to run Backup-DataGit.ps1 daily.

.DESCRIPTION
  Registers for the current user. Tries ScheduledTasks cmdlets first, then
  schtasks.exe. If both fail with access denied, re-run from an elevated
  PowerShell (Run as administrator).

.EXAMPLE
  .\Register-DataGitBackupTask.ps1
  .\Register-DataGitBackupTask.ps1 -Time 03:30
#>
[CmdletBinding()]
param(
  [string]$TaskName = "Homelab-Data-GitBackup",
  [string]$Time = "00:05"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Time -notmatch '^\d{1,2}:\d{2}$') {
  throw "Time must be HH:mm (24h), got: $Time"
}

$repoRoot = $PSScriptRoot
$backupScript = Join-Path $repoRoot "Backup-DataGit.ps1"

if (-not (Test-Path $backupScript)) {
  throw "Missing script: $backupScript"
}
if (-not (Test-Path (Join-Path $repoRoot "data"))) {
  Write-Warning "No data/ folder found. Register anyway; run from a site instance root for backups to work."
}

$pwsh = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path $pwsh)) {
  throw "PowerShell executable not found at: $pwsh"
}

$tr = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $pwsh, $backupScript
$registered = $false
$lastError = $null

# 1) Preferred: ScheduledTasks module (current user, interactive)
try {
  $action = New-ScheduledTaskAction -Execute $pwsh -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $backupScript)
  $trigger = New-ScheduledTaskTrigger -Daily -At $Time
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  # Omit Principal so the task is created in the current user context (often works without elevation).
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
  $registered = $true
} catch {
  $lastError = $_.Exception.Message
  Write-Warning ("Register-ScheduledTask failed: {0}" -f $lastError)
}

# 2) Fallback: schtasks for current user
if (-not $registered) {
  $schtasks = Join-Path $env:WINDIR "System32\schtasks.exe"
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $out = & $schtasks /Create /TN $TaskName /SC DAILY /ST $Time /RL LIMITED /F /TR $tr 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  if ($code -eq 0) {
    $registered = $true
  } else {
    $lastError = (($out | Out-String).Trim())
    Write-Warning ("schtasks failed (exit {0}): {1}" -f $code, $lastError)
  }
}

if (-not $registered) {
  throw @"
Access denied registering scheduled task '$TaskName'.
Re-open PowerShell as Administrator in this folder and run:
  .\Register-DataGitBackupTask.ps1 -Time $Time
Last error: $lastError
"@
}

Write-Host ("Scheduled task '{0}' registered for every day at {1} (runs while this user is logged on)." -f $TaskName, $Time)
