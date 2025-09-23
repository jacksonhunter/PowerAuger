# PowerAuger.psm1 - Proper predictor plugin with Ollama

using namespace System.Management.Automation.Subsystem
using namespace System.Management.Automation.Subsystem.Prediction

class PowerAugerPredictor : ICommandPredictor {
    [guid] $Id
    [string] $Name
    [string] $Description

    # Cache for performance
    hidden static [hashtable] $Cache = @{}
    hidden static [datetime] $CacheTime = [DateTime]::MinValue
    hidden static [int] $CacheTimeoutSeconds = 3

    # Configuration
    hidden static [string] $Model = "qwen2.5-0.5B-autocomplete-custom"
    hidden static [string] $ApiUrl = "http://127.0.0.1:11434"

    # History context
    hidden static [System.Collections.ArrayList] $HistoryExamples = @()

    PowerAugerPredictor() {
        $this.Id = [guid]::Parse('a1b2c3d4-e5f6-7890-abcd-ef1234567890')
        $this.Name = 'PowerAuger'
        $this.Description = 'Ollama-powered AI completions with history learning'

        # Pre-load some history examples on initialization
        $this.LoadHistoryExamples()
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
            $input = $context.InputAst.Extent.Text

            # Skip if too short or looks like a question
            if ($input.Length -lt 2 -or $input -match '^\s*(how|what|why|when|where|who)\s') {
                return $null
            }

            # Check cache first (for performance)
            $cacheKey = $input.GetHashCode()
            $now = [DateTime]::UtcNow

            if ([PowerAugerPredictor]::Cache.ContainsKey($cacheKey)) {
                $cached = [PowerAugerPredictor]::Cache[$cacheKey]
                if (($now - [PowerAugerPredictor]::CacheTime).TotalSeconds -lt [PowerAugerPredictor]::CacheTimeoutSeconds) {
                    return $cached
                }
            }

            # Build FIM prompt with history context
            $prompt = $this.BuildContextualPrompt($input)

            # Call Ollama API
            $completion = $this.GetOllamaCompletion($prompt)

            if ($completion) {
                # Create suggestions
                $suggestions = [System.Collections.Generic.List[PredictiveSuggestion]]::new()

                # Add the AI completion
                $fullSuggestion = $input + $completion
                $suggestions.Add([PredictiveSuggestion]::new(
                        $fullSuggestion,
                        "AI: $completion"
                ))

                # Also add relevant history matches
                $historyMatches = Get-History -Count 100 |
                        Where-Object { $_.CommandLine.StartsWith($input, 'CurrentCultureIgnoreCase') } |
                        Select-Object -First 2 -ExpandProperty CommandLine

                foreach ($match in $historyMatches) {
                    if ($match -ne $fullSuggestion) {
                        $suggestions.Add([PredictiveSuggestion]::new(
                                $match,
                                "History: $match"
                        ))
                    }
                }

                $package = [SuggestionPackage]::new($suggestions)

                # Cache the result
                [PowerAugerPredictor]::Cache[$cacheKey] = $package
                [PowerAugerPredictor]::CacheTime = $now

                return $package
            }
        } catch {
            # Return null on any error - don't break PSReadLine
        }

        return $null
    }

    hidden [string] BuildContextualPrompt([string] $input) {
        $prompt = ""

        # Add 2-3 history examples as context
        $examples = [PowerAugerPredictor]::HistoryExamples |
                Get-Random -Count ([Math]::Min(2, [PowerAugerPredictor]::HistoryExamples.Count))

        foreach ($ex in $examples) {
            $prompt += "<|fim_prefix|>$($ex.Prefix)<|fim_suffix|><|fim_middle|>$($ex.Completion)`n"
        }

        # Add the actual request
        $prompt += "<|fim_prefix|>$input<|fim_suffix|><|fim_middle|>"

        return $prompt
    }

    hidden [string] GetOllamaCompletion([string] $prompt) {
        try {
            $body = @{
                model = [PowerAugerPredictor]::Model
                prompt = $prompt
                stream = $false
                options = @{
                    num_predict = 80
                    temperature = 0.2
                    top_p = 0.9
                }
            } | ConvertTo-Json -Depth 3

            # Quick timeout for responsiveness
            $response = Invoke-RestMethod `
                -Uri "$([PowerAugerPredictor]::ApiUrl)/api/generate" `
                -Method Post `
                -Body $body `
                -ContentType 'application/json' `
                -TimeoutSec 2 `
                -ErrorAction Stop

            if ($response.response) {
                return $response.response.Trim()
            }
        } catch {
            # Silently fail
        }

        return $null
    }

    [void] OnCommandLineAccepted([string] $commandLine) {
        # When a command is accepted, add it to our history examples
        if ($commandLine.Length -gt 15) {
            try {
                $splitPoint = [Math]::Floor($commandLine.Length * 0.6)
                [PowerAugerPredictor]::HistoryExamples.Add(@{
                    Prefix = $commandLine.Substring(0, $splitPoint)
                    Completion = $commandLine.Substring($splitPoint)
                })

                # Keep only recent examples
                if ([PowerAugerPredictor]::HistoryExamples.Count -gt 30) {
                    [PowerAugerPredictor]::HistoryExamples.RemoveAt(0)
                }
            } catch {
                # Silently fail
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

# Export a status function for debugging
function Show-PowerAugerStatus {
    Write-Host "PowerAuger Predictor Status:" -ForegroundColor Cyan
    Write-Host "  Cache entries: $([PowerAugerPredictor]::Cache.Count)"
    Write-Host "  History examples: $([PowerAugerPredictor]::HistoryExamples.Count)"
    Write-Host "  Model: $([PowerAugerPredictor]::Model)"

    try {
        $test = Invoke-RestMethod -Uri "$([PowerAugerPredictor]::ApiUrl)/api/tags" -TimeoutSec 1
        Write-Host "  Ollama: ✅ Connected" -ForegroundColor Green
    } catch {
        Write-Host "  Ollama: ❌ Not responding" -ForegroundColor Red
    }
}

# Register the predictor with the subsystem manager
$predictorInstance = [PowerAugerPredictor]::new()
[System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
    [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
    $predictorInstance
)
