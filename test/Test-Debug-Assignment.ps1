# Debug test for assignment statement validation

param(
    [string]$ProjectPath = "C:\Users\jacks\experiments\RiderProjects\PowerAuger"
)

# Load assembly
Add-Type -Path "$ProjectPath\bin\Debug\net8.0\PowerAuger.dll"

Write-Host "Debug: Testing assignment statement validation" -ForegroundColor Cyan

$logger = [PowerAugerSharp.FastLogger]::new()
$logger.MinimumLevel = [PowerAugerSharp.FastLogger+LogLevel]::Debug
$processor = [PowerAugerSharp.BackgroundProcessor]::new($logger, 2)
$store = [PowerAugerSharp.FastCompletionStore]::new($logger, $processor)

# Test assignment statement
$assignmentInput = '$var = Get-ChildItem'
Write-Host "`nTesting input: $assignmentInput" -ForegroundColor Yellow

# Parse the assignment
$ast = [System.Management.Automation.Language.Parser]::ParseInput($assignmentInput, [ref]$null, [ref]$null)
$tokens = $null
[System.Management.Automation.Language.Parser]::ParseInput($assignmentInput, [ref]$tokens, [ref]$null) | Out-Null

Write-Host "AST Type: $($ast.GetType().Name)" -ForegroundColor Gray
Write-Host "AST Text: $($ast.Extent.Text)" -ForegroundColor Gray

if ($ast.EndBlock -and $ast.EndBlock.Statements.Count -gt 0) {
    $firstStatement = $ast.EndBlock.Statements[0]
    Write-Host "First Statement Type: $($firstStatement.GetType().Name)" -ForegroundColor Gray

    if ($firstStatement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        Write-Host "✓ Correctly identified as AssignmentStatementAst" -ForegroundColor Green
    }
}

# Get cursor position at end
$cursorPosition = $ast.Extent.EndScriptPosition
Write-Host "Cursor Position: $($cursorPosition.Offset)" -ForegroundColor Gray

# Try to get completions
Write-Host "`nAttempting to get completions..." -ForegroundColor Yellow
try {
    $completions = $store.GetCompletionsFromAstAsync($ast, $tokens, $cursorPosition, 5).Result
    Write-Host "Completions returned: $($completions.Count)" -ForegroundColor $(if ($completions.Count -eq 0) { "Green" } else { "Red" })

    if ($completions.Count -gt 0) {
        Write-Host "Unexpected completions:" -ForegroundColor Red
        foreach ($c in $completions) {
            Write-Host "  - $c" -ForegroundColor Red
        }
    }
}
catch {
    Write-Host "Error getting completions: $_" -ForegroundColor Red
}

# Cleanup
$store.Dispose()
$processor.Dispose()
$logger.Dispose()

Write-Host "`nDebug test complete." -ForegroundColor Cyan