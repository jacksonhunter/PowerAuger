# PowerAuger.psm1 - Proper predictor plugin with Ollama

using namespace System.Management.Automation.Subsystem
using namespace System.Management.Automation.Subsystem.Prediction

class PowerAugerPredictor : ICommandPredictor {
    [guid] $Id
    [string] $Name
    [string] $Description

    # Cache for performance - thread-safe synchronized hashtable
    hidden static [hashtable] $Cache = [hashtable]::Synchronized(@{})
    hidden static [datetime] $CacheTime = [DateTime]::MinValue
    hidden static [int] $CacheTimeoutSeconds = 3

    # Configuration
    hidden static [string] $Model = "qwen2.5-0.5B-autocomplete-custom"
    hidden static [string] $ApiUrl = "http://127.0.0.1:11434"

    # Persistent cache path
    hidden static [string] $CachePath = "$env:LOCALAPPDATA\PowerAuger\ai_cache.json"

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
    hidden static [System.Collections.Concurrent.ConcurrentDictionary[string,object]] $ResponseCache = [System.Collections.Concurrent.ConcurrentDictionary[string,object]]::new()

    # Channel for real-time updates (PowerShell 7+)
    hidden static [System.Threading.Channels.Channel[hashtable]] $UpdateChannel = [System.Threading.Channels.Channel]::CreateUnbounded[hashtable]()

    # Cancellation token for clean shutdown
    hidden static [System.Threading.CancellationTokenSource] $CancellationSource = [System.Threading.CancellationTokenSource]::new()

    # Shutdown mutex for cleanup synchronization
    hidden static [System.Threading.Mutex] $ShutdownMutex = [System.Threading.Mutex]::new($false)

    # Background running state
    hidden static [bool] $IsBackgroundRunning = $false

    PowerAugerPredictor() {
        $this.Id = [guid]::Parse('a1b2c3d4-e5f6-7890-abcd-ef1234567890')
        $this.Name = 'PowerAuger'
        $this.Description = 'Ollama-powered AI completions with history learning'

        # Load cached AI completions from disk
        try {
            if (Test-Path ([PowerAugerPredictor]::CachePath)) {
                $cacheData = Get-Content ([PowerAugerPredictor]::CachePath) -Raw | ConvertFrom-Json -AsHashtable
                foreach ($key in $cacheData.Keys) {
                    [PowerAugerPredictor]::Cache[$key] = $cacheData[$key]
                }
            }
        } catch {}

        # Pre-load some history examples on initialization
        $this.LoadHistoryExamples()

        # Start background prediction engine if not already running
        if (-not [PowerAugerPredictor]::IsBackgroundRunning) {
            $this.StartBackgroundPredictionEngine()
        }
    }

