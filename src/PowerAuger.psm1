# PowerAuger.psm1 - Proper predictor plugin with Ollama

using namespace System.Management.Automation.Subsystem
using namespace System.Management.Automation.Subsystem.Prediction

# Logging function - must be defined before the class
function Write-PowerAugerLog {
    param(
        [string]$Level = "Info",
        [string]$Component,
        [string]$Message,
        [object]$Data = $null
    )

    # Check if logging is enabled for this level...
    # TODO take off debug when finished debugging
    $logLevels = @{ Debug = 0; Info = 1; Warning = 2; Error = 3 }
    $currentLevel = if ([PowerAugerPredictor]::LogLevel) {
        $logLevels[[PowerAugerPredictor]::LogLevel]
    } else {
        $logLevels["Debug"]
    }

    if ($logLevels[$Level] -lt $currentLevel) { return }

    # Prepare log entry
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "$timestamp [$Level] [$Component] $Message"

    if ($Data) {
        $logEntry += " | Data: $(if ($Data -is [hashtable] -or $Data -is [PSObject]) {
            $Data | ConvertTo-Json -Compress -Depth 3
        } else {
            $Data.ToString()
        })"
    }

    # Determine log file
    $logPath = [PowerAugerPredictor]::GetLogPath()
    if (-not (Test-Path $logPath)) {
        New-Item -ItemType Directory -Path $logPath -Force | Out-Null
    }

    $logFile = switch ($Component) {
        "TabExpansion2" { Join-Path $logPath "tabexpansion2.log" }
        "OllamaAPI" { Join-Path $logPath "ollama_api.log" }
        default { Join-Path $logPath "powerauger.log" }
    }

    # Write to file (append for current session)
    try {
        $logEntry | Add-Content -Path $logFile -Encoding UTF8
    } catch {
        # Log to console if file write fails
        Write-Host "[LOG ERROR] Failed to write to $logFile : $_" -ForegroundColor Red
        Write-Host $logEntry -ForegroundColor Yellow
    }

    # Also output to console if Warning or Error
    if ($Level -in @("Warning", "Error")) {
        Write-Host $logEntry -ForegroundColor $(if ($Level -eq "Error") { "Red" } else { "Yellow" })
    }
}

class PowerAugerPredictor : ICommandPredictor {
    [guid] $Id
    [string] $Name
    [string] $Description

    # Removed simple cache - using contextual history instead

    # Configuration
    hidden static [string] $Model = "qwen2.5-0.5B-autocomplete-custom"
    hidden static [string] $ApiUrl = "http://127.0.0.1:11434"

    # Logging configuration
    hidden static [string] $LogLevel = "Debug"  # Debug, Info, Warning, Error
    hidden static [string] $_LogPath = ""  # Private backing field
    hidden static [hashtable] $LogLevels = @{
        Debug = 0
        Info = 1
        Warning = 2
        Error = 3
    }

    # Persistent contextual history path
    hidden static [string] $ContextualHistoryPath = "$env:LOCALAPPDATA\PowerAuger\contextual_history.json"

    # History context
    hidden static [System.Collections.Concurrent.ConcurrentBag[object]] $HistoryExamples = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

    # Enhanced contextual learning system (hashtable with command|path keys)
    hidden static [hashtable] $ContextualHistory = [hashtable]::Synchronized(@{})
    hidden static [int] $MaxContextualHistorySize = 300

    # Background prediction infrastructure with thread-safe message passing
    hidden static [System.Management.Automation.Runspaces.Runspace] $PredictionRunspace = $null
    hidden static [System.Management.Automation.PowerShell] $PredictionPowerShell = $null

    # Thread-safe message queues for communication with background runspace
    hidden static [System.Collections.Concurrent.BlockingCollection[hashtable]] $MessageQueue = [System.Collections.Concurrent.BlockingCollection[hashtable]]::new(100)  # Max 100 items
    hidden static [System.Collections.Concurrent.BlockingCollection[hashtable]] $LogQueue = [System.Collections.Concurrent.BlockingCollection[hashtable]]::new(200)  # Async logging queue
    hidden static [System.Collections.Concurrent.ConcurrentDictionary[string,object]] $ResponseCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

    # Channel for real-time updates (PowerShell 7+)
    hidden static [System.Threading.Channels.Channel[hashtable]] $UpdateChannel = [System.Threading.Channels.Channel]::CreateUnbounded[hashtable]()

    # Cancellation token for clean shutdown
    hidden static [System.Threading.CancellationTokenSource] $CancellationSource = [System.Threading.CancellationTokenSource]::new()

    # Shutdown mutex for cleanup synchronization
    hidden static [System.Threading.Mutex] $ShutdownMutex = [System.Threading.Mutex]::new($false)

    # Background running state
    hidden static [bool] $IsBackgroundRunning = $false

    # Static method to get LogPath (workaround for PowerShell static property limitations)
    hidden static [string] GetLogPath() {
        if (-not [PowerAugerPredictor]::_LogPath) {
            [PowerAugerPredictor]::_LogPath = "$env:LOCALAPPDATA\PowerAuger\logs"
        }
        return [PowerAugerPredictor]::_LogPath
    }

