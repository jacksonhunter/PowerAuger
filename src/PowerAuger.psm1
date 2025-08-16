# PowerAuger.psm1 - FIXED VERSION
# ========================================================================================================
# PRODUCTION-READY OLLAMA POWERSHELL PREDICTOR - FIXED RETURN VALUES
# JSON-first, Continue-compatible, cross-platform intelligent command prediction
# ========================================================================================================

#Requires -Version 7.0

# --------------------------------------------------------------------------------------------------------
# GLOBAL CONFIGURATION AND STATE
# --------------------------------------------------------------------------------------------------------

$global:OllamaConfig = @{
    # Server Configuration
    Server      = @{
        LinuxHost     = $env:POWERAUGER_LINUX_HOST -or "192.168.50.194" # Default can be overridden by env var
        LinuxPort     = 11434
        LocalPort     = 11434
        SSHUser       = $env:POWERAUGER_SSH_USER -or $null
        SSHKey        = $env:POWERAUGER_SSH_KEY -or $null
        TunnelProcess = $null
        IsConnected   = $false
        ApiUrl        = "http://localhost:11434"
    }
    
    # Model Strategy - Matching your actual model parameters
    Models      = @{
        FastCompletion = @{
            Name        = "powershell-fast:latest"
            UseCase     = "Quick completions <10 chars"
            KeepAlive   = "30s"
            MaxTokens   = 80
            Temperature = 0.1    # Matches your Modelfile
            TopP        = 0.8    # Matches your Modelfile
            Timeout     = 30000  # 30 seconds - your models need time
        }
        ContextAware   = @{
            Name        = "powershell-context:latest"
            UseCase     = "Complex completions with environment"
            KeepAlive   = "5m"
            MaxTokens   = 150
            Temperature = 0.4    # Matches your Modelfile
            TopP        = 0.85   # Matches your Modelfile
            Timeout     = 30000  # 30 seconds - your models need time
        }
    }
    
    # Performance Settings
    Performance = @{
        CacheTimeout            = 300
        CacheSize               = 200
        MaxHistoryLines         = 1000
        RecentTargetsCount      = 30
        SessionCleanupMinutes   = 30
        EnableDebug             = $false
        EnablePredictionLogging = $false # Default to off, can be enabled in config.json
    }
}

# Global state containers
$global:PredictionCache = @{}
$global:ChatSessions = @{}
$global:PredictionLog = [System.Collections.Generic.List[object]]::new()
$global:RecentTargets = @()
$global:CommandHistory = @()
$global:PerformanceMetrics = @{
    RequestCount       = 0
    CacheHits          = 0
    AverageLatency     = 0      # API latency
    SuccessRate        = 1.0
    ProviderTimings    = @{}    # Per-provider average latency
    TotalContextTime   = 0      # Total context gathering average latency
    AcceptanceTracking = @{} # Stores @{ Accepted = 0; Offered = 0 } per model/source
}

# --------------------------------------------------------------------------------------------------------
# DATA PERSISTENCE & CONFIGURATION
# --------------------------------------------------------------------------------------------------------
$global:PowerAugerDataPath = Join-Path -Path $env:USERPROFILE -ChildPath ".PowerAuger"
$global:PowerAugerConfigFile = Join-Path $global:PowerAugerDataPath "config.json"
$global:PowerAugerHistoryFile = Join-Path $global:PowerAugerDataPath "history.json"
$global:PowerAugerCacheFile = Join-Path $global:PowerAugerDataPath "cache.json"
$global:PowerAugerTargetsFile = Join-Path $global:PowerAugerDataPath "recent_targets.json"
$global:PowerAugerLogFile = Join-Path $global:PowerAugerDataPath "prediction_log.json"

function Merge-Hashtables {
    param($base, $overlay)
    $result = $base.Clone()
    foreach ($key in $overlay.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $overlay[$key] -is [hashtable]) {
            $result[$key] = Merge-Hashtables -base $result[$key] -overlay $overlay[$key]
        }
        else {
            $result[$key] = $overlay[$key]
        }
    }
    return $result
}

function Load-PowerAugerConfiguration {
    if (Test-Path $global:PowerAugerConfigFile) {
        try {
            $fileContent = Get-Content -Path $global:PowerAugerConfigFile -Raw
            if (-not [string]::IsNullOrWhiteSpace($fileContent)) {
                $loadedConfig = $fileContent | ConvertFrom-Json -AsHashtable
                $global:OllamaConfig = Merge-Hashtables -base $global:OllamaConfig -overlay $loadedConfig
            }
        }
        catch {
            Write-Warning "Failed to load or parse configuration from $($global:PowerAugerConfigFile). Using defaults. Error: $($_.Exception.Message)"
        }
    }
}

function Load-PowerAugerState {
    if ($global:OllamaConfig.Performance.EnableDebug) {
        Write-Host "🔄 Loading PowerAuger state from $($global:PowerAugerDataPath)..." -ForegroundColor Cyan
    }

    if (Test-Path $global:PowerAugerHistoryFile) {
        try { $global:CommandHistory = Get-Content -Path $global:PowerAugerHistoryFile -Raw | ConvertFrom-Json } catch {
            if ($global:OllamaConfig.Performance.EnableDebug) { Write-Warning "Could not load or parse history.json: $($_.Exception.Message)" }
        }
    }
    if (Test-Path $global:PowerAugerCacheFile) {
        try { $global:PredictionCache = Get-Content -Path $global:PowerAugerCacheFile -Raw | ConvertFrom-Json -AsHashtable } catch {
            if ($global:OllamaConfig.Performance.EnableDebug) { Write-Warning "Could not load or parse cache.json: $($_.Exception.Message)" }
        }
    }
    if (Test-Path $global:PowerAugerTargetsFile) {
        try { $global:RecentTargets = Get-Content -Path $global:PowerAugerTargetsFile -Raw | ConvertFrom-Json } catch {
            if ($global:OllamaConfig.Performance.EnableDebug) { Write-Warning "Could not load or parse recent_targets.json: $($_.Exception.Message)" }
        }
    }
    if (Test-Path $global:PowerAugerLogFile) {
        try {
            $logData = Get-Content -Path $global:PowerAugerLogFile -Raw | ConvertFrom-Json
            if ($logData) { $global:PredictionLog = [System.Collections.Generic.List[object]]::new($logData) }
        }
        catch {
            if ($global:OllamaConfig.Performance.EnableDebug) { Write-Warning "Could not load or parse prediction_log.json: $($_.Exception.Message)" }
        }
    }
}

