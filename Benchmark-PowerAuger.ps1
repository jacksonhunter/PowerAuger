# Benchmark-PowerAuger.ps1
# Performance benchmarking and model comparison for PowerAuger
# Use this to systematically test and compare fast vs context models

param(
    [int]$Iterations = 50,           # Number of test iterations
    [switch]$DetailedOutput,         # Show detailed per-test results
    [switch]$SaveResults             # Save results to file
)

Write-Host "🏁 PowerAuger Performance Benchmark" -ForegroundColor Cyan
Write-Host "Testing $Iterations iterations per scenario" -ForegroundColor Gray
Write-Host "=" * 50

# Import module
Import-Module "$PSScriptRoot\modules\PowerAuger\PowerAuger.psm1" -Force

# Test scenarios designed to trigger different models
$testScenarios = @(
    @{
        Name        = "Fast Model Tests"
        Description = "Simple completions that should use fast model"
        Tests       = @(
            "Get-Ch",     # Should complete to Get-ChildItem
            "Import-M",   # Should complete to Import-Module  
            "git st",     # Should complete to git status
            "dir",        # Simple command
            "cd",         # Navigation
            "ls",         # List files
            "echo",       # Simple output
            "type",       # File content
            "copy",       # File operations
            "del"         # File deletion
        )
    },
    @{
        Name        = "Context Model Tests" 
        Description = "Complex completions that should use context model"
        Tests       = @(
            "Get-Process | Where-Object",           # Pipeline operations
            "Get-ChildItem -Path C:\Windows -Recurse", # Complex parameters
            "Import-Module -Name PowerAuger -Force",   # Module with parameters
            "Set-Location -Path",                      # Path operations
            "Get-Service | Sort-Object Name | Select-Object", # Long pipeline
            "Invoke-RestMethod -Uri",                  # Web operations
            "Start-Process -FilePath",                 # Process management
            "Get-WmiObject -Class",                    # WMI queries
            "New-Object System.Collections.ArrayList", # Object creation
            "ForEach-Object { $_.Name }"               # Script blocks
        )
    }
)

# Benchmark results container
$benchmarkResults = @{
    StartTime = Get-Date
    Scenarios = @()
    Summary   = @{}
}

function Measure-PredictionPerformance {
    param(
        [string]$InputText,
        [string]$TestName,
        [switch]$WarmUp
    )
    
    $measurements = @()
    
    for ($i = 1; $i -le $Iterations; $i++) {
        if (-not $WarmUp -and $DetailedOutput) {
            Write-Progress -Activity "Testing $TestName" -Status "Iteration $i of $Iterations" -PercentComplete (($i / $Iterations) * 100)
        }
        
        # Clear any cached results to ensure fresh measurement
        if (-not $WarmUp) {
            $cacheKey = "*$($InputText.GetHashCode())*"
            $keysToRemove = $global:PredictionCache.Keys | Where-Object { $_ -like $cacheKey }
            foreach ($key in $keysToRemove) {
                $global:PredictionCache.Remove($key)
            }
        }
        
        # Measure prediction time
        $startTime = Get-Date
        try {
            $predictions = Get-CommandPrediction -InputLine $InputText
            $endTime = Get-Date
            $latency = ($endTime - $startTime).TotalMilliseconds
            
            if (-not $WarmUp) {
                $measurements += @{
                    Iteration       = $i
                    Latency         = $latency
                    PredictionCount = $predictions.Count
                    Success         = $true
                    FirstPrediction = if ($predictions.Count -gt 0) { $predictions[0] } else { "" }
                }
            }
        }
        catch {
            if (-not $WarmUp) {
                $measurements += @{
                    Iteration       = $i
                    Latency         = 999999  # High latency for failures
                    PredictionCount = 0
                    Success         = $false
                    Error           = $_.Exception.Message
                }
            }
        }
        
        # Small delay to avoid overwhelming the system
        Start-Sleep -Milliseconds 10
    }
    
    if (-not $WarmUp) {
        Write-Progress -Activity "Testing $TestName" -Completed
    }
    
    return $measurements
}

