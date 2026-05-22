#requires -Version 7

<#
.SYNOPSIS
    One-shot: migrate every repo from the OLD GitHub account to the NEW
    GitHub account. Idempotent and safe to re-run.

.DESCRIPTION
    For each repo owned by OldGitHubUser:
      1. If the repo doesn't exist on the new account, create it (PRIVATE).
      2. Clone --mirror from old (or fetch updates if cache exists).
      3. Push --mirror to new.
      4. Repoint the local cache's origin to the new account so subsequent
         backup.ps1 runs reuse the same cache.
      5. If PreserveDefaultBranch, set the new repo's default branch to match.

    The OLD account is never modified.

    After a successful run, the OLD PAT can be deleted from Credential
    Manager (the script reminds you).

.PARAMETER ConfigPath
    Path to config.psd1.

.PARAMETER DryRun
    List what would be migrated without doing anything.

.PARAMETER ForcePromptOldPat
    Re-prompt for the OLD GitHub PAT even if one is already stored.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1'),
    [switch]$ForcePromptOldPat,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\Logging.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Credentials.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\GitHub.psm1')      -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Mirror.psm1')      -Force

$config = Import-PowerShellDataFile -Path $ConfigPath
Initialize-Log -LogPath $config.LogPath -EventLogSource $config.EventLogSource

$startedAt = Get-Date

function Get-NewSecret {
    param([string]$Prompt)
    while ($true) {
        $s = Read-Host -AsSecureString -Prompt $Prompt
        if ($s.Length -gt 0) { return $s }
        Write-Host "(empty input, try again)" -ForegroundColor Yellow
    }
}

try {
    Write-Log "=== Migration run started at $startedAt ==="
    Write-Log "Old account: $($config.OldGitHubUser)"
    Write-Log "New account: $($config.GitHubUser)"
    Write-Log "Cache path:  $($config.CachePath)"
    Write-Log "Log file:    $(Get-CurrentLogFile)"

    $null = Get-Command git -ErrorAction Stop

    # --- Ensure both PATs are available ---
    $newName = $config.GitHubCredentialName
    $oldName = $config.OldGitHubCredentialName

    if (-not (Test-BackupCredential -Name $newName)) {
        throw "New-account PAT not stored at '$newName'. Run Register-Setup.ps1 first."
    }
    if ($ForcePromptOldPat -or -not (Test-BackupCredential -Name $oldName)) {
        Write-Host ""
        Write-Host "Enter the OLD account ($($config.OldGitHubUser)) PAT." -ForegroundColor Cyan
        Write-Host "Needs Contents:Read + Metadata:Read on all repos. This PAT is only used during migration."
        $tok = Get-NewSecret "Enter OLD GitHub PAT"
        Set-BackupCredential -Name $oldName -Token $tok
        Write-Log "Stored OLD GitHub PAT at '$oldName'"
    }

    $oldToken = Get-BackupCredential -Name $oldName
    $newToken = Get-BackupCredential -Name $newName

    # --- List repos from OLD ---
    Write-Log "Listing repos on $($config.OldGitHubUser)..."
    $repos = @(Get-GitHubRepoList -Token $oldToken `
                                  -SkipForks:$config.SkipForks `
                                  -SkipArchived:$config.SkipArchived)
    Write-Log "Found $($repos.Count) repos to migrate"

    if ($DryRun) {
        Write-Host "`n--- DryRun: would migrate the following repos ---" -ForegroundColor Cyan
        $repos | ForEach-Object {
            Write-Host ("  {0}  ->  github.com/{1}/{2}  (private, default={3})" -f $_.full_name, $config.GitHubUser, $_.name, $_.default_branch)
        }
        Write-Host "--- end DryRun ---" -ForegroundColor Cyan
        exit 0
    }

    $failed    = [System.Collections.Generic.List[object]]::new()
    $created   = 0
    $reused    = 0
    $succeeded = 0

    foreach ($repo in $repos) {
        Write-Log '----'
        Write-Log "Repo: $($repo.full_name)  (private=$($repo.private), default=$($repo.default_branch))"

        try {
            # Ensure repo exists on NEW account
            $existing = Get-GitHubRepo -Token $newToken -Owner $config.GitHubUser -Name $repo.name
            if ($existing) {
                Write-Log "  exists on new account; will mirror onto it"
                $reused++
            } else {
                $desc = ''
                if ($config.PreserveDescription -and $repo.description) { $desc = [string]$repo.description }
                Write-Log "  creating github.com/$($config.GitHubUser)/$($repo.name) (private)"
                $null = New-GitHubRepo -Token $newToken `
                                       -Name $repo.name `
                                       -Description $desc `
                                       -Private ($config.NewGitHubVisibility -eq 'private')
                $created++
            }

            # Mirror clone old -> push new, repoint origin
            $cachePath = Join-Path $config.CachePath ("{0}.git" -f $repo.name)
            $result = Sync-MigrationMirror `
                -OldOwner   $config.OldGitHubUser `
                -NewOwner   $config.GitHubUser `
                -RepoName   $repo.name `
                -OldToken   $oldToken `
                -NewToken   $newToken `
                -CachePath  $cachePath `
                -HandleLfs  ($config.LfsHandling -eq 'auto')

            # Set default branch on new repo to match old, if requested
            if ($config.PreserveDefaultBranch -and $repo.default_branch) {
                if (Test-GitHubBranchExists -Token $newToken -Owner $config.GitHubUser -Name $repo.name -Branch $repo.default_branch) {
                    $null = Set-GitHubRepoDefaultBranch -Token $newToken `
                        -Owner $config.GitHubUser -Name $repo.name -DefaultBranch $repo.default_branch
                    Write-Log "  default branch set to '$($repo.default_branch)'"
                } else {
                    Write-Log -Level WARN "  default branch '$($repo.default_branch)' not present after push; skipping default-branch update"
                }
            }

            Write-Log ("  OK (lfs={0})" -f $result.Lfs)
            $succeeded++
        } catch {
            Write-Log -Level ERROR ("  FAILED: {0}" -f $_.Exception.Message)
            $failed.Add([pscustomobject]@{ Repo = $repo.full_name; Error = $_.Exception.Message })
        }
    }

    Write-Log '----'
    $elapsed = (Get-Date) - $startedAt
    Write-Log ("Migration complete in {0:hh\:mm\:ss}: {1} succeeded ({2} created, {3} reused), {4} failed, {5} total" -f `
        $elapsed, $succeeded, $created, $reused, $failed.Count, $repos.Count)

    if ($failed.Count -eq 0) {
        Write-Host ""
        Write-Host "All repos migrated successfully." -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Run .\backup.ps1 to push everything to GitLab."
        Write-Host "  2. (Optional) Remove the old-account PAT from Credential Manager:"
        Write-Host "       Import-Module .\lib\Credentials.psm1; Remove-BackupCredential -Name '$oldName'"
        exit 0
    } else {
        $details = ($failed | ForEach-Object { "- $($_.Repo): $($_.Error)" }) -join "`n"
        $summary = "Migration: $($failed.Count) of $($repos.Count) repos failed.`n$details`nLog: $(Get-CurrentLogFile)"
        Write-FailureToEventLog -Message $summary
        exit 1
    }

} catch {
    Write-Log -Level ERROR ("Fatal: {0}" -f $_.Exception.Message)
    if ($_.ScriptStackTrace) { Write-Log -Level ERROR $_.ScriptStackTrace }
    Write-FailureToEventLog -Message ("Migration fatal error: {0}`nLog: {1}" -f $_.Exception.Message, (Get-CurrentLogFile))
    exit 2
}