function Save-PowerAugerState {
    [CmdletBinding()]
    param()

    if ($global:OllamaConfig.Performance.EnableDebug) {
        Write-Host "💾 Saving PowerAuger state to $($global:PowerAugerDataPath)..." -ForegroundColor Cyan
    }

    if (-not (Test-Path $global:PowerAugerDataPath)) {
        New-Item -Path $global:PowerAugerDataPath -ItemType Directory -Force | Out-Null
    }

    # Save Configuration
    Save-PowerAugerConfiguration

    # Save other state files
    $global:CommandHistory | ConvertTo-Json -Depth 5 | Set-Content -Path $global:PowerAugerHistoryFile -Encoding UTF8 -ErrorAction SilentlyContinue
    $global:PredictionCache | ConvertTo-Json -Depth 10 | Set-Content -Path $global:PowerAugerCacheFile -Encoding UTF8 -ErrorAction SilentlyContinue
    $global:RecentTargets | ConvertTo-Json -Depth 5 | Set-Content -Path $global:PowerAugerTargetsFile -Encoding UTF8 -ErrorAction SilentlyContinue
    $global:PredictionLog | ConvertTo-Json -Depth 5 | Set-Content -Path $global:PowerAugerLogFile -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Save-PowerAugerConfiguration {
    try {
        if (-not (Test-Path $global:PowerAugerDataPath)) {
            New-Item -Path $global:PowerAugerDataPath -ItemType Directory -Force | Out-Null
        }
        $configToSave = $global:OllamaConfig.Clone()
        $configToSave.Server.Remove('TunnelProcess')
        $configToSave | ConvertTo-Json -Depth 10 | Set-Content -Path $global:PowerAugerConfigFile -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Failed to save configuration: $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------------------------------------
# SSH TUNNEL MANAGEMENT
# --------------------------------------------------------------------------------------------------------

function Find-SSHTunnelProcess {
    [CmdletBinding()]
    param(
        [int]$LocalPort,
        [string]$RemoteHost
    )
    
    try {
        # Method 1: Use .NET TcpConnectionInformation to find listening processes
        $tcpConnections = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        $localEndpoint = $tcpConnections | Where-Object { $_.Port -eq $LocalPort -and $_.Address -eq [System.Net.IPAddress]::Loopback }
        
        if ($localEndpoint) {
            # Method 2: Use netstat to find the PID more reliably
            $netstatCmd = "netstat -ano"
            $netstatOutput = & cmd /c $netstatCmd 2>$null
            
            foreach ($line in $netstatOutput) {
                if ($line -match "TCP\s+127\.0\.0\.1:$LocalPort\s+.*\s+LISTENING\s+(\d+)") {
                    $psid = $matches[1]
                    
                    # Verify this is actually an SSH process
                    try {
                        $process = Get-Process -Id $psid -ErrorAction SilentlyContinue
                        if ($process -and ($process.ProcessName -eq "ssh" -or $process.ProcessName -eq "ssh.exe")) {
                            if ($global:OllamaConfig.Performance.EnableDebug) {
                                Write-Host "🔍 Found SSH tunnel process: PID $psid" -ForegroundColor Cyan
                            }
                            return [int]$psid
                        }
                    }
                    catch {
                        # Process might have exited, continue
                    }
                }
            }
        }
        
        # Method 3: Fallback - search all SSH processes and check their network connections
        $sshProcesses = Get-Process -Name "ssh*" -ErrorAction SilentlyContinue
        foreach ($proc in $sshProcesses) {
            try {
                # Use WMI to get network connections for this process (more reliable than CommandLine)
                $connections = Get-WmiObject -Class Win32_Process -Filter "ProcessId = $($proc.Id)" -ErrorAction SilentlyContinue
                if ($connections) {
                    # Check if this process has our port open
                    $portCheck = netstat -ano | Select-String ":$LocalPort.*LISTENING.*$($proc.Id)"
                    if ($portCheck) {
                        if ($global:OllamaConfig.Performance.EnableDebug) {
                            Write-Host "🔍 Found SSH tunnel via process search: PID $($proc.Id)" -ForegroundColor Cyan
                        }
                        return $proc.Id
                    }
                }
            }
            catch {
                # Access denied or other error, continue
            }
        }
        
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Warning "Could not find SSH tunnel process for port $LocalPort"
        }
        return $null
    }
    catch {
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Warning "Error finding SSH tunnel process: $($_.Exception.Message)"
        }
        return $null
    }
}

function Start-OllamaTunnel {
    [CmdletBinding()]
    param([switch]$Force)
    
    if ($global:OllamaConfig.Server.IsConnected -and -not $Force) {
        return $true
    }
    
    Stop-OllamaTunnel -Silent
    
    try {
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Host "🔗 Starting SSH tunnel to $($global:OllamaConfig.Server.LinuxHost)" -ForegroundColor Cyan
        }
        
        $sshArgs = @(
            "-f", "-N", "-T", "-C"
            "-o", "ExitOnForwardFailure=yes"
            "-o", "ServerAliveInterval=30"
            "-o", "ServerAliveCountMax=3"
            "-L", "$($global:OllamaConfig.Server.LocalPort):localhost:$($global:OllamaConfig.Server.LinuxPort)"
        )
        
        if (Test-Path $global:OllamaConfig.Server.SSHKey) {
            $sshArgs += @("-i", $global:OllamaConfig.Server.SSHKey)
        }
        
        $sshArgs += "$($global:OllamaConfig.Server.SSHUser)@$($global:OllamaConfig.Server.LinuxHost)"
        
        # Start SSH with -f flag and track the resulting process
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "ssh"
        $processInfo.Arguments = $sshArgs -join " "
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.RedirectStandardError = $true
        
        $process = [System.Diagnostics.Process]::Start($processInfo)
        $process.WaitForExit() # With -f, this should exit immediately after forking
        Start-Sleep -Seconds 3 # Give the background process time to establish the tunnel
        
        # Find the actual SSH tunnel process using more reliable method
        $tunnelPid = Find-SSHTunnelProcess -LocalPort $global:OllamaConfig.Server.LocalPort -RemoteHost $global:OllamaConfig.Server.LinuxHost
        
        # Test connection
        $testResponse = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/version" -Method Get -TimeoutSec 5 -ErrorAction Stop
        
        if ($testResponse) {
            # Store the tunnel process info for later cleanup
            $global:OllamaConfig.Server.TunnelProcessId = $tunnelPid
            $global:OllamaConfig.Server.TunnelProcess = $null # We don't have a direct handle
            $global:OllamaConfig.Server.IsConnected = $true
            
            if ($global:OllamaConfig.Performance.EnableDebug) {
                Write-Host "✅ SSH tunnel established in background (PID: $tunnelPid)" -ForegroundColor Green
            }
            return $true
        }
    }
    catch {
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Host "❌ SSH tunnel failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        return $false
    }
}

function Stop-OllamaTunnel {
    [CmdletBinding()]
    param([switch]$Silent)
    
    $tunnelStopped = $false
    
    # Method 1: Use stored PID if available
    if ($global:OllamaConfig.Server.TunnelProcessId) {
        try {
            $process = Get-Process -Id $global:OllamaConfig.Server.TunnelProcessId -ErrorAction SilentlyContinue
            if ($process) {
                $process.Kill()
                $tunnelStopped = $true
                if (-not $Silent -and $global:OllamaConfig.Performance.EnableDebug) {
                    Write-Host "🔗 Killed SSH tunnel process (PID: $($global:OllamaConfig.Server.TunnelProcessId))" -ForegroundColor Yellow
                }
            }
        }
        catch {
            if (-not $Silent -and $global:OllamaConfig.Performance.EnableDebug) {
                Write-Warning "Could not kill stored tunnel process: $($_.Exception.Message)"
            }
        }
        $global:OllamaConfig.Server.TunnelProcessId = $null
    }
    
    # Method 2: Fallback to finding the process (legacy support)
    if (-not $tunnelStopped) {
        $foundPid = Find-SSHTunnelProcess -LocalPort $global:OllamaConfig.Server.LocalPort -RemoteHost $global:OllamaConfig.Server.LinuxHost
        if ($foundPid) {
            try {
                $process = Get-Process -Id $foundPid -ErrorAction SilentlyContinue
                if ($process) {
                    $process.Kill()
                    $tunnelStopped = $true
                    if (-not $Silent -and $global:OllamaConfig.Performance.EnableDebug) {
                        Write-Host "🔗 Killed discovered SSH tunnel process (PID: $foundPid)" -ForegroundColor Yellow
                    }
                }
            }
            catch {
                if (-not $Silent -and $global:OllamaConfig.Performance.EnableDebug) {
                    Write-Warning "Could not kill discovered tunnel process: $($_.Exception.Message)"
                }
            }
        }
    }
    
    # Legacy cleanup
    if ($global:OllamaConfig.Server.TunnelProcess -and -not $global:OllamaConfig.Server.TunnelProcess.HasExited) {
        try {
            $global:OllamaConfig.Server.TunnelProcess.Kill()
            $tunnelStopped = $true
        }
        catch { }
    }
    
    # Clean up stored references
    $global:OllamaConfig.Server.TunnelProcess = $null
    $global:OllamaConfig.Server.TunnelProcessId = $null
    $global:OllamaConfig.Server.IsConnected = $false
    
    if (-not $Silent -and $global:OllamaConfig.Performance.EnableDebug -and $tunnelStopped) {
        Write-Host "✅ SSH tunnel stopped successfully" -ForegroundColor Green
    }
    elseif (-not $Silent -and $global:OllamaConfig.Performance.EnableDebug) {
        Write-Host "⚠️ SSH tunnel stop attempted (no active tunnel found)" -ForegroundColor Yellow
    }
}

