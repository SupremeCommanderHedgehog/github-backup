#requires -Version 7

<#
.SYNOPSIS
    Register a Windows scheduled task that runs backup.ps1 on a schedule.

.PARAMETER Time
    HH:mm time-of-day to run, e.g. '03:00'. Default: 03:00.

.PARAMETER Frequency
    'Daily' or 'Weekly'. Default: Daily.

.PARAMETER TaskName
    Name of the scheduled task. Default: 'GitHub Backup'.

.NOTES
    The task is registered as Interactive, which means it only runs while the
    user is logged on. If you want it to run when logged off, modify the
    Principal to use S4U or store the user's password (requires admin and a
    password prompt).
#>

[CmdletBinding()]
param(
    [string]$Time      = '03:00',
    [ValidateSet('Daily','Weekly')][string]$Frequency = 'Daily',
    [string]$TaskName  = 'GitHub Backup'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwsh       = (Get-Command pwsh -ErrorAction Stop).Source
$scriptPath = Join-Path $PSScriptRoot 'backup.ps1'

if (-not (Test-Path $scriptPath)) {
    throw "backup.ps1 not found at: $scriptPath"
}

$action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument ('-NoProfile -NonInteractive -File "{0}"' -f $scriptPath) `
    -WorkingDirectory $PSScriptRoot

$trigger = if ($Frequency -eq 'Daily') {
    New-ScheduledTaskTrigger -Daily -At $Time
} else {
    New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $Time
}

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal `
    -UserId    ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
    -LogonType Interactive `
    -RunLevel  Limited

Register-ScheduledTask `
    -TaskName  $TaskName `
    -Action    $action `
    -Trigger   $trigger `
    -Settings  $settings `
    -Principal $principal `
    -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName':" -ForegroundColor Green
Write-Host "  Frequency: $Frequency at $Time"
Write-Host "  Runs as:   $env:USERDOMAIN\$env:USERNAME (only while logged on)"
Write-Host "  Command:   $pwsh -NoProfile -NonInteractive -File `"$scriptPath`""
Write-Host ""
Write-Host "Test it now with:" -ForegroundColor Cyan
Write-Host "    Start-ScheduledTask -TaskName '$TaskName'"
