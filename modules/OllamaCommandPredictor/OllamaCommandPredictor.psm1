# MyCommandPredictor.psm1
# To use this module:

# Save both files in the same directory
# Import the module: Import-Module .\MyCommandPredictor.psd1
# Enable prediction with: Set-PSReadLineOption -PredictionSource HistoryAndPlugin

# Configuration for Ollama models and API
$global:OllamaModels = @{
    FastAutocomplete = 'qwen3:4b-q4_K_M'
    CodeAssistant    = 'bjoernb/qwen3-coder-30b-1m:latest' 
    ThinkingModel    = 'qwen3:30b-a3b-thinking-2507-q4_K_M'
}

# Ollama API configuration  
$global:OllamaApiUrl = 'http://192.168.50.194:11434'  # Your server IP
# NOTE: On your server, run: OLLAMA_HOST=0.0.0.0 ollama serve
# Or set environment variable: export OLLAMA_HOST=0.0.0.0

# Response cache and configuration
$global:OllamaCache = @{}
$global:CacheTimeout = 300 # 5 minutes
$global:OllamaConnectionCache = $null

# Smart defaults cache for fast context
$global:SmartDefaults = @{
    CommandSuccess    = @{}  # Track which commands typically succeed
    DirectoryPatterns = @{} # Common command patterns per directory type
    RecentCommands    = @() # Last 20 commands with timestamps
    ErrorHistory      = @()   # Commands that failed recently
    LastCacheUpdate   = (Get-Date).AddDays(-1)
}

# Context providers for @ triggers
$global:CodeContextProviders = @{
    'files'   = { Get-ChildItem -Name -File | Select-Object -First 20 }
    'dirs'    = { Get-ChildItem -Name -Directory | Select-Object -First 10 }
    'git'     = { 
        if (Test-Path .git) {
            @(
                "Branch - $(git branch --show-current 2>$null)"
                "Status - $(git status --porcelain 2>$null | Measure-Object | Select-Object -ExpandProperty Count) changes"
                "Recent - $(git log --oneline -5 2>$null | ForEach-Object { $_.Split(' ')[1..100] -join ' ' })"
            )
        }
        else { @() }
    }
    'history' = { Get-History -Count 20 | Select-Object -ExpandProperty CommandLine }
    'errors'  = { $global:SmartDefaults.ErrorHistory | Select-Object -First 5 }
    'modules' = { Get-Module | Select-Object -ExpandProperty Name | Select-Object -First 15 }
    'env'     = { 
        @(
            "SSH - $($null -ne $env:SSH_CLIENT)"
            "PWD - $(Get-Location)"
            "User - $env:USERNAME"
            "PS - $($PSVersionTable.PSVersion)"
        )
    }
}

# Default configuration
$global:PredictorConfig = @{
    MaxSuggestions        = 10
    EnableHistoryFallback = $true
    ModelTimeout          = 5000  # milliseconds
    CacheSize             = 100
    EnableSmartDefaults   = $true
}

# Update smart defaults cache
function Update-SmartDefaults {
    $now = Get-Date
    if (($now - $global:SmartDefaults.LastCacheUpdate).TotalMinutes -lt 5) {
        return # Don't update too frequently
    }
    
    try {
        # Update recent commands with success/failure tracking
        $recentHistory = Get-History -Count 20 -ErrorAction SilentlyContinue
        $global:SmartDefaults.RecentCommands = $recentHistory | ForEach-Object {
            @{
                Command   = $_.CommandLine
                Timestamp = $_.StartExecutionTime
                Success   = $null -ne $_.EndExecutionTime
            }
        }
        
        # Track directory patterns
        $currentDir = (Get-Location).Path
        if (-not $global:SmartDefaults.DirectoryPatterns.ContainsKey($currentDir)) {
            $global:SmartDefaults.DirectoryPatterns[$currentDir] = @()
        }
        
        $global:SmartDefaults.LastCacheUpdate = $now
    }
    catch {
        # Ignore cache update errors
    }
}