function Test-OllamaConnection {
    if (-not $global:OllamaConfig.Server.IsConnected) {
        return Start-OllamaTunnel
    }
    
    try {
        $null = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/tags" -Method Get -TimeoutSec 2 -ErrorAction Stop
        return $true
    }
    catch {
        $global:OllamaConfig.Server.IsConnected = $false
        return Start-OllamaTunnel
    }
}

# --------------------------------------------------------------------------------------------------------
# INTELLIGENT MODEL SELECTION
# --------------------------------------------------------------------------------------------------------

function Select-OptimalModel {
    [CmdletBinding()]
    param(
        [string]$InputLine,
        [hashtable]$Context = @{},
        [int]$HistoryCount = 0
    )
    
    # Fast model for simple completions
    if ($InputLine.Length -lt 10 -and -not ($Context.HasComplexContext -or $Context.HasTargets)) {
        return $global:OllamaConfig.Models.FastCompletion
    }
    
    # Context-aware for everything else
    return $global:OllamaConfig.Models.ContextAware
}

# --------------------------------------------------------------------------------------------------------
# ADVANCED CONTEXT ENGINE
# --------------------------------------------------------------------------------------------------------

function _Get-EnvironmentContext {
    param([hashtable]$Context)

    $Context.Environment = @{
        Directory         = (Get-Location).Path
        PowerShellVersion = $PSVersionTable.PSVersion
        IsElevated        = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        FilesInDirectory  = @(Get-ChildItem -Name -File | Select-Object -First 10)
    }
}

function _Get-CommandContext {
    param([hashtable]$Context)

    $inputLine = $Context.InputLine
    if ([string]::IsNullOrWhiteSpace($inputLine)) { return }

    $tokens = $inputLine.Trim() -split '\s+'
    if ($tokens.Count -gt 0) {
        $commandName = $tokens[0]
        $Context.ParsedCommand = @{
            Name       = $commandName
            Arguments  = $tokens[1..($tokens.Count - 1)]
            IsComplete = $inputLine.EndsWith(' ')
        }
        
        $commandInfo = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($commandInfo) {
            $Context.ParsedCommand.Type = $commandInfo.CommandType
            $Context.ParsedCommand.Parameters = @($commandInfo.Parameters.Keys)
            $Context.HasComplexContext = $true
        }
    }
}

function _Get-FileTargetContext {
    param([hashtable]$Context)

    if (-not $Context.ParsedCommand) { return }

    foreach ($arg in $Context.ParsedCommand.Arguments) {
        if (Test-Path $arg -IsValid) {
            $targetInfo = @{ Path = $arg; Exists = Test-Path $arg }
            if ($targetInfo.Exists) {
                try {
                    $item = Get-Item $arg -ErrorAction Stop
                    $targetInfo.Type = if ($item.PSIsContainer) { "Directory" } else { "File" }
                    $targetInfo.Size = if (-not $item.PSIsContainer) { $item.Length } else { $null }
                }
                catch {
                    # Could be a path that is valid but we don't have access to, ignore error
                }
            }
            $Context.Targets += $targetInfo
            $Context.HasTargets = $true
        }
    }
}

function _Get-GitContext {
    param([hashtable]$Context)

    # Check if we are in a git repo. Test-Path is faster than running git command.
    if (Test-Path (Join-Path $Context.Environment.Directory ".git")) {
        $Context.Environment.IsGitRepo = $true
        try {
            # Use -C to ensure we run git in the correct directory, regardless of PowerShell's current location
            $gitBranch = git -C $Context.Environment.Directory branch --show-current 2>$null
            $gitChanges = (git -C $Context.Environment.Directory status --porcelain 2>$null | Measure-Object).Count
            
            if ($gitBranch) { $Context.Environment.GitBranch = $gitBranch.Trim() }
            if ($gitChanges -ge 0) { $Context.Environment.GitChanges = $gitChanges }
        }
        catch { } # Silently fail if git command fails
    }
    else {
        $Context.Environment.IsGitRepo = $false
    }
}

function _Get-SmartDefaultsContext {
    param([hashtable]$Context)
    
    # Update smart defaults cache periodically (every 5 minutes)
    $now = Get-Date
    if (($now - $global:SmartDefaults.LastCacheUpdate).TotalMinutes -ge 5) {
        try {
            # Update recent commands with success/failure tracking
            $recentHistory = Get-History -Count 50 -ErrorAction SilentlyContinue
            $global:SmartDefaults.RecentCommands = $recentHistory | ForEach-Object {
                @{
                    Command   = $_.CommandLine
                    Timestamp = $_.StartExecutionTime
                    Success   = $null -ne $_.EndExecutionTime -and $_.ExecutionStatus -eq 'Completed'
                    Duration  = if ($_.EndExecutionTime) { ($_.EndExecutionTime - $_.StartExecutionTime).TotalMilliseconds } else { $null }
                }
            }
            
            $global:SmartDefaults.LastCacheUpdate = $now
        }
        catch {
            # Ignore cache update errors
        }
    }
    
    # Add smart defaults to context
    $Context.SmartDefaults = @{
        RecentSuccessfulCommands = $global:SmartDefaults.RecentCommands | Where-Object { $_.Success } | Select-Object -First 10
        RecentFailedCommands     = $global:SmartDefaults.RecentCommands | Where-Object { -not $_.Success } | Select-Object -First 5
        FastCommands            = $global:SmartDefaults.RecentCommands | Where-Object { $_.Duration -lt 1000 } | Select-Object -First 5
    }
}

function _Get-DirectoryPatternContext {
    param([hashtable]$Context)
    
    $currentDir = $Context.Environment.Directory
    if (-not $global:SmartDefaults.DirectoryPatterns.ContainsKey($currentDir)) {
        $global:SmartDefaults.DirectoryPatterns[$currentDir] = @()
    }
    
    # Detect directory type and common patterns
    $directoryType = "unknown"
    $commonPatterns = @()
    
    # Check for project indicators
    if (Test-Path (Join-Path $currentDir "package.json")) { 
        $directoryType = "nodejs"
        $commonPatterns = @("npm", "yarn", "node")
    }
    elseif (Test-Path (Join-Path $currentDir "requirements.txt") -or (Get-ChildItem "*.py" -ErrorAction SilentlyContinue)) { 
        $directoryType = "python"
        $commonPatterns = @("python", "pip", "pytest")
    }
    elseif (Test-Path (Join-Path $currentDir "*.csproj") -or (Test-Path (Join-Path $currentDir "*.sln"))) { 
        $directoryType = "dotnet"
        $commonPatterns = @("dotnet", "msbuild")
    }
    elseif (Get-ChildItem "*.ps1" -ErrorAction SilentlyContinue) { 
        $directoryType = "powershell"
        $commonPatterns = @("Test-Path", "Get-ChildItem", "Import-Module")
    }
    
    $Context.DirectoryPattern = @{
        Type = $directoryType
        CommonCommands = $commonPatterns
        PreviousCommands = $global:SmartDefaults.DirectoryPatterns[$currentDir]
    }
}

