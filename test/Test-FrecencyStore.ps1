# Test script for FrecencyStore Terminal/Transit Pattern

Write-Host "PowerAuger FrecencyStore Terminal/Transit Pattern Test" -ForegroundColor Cyan
Write-Host "=======================================================" -ForegroundColor Cyan

# Check current module status
Write-Host "`nChecking if PowerAuger is loaded..." -ForegroundColor Yellow
$subsystems = [System.Management.Automation.Subsystem.SubsystemManager]::GetAllSubsystemInfo()
$powerAuger = $subsystems | Where-Object { $_.ImplementationName -like "*PowerAuger*" }

if ($powerAuger) {
    Write-Host "PowerAuger is already loaded. Please restart PowerShell to test fresh." -ForegroundColor Red
    exit
}

# Set environment variable to enable FrecencyStore
Write-Host "`nEnabling FrecencyStore with POWERAUGER_USE_FRECENCY=1..." -ForegroundColor Yellow
$env:POWERAUGER_USE_FRECENCY = "1"

# Import the module
Write-Host "`nImporting PowerAuger module..." -ForegroundColor Yellow
$modulePath = Join-Path $PSScriptRoot "..\PowerShellModule\PowerAuger.psd1"
Import-Module $modulePath -Force

# Check if it loaded
$subsystems = [System.Management.Automation.Subsystem.SubsystemManager]::GetAllSubsystemInfo()
$powerAuger = $subsystems | Where-Object { $_.ImplementationName -like "*PowerAuger*" }

if ($powerAuger) {
    Write-Host "✓ PowerAuger loaded successfully!" -ForegroundColor Green
    Write-Host "  ID: $($powerAuger.SubsystemInfo.Id)" -ForegroundColor DarkGray
    Write-Host "  Name: $($powerAuger.SubsystemInfo.Name)" -ForegroundColor DarkGray
} else {
    Write-Host "✗ Failed to load PowerAuger" -ForegroundColor Red
    exit
}

# Test predictions
Write-Host "`nTesting Terminal/Transit Pattern Implementation..." -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Yellow

# Check logs for confirmation
$logDir = Join-Path $env:LOCALAPPDATA "PowerAuger\logs"
if (Test-Path $logDir) {
    $latestLog = Get-ChildItem $logDir -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestLog) {
        Write-Host "`nChecking latest log for FrecencyStore confirmation..." -ForegroundColor Yellow
        $frecencyLines = Select-String -Path $latestLog.FullName -Pattern "FrecencyStore|frecency|Loaded.*commands" -Context 0,2 | Select-Object -First 10
        if ($frecencyLines) {
            Write-Host "Log entries mentioning FrecencyStore:" -ForegroundColor Green
            $frecencyLines | ForEach-Object { Write-Host $_.Line -ForegroundColor DarkGray }
        }
    }
}

Write-Host "`n✓ Key improvements in this version:" -ForegroundColor Green
Write-Host "  - Commands stored ONCE at full path (terminal nodes)" -ForegroundColor White
Write-Host "  - Transit nodes used for prefix matching only" -ForegroundColor White
Write-Host "  - No redundant storage at every prefix" -ForegroundColor White
Write-Host "  - Eliminates double-counting in frecency scores" -ForegroundColor White

Write-Host "`n✓ Test setup complete. Start typing commands to test predictions!" -ForegroundColor Green
Write-Host "  Example: Type 'git' to see git commands" -ForegroundColor Cyan
Write-Host "  Example: Type 'docker' to see docker commands" -ForegroundColor Cyan

Write-Host "`nData files:" -ForegroundColor Yellow
Write-Host "  $(Join-Path $env:LOCALAPPDATA 'PowerAuger\frecency.dat')" -ForegroundColor DarkGray
Write-Host "  $(Join-Path $env:LOCALAPPDATA 'PowerAuger\frecency.json')" -ForegroundColor DarkGray

# Check if data files exist and show stats
$dataPath = Join-Path $env:LOCALAPPDATA "PowerAuger\frecency.dat"
if (Test-Path $dataPath) {
    $fileSize = (Get-Item $dataPath).Length / 1KB
    Write-Host "`nExisting data file found: $([Math]::Round($fileSize, 2))KB" -ForegroundColor Green
}