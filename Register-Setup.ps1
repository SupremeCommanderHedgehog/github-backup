#requires -Version 7

<#
.SYNOPSIS
    One-time setup for the GitHub -> GitLab backup script.

.DESCRIPTION
    Runs as the normal user. Briefly elevates only the one step that requires
    admin (registering the Event Log source) by spawning a tiny helper
    process; UAC will prompt once.

    Prompts for and stores the GitHub + GitLab PATs in Windows Credential
    Manager (via the native advapi32 Cred* APIs in lib/Credentials.psm1 — no
    PowerShell modules are installed), verifies the GitLab PAT, and creates
    the cache + log directories.

    Idempotent: safe to re-run.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Diagnostics: transcript so failures are recoverable ---
$transcriptDir = Join-Path $env:TEMP 'github-backup-setup'
New-Item -ItemType Directory -Force -Path $transcriptDir | Out-Null
$transcriptPath = Join-Path $transcriptDir ('register-setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
try { Start-Transcript -Path $transcriptPath -ErrorAction SilentlyContinue | Out-Null } catch {}

try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file '$ConfigPath' not found. Copy config.example.psd1 to config.psd1 and edit it first (see README)."
    }
    $config = Import-PowerShellDataFile -Path $ConfigPath

    Write-Host '=== GitHub backup setup ===' -ForegroundColor Cyan
    Write-Host "Config:     $ConfigPath"
    Write-Host "Transcript: $transcriptPath"

    Import-Module (Join-Path $PSScriptRoot 'lib\Credentials.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'lib\GitLab.psm1')      -Force

    # Read-only check via the registry — avoids EventLog.SourceExists's
    # tendency to throw from non-admin context because it can't enumerate
    # the Security event log.
    function Test-EventLogSource {
        param([string]$Name)
        return (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\$Name")
    }

    # --- Register Event Log source (brief elevation only if needed) ---
    $src = $config.EventLogSource
    if (Test-EventLogSource -Name $src) {
        Write-Host "`nEvent Log source already registered: $src"
    } else {
        Write-Host "`nRegistering Event Log source: $src"
        Write-Host "  (a UAC prompt will appear; the helper closes immediately on success)"

        # Use Windows PowerShell 5.1 (powershell.exe) for the elevated
        # helper, not pwsh 7. WinPS is a system component that launches
        # cleanly under UAC; pwsh occasionally hits STATUS_DLL_INIT_FAILED
        # (0xc0000142) when elevated from a user-profile working directory.
        # WorkingDirectory is also pinned to C:\Windows for the same reason.
        $winPS = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $elevCmd = "try { [System.Diagnostics.EventLog]::CreateEventSource('$src','Application'); exit 0 } catch { Write-Host `$_; Start-Sleep 5; exit 1 }"
        $proc = Start-Process `
            -FilePath         $winPS `
            -ArgumentList     @('-NoProfile','-NonInteractive','-Command', $elevCmd) `
            -WorkingDirectory $env:SystemRoot `
            -Verb             RunAs `
            -Wait `
            -PassThru
        if ($proc.ExitCode -ne 0 -or -not (Test-EventLogSource -Name $src)) {
            throw "Failed to register Event Log source '$src'. Open an elevated PowerShell and run: [System.Diagnostics.EventLog]::CreateEventSource('$src','Application')"
        }
        Write-Host "Event Log source registered."
    }

    # --- PAT helpers ---
    function Get-NewSecret {
        param([string]$Prompt)
        while ($true) {
            $s = Read-Host -AsSecureString -Prompt $Prompt
            if ($s.Length -gt 0) { return $s }
            Write-Host "(empty input, try again)" -ForegroundColor Yellow
        }
    }

    # --- GitHub PAT (NEW account) ---
    Write-Host ""
    $ghName = $config.GitHubCredentialName
    $ghPrompt = "Enter GitHub PAT for '$($config.GitHubUser)' (Contents+Metadata read; Administration:write only during migration)"
    if (Test-BackupCredential -Name $ghName) {
        $ans = Read-Host "GitHub PAT for '$($config.GitHubUser)' already stored at '$ghName'. Overwrite? (y/N)"
        if ($ans -match '^[Yy]') {
            $tok = Get-NewSecret $ghPrompt
            Set-BackupCredential -Name $ghName -Token $tok
            Write-Host "GitHub PAT updated."
        } else {
            Write-Host "Keeping existing GitHub PAT."
        }
    } else {
        $tok = Get-NewSecret $ghPrompt
        Set-BackupCredential -Name $ghName -Token $tok
        Write-Host "GitHub PAT stored at '$ghName'."
    }

    # --- GitLab PAT ---
    Write-Host ""
    $glName = $config.GitLabCredentialName
    if (Test-BackupCredential -Name $glName) {
        $ans = Read-Host "GitLab PAT already stored at '$glName'. Overwrite? (y/N)"
        if ($ans -match '^[Yy]') {
            $tok = Get-NewSecret "Enter GitLab PAT (scope: api)"
            Set-BackupCredential -Name $glName -Token $tok
            Write-Host "GitLab PAT updated."
        } else {
            Write-Host "Keeping existing GitLab PAT."
        }
    } else {
        $tok = Get-NewSecret "Enter GitLab PAT (scope: api)"
        Set-BackupCredential -Name $glName -Token $tok
        Write-Host "GitLab PAT stored at '$glName'."
    }

    # --- Verify GitLab auth ---
    Write-Host ""
    $glToken = Get-BackupCredential -Name $glName
    $glUser  = Get-GitLabCurrentUser -GitLabHost $config.GitLabHost -Token $glToken
    Write-Host "GitLab auth OK. Mirrors will land under: $($config.GitLabHost)/$($glUser.username)/<repo>"

    # --- Verify cache + log dirs ---
    foreach ($p in @($config.CachePath, $config.LogPath)) {
        if (-not (Test-Path $p)) {
            Write-Host "Creating directory: $p"
            New-Item -ItemType Directory -Force -Path $p | Out-Null
        }
    }

    Write-Host ""
    Write-Host "Setup complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "Next:" -ForegroundColor Cyan
    Write-Host "  pwsh -File `"$(Join-Path $PSScriptRoot 'Migrate-ToNewAccount.ps1')`" -WhatIf"
    Write-Host "  pwsh -File `"$(Join-Path $PSScriptRoot 'Migrate-ToNewAccount.ps1')`""
    Write-Host "  pwsh -File `"$(Join-Path $PSScriptRoot 'backup.ps1')`""

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed }
    Write-Host ""
    Write-Host "Transcript: $transcriptPath" -ForegroundColor Yellow
    exit 1
} finally {
    try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
}
