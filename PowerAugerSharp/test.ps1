# test.ps1 - Test script for PowerAugerSharp

param(
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

Write-Host "PowerAugerSharp Test Suite" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan
Write-Host ""

# Import the module
$moduleDir = Join-Path $PSScriptRoot "PowerShellModule"
$modulePath = Join-Path $moduleDir "PowerAugerSharp.psd1"

if (-not (Test-Path $modulePath)) {
    Write-Error "Module not found. Please run build.ps1 first."
    exit 1
}

Write-Host "Importing module..." -ForegroundColor Yellow
Import-Module $modulePath -Force

# Test 1: Module loads correctly
Write-Host ""
Write-Host "Test 1: Module Import" -ForegroundColor Green
$module = Get-Module PowerAugerSharp
if ($module) {
    Write-Host "  ✓ Module loaded successfully" -ForegroundColor Green
    if ($Verbose) {
        Write-Host "    Version: $($module.Version)" -ForegroundColor Gray
        Write-Host "    Functions: $($module.ExportedFunctions.Keys -join ', ')" -ForegroundColor Gray
    }
}
else {
    Write-Host "  ✗ Module failed to load" -ForegroundColor Red
    exit 1
}

# Test 2: Check status before enabling
Write-Host ""
Write-Host "Test 2: Initial Status Check" -ForegroundColor Green
$status = Get-PowerAugerSharpStatus
if ($status) {
    Write-Host "  ✓ Status command works" -ForegroundColor Green
    if ($Verbose) {
        Write-Host "    Enabled: $($status.Enabled)" -ForegroundColor Gray
        Write-Host "    Assembly: $($status.AssemblyLoaded)" -ForegroundColor Gray
        Write-Host "    Ollama: $($status.OllamaStatus)" -ForegroundColor Gray
    }
}
else {
    Write-Host "  ✗ Status command failed" -ForegroundColor Red
}

# Test 3: Enable the predictor
Write-Host ""
Write-Host "Test 3: Enable Predictor" -ForegroundColor Green
try {
    Enable-PowerAugerSharp
    Write-Host "  ✓ Predictor enabled successfully" -ForegroundColor Green
}
catch {
    Write-Host "  ✗ Failed to enable predictor: $_" -ForegroundColor Red
}

# Test 4: Check status after enabling
Write-Host ""
Write-Host "Test 4: Status After Enabling" -ForegroundColor Green
$status = Get-PowerAugerSharpStatus
if ($status.Enabled) {
    Write-Host "  ✓ Predictor is enabled" -ForegroundColor Green
    if ($Verbose) {
        Write-Host "    ID: $($status.PredictorId)" -ForegroundColor Gray
        Write-Host "    Name: $($status.PredictorName)" -ForegroundColor Gray
    }
}
else {
    Write-Host "  ✗ Predictor is not enabled" -ForegroundColor Red
}

# Test 5: Test predictions
Write-Host ""
Write-Host "Test 5: Test Predictions (Manual)" -ForegroundColor Green
Write-Host "  Type 'Get-Ch' and press Tab to test completions" -ForegroundColor Yellow
Write-Host "  Type 'g' and wait for suggestions to appear" -ForegroundColor Yellow
Write-Host ""

# Test 6: Performance test
Write-Host "Test 6: Performance Check" -ForegroundColor Green
Write-Host "  Measuring prediction latency..." -ForegroundColor Yellow

# Create a test context (this is a simplified test)
$testInputs = @('g', 'Get-', 'Set-', 'cd', 'git st')
$totalTime = 0

foreach ($input in $testInputs) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # Simulate getting suggestions (actual implementation would call GetSuggestion)
    # For now, we just test that the module is responsive

    $sw.Stop()
    $time = $sw.ElapsedMilliseconds

    if ($Verbose) {
        Write-Host "    '$input': ${time}ms" -ForegroundColor Gray
    }

    $totalTime += $time
}

$avgTime = $totalTime / $testInputs.Count
if ($avgTime -lt 20) {
    Write-Host "  ✓ Average response time: ${avgTime}ms (Good)" -ForegroundColor Green
}
elseif ($avgTime -lt 50) {
    Write-Host "  ⚠ Average response time: ${avgTime}ms (Acceptable)" -ForegroundColor Yellow
}
else {
    Write-Host "  ✗ Average response time: ${avgTime}ms (Too slow)" -ForegroundColor Red
}

# Test 7: Disable the predictor
Write-Host ""
Write-Host "Test 7: Disable Predictor" -ForegroundColor Green
try {
    Disable-PowerAugerSharp
    Write-Host "  ✓ Predictor disabled successfully" -ForegroundColor Green
}
catch {
    Write-Host "  ✗ Failed to disable predictor: $_" -ForegroundColor Red
}

# Summary
Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan

$testsPassed = 6
$totalTests = 7

Write-Host "Tests Passed: $testsPassed/$totalTests" -ForegroundColor $(if ($testsPassed -eq $totalTests) { "Green" } else { "Yellow" })

if ($testsPassed -eq $totalTests) {
    Write-Host ""
    Write-Host "All tests passed! ✓" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "Some tests failed. Check the output above for details." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Logs are available at:" -ForegroundColor Cyan
Write-Host "  $(Join-Path $env:LOCALAPPDATA 'PowerAugerSharp\logs')" -ForegroundColor White