function Calculate-Statistics {
    param([array]$Measurements)
    
    $latencies = $Measurements | Where-Object { $_.Success } | ForEach-Object { $_.Latency }
    $successCount = ($Measurements | Where-Object { $_.Success }).Count
    
    if ($latencies.Count -eq 0) {
        return @{
            Min = 0; Max = 0; Avg = 0; Median = 0; P95 = 0; P99 = 0
            SuccessRate = 0; TotalTests = $Measurements.Count
        }
    }
    
    $sorted = $latencies | Sort-Object
    
    return @{
        Min         = [math]::Round($sorted[0], 1)
        Max         = [math]::Round($sorted[-1], 1) 
        Avg         = [math]::Round(($latencies | Measure-Object -Average).Average, 1)
        Median      = [math]::Round($sorted[[math]::Floor($sorted.Count / 2)], 1)
        P95         = [math]::Round($sorted[[math]::Floor($sorted.Count * 0.95)], 1)
        P99         = [math]::Round($sorted[[math]::Floor($sorted.Count * 0.99)], 1)
        SuccessRate = [math]::Round(($successCount / $Measurements.Count) * 100, 1)
        TotalTests  = $Measurements.Count
    }
}

# Warm up the system
Write-Host "`n🔥 Warming up system..." -ForegroundColor Yellow
foreach ($scenario in $testScenarios) {
    foreach ($test in $scenario.Tests[0..2]) {
        # Just warm up with first few tests
        Measure-PredictionPerformance -InputText $test -TestName "Warmup" -WarmUp | Out-Null
    }
}

# Capture initial state
$initialStats = Get-PredictorStatistics

Write-Host "`n📊 Running benchmarks..." -ForegroundColor Yellow

# Run benchmarks for each scenario
foreach ($scenario in $testScenarios) {
    Write-Host "`n🔍 $($scenario.Name)" -ForegroundColor Cyan
    Write-Host $scenario.Description -ForegroundColor Gray
    
    $scenarioResults = @{
        Name        = $scenario.Name
        Description = $scenario.Description
        Tests       = @()
    }
    
    foreach ($testInput in $scenario.Tests) {
        Write-Host "  Testing: $testInput" -ForegroundColor White
        
        $measurements = Measure-PredictionPerformance -InputText $testInput -TestName $testInput
        $stats = Calculate-Statistics -Measurements $measurements
        
        $testResult = @{
            InputText    = $testInput
            Measurements = $measurements
            Statistics   = $stats
        }
        
        $scenarioResults.Tests += $testResult
        
        # Display immediate results
        $statusColor = if ($stats.SuccessRate -eq 100) { "Green" } elseif ($stats.SuccessRate -gt 90) { "Yellow" } else { "Red" }
        Write-Host "    Avg: $($stats.Avg)ms | P95: $($stats.P95)ms | Success: $($stats.SuccessRate)%" -ForegroundColor $statusColor
        
        if ($DetailedOutput) {
            Write-Host "    Range: $($stats.Min)-$($stats.Max)ms | Median: $($stats.Median)ms" -ForegroundColor Gray
        }
    }
    
    $benchmarkResults.Scenarios += $scenarioResults
}

# Capture final state and calculate changes
$finalStats = Get-PredictorStatistics

Write-Host "`n📈 BENCHMARK RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 50

# Calculate scenario averages
foreach ($scenario in $benchmarkResults.Scenarios) {
    Write-Host "`n$($scenario.Name):" -ForegroundColor Yellow
    
    $allMeasurements = $scenario.Tests | ForEach-Object { $_.Measurements } | Where-Object { $_.Success }
    $overallStats = Calculate-Statistics -Measurements $allMeasurements
    
    Write-Host "  Average Latency: $($overallStats.Avg)ms" -ForegroundColor White
    Write-Host "  P95 Latency: $($overallStats.P95)ms" -ForegroundColor White
    Write-Host "  Success Rate: $($overallStats.SuccessRate)%" -ForegroundColor White
    Write-Host "  Tests Completed: $($overallStats.TotalTests)" -ForegroundColor White
    
    # Store in summary
    $benchmarkResults.Summary[$scenario.Name] = $overallStats
}

# Model comparison
Write-Host "`n🧠 MODEL ACCEPTANCE & ERROR RATES" -ForegroundColor Cyan
Write-Host "-" * 35

