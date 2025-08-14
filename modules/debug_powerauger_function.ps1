# Debug PowerAuger Get-CommandPrediction function step by step

Write-Host "🔍 Debugging PowerAuger Get-CommandPrediction..." -ForegroundColor Cyan

# Step 1: Verify model configuration
Write-Host "`n📋 Step 1: Current Model Configuration" -ForegroundColor Yellow
Write-Host "Fast Model: $($global:OllamaConfig.Models.FastCompletion.Name)" -ForegroundColor Gray
Write-Host "Context Model: $($global:OllamaConfig.Models.ContextAware.Name)" -ForegroundColor Gray
Write-Host "Registry Fast: $($global:ModelRegistry.FastCompletion.Name)" -ForegroundColor Gray
Write-Host "Registry Context: $($global:ModelRegistry.ContextAware.Name)" -ForegroundColor Gray

# Step 2: Test connection
Write-Host "`n🌐 Step 2: Testing Connection" -ForegroundColor Yellow
$connectionResult = Test-OllamaConnection
Write-Host "Connection result: $connectionResult" -ForegroundColor $(if ($connectionResult) { 'Green' } else { 'Red' })

# Step 3: Test context generation
Write-Host "`n📝 Step 3: Testing Context Generation" -ForegroundColor Yellow
try {
    $context = Get-EnhancedContext -InputLine "Get-Child" -CursorIndex 9
    Write-Host "Context generated successfully" -ForegroundColor Green
    Write-Host "Context directory: $($context.Environment.Directory)" -ForegroundColor Gray
    Write-Host "Has complex context: $($context.HasComplexContext)" -ForegroundColor Gray
    Write-Host "Has targets: $($context.HasTargets)" -ForegroundColor Gray
}
catch {
    Write-Host "❌ Context generation failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Step 4: Test model selection
Write-Host "`n🎯 Step 4: Testing Model Selection" -ForegroundColor Yellow
try {
    $selectedModel = Select-OptimalModel -InputLine "Get-Child" -Context $context
    Write-Host "Selected model: $($selectedModel.Name)" -ForegroundColor Green
    Write-Host "Model timeout: $($selectedModel.Timeout)ms" -ForegroundColor Gray
    Write-Host "Model use case: $($selectedModel.UseCase)" -ForegroundColor Gray
}
catch {
    Write-Host "❌ Model selection failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Step 5: Test Ollama request directly
Write-Host "`n🔧 Step 5: Testing Direct Ollama Request" -ForegroundColor Yellow
try {
    Write-Host "Testing with model: $($selectedModel.Name)" -ForegroundColor Cyan
    
    # Build the prompt like PowerAuger does
    $promptParts = @()
    $promptParts += "COMPLETE: Get-Child"
    $promptParts += "DIRECTORY: $($context.Environment.Directory)"
    if ($global:RecentTargets) {
        $promptParts += "RECENT: $($global:RecentTargets | Select-Object -First 5 | Join-String -Separator ', ')"
    }
    $enhancedPrompt = $promptParts -join "`n"
    
    Write-Host "Enhanced prompt:" -ForegroundColor Gray
    Write-Host $enhancedPrompt -ForegroundColor DarkGray
    
    # Make the request exactly like PowerAuger does
    $requestBody = @{
        model    = $selectedModel.Name
        messages = @(@{
                role    = "user"
                content = $enhancedPrompt
            })
        stream   = $false
        options  = @{
            temperature = $selectedModel.Temperature
            top_p       = $selectedModel.TopP
            num_predict = $selectedModel.MaxTokens
        }
        format   = "json"
    }
    
    Write-Host "`nMaking request..." -ForegroundColor Cyan
    $response = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/chat" -Method Post -Body ($requestBody | ConvertTo-Json -Depth 10) -ContentType 'application/json' -TimeoutSec 30
    
    if ($response.message) {
        Write-Host "✅ Raw response received" -ForegroundColor Green
        Write-Host "Response content preview: $($response.message.content.Substring(0, [Math]::Min(200, $response.message.content.Length)))..." -ForegroundColor Gray
        
        # Try to parse JSON
        try {
            $cleanJson = $response.message.content -replace '```json\s*', '' -replace '```\s*$', ''
            $parsedJson = $cleanJson | ConvertFrom-Json
            Write-Host "✅ JSON parsed successfully" -ForegroundColor Green
            
            if ($parsedJson.completions) {
                Write-Host "✅ Found completions array with $($parsedJson.completions.Count) items" -ForegroundColor Green
                $parsedJson.completions | ForEach-Object { 
                    if ($_ -is [string]) {
                        Write-Host "  - $_" -ForegroundColor Cyan
                    }
                    elseif ($_.text) {
                        Write-Host "  - $($_.text)" -ForegroundColor Cyan
                    }
                    else {
                        Write-Host "  - $($_)" -ForegroundColor Cyan
                    }
                }
            }
            else {
                Write-Host "❌ No 'completions' field in JSON response" -ForegroundColor Red
                Write-Host "JSON structure: $($parsedJson | ConvertTo-Json -Depth 2)" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "❌ JSON parsing failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Raw content: $($response.message.content)" -ForegroundColor Gray
        }
    }
    else {
        Write-Host "❌ No message in response" -ForegroundColor Red
        Write-Host "Response: $($response | ConvertTo-Json -Depth 3)" -ForegroundColor Gray
    }
    
}
catch {
    Write-Host "❌ Direct request failed: $($_.Exception.Message)" -ForegroundColor Red
}

# Step 6: Test PowerAuger function with debug
Write-Host "`n🔬 Step 6: Testing PowerAuger Function with Verbose Output" -ForegroundColor Yellow

# Enable debug if not already
$originalDebug = $global:OllamaConfig.Performance.EnableDebug
$global:OllamaConfig.Performance.EnableDebug = $true

try {
    Write-Host "Calling Get-CommandPrediction with debug enabled..." -ForegroundColor Cyan
    $result = Get-CommandPrediction -InputLine "Get-Child" -CursorIndex 9
    
    if ($result) {
        Write-Host "✅ PowerAuger returned results:" -ForegroundColor Green
        $result | ForEach-Object { "  - $_" } | Write-Host -ForegroundColor Cyan
    }
    else {
        Write-Host "❌ PowerAuger returned no results" -ForegroundColor Red
    }
}
catch {
    Write-Host "❌ PowerAuger function failed: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    # Restore original debug setting
    $global:OllamaConfig.Performance.EnableDebug = $originalDebug
}

# Step 7: Check cache
Write-Host "`n💾 Step 7: Checking Cache State" -ForegroundColor Yellow
Write-Host "Cache entries: $($global:PredictionCache.Count)" -ForegroundColor Gray
if ($global:PredictionCache.Count -gt 0) {
    $global:PredictionCache.GetEnumerator() | ForEach-Object {
        Write-Host "  Cache key: $($_.Key)" -ForegroundColor Gray
        Write-Host "  Timestamp: $($_.Value.Timestamp)" -ForegroundColor Gray
        Write-Host "  Result count: $($_.Value.Result.Count)" -ForegroundColor Gray
    }
}

Write-Host "`n🎯 Debug complete!" -ForegroundColor Green