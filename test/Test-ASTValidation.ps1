# Test-ASTValidation.ps1
# Tests the AST validation functionality of PowerAuger

param(
    [string]$ProjectPath = "C:\Users\jacks\experiments\RiderProjects\PowerAuger"
)

# Add PowerShell.SDK assembly
Add-Type -Path "$ProjectPath\bin\Debug\net8.0\System.Management.Automation.dll"
Add-Type -Path "$ProjectPath\bin\Debug\net8.0\PowerAuger.dll"

Write-Host "Testing PowerAuger AST Validation" -ForegroundColor Cyan

# Test cases for validation
$testCases = @(
    @{
        Description = "Valid command - should pass"
        Input = "Get-ChildItem"
        ShouldPass = $true
    },
    @{
        Description = "Assignment statement - should fail"
        Input = '$var = Get-ChildItem'
        ShouldPass = $false
    },
    @{
        Description = "If statement - should fail"
        Input = 'if ($true) { Get-ChildItem }'
        ShouldPass = $false
    },
    @{
        Description = "Valid pipeline - should pass"
        Input = "Get-ChildItem | Where-Object { `$_.Name -like '*.txt' }"
        ShouldPass = $true
    },
    @{
        Description = "Invalid command - should fail"
        Input = "Get-NonExistentCommand123"
        ShouldPass = $false
    },
    @{
        Description = "Valid command with parameters - should pass"
        Input = "Get-ChildItem -Path C:\ -Recurse"
        ShouldPass = $true
    }
)

# Initialize components
try {
    $logger = [PowerAugerSharp.FastLogger]::new("C:\temp\powerauger-test.log", $true)
    $processor = [PowerAugerSharp.BackgroundProcessor]::new($logger, 2)
    $store = [PowerAugerSharp.FastCompletionStore]::new($logger, $processor)

    Write-Host "Components initialized successfully" -ForegroundColor Green
}
catch {
    Write-Host "Failed to initialize components: $_" -ForegroundColor Red
    exit 1
}

# Test each case
$passCount = 0
$failCount = 0

foreach ($test in $testCases) {
    Write-Host "`nTesting: $($test.Description)" -ForegroundColor Yellow
    Write-Host "  Input: $($test.Input)" -ForegroundColor Gray

    try {
        # Parse the input
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($test.Input, [ref]$null, [ref]$null)
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseInput($test.Input, [ref]$tokens, [ref]$errors) | Out-Null

        # Create cursor position at end of input
        $cursorPosition = $ast.Extent.EndScriptPosition

        # Get completions (which will trigger validation)
        $completions = $store.GetCompletionsFromAstAsync($ast, $tokens, $cursorPosition, 5).Result

        # Check if we got results
        $gotResults = $completions.Count -gt 0

        if ($test.ShouldPass -and $gotResults) {
            Write-Host "  ✓ PASS - Got $($completions.Count) completions as expected" -ForegroundColor Green
            $passCount++
        }
        elseif (-not $test.ShouldPass -and -not $gotResults) {
            Write-Host "  ✓ PASS - No completions returned as expected (filtered out)" -ForegroundColor Green
            $passCount++
        }
        else {
            Write-Host "  ✗ FAIL - Expected ShouldPass=$($test.ShouldPass) but got $($completions.Count) results" -ForegroundColor Red
            $failCount++
        }
    }
    catch {
        Write-Host "  ✗ ERROR - $_" -ForegroundColor Red
        $failCount++
    }
}

# Summary
Write-Host "`n" + ("=" * 50) -ForegroundColor Cyan
Write-Host "Test Summary:" -ForegroundColor Cyan
Write-Host "  Passed: $passCount" -ForegroundColor Green
Write-Host "  Failed: $failCount" -ForegroundColor Red

if ($failCount -eq 0) {
    Write-Host "`nAll tests passed! ✓" -ForegroundColor Green
}
else {
    Write-Host "`nSome tests failed. Please review the output above." -ForegroundColor Yellow
}

# Cleanup
$processor.Dispose()
$store.Dispose()
$logger.Dispose()

Write-Host "`nTest complete." -ForegroundColor Cyan