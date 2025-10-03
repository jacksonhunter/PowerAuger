# Test that JsonSerializer properly handles Unicode escapes

$testCases = @{
    'Simple Unicode' = @{
        Input = 'Hello \u0022World\u0022'
        Expected = 'Hello "World"'
    }
    'Windows Path' = @{
        Input = 'C:\Users\jacks\Documents'
        Expected = 'C:\Users\jacks\Documents'
    }
    'Mixed' = @{
        Input = 'Set GDAL="C:\Users\test" with \u0022quotes\u0022'
        Expected = 'Set GDAL="C:\Users\test" with "quotes"'
    }
    'Tab and Newline' = @{
        Input = 'Line1\tTab\nLine2'
        Expected = "Line1`tTab`nLine2"
    }
}

Write-Host "Testing JsonSerializer.Deserialize handling:" -ForegroundColor Cyan

foreach ($name in $testCases.Keys) {
    $test = $testCases[$name]
    Write-Host "`n${name}:" -ForegroundColor Yellow
    Write-Host "  Input:    $($test.Input)" -ForegroundColor Gray

    try {
        # This is what our NormalizeCommand does
        $jsonString = '"' + $test.Input + '"'
        Add-Type -AssemblyName System.Text.Json -ErrorAction SilentlyContinue
        $result = [System.Text.Json.JsonSerializer]::Deserialize($jsonString, [string])

        Write-Host "  Result:   $result" -ForegroundColor Green
        Write-Host "  Expected: $($test.Expected)" -ForegroundColor Blue

        if ($result -eq $test.Expected) {
            Write-Host "  ✓ PASS" -ForegroundColor Green
        } else {
            Write-Host "  ✗ FAIL" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "  Error: $_" -ForegroundColor Red
    }
}