    hidden [hashtable] GetStandardizedContext([string]$inputText, [int]$cursorPos) {
        try {
            # Get TabExpansion completions
            $tabCompletions = $null
            if (Get-Command TabExpansion2 -ErrorAction SilentlyContinue) {
                $tabCompletions = TabExpansion2 -inputScript $inputText -cursorColumn $cursorPos
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

            # Build standardized context
            return @{
                Groups = $contextGroups
                Directory = $PWD.Path
                IsGitRepo = (Test-Path (Join-Path $PWD.Path ".git"))
                DirName = (Split-Path $PWD.Path -Leaf)
                Timestamp = Get-Date
            }
        }
        catch {
            # Return minimal context on error
            return @{
                Groups = @{}
                Directory = $PWD.Path
                IsGitRepo = $false
                DirName = (Split-Path $PWD.Path -Leaf)
                Timestamp = Get-Date
            }
        }
    }

    hidden [string] BuildContextAwarePrompt([string]$inputText, [hashtable]$currentContext) {
        $prompt = ""

        # Find matching contexts from history (now a hashtable)
        $exactMatches = @()
        $similarMatches = @()

        foreach ($kvp in [PowerAugerPredictor]::ContextualHistory.GetEnumerator()) {
            $entry = $kvp.Value

            # Check for exact context match (same directory and same completion types)
            if ($entry.Context -and
                $entry.Context.DirName -eq $currentContext.DirName -and
                ($entry.Context.Groups.Keys -join ',') -eq ($currentContext.Groups.Keys -join ',')) {
                $exactMatches += $entry
            }
            # Check for similar context (same type of environment)
            elseif ($entry.Context -and
                    $entry.Context.IsGitRepo -eq $currentContext.IsGitRepo) {
                $similarMatches += $entry
            }
        }

        # Sort by acceptance count and take top matches
        $exactMatches = $exactMatches | Sort-Object -Property AcceptedCount -Descending | Select-Object -First 2
        $similarMatches = $similarMatches | Sort-Object -Property AcceptedCount -Descending | Select-Object -First 2

        # Add exact matches as examples (highest value)
        foreach ($match in $exactMatches) {
            if ($match.Input -and $match.Completion) {
                $contextHint = "Dir:$($match.Context.DirName)"
                if ($match.AcceptedCount -gt 1) {
                    $contextHint += " (used $($match.AcceptedCount)x)"
                }
                $prompt += "# $contextHint`n"
                $prompt += "<|fim_prefix|>$($match.Input)<|fim_suffix|><|fim_middle|>$($match.Completion)`n`n"
            }
        }

        # Add similar matches as examples
        foreach ($match in $similarMatches) {
            if ($match.Input -and $match.Completion) {
                $prompt += "# Dir:$($match.Context.DirName)`n"
                $prompt += "<|fim_prefix|>$($match.Input)<|fim_suffix|><|fim_middle|>$($match.Completion)`n`n"
            }
        }

        # Add current context with available completions
        $contextInfo = "# Current: $($currentContext.DirName)"
        if ($currentContext.Groups.Count -gt 0) {
            $availableTypes = $currentContext.Groups.Keys -join ','
            $contextInfo += " [$availableTypes]"
        }
        $prompt += "$contextInfo`n"
        $prompt += "<|fim_prefix|>$inputText<|fim_suffix|><|fim_middle|>"

        return $prompt
    }

    hidden [void] StartBackgroundPredictionEngine() {
        try {
            # Create runspace for background predictions
            [PowerAugerPredictor]::PredictionRunspace = [runspacefactory]::CreateRunspace()
            [PowerAugerPredictor]::PredictionRunspace.Open()

            # Pass thread-safe message queues and channel to the runspace
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('MessageQueue', [PowerAugerPredictor]::MessageQueue)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('ResponseCache', [PowerAugerPredictor]::ResponseCache)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('UpdateChannel', [PowerAugerPredictor]::UpdateChannel)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('CancellationToken', [PowerAugerPredictor]::CancellationSource.Token)

            # Pass read-only configuration values (not shared references)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('Model', [PowerAugerPredictor]::Model)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('ApiUrl', [PowerAugerPredictor]::ApiUrl)

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
                # Local cache for the background runspace (not shared)
                $localCache = @{}
                $lastSaveTime = Get-Date
                $saveIntervalMinutes = 5

                # Check for cancellation
                while (-not $CancellationToken.IsCancellationRequested) {
                    try {
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

                            # Build context-aware prompt
                            $fimPrompt = ""

                            # Find matching contexts from history (now a hashtable)
                            $exactMatches = @()
                            $similarMatches = @()

                            # Search through hashtable values
                            foreach ($kvp in $ContextualHistory.GetEnumerator()) {
                                $entry = $kvp.Value

                                # Check for exact context match
                                if ($entry.Context -and
                                    $entry.Context.DirName -eq $currentContext.DirName -and
                                    ($entry.Context.Groups.Keys -join ',') -eq ($currentContext.Groups.Keys -join ',')) {
                                    $exactMatches += $entry
                                }
                                # Check for similar context (same type of environment)
                                elseif ($entry.Context -and
                                        $entry.Context.IsGitRepo -eq $currentContext.IsGitRepo) {
                                    $similarMatches += $entry
                                }
                            }

                            # Sort and take top matches
                            $exactMatches = $exactMatches | Sort-Object -Property AcceptedCount -Descending | Select-Object -First 2
                            $similarMatches = $similarMatches | Sort-Object -Property AcceptedCount -Descending | Select-Object -First 1

                            # Add contextual examples
                            foreach ($match in $exactMatches) {
                                if ($match.Input -and $match.Completion) {
                                    $fimPrompt += "# Dir:$($match.Context.DirName) (used $($match.AcceptedCount)x)`n"
                                    $fimPrompt += "<|fim_prefix|>$($match.Input)<|fim_suffix|><|fim_middle|>$($match.Completion)`n"
                                }
                            }

                            foreach ($match in $similarMatches) {
                                if ($match.Input -and $match.Completion) {
                                    $fimPrompt += "<|fim_prefix|>$($match.Input)<|fim_suffix|><|fim_middle|>$($match.Completion)`n"
                                }
                            }

                            # Add context hint for current request
                            if ($currentContext.Groups.Count -gt 0) {
                                $availableTypes = $currentContext.Groups.Keys -join ','
                                $fimPrompt += "# Context: [$availableTypes]`n"
                            }

                            # Add the current request
                            $fimPrompt += "<|fim_prefix|>$($request.Input)<|fim_suffix|><|fim_middle|>"

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

                            $response = Invoke-RestMethod -Uri "$ApiUrl/api/generate" `
                                                         -Method Post -Body $body `
                                                         -ContentType 'application/json' `
                                                         -TimeoutSec 5 -ErrorAction Stop

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

                        # Pre-fetch common prefixes ONCE at startup
                        if ($localCache.Count -eq 0 -and -not $localCache.ContainsKey('_initialized')) {
                            # Send startup notification
                            [void]$UpdateChannel.Writer.TryWrite(@{
                                Type = 'BackgroundStarted'
                                QueueCount = $MessageQueue.Count
                            })

                            foreach ($prefix in @("Get-", "Set-", "New-", "Remove-")) {
                                if (-not $localCache.ContainsKey($prefix)) {
                                    # Send message to self for pre-warming
                                    [void]$MessageQueue.TryAdd(@{Input = $prefix}, 100)
                                }
                            }
                            # Mark that we've done initial warming
                            $localCache['_initialized'] = @{ Completion = "true"; Timestamp = Get-Date }
                        }

                        # Periodic cache save every 5 minutes
                        if ((Get-Date) - $lastSaveTime -gt [TimeSpan]::FromMinutes($saveIntervalMinutes)) {
                            try {
                                # Only save if local cache has real entries (not just _initialized)
                                if ($localCache.Count -gt 1) {
                                    $cachePath = "$env:LOCALAPPDATA\PowerAuger\ai_cache.json"
                                    $cacheDir = Split-Path -Path $cachePath -Parent
                                    if (-not (Test-Path $cacheDir)) {
                                        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                                    }

                                    # Filter out internal keys when saving
                                    $cacheData = @{}
                                    foreach ($key in $localCache.Keys) {
                                        if ($key -notmatch '^_') {
                                            $cacheData[$key] = $localCache[$key]
                                        }
                                    }

                                    $cacheData | ConvertTo-Json -Depth 3 | Set-Content -Path $cachePath -Force
                                    $lastSaveTime = Get-Date

                                    # Also sync to ResponseCache for main thread access
                                    foreach ($key in $cacheData.Keys) {
                                        [void]$ResponseCache.TryAdd($key, $cacheData[$key])
                                    }

                                    # Notify of cache save
                                    [void]$UpdateChannel.Writer.TryWrite(@{
                                        Type = 'CacheSaved'
                                        ItemCount = $cacheData.Count
                                        QueueCount = $MessageQueue.Count
                                    })
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

                    # Final cache save before exit
                    if ($localCache.Count -gt 1) {
                        $cachePath = "$env:LOCALAPPDATA\PowerAuger\ai_cache.json"
                        $cacheData = @{}
                        foreach ($key in $localCache.Keys) {
                            if ($key -notmatch '^_') {
                                $cacheData[$key] = $localCache[$key]
                            }
                        }
                        $cacheData | ConvertTo-Json -Depth 3 | Set-Content -Path $cachePath -Force
                    }

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
                    Where-Object { $_.CommandLine.Length -gt 10 }

            [PowerAugerPredictor]::HistoryExamples.Clear()

            foreach ($cmd in $history | Select-Object -Last 20) {
                $line = $cmd.CommandLine
                # Find good split points for FIM examples
                if ($line.Length -gt 15) {
                    $splitPoint = [Math]::Floor($line.Length * 0.6)
                    [PowerAugerPredictor]::HistoryExamples.Add(@{
                        Prefix = $line.Substring(0, $splitPoint)
                        Completion = $line.Substring($splitPoint)
                    })
                }
            }
        } catch {
            # Silently fail - history loading is optional
        }
    }

    [SuggestionPackage] GetSuggestion([PredictionClient] $client, [PredictionContext] $context, [System.Threading.CancellationToken] $cancellationToken) {
        try {
            # Get the input text
            $inputText = $context.InputAst.Extent.Text

            # Skip if too short or looks like a question
            if ($inputText.Length -lt 2 -or $inputText -match '^\s*(how|what|why|when|where|who)\s') {
                return $null
            }

            # Generate context for this input
            $currentContext = $this.GetStandardizedContext($inputText, $inputText.Length)

            # Create suggestions list
            $suggestions = [System.Collections.Generic.List[PredictiveSuggestion]]::new()

            # First, try TabExpansion2 for immediate suggestions
            $tabCompletions = $null
            try {
                $tabCompletions = TabExpansion2 -inputScript $inputText -cursorColumn $inputText.Length

                if ($tabCompletions -and $tabCompletions.CompletionMatches.Count -gt 0) {
                    # Group by type and get commands first
                    $commands = $tabCompletions.CompletionMatches |
                        Where-Object { $_.ResultType -eq 'Command' } |
                        Select-Object -First 5

                    # If no commands, take whatever we got
                    if ($commands.Count -eq 0) {
                        $commands = $tabCompletions.CompletionMatches | Select-Object -First 5
                    }

                    # Enhance with contextual history
                    foreach ($tab in $commands) {
                        if ($suggestions.Count -ge 3) { break }

                        # Extract command name (first word)
                        $cmdName = if ($tab.ResultType -eq 'Command') {
                            $tab.CompletionText
                        } else {
                            ($inputText -split '\s+')[0]
                        }

                        # Try to find in contextual history
                        $historyKey = "$cmdName|$($PWD.Path)"
                        $wildcardKey = "$cmdName|*"

                        $history = if ([PowerAugerPredictor]::ContextualHistory.ContainsKey($historyKey)) {
                            [PowerAugerPredictor]::ContextualHistory[$historyKey]
                        } elseif ([PowerAugerPredictor]::ContextualHistory.ContainsKey($wildcardKey)) {
                            [PowerAugerPredictor]::ContextualHistory[$wildcardKey]
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
                # TabExpansion2 failed, continue with AI cache fallback
            }

            # If still no suggestions, try AI cache as fallback
            if ($suggestions.Count -eq 0 -and [PowerAugerPredictor]::Cache.ContainsKey($inputText)) {
                $cached = [PowerAugerPredictor]::Cache[$inputText]
                if ($cached -and $cached.Completion) {
                    $fullSuggestion = $inputText + $cached.Completion
                    $suggestions.Add([PredictiveSuggestion]::new(
                        $fullSuggestion,
                        "AI: $($cached.Completion)"
                    ))
                }
            }

            # Queue AI completion for top TabExpansion2 result if not already cached/queued
            if ([PowerAugerPredictor]::IsBackgroundRunning -and
                [PowerAugerPredictor]::MessageQueue.Count -lt 50 -and
                $tabCompletions -and $tabCompletions.CompletionMatches.Count -gt 0) {

                # Get the top command completion
                $topCompletion = $tabCompletions.CompletionMatches |
                    Where-Object { $_.ResultType -eq 'Command' } |
                    Select-Object -First 1

                if ($topCompletion) {
                    $completionText = $topCompletion.CompletionText

                    # Check if not already cached in response cache
                    if (-not [PowerAugerPredictor]::ResponseCache.ContainsKey($completionText)) {
                        # Send message to background runspace
                        $message = @{
                            Input = $completionText
                            Context = $currentContext.Clone()  # Clone to avoid shared references
                        }
                        [void][PowerAugerPredictor]::MessageQueue.TryAdd($message, 100)
                    }
                }
            }

            # Return suggestions if we have any
            if ($suggestions.Count -gt 0) {
                return [SuggestionPackage]::new($suggestions)
            }
        } catch {
            # Return null on any error - don't break PSReadLine
        }

        return $null
    }

    [void] OnCommandLineAccepted([string] $commandLine) {
        # Store both simple and contextual history
        if ($commandLine.Length -gt 15) {
            try {
                # Generate FULL context for the accepted command
                $acceptedContext = $this.GetStandardizedContext($commandLine, $commandLine.Length)

                # Extract command name (first word)
                $command = ($commandLine -split '\s+')[0]

                # Determine directory key (absolute path or wildcard)
                $hasTarget = $commandLine -match '-Path\s+(\S+)' -or
                            $commandLine -match '>\s*(\S+)' -or
                            $commandLine -match '\|\s*Out-File\s+(\S+)'

                $dirKey = if ($hasTarget) { $PWD.Path } else { "*" }
                $key = "$command|$dirKey"

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
                # Silently fail - history tracking is optional
            }
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
        $cachePath = [PowerAugerPredictor]::CachePath
        $cacheDir = Split-Path -Path $cachePath -Parent
        if (-not (Test-Path $cacheDir)) {
            New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
        }

        # Convert cache to serializable format
        $cacheData = @{}
        foreach ($key in [PowerAugerPredictor]::Cache.Keys) {
            $cacheData[$key] = [PowerAugerPredictor]::Cache[$key]
        }

        $cacheData | ConvertTo-Json -Depth 3 | Set-Content -Path $cachePath -Force
        Write-Host "Saved $($cacheData.Count) AI completions to cache at $cachePath" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to save cache: $_"
    }
}

# Function to load AI cache from disk
function Import-PowerAugerCache {
    try {
        $cachePath = [PowerAugerPredictor]::CachePath
        if (Test-Path $cachePath) {
            $cacheData = Get-Content -Path $cachePath -Raw | ConvertFrom-Json -AsHashtable

            foreach ($key in $cacheData.Keys) {
                [PowerAugerPredictor]::Cache[$key] = $cacheData[$key]
            }

            Write-Host "Loaded $($cacheData.Count) AI completions from cache" -ForegroundColor Green
        } else {
            Write-Host "No cache file found at $cachePath" -ForegroundColor Yellow
        }
    } catch {
        Write-Warning "Failed to load cache: $_"
    }
}

# Debug function to access internal state
function Get-PowerAugerState {
    @{
        IsBackgroundRunning = [PowerAugerPredictor]::IsBackgroundRunning
        CacheCount = [PowerAugerPredictor]::Cache.Count
        ResponseCacheCount = [PowerAugerPredictor]::ResponseCache.Count
        CacheKeys = @([PowerAugerPredictor]::Cache.Keys)
        QueueCount = [PowerAugerPredictor]::MessageQueue.Count
        MaxQueueSize = 100
        ContextualHistoryCount = [PowerAugerPredictor]::ContextualHistory.Count
        ContextualHistoryKeys = @([PowerAugerPredictor]::ContextualHistory.Keys)
        CachePath = [PowerAugerPredictor]::CachePath
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
        # Get queue health from MessageQueue
        $queueCount = 0
        try {
            $queueCount = [PowerAugerPredictor]::MessageQueue.Count
        } catch {}

        # Get the cat display using centralized function
        $catDisplay = Get-PowerAugerCat -QueueCount $queueCount

        # Also store globally for event systems to update
        $global:PowerAugerCurrentCat = $catDisplay
        $global:PowerAugerCurrentQueueCount = $queueCount

        # Return the complete prompt string with cat and proper formatting
        # Must end with the return value that becomes the prompt
        "$catDisplay $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
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

                    # Optional: Trigger PSReadLine refresh for new predictions
                    # This is more conservative - only refresh if we have the current input
                    $currentLine = ""
                    $currentPos = 0
                    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$currentLine, [ref]$currentPos)

                    if ($currentLine -and $update.Input -and $currentLine.StartsWith($update.Input)) {
                        # We have a relevant prediction - trigger refresh
                        [Microsoft.PowerShell.PSConsoleReadLine]::Insert(' ')
                        [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar()
                    }
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
        # Silently ignore errors to not disrupt the prompt
    }
}

# Function to enable channel-based real-time updates
function Start-PowerAugerRealtimeUpdates {
    param(
        [int]$IntervalMs = 100  # Check every 100ms for updates
    )

    # Stop any existing timer
    Stop-PowerAugerRealtimeUpdates

    # Single timer for channel monitoring (not every keystroke!)
    $script:UpdateTimer = New-Object System.Timers.Timer
    $script:UpdateTimer.Interval = $IntervalMs
    $script:UpdateTimer.AutoReset = $true

    # Register timer event for channel monitoring
    Register-ObjectEvent -InputObject $script:UpdateTimer -EventName Elapsed -SourceIdentifier PowerAugerChannelMonitor -Action {
        try {
            $reader = [PowerAugerPredictor]::UpdateChannel.Reader
            $hasUpdates = $false
            $latestQueueCount = -1

            # Process ALL pending updates (drain the channel)
            while ($reader.TryRead([ref]$update)) {
                switch ($update.Type) {
                    'PredictionComplete' {
                        $hasUpdates = $true
                        if ($update.QueueCount -ge 0) {
                            $latestQueueCount = $update.QueueCount
                        }
                    }
                    'QueueChanged' {
                        $hasUpdates = $true
                        if ($update.QueueCount -ge 0) {
                            $latestQueueCount = $update.QueueCount
                        }
                    }
                    'BackgroundStarted' {
                        $hasUpdates = $true
                        if ($update.QueueCount -ge 0) {
                            $latestQueueCount = $update.QueueCount
                        }
                    }
                    'BackgroundStopping' {
                        $latestQueueCount = 0
                        $hasUpdates = $true
                    }
                }
            }

            # Update cat ONCE with the latest queue count
            if ($hasUpdates -and $latestQueueCount -ge 0) {
                $global:PowerAugerCurrentCat = Get-PowerAugerCat -QueueCount $latestQueueCount
                $global:PowerAugerCurrentQueueCount = $latestQueueCount

                # Trigger prompt refresh (safer than manipulating buffer)
                # This will cause the prompt function to be called again
                [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
            }
        } catch {
            # Silent fail to avoid disrupting the terminal
        }
    } | Out-Null

    $script:UpdateTimer.Start()

    Write-Host "PowerAuger real-time updates enabled!" -ForegroundColor Green
    Write-Host "Channel monitoring every ${IntervalMs}ms for cat updates." -ForegroundColor Cyan
}

# Function to stop real-time updates
function Stop-PowerAugerRealtimeUpdates {
    if ($script:UpdateTimer) {
        $script:UpdateTimer.Stop()
        $script:UpdateTimer.Dispose()
        $script:UpdateTimer = $null
    }

    # Unregister the event
    Get-EventSubscriber -SourceIdentifier PowerAugerChannelMonitor -ErrorAction SilentlyContinue | Unregister-Event
    Remove-Job -Name PowerAugerChannelMonitor -Force -ErrorAction SilentlyContinue
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
    Write-Host "  Legacy Cache: $([PowerAugerPredictor]::Cache.Count)"
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

    # Stop real-time updates timer if running
    Stop-PowerAugerRealtimeUpdates

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
            # NOW safe to save cache after background has stopped
            try {
                $cachePath = [PowerAugerPredictor]::CachePath
                $cacheDir = Split-Path -Path $cachePath -Parent
                if (-not (Test-Path $cacheDir)) {
                    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                }

                # Save both legacy cache and ResponseCache
                $cacheData = @{}

                # Get from legacy cache
                foreach ($key in [PowerAugerPredictor]::Cache.Keys) {
                    $cacheData[$key] = [PowerAugerPredictor]::Cache[$key]
                }

                # Also get from ResponseCache
                foreach ($key in [PowerAugerPredictor]::ResponseCache.Keys) {
                    if (-not $cacheData.ContainsKey($key)) {
                        $value = $null
                        if ([PowerAugerPredictor]::ResponseCache.TryGetValue($key, [ref]$value)) {
                            $cacheData[$key] = $value
                        }
                    }
                }

                if ($cacheData.Count -gt 0) {
                    $cacheData | ConvertTo-Json -Depth 3 | Set-Content -Path $cachePath -Force
                    Write-Host "PowerAuger: Saved $($cacheData.Count) AI completions to cache" -ForegroundColor Green
                }
            } catch {
                Write-Warning "Failed to save PowerAuger cache on exit: $_"
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