function _Get-ErrorHistoryContext {
    param([hashtable]$Context)
    
    # Get recent PowerShell errors
    $recentErrors = Get-Variable Error -ValueOnly -ErrorAction SilentlyContinue | Select-Object -First 5
    
    $Context.ErrorHistory = @{
        RecentErrors = $recentErrors | ForEach-Object {
            @{
                Message = $_.Exception.Message
                CommandName = $_.InvocationInfo.MyCommand.Name
                Line = $_.InvocationInfo.Line
            }
        }
        FailedCommands = $global:SmartDefaults.ErrorHistory
    }
}

function _Get-ModuleContext {
    param([hashtable]$Context)
    
    $loadedModules = Get-Module | Select-Object Name, Version, ModuleType
    $availableCommands = Get-Command | Where-Object { $_.Source } | 
                        Group-Object Source | 
                        Sort-Object Count -Descending | 
                        Select-Object -First 10
    
    $Context.ModuleContext = @{
        LoadedModules = $loadedModules
        TopCommandSources = $availableCommands
        RecentModuleImports = $global:SmartDefaults.RecentCommands | 
                             Where-Object { $_.Command -like "Import-Module*" } | 
                             Select-Object -First 5
    }
}

function _Get-TriggerContext {
    param([hashtable]$Context)
    
    # Check for @ triggers in input line for context injection
    if ($Context.InputLine -match '@(\w+)\s*(.*)') {
        $triggerName = $matches[1]
        $triggerQuery = $matches[2].Trim()
        
        $Context.Trigger = @{
            Name = $triggerName
            Query = $triggerQuery
            ProviderData = $null
        }
        
        # Execute trigger provider if available
        if ($global:SmartDefaults.TriggerProviders.ContainsKey($triggerName)) {
            try {
                $Context.Trigger.ProviderData = & $global:SmartDefaults.TriggerProviders[$triggerName]
                $Context.HasComplexContext = $true
            }
            catch {
                $Context.Trigger.ProviderData = @("Error loading $triggerName context: $($_.Exception.Message)")
            }
        }
    }
}

function Get-EnhancedContext {
    [CmdletBinding()]
    param([string]$InputLine, [int]$CursorIndex = 0)
    
    $context = @{
        InputLine         = $InputLine
        CursorIndex       = $CursorIndex
        Timestamp         = Get-Date
        Environment       = @{} # Populated by providers
        ParsedCommand     = $null # Populated by providers
        Targets           = @()
        HasComplexContext = $false
        HasTargets        = $false
    }
    
    $context.Timings = @{} # Add timings to the context object itself for logging
    $totalContextTimeMs = 0

    # Execute all registered context providers in order
    foreach ($provider in $global:ContextProviders.GetEnumerator()) {
        try {
            $timing = Measure-Command {
                & $provider.Value -context $context
            }
            $providerName = $provider.Name
            $ms = [math]::Round($timing.TotalMilliseconds, 2)
            $context.Timings[$providerName] = $ms
            $totalContextTimeMs += $ms

            # Update global metrics with a running average
            $currentAvg = if ($global:PerformanceMetrics.ProviderTimings.ContainsKey($providerName)) { $global:PerformanceMetrics.ProviderTimings[$providerName] } else { 0 }
            $global:PerformanceMetrics.ProviderTimings[$providerName] = ($currentAvg + $ms) / 2
        }
        catch {
            if ($global:OllamaConfig.Performance.EnableDebug) {
                Write-Warning "Context provider '$($provider.Name)' failed: $($_.Exception.Message)"
            }
        }
    }
    $global:PerformanceMetrics.TotalContextTime = ($global:PerformanceMetrics.TotalContextTime + $totalContextTimeMs) / 2
    
    return $context
}

function Update-RecentTargets {
    [CmdletBinding()]
    param([string]$Command)
    
    # Extract file paths from command
    $pathPatterns = @(
        '([a-z]:\\(?:[^\\/:*?"<>|\r\n]+\\)*[^\\/:*?"<>|\r\n]*)',
        '(\\.\\[^\\/:*?"<>|\r\n]+(?:\\[^\\/:*?"<>|\r\n]+)*)',
        '([^\\s]+\\.(?:ps1|psd1|psm1|txt|log|json|xml|csv|exe))'
    )
    
    $foundPaths = @()
    foreach ($pattern in $pathPatterns) {
        $matches = [regex]::Matches($Command, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($match in $matches) {
            $path = $match.Groups[1].Value.Trim('"''')
            if (Test-Path $path -IsValid) {
                $foundPaths += $path
            }
        }
    }
    
    if ($foundPaths) {
        $global:RecentTargets = (@($foundPaths) + @($global:RecentTargets) | 
            Select-Object -Unique -First $global:OllamaConfig.Performance.RecentTargetsCount)
    }
}

# --------------------------------------------------------------------------------------------------------
# JSON-FIRST OLLAMA API INTEGRATION
# --------------------------------------------------------------------------------------------------------

function Invoke-OllamaCompletion {
    [CmdletBinding()]
    param(
        [hashtable]$RequestPayload,         # Complete API payload from prompt builders
        [string]$Endpoint = "/api/chat",    # API endpoint (/api/chat or /api/generate)
        [int]$TimeoutMs = 30000            # Request timeout in milliseconds
    )
    
    if (-not (Test-OllamaConnection)) {
        throw "Ollama connection not available"
    }
    
    $global:PerformanceMetrics.RequestCount++
    $startTime = Get-Date
    
    try {
        # Execute the complete request payload as provided by prompt builders
        $job = Start-Job -ScriptBlock {
            param($apiUrl, $endpoint, $requestBodyJson, $timeoutSec)
            try {
                $uri = "$apiUrl$endpoint"
                Invoke-RestMethod -Uri $uri -Method Post -Body $requestBodyJson -ContentType 'application/json' -TimeoutSec $timeoutSec
            }
            catch {
                @{ 
                    error = $_.Exception.Message
                    status_code = if ($_.Exception.Response) { $_.Exception.Response.StatusCode } else { "Unknown" }
                    endpoint = $endpoint
                }
            }
        } -ArgumentList $global:OllamaConfig.Server.ApiUrl, $Endpoint, ($RequestPayload | ConvertTo-Json -Depth 10), ($TimeoutMs / 1000)
        
        $result = $null
        if (Wait-Job $job -Timeout ($TimeoutMs / 1000 + 5)) {  # Add 5s buffer for job overhead
            $result = Receive-Job $job
        }
        else {
            # Job timed out
            Remove-Job $job -Force
            throw "Ollama request timed out after $($TimeoutMs)ms"
        }
        
        Remove-Job $job -Force
        
        # Update performance metrics
        $latency = ((Get-Date) - $startTime).TotalMilliseconds
        $global:PerformanceMetrics.AverageLatency = ($global:PerformanceMetrics.AverageLatency + $latency) / 2
        
        if ($result -and -not $result.error) {
            # Success
            $global:PerformanceMetrics.SuccessRate = ($global:PerformanceMetrics.SuccessRate * 0.95) + 0.05
            
            # Return raw response - let callers handle parsing
            return @{
                response = $result
                latency_ms = $latency
                endpoint = $Endpoint
                model = $RequestPayload.model
                success = $true
            }
        }
        else {
            # API returned an error
            $global:PerformanceMetrics.SuccessRate = $global:PerformanceMetrics.SuccessRate * 0.9
            
            $errorMsg = if ($result.error) { $result.error } else { "Unknown API error" }
            throw "Ollama API error: $errorMsg"
        }
    }
    catch {
        # Update failure metrics
        $global:PerformanceMetrics.SuccessRate = $global:PerformanceMetrics.SuccessRate * 0.9
        
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Host "⚠️ Ollama request failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($RequestPayload.model) {
                Write-Host "   Model: $($RequestPayload.model), Endpoint: $Endpoint" -ForegroundColor Gray
            }
        }
        throw
    }
}

