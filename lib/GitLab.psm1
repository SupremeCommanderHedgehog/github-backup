Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-GitLabApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitLabHost,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Path,           # e.g. "/api/v4/groups/foo"
        [string]$Method = 'GET',
        [object]$Body = $null
    )
    $url = "$GitLabHost$Path"
    $headers = @{ 'PRIVATE-TOKEN' = $Token }
    $params = @{
        Uri     = $url
        Method  = $Method
        Headers = $headers
    }
    if ($null -ne $Body) {
        $params['Body'] = ($Body | ConvertTo-Json -Depth 10)
        $params['ContentType'] = 'application/json'
    }
    return Invoke-RestMethod @params
}

function Get-GitLabCurrentUser {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitLabHost,
        [Parameter(Mandatory)][string]$Token
    )
    return Invoke-GitLabApi -GitLabHost $GitLabHost -Token $Token -Path '/api/v4/user'
}

function Get-GitLabProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitLabHost,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ProjectPath   # e.g. "group/repo"
    )
    $encoded = [uri]::EscapeDataString($ProjectPath)
    try {
        return Invoke-GitLabApi -GitLabHost $GitLabHost -Token $Token -Path "/api/v4/projects/$encoded"
    } catch {
        $code = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
        }
        if ($code -eq 404) { return $null }
        throw
    }
}

function New-GitLabProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitLabHost,
        [Parameter(Mandatory)][string]$Token,
        [int]$NamespaceId = 0,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [string]$Visibility = 'private',
        [string]$Description = ''
    )
    $body = @{
        name                   = $Name
        path                   = $Path
        visibility             = $Visibility
        description            = $Description
        initialize_with_readme = $false
    }
    if ($NamespaceId -gt 0) { $body.namespace_id = $NamespaceId }
    # When namespace_id is omitted, GitLab creates the project in the
    # authenticated user's personal namespace.
    return Invoke-GitLabApi -GitLabHost $GitLabHost -Token $Token -Path '/api/v4/projects' -Method POST -Body $body
}

Export-ModuleMember -Function Get-GitLabCurrentUser, Get-GitLabProject, New-GitLabProject
