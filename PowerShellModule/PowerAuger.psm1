# PowerAuger.psm1 - PowerShell module wrapper for AST-based C# predictor

using namespace System.Management.Automation.Subsystem

# Load the C# assembly
$assemblyPath = Join-Path $PSScriptRoot "bin\PowerAuger.dll"
if (Test-Path $assemblyPath) {
    try {
        Add-Type -Path $assemblyPath
        Write-Verbose "PowerAuger assembly loaded from: $assemblyPath"
    }
    catch {
        Write-Error "Failed to load PowerAuger assembly: $_"
        return
    }
}
else {
    Write-Error "PowerAuger.dll not found at: $assemblyPath"
    Write-Host "Please build the project first with: dotnet build" -ForegroundColor Yellow
    return
}

# Module-level variables
$script:PredictorInstance = $null
$script:IsEnabled = $false

function Enable-PowerAuger {
    <#
    .SYNOPSIS
    Enables the PowerAuger predictor for PSReadLine

    .DESCRIPTION
    Registers the PowerAuger predictor with the PowerShell subsystem manager
    and configures PSReadLine to use it for AI-powered command completions.

    .EXAMPLE
    Enable-PowerAuger
    #>
    [CmdletBinding()]
    param()

    if ($script:IsEnabled) {
        Write-Host "PowerAuger is already enabled" -ForegroundColor Yellow

        # Check if it's actually registered
        $registered = [System.Management.Automation.Subsystem.SubsystemManager]::GetSubsystems([System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor) |
            Where-Object { $_.Id -eq $script:PredictorInstance.Id }

        if (-not $registered) {
            Write-Host "PowerAuger was marked as enabled but not registered. Re-registering..." -ForegroundColor Yellow
            $script:IsEnabled = $false
        }
        else {
            return
        }
    }

    try {
        # Get or create the predictor instance
        if ($null -eq $script:PredictorInstance) {
            Write-Verbose "Creating new PowerAugerPredictor instance..."
            $script:PredictorInstance = [PowerAuger.PowerAugerPredictor]::Instance
            Write-Verbose "Instance created with ID: $($script:PredictorInstance.Id)"
        }

        # Check if already registered
        $existing = [System.Management.Automation.Subsystem.SubsystemManager]::GetSubsystems([System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor) |
            Where-Object { $_.Id -eq $script:PredictorInstance.Id }

        if ($existing) {
            Write-Host "PowerAuger predictor is already registered" -ForegroundColor Yellow
            $script:IsEnabled = $true
            return
        }

        # Register with subsystem manager
        Write-Verbose "Registering predictor with SubsystemManager..."
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            $script:PredictorInstance
        )

        # Configure PSReadLine
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        Set-PSReadLineOption -PredictionViewStyle ListView

        $script:IsEnabled = $true
        Write-Host "PowerAuger predictor enabled successfully!" -ForegroundColor Green
        Write-Host "Predictor ID: $($script:PredictorInstance.Id)" -ForegroundColor DarkGray
        Write-Host "Start typing commands to see AI-powered suggestions (F2 to toggle view)" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Failed to enable PowerAuger: $_"
        Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    }
}

function Disable-PowerAuger {
    <#
    .SYNOPSIS
    Disables the PowerAuger predictor

    .DESCRIPTION
    Unregisters the PowerAuger predictor from the PowerShell subsystem manager
    and cleans up resources.

    .EXAMPLE
    Disable-PowerAuger
    #>
    [CmdletBinding()]
    param()

    if (-not $script:IsEnabled) {
        Write-Host "PowerAuger is not currently enabled" -ForegroundColor Yellow
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
        Write-Host "PowerAuger predictor disabled" -ForegroundColor Yellow
    }
    catch {
        Write-Error "Failed to disable PowerAuger: $_"
    }
}

function Get-PowerAugerStatus {
    <#
    .SYNOPSIS
    Gets the status of PowerAuger predictor

    .DESCRIPTION
    Returns information about the PowerAuger predictor including
    whether it's enabled, cache statistics, and Ollama connectivity.

    .EXAMPLE
    Get-PowerAugerStatus
    #>
    [CmdletBinding()]
    param()

    $status = [PSCustomObject]@{
        Enabled = $script:IsEnabled
        PredictorId = $null
        PredictorName = $null
        PredictorDescription = $null
        AssemblyLoaded = $false
        OllamaUrl = "http://127.0.0.1:11434"
        LogDirectory = $null
        CacheDirectory = $null
        Architecture = "AST-Based with PowerShell Pool"
    }

    if ($null -ne $script:PredictorInstance) {
        $status.PredictorId = $script:PredictorInstance.Id
        $status.PredictorName = $script:PredictorInstance.Name
        $status.PredictorDescription = $script:PredictorInstance.Description
        $status.AssemblyLoaded = $true
    }

    # Get log and cache directories
    $status.LogDirectory = Join-Path $env:LOCALAPPDATA "PowerAuger\logs"
    $status.CacheDirectory = Join-Path $env:LOCALAPPDATA "PowerAuger"

    # Check if Ollama is running
    try {
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get -TimeoutSec 1 -ErrorAction Stop
        $status | Add-Member -NotePropertyName "OllamaStatus" -NotePropertyValue "Running"
        $modelNames = $response.models.name -join ", "
        $status | Add-Member -NotePropertyName "OllamaModels" -NotePropertyValue $modelNames

        # Check if our model is available
        if ($modelNames -like "*qwen2.5-0.5B-autocomplete-custom*") {
            $status | Add-Member -NotePropertyName "RequiredModel" -NotePropertyValue "Available"
        }
        else {
            $status | Add-Member -NotePropertyName "RequiredModel" -NotePropertyValue "Missing (qwen2.5-0.5B-autocomplete-custom)"
        }
    }
    catch {
        $status | Add-Member -NotePropertyName "OllamaStatus" -NotePropertyValue "Not Available"
        $status | Add-Member -NotePropertyName "OllamaError" -NotePropertyValue $_.Exception.Message
    }

    return $status
}


# Auto-enable on module import
Write-Host "PowerAuger: Module loaded. Registering predictor..." -ForegroundColor Cyan

# Use a script block to ensure proper initialization timing
$registerPredictor = {
    try {
        # Small delay to ensure assembly is fully loaded
        Start-Sleep -Milliseconds 100

        # Check if we can access the C# class
        if (-not ([System.Management.Automation.PSTypeName]'PowerAuger.PowerAugerPredictor').Type) {
            Write-Warning "PowerAuger assembly not yet loaded. Run Enable-PowerAuger manually."
            return
        }

        # Try to get the singleton instance
        $instance = $null
        try {
            $instance = [PowerAuger.PowerAugerPredictor]::Instance
        }
        catch {
            Write-Verbose "Could not get PowerAugerPredictor instance: $_"
        }

        if ($null -eq $instance) {
            Write-Host "PowerAuger: Predictor not ready. Run Enable-PowerAuger when ready to use." -ForegroundColor Yellow
            return
        }

        # Store instance and register
        $script:PredictorInstance = $instance

        # Register with subsystem manager
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            $script:PredictorInstance
        )

        # Configure PSReadLine
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
        Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction SilentlyContinue

        $script:IsEnabled = $true
        Write-Host "PowerAuger: [OK] Predictor registered successfully!" -ForegroundColor Green
        Write-Host "PowerAuger: Start typing to see AI-powered suggestions (F2 to toggle view)" -ForegroundColor Cyan
        Write-Host "PowerAuger: Predictor ID: $($script:PredictorInstance.Id)" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "PowerAuger: Auto-registration failed. Error: $_" -ForegroundColor Yellow
        Write-Host "PowerAuger: Run 'Enable-PowerAuger' manually to register the predictor." -ForegroundColor Yellow
    }
}

# Execute registration
if ($Host.Name -eq 'ConsoleHost') {
    # For console host, register immediately
    & $registerPredictor
}
else {
    # For ISE or other hosts, use event-based delayed registration
    Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -MaxTriggerCount 1 -Action $registerPredictor -ErrorAction SilentlyContinue
}

# Register cleanup on module removal
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
    Write-Host "PowerAuger: Cleaning up..." -ForegroundColor Yellow
    Disable-PowerAuger
}

# Display helpful information
Write-Host "PowerAuger: Cache location: $env:LOCALAPPDATA\PowerAuger" -ForegroundColor DarkGray
Write-Host "PowerAuger: Log location: $env:LOCALAPPDATA\PowerAuger\logs" -ForegroundColor DarkGray
Write-Host "PowerAuger: Architecture: AST-based with PowerShell pool" -ForegroundColor DarkGray
