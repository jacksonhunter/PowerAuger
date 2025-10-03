# Test that the Unicode escape fix works
$testCommands = @(
    'conda env config vars set GDAL_DATA="C:\Users\jacks\anaconda3\envs\planetarium\Library\share\gdal"',
    'Set-Location C:\Users\jacks\Documents',
    'Get-ChildItem C:\Program Files\',
    'Test-Path "C:\Windows\System32"'
)

Write-Host "Testing command normalization..." -ForegroundColor Cyan

foreach ($cmd in $testCommands) {
    Write-Host "`nOriginal: $cmd" -ForegroundColor Yellow

    try {
        # Test the regex pattern that was failing
        $pattern = [regex]::Unescape($cmd)
        Write-Host "ERROR: Should have failed but didn't!" -ForegroundColor Red
    }
    catch {
        Write-Host "Correctly rejected by Regex.Unescape: $($_.Exception.Message)" -ForegroundColor Green
    }

    # Test our new normalization
    try {
        $normalized = [regex]::Replace($cmd, '\\u([0-9A-Fa-f]{4})', {
            param($m)
            [char][Convert]::ToInt32($m.Groups[1].Value, 16)
        })
        Write-Host "Normalized successfully: $normalized" -ForegroundColor Green
    }
    catch {
        Write-Host "Normalization failed: $_" -ForegroundColor Red
    }
}

Write-Host "`nTesting history loading..." -ForegroundColor Cyan

# Load the module and check if it initializes correctly
try {
    Import-Module ./PowerShellModule/PowerAuger.psd1 -Force
    Write-Host "Module loaded successfully!" -ForegroundColor Green

    # Check if FrecencyStore initialized
    $logFile = Get-ChildItem "$env:LOCALAPPDATA\PowerAuger\logs\" -Filter "powerauger*.log" |
               Sort-Object LastWriteTime -Descending |
               Select-Object -First 1

    if ($logFile) {
        $recentLogs = Get-Content $logFile.FullName -Tail 10
        $loadedMsg = $recentLogs | Where-Object { $_ -match 'Loaded \d+ validated commands' }
        if ($loadedMsg) {
            Write-Host "History loaded: $loadedMsg" -ForegroundColor Green
        }
    }
}
catch {
    Write-Host "Failed to load module: $_" -ForegroundColor Red
}