# Enhanced Ollama connection test with caching
function Test-OllamaConnection {
    # Write-Host "[DEBUG] Testing Ollama connection..." -ForegroundColor Cyan
    
    if ($global:OllamaConnectionCache -and 
        ((Get-Date) - $global:OllamaConnectionCache.LastCheck).TotalSeconds -lt 30) {
        # Write-Host "[DEBUG] Using cached connection result: $($global:OllamaConnectionCache.IsConnected)" -ForegroundColor Cyan
        return $global:OllamaConnectionCache.IsConnected
    }
    
    try {
        Write-Host "[DEBUG] Testing Ollama API at $global:OllamaApiUrl" -ForegroundColor Cyan
        
        # Test Ollama API connection
        $response = Invoke-RestMethod -Uri "$global:OllamaApiUrl/api/tags" -Method Get -TimeoutSec 5
        
        if ($response -and $response.models) {
            Write-Host "[DEBUG] Ollama API connection successful! Found $($response.models.Count) models" -ForegroundColor Green
            $global:OllamaConnectionCache = @{
                IsConnected     = $true
                LastCheck       = Get-Date
                AvailableModels = $response.models.name
            }
            return $true
        }
    }
    catch {
        Write-Host "[DEBUG] Ollama API connection failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Write-Host "[DEBUG] All Ollama connection attempts failed" -ForegroundColor Red
    $global:OllamaConnectionCache = @{
        IsConnected = $false
        LastCheck   = Get-Date
    }
    return $false
}

# Configuration management
function Import-PredictorConfig {
    $configPath = "$env:USERPROFILE\.ollama-predictor-config.json"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content $configPath | ConvertFrom-Json
            foreach ($key in $config.PSObject.Properties.Name) {
                if ($global:PredictorConfig.ContainsKey($key)) {
                    $global:PredictorConfig[$key] = $config.$key
                }
            }
        }
        catch {
            Write-Warning "Failed to load predictor config: $_"
        }
    }
}

# Cache management
function Get-CachedOllamaSuggestions {
    param(
        [string]$CacheKey, 
        [scriptblock]$GenerateSuggestions
    )
    
    $now = Get-Date
    if ($global:OllamaCache.ContainsKey($CacheKey)) {
        $cached = $global:OllamaCache[$CacheKey]
        if (($now - $cached.Timestamp).TotalSeconds -lt $global:CacheTimeout) {
            return $cached.Suggestions
        }
    }
    
    # Clean old cache entries if cache is getting large
    if ($global:OllamaCache.Count -gt $global:PredictorConfig.CacheSize) {
        $oldestKeys = $global:OllamaCache.GetEnumerator() | 
        Sort-Object { $_.Value.Timestamp } | 
        Select-Object -First ($global:OllamaCache.Count - $global:PredictorConfig.CacheSize + 10) |
        ForEach-Object { $_.Key }
        foreach ($key in $oldestKeys) {
            $global:OllamaCache.Remove($key)
        }
    }
    
    $suggestions = & $GenerateSuggestions
    $global:OllamaCache[$CacheKey] = @{
        Suggestions = $suggestions
        Timestamp   = $now
    }
    return $suggestions
}

# Get lightweight context for fast suggestions
function Get-FastContext {
    param([string]$InputLine)
    
    # Update smart defaults periodically
    if ($global:PredictorConfig.EnableSmartDefaults) {
        Update-SmartDefaults
    }
    
    return @{
        InputLine        = $InputLine
        RecentCommands   = $global:SmartDefaults.RecentCommands | Select-Object -First 10
        CurrentDirectory = Get-Location
        IsSSH            = $null -ne $env:SSH_CLIENT
        IsGitRepo        = Test-Path .git
        LastError        = $global:SmartDefaults.ErrorHistory | Select-Object -First 1
    }
}

