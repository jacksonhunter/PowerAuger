# Test-PowerAugerTracking.ps1
# Comprehensive test script for PowerAuger tracking system
# Run this to validate tracking functionality and generate test data

param(
    [switch]$Quick,           # Run only basic tests
    [switch]$Detailed,        # Run comprehensive tests with delays
    [switch]$ExportResults    # Export test results
)

Write-Host "🧪 PowerAuger Tracking System Test Suite" -ForegroundColor Cyan
Write-Host "=" * 50 -ForegroundColor Gray

# Import PowerAuger module
try {
    Import-Module "$PSScriptRoot\modules\PowerAuger\PowerAuger.psm1" -Force
    Write-Host "✅ PowerAuger module imported successfully" -ForegroundColor Green
} catch {
    Write-Host "❌ Failed to import PowerAuger module: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Test configuration
$TestResults = @{
    StartTime = Get-Date
    Tests = @()
    InitialStats = $null
    FinalStats = $null
}

function Add-TestResult {
    param($TestName, $Status, $Details = "")
    $script:TestResults.Tests += @{
        Name = $TestName
        Status = $Status
        Details = $Details
        Timestamp = Get-Date
    }
    
    $statusColor = if ($Status -eq "PASS") { "Green" } elseif ($Status -eq "FAIL") { "Red" } else { "Yellow" }
    Write-Host "  $Status : $TestName" -ForegroundColor $statusColor
    if ($Details) { Write-Host "    $Details" -ForegroundColor Gray }
}

# Capture initial statistics
Write-Host "`n📊 Capturing initial statistics..." -ForegroundColor Yellow
$TestResults.InitialStats = Get-PredictorStatistics

Write-Host "`n🔧 TEST 1: Basic Module Functions" -ForegroundColor Yellow
Write-Host "-" * 30

# Test 1: Connection Test
try {
    $connectionResult = Test-OllamaConnection
    Add-TestResult "Connection Test" $(if ($connectionResult) { "PASS" } else { "WARN" }) "Connection status: $connectionResult"
} catch {
    Add-TestResult "Connection Test" "FAIL" $_.Exception.Message
}

# Test 2: Status Display
try {
    Show-PredictorStatus | Out-Null
    Add-TestResult "Status Display" "PASS"
} catch {
    Add-TestResult "Status Display" "FAIL" $_.Exception.Message
}

# Test 3: Statistics Retrieval
try {
    $stats = Get-PredictorStatistics
    Add-TestResult "Statistics Retrieval" "PASS" "Retrieved $($stats.Keys.Count) metric categories"
} catch {
    Add-TestResult "Statistics Retrieval" "FAIL" $_.Exception.Message
}

Write-Host "`n🎯 TEST 2: Prediction Generation & Tracking" -ForegroundColor Yellow
Write-Host "-" * 40

# Test scenarios for different prediction types
$testScenarios = @(
    @{ Input = "Get-Ch"; Description = "Simple completion (should use fast model)" },
    @{ Input = "git st"; Description = "Git command completion" },
    @{ Input = "Import-Mod"; Description = "PowerShell cmdlet completion" },
    @{ Input = "ls -l"; Description = "Unix-style command" },
    @{ Input = "Get-Process | Where-Object"; Description = "Pipeline completion (should use context model)" }
)

foreach ($scenario in $testScenarios) {
    Write-Host "  Testing: $($scenario.Description)" -ForegroundColor Cyan
    
    try {
        # Get prediction
        $beforeCount = $global:PredictionTracking.TotalPredictions
        $predictions = Get-CommandPrediction -InputLine $scenario.Input
        $afterCount = $global:PredictionTracking.TotalPredictions
        
        if ($afterCount -gt $beforeCount) {
            Add-TestResult "Prediction Generation: $($scenario.Input)" "PASS" "Generated $($predictions.Count) predictions"
        } else {
            Add-TestResult "Prediction Generation: $($scenario.Input)" "WARN" "No new predictions tracked"
        }
        
        # Display first few predictions
        if ($predictions.Count -gt 0) {
            Write-Host "    Predictions: $($predictions[0..2] -join ', ')..." -ForegroundColor Gray
        }
        
    } catch {
        Add-TestResult "Prediction Generation: $($scenario.Input)" "FAIL" $_.Exception.Message
    }
    
    if (-not $Quick) { Start-Sleep -Milliseconds 500 }
}

Write-Host "`n📈 TEST 3: Acceptance Rate Simulation" -ForegroundColor Yellow
Write-Host "-" * 35

# Simulate accepting some predictions
$simulatedCommands = @(
    "Get-ChildItem",
    "git status", 
    "Import-Module",
    "Get-Process",
    "ls"
)

Write-Host "  Simulating command execution to test acceptance tracking..." -ForegroundColor Cyan

foreach ($cmd in $simulatedCommands) {
    try {
        # First get predictions for partial input
        $partialInput = $cmd.Substring(0, [Math]::Min(6, $cmd.Length))
        Get-CommandPrediction -InputLine $partialInput | Out-Null
        
        # Then "execute" the full command
        Add-CommandToHistory -Command $cmd -Success $true
        
        Add-TestResult "Acceptance Simulation: $cmd" "PASS"
    } catch {
        Add-TestResult "Acceptance Simulation: $cmd" "FAIL" $_.Exception.Message
    }
    
    if (-not $Quick) { Start-Sleep -Milliseconds 200 }
}

Write-Host "`n⚡ TEST 4: Performance Metrics" -ForegroundColor Yellow
Write-Host "-" * 25

# Test performance tracking
try {
    $beforeMetrics = Get-PredictorStatistics
    
    # Generate multiple predictions to test performance tracking
    $performanceTests = @("dir", "cd", "echo", "type", "copy")
    foreach ($test in $performanceTests) {
        Get-CommandPrediction -InputLine $test | Out-Null
        if (-not $Quick) { Start-Sleep -Milliseconds 100 }
    }
    
    $afterMetrics = Get-PredictorStatistics
    
    if ($afterMetrics.Performance.RequestCount -gt $beforeMetrics.Performance.RequestCount) {
        Add-TestResult "Performance Tracking" "PASS" "Request count increased: $($beforeMetrics.Performance.RequestCount) → $($afterMetrics.Performance.RequestCount)"
    } else {
        Add-TestResult "Performance Tracking" "WARN" "No performance metrics change detected"
    }
    
    # Test response time tracking
    if ($afterMetrics.ResponseTimes.Count -gt 0) {
        Add-TestResult "Response Time Tracking" "PASS" "Tracked $($afterMetrics.ResponseTimes.Count) response times"
    } else {
        Add-TestResult "Response Time Tracking" "WARN" "No response times recorded"
    }
    
} catch {
    Add-TestResult "Performance Metrics" "FAIL" $_.Exception.Message
}

Write-Host "`n📂 TEST 5: Context Awareness" -ForegroundColor Yellow
Write-Host "-" * 25

# Test context-dependent predictions
$contextTests = @(
    @{ Location = "C:\Windows\System32"; Command = "Get-Service"; Description = "System directory context" },
    @{ Location = $PSScriptRoot; Command = ".\Test"; Description = "Script directory context" }
)

foreach ($contextTest in $contextTests) {
    try {
        $originalLocation = Get-Location
        Set-Location $contextTest.Location
        
        $beforeContext = $global:PerformanceMetrics.ContextEffectiveness.WithContext.Count
        Get-CommandPrediction -InputLine $contextTest.Command | Out-Null
        $afterContext = $global:PerformanceMetrics.ContextEffectiveness.WithContext.Count
        
        Set-Location $originalLocation
        
        if ($afterContext -gt $beforeContext) {
            Add-TestResult "Context Awareness: $($contextTest.Description)" "PASS"
        } else {
            Add-TestResult "Context Awareness: $($contextTest.Description)" "WARN" "Context not detected"
        }
        
    } catch {
        Add-TestResult "Context Awareness: $($contextTest.Description)" "FAIL" $_.Exception.Message
        Set-Location $originalLocation
    }
}

if ($Detailed) {
    Write-Host "`n🕒 TEST 6: Extended Performance Test" -ForegroundColor Yellow
    Write-Host "-" * 30
    
    Write-Host "  Running 20 predictions to gather performance data..." -ForegroundColor Cyan
    
    $extendedTests = @(
        "Get-Process", "Get-Service", "Get-ChildItem", "Set-Location", "Import-Module",
        "git commit", "git push", "git pull", "git status", "git log",
        "docker run", "docker ps", "kubectl get", "az login", "npm install",
        "python -m", "pip install", "node -v", "yarn add", "code ."
    )
    
    $startTime = Get-Date
    foreach ($test in $extendedTests) {
        Get-CommandPrediction -InputLine $test | Out-Null
        Start-Sleep -Milliseconds 250  # Simulate realistic typing speed
    }
    $endTime = Get-Date
    
    $totalTime = ($endTime - $startTime).TotalMilliseconds
    Add-TestResult "Extended Performance Test" "PASS" "20 predictions in $([math]::Round($totalTime, 0))ms (avg: $([math]::Round($totalTime/20, 1))ms)"
}

# Capture final statistics
Write-Host "`n📊 Capturing final statistics..." -ForegroundColor Yellow
$TestResults.FinalStats = Get-PredictorStatistics
$TestResults.EndTime = Get-Date

# Display results summary
Write-Host "`n📋 TEST RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 50 -ForegroundColor Gray

$passCount = ($TestResults.Tests | Where-Object { $_.Status -eq "PASS" }).Count
$failCount = ($TestResults.Tests | Where-Object { $_.Status -eq "FAIL" }).Count
$warnCount = ($TestResults.Tests | Where-Object { $_.Status -eq "WARN" }).Count
$totalTests = $TestResults.Tests.Count

Write-Host "Total Tests: $totalTests" -ForegroundColor White
Write-Host "Passed: $passCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor Red
Write-Host "Warnings: $warnCount" -ForegroundColor Yellow

# Compare statistics
$statsComparison = @{
    PredictionIncrease = $TestResults.FinalStats.PredictionTracking.TotalPredictions - $TestResults.InitialStats.PredictionTracking.TotalPredictions
    AcceptanceIncrease = $TestResults.FinalStats.PredictionTracking.TotalAccepted - $TestResults.InitialStats.PredictionTracking.TotalAccepted
    RequestIncrease = $TestResults.FinalStats.Performance.RequestCount - $TestResults.InitialStats.Performance.RequestCount
}

Write-Host "`n📈 Statistics Changes During Test:" -ForegroundColor Yellow
Write-Host "  Predictions Generated: +$($statsComparison.PredictionIncrease)" -ForegroundColor White
Write-Host "  Predictions Accepted: +$($statsComparison.AcceptanceIncrease)" -ForegroundColor White
Write-Host "  API Requests: +$($statsComparison.RequestIncrease)" -ForegroundColor White

if ($TestResults.FinalStats.PredictionTracking.AcceptanceRate -gt 0) {
    Write-Host "  Current Acceptance Rate: $($TestResults.FinalStats.PredictionTracking.AcceptanceRate * 100)%" -ForegroundColor Green
}

# Export results if requested
if ($ExportResults) {
    try {
        $exportPath = Export-PredictorMetrics -IncludeHistory
        Write-Host "`n📁 Test results and metrics exported to: $exportPath" -ForegroundColor Green
    } catch {
        Write-Host "`n❌ Failed to export results: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Display current status
Write-Host "`n🎯 Current Predictor Status:" -ForegroundColor Cyan
Show-PredictorStatus -Detailed

Write-Host "`n✅ Test suite completed!" -ForegroundColor Green
Write-Host "Run 'Show-PredictorStatus -Detailed' anytime to see current metrics." -ForegroundColor Gray