    PowerAugerPredictor() {
        $this.Id = [guid]::Parse('a1b2c3d4-e5f6-7890-abcd-ef1234567890')
        $this.Name = 'PowerAuger'
        $this.Description = 'Ollama-powered AI completions with history learning'

        # Clear logs at session start
        try {
            $logPath = [PowerAugerPredictor]::GetLogPath()
            if (-not (Test-Path $logPath)) {
                New-Item -ItemType Directory -Path $logPath -Force | Out-Null
            }
            # Clear existing log files for fresh session
            @("tabexpansion2.log", "ollama_api.log", "powerauger.log") | ForEach-Object {
                $logFile = Join-Path $logPath $_
                if (Test-Path $logFile) {
                    Clear-Content -Path $logFile -Force
                }
            }
        } catch {
            Write-Warning "Failed to clear log files: $_"
        }

        Write-PowerAugerLog -Level "Info" -Component "Initialization" -Message "PowerAuger predictor starting"

        # Load contextual history from disk
        try {
            if (Test-Path ([PowerAugerPredictor]::ContextualHistoryPath)) {
                $historyData = Get-Content ([PowerAugerPredictor]::ContextualHistoryPath) -Raw | ConvertFrom-Json -AsHashtable
                foreach ($key in $historyData.Keys) {
                    [PowerAugerPredictor]::ContextualHistory[$key] = $historyData[$key]
                }
                Write-PowerAugerLog -Level "Info" -Component "Initialization" `
                    -Message "Loaded $([PowerAugerPredictor]::ContextualHistory.Count) contextual history entries"
            }
        } catch {
            Write-PowerAugerLog -Level "Warning" -Component "Initialization" `
                -Message "Failed to load contextual history" -Data $_
        }

        # Pre-load some history examples on initialization
        $this.LoadHistoryExamples()

        # Start background prediction engine if not already running
        if (-not [PowerAugerPredictor]::IsBackgroundRunning) {
            Write-PowerAugerLog -Level "Info" -Component "Initialization" -Message "Starting background engine"
            $this.StartBackgroundPredictionEngine()
            Write-PowerAugerLog -Level "Info" -Component "Initialization" -Message "Background engine started: $([PowerAugerPredictor]::IsBackgroundRunning)"
        }

        Write-PowerAugerLog -Level "Info" -Component "Initialization" -Message "Constructor completed successfully"
    }

    hidden [hashtable] GetStandardizedContext([string]$inputText, [int]$cursorPos, $tabCompletions = $null) {
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            # Only call TabExpansion2 if not provided and input is long enough
            if ($null -eq $tabCompletions -and $inputText.Length -ge [PowerAugerPredictor]::MinTabExpansionLength) {
                if (Get-Command TabExpansion2 -ErrorAction SilentlyContinue) {
                    $tabStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    $tabCompletions = TabExpansion2 -inputScript $inputText -cursorColumn $cursorPos
                    $tabStopwatch.Stop()

                    Write-PowerAugerLog -Level "Debug" -Component "TabExpansion2" `
                        -Message "TabExpansion2 took $($tabStopwatch.ElapsedMilliseconds)ms" `
                        -Data @{
                            Input = $inputText
                            CursorPos = $cursorPos
                            MatchCount = if ($tabCompletions) { $tabCompletions.CompletionMatches.Count } else { 0 }
                        }
                }
            }

            # Group completions by type (first 3 of each group for consistency)
            $contextGroups = @{}
            if ($tabCompletions -and $tabCompletions.CompletionMatches.Count -gt 0) {
                $groups = $tabCompletions.CompletionMatches | Group-Object ResultType
                foreach ($group in $groups | Select-Object -First 3) {
                    $contextGroups[$group.Name] = $group.Group |
                        Select-Object -First 3 -ExpandProperty CompletionText
                }
            }

            $stopwatch.Stop()
            Write-PowerAugerLog -Level "Debug" -Component "Context" `
                -Message "Context building took $($stopwatch.ElapsedMilliseconds)ms"

            # Build standardized context
            return @{
                Groups = $contextGroups
                Directory = $PWD.Path
                IsGitRepo = (Test-Path (Join-Path $PWD.Path ".git"))
                DirName = (Split-Path $PWD.Path -Leaf)
                Timestamp = Get-Date
                TabCompletions = $tabCompletions  # Pass along to avoid duplicate call
            }
        }
        catch {
            Write-PowerAugerLog -Level "Error" -Component "Context" `
                -Message "Failed to build context" -Data $_

            # Return minimal context on error
            return @{
                Groups = @{}
                Directory = $PWD.Path
                IsGitRepo = $false
                DirName = (Split-Path $PWD.Path -Leaf)
                Timestamp = Get-Date
                TabCompletions = $null
            }
        }
    }

    hidden [string] BuildContextAwarePrompt([string]$inputText, [hashtable]$currentContext) {
        $prompt = ""

        # Build compact TabExpansion2 context - just grab completion texts
        $tabContext = ""
        if ($currentContext.TabCompletions -and $currentContext.TabCompletions.CompletionMatches.Count -gt 0) {
            # Just take first 50 completion texts, no filtering
            $completions = $currentContext.TabCompletions.CompletionMatches |
                Select-Object -First 50 -ExpandProperty CompletionText
            $tabContext = ($completions -join ',')
        }

        # Find matching contexts from history with same path
        $exactMatches = @()
        foreach ($kvp in [PowerAugerPredictor]::ContextualHistory.GetEnumerator()) {
            $entry = $kvp.Value
            if ($entry.Context -and $entry.Context.Directory -eq $currentContext.Directory) {
                $exactMatches += $entry
            }
        }

        # Sort by acceptance count and take top 2
        $exactMatches = $exactMatches | Sort-Object -Property AcceptedCount -Descending | Select-Object -First 2

        # Add history examples with full context format
        foreach ($match in $exactMatches) {
            if ($match.Input -and $match.Completion) {
                # Build historical context from stored completions
                $histContext = ""
                if ($match.Context.TabCompletions -and $match.Context.TabCompletions.CompletionMatches.Count -gt 0) {
                    $histCompletions = $match.Context.TabCompletions.CompletionMatches |
                        Select-Object -First 50 -ExpandProperty CompletionText
                    $histContext = ($histCompletions -join ',')
                }
                $prompt += "<|fim_prefix|>$($match.Context.Directory)|$histContext|$($match.Input)<|fim_suffix|><|fim_middle|>$($match.Completion)`n"
            }
        }

        # Add current request with full context
        $prompt += "<|fim_prefix|>$($currentContext.Directory)|$tabContext|$inputText<|fim_suffix|><|fim_middle|>"

        return $prompt
    }

