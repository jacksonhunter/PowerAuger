# PowerAugerCompletion.psm1 - Ctrl+Space triggered AI completions with smart caching

# Cache structure: Key = "directory|input", Value = completion history
$script:CompletionCache = @{}

# Persistent cache path
$script:CachePath = "$env:LOCALAPPDATA\PowerAuger\completion_cache.json"

# Load cache from disk
function Initialize-CompletionCache {
    if (Test-Path $script:CachePath) {
        try {
            $data = Get-Content $script:CachePath -Raw | ConvertFrom-Json -AsHashtable
            $script:CompletionCache = $data
            Write-Host "Loaded $($script:CompletionCache.Count) cached completion patterns" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to load completion cache: $_"
            $script:CompletionCache = @{}
        }
    } else {
        # Ensure directory exists
        $dir = Split-Path $script:CachePath -Parent
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

# Save cache to disk
function Save-CompletionCache {
    try {
        $script:CompletionCache | ConvertTo-Json -Depth 4 |
            Set-Content -Path $script:CachePath -Force
        Write-Host "Saved $($script:CompletionCache.Count) completion patterns" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to save completion cache: $_"
    }
}

# Track when a completion is accepted
function Add-CompletionToCache {
    param(
        [string]$Directory,
        [string]$Input,
        [string]$Completion,
        [hashtable]$Context = @{}
    )

    $key = "$Directory|$Input"

    if (-not $script:CompletionCache.ContainsKey($key)) {
        $script:CompletionCache[$key] = @{
            Completions = @()
            LastUsed = Get-Date
            TotalUses = 0
        }
    }

    # Find or add this specific completion
    $existing = $script:CompletionCache[$key].Completions |
        Where-Object { $_.Text -eq $Completion } |
        Select-Object -First 1

    if ($existing) {
        $existing.Count++
        $existing.LastUsed = Get-Date
    } else {
        $script:CompletionCache[$key].Completions += @{
            Text = $Completion
            Count = 1
            LastUsed = Get-Date
            Context = $Context
        }
    }

    $script:CompletionCache[$key].TotalUses++
    $script:CompletionCache[$key].LastUsed = Get-Date
}

# Get relevant examples from cache for multishot
function Get-CachedExamples {
    param(
        [string]$Directory,
        [string]$Input,
        [int]$MaxExamples = 3
    )

    $examples = @()

    # First, try exact directory match
    $exactKey = "$Directory|$Input"
    if ($script:CompletionCache.ContainsKey($exactKey)) {
        $cached = $script:CompletionCache[$exactKey]
        $topCompletions = $cached.Completions |
            Sort-Object -Property Count -Descending |
            Select-Object -First $MaxExamples

        foreach ($comp in $topCompletions) {
            $examples += @{
                Input = $Input
                Output = $comp.Text
                Count = $comp.Count
                Directory = $Directory
            }
        }
    }

    # If not enough examples, look for similar inputs in same directory
    if ($examples.Count -lt $MaxExamples) {
        $prefix = ($Input -split '-')[0]
        $similarKeys = $script:CompletionCache.Keys |
            Where-Object { $_ -like "$Directory|$prefix*" -and $_ -ne $exactKey }

        foreach ($key in $similarKeys) {
            if ($examples.Count -ge $MaxExamples) { break }

            $parts = $key -split '\|'
            $cachedInput = $parts[1]
            $cached = $script:CompletionCache[$key]

            $bestCompletion = $cached.Completions |
                Sort-Object -Property Count -Descending |
                Select-Object -First 1

            if ($bestCompletion) {
                $examples += @{
                    Input = $cachedInput
                    Output = $bestCompletion.Text
                    Count = $bestCompletion.Count
                    Directory = $Directory
                }
            }
        }
    }

    # If still not enough, look in other directories
    if ($examples.Count -lt $MaxExamples) {
        $otherKeys = $script:CompletionCache.Keys |
            Where-Object { $_ -like "*|$Input" -and $_ -notlike "$Directory|*" } |
            Select-Object -First ($MaxExamples - $examples.Count)

        foreach ($key in $otherKeys) {
            $parts = $key -split '\|'
            $dir = $parts[0]
            $cached = $script:CompletionCache[$key]

            $bestCompletion = $cached.Completions |
                Sort-Object -Property Count -Descending |
                Select-Object -First 1

            if ($bestCompletion) {
                $examples += @{
                    Input = $Input
                    Output = $bestCompletion.Text
                    Count = $bestCompletion.Count
                    Directory = $dir
                }
            }
        }
    }

    return $examples
}

# Build FIM prompt with cached examples
function Build-CompletionPrompt {
    param(
        [string]$Input,
        [string]$Directory = $PWD.Path,
        [array]$TabCompletions = @(),
        [array]$CachedExamples = @()
    )

    $prompt = ""

    # Add cached examples as multishot
    foreach ($example in $CachedExamples) {
        $prompt += "<|fim_prefix|>$($example.Directory)|$($example.Input)<|fim_suffix|><|fim_middle|>$($example.Output)`n"
    }

    # Add TabExpansion2 completions as context (first 50)
    $tabContext = ""
    if ($TabCompletions.Count -gt 0) {
        $completionTexts = $TabCompletions |
            Select-Object -First 50 -ExpandProperty CompletionText
        $tabContext = $completionTexts -join ','
    }

    # Add current request
    $prompt += "<|fim_prefix|>$Directory|$tabContext|$Input<|fim_suffix|><|fim_middle|>"

    return $prompt
}

# Main completion function
function Invoke-PowerAugerCompletion {
    param(
        [string]$Line,
        [int]$Cursor
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Extract the current token being completed
    $tokens = $Line.Substring(0, $Cursor) -split '\s+'
    $currentInput = $tokens[-1]

    if ([string]::IsNullOrEmpty($currentInput)) {
        Write-Host "No input to complete" -ForegroundColor Yellow
        return $null
    }

    Write-Host "`nPowerAuger: Completing '$currentInput'..." -ForegroundColor Cyan

    # Get TabExpansion2 completions for context
    $tabSw = [System.Diagnostics.Stopwatch]::StartNew()
    $tabResult = TabExpansion2 -inputScript $Line -cursorColumn $Cursor
    $tabSw.Stop()

    $tabCompletions = @()
    if ($tabResult -and $tabResult.CompletionMatches.Count -gt 0) {
        $tabCompletions = $tabResult.CompletionMatches
        Write-Host "  Found $($tabCompletions.Count) TabExpansion2 completions ($($tabSw.ElapsedMilliseconds)ms)" -ForegroundColor DarkGray
    }

    # Get cached examples
    $examples = Get-CachedExamples -Directory $PWD.Path -Input $currentInput -MaxExamples 3
    if ($examples.Count -gt 0) {
        Write-Host "  Using $($examples.Count) cached examples" -ForegroundColor DarkGray
    }

    # Build prompt
    $prompt = Build-CompletionPrompt -Input $currentInput -Directory $PWD.Path `
        -TabCompletions $tabCompletions -CachedExamples $examples

    Write-Host "  Prompt size: $($prompt.Length) chars" -ForegroundColor DarkGray

    # Call Ollama
    try {
        $body = @{
            model = "qwen2.5-0.5B-autocomplete-custom"
            prompt = $prompt
            stream = $false
            options = @{
                num_predict = 100
                temperature = 0.2
                top_p = 0.9
            }
        } | ConvertTo-Json -Depth 3

        $ollSw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" `
            -Method Post -Body $body -ContentType 'application/json' `
            -TimeoutSec 2
        $ollSw.Stop()

        Write-Host "  Ollama responded in $($ollSw.ElapsedMilliseconds)ms" -ForegroundColor DarkGray

        $completion = $response.response.Trim()

        if ($completion) {
            # Add to cache (will be confirmed if user accepts it)
            $script:PendingCompletion = @{
                Directory = $PWD.Path
                Input = $currentInput
                Completion = $completion
                Context = @{
                    TabCompletionCount = $tabCompletions.Count
                    CachedExamples = $examples.Count
                    Timestamp = Get-Date
                }
            }

            $sw.Stop()
            Write-Host "  Total time: $($sw.ElapsedMilliseconds)ms" -ForegroundColor Green

            return $completion
        }
    } catch {
        Write-Warning "Ollama request failed: $_"
    }

    $sw.Stop()
    return $null
}

# PSReadLine key handler for Ctrl+Space
function Set-PowerAugerKeyHandler {
    Set-PSReadLineKeyHandler -Key Ctrl+Spacebar -ScriptBlock {
        $line = $null
        $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

        $completion = Invoke-PowerAugerCompletion -Line $line -Cursor $cursor

        if ($completion) {
            # Find where current token starts
            $tokens = $line.Substring(0, $cursor) -split '\s+'
            $currentToken = $tokens[-1]

            if ($currentToken.Length -gt 0) {
                # Delete current partial input
                for ($i = 0; $i -lt $currentToken.Length; $i++) {
                    [Microsoft.PowerShell.PSConsoleReadLine]::BackwardDeleteChar()
                }
            }

            # Insert the completion
            [Microsoft.PowerShell.PSConsoleReadLine]::Insert($completion)

            # Track this as pending (will confirm on accept)
            $script:LastInsertion = @{
                Line = $line
                Cursor = $cursor
                Completion = $completion
                Timestamp = Get-Date
            }
        } else {
            Write-Host "No completion available" -ForegroundColor Yellow
        }
    }.GetNewClosure()

    # Also set up handler to track accepted completions
    Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
        # Check if we just inserted a completion
        if ($script:PendingCompletion) {
            $pending = $script:PendingCompletion

            # Verify the line still contains our completion
            $line = $null
            $cursor = $null
            [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)

            if ($line -like "*$($pending.Completion)*") {
                # Add to cache as accepted
                Add-CompletionToCache -Directory $pending.Directory `
                    -Input $pending.Input -Completion $pending.Completion `
                    -Context $pending.Context

                # Save cache periodically (every 10 acceptances)
                if (($script:CompletionCache.Values.TotalUses | Measure-Object -Sum).Sum % 10 -eq 0) {
                    Save-CompletionCache
                }
            }

            $script:PendingCompletion = $null
        }

        # Execute the default Enter behavior
        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }.GetNewClosure()

    Write-Host "PowerAuger completion handler installed (Ctrl+Space)" -ForegroundColor Green
}

# Module initialization
Initialize-CompletionCache

# Export functions
Export-ModuleMember -Function @(
    'Set-PowerAugerKeyHandler',
    'Invoke-PowerAugerCompletion',
    'Save-CompletionCache',
    'Add-CompletionToCache',
    'Get-CachedExamples'
)