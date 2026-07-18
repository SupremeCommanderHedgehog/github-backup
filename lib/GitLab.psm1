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

function Get-GitLabProjectDeletionSchedule {
    # Returns the pending-deletion timestamp for a project object, or $null if the
    # project is not scheduled for deletion. GitLab renamed this field from
    # 'marked_for_deletion_on' to 'marked_for_deletion_at'; check both, and probe
    # via PSObject so an absent field yields $null instead of throwing under
    # Set-StrictMode.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project)
    foreach ($name in 'marked_for_deletion_at', 'marked_for_deletion_on') {
        $prop = $Project.PSObject.Properties[$name]
        if ($prop -and $prop.Value) { return $prop.Value }
    }
    return $null
}

function Restore-GitLabProject {
    # Undo a pending (delayed) deletion. gitlab.com keeps a deleted project for
    # a retention window during which it exists but is read-only, so pushes fail
    # with HTTP 403 "You are not allowed to push code to this project". Restoring
    # makes it writable again. The restore route requires the numeric project id
    # (the URL-encoded path form returns 405).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitLabHost,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][int]$ProjectId
    )
    return Invoke-GitLabApi -GitLabHost $GitLabHost -Token $Token `
        -Path "/api/v4/projects/$ProjectId/restore" -Method POST
}

function Clear-GitLabProtectedBranches {
    # Remove every branch-protection rule on a mirror project. GitLab auto-protects
    # the default branch on a project's first push; thereafter `git push --mirror`
    # fails whenever it needs to force-update that branch (rebased history, deleted
    # refs) with "You are not allowed to force push code to a protected branch".
    # Mirrors are throwaway copies of the GitHub source, so protection serves no
    # purpose here. Returns the number of rules removed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$GitLabHost,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][int]$ProjectId
    )
    $response = Invoke-GitLabApi -GitLabHost $GitLabHost -Token $Token `
        -Path "/api/v4/projects/$ProjectId/protected_branches?per_page=100"
    # An empty list comes back as $null; filter it so the loop doesn't try to
    # dereference a null element under Set-StrictMode.
    $protected = @($response | Where-Object { $null -ne $_ })
    foreach ($b in $protected) {
        $name = [uri]::EscapeDataString($b.name)
        $null = Invoke-GitLabApi -GitLabHost $GitLabHost -Token $Token `
            -Path "/api/v4/projects/$ProjectId/protected_branches/$name" -Method DELETE
    }
    return $protected.Count
}

Export-ModuleMember -Function Get-GitLabCurrentUser, Get-GitLabProject, New-GitLabProject, Get-GitLabProjectDeletionSchedule, Restore-GitLabProject, Clear-GitLabProtectedBranches