    hidden [void] StartBackgroundPredictionEngine() {
        try {
            # Create runspace for background predictions
            [PowerAugerPredictor]::PredictionRunspace = [runspacefactory]::CreateRunspace()
            [PowerAugerPredictor]::PredictionRunspace.Open()

            # Pass thread-safe message queues and channel to the runspace
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('MessageQueue', [PowerAugerPredictor]::MessageQueue)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('LogQueue', [PowerAugerPredictor]::LogQueue)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('ResponseCache', [PowerAugerPredictor]::ResponseCache)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('UpdateChannel', [PowerAugerPredictor]::UpdateChannel)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('CancellationToken', [PowerAugerPredictor]::CancellationSource.Token)

            # Pass read-only configuration values (not shared references)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('Model', [PowerAugerPredictor]::Model)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('ApiUrl', [PowerAugerPredictor]::ApiUrl)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('LogLevel', [PowerAugerPredictor]::LogLevel)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('LogPath', [PowerAugerPredictor]::GetLogPath())

            # Create deep copies of history for the background runspace
            $historyCopy = @()
            foreach ($item in [PowerAugerPredictor]::HistoryExamples) {
                $historyCopy += @{ Prefix = $item.Prefix; Completion = $item.Completion }
            }
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('HistoryExamples', $historyCopy)

            # Create a snapshot of contextual history
            $contextHistoryCopy = @{}
            foreach ($key in [PowerAugerPredictor]::ContextualHistory.Keys) {
                $value = [PowerAugerPredictor]::ContextualHistory[$key]
                $contextHistoryCopy[$key] = @{
                    FullCommand = $value.FullCommand
                    Input = $value.Input
                    Completion = $value.Completion
                    Context = if ($value.Context) { $value.Context.Clone() } else { $null }
                    AcceptedCount = $value.AcceptedCount
                    LastUsed = $value.LastUsed
                }
            }
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('ContextualHistory', $contextHistoryCopy)

            # Create the background script with proper message passing
            $backgroundScript = {
                # Define logging function for background runspace
                function Write-BackgroundLog {
                    param(
                        [string]$Level = "Info",
                        [string]$Component,
                        [string]$Message,
                        [object]$Data = $null
                    )

                    $logLevels = @{ Debug = 0; Info = 1; Warning = 2; Error = 3 }
                    $currentLevel = $logLevels[$LogLevel]
                    if ($logLevels[$Level] -lt $currentLevel) { return }

                    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
                    $logEntry = "$timestamp [$Level] [BG:$Component] $Message"

                    if ($Data) {
                        $logEntry += " | Data: $(if ($Data -is [hashtable] -or $Data -is [PSObject]) {
                            $Data | ConvertTo-Json -Compress -Depth 3
                        } else {
                            $Data.ToString()
                        })"
                    }

                    $logFile = switch ($Component) {
                        "TabExpansion2" { Join-Path $LogPath "tabexpansion2.log" }
                        "OllamaAPI" { Join-Path $LogPath "ollama_api.log" }
                        default { Join-Path $LogPath "powerauger.log" }
                    }

                    try {
                        $logEntry | Add-Content -Path $logFile -Encoding UTF8
                    } catch {}
                }

                # Local cache for the background runspace (not shared)
                $localCache = @{}
                $lastSaveTime = Get-Date
                $saveIntervalMinutes = 5

                # Check for cancellation
                while (-not $CancellationToken.IsCancellationRequested) {
                    try {
                        # Process log messages first (non-blocking)
                        $logRequest = $null
                        while ($LogQueue.TryTake([ref]$logRequest, 0)) {  # 0ms timeout, drain all logs
                            try {
                                # Write the log using the background log function
                                if ($logRequest.Data) {
                                    Write-BackgroundLog -Level $logRequest.Level -Component $logRequest.Component `
                                        -Message $logRequest.Message -Data $logRequest.Data
                                } else {
                                    Write-BackgroundLog -Level $logRequest.Level -Component $logRequest.Component `
                                        -Message $logRequest.Message
                                }
                            } catch {
                                # Silent fail on log errors
                            }
                        }

                        # Use BlockingCollection for thread-safe message retrieval with cancellation support
                        $request = $null
                        if ($MessageQueue.TryTake([ref]$request, 200, $CancellationToken)) {
                            # Get context for this request if provided
                            $currentContext = $request.Context
                            if (-not $currentContext) {
                                # Fallback to simple context if not provided
                                $currentContext = @{
                                    Groups = @{}
                                    Directory = $PWD.Path
                                    DirName = (Split-Path $PWD.Path -Leaf)
                                    IsGitRepo = $false
                                }
                            }

                            # Build FIM prompt with full context
                            $fimPrompt = ""

                            # Get TabExpansion2 completions for context (quick and dirty)
                            $tabContext = ""
                            try {
                                $tabCompletions = TabExpansion2 -inputScript $request.Input -cursorColumn $request.Input.Length
                                if ($tabCompletions -and $tabCompletions.CompletionMatches.Count -gt 0) {
                                    # Just grab first 50 completion texts
                                    $completions = $tabCompletions.CompletionMatches |
                                        Select-Object -First 50 -ExpandProperty CompletionText
                                    $tabContext = ($completions -join ',')
                                }
                            } catch {
                                # Ignore TabExpansion2 errors
                            }

                            # Find matching contexts from history with same directory
                            $exactMatches = @()
                            foreach ($kvp in $ContextualHistory.GetEnumerator()) {
                                $entry = $kvp.Value
                                if ($entry.Context -and $entry.Context.Directory -eq $currentContext.Directory) {
                                    $exactMatches += $entry
                                }
                            }

                            # Sort and take top 2 matches
                            $exactMatches = $exactMatches | Sort-Object -Property AcceptedCount -Descending | Select-Object -First 2

                            # Add history examples with full context
                            foreach ($match in $exactMatches) {
                                if ($match.Input -and $match.Completion) {
                                    # Get stored completions if available
                                    $histContext = ""
                                    if ($match.Context.TabCompletions -and $match.Context.TabCompletions.CompletionMatches.Count -gt 0) {
                                        $histCompletions = $match.Context.TabCompletions.CompletionMatches |
                                            Select-Object -First 50 -ExpandProperty CompletionText
                                        $histContext = ($histCompletions -join ',')
                                    }
                                    $fimPrompt += "<|fim_prefix|>$($match.Context.Directory)|$histContext|$($match.Input)<|fim_suffix|><|fim_middle|>$($match.Completion)`n"
                                }
                            }

                            # Add current request with full context
                            $fimPrompt += "<|fim_prefix|>$($currentContext.Directory)|$tabContext|$($request.Input)<|fim_suffix|><|fim_middle|>"

                            # Call Ollama API
                            $body = @{
                                model = $Model
                                prompt = $fimPrompt
                                stream = $false
                                options = @{
                                    num_predict = 80
                                    temperature = 0.2
                                    top_p = 0.9
                                }
                            } | ConvertTo-Json -Depth 3

                            Write-BackgroundLog -Level "Debug" -Component "OllamaAPI" `
                                -Message "Sending request" -Data @{
                                    Input = $request.Input
                                    PromptLength = $fimPrompt.Length
                                    Model = $Model
                                }

                            $apiStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $response = Invoke-RestMethod -Uri "$ApiUrl/api/generate" `
                                                         -Method Post -Body $body `
                                                         -ContentType 'application/json' `
                                                         -TimeoutSec 5 -ErrorAction Stop
                            $apiStopwatch.Stop()

                            Write-BackgroundLog -Level "Debug" -Component "OllamaAPI" `
                                -Message "Response received in $($apiStopwatch.ElapsedMilliseconds)ms" `
                                -Data @{
                                    ResponseLength = if ($response.response) { $response.response.Length } else { 0 }
                                    TotalDuration = $response.total_duration
                                    LoadDuration = $response.load_duration
                                    EvalDuration = $response.eval_duration
                                }

                            if ($response.response) {
                                # Add to local cache
                                $localCache[$request.Input] = @{
                                    Completion = $response.response.Trim()
                                    Timestamp = Get-Date
                                }

                                # Send response back through thread-safe dictionary
                                $responseData = @{
                                    Completion = $response.response.Trim()
                                    Timestamp = Get-Date
                                }
                                [void]$ResponseCache.TryAdd($request.Input, $responseData)

                                # Send update through channel for real-time notification
                                $updateMessage = @{
                                    Type = 'PredictionComplete'
                                    Input = $request.Input
                                    Completion = $response.response.Trim()
                                    QueueCount = $MessageQueue.Count
                                    Timestamp = Get-Date
                                }
                                [void]$UpdateChannel.Writer.TryWrite($updateMessage)
                            }
                        }

                        # Send startup notification (removed broken pre-warming)
                        if ($localCache.Count -eq 0 -and -not $localCache.ContainsKey('_initialized')) {
                            # Send startup notification
                            [void]$UpdateChannel.Writer.TryWrite(@{
                                Type = 'BackgroundStarted'
                                QueueCount = $MessageQueue.Count
                            })
                            # Mark that we've initialized
                            $localCache['_initialized'] = @{ Completion = "true"; Timestamp = Get-Date }
                        }

                        # Keep response cache synchronized but don't save to disk
                        if ((Get-Date) - $lastSaveTime -gt [TimeSpan]::FromMinutes($saveIntervalMinutes)) {
                            try {
                                # Sync local cache to ResponseCache for main thread access
                                if ($localCache.Count -gt 1) {
                                    foreach ($key in $localCache.Keys) {
                                        if ($key -notmatch '^_') {
                                            [void]$ResponseCache.TryAdd($key, $localCache[$key])
                                        }
                                    }
                                    $lastSaveTime = Get-Date
                                }
                            } catch {
                                # Silent fail - don't disrupt background processing
                            }
                        }

                        # No sleep needed - BlockingCollection.TryTake handles timeout
                    }
                    catch [System.OperationCanceledException] {
                        # Clean cancellation requested
                        break
                    }
                    catch {
                        # Continue on error unless cancelled
                        if ($CancellationToken.IsCancellationRequested) { break }
                        Start-Sleep -Milliseconds 500
                    }
                }

                # Cleanup on exit
                try {
                    # Send shutdown notification
                    [void]$UpdateChannel.Writer.TryWrite(@{
                        Type = 'BackgroundStopping'
                        QueueCount = 0
                    })

                    # No longer saving old cache file - using contextual history instead

                    # Complete the channel
                    $UpdateChannel.Writer.TryComplete()
                } catch {}

                Write-Host "Background prediction engine stopped cleanly" -ForegroundColor Yellow
            }

