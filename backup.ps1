#requires -Version 7

<#
.SYNOPSIS
    Back up all GitHub repos owned by the configured user to GitLab.

.DESCRIPTION
    For each repo:
      1. Clone --mirror to local cache, or fetch updates if cache exists.
      2. If repo uses LFS, fetch LFS blobs.
      3. Ensure a GitLab project exists under the configured group.
      4. push --mirror to GitLab (and lfs push --all if applicable).

    Designed to be idempotent and safe to run on a schedule.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib\Logging.psm1')     -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Credentials.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\GitHub.psm1')      -Force
Import-Module (Join-Path $PSScriptRoot 'lib\GitLab.psm1')      -Force
Import-Module (Join-Path $PSScriptRoot 'lib\Mirror.psm1')      -Force

$config = Import-PowerShellDataFile -Path $ConfigPath
Initialize-Log -LogPath $config.LogPath -EventLogSource $config.EventLogSource

$startedAt = Get-Date

try {
    Write-Log "=== Backup run started at $startedAt ==="
    Write-Log "GitHub user:    $($config.GitHubUser)"
    Write-Log "GitLab host:    $($config.GitLabHost)"
    Write-Log "Cache path:     $($config.CachePath)"
    Write-Log "Log file:       $(Get-CurrentLogFile)"

    # Sanity: git available?
    $null = (Get-Command git -ErrorAction Stop)

    # Resolve credentials
    $ghToken = Get-BackupCredential -Name $config.GitHubCredentialName
    $glToken = Get-BackupCredential -Name $config.GitLabCredentialName

    # Resolve GitLab user (mirrors land under their personal namespace)
    $glUser = Get-GitLabCurrentUser -GitLabHost $config.GitLabHost -Token $glToken
    $glNamespace = $glUser.username
    Write-Log "GitLab user: $glNamespace (id=$($glUser.id))"

    # List GitHub repos
    Write-Log "Listing GitHub repos..."
    $repos = @(Get-GitHubRepoList -Token $ghToken `
                                  -SkipForks:$config.SkipForks `
                                  -SkipArchived:$config.SkipArchived)
    Write-Log "Found $($repos.Count) repos to back up"

    $failed = [System.Collections.Generic.List[object]]::new()
    $succeeded = 0

    foreach ($repo in $repos) {
        Write-Log '----'
        Write-Log "Repo: $($repo.full_name)  (private=$($repo.private), default=$($repo.default_branch))"
        try {
            $projectPath = "$glNamespace/$($repo.name)"
            $existing = Get-GitLabProject -GitLabHost $config.GitLabHost -Token $glToken -ProjectPath $projectPath
            if (-not $existing) {
                Write-Log "  creating GitLab project: $projectPath"
                # NamespaceId omitted -> GitLab creates under the authenticated user
                $null = New-GitLabProject `
                    -GitLabHost   $config.GitLabHost `
                    -Token        $glToken `
                    -Name         $repo.name `
                    -Path         $repo.name `
                    -Visibility   $config.GitLabVisibility `
                    -Description  ("Mirror of github.com/{0}" -f $repo.full_name)
            }

            $cachePath = Join-Path $config.CachePath ("{0}.git" -f $repo.name)
            $result = Sync-Mirror `
                -GitHubFullName $repo.full_name `
                -GitLabPath     $projectPath `
                -GitHubToken    $ghToken `
                -GitLabToken    $glToken `
                -GitLabHost     $config.GitLabHost `
                -CachePath      $cachePath `
                -HandleLfs      ($config.LfsHandling -eq 'auto')

            Write-Log ("  OK (lfs={0})" -f $result.Lfs)
            $succeeded++
        } catch {
            Write-Log -Level ERROR ("  FAILED: {0}" -f $_.Exception.Message)
            $failed.Add([pscustomobject]@{
                Repo  = $repo.full_name
                Error = $_.Exception.Message
            })
        }
    }

    Write-Log '----'
    $elapsed = (Get-Date) - $startedAt
    Write-Log ("Run complete in {0:hh\:mm\:ss}: {1} succeeded, {2} failed, {3} total" -f $elapsed, $succeeded, $failed.Count, $repos.Count)

    if ($failed.Count -gt 0) {
        $details = ($failed | ForEach-Object { "- $($_.Repo): $($_.Error)" }) -join "`n"
        $summary = "GitHub backup: $($failed.Count) of $($repos.Count) repos failed.`n$details`nLog: $(Get-CurrentLogFile)"
        Write-FailureToEventLog -Message $summary
        exit 1
    }
    exit 0

} catch {
    Write-Log -Level ERROR ("Fatal: {0}" -f $_.Exception.Message)
    if ($_.ScriptStackTrace) { Write-Log -Level ERROR $_.ScriptStackTrace }
    Write-FailureToEventLog -Message ("GitHub backup fatal error: {0}`nLog: {1}" -f $_.Exception.Message, (Get-CurrentLogFile))
    exit 2
}
