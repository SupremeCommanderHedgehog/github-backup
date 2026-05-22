Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AuthHeaderConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UrlPrefix,
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$Token
    )
    $pair = "${Username}:${Token}"
    $b64  = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    # Returned form is suitable for `git -c <returned>`
    return "http.$UrlPrefix.extraheader=Authorization: Basic $b64"
}

function Test-RepoUsesLfs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$BarePath)

    $oldErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $content = & git --git-dir=$BarePath show 'HEAD:.gitattributes' 2>$null
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $oldErr

    if ($exit -ne 0) { return $false }
    if (-not $content) { return $false }
    return ([string]($content -join "`n") -match 'filter\s*=\s*lfs')
}

function Invoke-Git {
    # Run git with `-c <auth>` injected up front. Throws on nonzero exit.
    [CmdletBinding()]
    param(
        [string]$AuthConfig,                  # may be empty
        [Parameter(Mandatory)][string[]]$GitArgs,
        [string]$ErrorContext = 'git'
    )
    $argv = @()
    if ($AuthConfig) { $argv += @('-c', $AuthConfig) }
    $argv += $GitArgs

    & git @argv
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorContext failed (exit $LASTEXITCODE): git $($GitArgs -join ' ')"
    }
}

function Sync-Mirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitHubFullName,    # owner/repo
        [Parameter(Mandatory)][string]$GitLabPath,        # group/repo
        [Parameter(Mandatory)][string]$GitHubToken,
        [Parameter(Mandatory)][string]$GitLabToken,
        [Parameter(Mandatory)][string]$GitLabHost,
        [Parameter(Mandatory)][string]$CachePath,
        [bool]$HandleLfs = $true
    )

    $ghUrl  = "https://github.com/$GitHubFullName.git"
    $glUrl  = "$GitLabHost/$GitLabPath.git"
    $ghAuth = Get-AuthHeaderConfig -UrlPrefix 'https://github.com/' -Username 'x-access-token' -Token $GitHubToken
    $glAuth = Get-AuthHeaderConfig -UrlPrefix "$GitLabHost/"        -Username 'oauth2'         -Token $GitLabToken

    if (Test-Path $CachePath) {
        Invoke-Git -AuthConfig $ghAuth -ErrorContext "fetch $GitHubFullName" `
            -GitArgs @('--git-dir', $CachePath, 'remote', 'update', '--prune')
    } else {
        $parent = Split-Path -Parent $CachePath
        if (-not (Test-Path $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Invoke-Git -AuthConfig $ghAuth -ErrorContext "clone $GitHubFullName" `
            -GitArgs @('clone', '--mirror', $ghUrl, $CachePath)
    }

    $usesLfs = $HandleLfs -and (Test-RepoUsesLfs -BarePath $CachePath)
    if ($usesLfs) {
        Invoke-Git -AuthConfig $ghAuth -ErrorContext "lfs fetch $GitHubFullName" `
            -GitArgs @('--git-dir', $CachePath, 'lfs', 'fetch', '--all')
    }

    Invoke-Git -AuthConfig $glAuth -ErrorContext "push $GitHubFullName" `
        -GitArgs @('--git-dir', $CachePath, 'push', '--mirror', $glUrl)

    if ($usesLfs) {
        # git lfs push --all needs a remote name, not a URL — add a temp remote
        $oldErr = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & git --git-dir=$CachePath remote remove gitlab 2>$null | Out-Null
        $ErrorActionPreference = $oldErr

        Invoke-Git -ErrorContext "remote add gitlab $GitHubFullName" `
            -GitArgs @('--git-dir', $CachePath, 'remote', 'add', 'gitlab', $glUrl)
        try {
            Invoke-Git -AuthConfig $glAuth -ErrorContext "lfs push $GitHubFullName" `
                -GitArgs @('--git-dir', $CachePath, 'lfs', 'push', '--all', 'gitlab')
        } finally {
            $ErrorActionPreference = 'Continue'
            & git --git-dir=$CachePath remote remove gitlab 2>$null | Out-Null
            $ErrorActionPreference = $oldErr
        }
    }

    return [pscustomobject]@{ Lfs = $usesLfs }
}

function Sync-MigrationMirror {
    # Clone/fetch from OLD GitHub, push --mirror to NEW GitHub, then repoint
    # origin to the new account so the ongoing backup tool can reuse the cache.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OldOwner,
        [Parameter(Mandatory)][string]$NewOwner,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$OldToken,
        [Parameter(Mandatory)][string]$NewToken,
        [Parameter(Mandatory)][string]$CachePath,
        [bool]$HandleLfs = $true
    )

    $oldUrl = "https://github.com/$OldOwner/$RepoName.git"
    $newUrl = "https://github.com/$NewOwner/$RepoName.git"
    $auth   = Get-AuthHeaderConfig -UrlPrefix 'https://github.com/' -Username 'x-access-token' -Token $OldToken
    $authN  = Get-AuthHeaderConfig -UrlPrefix 'https://github.com/' -Username 'x-access-token' -Token $NewToken

    # --- 1. Cache: clone --mirror from OLD, or update if exists ---
    if (-not (Test-Path $CachePath)) {
        $parent = Split-Path -Parent $CachePath
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Invoke-Git -AuthConfig $auth -ErrorContext "clone $OldOwner/$RepoName" `
            -GitArgs @('clone', '--mirror', $oldUrl, $CachePath)
    } else {
        # Point origin at OLD (defensive: a previous run may have pointed it elsewhere)
        $oldErr = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & git --git-dir=$CachePath remote set-url origin $oldUrl *>$null
        $ErrorActionPreference = $oldErr

        Invoke-Git -AuthConfig $auth -ErrorContext "fetch $OldOwner/$RepoName" `
            -GitArgs @('--git-dir', $CachePath, 'remote', 'update', '--prune')
    }

    $usesLfs = $HandleLfs -and (Test-RepoUsesLfs -BarePath $CachePath)
    if ($usesLfs) {
        Invoke-Git -AuthConfig $auth -ErrorContext "lfs fetch $OldOwner/$RepoName" `
            -GitArgs @('--git-dir', $CachePath, 'lfs', 'fetch', '--all')
    }

    # --- 2. Repoint origin to NEW for the push (and for ongoing backup later) ---
    Invoke-Git -ErrorContext "remote set-url $RepoName" `
        -GitArgs @('--git-dir', $CachePath, 'remote', 'set-url', 'origin', $newUrl)

    Invoke-Git -AuthConfig $authN -ErrorContext "push $NewOwner/$RepoName" `
        -GitArgs @('--git-dir', $CachePath, 'push', '--mirror', 'origin')

    if ($usesLfs) {
        Invoke-Git -AuthConfig $authN -ErrorContext "lfs push $NewOwner/$RepoName" `
            -GitArgs @('--git-dir', $CachePath, 'lfs', 'push', '--all', 'origin')
    }

    return [pscustomobject]@{ Lfs = $usesLfs }
}

Export-ModuleMember -Function Sync-Mirror, Sync-MigrationMirror, Test-RepoUsesLfs