foreach ($modelName in $finalStats.AcceptanceRates.Keys) {
    $finalRate = $finalStats.AcceptanceRates[$modelName]
    $initialRate = if ($initialStats.AcceptanceRates.ContainsKey($modelName)) { $initialStats.AcceptanceRates[$modelName] } else { @{ Offered = 0; Accepted = 0; Errors = 0 } }

    $offeredDuringTest = $finalRate.Offered - $initialRate.Offered
    $acceptedDuringTest = $finalRate.Accepted - $initialRate.Accepted
    $errorsDuringTest = $finalRate.Errors - $initialRate.Errors

    $acceptanceRateDuringTest = if ($offeredDuringTest -gt 0) { [math]::Round(($acceptedDuringTest / $offeredDuringTest) * 100, 1) } else { 0 }
    $errorRateDuringTest = if ($acceptedDuringTest -gt 0) { [math]::Round(($errorsDuringTest / $acceptedDuringTest) * 100, 1) } else { 0 }

    Write-Host "$modelName:" -ForegroundColor Yellow
    Write-Host "  - Suggestions Offered: $offeredDuringTest" -ForegroundColor White
    Write-Host "  - Suggestions Accepted: $acceptedDuringTest" -ForegroundColor White
    Write-Host "  - Acceptance Rate: $acceptanceRateDuringTest%" -ForegroundColor White
    $errorColor = if ($errorsDuringTest -gt 0) { "Red" } else { "Green" }
    Write-Host "  - Errors on Acceptance: $errorsDuringTest ($($errorRateDuringTest)%)" -ForegroundColor $errorColor
}

# Context provider performance
Write-Host "`n🎯 CONTEXT PROVIDER PERFORMANCE" -ForegroundColor Cyan
Write-Host "-" * 30
Write-Host "Average time spent gathering context: $([math]::Round($finalStats.Performance.TotalContextTime, 1))ms" -ForegroundColor White
foreach ($provider in ($finalStats.Performance.ProviderTimings.GetEnumerator() | Sort-Object Name)) {
    Write-Host ("  - {0,-15}: {1}ms" -f $provider.Name, $([math]::Round($provider.Value, 2))) -ForegroundColor Gray
}

# Performance insights
Write-Host "`n💡 PERFORMANCE INSIGHTS" -ForegroundColor Magenta
Write-Host "-" * 25

$fastStats = $benchmarkResults.Summary["Fast Model Tests"]
$contextStats = $benchmarkResults.Summary["Context Model Tests"]
if ($fastStats -and $contextStats) {
    $speedDifference = $contextStats.Avg - $fastStats.Avg
    $speedRatio = [math]::Round($contextStats.Avg / $fastStats.Avg, 1)
    
    Write-Host "Context model is $([math]::Round($speedDifference, 1))ms slower than fast model" -ForegroundColor White
    Write-Host "Context model takes $($speedRatio)x longer than fast model" -ForegroundColor White
    
    if ($speedDifference -lt 100) {
        Write-Host "✅ Performance difference is acceptable (<100ms)" -ForegroundColor Green
    }
    elseif ($speedDifference -lt 500) {
        Write-Host "⚠️ Consider optimization - difference is $([math]::Round($speedDifference, 0))ms" -ForegroundColor Yellow
    }
    else {
        Write-Host "❌ Significant performance gap - optimization needed" -ForegroundColor Red
    }
}

# Recommendations
Write-Host "`n🎯 RECOMMENDATIONS" -ForegroundColor Magenta
Write-Host "-" * 20

if ($fastStats.Avg -gt 200) {
    Write-Host "• Fast model averaging $($fastStats.Avg)ms - consider model optimization" -ForegroundColor Yellow
}

if ($contextStats.Avg -gt 1000) {
    Write-Host "• Context model averaging $($contextStats.Avg)ms - consider timeout reduction" -ForegroundColor Yellow
}

$overallSuccessRate = ($fastStats.SuccessRate + $contextStats.SuccessRate) / 2
if ($overallSuccessRate -lt 95) {
    Write-Host "• Success rate is $([math]::Round($overallSuccessRate, 1))% - investigate failures" -ForegroundColor Red
}

# Save results if requested
if ($SaveResults) {
    $benchmarkResults.EndTime = Get-Date
    $benchmarkResults.ModelComparison = $modelComparison
    $benchmarkResults.FinalStats = $finalStats
    
    $resultsPath = "$PSScriptRoot\PowerAuger_Benchmark_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $benchmarkResults | ConvertTo-Json -Depth 10 | Set-Content -Path $resultsPath -Encoding UTF8
    
    Write-Host "`n📁 Benchmark results saved to: $resultsPath" -ForegroundColor Green
}

Write-Host "`n✅ Benchmark completed!" -ForegroundColor Green
Write-Host "Run with -DetailedOutput for per-test details or -SaveResults to save data" -ForegroundColor Gray