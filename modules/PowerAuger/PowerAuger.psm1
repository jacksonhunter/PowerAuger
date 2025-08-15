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
        CacheTimeout          = 300
        CacheSize             = 200
        MaxHistoryLines       = 1000
        RecentTargetsCount    = 30
        SessionCleanupMinutes = 30
        EnableDebug           = $false
    }
}

# Global state containers
$global:PredictionCache = @{}
$global:ChatSessions = @{}
$global:PredictionLog = [System.Collections.Generic.List[object]]::new()
$global:RecentTargets = @()
$global:CommandHistory = @()
$global:PerformanceMetrics = @{
    RequestCount   = 0
    CacheHits      = 0
    AverageLatency = 0
    SuccessRate    = 1.0
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
        try { $global:CommandHistory = Get-Content -Path $global:PowerAugerHistoryFile -Raw | ConvertFrom-Json } catch { }
    }
    if (Test-Path $global:PowerAugerCacheFile) {
        try { $global:PredictionCache = Get-Content -Path $global:PowerAugerCacheFile -Raw | ConvertFrom-Json -AsHashtable } catch { }
    }
    if (Test-Path $global:PowerAugerTargetsFile) {
        try { $global:RecentTargets = Get-Content -Path $global:PowerAugerTargetsFile -Raw | ConvertFrom-Json } catch { }
    }
    if (Test-Path $global:PowerAugerLogFile) {
        try {
            $logData = Get-Content -Path $global:PowerAugerLogFile -Raw | ConvertFrom-Json
            if ($logData) { $global:PredictionLog = [System.Collections.Generic.List[object]]::new($logData) }
        }
        catch { }
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
            "-N", "-T", "-C"
            "-L", "$($global:OllamaConfig.Server.LocalPort):localhost:$($global:OllamaConfig.Server.LinuxPort)"
        )
        
        if (Test-Path $global:OllamaConfig.Server.SSHKey) {
            $sshArgs += @("-i", $global:OllamaConfig.Server.SSHKey)
        }
        
        $sshArgs += "$($global:OllamaConfig.Server.SSHUser)@$($global:OllamaConfig.Server.LinuxHost)"
        
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "ssh"
        $processInfo.Arguments = $sshArgs -join " "
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.RedirectStandardError = $true
        
        $process = [System.Diagnostics.Process]::Start($processInfo)
        Start-Sleep -Seconds 2
        
        # Test connection
        $testResponse = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/version" -Method Get -TimeoutSec 5 -ErrorAction Stop
        
        if ($testResponse) {
            $global:OllamaConfig.Server.TunnelProcess = $process
            $global:OllamaConfig.Server.IsConnected = $true
            
            if ($global:OllamaConfig.Performance.EnableDebug) {
                Write-Host "✅ SSH tunnel established" -ForegroundColor Green
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
    
    if ($global:OllamaConfig.Server.TunnelProcess -and -not $global:OllamaConfig.Server.TunnelProcess.HasExited) {
        try {
            $global:OllamaConfig.Server.TunnelProcess.Kill()
        }
        catch { }
        $global:OllamaConfig.Server.TunnelProcess = $null
    }
    $global:OllamaConfig.Server.IsConnected = $false
    
    if (-not $Silent -and $global:OllamaConfig.Performance.EnableDebug) {
        Write-Host "🔗 SSH tunnel stopped" -ForegroundColor Yellow
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
    
    # Execute all registered context providers in order
    foreach ($provider in $global:ContextProviders.GetEnumerator()) {
        try {
            & $provider.Value -context $context
        }
        catch {
            if ($global:OllamaConfig.Performance.EnableDebug) {
                Write-Warning "Context provider '$($provider.Name)' failed: $($_.Exception.Message)"
            }
        }
    }
    
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
        [string]$Model,
        [string]$Prompt,
        [hashtable]$Context = @{},
        [int]$TimeoutMs = 5000,
        [switch]$UseJSON = $false  # Changed default to false since your models output text
    )
    
    if (-not (Test-OllamaConnection)) {
        throw "Ollama connection not available"
    }
    
    $global:PerformanceMetrics.RequestCount++
    $startTime = Get-Date
    
    # Build enhanced prompt with context using model-specific format
    $enhancedPrompt = Build-ContextualPrompt -BasePrompt $Prompt -Context $Context -ModelName $Model
    
    # Get model config for the specific model being used
    $modelConfig = $null
    if ($Model -eq $global:OllamaConfig.Models.FastCompletion.Name) {
        $modelConfig = $global:OllamaConfig.Models.FastCompletion
    }
    elseif ($Model -eq $global:OllamaConfig.Models.ContextAware.Name) {
        $modelConfig = $global:OllamaConfig.Models.ContextAware
    }
    else {
        # Default to fast completion settings
        $modelConfig = $global:OllamaConfig.Models.FastCompletion
    }
    
    try {
        $requestBody = @{
            model    = $Model
            messages = @(@{
                    role    = "user"
                    content = $enhancedPrompt
                })
            stream   = $false
            options  = @{
                temperature = $modelConfig.Temperature
                top_p       = $modelConfig.TopP
                num_predict = $modelConfig.MaxTokens
            }
        }
        
        # Your models output line-separated text, not JSON
        # Remove JSON format requirement
        
        $job = Start-Job -ScriptBlock {
            param($apiUrl, $requestBodyJson)
            try {
                Invoke-RestMethod -Uri "$apiUrl/api/chat" -Method Post -Body $requestBodyJson -ContentType 'application/json' -TimeoutSec 30
            }
            catch {
                @{ error = $_.Exception.Message }
            }
        } -ArgumentList $global:OllamaConfig.Server.ApiUrl, ($requestBody | ConvertTo-Json -Depth 10)
        
        $result = $null
        if (Wait-Job $job -Timeout ($TimeoutMs / 1000)) {
            $result = Receive-Job $job
        }
        
        Remove-Job $job -Force
        
        if ($result -and -not $result.error -and $result.message) {
            $latency = ((Get-Date) - $startTime).TotalMilliseconds
            $global:PerformanceMetrics.AverageLatency = ($global:PerformanceMetrics.AverageLatency + $latency) / 2
            $global:PerformanceMetrics.SuccessRate = ($global:PerformanceMetrics.SuccessRate * 0.95) + 0.05
            
            $responseContent = $result.message.content
            
            # Your models output line-separated commands, not JSON
            # Parse as line-separated text
            $completions = $responseContent -split "`n" | 
            Where-Object { $_.Trim() -and $_ -notmatch '^(INPUT:|OUTPUT:|CONTEXT:|SUGGESTIONS:)' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
            
            # Return in consistent format for PowerAuger
            return @{
                completions = $completions
                confidence  = 0.9
                context     = "model_native_format"
            }
        }
        
        # Update failure metrics
        $global:PerformanceMetrics.SuccessRate = $global:PerformanceMetrics.SuccessRate * 0.9
        throw "Ollama request failed or timed out"
    }
    catch {
        if ($global:OllamaConfig.Performance.EnableDebug) {
            Write-Host "⚠️ Ollama request failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        throw
    }
}

function Build-ContextualPrompt {
    [CmdletBinding()]
    param([string]$BasePrompt, [hashtable]$Context, [string]$ModelName)
    
    # Build prompt based on model template
    if ($ModelName -like "*fast*") {
        # Fast model template: "INPUT: {{ .Prompt }}"
        return "INPUT: $BasePrompt"
    }
    elseif ($ModelName -like "*context*") {
        # Context model template: "CONTEXT: pwd=..., files=[...], command=..."
        $contextParts = @()
        
        # Add directory
        if ($Context.Environment.Directory) {
            $contextParts += "pwd=$($Context.Environment.Directory)"
        }
        
        # Add git status if in repo
        if ($Context.Environment.IsGitRepo) {
            $contextParts += "git_status=$($Context.Environment.GitChanges)_changes"
        }
        
        # Add files in directory
        if ($Context.Environment.FilesInDirectory) {
            $fileList = $Context.Environment.FilesInDirectory | ForEach-Object { "*.$($_ -split '\.' | Select-Object -Last 1)" } | Select-Object -Unique | Select-Object -First 5
            $contextParts += "files=[$($fileList -join ', ')]"
        }
        
        # Add recent success patterns (simplified)
        if ($global:RecentTargets) {
            $recentCommands = $global:RecentTargets | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -First 3
            $contextParts += "recent_success=[$($recentCommands -join ', ')]"
        }
        
        # Add the command being completed
        $contextParts += "command=$BasePrompt"
        
        return "CONTEXT: $($contextParts -join ', ')"
    }
    else {
        # Default to fast model format
        return "INPUT: $BasePrompt"
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

        # NEW: Log prediction if enabled
        if ($global:OllamaConfig.Performance.EnablePredictionLogging) {
            $logEntry = @{
                Timestamp    = Get-Date
                InputLine    = $InputLine
                ModelUsed    = $modelConfig.Name
                ResultSource = if ($result.context) { $result.context } else { "unknown" }
                Predictions  = $finalCompletions
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
    Write-Host "Average Latency: $([math]::Round($stats.Performance.AverageLatency, 0))ms" -ForegroundColor White
    Write-Host "Success Rate: $([math]::Round($stats.Performance.SuccessRate * 100, 1))%" -ForegroundColor White
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

function Initialize-OllamaPredictor {
    [CmdletBinding()]
    param(
        [switch]$EnableDebug,
        [switch]$StartTunnel = $true
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
    }
    
    # Register cleanup events
    Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        Save-PowerAugerState
        Stop-OllamaTunnel -Silent
    } | Out-Null
    
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

# Context Provider Registry for future expansion
# This ordered dictionary defines the context providers and their execution order.
# Each value is a scriptblock that accepts a single [hashtable]$Context parameter.
$global:ContextProviders = [ordered]@{
    'Environment' = { param($Context) _Get-EnvironmentContext -Context $Context }
    'Command'     = { param($Context) _Get-CommandContext -Context $Context }
    'FileTarget'  = { param($Context) _Get-FileTargetContext -Context $Context }
    'Git'         = { param($Context) _Get-GitContext -Context $Context }
    # Future providers can be added here: Azure, AWS, Docker, etc.
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
    'Get-PredictionLog' # NEW
)

# Auto-initialize if not in module development mode
if (-not $env:OLLAMA_PREDICTOR_DEV_MODE) {
    Initialize-OllamaPredictor -StartTunnel
}