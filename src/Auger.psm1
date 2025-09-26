# Auger.psm1 - Testing module for Ollama FIM prompts

# Basic working completion function from CLAUDE.md
function Get-CodeCompletion {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prefix,

        [string]$Suffix = "",

        [int]$MaxTokens = 256
    )

    $prompt = "<|fim_prefix|>$Prefix<|fim_suffix|>$Suffix<|fim_middle|>"

    $body = @{
        model = "qwen2.5-0.5B-autocomplete-custom"
        prompt = $prompt
        stream = $false
        options = @{
            num_predict = $MaxTokens
            temperature = 0.2
            top_p = 0.9
        }
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" `
                                  -Method Post -Body $body -ContentType 'application/json'
    return $response.response
}

# Test completion with context (path + completions)
function Get-ContextualCompletion {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Input,

        [string]$Path = $PWD.Path,

        [string[]]$Completions = @(),

        [int]$MaxTokens = 80
    )

    # Build context string
    $context = $Path
    if ($Completions.Count -gt 0) {
        $context += "|" + ($Completions[0..49] -join ',')  # First 50 completions
    }

    $prompt = "<|fim_prefix|>$context|$Input<|fim_suffix|><|fim_middle|>"

    Write-Host "Prompt: $prompt" -ForegroundColor DarkGray

    $body = @{
        model = "qwen2.5-0.5B-autocomplete-custom"
        prompt = $prompt
        stream = $false
        options = @{
            num_predict = $MaxTokens
            temperature = 0.2
            top_p = 0.9
        }
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" `
                                  -Method Post -Body $body -ContentType 'application/json'
    return $response.response
}

# Test multishot learning with examples
function Get-MultishotCompletion {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Input,

        [hashtable[]]$Examples = @(),

        [string]$Path = $PWD.Path,

        [int]$MaxTokens = 80
    )

    # Build multishot prompt with examples
    $prompt = ""

    # Add examples first
    foreach ($example in $Examples) {
        if ($example.Path -and $example.Input -and $example.Output) {
            $prompt += "<|fim_prefix|>$($example.Path)|$($example.Input)<|fim_suffix|><|fim_middle|>$($example.Output)`n"
        }
    }

    # Add current request
    $prompt += "<|fim_prefix|>$Path|$Input<|fim_suffix|><|fim_middle|>"

    Write-Host "Multishot prompt:`n$prompt" -ForegroundColor DarkGray

    $body = @{
        model = "qwen2.5-0.5B-autocomplete-custom"
        prompt = $prompt
        stream = $false
        options = @{
            num_predict = $MaxTokens
            temperature = 0.2
            top_p = 0.9
        }
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" `
                                  -Method Post -Body $body -ContentType 'application/json'
    return $response.response
}