            # Start the background PowerShell
            [PowerAugerPredictor]::PredictionPowerShell = [PowerShell]::Create()
            [PowerAugerPredictor]::PredictionPowerShell.Runspace = [PowerAugerPredictor]::PredictionRunspace

            # Add script and begin invoke - NO ARGUMENTS since we're using shared variables
            [void][PowerAugerPredictor]::PredictionPowerShell.AddScript($backgroundScript)

            [void][PowerAugerPredictor]::PredictionPowerShell.BeginInvoke()
            [PowerAugerPredictor]::IsBackgroundRunning = $true
        }
        catch {
            # Background engine failed to start, fall back to sync mode
            [PowerAugerPredictor]::IsBackgroundRunning = $false
        }
    }

    hidden [void] LoadHistoryExamples() {
        try {
            $history = Get-History -Count 50 -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine.Length -gt [PowerAugerPredictor]::MinHistoryExampleLength }

            [PowerAugerPredictor]::HistoryExamples.Clear()

            foreach ($cmd in $history | Select-Object -Last 20) {
                $line = $cmd.CommandLine
                # Find good split points for FIM examples
                if ($line.Length -gt [PowerAugerPredictor]::MinSplitLength) {
                    $splitPoint = [Math]::Floor($line.Length * 0.6)
                    [PowerAugerPredictor]::HistoryExamples.Add(@{
                        Prefix = $line.Substring(0, $splitPoint)
                        Completion = $line.Substring($splitPoint)
                    })
                }
            }
        } catch {
            Write-PowerAugerLog -Level "Warning" -Component "LoadHistoryExamples" `
                -Message "Failed to load history examples" -Data $_
        }
    }

    [SuggestionPackage] GetSuggestion([PredictionClient] $client, [PredictionContext] $context, [System.Threading.CancellationToken] $cancellationToken) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # Get the input text
            $inputText = $context.InputAst.Extent.Text

            # Queue log message instead of direct file I/O
            [void][PowerAugerPredictor]::LogQueue.TryAdd(@{
                Level = "Debug"
                Component = "GetSuggestion"
                Message = "Called with input: $inputText"
                Timestamp = Get-Date
            }, 0)

            # Generate context for this input (will call TabExpansion2 once)
            $currentContext = $this.GetStandardizedContext($inputText, $inputText.Length, $null)

            # Create suggestions list
            $suggestions = [System.Collections.Generic.List[PredictiveSuggestion]]::new()

            # Use TabExpansion2 results from context (avoiding duplicate call!)
            $tabCompletions = $currentContext.TabCompletions
            try {

                if ($tabCompletions -and $tabCompletions.CompletionMatches.Count -gt 0) {
                    # Group by type and get commands first
                    $commands = $tabCompletions.CompletionMatches |
                        Where-Object { $_.ResultType -eq [System.Management.Automation.CompletionResultType]::Command } |
                        Select-Object -First 5

                    # If no commands, take whatever we got
                    if ($commands.Count -eq 0) {
                        $commands = $tabCompletions.CompletionMatches | Select-Object -First 5
                    }

                    # Enhance with contextual history
                    foreach ($tab in $commands) {
                        if ($suggestions.Count -ge 3) { break }

                        # Extract command name (first word)
                        $cmdName = if ($tab.ResultType -eq [System.Management.Automation.CompletionResultType]::Command) {
                            $tab.CompletionText
                        } else {
                            ($inputText -split '\s+')[0]
                        }

                        # Try to find in contextual history with new key format
                        $historyKey = "$($PWD.Path)|$($tab.CompletionText)"

                        $history = if ([PowerAugerPredictor]::ContextualHistory.ContainsKey($historyKey)) {
                            [PowerAugerPredictor]::ContextualHistory[$historyKey]
                        } else {
                            $null
                        }

                        if ($history) {
                            # Use the full historical command
                            $suggestions.Add([PredictiveSuggestion]::new(
                                $history.FullCommand,
                                "History: Used $($history.AcceptedCount)x"
                            ))
                        } else {
                            # Use raw TabExpansion2 result
                            $suggestions.Add([PredictiveSuggestion]::new(
                                $tab.CompletionText,
                                "Tab: $($tab.ResultType)"
                            ))
                        }
                    }
                }
            } catch {
                # Queue error log
                [void][PowerAugerPredictor]::LogQueue.TryAdd(@{
                    Level = "Warning"
                    Component = "GetSuggestion"
                    Message = "TabExpansion2 processing failed: $_"
                    Timestamp = Get-Date
                }, 0)
            }

            # If still no suggestions, try contextual history as fallback
            if ($suggestions.Count -eq 0) {
                # Try to find a match in contextual history with new key format
                $historyKey = "$($PWD.Path)|$inputText"

                $historyMatch = if ([PowerAugerPredictor]::ContextualHistory.ContainsKey($historyKey)) {
                    [PowerAugerPredictor]::ContextualHistory[$historyKey]
                } else {
                    $null
                }

                if ($historyMatch -and $historyMatch.FullCommand -and $historyMatch.FullCommand.StartsWith($inputText)) {
                    $suggestions.Add([PredictiveSuggestion]::new(
                        $historyMatch.FullCommand,
                        "History: Used $($historyMatch.AcceptedCount)x"
                    ))
                }

                # If STILL no suggestions, provide basic fallback for common prefixes
                if ($suggestions.Count -eq 0) {
                    $fallbacks = @{
                        'Get-Ch' = 'Get-ChildItem'
                        'Get-Co' = 'Get-Content'
                        'Get-Pr' = 'Get-Process'
                        'Set-Lo' = 'Set-Location'
                        'New-It' = 'New-Item'
                        'Remove-It' = 'Remove-Item'
                    }

                    foreach ($prefix in $fallbacks.Keys) {
                        if ($inputText -like "$prefix*") {
                            $suggestions.Add([PredictiveSuggestion]::new(
                                $fallbacks[$prefix],
                                "Fallback"
                            ))
                            break
                        }
                    }
                }
            }

            # Queue AI completion - just use whatever we have
            if ([PowerAugerPredictor]::IsBackgroundRunning -and
                [PowerAugerPredictor]::MessageQueue.Count -lt 50 -and
                -not [PowerAugerPredictor]::ResponseCache.ContainsKey($inputText)) {

                # Send message to background runspace
                $message = @{
                    Input = $inputText
                    Context = $currentContext.Clone()  # Clone to avoid shared references
                }
                $queued = [PowerAugerPredictor]::MessageQueue.TryAdd($message, 100)

                # Log the queue attempt
                [void][PowerAugerPredictor]::LogQueue.TryAdd(@{
                    Level = "Debug"
                    Component = "GetSuggestion"
                    Message = "Queue attempt for '$inputText': $queued, Queue count: $([PowerAugerPredictor]::MessageQueue.Count)"
                    Timestamp = Get-Date
                }, 0)
            } else {
                # Log why we didn't queue
                [void][PowerAugerPredictor]::LogQueue.TryAdd(@{
                    Level = "Debug"
                    Component = "GetSuggestion"
                    Message = "Skipped queue for '$inputText' - BG:$([PowerAugerPredictor]::IsBackgroundRunning) Q:$([PowerAugerPredictor]::MessageQueue.Count) Cached:$([PowerAugerPredictor]::ResponseCache.ContainsKey($inputText))"
                    Timestamp = Get-Date
                }, 0)
            }

            # ALWAYS return at least one suggestion for testing
            if ($suggestions.Count -eq 0) {
                $suggestions.Add([PredictiveSuggestion]::new(
                    "Get-ChildItem",
                    "HARDCODED TEST"
                ))
            }

            # Return suggestions if we have any
            $stopwatch.Stop()

            # Queue completion log
            [void][PowerAugerPredictor]::LogQueue.TryAdd(@{
                Level = "Debug"
                Component = "GetSuggestion"
                Message = "Completed in $($stopwatch.ElapsedMilliseconds)ms with $($suggestions.Count) suggestions"
                Timestamp = Get-Date
            }, 0)

            if ($suggestions.Count -gt 0) {
                return [SuggestionPackage]::new($suggestions)
            }
        } catch {
            # Queue error log
            [void][PowerAugerPredictor]::LogQueue.TryAdd(@{
                Level = "Error"
                Component = "GetSuggestion"
                Message = "Failed to get suggestions: $_"
                Timestamp = Get-Date
            }, 0)
            # Return null on any error - don't break PSReadLine
        } finally {
            if ($stopwatch.IsRunning) {
                $stopwatch.Stop()
            }
        }

        return $null
    }

    [void] OnCommandLineAccepted([string] $commandLine) {
        # Store both simple and contextual history
            try {
                # Generate FULL context for the accepted command (with null TabCompletions parameter)
                $acceptedContext = $this.GetStandardizedContext($commandLine, $commandLine.Length, $null)

                # Use full path and input as key
                $key = "$($PWD.Path)|$commandLine"

                # Find the split point for FIM format - split at first space for command name
                $firstSpace = $commandLine.IndexOf(' ')
                $splitPoint = if ($firstSpace -gt 0) { $firstSpace } else { $commandLine.Length }
                $prefix = $commandLine.Substring(0, $splitPoint)
                $completion = if ($splitPoint -lt $commandLine.Length) {
                    $commandLine.Substring($splitPoint)
                } else {
                    ""
                }

                # Check if we have this key already
                if ([PowerAugerPredictor]::ContextualHistory.ContainsKey($key)) {
                    # Update existing entry
                    $existing = [PowerAugerPredictor]::ContextualHistory[$key]
                    $existing.AcceptedCount++
                    $existing.LastUsed = Get-Date

                    # Update to longer/more complete command if applicable
                    if ($commandLine.Length -gt $existing.FullCommand.Length) {
                        $existing.FullCommand = $commandLine
                        $existing.Input = $prefix
                        $existing.Completion = $completion
                        $existing.Context = $acceptedContext  # Update with new context
                    }
                } else {
                    # Add new entry with simple key but FULL context value
                    [PowerAugerPredictor]::ContextualHistory[$key] = @{
                        FullCommand = $commandLine
                        Input = $prefix
                        Completion = $completion
                        Context = $acceptedContext  # Full rich context preserved
                        AcceptedCount = 1
                        LastUsed = Get-Date
                    }
                }

                # Prune old entries if history is too large
                if ([PowerAugerPredictor]::ContextualHistory.Count -gt [PowerAugerPredictor]::MaxContextualHistorySize) {
                    # Find least recently used entries
                    $entries = [PowerAugerPredictor]::ContextualHistory.GetEnumerator() |
                        Sort-Object { $_.Value.LastUsed }

                    $toRemove = $entries |
                        Select-Object -First ([PowerAugerPredictor]::ContextualHistory.Count - [PowerAugerPredictor]::MaxContextualHistorySize) |
                        Select-Object -ExpandProperty Key

                    foreach ($removeKey in $toRemove) {
                        [PowerAugerPredictor]::ContextualHistory.Remove($removeKey)
                    }
                }

                # Also maintain simple history for backward compatibility
                # ConcurrentBag doesn't support RemoveAt, so just add without pruning
                # The bag will grow but it's thread-safe
                [PowerAugerPredictor]::HistoryExamples.Add(@{
                    Prefix = $prefix
                    Completion = $completion
                })
            } catch {
                Write-PowerAugerLog -Level "Warning" -Component "OnCommandLineAccepted" `
                    -Message "Failed to track history" -Data $_
            }

    }

    [void] OnCommandLineExecuted([string] $commandLine) {
        # Called after command execution - can be used for feedback
    }

    [void] OnCommandLineCleared() {
        # Could clear cache here if desired
    }
}

