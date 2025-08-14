# Debug Ollama Models - Step by step troubleshooting
Write-Host "🔍 Debugging Ollama Model Issues..." -ForegroundColor Cyan

# Step 1: Verify connection and current config
Write-Host "`n📋 Step 1: Current Configuration" -ForegroundColor Yellow
Write-Host "API URL: $($global:OllamaConfig.Server.ApiUrl)" -ForegroundColor Gray
Write-Host "Fast Model: $($global:OllamaConfig.Models.FastCompletion.Name)" -ForegroundColor Gray
Write-Host "Context Model: $($global:OllamaConfig.Models.ContextAware.Name)" -ForegroundColor Gray

# Step 2: Test basic API connectivity
Write-Host "`n🌐 Step 2: Testing Basic API Connectivity" -ForegroundColor Yellow
try {
    $versionResponse = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/version" -Method Get -TimeoutSec 5
    Write-Host "✅ API Version: $($versionResponse.version)" -ForegroundColor Green
}
catch {
    Write-Host "❌ API connectivity failed: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Step 3: List and verify models
Write-Host "`n📦 Step 3: Verifying Available Models" -ForegroundColor Yellow
try {
    $modelsResponse = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/tags" -Method Get -TimeoutSec 5
    $availableModels = $modelsResponse.models
    
    Write-Host "Available models:" -ForegroundColor Cyan
    foreach ($model in $availableModels) {
        $sizeGB = [math]::Round($model.size / 1GB, 1)
        Write-Host "  - $($model.name) (${sizeGB}GB, modified: $($model.modified_at))" -ForegroundColor Gray
    }
    
    # Check if our configured models exist
    $fastModel = $global:OllamaConfig.Models.FastCompletion.Name
    $contextModel = $global:OllamaConfig.Models.ContextAware.Name
    
    $fastExists = $availableModels | Where-Object { $_.name -eq $fastModel }
    $contextExists = $availableModels | Where-Object { $_.name -eq $contextModel }
    
    if ($fastExists) {
        Write-Host "✅ Fast model '$fastModel' found" -ForegroundColor Green
    }
    else {
        Write-Host "❌ Fast model '$fastModel' NOT found" -ForegroundColor Red
    }
    
    if ($contextExists) {
        Write-Host "✅ Context model '$contextModel' found" -ForegroundColor Green
    }
    else {
        Write-Host "❌ Context model '$contextModel' NOT found" -ForegroundColor Red
    }
    
}
catch {
    Write-Host "❌ Failed to get model list: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Step 4: Test individual model requests
Write-Host "`n🧪 Step 4: Testing Individual Model Requests" -ForegroundColor Yellow

function Test-OllamaModel {
    param([string]$ModelName, [string]$TestPrompt = "Hello")
    
    Write-Host "Testing model: $ModelName" -ForegroundColor Cyan
    
    try {
        # Test with basic generate API
        $requestBody = @{
            model  = $ModelName
            prompt = $TestPrompt
            stream = $false
        } | ConvertTo-Json
        
        Write-Host "  Making request..." -ForegroundColor Gray
        $response = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/generate" -Method Post -Body $requestBody -ContentType 'application/json' -TimeoutSec 30
        
        if ($response.response) {
            Write-Host "  ✅ Model responded: $($response.response.Substring(0, [Math]::Min(50, $response.response.Length)))..." -ForegroundColor Green
            return $true
        }
        else {
            Write-Host "  ❌ Model returned empty response" -ForegroundColor Red
            return $false
        }
    }
    catch {
        Write-Host "  ❌ Model test failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# Test the fast model
$fastModel = $global:OllamaConfig.Models.FastCompletion.Name
$fastWorks = Test-OllamaModel -ModelName $fastModel -TestPrompt "pwd"

# Test the context model
$contextModel = $global:OllamaConfig.Models.ContextAware.Name
$contextWorks = Test-OllamaModel -ModelName $contextModel -TestPrompt "Get-"

# Step 5: Test PowerAuger's specific request format
Write-Host "`n🔧 Step 5: Testing PowerAuger Request Format" -ForegroundColor Yellow

if ($fastWorks) {
    Write-Host "Testing PowerAuger's JSON chat format with $fastModel..." -ForegroundColor Cyan
    
    try {
        $requestBody = @{
            model    = $fastModel
            messages = @(@{
                    role    = "user"
                    content = "Complete this PowerShell command: 'Get-Child'"
                })
            stream   = $false
            format   = "json"
            options  = @{
                temperature = 0.15
                top_p       = 0.6
                num_predict = 80
            }
        } | ConvertTo-Json -Depth 10
        
        Write-Host "  Making PowerAuger-style request..." -ForegroundColor Gray
        $response = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/chat" -Method Post -Body $requestBody -ContentType 'application/json' -TimeoutSec 30
        
        if ($response.message) {
            Write-Host "  ✅ PowerAuger format works: $($response.message.content.Substring(0, [Math]::Min(100, $response.message.content.Length)))..." -ForegroundColor Green
        }
        else {
            Write-Host "  ❌ PowerAuger format returned no message" -ForegroundColor Red
            Write-Host "  Response: $($response | ConvertTo-Json -Depth 3)" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "  ❌ PowerAuger format failed: $($_.Exception.Message)" -ForegroundColor Red
        
        # Try without JSON format
        Write-Host "  Trying without JSON format..." -ForegroundColor Yellow
        try {
            $requestBodyNoJson = @{
                model    = $fastModel
                messages = @(@{
                        role    = "user"
                        content = "Complete this PowerShell command: 'Get-Child'"
                    })
                stream   = $false
                options  = @{
                    temperature = 0.15
                    top_p       = 0.6
                    num_predict = 80
                }
            } | ConvertTo-Json -Depth 10
            
            $response2 = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/chat" -Method Post -Body $requestBodyNoJson -ContentType 'application/json' -TimeoutSec 30
            
            if ($response2.message) {
                Write-Host "  ✅ Works without JSON format!" -ForegroundColor Green
                Write-Host "  💡 Suggestion: PowerAuger may need to disable JSON format for your models" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  ❌ Both formats failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Step 6: Recommendations
Write-Host "`n💡 Step 6: Recommendations" -ForegroundColor Yellow

if (-not $fastWorks -and -not $contextWorks) {
    Write-Host "❌ Neither model is working. Possible issues:" -ForegroundColor Red
    Write-Host "  1. Models might be corrupted - try: ollama pull $fastModel" -ForegroundColor Gray
    Write-Host "  2. Ollama server might be overloaded" -ForegroundColor Gray
    Write-Host "  3. Models might not be compatible with chat API" -ForegroundColor Gray
}
elseif ($fastWorks -or $contextWorks) {
    Write-Host "✅ Basic model functionality works" -ForegroundColor Green
    Write-Host "💡 The issue is likely with PowerAuger's request format or timeout settings" -ForegroundColor Yellow
    Write-Host "Try these fixes:" -ForegroundColor Cyan
    Write-Host "  1. Increase timeout: Set-PredictorConfiguration -EnableDebug" -ForegroundColor Gray
    Write-Host "  2. Test with working model only" -ForegroundColor Gray
    Write-Host "  3. Disable JSON format in PowerAuger requests" -ForegroundColor Gray
}

Write-Host "`n🎯 Next steps based on results above..." -ForegroundColor Green