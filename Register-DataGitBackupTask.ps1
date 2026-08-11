<#
.SYNOPSIS
  Registers a Windows Scheduled Task to run Backup-DataGit.ps1 daily.

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

$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$backupScript`""
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

Write-Host ("Scheduled task '{0}' registered for every day at {1}." -f $TaskName, $Time)