# Function to save AI cache to disk
function Save-PowerAugerCache {
    try {
        $historyPath = [PowerAugerPredictor]::ContextualHistoryPath
        $historyDir = Split-Path -Path $historyPath -Parent
        if (-not (Test-Path $historyDir)) {
            New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
        }

        # Convert contextual history to serializable format
        $historyData = @{}
        foreach ($key in [PowerAugerPredictor]::ContextualHistory.Keys) {
            $historyData[$key] = [PowerAugerPredictor]::ContextualHistory[$key]
        }

        $historyData | ConvertTo-Json -Depth 4 | Set-Content -Path $historyPath -Force
        Write-Host "Saved $($historyData.Count) contextual history entries to $historyPath" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to save contextual history: $_"
    }
}

# Function to set log level
function Set-PowerAugerLogLevel {
    param(
        [ValidateSet("Debug", "Info", "Warning", "Error")]
        [string]$Level = "Info"
    )

    [PowerAugerPredictor]::LogLevel = $Level
    Write-PowerAugerLog -Level "Info" -Component "Configuration" `
        -Message "Log level set to: $Level"

    if ($Level -eq "Debug") {
        Write-Host "PowerAuger debug logging enabled. Logs will be written to:" -ForegroundColor Yellow
        Write-Host "  $([PowerAugerPredictor]::GetLogPath())" -ForegroundColor Cyan
    }
}

# Function to load contextual history from disk
function Import-PowerAugerCache {
    try {
        $historyPath = [PowerAugerPredictor]::ContextualHistoryPath
        if (Test-Path $historyPath) {
            $historyData = Get-Content -Path $historyPath -Raw | ConvertFrom-Json -AsHashtable

            foreach ($key in $historyData.Keys) {
                [PowerAugerPredictor]::ContextualHistory[$key] = $historyData[$key]
            }

            Write-Host "Loaded $($historyData.Count) contextual history entries" -ForegroundColor Green
        } else {
            Write-Host "No contextual history file found at $historyPath" -ForegroundColor Yellow
        }
    } catch {
        Write-Warning "Failed to load contextual history: $_"
    }
}

# Debug function to access internal state
function Get-PowerAugerState {
    @{
        IsBackgroundRunning = [PowerAugerPredictor]::IsBackgroundRunning
        ContextualHistoryCount = [PowerAugerPredictor]::ContextualHistory.Count
        ResponseCacheCount = [PowerAugerPredictor]::ResponseCache.Count
        ContextualHistoryKeys = @([PowerAugerPredictor]::ContextualHistory.Keys)
        QueueCount = [PowerAugerPredictor]::MessageQueue.Count
        MaxQueueSize = 100
        ContextualHistoryPath = [PowerAugerPredictor]::ContextualHistoryPath
        RunspaceState = if ([PowerAugerPredictor]::PredictionRunspace) { [PowerAugerPredictor]::PredictionRunspace.RunspaceStateInfo.State } else { "Not created" }
        IsCancellationRequested = [PowerAugerPredictor]::CancellationSource.IsCancellationRequested
    }
}

# Function to get the PowerAuger cat with dynamic coloring based on queue count
function Get-PowerAugerCat {
    param(
        [int]$QueueCount = 0
    )

    # Simple gradient colors
    $colors = @(
        @(166, 226, 46),   # Green
        @(174, 129, 255),  # Purple
        @(253, 151, 31)    # Orange
    )

    # Cat characters: ᓚ (tail) ᘏ (body) ᗢ (head)
    $catChars = @('ᓚ', 'ᘏ', 'ᗢ')

    # Determine stress level (0-2)
    $stressLevel = if ($QueueCount -eq 0) { 0 }
                   elseif ($QueueCount -le 20) { 1 }
                   else { 2 }

    $esc = [char]0x1b
    $rgb = $colors[$stressLevel]

    # Build cat with selected color
    $catDisplay = "${esc}[38;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m"
    $catDisplay += $catChars -join ''
    $catDisplay += "${esc}[0m"

    return $catDisplay
}

# Function to set up PowerAuger-enhanced prompt with queue health cat
function Set-PowerAugerPrompt {
    # Store the original prompt if not already saved
    if (-not $global:PowerAugerOriginalPrompt) {
        $global:PowerAugerOriginalPrompt = (Get-Content function:prompt -ErrorAction SilentlyContinue)
    }

    # Define the custom prompt function globally
    function global:prompt {
        # Check for channel updates first (event-driven, no timers)
        Update-PowerAugerFromChannel

        # Get current queue count
        $queueCount = 0
        try {
            $queueCount = [PowerAugerPredictor]::MessageQueue.Count
        } catch {}

        # Use the cat from channel updates if available, otherwise calculate
        if ($null -eq $global:PowerAugerCurrentCat -or $queueCount -ne $global:PowerAugerCurrentQueueCount) {
            $global:PowerAugerCurrentCat = Get-PowerAugerCat -QueueCount $queueCount
            $global:PowerAugerCurrentQueueCount = $queueCount
        }

        # Return the complete prompt string with cat and proper formatting
        "$global:PowerAugerCurrentCat $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }

    Write-Host "PowerAuger gradient cat prompt enabled!" -ForegroundColor Green
    Write-Host "The cat ᓚᘏᗢ changes color based on AI queue pressure (green→purple→orange)" -ForegroundColor Cyan
}

# Function to process channel updates (non-blocking)
function Update-PowerAugerChannelMessages {
    try {
        # Check for updates from the background thread
        $reader = [PowerAugerPredictor]::UpdateChannel.Reader

        # Process all available messages (non-blocking)
        while ($reader.TryRead([ref]$update)) {
            switch ($update.Type) {
                'PredictionComplete' {
                    # Update cat based on new queue count
                    if ($update.QueueCount -ne $global:PowerAugerCurrentQueueCount) {
                        $global:PowerAugerCurrentCat = Get-PowerAugerCat -QueueCount $update.QueueCount
                        $global:PowerAugerCurrentQueueCount = $update.QueueCount
                    }
                    # DO NOT manipulate PSReadLine buffer - it causes issues
                }

                'BackgroundStarted' {
                    # Update cat for initial state
                    $global:PowerAugerCurrentCat = Get-PowerAugerCat -QueueCount $update.QueueCount
                    $global:PowerAugerCurrentQueueCount = $update.QueueCount
                }

                'BackgroundStopping' {
                    # Reset cat to idle state
                    $global:PowerAugerCurrentCat = Get-PowerAugerCat -QueueCount 0
                    $global:PowerAugerCurrentQueueCount = 0
                }

                'CacheSaved' {
                    # Optional: Could show a brief notification
                }
            }
        }
    } catch {
        # Log but don't disrupt prompt
        Write-Debug "PowerAuger channel update error: $_"
    }
}

# Function to process channel updates when prompt is displayed
# This is called from the prompt function itself - no timers needed
function Update-PowerAugerFromChannel {
    try {
        $reader = [PowerAugerPredictor]::UpdateChannel.Reader
        $latestQueueCount = -1

        # Process all pending updates from channel
        while ($reader.TryRead([ref]$update)) {
            if ($update.QueueCount -ge 0) {
                $latestQueueCount = $update.QueueCount
            }
        }

        # Update cat if we got a new queue count
        if ($latestQueueCount -ge 0 -and $latestQueueCount -ne $global:PowerAugerCurrentQueueCount) {
            $global:PowerAugerCurrentCat = Get-PowerAugerCat -QueueCount $latestQueueCount
            $global:PowerAugerCurrentQueueCount = $latestQueueCount
        }
    } catch {
        # Log but don't disrupt
        Write-Debug "PowerAuger channel read error: $_"
    }
}

# Function to restore original prompt
function Reset-PowerAugerPrompt {
    if ($global:PowerAugerOriginalPrompt) {
        Set-Content function:prompt -Value $global:PowerAugerOriginalPrompt
        Remove-Variable -Name PowerAugerOriginalPrompt -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name PowerAugerCurrentCat -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name PowerAugerCurrentQueueCount -Scope Global -ErrorAction SilentlyContinue
        Write-Host "Original prompt restored." -ForegroundColor Yellow
    }
}

# Function to manually populate history for testing
function Add-PowerAugerHistory {
    param(
        [string[]]$Commands
    )

    $predictors = [System.Management.Automation.Subsystem.SubsystemManager]::GetAllSubsystemInfo() |
        Where-Object { $_.Kind -eq 'CommandPredictor' }

    $ourPredictor = $null
    if ($predictors -and $predictors.Implementations) {
        $ourPredictor = $predictors.Implementations |
            Where-Object { $_.Id -eq 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' }
    }

    if ($ourPredictor) {
        foreach ($cmd in $Commands) {
            Write-Host "  Adding: $cmd" -ForegroundColor Gray
            $ourPredictor.OnCommandLineAccepted($cmd)
        }
        Write-Host "Added $($Commands.Count) commands to contextual history" -ForegroundColor Green
    } else {
        Write-Warning "PowerAuger predictor not found"
    }
}

# Export a status function for debugging
function Get-PowerAugerStatus {
    Write-Host "PowerAuger Predictor Status:" -ForegroundColor Cyan
    Write-Host "  Contextual history: $([PowerAugerPredictor]::ContextualHistory.Count)" -ForegroundColor Green
    Write-Host "  Response Cache (thread-safe): $([PowerAugerPredictor]::ResponseCache.Count)" -ForegroundColor Green
    Write-Host "  Model: $([PowerAugerPredictor]::Model)"
    Write-Host "  Background engine: $(if ([PowerAugerPredictor]::IsBackgroundRunning) { '✅ Running' } else { '❌ Stopped' })" -ForegroundColor $(if ([PowerAugerPredictor]::IsBackgroundRunning) { 'Green' } else { 'Red' })

    # Show queue status with gradient cat health indicator
    $queueCount = 0
    try {
        $queueCount = [PowerAugerPredictor]::MessageQueue.Count
    } catch {}

    # Queue health status
    $queueStatus = switch ($queueCount) {
        {$_ -eq 0}    { @{ Color = "Green"; Desc = "idle" } }
        {$_ -le 5}    { @{ Color = "DarkGreen"; Desc = "light" } }
        {$_ -le 10}   { @{ Color = "Cyan"; Desc = "moderate" } }
        {$_ -le 20}   { @{ Color = "Yellow"; Desc = "busy" } }
        {$_ -le 30}   { @{ Color = "DarkYellow"; Desc = "heavy" } }
        {$_ -le 45}   { @{ Color = "Magenta"; Desc = "overloaded" } }
        default       { @{ Color = "Red"; Desc = "critical" } }
    }

    Write-Host "  Queue: $queueCount ($($queueStatus.Desc))" -ForegroundColor $queueStatus.Color

    # Show contextual learning stats
    if ([PowerAugerPredictor]::ContextualHistory.Count -gt 0) {
        Write-Host "`n  Contextual Learning:" -ForegroundColor Magenta

        # Extract unique directories from keys
        $directories = [PowerAugerPredictor]::ContextualHistory.Keys |
            ForEach-Object { ($_ -split '\|')[1] } |
            Select-Object -Unique |
            Where-Object { $_ -ne '*' }
        Write-Host "    Directories tracked: $($directories.Count + 1)" # +1 for wildcard

        # Show top accepted commands from hashtable values
        $topCommands = [PowerAugerPredictor]::ContextualHistory.Values |
            Sort-Object -Property AcceptedCount -Descending |
            Select-Object -First 3

        Write-Host "    Top accepted predictions:" -ForegroundColor Yellow
        foreach ($cmd in $topCommands) {
            $shortCmd = if ($cmd.FullCommand.Length -gt 40) {
                $cmd.FullCommand.Substring(0, 40) + "..."
            } else {
                $cmd.FullCommand
            }
            Write-Host "      [$($cmd.AcceptedCount)x] $shortCmd (in $($cmd.Context.DirName))"
        }
    }

    # DON'T show cache samples - they're not real predictions
    # Just check Ollama connection
    try {
        $test = Invoke-RestMethod -Uri "$([PowerAugerPredictor]::ApiUrl)/api/tags" -TimeoutSec 1
        Write-Host "`n  Ollama: ✅ Connected" -ForegroundColor Green
    } catch {
        Write-Host "`n  Ollama: ❌ Not responding" -ForegroundColor Red
    }
}

