# Test-CompletionsWorking.ps1
# Comprehensive test to verify completions are actually being generated

param(
    [string]$ProjectPath = "C:\Users\jacks\experiments\RiderProjects\PowerAuger"
)

Write-Host "`n=== PowerAuger Completion Verification Test ===" -ForegroundColor Cyan
Write-Host "This test verifies that completions are actually being generated`n" -ForegroundColor Gray

# Load assembly
Add-Type -Path "$ProjectPath\bin\Release\net8.0\PowerAuger.dll"

# Initialize components
Write-Host "Initializing components..." -ForegroundColor Yellow
$logger = [PowerAugerSharp.FastLogger]::new()
$logger.MinimumLevel = [PowerAugerSharp.FastLogger+LogLevel]::Debug
$processor = [PowerAugerSharp.BackgroundProcessor]::new($logger, 2)
$store = [PowerAugerSharp.FastCompletionStore]::new($logger, $processor)

Write-Host "✓ Components initialized" -ForegroundColor Green

# Test cases
$testInputs = @(
    @{Input = "Get-Ch"; Description = "Common Get- command"},
    @{Input = "Set-Lo"; Description = "Common Set- command"},
    @{Input = "New-"; Description = "New- prefix"},
    @{Input = "Test-"; Description = "Test- prefix"},
    @{Input = "git "; Description = "Git command"},
    @{Input = "cd "; Description = "Change directory"},
    @{Input = "ls"; Description = "List files"}
)

$totalTests = 0
$successfulTests = 0
$testsWithCompletions = 0

Write-Host "`nTesting synchronous completions (from cache):" -ForegroundColor Yellow
Write-Host "=" * 60

foreach ($test in $testInputs) {
    $totalTests++
    Write-Host "`nTest: '$($test.Input)'" -ForegroundColor Cyan
    Write-Host "  Description: $($test.Description)" -ForegroundColor Gray

    try {
        # Test synchronous completions
        $syncCompletions = $store.GetCompletions($test.Input, 5)

        if ($syncCompletions.Count -gt 0) {
            Write-Host "  ✓ Sync completions: $($syncCompletions.Count) results" -ForegroundColor Green
            foreach ($comp in $syncCompletions) {
                Write-Host "    - $comp" -ForegroundColor DarkGreen
            }
            $testsWithCompletions++
        }
        else {
            Write-Host "  ⚠ No sync completions (cache may be cold)" -ForegroundColor Yellow
        }

        $successfulTests++
    }
    catch {
        Write-Host "  ✗ Error: $_" -ForegroundColor Red
    }
}

Write-Host "`n" + "=" * 60
Write-Host "Testing asynchronous completions (with AST):" -ForegroundColor Yellow
Write-Host "=" * 60

foreach ($test in $testInputs) {
    $totalTests++
    Write-Host "`nTest: '$($test.Input)'" -ForegroundColor Cyan

    try {
        # Create AST from input
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($test.Input, [ref]$null, [ref]$null)
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseInput($test.Input, [ref]$tokens, [ref]$null) | Out-Null
        $cursorPosition = $ast.Extent.EndScriptPosition

        # Test async completions with AST
        $asyncTask = $store.GetCompletionsFromAstAsync($ast, $tokens, $cursorPosition, 5)
        $asyncCompletions = $asyncTask.Result

        if ($asyncCompletions.Count -gt 0) {
            Write-Host "  ✓ Async completions: $($asyncCompletions.Count) results" -ForegroundColor Green
            foreach ($comp in $asyncCompletions) {
                Write-Host "    - $comp" -ForegroundColor DarkGreen
            }
            $testsWithCompletions++
        }
        else {
            Write-Host "  ⚠ No async completions" -ForegroundColor Yellow
        }

        $successfulTests++
    }
    catch {
        Write-Host "  ✗ Error: $_" -ForegroundColor Red
    }
}

# Test with actual PowerShell TabExpansion2
Write-Host "`n" + "=" * 60
Write-Host "Testing direct TabExpansion2 (baseline comparison):" -ForegroundColor Yellow
Write-Host "=" * 60

foreach ($test in $testInputs[0..2]) {
    Write-Host "`nTest: '$($test.Input)'" -ForegroundColor Cyan

    try {
        $tabCompletions = TabExpansion2 -inputScript $test.Input -cursorColumn $test.Input.Length
        if ($tabCompletions.CompletionMatches.Count -gt 0) {
            Write-Host "  ✓ TabExpansion2: $($tabCompletions.CompletionMatches.Count) results" -ForegroundColor Green
            foreach ($comp in $tabCompletions.CompletionMatches.Take(5)) {
                Write-Host "    - $($comp.CompletionText) [$($comp.ResultType)]" -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host "  ⚠ No TabExpansion2 results" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "  ⚠ TabExpansion2 not available" -ForegroundColor Yellow
    }
}

# Load and test history
Write-Host "`n" + "=" * 60
Write-Host "Testing history loading:" -ForegroundColor Yellow
Write-Host "=" * 60

try {
    $history = [PowerAugerSharp.PowerShellHistoryLoader]::LoadValidatedHistory($logger)
    Write-Host "✓ Loaded $($history.Count) validated history commands" -ForegroundColor Green

    if ($history.Count -gt 0) {
        Write-Host "Sample history entries:" -ForegroundColor Gray
        foreach ($cmd in $history[0..[Math]::Min(4, $history.Count-1)]) {
            $preview = if ($cmd.Length -gt 60) { $cmd.Substring(0, 60) + "..." } else { $cmd }
            Write-Host "  - $preview" -ForegroundColor DarkGray
        }
    }
}
catch {
    Write-Host "✗ Failed to load history: $_" -ForegroundColor Red
}

# Summary
Write-Host "`n" + "=" * 60 -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 60 -ForegroundColor Cyan

$successRate = if ($totalTests -gt 0) { [math]::Round(($successfulTests / $totalTests) * 100, 1) } else { 0 }
$completionRate = if ($totalTests -gt 0) { [math]::Round(($testsWithCompletions / $totalTests) * 100, 1) } else { 0 }

Write-Host "Total tests run: $totalTests" -ForegroundColor White
Write-Host "Successful tests: $successfulTests ($successRate%)" -ForegroundColor $(if ($successRate -gt 80) { "Green" } else { "Yellow" })
Write-Host "Tests with completions: $testsWithCompletions ($completionRate%)" -ForegroundColor $(if ($completionRate -gt 50) { "Green" } else { "Yellow" })

if ($completionRate -gt 70) {
    Write-Host "`n✅ PASS: PowerAuger is generating completions successfully!" -ForegroundColor Green
}
elseif ($completionRate -gt 30) {
    Write-Host "`n⚠️ PARTIAL: PowerAuger is generating some completions" -ForegroundColor Yellow
    Write-Host "   Cache may need time to warm up or history may be limited" -ForegroundColor Gray
}
else {
    Write-Host "`n❌ FAIL: PowerAuger is not generating sufficient completions" -ForegroundColor Red
    Write-Host "   Check configuration and history loading" -ForegroundColor Gray
}

# Cleanup
$store.Dispose()
$processor.Dispose()
$logger.Dispose()

Write-Host "`nTest complete." -ForegroundColor Cyan