# Test that error logging works for normalization
Write-Host "Testing normalization error logging..." -ForegroundColor Cyan

# Force delete cache to trigger fresh load
Remove-Item 'C:\Users\jacks\AppData\Local\PowerAuger\frecency.dat' -Force -ErrorAction SilentlyContinue

# Import module
Import-Module ./PowerShellModule/PowerAuger.psd1 -Force

Write-Host "`nChecking logs for normalization messages..." -ForegroundColor Yellow

# Wait a moment for initialization
Start-Sleep -Milliseconds 500

# Get the latest log file
$logFile = Get-ChildItem "$env:LOCALAPPDATA\PowerAuger\logs\" -Filter "powerauger*.log" |
           Sort-Object LastWriteTime -Descending |
           Select-Object -First 1

if ($logFile) {
    Write-Host "Log file: $($logFile.Name)" -ForegroundColor Gray

    # Look for JSON normalization messages
    $logs = Get-Content $logFile.FullName -Tail 200

    $normalizationLogs = $logs | Where-Object { $_ -match 'JSON normalization|NormalizeCommand' }

    if ($normalizationLogs) {
        Write-Host "`nFound normalization logs:" -ForegroundColor Green
        $normalizationLogs | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
    }
    else {
        Write-Host "`nNo normalization logs found. This is expected if all commands normalize successfully." -ForegroundColor Yellow

        # Check if history was loaded
        $loadedLogs = $logs | Where-Object { $_ -match 'Loaded.*commands' }
        if ($loadedLogs) {
            Write-Host "`nHistory loading succeeded:" -ForegroundColor Green
            $loadedLogs | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
        }
    }
}
else {
    Write-Host "No log file found!" -ForegroundColor Red
}