# Cleanup function for module unload
function Stop-PowerAugerBackground {
    if ([PowerAugerPredictor]::IsBackgroundRunning) {
        try {
            if ([PowerAugerPredictor]::PredictionPowerShell) {
                [PowerAugerPredictor]::PredictionPowerShell.Stop()
                [PowerAugerPredictor]::PredictionPowerShell.Dispose()
            }
            if ([PowerAugerPredictor]::PredictionRunspace) {
                [PowerAugerPredictor]::PredictionRunspace.Close()
                [PowerAugerPredictor]::PredictionRunspace.Dispose()
            }
            [PowerAugerPredictor]::IsBackgroundRunning = $false
            Write-Host "PowerAuger background engine stopped." -ForegroundColor Yellow
        } catch {
            Write-Warning "Error stopping PowerAuger background: $_"
        }
    }
}

# Check if already registered and only create new instance if not
try {
    $existingPredictors = [System.Management.Automation.Subsystem.SubsystemManager]::GetSubsystems([System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor)
    $ourPredictor = $existingPredictors | Where-Object { $_.Id -eq 'a1b2c3d4-e5f6-7890-abcd-ef1234567890' }

    if ($ourPredictor) {
        Write-Host "PowerAuger predictor already registered." -ForegroundColor Yellow
        # Restart background if needed
        if (-not [PowerAugerPredictor]::IsBackgroundRunning) {
            Write-Host "Restarting background prediction engine..." -ForegroundColor Cyan
            $dummy = [PowerAugerPredictor]::new()  # This will restart the background
        }
    } else {
        # Not registered yet, create and register
        $predictorInstance = [PowerAugerPredictor]::new()
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            $predictorInstance
        )
        Write-Host "PowerAuger predictor registered successfully." -ForegroundColor Green
    }

    # Event systems removed - no auto-refresh

} catch {
    # First time registration
    try {
        $predictorInstance = [PowerAugerPredictor]::new()
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            $predictorInstance
        )
        Write-Host "PowerAuger predictor registered successfully." -ForegroundColor Green

        # Event systems removed - no auto-refresh

    } catch {
        Write-Warning "Failed to register PowerAuger predictor: $_"
    }
}

