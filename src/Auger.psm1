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
    hidden static [System.Collections.ArrayList] $HistoryExamples = @()

    # Enhanced contextual learning system (hashtable with command|path keys)
    hidden static [hashtable] $ContextualHistory = @{}
    hidden static [int] $MaxContextualHistorySize = 300

    # Background prediction infrastructure
    hidden static [System.Management.Automation.Runspaces.Runspace] $PredictionRunspace = $null
    hidden static [System.Management.Automation.PowerShell] $PredictionPowerShell = $null
    hidden static [System.Collections.Concurrent.ConcurrentQueue[hashtable]] $PredictionQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
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

            # Share variables with the runspace
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('Cache', [PowerAugerPredictor]::Cache)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('Queue', [PowerAugerPredictor]::PredictionQueue)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('Model', [PowerAugerPredictor]::Model)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('ApiUrl', [PowerAugerPredictor]::ApiUrl)

            # Pass history examples to background runspace
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('HistoryExamples', [PowerAugerPredictor]::HistoryExamples)
            [PowerAugerPredictor]::PredictionRunspace.SessionStateProxy.SetVariable('ContextualHistory', [PowerAugerPredictor]::ContextualHistory)

            # Create the background script - NO PARAMETERS, use variables directly
            $backgroundScript = {
                # Access shared variables directly from runspace - these are references, not copies!
                $lastSaveTime = Get-Date
                $saveIntervalMinutes = 5

                while ($true) {
                    try {
                        $request = $null
                        if ($Queue.TryDequeue([ref]$request)) {
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
                                # Add to cache
                                $Cache[$request.Input] = @{
                                    Completion = $response.response.Trim()
                                    Timestamp = Get-Date
                                }

                                # Signal that new completions are available
                                $Cache['_new_completions'] = $true
                            }
                        }

                        # Pre-fetch common prefixes ONCE at startup
                        if ($Cache.Count -eq 0 -and -not $Cache.ContainsKey('_initialized')) {
                            foreach ($prefix in @("Get-", "Set-", "New-", "Remove-")) {
                                if (-not $Cache.ContainsKey($prefix)) {
                                    $Queue.Enqueue(@{Input = $prefix})
                                }
                            }
                            # Mark that we've done initial warming
                            $Cache['_initialized'] = @{ Completion = "true"; Timestamp = Get-Date }
                        }

                        # Periodic cache save every 5 minutes
                        if ((Get-Date) - $lastSaveTime -gt [TimeSpan]::FromMinutes($saveIntervalMinutes)) {
                            try {
                                # Only save if cache has real entries (not just _initialized)
                                if ($Cache.Count -gt 1) {
                                    $cachePath = "$env:LOCALAPPDATA\PowerAuger\ai_cache.json"
                                    $cacheDir = Split-Path -Path $cachePath -Parent
                                    if (-not (Test-Path $cacheDir)) {
                                        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                                    }

                                    # Filter out internal keys when saving
                                    $cacheData = @{}
                                    foreach ($key in $Cache.Keys) {
                                        if ($key -notmatch '^_') {
                                            $cacheData[$key] = $Cache[$key]
                                        }
                                    }

                                    $cacheData | ConvertTo-Json -Depth 3 | Set-Content -Path $cachePath -Force
                                    $lastSaveTime = Get-Date
                                }
                            } catch {
                                # Silent fail - don't disrupt background processing
                            }
                        }

                        Start-Sleep -Milliseconds 200
                    }
                    catch {
                        # Continue on error
                        Start-Sleep -Milliseconds 500
                    }
                }
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
                [PowerAugerPredictor]::PredictionQueue.Count -lt 50 -and
                $tabCompletions -and $tabCompletions.CompletionMatches.Count -gt 0) {

                # Get the top command completion
                $topCompletion = $tabCompletions.CompletionMatches |
                    Where-Object { $_.ResultType -eq 'Command' } |
                    Select-Object -First 1

                if ($topCompletion) {
                    $completionText = $topCompletion.CompletionText

                    # Check if not already cached or queued
                    if (-not [PowerAugerPredictor]::Cache.ContainsKey($completionText)) {
                        # Check if not already in queue (avoid duplicates)
                        $alreadyQueued = $false
                        try {
                            # Note: ConcurrentQueue doesn't have Contains, so track separately if needed
                            # For now, just queue it - duplicates are handled by cache check in background
                        } catch {}

                        if (-not $alreadyQueued) {
                            [PowerAugerPredictor]::PredictionQueue.Enqueue(@{
                                Input = $completionText
                                Context = $currentContext
                            })
                        }
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
                [PowerAugerPredictor]::HistoryExamples.Add(@{
                    Prefix = $prefix
                    Completion = $completion
                })

                # Keep only recent simple examples
                if ([PowerAugerPredictor]::HistoryExamples.Count -gt 30) {
                    [PowerAugerPredictor]::HistoryExamples.RemoveAt(0)
                }
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
function Get-PowerAugerInternals {
    @{
        IsBackgroundRunning = [PowerAugerPredictor]::IsBackgroundRunning
        CacheCount = [PowerAugerPredictor]::Cache.Count
        CacheKeys = @([PowerAugerPredictor]::Cache.Keys)
        QueueCount = [PowerAugerPredictor]::PredictionQueue.Count
        ContextualHistoryCount = [PowerAugerPredictor]::ContextualHistory.Count
        ContextualHistoryKeys = @([PowerAugerPredictor]::ContextualHistory.Keys)
        CachePath = [PowerAugerPredictor]::CachePath
        RunspaceState = if ([PowerAugerPredictor]::PredictionRunspace) { [PowerAugerPredictor]::PredictionRunspace.RunspaceStateInfo.State } else { "Not created" }
    }
}

# Function to test cache sharing
function Test-PowerAugerCacheSharing {
    Write-Host "Testing cache sharing..." -ForegroundColor Cyan

    # Initial state
    $before = [PowerAugerPredictor]::Cache.Count
    Write-Host "  Cache entries before: $before"

    # Queue some predictions
    Write-Host "  Queueing predictions..."
    [PowerAugerPredictor]::PredictionQueue.Enqueue(@{Input = "Get-Process"; Context = @{DirName = "Test"}})
    [PowerAugerPredictor]::PredictionQueue.Enqueue(@{Input = "Get-Service"; Context = @{DirName = "Test"}})
    [PowerAugerPredictor]::PredictionQueue.Enqueue(@{Input = "Get-ChildItem"; Context = @{DirName = "Test"}})

    Write-Host "  Queue size: $([PowerAugerPredictor]::PredictionQueue.Count)"
    Write-Host "  Waiting 3 seconds for background processing..."
    Start-Sleep -Seconds 3

    $after = [PowerAugerPredictor]::Cache.Count
    Write-Host "  Cache entries after: $after"

    if ($after -gt $before) {
        Write-Host "  ✅ Cache is being populated by background!" -ForegroundColor Green
        Write-Host "  New cache keys:"
        [PowerAugerPredictor]::Cache.Keys | Select-Object -First 5 | ForEach-Object { Write-Host "    - $_" }
    } else {
        Write-Host "  ❌ Cache not growing - checking runspace..." -ForegroundColor Red

        if ([PowerAugerPredictor]::PredictionRunspace) {
            $rs = [PowerAugerPredictor]::PredictionRunspace
            try {
                $rsCache = $rs.SessionStateProxy.GetVariable('Cache')
                Write-Host "  Runspace cache count: $($rsCache.Count)"
                Write-Host "  Same object? $([Object]::ReferenceEquals($rsCache, [PowerAugerPredictor]::Cache))"
            } catch {
                Write-Host "  Failed to access runspace cache: $_" -ForegroundColor Red
            }
        }
    }
}

# Function to set up PowerAuger-enhanced prompt with queue health cat
function Set-PowerAugerPrompt {
    Set-PSReadLineOption -PromptText @{
        Success = {
            # Get queue health
            $queueCount = 0
            try {
                $queueCount = [PowerAugerPredictor]::PredictionQueue.Count
            } catch {}

            # Determine cat mood and color based on queue
            $cat = switch ($queueCount) {
                {$_ -eq 0}    { "$([char]0x1b)[32mᓚᘏᗢ" }     # Green - purring
                {$_ -le 3}    { "$([char]0x1b)[32mᓚᘏᗢ" }     # Green - happy
                {$_ -le 7}    { "$([char]0x1b)[36mᓚᘏᗢ" }     # Cyan - content
                {$_ -le 12}   { "$([char]0x1b)[36mᓚᘏᗢ" }     # Cyan - busy
                {$_ -le 20}   { "$([char]0x1b)[33mᓚᘏᗢ" }     # Yellow - working
                {$_ -le 30}   { "$([char]0x1b)[33mᓚᘏᗢ" }     # Yellow - concerned
                {$_ -le 45}   { "$([char]0x1b)[35mᓚᘏᗢ" }     # Magenta - worried
                {$_ -le 60}   { "$([char]0x1b)[31mᓚᘏᗢ" }     # Red - stressed
                default       { "$([char]0x1b)[31mᓚᘏᗢ" }     # Red - overwhelmed
            }
            "$cat$([char]0x1b)[0m "  # Cat with reset
        }
        Error = {
            # Always show stressed cat on error
            "$([char]0x1b)[31mᓚᘏᗢ$([char]0x1b)[0m "
        }
    }

    Write-Host "PowerAuger prompt with queue health cat enabled!" -ForegroundColor Green
    Write-Host "The cat in your prompt will change color based on AI queue pressure." -ForegroundColor Cyan
}

# Alternative: Function to create a custom prompt function
function Start-PowerAugerPrompt {
    # This replaces the entire prompt function
    function global:prompt {
        # Get queue health
        $queueCount = 0
        try {
            $queueCount = [PowerAugerPredictor]::PredictionQueue.Count
        } catch {}

        # Determine cat and color
        $catInfo = switch ($queueCount) {
            {$_ -eq 0}    { @{Cat="ᓚᘏᗢ"; Color="Green"} }
            {$_ -le 3}    { @{Cat="ᓚᘏᗢ"; Color="DarkGreen"} }
            {$_ -le 7}    { @{Cat="ᓚᘏᗢ"; Color="Cyan"} }
            {$_ -le 12}   { @{Cat="ᓚᘏᗢ"; Color="DarkCyan"} }
            {$_ -le 20}   { @{Cat="ᓚᘏᗢ"; Color="Yellow"} }
            {$_ -le 30}   { @{Cat="ᓚᘏᗢ"; Color="DarkYellow"} }
            {$_ -le 45}   { @{Cat="ᓚᘏᗢ"; Color="Magenta"} }
            {$_ -le 60}   { @{Cat="ᓚᘏᗢ"; Color="Red"} }
            default       { @{Cat="ᓚᘏᗢ"; Color="DarkRed"} }
        }

        # Build prompt with cat
        Write-Host $catInfo.Cat -NoNewline -ForegroundColor $catInfo.Color
        Write-Host " $($PWD.Path)" -NoNewline -ForegroundColor White
        return "> "
    }

    Write-Host "PowerAuger prompt enabled! Your prompt now shows queue health." -ForegroundColor Green
}

# Function to register event-driven completion notifications
function Register-PowerAugerEvents {
    # Register an idle action that runs periodically
    Register-EngineEvent -SourceIdentifier PowerShell.OnIdle -Action {
        try {
            # Get current queue state
            $queueCount = [PowerAugerPredictor]::PredictionQueue.Count
            $cacheCount = [PowerAugerPredictor]::Cache.Count

            # Store previous state to detect changes
            if (-not $global:PowerAugerLastState) {
                $global:PowerAugerLastState = @{
                    QueueCount = $queueCount
                    CacheCount = $cacheCount
                    LastCat = ""
                }
            }

            # Determine current cat state
            $catInfo = switch ($queueCount) {
                {$_ -eq 0}    { @{Cat="ᓚᘏᗢ"; Color="Green"} }
                {$_ -le 3}    { @{Cat="ᓚᘏᗢ"; Color="DarkGreen"} }
                {$_ -le 7}    { @{Cat="ᓚᘏᗢ"; Color="Cyan"} }
                {$_ -le 12}   { @{Cat="ᓚᘏᗢ"; Color="DarkCyan"} }
                {$_ -le 20}   { @{Cat="ᓚᘏᗢ"; Color="Yellow"} }
                {$_ -le 30}   { @{Cat="ᓚᘏᗢ"; Color="DarkYellow"} }
                {$_ -le 45}   { @{Cat="ᓚᘏᗢ"; Color="Magenta"} }
                {$_ -le 60}   { @{Cat="ᓚᘏᗢ"; Color="Red"} }
                default       { @{Cat="ᓚᘏᗢ"; Color="DarkRed"} }
            }

            # Check if cache grew (new completions arrived)
            $cacheGrew = $cacheCount -gt $global:PowerAugerLastState.CacheCount

            # Check if queue changed significantly
            $queueChanged = [Math]::Abs($queueCount - $global:PowerAugerLastState.QueueCount) -gt 5

            if ($cacheGrew -or $queueChanged) {
                # Trigger refresh by sending a virtual keystroke
                # This simulates typing to trigger new suggestions
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert('')
                [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar()

                # Visual feedback - briefly flash the prompt
                if ($cacheGrew) {
                    Write-Host "`r$($catInfo.Cat) " -NoNewline -ForegroundColor $catInfo.Color
                }
            }

            # Update state
            $global:PowerAugerLastState.QueueCount = $queueCount
            $global:PowerAugerLastState.CacheCount = $cacheCount
            $global:PowerAugerLastState.LastCat = $catInfo.Cat

        } catch {
            # Silently fail to not disrupt terminal
        }
    }

    Write-Host "PowerAuger event engine registered!" -ForegroundColor Green
    Write-Host "The prompt will auto-refresh when new AI completions arrive." -ForegroundColor Cyan
}

# Function to unregister events
function Unregister-PowerAugerEvents {
    Get-EventSubscriber | Where-Object { $_.SourceIdentifier -eq 'PowerShell.OnIdle' } | Unregister-Event
    Remove-Variable -Name PowerAugerLastState -Scope Global -ErrorAction SilentlyContinue
    Write-Host "PowerAuger events unregistered." -ForegroundColor Yellow
}

# Alternative approach using a timer for more control
function Start-PowerAugerAutoRefresh {
    param(
        [int]$IntervalMs = 500  # Check every 500ms
    )

    # Create a timer that checks for changes
    $timer = New-Object System.Timers.Timer
    $timer.Interval = $IntervalMs
    $timer.AutoReset = $true

    # Store timer globally so we can stop it later
    $global:PowerAugerRefreshTimer = $timer

    # Initialize state tracking
    $global:PowerAugerLastState = @{
        QueueCount = [PowerAugerPredictor]::PredictionQueue.Count
        CacheCount = [PowerAugerPredictor]::Cache.Count
        CurrentInput = ""
    }

    # Register timer event
    Register-ObjectEvent -InputObject $timer -EventName Elapsed -SourceIdentifier PowerAugerRefresh -Action {
        try {
            # Check for new completions flag
            $hasNewCompletions = [PowerAugerPredictor]::Cache.ContainsKey('_new_completions')

            if ($hasNewCompletions) {
                # Clear the flag first
                [PowerAugerPredictor]::Cache.Remove('_new_completions')

                # Get current input from PSReadLine
                $currentLine = ""
                $currentPos = 0
                [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$currentLine, [ref]$currentPos)

                # Only refresh if user has typed something meaningful
                if ($currentLine.Length -gt 2) {
                    # Check if we have a relevant completion for current input
                    $hasRelevantCompletion = $false

                    # Check exact match
                    if ([PowerAugerPredictor]::Cache.ContainsKey($currentLine)) {
                        $hasRelevantCompletion = $true
                    }
                    # Check if current input is a prefix of any cached completion
                    else {
                        foreach ($key in [PowerAugerPredictor]::Cache.Keys) {
                            if ($key.StartsWith($currentLine, 'CurrentCultureIgnoreCase')) {
                                $hasRelevantCompletion = $true
                                break
                            }
                        }
                    }

                    if ($hasRelevantCompletion) {
                        # Trigger suggestion refresh by simulating a micro-edit
                        # This is the least intrusive way to get PSReadLine to re-query predictions
                        [Microsoft.PowerShell.PSConsoleReadLine]::Insert(' ')
                        [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar()
                    }
                }
            }

            # Update queue tracking for the cat indicator
            $global:PowerAugerLastState.QueueCount = [PowerAugerPredictor]::PredictionQueue.Count
            $global:PowerAugerLastState.CurrentInput = $currentLine

        } catch {
            # Silent fail
        }
    }

    # Start the timer
    $timer.Start()

    Write-Host "PowerAuger auto-refresh enabled!" -ForegroundColor Green
    Write-Host "Suggestions will update automatically as AI completions arrive." -ForegroundColor Cyan
    Write-Host "Check every ${IntervalMs}ms. Use Stop-PowerAugerAutoRefresh to stop." -ForegroundColor Gray
}

# Function to disable auto-refresh
function Stop-PowerAugerAutoRefresh {
    if ($global:PowerAugerRefreshTimer) {
        $global:PowerAugerRefreshTimer.Stop()
        Unregister-Event -SourceIdentifier PowerAugerRefresh -ErrorAction SilentlyContinue
        Remove-Variable -Name PowerAugerRefreshTimer -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name PowerAugerLastState -Scope Global -ErrorAction SilentlyContinue
        Write-Host "PowerAuger auto-refresh disabled." -ForegroundColor Yellow
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
function Show-PowerAugerStatus {
    Write-Host "PowerAuger Predictor Status:" -ForegroundColor Cyan
    Write-Host "  Contextual history: $([PowerAugerPredictor]::ContextualHistory.Count)" -ForegroundColor Green
    Write-Host "  AI Cache (background): $([PowerAugerPredictor]::Cache.Count)"
    Write-Host "  Model: $([PowerAugerPredictor]::Model)"
    Write-Host "  Background engine: $(if ([PowerAugerPredictor]::IsBackgroundRunning) { '✅ Running' } else { '❌ Stopped' })" -ForegroundColor $(if ([PowerAugerPredictor]::IsBackgroundRunning) { 'Green' } else { 'Red' })

    # Show queue status with gradient cat health indicator
    $queueCount = 0
    try {
        $queueCount = [PowerAugerPredictor]::PredictionQueue.Count
    } catch {}

    # Queue health gradient using Nightdrive theme
    # 9 states from happy (green) to stressed (magenta/orange)
    $queueHealth = switch ($queueCount) {
        {$_ -eq 0}    { @{ Cat = "ᓚᘏᗢ"; Color = "Green"; Desc = "purring" } }      # Success - #A6E22E
        {$_ -le 3}    { @{ Cat = "ᓚᘏᗢ"; Color = "DarkGreen"; Desc = "happy" } }
        {$_ -le 7}    { @{ Cat = "ᓚᘏᗢ"; Color = "Cyan"; Desc = "content" } }      # Secondary - #66D9EF
        {$_ -le 12}   { @{ Cat = "ᓚᘏᗢ"; Color = "DarkCyan"; Desc = "busy" } }
        {$_ -le 20}   { @{ Cat = "ᓚᘏᗢ"; Color = "Yellow"; Desc = "working" } }    # Accent - #E6DB74
        {$_ -le 30}   { @{ Cat = "ᓚᘏᗢ"; Color = "DarkYellow"; Desc = "concerned" } }
        {$_ -le 45}   { @{ Cat = "ᓚᘏᗢ"; Color = "Magenta"; Desc = "worried" } }   # Info - #AE81FF
        {$_ -le 60}   { @{ Cat = "ᓚᘏᗢ"; Color = "Red"; Desc = "stressed" } }      # Error - #FD971F
        default       { @{ Cat = "ᓚᘏᗢ"; Color = "DarkRed"; Desc = "overwhelmed" } } # Primary - #F92672
    }

    Write-Host "  Queue: $queueCount $($queueHealth.Cat) ($($queueHealth.Desc))" -ForegroundColor $queueHealth.Color

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

    # Show cache samples
    if ([PowerAugerPredictor]::Cache.Count -gt 0) {
        Write-Host "`n  Sample cache entries:" -ForegroundColor Yellow
        $shown = 0
        foreach ($key in [PowerAugerPredictor]::Cache.Keys) {
            if ($shown -ge 3) { break }
            $cached = [PowerAugerPredictor]::Cache[$key]
            if ($cached) {
                # Handle both direct string and hashtable with Completion property
                $completion = if ($cached -is [string]) {
                    $cached
                } elseif ($cached.Completion) {
                    $cached.Completion
                } else {
                    $null
                }

                if ($completion) {
                    $preview = $completion.Substring(0, [Math]::Min(20, $completion.Length))
                    Write-Host "    '$key' → '$preview...'"
                    $shown++
                }
            }
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

    # Auto-enable the refresh timer for live updates
    Start-PowerAugerAutoRefresh -IntervalMs 750

} catch {
    # First time registration
    try {
        $predictorInstance = [PowerAugerPredictor]::new()
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
            [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
            $predictorInstance
        )
        Write-Host "PowerAuger predictor registered successfully." -ForegroundColor Green

        # Auto-enable the refresh timer for live updates
        Start-PowerAugerAutoRefresh -IntervalMs 750

    } catch {
        Write-Warning "Failed to register PowerAuger predictor: $_"
    }
}

# Register cleanup on module removal
$ExecutionContext.SessionState.Module.OnRemove = {
    # Disable auto-refresh if running
    Stop-PowerAugerAutoRefresh

    # Save cache before stopping
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

        if ($cacheData.Count -gt 0) {
            $cacheData | ConvertTo-Json -Depth 3 | Set-Content -Path $cachePath -Force
            Write-Host "PowerAuger: Saved $($cacheData.Count) AI completions to cache" -ForegroundColor Green
        }
    } catch {
        Write-Warning "Failed to save PowerAuger cache on exit: $_"
    }

    # Stop background engine
    Stop-PowerAugerBackground

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
}
