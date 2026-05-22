Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null
$script:EventLogSource = $null

function Initialize-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$EventLogSource
    )
    if (-not (Test-Path $LogPath)) {
        New-Item -ItemType Directory -Force -Path $LogPath | Out-Null
    }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $script:LogFile = Join-Path $LogPath "backup-$stamp.log"
    $script:EventLogSource = $EventLogSource
    # touch
    Set-Content -Path $script:LogFile -Value '' -Encoding utf8
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    process {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = "$ts [$Level] $Message"
        if ($script:LogFile) {
            Add-Content -Path $script:LogFile -Value $line -Encoding utf8
        }
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            default { Write-Host $line }
        }
    }
}

function Write-FailureToEventLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$EventId = 1001
    )
    if (-not $script:EventLogSource) { return }
    try {
        [System.Diagnostics.EventLog]::WriteEntry(
            $script:EventLogSource,
            $Message,
            [System.Diagnostics.EventLogEntryType]::Error,
            $EventId
        )
    } catch {
        Write-Log -Level WARN -Message "Could not write to Event Log (run Register-Setup.ps1 as admin to register source '$($script:EventLogSource)'): $($_.Exception.Message)"
    }
}

function Get-CurrentLogFile {
    return $script:LogFile
}

Export-ModuleMember -Function Initialize-Log, Write-Log, Write-FailureToEventLog, Get-CurrentLogFile