# Get TabExpansion2 completions separately for testing
function Get-TabCompletions {
    param(
        [Parameter(Mandatory=$true)]
        [string]$InputText,

        [int]$MaxCompletions = 100
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tab = TabExpansion2 -inputScript $InputText -cursorColumn $InputText.Length
    $sw.Stop()

    Write-Host "TabExpansion2 took $($sw.ElapsedMilliseconds)ms" -ForegroundColor Yellow

    if ($tab -and $tab.CompletionMatches.Count -gt 0) {
        Write-Host "Found $($tab.CompletionMatches.Count) completions" -ForegroundColor Green

        # Return the full completion objects
        return $tab.CompletionMatches | Select-Object -First $MaxCompletions
    } else {
        Write-Host "No completions found" -ForegroundColor Red
        return @()
    }
}

# Test completion with TabExpansion2 results
function Get-TabExpansionCompletion {
    param(
        [Parameter(Mandatory=$true)]
        [string]$InputText,

        [int]$MaxCompletions = 50,

        [int]$MaxTokens = 80
    )

    # Get TabExpansion2 completions
    $completions = Get-TabCompletions -InputText $InputText -MaxCompletions $MaxCompletions

    # Extract completion texts
    $completionTexts = @()
    if ($completions) {
        $completionTexts = $completions | Select-Object -ExpandProperty CompletionText
    }

    # Build prompt with completions
    $context = "$($PWD.Path)|$($completionTexts -join ',')"
    $prompt = "<|fim_prefix|>$context|$InputText<|fim_suffix|><|fim_middle|>"

    Write-Host "Using $($completionTexts.Count) completions in prompt" -ForegroundColor Cyan
    Write-Host "Prompt length: $($prompt.Length) chars" -ForegroundColor Cyan

    $body = @{
        model = "qwen2.5-0.5B-autocomplete-custom"
        prompt = $prompt
        stream = $false
        options = @{
            num_predict = $MaxTokens
            temperature = 0.2
            top_p = 0.9
        }
    } | ConvertTo-Json -Depth 3

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" `
                                  -Method Post -Body $body -ContentType 'application/json'
    $sw.Stop()

    Write-Host "Ollama took $($sw.ElapsedMilliseconds)ms" -ForegroundColor Yellow

    return $response.response
}

# Test different prompt formats
function Test-PromptFormats {
    param(
        [string]$TestInput = "Get-Ch"
    )

    Write-Host "`n=== Testing Prompt Formats for: '$TestInput' ===" -ForegroundColor Green

    # Test 1: Basic (no context)
    Write-Host "`n1. Basic (prefix/suffix only):" -ForegroundColor Yellow
    $result1 = Get-CodeCompletion -Prefix $TestInput
    Write-Host "   Result: $result1" -ForegroundColor Cyan

    # Test 2: With path context
    Write-Host "`n2. With path context:" -ForegroundColor Yellow
    $result2 = Get-ContextualCompletion -Input $TestInput
    Write-Host "   Result: $result2" -ForegroundColor Cyan

    # Test 3: With multishot examples
    Write-Host "`n3. With multishot examples:" -ForegroundColor Yellow
    $examples = @(
        @{ Path = "C:\Windows\System32"; Input = "Get-"; Output = "Get-Process" }
        @{ Path = "C:\Users"; Input = "Get-Ch"; Output = "Get-ChildItem -Path" }
    )
    $result3 = Get-MultishotCompletion -Input $TestInput -Examples $examples
    Write-Host "   Result: $result3" -ForegroundColor Cyan

    # Test 4: With TabExpansion2 context (slow!)
    Write-Host "`n4. With TabExpansion2 context:" -ForegroundColor Yellow
    $result4 = Get-TabExpansionCompletion -InputText $TestInput -MaxCompletions 30
    Write-Host "   Result: $result4" -ForegroundColor Cyan
}

# Benchmark different approaches
function Measure-CompletionPerformance {
    param(
        [string]$TestInput = "Get-"
    )

    Write-Host "`n=== Performance Comparison ===" -ForegroundColor Green

    # Basic
    $time1 = Measure-Command { Get-CodeCompletion -Prefix $TestInput }
    Write-Host "Basic:              $($time1.TotalMilliseconds)ms" -ForegroundColor Yellow

    # With path
    $time2 = Measure-Command { Get-ContextualCompletion -Input $TestInput }
    Write-Host "With path:          $($time2.TotalMilliseconds)ms" -ForegroundColor Yellow

    # With examples
    $examples = @(
        @{ Path = "C:\"; Input = "Get-"; Output = "Get-Process" }
    )
    $time3 = Measure-Command { Get-MultishotCompletion -Input $TestInput -Examples $examples }
    Write-Host "With examples:      $($time3.TotalMilliseconds)ms" -ForegroundColor Yellow

    # With TabExpansion2
    $time4 = Measure-Command { Get-TabExpansionCompletion -InputText $TestInput -MaxCompletions 20 }
    Write-Host "With TabExpansion2: $($time4.TotalMilliseconds)ms" -ForegroundColor Yellow
}

# Test multishot with TabExpansion2 completions as examples
function Get-TabMultishotCompletion {
    param(
        [Parameter(Mandatory=$true)]
        [string]$InputText,

        [int]$MaxExamples = 3,

        [int]$MaxTokens = 80
    )

    # Get completions for the input
    $completions = Get-TabCompletions -InputText $InputText -MaxCompletions 10

    if ($completions.Count -eq 0) {
        Write-Host "No TabExpansion2 completions to use as examples" -ForegroundColor Yellow
        # Fall back to simple prompt
        return Get-CodeCompletion -Prefix $InputText
    }

    # Build multishot prompt using first N completions as examples
    $prompt = ""

    # Add completions as examples (teaching the model the pattern)
    $examples = $completions | Select-Object -First $MaxExamples
    foreach ($example in $examples) {
        # Use a shortened version of the input as the prefix
        $shortInput = if ($InputText.Length -gt 2) { $InputText.Substring(0, $InputText.Length - 1) } else { $InputText.Substring(0, 1) }
        $prompt += "<|fim_prefix|>$($PWD.Path)|$shortInput<|fim_suffix|><|fim_middle|>$($example.CompletionText)`n"
    }

    # Add the actual request
    $prompt += "<|fim_prefix|>$($PWD.Path)|$InputText<|fim_suffix|><|fim_middle|>"

    Write-Host "TabExpansion multishot prompt:" -ForegroundColor DarkGray
    Write-Host $prompt -ForegroundColor DarkGray

    $body = @{
        model = "qwen2.5-0.5B-autocomplete-custom"
        prompt = $prompt
        stream = $false
        options = @{
            num_predict = $MaxTokens
            temperature = 0.2
            top_p = 0.9
        }
    } | ConvertTo-Json -Depth 3

    $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" `
                                  -Method Post -Body $body -ContentType 'application/json'
    return $response.response
}

# Export functions
Export-ModuleMember -Function @(
    'Get-CodeCompletion',
    'Get-ContextualCompletion',
    'Get-MultishotCompletion',
    'Get-TabCompletions',
    'Get-TabExpansionCompletion',
    'Get-TabMultishotCompletion',
    'Test-PromptFormats',
    'Measure-CompletionPerformance'
)