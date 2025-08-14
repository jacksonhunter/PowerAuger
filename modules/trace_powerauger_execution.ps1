# Trace PowerAuger execution step by step
Write-Host "🔍 Tracing PowerAuger Get-CommandPrediction execution..." -ForegroundColor Cyan

# Step 1: Enable full debug mode
Write-Host "`n🔧 Step 1: Enabling full debug mode" -ForegroundColor Yellow
$global:OllamaConfig.Performance.EnableDebug = $true
Write-Host "Debug enabled: $($global:OllamaConfig.Performance.EnableDebug)" -ForegroundColor Green

# Step 2: Test the internal function calls manually
Write-Host "`n📝 Step 2: Testing internal functions manually" -ForegroundColor Yellow

# Test Get-EnhancedContext manually within module scope
try {
    Write-Host "Testing Get-EnhancedContext..." -ForegroundColor Cyan
    $result = & (Get-Module PowerAuger) { Get-EnhancedContext -InputLine "Get-Child" -CursorIndex 9 }
    if ($result) {
        Write-Host "✅ Get-EnhancedContext works!" -ForegroundColor Green
        Write-Host "  Directory: $($result.Environment.Directory)" -ForegroundColor Gray
        Write-Host "  Has complex context: $($result.HasComplexContext)" -ForegroundColor Gray
    }
    else {
        Write-Host "❌ Get-EnhancedContext returned null" -ForegroundColor Red
    }
}
catch {
    Write-Host "❌ Get-EnhancedContext failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Test Select-OptimalModel manually within module scope
try {
    Write-Host "Testing Select-OptimalModel..." -ForegroundColor Cyan
    $result2 = & (Get-Module PowerAuger) { Select-OptimalModel -InputLine "Get-Child" -Context $result }
    if ($result2) {
        Write-Host "✅ Select-OptimalModel works!" -ForegroundColor Green
        Write-Host "  Selected model: $($result2.Name)" -ForegroundColor Gray
        Write-Host "  Timeout: $($result2.Timeout)ms" -ForegroundColor Gray
    }
    else {
        Write-Host "❌ Select-OptimalModel returned null" -ForegroundColor Red
    }
}
catch {
    Write-Host "❌ Select-OptimalModel failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Step 3: Test the core Ollama function manually
Write-Host "`n🔧 Step 3: Testing Invoke-OllamaCompletion manually" -ForegroundColor Yellow
try {
    Write-Host "Testing Invoke-OllamaCompletion..." -ForegroundColor Cyan
    $result3 = & (Get-Module PowerAuger) { 
        Invoke-OllamaCompletion -Model "powershell-fast:latest" -Prompt "Get-Child" -Context $result -TimeoutMs 10000
    }
    if ($result3) {
        Write-Host "✅ Invoke-OllamaCompletion works!" -ForegroundColor Green
        Write-Host "  Result type: $($result3.GetType().Name)" -ForegroundColor Gray
        if ($result3.completions) {
            Write-Host "  Completions found: $($result3.completions.Count)" -ForegroundColor Gray
            $result3.completions | Select-Object -First 3 | ForEach-Object { 
                if ($_ -is [string]) {
                    Write-Host "    - $_" -ForegroundColor Cyan
                }
                elseif ($_.text) {
                    Write-Host "    - $($_.text)" -ForegroundColor Cyan
                }
            }
        }
        else {
            Write-Host "  No completions field" -ForegroundColor Yellow
            Write-Host "  Raw result: $($result3 | ConvertTo-Json -Depth 2)" -ForegroundColor Gray
        }
    }
    else {
        Write-Host "❌ Invoke-OllamaCompletion returned null" -ForegroundColor Red
    }
}
catch {
    Write-Host "❌ Invoke-OllamaCompletion failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack trace: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
}

# Step 4: Test with simplified parameters
Write-Host "`n🧪 Step 4: Testing with minimal parameters" -ForegroundColor Yellow
try {
    Write-Host "Testing minimal Get-CommandPrediction call..." -ForegroundColor Cyan
    $result4 = Get-CommandPrediction -InputLine "pwd"
    if ($result4) {
        Write-Host "✅ Minimal call works!" -ForegroundColor Green
        $result4 | ForEach-Object { "  - $_" } | Write-Host -ForegroundColor Cyan
    }
    else {
        Write-Host "❌ Minimal call returned nothing" -ForegroundColor Red
    }
}
catch {
    Write-Host "❌ Minimal call failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Step 5: Check cache behavior
Write-Host "`n💾 Step 5: Checking cache behavior" -ForegroundColor Yellow
Write-Host "Cache entries before: $($global:PredictionCache.Count)" -ForegroundColor Gray

try {
    $result5 = Get-CommandPrediction -InputLine "ls"
    Write-Host "Cache entries after: $($global:PredictionCache.Count)" -ForegroundColor Gray
    
    if ($global:PredictionCache.Count -gt 0) {
        $latestCache = $global:PredictionCache.GetEnumerator() | Sort-Object { $_.Value.Timestamp } | Select-Object -Last 1
        Write-Host "Latest cache entry:" -ForegroundColor Cyan
        Write-Host "  Key: $($latestCache.Key)" -ForegroundColor Gray
        Write-Host "  Result count: $($latestCache.Value.Result.Count)" -ForegroundColor Gray
        Write-Host "  Timestamp: $($latestCache.Value.Timestamp)" -ForegroundColor Gray
    }
}
catch {
    Write-Host "Cache test failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Step 6: Check performance metrics
Write-Host "`n📊 Step 6: Performance metrics" -ForegroundColor Yellow
Write-Host "Request count: $($global:PerformanceMetrics.RequestCount)" -ForegroundColor Gray
Write-Host "Success rate: $($global:PerformanceMetrics.SuccessRate)" -ForegroundColor Gray
Write-Host "Cache hits: $($global:PerformanceMetrics.CacheHits)" -ForegroundColor Gray

Write-Host "`n🎯 Trace complete!" -ForegroundColor Green