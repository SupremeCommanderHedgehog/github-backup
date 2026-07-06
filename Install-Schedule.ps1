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

# Resolve an absolute pwsh path for the task action that stays valid after
# PowerShell auto-updates. Get-Command returns the on-PATH interpreter, which
# is guaranteed to exist. For a Microsoft Store install that path is a
# version-pinned package path
# (…\WindowsApps\Microsoft.PowerShell..._<ver>_…\pwsh.exe) that the next update
# deletes, which would fail the task with ERROR_FILE_NOT_FOUND (0x80070002).
# In that one case swap in the per-user app-execution-alias stub — a stable
# absolute path that always resolves to the current Store build and is verified
# launchable from Task Scheduler under an Interactive principal. If the stub is
# unavailable (aliases disabled, unusual packaging), keep the resolved path so
# the task is still registered and runs until the next update. MSI/zip/portable
# installs already report a stable path and are used unchanged.
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
if ($pwsh -like '*\WindowsApps\Microsoft.PowerShell*' -and $env:LOCALAPPDATA) {
    $aliasStub = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'
    if (Test-Path -LiteralPath $aliasStub) { $pwsh = $aliasStub }
}

$scriptPath = Join-Path $PSScriptRoot 'backup.ps1'
$pwshArgs   = '-NoProfile -NonInteractive -File "{0}"' -f $scriptPath

if (-not (Test-Path $scriptPath)) {
    throw "backup.ps1 not found at: $scriptPath"
}

$action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument $pwshArgs `
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
Write-Host "  Command:   `"$pwsh`" $pwshArgs"
Write-Host ""
Write-Host "Test it now by running the backup directly (does not touch the scheduled task):" -ForegroundColor Cyan
Write-Host "    `"$pwsh`" $pwshArgs"