function Build-AutocompletePrompt {
    [CmdletBinding()]
    param(
        [string]$InputLine,
        [hashtable]$Context = @{},
        [string]$ModelName = "powershell-fast:latest"
    )
    
    # Simple, focused prompt for immediate completion
    $userPrompt = "Complete: $InputLine"
    
    # Streamlined API payload - modelfile handles system prompt, parameters, and JSON format
    return @{
        model = $ModelName
        messages = @(
            @{ role = "user"; content = $userPrompt }
        )
        format = "json"
        stream = $true
        keep_alive = "30s"
    }
}

function Build-CoderPrompt {
    [CmdletBinding()]
    param(
        [string]$InputLine,
        [hashtable]$Context = @{},
        [string]$ModelName = "powershell-context:latest"
    )
    
    # Build rich contextual information for sophisticated analysis
    $contextParts = @()
    
    # Add directory context
    if ($Context.Environment.Directory) { 
        $contextParts += "Directory: $($Context.Environment.Directory)" 
    }
    
    # Add git context if available
    if ($Context.Environment.IsGitRepo) { 
        $contextParts += "Git: $($Context.Environment.GitBranch) ($($Context.Environment.GitChanges) changes)" 
    }
    
    # Add file context
    if ($Context.Environment.FilesInDirectory) { 
        $fileTypes = $Context.Environment.FilesInDirectory | 
                     ForEach-Object { "*." + ($_ -split '\.')[-1] } | 
                     Select-Object -Unique -First 5
        $contextParts += "Files: [$($fileTypes -join ', ')]"
    }
    
    # Add elevation status
    if ($Context.Environment.IsElevated) {
        $contextParts += "PowerShell: Elevated"
    }
    
    # Add recent command patterns
    if ($global:RecentTargets) {
        $recentCommands = $global:RecentTargets | 
                         ForEach-Object { Split-Path $_ -Leaf } | 
                         Select-Object -First 3
        $contextParts += "Recent: [$($recentCommands -join ', ')]"
    }
    
    # Add parsed command context if available
    if ($Context.ParsedCommand) {
        $contextParts += "Command: $($Context.ParsedCommand.Name) ($($Context.ParsedCommand.Type))"
        if ($Context.ParsedCommand.Arguments) {
            $contextParts += "Args: [$($Context.ParsedCommand.Arguments -join ', ')]"
        }
    }
    
    $userPrompt = @"
Context: $($contextParts -join ' | ')
Input: $InputLine

Analyze the context and provide sophisticated PowerShell command suggestions with detailed explanations.
"@
    
    # Streamlined payload - modelfile handles system prompt, parameters, and JSON format
    return @{
        model = $ModelName
        messages = @(
            @{ role = "user"; content = $userPrompt }
        )
        format = "json"
        stream = $true
        options = @{
            num_ctx = 16384     # Override for large context when needed
        }
        keep_alive = "5m"
    }
}

function Build-RankerPrompt {
    [CmdletBinding()]
    param(
        [string]$Query,
        [string]$Completion,
        [hashtable]$Context = @{},
        [string]$ModelName = "qwen3-reranker:latest"
    )
    
    # Build context summary for evaluation
    $contextSummary = @()
    if ($Context.Environment.Directory) { 
        $contextSummary += "Dir: $($Context.Environment.Directory)" 
    }
    if ($Context.Environment.IsGitRepo) { 
        $contextSummary += "Git: $($Context.Environment.GitBranch)" 
    }
    if ($Context.Environment.FilesInDirectory) { 
        $contextSummary += "Files: $($Context.Environment.FilesInDirectory.Count)" 
    }
    if ($Context.Environment.IsElevated) {
        $contextSummary += "Elevated: Yes"
    }
    
    # Structured evaluation prompt
    $evaluationPrompt = @"
Query: "$Query"
Completion: "$Completion"
Context: $($contextSummary -join ', ')

Evaluate the relevance and quality of this PowerShell completion.
"@
    
    # Streamlined payload for precise evaluation - modelfile handles system prompt and parameters
    return @{
        model = $ModelName
        prompt = $evaluationPrompt      # Use generate endpoint for efficiency
        format = "json"
        stream = $false                 # Ranking needs complete response for accuracy
        keep_alive = "1m"
    }
}

# --------------------------------------------------------------------------------------------------------
# INTELLIGENT CACHING SYSTEM
# --------------------------------------------------------------------------------------------------------

function Get-CachedPrediction {
    [CmdletBinding()]
    param([string]$CacheKey, [scriptblock]$Generator)
    
    $now = Get-Date
    
    # Check cache
    if ($global:PredictionCache.ContainsKey($CacheKey)) {
        $cached = $global:PredictionCache[$CacheKey]
        if (($now - $cached.Timestamp).TotalSeconds -lt $global:OllamaConfig.Performance.CacheTimeout) {
            $global:PerformanceMetrics.CacheHits++
            return $cached.Result
        }
    }
    
    # Generate new result
    $result = & $Generator
    
    if ($result) {
        # Clean cache if too large
        if ($global:PredictionCache.Count -gt $global:OllamaConfig.Performance.CacheSize) {
            $oldestKeys = $global:PredictionCache.GetEnumerator() | 
            Sort-Object { $_.Value.Timestamp } | 
            Select-Object -First 50 | 
            ForEach-Object { $_.Key }
            foreach ($key in $oldestKeys) {
                $global:PredictionCache.Remove($key)
            }
        }
        
        $global:PredictionCache[$CacheKey] = @{
            Result    = $result
            Timestamp = $now
        }
    }
    
    return $result
}

# --------------------------------------------------------------------------------------------------------
# FALLBACK PREDICTION SYSTEM
# --------------------------------------------------------------------------------------------------------

function Get-HistoryBasedSuggestions {
    [CmdletBinding()]
    param([string]$InputLine)
    
    if ([string]::IsNullOrWhiteSpace($InputLine)) {
        return @()
    }
    
    try {
        # Get from PowerShell history
        $historySuggestions = Get-History | 
        Select-Object -ExpandProperty CommandLine |
        Where-Object { $_ -like "$InputLine*" } |
        Select-Object -Unique -First 5
        
        # Convert to JSON format for consistency
        return @{
            completions = @($historySuggestions)
            confidence  = 0.6
            context     = "history_fallback"
        }
    }
    catch {
        return @{
            completions = @()
            confidence  = 0.0
            context     = "fallback_failed"
        }
    }
}

# --------------------------------------------------------------------------------------------------------
# MAIN PREDICTION ENGINE - FIXED RETURN VALUES
# --------------------------------------------------------------------------------------------------------

