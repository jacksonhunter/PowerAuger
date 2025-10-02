# Test different command types to see their AST classifications

$testCases = @(
    # Pure expressions
    '2 + 2'
    '$true'
    '"hello"'
    '@{Name="Test"}'
    '[math]::PI'

    # Pipelines with ForEach-Object (should be allowed)
    'Get-ChildItem | ForEach-Object { $_.Name }'
    'Get-Process | Where-Object { $_.CPU -gt 10 }'
    '1..10 | ForEach-Object { $_ * 2 }'

    # Loop statements (currently filtered)
    'foreach ($i in 1..10) { $i }'
    'for ($i = 0; $i -lt 10; $i++) { $i }'
    'while ($true) { break }'

    # Mixed pipelines
    'Get-ChildItem | Select-Object Name | Sort-Object'
    '$array | ForEach-Object { $_ * 2 } | Where-Object { $_ -gt 5 }'
)

Write-Host "AST Type Analysis:" -ForegroundColor Cyan
Write-Host "==================" -ForegroundColor Cyan

foreach ($test in $testCases) {
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($test, [ref]$null, [ref]$null)
    $firstStatement = $ast.EndBlock.Statements[0]

    $color = "White"
    $allowed = "?"

    if ($firstStatement -is [System.Management.Automation.Language.PipelineAst]) {
        $color = "Green"
        $allowed = "ALLOWED"

        # Check pipeline elements
        $pipeline = $firstStatement -as [System.Management.Automation.Language.PipelineAst]
        $elements = @()
        foreach ($element in $pipeline.PipelineElements) {
            $elements += $element.GetType().Name
        }
        $elementInfo = " [Elements: $($elements -join ', ')]"
    }
    elseif ($firstStatement -is [System.Management.Automation.Language.LoopStatementAst]) {
        $color = "Red"
        $allowed = "FILTERED"
        $elementInfo = ""
    }
    elseif ($firstStatement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        $color = "Red"
        $allowed = "FILTERED"
        $elementInfo = ""
    }
    else {
        $elementInfo = ""
    }

    Write-Host ("{0,-10} {1,-30} -> {2}{3}" -f $allowed, $firstStatement.GetType().Name, $test.Substring(0, [Math]::Min(40, $test.Length)), $elementInfo) -ForegroundColor $color
}

Write-Host "`nKey insights:" -ForegroundColor Yellow
Write-Host "- Pure expressions (2+2, `$true) are PipelineAst" -ForegroundColor Gray
Write-Host "- ForEach-Object in pipeline is CommandAst (allowed)" -ForegroundColor Gray
Write-Host "- foreach/for/while statements are LoopStatementAst (filtered)" -ForegroundColor Gray
Write-Host "- Most useful completions are PipelineAst" -ForegroundColor Gray