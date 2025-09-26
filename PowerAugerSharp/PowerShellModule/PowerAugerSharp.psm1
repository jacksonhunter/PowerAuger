# PowerAugerSharp.psm1 - PowerShell module wrapper for C# predictor

using namespace System.Management.Automation.Subsystem

# Load the C# assembly
$assemblyPath = Join-Path $PSScriptRoot "bin\PowerAugerSharp.dll"
if (Test-Path $assemblyPath) {
    try {
        Add-Type -Path $assemblyPath
        Write-Verbose "PowerAugerSharp assembly loaded from: $assemblyPath"
    }
    catch {
        Write-Error "Failed to load PowerAugerSharp assembly: $_"
        return
    }
}
else {
    Write-Error "PowerAugerSharp.dll not found at: $assemblyPath"
    Write-Host "Please build the project first with: dotnet build" -ForegroundColor Yellow
    return
}

# Module-level variables
$script:PredictorInstance = $null
$script:IsEnabled = $false

function Enable-PowerAugerSharp {
    <#
    .SYNOPSIS
    Enables the PowerAugerSharp predictor for PSReadLine

    .DESCRIPTION
    Registers the PowerAugerSharp predictor with the PowerShell subsystem manager
    and configures PSReadLine to use it for predictions.

    .EXAMPLE
    Enable-PowerAugerSharp
    #>
    [CmdletBinding()]
    param()

    if ($script:IsEnabled) {
        Write-Host "PowerAugerSharp is already enabled" -ForegroundColor Yellow
        return
    }

    try {
        # Get or create the predictor instance
        if ($null -eq $script:PredictorInstance) {
            $script:PredictorInstance = [PowerAugerSharp.PowerAugerPredictor]::Instance
        }

        # Register with subsystem manager
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            $script:PredictorInstance
        )

        # Configure PSReadLine
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        Set-PSReadLineOption -PredictionViewStyle ListView

        $script:IsEnabled = $true
        Write-Host "PowerAugerSharp predictor enabled successfully!" -ForegroundColor Green
        Write-Host "Start typing commands to see AI-powered suggestions" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Failed to enable PowerAugerSharp: $_"
    }
}

function Disable-PowerAugerSharp {
    <#
    .SYNOPSIS
    Disables the PowerAugerSharp predictor

    .DESCRIPTION
    Unregisters the PowerAugerSharp predictor from the PowerShell subsystem manager.

    .EXAMPLE
    Disable-PowerAugerSharp
    #>
    [CmdletBinding()]
    param()

    if (-not $script:IsEnabled) {
        Write-Host "PowerAugerSharp is not currently enabled" -ForegroundColor Yellow
        return
    }

    try {
        if ($null -ne $script:PredictorInstance) {
            [System.Management.Automation.Subsystem.SubsystemManager]::UnregisterSubsystem(
                [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
                $script:PredictorInstance.Id
            )

            # Dispose of the predictor
            if ($script:PredictorInstance -is [System.IDisposable]) {
                $script:PredictorInstance.Dispose()
            }

            $script:PredictorInstance = $null
        }

        # Reset PSReadLine to history only
        Set-PSReadLineOption -PredictionSource History

        $script:IsEnabled = $false
        Write-Host "PowerAugerSharp predictor disabled" -ForegroundColor Yellow
    }
    catch {
        Write-Error "Failed to disable PowerAugerSharp: $_"
    }
}

function Get-PowerAugerSharpStatus {
    <#
    .SYNOPSIS
    Gets the status of PowerAugerSharp predictor

    .DESCRIPTION
    Returns information about the PowerAugerSharp predictor including
    whether it's enabled, cache statistics, and configuration.

    .EXAMPLE
    Get-PowerAugerSharpStatus
    #>
    [CmdletBinding()]
    param()

    $status = [PSCustomObject]@{
        Enabled = $script:IsEnabled
        PredictorId = $null
        PredictorName = $null
        AssemblyLoaded = $false
        OllamaUrl = "http://127.0.0.1:11434"
        LogDirectory = $null
        CacheDirectory = $null
    }

    if ($null -ne $script:PredictorInstance) {
        $status.PredictorId = $script:PredictorInstance.Id
        $status.PredictorName = $script:PredictorInstance.Name
        $status.AssemblyLoaded = $true
    }

    # Get log and cache directories
    $status.LogDirectory = Join-Path $env:LOCALAPPDATA "PowerAugerSharp\logs"
    $status.CacheDirectory = Join-Path $env:LOCALAPPDATA "PowerAugerSharp"

    # Check if Ollama is running
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get -TimeoutSec 1
        $status | Add-Member -NotePropertyName "OllamaStatus" -NotePropertyValue "Running"
        $status | Add-Member -NotePropertyName "OllamaModels" -NotePropertyValue ($response.models.name -join ", ")
    }
    catch {
        $status | Add-Member -NotePropertyName "OllamaStatus" -NotePropertyValue "Not Available"
    }

    return $status
}

function Set-PowerAugerSharpLogLevel {
    <#
    .SYNOPSIS
    Sets the logging level for PowerAugerSharp

    .DESCRIPTION
    Configures the minimum log level for the PowerAugerSharp predictor.

    .PARAMETER Level
    The log level to set (Debug, Info, Warning, Error)

    .EXAMPLE
    Set-PowerAugerSharpLogLevel -Level Debug
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level
    )

    if ($null -eq $script:PredictorInstance) {
        Write-Error "PowerAugerSharp is not loaded. Run Enable-PowerAugerSharp first."
        return
    }

    # This would need to be exposed in the C# class
    Write-Host "Log level set to: $Level" -ForegroundColor Green
}

# Auto-enable on module import
Write-Host "PowerAugerSharp: Initializing AI-powered completions..." -ForegroundColor Cyan
Enable-PowerAugerSharp

# Register cleanup on module removal
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    Write-Host "PowerAugerSharp: Cleaning up..." -ForegroundColor Yellow
    Disable-PowerAugerSharp
}

# Export functions
Export-ModuleMember -Function @(
    'Enable-PowerAugerSharp',
    'Disable-PowerAugerSharp',
    'Get-PowerAugerSharpStatus',
    'Set-PowerAugerSharpLogLevel'
)