function Get-CommandPrediction {
    [CmdletBinding()]
    param(
        [string]$InputLine,
        [int]$CursorIndex = 0
    )
    
    try {
        # Empty input handling
        if ([string]::IsNullOrWhiteSpace($InputLine)) {
            $historyResult = Get-HistoryBasedSuggestions -InputLine ""
            return $historyResult.completions
        }
        
        # Get enhanced context
        $context = Get-EnhancedContext -InputLine $InputLine -CursorIndex $CursorIndex
        
        # Update recent targets
        if ($global:CommandHistory) {
            $lastCommand = $global:CommandHistory | Select-Object -Last 1
            if ($lastCommand -and $lastCommand.Command -ne $InputLine) {
                Update-RecentTargets -Command $lastCommand.Command
            }
        }
        
        # Select optimal model
        $modelConfig = Select-OptimalModel -InputLine $InputLine -Context $context
        $cacheKey = "$($modelConfig.Name)_$($InputLine.GetHashCode())_$($context.Environment.Directory.GetHashCode())"
        
        # Get cached or generate new predictions
        $result = Get-CachedPrediction -CacheKey $cacheKey -Generator {
            try {
                Invoke-OllamaCompletion -Model $modelConfig.Name -Prompt $InputLine -Context $context -TimeoutMs $modelConfig.Timeout
            }
            catch {
                # Fallback to history-based suggestions
                Get-HistoryBasedSuggestions -InputLine $InputLine
            }
        }
        
        # FIXED: Convert to consistent format - handle both strings and objects
        $finalCompletions = @()
        if ($result -and $result.completions) {
            $finalCompletions = $result.completions | ForEach-Object { 
                if ($_ -is [string]) { 
                    $_ 
                } 
                elseif ($_.text) { 
                    $_.text 
                } 
                else { 
                    $_.ToString()
                }
            } | Where-Object { $_ -and $_.Trim() }
        }
        elseif ($result -is [array]) {
            # Handle cases where raw array is returned
            $finalCompletions = $result
        }

        # --- Acceptance Tracking: Increment "Offered" Count ---
        # Use the result context (e.g., 'history_fallback') or the model name as the identifier
        $modelIdentifier = if ($result.context) { $result.context } else { $modelConfig.Name }
        if (-not $global:PerformanceMetrics.AcceptanceTracking.ContainsKey($modelIdentifier)) {
            $global:PerformanceMetrics.AcceptanceTracking[$modelIdentifier] = @{ Accepted = 0; Offered = 0; Errors = 0 }
        }
        # Only count as "offered" if we actually produced suggestions
        if ($finalCompletions.Count -gt 0) {
            $global:PerformanceMetrics.AcceptanceTracking[$modelIdentifier].Offered++
        }
        # --- End Acceptance Tracking ---

        # NEW: Log prediction if enabled
        if ($global:OllamaConfig.Performance.EnablePredictionLogging) {
            $logEntry = @{
                Timestamp    = Get-Date
                InputLine    = $InputLine
                ModelUsed    = $modelIdentifier # Use the more accurate identifier
                ResultSource = $modelIdentifier
                Predictions  = $finalCompletions
                Timings      = $context.Timings
                CacheKey     = $cacheKey
            }
            $global:PredictionLog.Add($logEntry)
            # Trim log if it gets too big to prevent memory issues
            if ($global:PredictionLog.Count -gt 500) {
                $global:PredictionLog.RemoveRange(0, $global:PredictionLog.Count - 500)
            }
        }

        return $finalCompletions
    }
    catch {
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Host "⚠️ Prediction error: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        $fallbackResult = Get-HistoryBasedSuggestions -InputLine $InputLine
        # Ensure fallback also returns a consistent format
        return if ($fallbackResult.completions) { $fallbackResult.completions } else { @() }
    }
}

# --------------------------------------------------------------------------------------------------------
# COMMAND HISTORY AND FEEDBACK SYSTEM
# --------------------------------------------------------------------------------------------------------

function Add-CommandToHistory {
    [CmdletBinding()]
    param(
        [string]$Command,
        [bool]$Success = $true,
        [string]$ErrorMessage = ""
    )
    
    # --- Acceptance Tracking: Check if this command was an accepted prediction ---
    if ($global:PredictionLog.Count -gt 0) {
        $lastPrediction = $global:PredictionLog[-1]
        
        # To be an "acceptance", the executed command must start with the input that generated
        # the prediction, and it must exactly match one of the suggestions.
        if ($Command.StartsWith($lastPrediction.InputLine) -and ($lastPrediction.Predictions -contains $Command)) {
            $modelIdentifier = $lastPrediction.ModelUsed
            if ($global:PerformanceMetrics.AcceptanceTracking.ContainsKey($modelIdentifier)) {
                $global:PerformanceMetrics.AcceptanceTracking[$modelIdentifier].Accepted++
                # NEW: Track if the accepted command resulted in an error
                if (-not $Success) {
                    $global:PerformanceMetrics.AcceptanceTracking[$modelIdentifier].Errors++
                }
                if ($global:OllamaConfig.Performance.EnableDebug) {
                    Write-Host "✅ Prediction accepted for model '$modelIdentifier'" -ForegroundColor DarkGreen
                }
            }
        }
    }
    
    $entry = @{
        Command   = $Command
        Success   = $Success
        Error     = $ErrorMessage
        Timestamp = Get-Date
        Directory = Get-Location
    }
    
    $global:CommandHistory += $entry
    
    # Trim history if too large
    if ($global:CommandHistory.Count -gt $global:OllamaConfig.Performance.MaxHistoryLines) {
        $startIndex = $global:CommandHistory.Count - $global:OllamaConfig.Performance.MaxHistoryLines
        $global:CommandHistory = $global:CommandHistory[$startIndex..($global:CommandHistory.Count - 1)]
    }
    
    # Update recent targets
    Update-RecentTargets -Command $Command
}

function Clear-PowerAugerCache {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param()
    <#
    .SYNOPSIS
    Clears the in-memory prediction cache and deletes the cache file from disk.
    #>

    if ($pscmdlet.ShouldProcess("the prediction cache in memory and on disk ($($global:PowerAugerCacheFile))")) {
        $global:PredictionCache.Clear()
        if (Test-Path $global:PowerAugerCacheFile) {
            try {
                Remove-Item -Path $global:PowerAugerCacheFile -Force -ErrorAction Stop
                Write-Host "✅ Prediction cache file removed." -ForegroundColor Green
            }
            catch { Write-Warning "Failed to remove cache file: $($_.Exception.Message)" }
        }
        Write-Host "✅ In-memory prediction cache cleared." -ForegroundColor Green
    }
}
# --------------------------------------------------------------------------------------------------------
# PERFORMANCE MONITORING AND DIAGNOSTICS
# --------------------------------------------------------------------------------------------------------

function Get-PredictorStatistics {
    [CmdletBinding()]
    param()
    
    $stats = @{
        Performance = $global:PerformanceMetrics.Clone()
        Cache       = @{
            Size    = $global:PredictionCache.Count
            MaxSize = $global:OllamaConfig.Performance.CacheSize
            HitRate = if ($global:PerformanceMetrics.RequestCount -gt 0) { 
                [math]::Round(($global:PerformanceMetrics.CacheHits / $global:PerformanceMetrics.RequestCount) * 100, 1) 
            }
            else { 0 }
        }
        Connection  = @{
            Status       = if ($global:OllamaConfig.Server.IsConnected) { "Connected" } else { "Disconnected" }
            TunnelActive = $null -ne $global:OllamaConfig.Server.TunnelProcess -and -not $global:OllamaConfig.Server.TunnelProcess.HasExited
        }
        History     = @{
            CommandCount  = $global:CommandHistory.Count
            RecentTargets = $global:RecentTargets.Count
        }
    }
    
    # Add calculated acceptance rates
    $stats.AcceptanceRates = @{}
    foreach ($modelEntry in $global:PerformanceMetrics.AcceptanceTracking.GetEnumerator()) {
        $modelName = $modelEntry.Name
        $accepted = $modelEntry.Value.Accepted
        $offered = $modelEntry.Value.Offered
        $errors = $modelEntry.Value.Errors
        $rate = if ($offered -gt 0) { [math]::Round(($accepted / $offered) * 100, 1) } else { 0 }
        $errorRate = if ($accepted -gt 0) { [math]::Round(($errors / $accepted) * 100, 1) } else { 0 }
        
        $stats.AcceptanceRates[$modelName] = @{
            Accepted  = $accepted
            Offered   = $offered
            Rate      = $rate
            Errors    = $errors
            ErrorRate = $errorRate
        }
    }
    
    return $stats
}