# Get rich context for code suggestions (@triggers)
function Get-CodeContext {
    param([string]$Provider, [string]$Query)
    
    $context = Get-FastContext -InputLine $Query
    $context.Provider = $Provider
    $context.Query = $Query
    
    # Add provider-specific context
    if ($global:CodeContextProviders.ContainsKey($Provider)) {
        try {
            $context.ProviderData = & $global:CodeContextProviders[$Provider]
        }
        catch {
            $context.ProviderData = @("Error loading $Provider context")
        }
    }
    else {
        # Default provider includes multiple contexts
        $context.ProviderData = @{
            Files  = & $global:CodeContextProviders['files']
            Git    = & $global:CodeContextProviders['git']
            Recent = & $global:CodeContextProviders['history']
        }
    }
    
    return $context
}

# Legacy function for compatibility (simplified)
function Get-CommandContext {
    param(
        [string]$InputLine,
        [int]$CursorIndex
    )
    
    return Get-FastContext -InputLine $InputLine
    
    # Extract current word being typed
    if ($CursorIndex -gt 0) {
        $beforeCursor = $InputLine.Substring(0, $CursorIndex)
        $words = $beforeCursor.Trim() -split '\s+'
        if ($words.Count -gt 0) {
            $context.CurrentWord = $words[-1]
            $context.PreviousWords = $words[0..($words.Count - 2)]
        }
    }
    
    # Extract command prefix (first word)
    if ($InputLine.Trim() -match '^\w+') {
        $context.CommandPrefix = $matches[0]
    }
    
    # Legacy compatibility - just return fast context
    return $context
}

# Simple Ollama request function
function Invoke-OllamaRequest {
    param(
        [string]$Model,
        [string]$Prompt,
        [int]$TimeoutMs = 5000
    )
    
    try {
        $job = Start-Job -ScriptBlock {
            param($apiUrl, $model, $prompt)
            try {
                # Use Ollama HTTP API
                $requestBody = @{
                    model  = $model
                    prompt = $prompt
                    stream = $false
                } | ConvertTo-Json
                
                $response = Invoke-RestMethod -Uri "$apiUrl/api/generate" -Method Post -Body $requestBody -ContentType 'application/json' -TimeoutSec 30
                return $response.response
            }
            catch {
                return $null
            }
        } -ArgumentList $global:OllamaApiUrl, $Model, $Prompt
        
        $result = $null
        if (Wait-Job $job -Timeout ($TimeoutMs / 1000)) {
            $result = Receive-Job $job
        }
        Remove-Job $job -Force
        
        if ($result) {
            return $result -split "`n" | 
            Where-Object { $_ -notmatch "^\s*$" } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_.Length -gt 0 }
        }
        
        return @()
    }
    catch {
        return @()
    }
}

# Fast suggestions using lightweight model
function Get-FastSuggestions {
    param([string]$InputLine)
    
    # Quick history-based suggestions first
    $historySuggestions = Get-HistorySuggestions -InputLine $InputLine -CursorIndex 0
    if ($historySuggestions.Count -gt 0) {
        return $historySuggestions | Select-Object -First 3
    }
    
    # Check if Ollama is available
    if (-not (Test-OllamaConnection)) {
        return @()
    }
    
    # Create cache key
    $cacheKey = "fast_$($InputLine.GetHashCode())"
    
    return Get-CachedOllamaSuggestions -CacheKey $cacheKey -GenerateSuggestions {
        $context = Get-FastContext -InputLine $InputLine
        
        $prompt = @"
Complete this PowerShell command: '$InputLine'
Context:
- Recent: $($context.RecentCommands | Select-Object -First 3 | ForEach-Object { $_.Command } | Join-String -Separator ', ')
- Directory: $($context.CurrentDirectory)
- Git repo: $($context.IsGitRepo)

Suggest 5-8 command completions, one per line:
"@
        
        return Invoke-OllamaRequest -Model $global:OllamaModels.FastAutocomplete -Prompt $prompt
    }
}

