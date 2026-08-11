<#
.SYNOPSIS
  Registers a Windows Scheduled Task to run Backup-DataGit.ps1 daily.

.DESCRIPTION
  Prefers a current-user interactive task (/IT) so elevation is often not
  required. Falls back to ScheduledTasks cmdlets, then schtasks without /IT.
  If all fail, open PowerShell as Administrator and re-run.

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

$schtasks = Join-Path $env:WINDIR "System32\schtasks.exe"
$tr = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f $pwsh, $backupScript
$userName = $env:USERNAME
$registered = $false
$errors = New-Object System.Collections.Generic.List[string]

function Invoke-SchtasksCreate {
  param([string[]]$ExtraArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $allArgs = @("/Create", "/TN", $TaskName, "/SC", "DAILY", "/ST", $Time, "/F", "/TR", $tr) + $ExtraArgs
  $out = & $schtasks @allArgs 2>&1
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  return @{ Code = $code; Output = (($out | Out-String).Trim()) }
}

# 1) Current-user interactive task — usually works without Administrator
$r = Invoke-SchtasksCreate -ExtraArgs @("/IT", "/RL", "LIMITED", "/RU", $userName)
if ($r.Code -eq 0) {
  $registered = $true
} else {
  $errors.Add(("schtasks /IT: {0}" -f $r.Output)) | Out-Null
}

# 2) ScheduledTasks module (current session user)
if (-not $registered) {
  try {
    $action = New-ScheduledTaskAction -Execute $pwsh -Argument ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $backupScript)
    $trigger = New-ScheduledTaskTrigger -Daily -At $Time
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
    $registered = $true
  } catch {
    $errors.Add(("Register-ScheduledTask: {0}" -f $_.Exception.Message)) | Out-Null
  }
}

# 3) schtasks without /IT (may need elevation)
if (-not $registered) {
  $r = Invoke-SchtasksCreate -ExtraArgs @("/RL", "LIMITED")
  if ($r.Code -eq 0) {
    $registered = $true
  } else {
    $errors.Add(("schtasks: {0}" -f $r.Output)) | Out-Null
  }
}

if (-not $registered) {
  $detail = ($errors -join "`n")
  throw @"
Access denied registering scheduled task '$TaskName'.

This Windows account cannot create scheduled tasks without elevation.

1) Right-click PowerShell -> Run as administrator, then:
   cd `"$repoRoot`"
   .\Register-DataGitBackupTask.ps1 -Time $Time

2) Or open Task Scheduler (taskschd.msc) as admin and create a Daily task
   that runs:
   $tr

Errors:
$detail
"@
}

Write-Host ("Scheduled task '{0}' registered for every day at {1}." -f $TaskName, $Time)
Write-Host "Runs while this Windows user is logged on (/IT)."
Write-Host "Test now: schtasks /Run /TN `"$TaskName`""
