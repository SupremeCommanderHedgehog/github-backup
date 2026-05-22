Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GitHubHeaders {
    param([Parameter(Mandatory)][string]$Token)
    return @{
        'Authorization'        = "Bearer $Token"
        'Accept'               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'github-backup-script'
    }
}

function Get-GitHubRepoList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [bool]$SkipForks = $true,
        [bool]$SkipArchived = $false
    )

    $headers = Get-GitHubHeaders -Token $Token

    $repos = [System.Collections.Generic.List[object]]::new()
    # GitHub's /user/repos treats `type` and `affiliation` as mutually
    # exclusive — passing both returns HTTP 422. We use affiliation=owner
    # to limit results to repos the user actually owns (no collaborator /
    # org-member repos).
    $url = 'https://api.github.com/user/repos?affiliation=owner&per_page=100'

    while ($url) {
        $response = Invoke-WebRequest -Uri $url -Headers $headers -Method Get -UseBasicParsing
        $page = $response.Content | ConvertFrom-Json
        foreach ($r in $page) { $repos.Add($r) }

        # parse Link header for next page
        $linkVal = $null
        if ($response.Headers.ContainsKey('Link')) {
            $linkVal = $response.Headers['Link']
            if ($linkVal -is [array]) { $linkVal = $linkVal -join ',' }
        }
        if ($linkVal -and $linkVal -match '<([^>]+)>;\s*rel="next"') {
            $url = $matches[1]
        } else {
            $url = $null
        }
    }

    $out = $repos
    if ($SkipForks)    { $out = $out | Where-Object { -not $_.fork } }
    if ($SkipArchived) { $out = $out | Where-Object { -not $_.archived } }
    return @($out)
}

function Get-GitHubRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Name
    )
    $headers = Get-GitHubHeaders -Token $Token
    try {
        return Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Name" -Headers $headers -Method Get
    } catch {
        $code = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
        }
        if ($code -eq 404) { return $null }
        throw
    }
}

function New-GitHubRepo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = '',
        [bool]$Private = $true
    )
    $headers = Get-GitHubHeaders -Token $Token
    $body = @{
        name        = $Name
        description = $Description
        private     = $Private
        has_issues  = $true
        has_wiki    = $false
        auto_init   = $false
    } | ConvertTo-Json
    # POST /user/repos creates under the authenticated user
    return Invoke-RestMethod -Uri 'https://api.github.com/user/repos' `
        -Method Post -Headers $headers -Body $body -ContentType 'application/json'
}

function Set-GitHubRepoDefaultBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DefaultBranch
    )
    $headers = Get-GitHubHeaders -Token $Token
    $body = @{ default_branch = $DefaultBranch } | ConvertTo-Json
    return Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Name" `
        -Method Patch -Headers $headers -Body $body -ContentType 'application/json'
}

function Test-GitHubBranchExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Branch
    )
    $headers = Get-GitHubHeaders -Token $Token
    try {
        $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Name/branches/$Branch" `
            -Headers $headers -Method Get
        return $true
    } catch {
        $code = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
        }
        if ($code -eq 404) { return $false }
        throw
    }
}

Export-ModuleMember -Function Get-GitHubRepoList, Get-GitHubRepo, New-GitHubRepo, Set-GitHubRepoDefaultBranch, Test-GitHubBranchExists