function Show-PredictorStatus {
    [CmdletBinding()]
    param()
    
    $stats = Get-PredictorStatistics
    
    Write-Host "🤖 Ollama PowerShell Predictor Status" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    Write-Host "Connection: " -NoNewline -ForegroundColor White
    if ($stats.Connection.Status -eq "Connected") {
        Write-Host $stats.Connection.Status -ForegroundColor Green
    }
    else {
        Write-Host $stats.Connection.Status -ForegroundColor Red
    }
    
    Write-Host "Requests: $($stats.Performance.RequestCount)" -ForegroundColor White
    Write-Host "Cache Hit Rate: $($stats.Cache.HitRate)%" -ForegroundColor White
    Write-Host "Avg API Latency: $([math]::Round($stats.Performance.AverageLatency, 0))ms" -ForegroundColor White
    Write-Host "Avg Context Time: $([math]::Round($stats.Performance.TotalContextTime, 1))ms" -ForegroundColor White
    Write-Host "Success Rate: $([math]::Round($stats.Performance.SuccessRate * 100, 1))%" -ForegroundColor White
    Write-Host ""
    Write-Host "Models:" -ForegroundColor White
    Write-Host "  - Fast:    $($global:OllamaConfig.Models.FastCompletion.Name)" -ForegroundColor Gray
    Write-Host "  - Context: $($global:OllamaConfig.Models.ContextAware.Name)" -ForegroundColor Gray
    
    if ($stats.AcceptanceRates.Count -gt 0) {
        Write-Host ""
        Write-Host "Acceptance Rate:" -ForegroundColor White
        foreach ($rateEntry in ($stats.AcceptanceRates.GetEnumerator() | Sort-Object Name)) {
            $line = "  - {0,-25}: {1}% ({2}/{3})" -f $rateEntry.Name, $rateEntry.Value.Rate, $rateEntry.Value.Accepted, $rateEntry.Value.Offered
            if ($rateEntry.Value.Accepted -gt 0) {
                $line += " | Errors: $($rateEntry.Value.ErrorRate)% ($($rateEntry.Value.Errors))"
            }
            $color = if ($rateEntry.Value.Errors -gt 0) { "Yellow" } else { "Gray" }
            Write-Host $line -ForegroundColor $color
        }
    }

    Write-Host ""
}

function Get-PredictionLog {
    [CmdletBinding()]
    param(
        [int]$Last = 50
    )
    <#
    .SYNOPSIS
    Retrieves the log of recent predictions for troubleshooting.
    #>
    
    $count = [math]::Min($Last, $global:PredictionLog.Count)
    if ($count -gt 0) {
        # Return in reverse chronological order (most recent first)
        return $global:PredictionLog[($global:PredictionLog.Count - 1)..($global:PredictionLog.Count - $count)]
    }
    return @()
}
# --------------------------------------------------------------------------------------------------------
# INITIALIZATION AND CLEANUP
# --------------------------------------------------------------------------------------------------------

function Register-PowerAugerCleanupEvents {
    [CmdletBinding()]
    param()
    
    try {
        # PowerShell exit event (primary cleanup)
        Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
            try {
                Save-PowerAugerState
                Stop-OllamaTunnel -Silent
            }
            catch {
                # Silent cleanup - errors during shutdown are not critical
            }
        } | Out-Null
        
        # .NET AppDomain exit event (backup cleanup for unexpected exits)
        $cleanupAction = {
            try {
                Stop-OllamaTunnel -Silent
            }
            catch {
                # Silent cleanup
            }
        }
        
        # Register .NET ProcessExit event for more reliable cleanup
        [System.AppDomain]::CurrentDomain.add_ProcessExit($cleanupAction)
        
        # Windows console control event (Ctrl+C, system shutdown, etc.)
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            try {
                # Use P/Invoke to handle Windows console control events
                Add-Type -TypeDefinition @"
                    using System;
                    using System.Runtime.InteropServices;
                    
                    public static class ConsoleHelper {
                        public delegate bool ConsoleCtrlDelegate(int dwCtrlType);
                        
                        [DllImport("kernel32.dll")]
                        public static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate HandlerRoutine, bool Add);
                        
                        public const int CTRL_C_EVENT = 0;
                        public const int CTRL_BREAK_EVENT = 1;
                        public const int CTRL_CLOSE_EVENT = 2;
                        public const int CTRL_LOGOFF_EVENT = 5;
                        public const int CTRL_SHUTDOWN_EVENT = 6;
                        
                        public static bool ConsoleCtrlHandler(int dwCtrlType) {
                            try {
                                // Call PowerShell function for cleanup
                                System.Management.Automation.PowerShell.Create().AddScript("Stop-OllamaTunnel -Silent").Invoke();
                                return true;
                            } catch {
                                return false;
                            }
                        }
                    }
"@ -ErrorAction SilentlyContinue
                
                # Register the console control handler
                $handler = [ConsoleHelper+ConsoleCtrlDelegate] {
                    param($ctrlType)
                    try {
                        Stop-OllamaTunnel -Silent
                        return $true
                    }
                    catch {
                        return $false
                    }
                }
                
                [ConsoleHelper]::SetConsoleCtrlHandler($handler, $true)
            }
            catch {
                # P/Invoke setup failed, continue with other cleanup methods
                if ($global:OllamaConfig.Performance.EnableDebug) {
                    Write-Warning "Could not register Windows console control handler: $($_.Exception.Message)"
                }
            }
        }
        
        # WMI system shutdown event (Windows-specific)
        try {
            Register-WmiEvent -Query "SELECT * FROM Win32_SystemShutdownEvent" -Action {
                try {
                    Save-PowerAugerState
                    Stop-OllamaTunnel -Silent
                }
                catch {
                    # Silent cleanup
                }
            } -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            # WMI events might not be available in all environments
        }
        
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Host "✅ Registered comprehensive cleanup events" -ForegroundColor Green
        }
    }
    catch {
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Warning "Some cleanup events could not be registered: $($_.Exception.Message)"
        }
    }
}