# Code suggestions with rich context (@trigger)
function Get-CodeSuggestions {
    param([string]$Provider = 'default', [string]$Query)
    
    # Check if Ollama is available
    if (-not (Test-OllamaConnection)) {
        return Get-HistorySuggestions -InputLine $Query -CursorIndex 0
    }
    
    # Create cache key
    $cacheKey = "code_${Provider}_$($Query.GetHashCode())"
    
    return Get-CachedOllamaSuggestions -CacheKey $cacheKey -GenerateSuggestions {
        $context = Get-CodeContext -Provider $Provider -Query $Query
        
        $contextStr = if ($context.ProviderData -is [hashtable]) {
            $context.ProviderData.GetEnumerator() | ForEach-Object {
                "- $($_.Key): $($_.Value -join ', ')"
            } | Join-String -Separator "`n"
        }
        else {
            "- $Provider`: $($context.ProviderData -join ', ')"
        }
        
        $prompt = @"
PowerShell command assistance for: '$Query'
Context:
$contextStr
- Directory: $($context.CurrentDirectory)
- SSH: $($context.IsSSH)

Suggest relevant PowerShell commands, one per line:
"@
        
        return Invoke-OllamaRequest -Model $global:OllamaModels.CodeAssistant -Prompt $prompt
    }
}

# Thinking suggestions for analysis (%trigger)
function Get-ThinkingSuggestions {
    param([string]$Query)
    
    Write-Host "[DEBUG] Get-ThinkingSuggestions called with: '$Query'" -ForegroundColor Magenta
    
    # Check if Ollama is available
    if (-not (Test-OllamaConnection)) {
        Write-Host "[DEBUG] Ollama connection failed, returning fallback" -ForegroundColor Red
        return @("Ollama not available for analysis")
    }
    
    # Create cache key
    $cacheKey = "think_$($Query.GetHashCode())"
    
    return Get-CachedOllamaSuggestions -CacheKey $cacheKey -GenerateSuggestions {
        $context = Get-FastContext -InputLine $Query
        
        $prompt = @"
Analyze this PowerShell task: '$Query'
Environment:
- Directory: $($context.CurrentDirectory)
- Git repo: $($context.IsGitRepo)
- SSH session: $($context.IsSSH)
- Recent commands: $($context.RecentCommands | Select-Object -First 5 | ForEach-Object { $_.Command } | Join-String -Separator ', ')

Suggest strategic PowerShell commands to accomplish this, one per line:
"@
        
        return Invoke-OllamaRequest -Model $global:OllamaModels.ThinkingModel -Prompt $prompt -TimeoutMs 15000
    }
}

# History-based fallback suggestions
function Get-HistorySuggestions {
    param(
        [string]$InputLine,
        [int]$CursorIndex
    )
    
    if ([string]::IsNullOrWhiteSpace($InputLine)) {
        try {
            return Get-History | Select-Object -ExpandProperty CommandLine -First 5 | Select-Object -Unique
        }
        catch {
            return @()
        }
    }
    
    try {
        return Get-History | 
        Select-Object -ExpandProperty CommandLine |
        Where-Object { $_ -like "$InputLine*" } |
        Select-Object -Unique -First 5
    }
    catch {
        return @()
    }
}

# Main predictor function that PSReadLine will call
# Simple trigger-based main function
# function Get-CommandPrediction {
#     param(
#         [string]$InputLine,
#         [int]$CursorIndex
#     )
    
#     # Write-Host "[DEBUG] Get-CommandPrediction called with: '$InputLine'" -ForegroundColor Yellow
    
#     # Empty input - show recent history
#     if ([string]::IsNullOrWhiteSpace($InputLine)) {
#         # Write-Host "[DEBUG] Empty input, returning history" -ForegroundColor Yellow
#         return Get-HistorySuggestions -InputLine "" -CursorIndex 0
#     }
    
#     # Handle ai: trigger for code suggestions (ai:files compress)
#     if ($InputLine -match '^ai:(\w+)?\s*(.*)') {
#         $provider = if ($matches[1]) { $matches[1] } else { 'default' }
#         $query = $matches[2]
#         Write-Host "[DEBUG] ai: trigger detected: provider='$provider', query='$query'" -ForegroundColor Yellow
#         return Get-CodeSuggestions -Provider $provider -Query $query
#     }
    