# Register cleanup on module removal
$ExecutionContext.SessionState.Module.OnRemove = {
    # Signal cancellation FIRST to stop background work
    if ([PowerAugerPredictor]::CancellationSource) {
        [PowerAugerPredictor]::CancellationSource.Cancel()
    }

    # No timers to stop - using event-driven channel updates

    # Complete the message queue to stop accepting new work
    if ([PowerAugerPredictor]::MessageQueue) {
        [PowerAugerPredictor]::MessageQueue.CompleteAdding()
    }

    # Wait for background to acknowledge shutdown with mutex
    $acquired = $false
    try {
        if ([PowerAugerPredictor]::ShutdownMutex) {
            $acquired = [PowerAugerPredictor]::ShutdownMutex.WaitOne(5000)
        }

        if ($acquired) {
            # NOW safe to save contextual history after background has stopped
            try {
                $historyPath = [PowerAugerPredictor]::ContextualHistoryPath
                $historyDir = Split-Path -Path $historyPath -Parent
                if (-not (Test-Path $historyDir)) {
                    New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
                }

                # Save contextual history
                $historyData = @{}
                foreach ($key in [PowerAugerPredictor]::ContextualHistory.Keys) {
                    $historyData[$key] = [PowerAugerPredictor]::ContextualHistory[$key]
                }

                if ($historyData.Count -gt 0) {
                    $historyData | ConvertTo-Json -Depth 4 | Set-Content -Path $historyPath -Force
                    Write-Host "PowerAuger: Saved $($historyData.Count) contextual history entries" -ForegroundColor Green
                }
            } catch {
                Write-Warning "Failed to save PowerAuger contextual history on exit: $_"
            }
        }
    } finally {
        if ($acquired -and [PowerAugerPredictor]::ShutdownMutex) {
            [PowerAugerPredictor]::ShutdownMutex.ReleaseMutex()
        }
    }

    # Clean shutdown of runspace and PowerShell
    if ([PowerAugerPredictor]::PredictionPowerShell) {
        try { [PowerAugerPredictor]::PredictionPowerShell.Stop() } catch { }
        try { [PowerAugerPredictor]::PredictionPowerShell.Dispose() } catch { }
        [PowerAugerPredictor]::PredictionPowerShell = $null
    }

    if ([PowerAugerPredictor]::PredictionRunspace) {
        try { [PowerAugerPredictor]::PredictionRunspace.Close() } catch { }
        try { [PowerAugerPredictor]::PredictionRunspace.Dispose() } catch { }
        [PowerAugerPredictor]::PredictionRunspace = $null
    }

    # Unregister the predictor
    try {
        [System.Management.Automation.Subsystem.SubsystemManager]::UnregisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            [guid]::Parse('a1b2c3d4-e5f6-7890-abcd-ef1234567890')
        )
        Write-Host "PowerAuger predictor unregistered." -ForegroundColor Yellow
    } catch {
        # Ignore if already unregistered
    }

    # Clean up static resources
    if ([PowerAugerPredictor]::MessageQueue) {
        try { [PowerAugerPredictor]::MessageQueue.Dispose() } catch { }
    }
    if ([PowerAugerPredictor]::CancellationSource) {
        try { [PowerAugerPredictor]::CancellationSource.Dispose() } catch { }
    }
    if ([PowerAugerPredictor]::ShutdownMutex) {
        try { [PowerAugerPredictor]::ShutdownMutex.Dispose() } catch { }
    }
}