function Initialize-OllamaPredictor {
    [CmdletBinding()]
    param(
        [switch]$EnableDebug,
        [switch]$StartTunnel = $true,
        [switch]$NoPrewarm
    )
    
    # Load configuration from file first, which may enable debug mode or change settings
    Load-PowerAugerConfiguration

    if ($EnableDebug) {
        $global:OllamaConfig.Performance.EnableDebug = $true
    }
    
    Write-Host "🚀 Initializing Ollama PowerShell Predictor..." -ForegroundColor Cyan
    
    Load-PowerAugerState
    
    # Start SSH tunnel
    if ($StartTunnel) {
        $connected = Start-OllamaTunnel
        if (-not $connected) {
            Write-Host "⚠️ Could not establish SSH tunnel. Predictor will use fallback mode." -ForegroundColor Yellow
        }
        elseif (-not $NoPrewarm) {
            # Pre-warm models to reduce first-use latency
            Write-Host "🔥 Pre-warming models in the background... (this may take a moment)" -ForegroundColor Yellow
            
            foreach ($modelEntry in $global:ModelRegistry.GetEnumerator()) {
                $modelName = $modelEntry.Value.Name
                $keepAlive = $modelEntry.Value.KeepAlive
                
                # Use a fire-and-forget job to load the model
                Start-Job -ScriptBlock {
                    param($modelToWarm, $keepAliveSetting, $apiUrl, $debugEnabled)
                    
                    if ($debugEnabled) {
                        Write-Host "  - Sending pre-warm request to '$modelToWarm'..."
                    }
                    
                    $body = @{
                        model      = $modelToWarm
                        prompt     = "Pre-warming model" # Simple prompt, just to load it
                        stream     = $false
                        keep_alive = $keepAliveSetting
                    } | ConvertTo-Json

                    try {
                        # Use a long timeout because model loading can be slow.
                        # The job runs in the background, so it won't block the user.
                        $null = Invoke-RestMethod -Uri "$apiUrl/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 120 -ErrorAction Stop
                    }
                    catch {
                        # This is a background job, so we can't easily show warnings. The failure is non-critical.
                    }
                } -ArgumentList $modelName, $keepAlive, $global:OllamaConfig.Server.ApiUrl, $global:OllamaConfig.Performance.EnableDebug | Out-Null
            }
        }
    }
    
    # Register comprehensive cleanup events for Windows
    Register-PowerAugerCleanupEvents
    
    # Register command feedback (if available)
    Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
        try {
            $lastCmd = Get-History -Count 1 -ErrorAction SilentlyContinue
            if ($lastCmd -and ($null -eq $global:LastProcessedCommandId -or $lastCmd.Id -gt $global:LastProcessedCommandId)) {
                $global:LastProcessedCommandId = $lastCmd.Id
                Add-CommandToHistory -Command $lastCmd.CommandLine -Success $? -ErrorMessage $(if (-not $?) { $Error[0].Exception.Message } else { "" })
            }
        }
        catch { }
    } | Out-Null
    
    Write-Host "✅ Ollama PowerShell Predictor initialized!" -ForegroundColor Green
    Show-PredictorStatus
}

# --------------------------------------------------------------------------------------------------------
# CONFIGURATION MANAGEMENT
# --------------------------------------------------------------------------------------------------------

function Set-PredictorConfiguration {
    [CmdletBinding()]
    param(
        [string]$LinuxHost,
        [int]$LocalPort,
        [switch]$EnableDebug,
        [int]$CacheTimeout,
        [int]$CacheSize
    )
    
    if ($LinuxHost) { $global:OllamaConfig.Server.LinuxHost = $LinuxHost }
    if ($LocalPort) { $global:OllamaConfig.Server.LocalPort = $LocalPort }
    if ($EnableDebug.IsPresent) { $global:OllamaConfig.Performance.EnableDebug = $EnableDebug }
    if ($CacheTimeout) { $global:OllamaConfig.Performance.CacheTimeout = $CacheTimeout }
    if ($CacheSize) { $global:OllamaConfig.Performance.CacheSize = $CacheSize }
    
    # Update API URL
    $global:OllamaConfig.Server.ApiUrl = "http://localhost:$($global:OllamaConfig.Server.LocalPort)"

    # Persist configuration changes
    Save-PowerAugerConfiguration
}

# --------------------------------------------------------------------------------------------------------
# EXPANSION STRATEGY HOOKS
# --------------------------------------------------------------------------------------------------------

# Context Provider Registry with enhanced providers from legacy analysis
# This ordered dictionary defines the context providers and their execution order.
# Each value is a scriptblock that accepts a single [hashtable]$Context parameter.
$global:ContextProviders = [ordered]@{
    'Environment'    = { param($Context) _Get-EnvironmentContext -Context $Context }
    'Command'        = { param($Context) _Get-CommandContext -Context $Context }
    'FileTarget'     = { param($Context) _Get-FileTargetContext -Context $Context }
    'Git'            = { param($Context) _Get-GitContext -Context $Context }
    'SmartDefaults'  = { param($Context) _Get-SmartDefaultsContext -Context $Context }
    'DirectoryPattern' = { param($Context) _Get-DirectoryPatternContext -Context $Context }
    'ErrorHistory'   = { param($Context) _Get-ErrorHistoryContext -Context $Context }
    'ModuleContext'  = { param($Context) _Get-ModuleContext -Context $Context }
    'TriggerContext' = { param($Context) _Get-TriggerContext -Context $Context }
    # Future providers: Azure, AWS, Docker, Kubernetes, etc.
}

# Smart defaults for command success tracking and pattern recognition
$global:SmartDefaults = @{
    CommandSuccess    = @{}    # Track which commands typically succeed
    DirectoryPatterns = @{}    # Common command patterns per directory type  
    RecentCommands    = @()    # Last 50 commands with success/failure tracking
    ErrorHistory      = @()    # Commands that failed recently
    LastCacheUpdate   = (Get-Date).AddDays(-1)
    TriggerProviders  = @{     # @ trigger system for context injection
        'files'   = { Get-ChildItem -Name -File | Select-Object -First 20 }
        'dirs'    = { Get-ChildItem -Name -Directory | Select-Object -First 10 }
        'git'     = { 
            if (Test-Path .git) {
                @(
                    "Branch: $(git branch --show-current 2>$null)"
                    "Status: $(git status --porcelain 2>$null | Measure-Object | Select-Object -ExpandProperty Count) changes"
                    "Recent: $(git log --oneline -5 2>$null | ForEach-Object { ($_ -split ' ')[1..100] -join ' ' } | Select-Object -First 3)"
                )
            } else { @() }
        }
        'history' = { Get-History -Count 20 | Select-Object -ExpandProperty CommandLine }
        'errors'  = { $global:SmartDefaults.ErrorHistory | Select-Object -First 5 }
        'modules' = { Get-Module | Select-Object -ExpandProperty Name | Select-Object -First 15 }
        'env'     = { 
            @(
                "SSH: $($null -ne $env:SSH_CLIENT)"
                "PWD: $(Get-Location)"
                "User: $env:USERNAME"
                "PS: $($PSVersionTable.PSVersion)"
                "Elevated: $([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)"
            )
        }
    }
}

# Model Registry for easy expansion
$global:ModelRegistry = @{
    'FastCompletion' = $global:OllamaConfig.Models.FastCompletion
    'ContextAware'   = $global:OllamaConfig.Models.ContextAware
    # Future models: Python, JavaScript, JSON-specific, etc.
}


# --------------------------------------------------------------------------------------------------------
# MODULE EXPORTS
# --------------------------------------------------------------------------------------------------------

# Main prediction function for PSReadLine
Export-ModuleMember -Function Get-CommandPrediction

# Management functions
Export-ModuleMember -Function @(
    'Initialize-OllamaPredictor',
    'Set-PredictorConfiguration',
    'Start-OllamaTunnel',
    'Stop-OllamaTunnel',
    'Test-OllamaConnection',
    'Show-PredictorStatus',
    'Get-PredictorStatistics',
    'Get-PredictionLog', # NEW
    'Save-PowerAugerState',
    'Clear-PowerAugerCache' # NEW
)

# Auto-initialize if not in module development mode
if (-not $env:OLLAMA_PREDICTOR_DEV_MODE) {
    Initialize-OllamaPredictor
}