#     # Handle ask: trigger for thinking suggestions (ask: how do I...)
#     if ($InputLine -match '^ask:\s*(.+)') {
#         $query = $matches[1]
#         Write-Host "[DEBUG] ask: trigger detected: query='$query'" -ForegroundColor Yellow
#         return Get-ThinkingSuggestions -Query $query
#     }
    
#     # Default: Fast suggestions with lightweight context
#     # Write-Host "[DEBUG] Using fast suggestions for: '$InputLine'" -ForegroundColor Yellow
#     return Get-FastSuggestions -InputLine $InputLine
# }

function Get-CommandPrediction {
    param(
        [string]$InputLine,
        [int]$CursorIndex
    )
    
    # 1. Parse the input line into command and arguments
    $tokens = $InputLine.Trim() -split '\s+'
    $commandName = $tokens[0]
    $arguments = $tokens[1..($tokens.Count - 1)]

    # 2. Check if the command is a real command
    $commandInfo = Get-Command $commandName -ErrorAction SilentlyContinue
    
    $dynamicContext = @{}
    if ($commandInfo) {
        # 3. If it's a real command, get its syntax and parameters!
        # This is the dynamic help injection you mentioned.
        $dynamicContext.CommandSyntax = $commandInfo.Syntax
        $dynamicContext.Parameters = $commandInfo.Parameters.Keys
    }

    # 4. Identify the target of the command
    # Find the last argument that looks like a file/directory path
    $targetPath = $arguments | Where-Object { Test-Path $_ -IsValid } | Select-Object -Last 1
    if ($targetPath) {
        $dynamicContext.TargetInfo = Get-Item $targetPath | Select-Object Name, Length, LastWriteTime, Attributes
    }

    # ... now pass this $dynamicContext to Get-FastSuggestions to be used in the prompt ...
    return Get-FastSuggestions -InputLine $InputLine -DynamicContext $dynamicContext
}

function Get-RecentTargets {
    # Scan the last 200 commands from our log
    $history = Get-Content $global:CommandHistoryLogPath -Tail 200 | ConvertFrom-Json
    
    $targets = @()
    $pathRegex = '(\w+:\\|\\|\.\.?\\|/)[\\\w\s\.\-]+' # Basic regex for paths

    foreach ($entry in $history) {
        # Find all path-like strings in the command
        $matches = [regex]::Matches($entry.Command, $pathRegex)
        foreach ($match in $matches) {
            # Add valid paths to our list
            if (Test-Path $match.Value) {
                $targets += $match.Value
            }
        }
    }

    # Return the top 10 most recent, unique targets
    return $targets | Select-Object -Unique -Last 10
}
# Initialize configuration on module load
Import-PredictorConfig


# Export the function so it can be used by PSReadLine
Export-ModuleMember -Function Get-CommandPrediction

# Add this to the end of the .psm1 module file

$global:CommandHistoryLogPath = Join-Path $env:LOCALAPPDATA 'OllamaPredictor_CommandLog.jsonl'

function Log-LastCommand {
    # Get details about the last executed command from history
    $lastCmd = Get-History -Count 1
    if (-not $lastCmd) { return }

    # Capture the most important context: did it succeed?
    $wasSuccess = $? # PowerShell's automatic variable for last command success (True/False)
    $errorMessage = ""
    if (-not $wasSuccess) {
        # Get the last error message if it failed
        $errorMessage = ($error[0] | Out-String) -replace '\s+', ' '
    }

    $logEntry = @{
        Timestamp = (Get-Date -Format 'o') # ISO 8601 format
        Command   = $lastCmd.CommandLine
        Success   = $wasSuccess
        Error     = $errorMessage
        Directory = (Get-Location).Path
    }

    # Append to a JSON Lines file (each line is a complete JSON object)
    $logEntry | ConvertTo-Json -Compress | Add-Content -Path $global:CommandHistoryLogPath
    
    # Prune the log to keep it from growing indefinitely (e.g., keep last 200-500 lines)
    # (This logic can be added to run periodically)
}

# Register our function to run every time the prompt is displayed
Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action { Log-LastCommand } | Out-Null
