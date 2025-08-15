# ========================================================================================================
# COMPLETE GLOBALS SETUP GUIDE FOR POWERAUGER COMMAND PREDICTOR
# Comprehensive setup and troubleshooting for all global variables
# ========================================================================================================

Write-Host "🔧 Starting Complete PowerAuger Setup..." -ForegroundColor Cyan

# --------------------------------------------------------------------------------------------------------
# STEP 0: CREATE CENTRAL DATA DIRECTORY
# All configuration, history, and cache files will be stored here.
# --------------------------------------------------------------------------------------------------------

Write-Host "`n📁 Step 0: Setting up central data directory..." -ForegroundColor Yellow

$powerAugerDataPath = Join-Path -Path $env:USERPROFILE -ChildPath ".PowerAuger"
if (-not (Test-Path $powerAugerDataPath)) {
    New-Item -Path $powerAugerDataPath -ItemType Directory -Force | Out-Null
    Write-Host "✅ Created data directory at: $powerAugerDataPath" -ForegroundColor Green
}
else {
    Write-Host "✅ Data directory already exists at: $powerAugerDataPath" -ForegroundColor Green
}


# --------------------------------------------------------------------------------------------------------
# STEP 1: VERIFY MODULE IMPORT AND AUTO-INITIALIZATION
# --------------------------------------------------------------------------------------------------------

Write-Host "`n📦 Step 1: Verifying PowerAuger Module Import..." -ForegroundColor Yellow

# Import the correct PowerAuger module (this should auto-initialize most globals)
if (-not (Get-Module PowerAuger)) {
    try {
        # Try importing with manifest first (preferred)
        if (Test-Path .\PowerAuger.psd1) {
            Import-Module .\PowerAuger.psd1 -Force
            Write-Host "✅ PowerAuger module imported via manifest" -ForegroundColor Green
        }
        # Fallback to direct .psm1 import
        elseif (Test-Path .\PowerAuger.psm1) {
            Import-Module .\PowerAuger.psm1 -Force
            Write-Host "✅ PowerAuger module imported directly" -ForegroundColor Green
        }
        else {
            throw "PowerAuger module files not found"
        }
    }
    catch {
        Write-Host "❌ Module import failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Please ensure PowerAuger.psm1 and PowerAuger.psd1 are in the current directory" -ForegroundColor Yellow
        return
    }
}

# Check if globals were auto-initialized
Write-Host "`n🔍 Checking auto-initialized globals..." -ForegroundColor Cyan

$globalChecks = @{
    'OllamaConfig'       = $global:OllamaConfig
    'PredictionCache'    = $global:PredictionCache  
    'ChatSessions'       = $global:ChatSessions
    'RecentTargets'      = $global:RecentTargets
    'CommandHistory'     = $global:CommandHistory
    'PerformanceMetrics' = $global:PerformanceMetrics
    'ContextProviders'   = $global:ContextProviders
    'ModelRegistry'      = $global:ModelRegistry
}

$missingGlobals = @()
foreach ($check in $globalChecks.GetEnumerator()) {
    if ($check.Value) {
        Write-Host "✅ $($check.Key) initialized" -ForegroundColor Green
    }
    else {
        Write-Host "❌ $($check.Key) missing" -ForegroundColor Red
        $missingGlobals += $check.Key
    }
}

# --------------------------------------------------------------------------------------------------------
# STEP 2: MANUAL GLOBALS INITIALIZATION (if needed)
# --------------------------------------------------------------------------------------------------------

if ($missingGlobals.Count -gt 0) {
    Write-Host "`n🔧 Step 2: Manually initializing missing globals..." -ForegroundColor Yellow
    
    # Initialize OllamaConfig if missing
    if ('OllamaConfig' -in $missingGlobals) {
        Write-Host "Initializing OllamaConfig..." -ForegroundColor Cyan
        $global:OllamaConfig = @{
            # Server Configuration
            Server      = @{
                LinuxHost     = "192.168.50.194"
                LinuxPort     = 11434
                LocalPort     = 11434
                SSHUser       = $null # Will be auto-detected or prompted for
                SSHKey        = $null # Will be auto-detected
                TunnelProcess = $null
                IsConnected   = $false
                ApiUrl        = "http://localhost:11434"
            }
            
            # Model Strategy
            Models      = @{
                FastCompletion = @{
                    Name        = "powershell-fast"
                    UseCase     = "Quick completions <10 chars"
                    KeepAlive   = "30s"
                    MaxTokens   = 80
                    Temperature = 0.15
                    TopP        = 0.6
                    Timeout     = 8000
                }
                ContextAware   = @{
                    Name        = "powershell-context"
                    UseCase     = "Complex completions with environment"
                    KeepAlive   = "5m"
                    MaxTokens   = 150
                    Temperature = 0.3
                    TopP        = 0.8
                    Timeout     = 15000
                }
            }
            
            # Performance Settings
            Performance = @{
                CacheTimeout            = 300
                CacheSize               = 200
                MaxHistoryLines         = 1000
                RecentTargetsCount      = 30
                SessionCleanupMinutes   = 30
                EnableDebug             = $false
                EnablePredictionLogging = $true # Enabled by default as requested
            }
        }
        Write-Host "✅ OllamaConfig initialized" -ForegroundColor Green
    }
    
    # Initialize other missing globals (same as before but more concise)
    if ('PredictionCache' -in $missingGlobals) {
        $global:PredictionCache = @{}
        Write-Host "✅ PredictionCache initialized" -ForegroundColor Green
    }
    
    if ('ChatSessions' -in $missingGlobals) {
        $global:ChatSessions = @{}
        Write-Host "✅ ChatSessions initialized" -ForegroundColor Green
    }
    
    if ('RecentTargets' -in $missingGlobals) {
        $global:RecentTargets = @()
        Write-Host "✅ RecentTargets initialized" -ForegroundColor Green
    }
    
    if ('CommandHistory' -in $missingGlobals) {
        $global:CommandHistory = @()
        Write-Host "✅ CommandHistory initialized" -ForegroundColor Green
    }
    
    if ('PerformanceMetrics' -in $missingGlobals) {
        $global:PerformanceMetrics = @{
            RequestCount   = 0
            CacheHits      = 0
            AverageLatency = 0
            SuccessRate    = 1.0
        }
        Write-Host "✅ PerformanceMetrics initialized" -ForegroundColor Green
    }
    
    if ('ContextProviders' -in $missingGlobals) {
        Write-Host "❌ FATAL: ContextProviders global is missing even after module import." -ForegroundColor Red
        Write-Host "   This indicates a corrupted module. Please reinstall PowerAuger or restart your session." -ForegroundColor Yellow
        # This is a critical failure, so we stop the script.
        return
    }
    
    if ('ModelRegistry' -in $missingGlobals) {
        $global:ModelRegistry = @{
            'FastCompletion' = $global:OllamaConfig.Models.FastCompletion
            'ContextAware'   = $global:OllamaConfig.Models.ContextAware
        }
        Write-Host "✅ ModelRegistry initialized" -ForegroundColor Green
    }
    
    # Initialize missing tracking variables
    if (-not $global:LastProcessedCommandId) {
        $global:LastProcessedCommandId = 0
    }
}
else {
    Write-Host "`n✅ Step 2: All globals already initialized!" -ForegroundColor Green
}

# --------------------------------------------------------------------------------------------------------
# STEP 3: CUSTOMIZE CONFIGURATION FOR YOUR ENVIRONMENT
# --------------------------------------------------------------------------------------------------------

Write-Host "`n⚙️ Step 3: Customizing configuration for your environment..." -ForegroundColor Yellow

# Get current user information for SSH
$currentUser = $env:USERNAME
$sshKeyPath = "$env:USERPROFILE\.ssh\id_rsa"

Write-Host "Current Windows user: $currentUser" -ForegroundColor Cyan
Write-Host "SSH key path: $sshKeyPath" -ForegroundColor Cyan

# Check if SSH key exists
if (Test-Path $sshKeyPath) {
    Write-Host "✅ SSH key found" -ForegroundColor Green
    $global:OllamaConfig.Server.SSHKey = $sshKeyPath
}
else {
    Write-Host "⚠️ SSH key not found at default location" -ForegroundColor Yellow
    
    # Look for alternative SSH key locations
    $altKeyPaths = @(
        "$env:USERPROFILE\.ssh\id_ed25519",
        "$env:USERPROFILE\.ssh\id_ecdsa",
        "$env:USERPROFILE\.ssh\id_dsa"
    )
    
    $foundKey = $false
    foreach ($keyPath in $altKeyPaths) {
        if (Test-Path $keyPath) {
            Write-Host "✅ Found SSH key: $keyPath" -ForegroundColor Green
            $global:OllamaConfig.Server.SSHKey = $keyPath
            $foundKey = $true
            break
        }
    }
    
    if (-not $foundKey) {
        Write-Host "❌ No SSH keys found. You may need to generate one:" -ForegroundColor Red
        Write-Host "   ssh-keygen -t rsa -b 4096 -C 'your-email@example.com'" -ForegroundColor Gray
    }
}

# Prompt for server customization
Write-Host "`n🌐 Server Configuration:" -ForegroundColor Cyan
Write-Host "Current Linux host: $($global:OllamaConfig.Server.LinuxHost)" -ForegroundColor Gray

$newHost = Read-Host "Enter Linux server IP (press Enter to keep current)"
if ($newHost) {
    $global:OllamaConfig.Server.LinuxHost = $newHost
    Write-Host "✅ Updated Linux host to: $newHost" -ForegroundColor Green
}

$newUser = Read-Host "Enter SSH username (press Enter to use current Windows username: $currentUser)"
if ($newUser) {
    $global:OllamaConfig.Server.SSHUser = $newUser
}
else {
    $global:OllamaConfig.Server.SSHUser = $currentUser
}
Write-Host "✅ SSH user set to: $($global:OllamaConfig.Server.SSHUser)" -ForegroundColor Green

# Update API URL to match configuration
$global:OllamaConfig.Server.ApiUrl = "http://localhost:$($global:OllamaConfig.Server.LocalPort)"

# --------------------------------------------------------------------------------------------------------
# STEP 4: VERIFY POWERAUGER FUNCTIONS ARE AVAILABLE
# --------------------------------------------------------------------------------------------------------

Write-Host "`n🔧 Step 4: Verifying PowerAuger functions..." -ForegroundColor Yellow

$requiredFunctions = @(
    'Get-CommandPrediction',
    'Initialize-OllamaPredictor',
    'Set-PredictorConfiguration',
    'Start-OllamaTunnel',
    'Stop-OllamaTunnel',
    'Test-OllamaConnection',
    'Show-PredictorStatus',
    'Get-PredictorStatistics'
)

$missingFunctions = @()
foreach ($func in $requiredFunctions) {
    if (Get-Command $func -ErrorAction SilentlyContinue) {
        Write-Host "✅ Function '$func' available" -ForegroundColor Green
    }
    else {
        Write-Host "❌ Function '$func' missing" -ForegroundColor Red
        $missingFunctions += $func
    }
}

if ($missingFunctions.Count -gt 0) {
    Write-Host "❌ Missing PowerAuger functions detected!" -ForegroundColor Red
    Write-Host "This suggests the PowerAuger module didn't load properly." -ForegroundColor Yellow
    Write-Host "Missing functions: $($missingFunctions -join ', ')" -ForegroundColor Red
    return
}

# --------------------------------------------------------------------------------------------------------
# STEP 5: TEST CONNECTION AND AUTO-CONFIGURE MODELS
# --------------------------------------------------------------------------------------------------------

Write-Host "`n🤖 Step 5: Testing Ollama connection and auto-configuring models..." -ForegroundColor Yellow

# Test connection first
$connectionTest = Test-NetConnection -ComputerName $global:OllamaConfig.Server.LinuxHost -Port 22 -InformationLevel Quiet
if ($connectionTest) {
    Write-Host "✅ Network connection to Linux host successful" -ForegroundColor Green
    
    # Try to connect via PowerAuger functions and get available models
    try {
        if (Test-OllamaConnection) {
            Write-Host "✅ PowerAuger Ollama connection successful" -ForegroundColor Green
            
            # Get available models and auto-configure
            try {
                $models = Invoke-RestMethod -Uri "$($global:OllamaConfig.Server.ApiUrl)/api/tags" -TimeoutSec 5
                Write-Host "✅ Successfully connected to Ollama server" -ForegroundColor Green
                Write-Host "Available models:" -ForegroundColor Cyan
                $availableModels = $models.models.name
                $availableModels | ForEach-Object { "  - $_" } | Write-Host -ForegroundColor Gray
                
                # Auto-detect and fix model names
                Write-Host "`n🔧 Auto-configuring model names..." -ForegroundColor Yellow
                
                # Current configured models
                $configuredFast = $global:OllamaConfig.Models.FastCompletion.Name
                $configuredContext = $global:OllamaConfig.Models.ContextAware.Name
                
                Write-Host "Current Fast Model: $configuredFast" -ForegroundColor Gray
                Write-Host "Current Context Model: $configuredContext" -ForegroundColor Gray
                
                # Find best matches for PowerShell models
                $fastMatch = $availableModels | Where-Object { 
                    $_ -like "*powershell*fast*" -or $_ -eq "powershell-fast:latest" 
                } | Select-Object -First 1
                
                $contextMatch = $availableModels | Where-Object { 
                    $_ -like "*powershell*context*" -or $_ -eq "powershell-context:latest" 
                } | Select-Object -First 1
                
                # Update configuration if we found better matches
                $configUpdated = $false
                if ($fastMatch -and $fastMatch -ne $configuredFast) {
                    Write-Host "🔄 Updating Fast model: $configuredFast → $fastMatch" -ForegroundColor Cyan
                    $global:OllamaConfig.Models.FastCompletion.Name = $fastMatch
                    $configUpdated = $true
                }
                elseif ($fastMatch) {
                    Write-Host "✅ Fast model '$fastMatch' found and configured correctly" -ForegroundColor Green
                }
                else {
                    Write-Host "⚠️ No PowerShell fast model found - using fallback" -ForegroundColor Yellow
                    # Try to use a general purpose small model as fallback
                    $fallbackFast = $availableModels | Where-Object {
                        $_ -like "*qwen*4b*" -or $_ -like "*3b*" -or $_ -like "*small*"
                    } | Select-Object -First 1
                    if ($fallbackFast) {
                        Write-Host "🔄 Using fallback fast model: $fallbackFast" -ForegroundColor Yellow
                        $global:OllamaConfig.Models.FastCompletion.Name = $fallbackFast
                        $configUpdated = $true
                    }
                }
                
                if ($contextMatch -and $contextMatch -ne $configuredContext) {
                    Write-Host "🔄 Updating Context model: $configuredContext → $contextMatch" -ForegroundColor Cyan
                    $global:OllamaConfig.Models.ContextAware.Name = $contextMatch
                    $configUpdated = $true
                }
                elseif ($contextMatch) {
                    Write-Host "✅ Context model '$contextMatch' found and configured correctly" -ForegroundColor Green
                }
                else {
                    Write-Host "⚠️ No PowerShell context model found - using fallback" -ForegroundColor Yellow
                    # Try to use a larger general purpose model as fallback
                    $fallbackContext = $availableModels | Where-Object {
                        $_ -like "*qwen*30b*" -or $_ -like "*coder*" -or $_ -like "*large*"
                    } | Select-Object -First 1
                    if ($fallbackContext) {
                        Write-Host "🔄 Using fallback context model: $fallbackContext" -ForegroundColor Yellow
                        $global:OllamaConfig.Models.ContextAware.Name = $fallbackContext
                        $configUpdated = $true
                    }
                }
                
                # Auto-update configuration if successful
                if ($configUpdated) {
                    Write-Host "✅ Model configuration updated!" -ForegroundColor Green
                    Write-Host "New Fast Model: $($global:OllamaConfig.Models.FastCompletion.Name)" -ForegroundColor Green
                    Write-Host "New Context Model: $($global:OllamaConfig.Models.ContextAware.Name)" -ForegroundColor Green
                    
                    # Update the configuration using the module's function to ensure persistence
                    try {
                        Set-PredictorConfiguration
                        Write-Host "✅ Configuration saved successfully via PowerAuger." -ForegroundColor Green
                    }
                    catch {
                        Write-Host "⚠️ Could not save updated model configuration: $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }
            }
            catch {
                Write-Host "⚠️ Could not get model list: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "Proceeding with current configuration..." -ForegroundColor Gray
            }
            
            # Show current status
            Show-PredictorStatus
        }
        else {
            Write-Host "⚠️ PowerAuger connection test failed" -ForegroundColor Yellow
            Write-Host "This is normal if Ollama isn't running or models aren't deployed yet" -ForegroundColor Gray
        }
    }
    catch {
        Write-Host "⚠️ Could not test Ollama connection: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "❌ Cannot reach Linux host at $($global:OllamaConfig.Server.LinuxHost)" -ForegroundColor Red
    Write-Host "Please verify the IP address and network connectivity" -ForegroundColor Gray
}

# --------------------------------------------------------------------------------------------------------
# STEP 6: INITIALIZE POWERAUGER PREDICTOR
# --------------------------------------------------------------------------------------------------------

Write-Host "`n🚀 Step 6: Initializing PowerAuger Predictor..." -ForegroundColor Yellow

try {
    # Ask about debug mode
    $enableDebug = Read-Host "Enable debug mode for verbose logging? (y/N)"
    if ($enableDebug -eq 'y' -or $enableDebug -eq 'Y') {
        $debugMode = $true
        Write-Host "✅ Debug mode will be enabled" -ForegroundColor Green
    }
    else {
        $debugMode = $false
        Write-Host "✅ Debug mode will be disabled" -ForegroundColor Green
    }
    
    # Initialize the predictor with settings
    Initialize-OllamaPredictor -EnableDebug:$debugMode
    $global:OllamaConfig.Performance.EnableDebug = $debugMode # Ensure this is set for saving
    Write-Host "✅ PowerAuger Predictor initialized successfully!" -ForegroundColor Green
}
catch {
    Write-Host "❌ Error initializing PowerAuger: $($_.Exception.Message)" -ForegroundColor Red
}

# --------------------------------------------------------------------------------------------------------
# STEP 7: CENTRALIZED CONFIGURATION & PROFILE SETUP
# --------------------------------------------------------------------------------------------------------

Write-Host "`n💾 Step 7: Saving configuration and setting up profile..." -ForegroundColor Yellow

# --- Part A: Save configuration and create data files in ~/.PowerAuger ---
Write-Host "📝 Saving configuration to JSON..." -ForegroundColor Cyan
try {    
    # Use the module's built-in function to save all state files (config, history, etc.)
    # This ensures consistency and centralizes the persistence logic.
    Save-PowerAugerState
    Write-Host "✅ Configuration and state files saved to: $powerAugerDataPath" -ForegroundColor Green
}
catch {
    Write-Host "❌ Failed to save configuration using Save-PowerAugerState: $($_.Exception.Message)" -ForegroundColor Red
}

# --- Part B: Add auto-load command to PowerShell Profile ---
Write-Host "`n🔌 Configuring PowerShell profile for auto-loading..." -ForegroundColor Cyan
try {
    # Determine the absolute path to the module manifest to ensure it can be loaded from anywhere
    $moduleManifestPath = Join-Path $PSScriptRoot "PowerAuger.psd1"

    if (-not (Test-Path $PROFILE)) {
        New-Item -Path $PROFILE -Type File -Force | Out-Null
        Write-Host "✅ Created new PowerShell profile at: $PROFILE" -ForegroundColor Green
    }

    $profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    # Use the absolute path to the manifest for robust loading. Use single quotes to handle spaces in path.
    $loaderBlock = "# PowerAuger Auto-Loader`nImport-Module '$moduleManifestPath'"

    if ($profileContent -notlike "*# PowerAuger Auto-Loader*") {
        Add-Content -Path $PROFILE -Value "`n`n$loaderBlock" -Force
        Write-Host "✅ Added PowerAuger auto-loader to your profile (using absolute path)." -ForegroundColor Green
    }
    else {
        Write-Host "✅ PowerAuger auto-loader already exists in your profile." -ForegroundColor Green
    }
    Write-Host "   PowerAuger will now load automatically in new PowerShell sessions." -ForegroundColor White
}
catch {
    Write-Host "❌ Failed to write to profile: $($_.Exception.Message)" -ForegroundColor Red
}

# --------------------------------------------------------------------------------------------------------
# FINAL SUMMARY AND NEXT STEPS
# --------------------------------------------------------------------------------------------------------

Write-Host "`n🎉 PowerAuger Setup Complete!" -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray

Write-Host "`n📝 Configuration Summary:" -ForegroundColor Cyan
Write-Host "Linux Host: $($global:OllamaConfig.Server.LinuxHost)" -ForegroundColor White
Write-Host "SSH User: $($global:OllamaConfig.Server.SSHUser)" -ForegroundColor White
Write-Host "Fast Model: $($global:OllamaConfig.Models.FastCompletion.Name)" -ForegroundColor White
Write-Host "Context Model: $($global:OllamaConfig.Models.ContextAware.Name)" -ForegroundColor White
Write-Host "Data Path: $powerAugerDataPath" -ForegroundColor White

Write-Host "`n📋 Next Steps:" -ForegroundColor Cyan
Write-Host "1. Enable PSReadLine integration:" -ForegroundColor White
Write-Host "   Set-PSReadLineOption -PredictionSource HistoryAndPlugin" -ForegroundColor Gray

Write-Host "`n2. Test the predictor:" -ForegroundColor White
Write-Host "   Get-CommandPrediction -InputLine 'Get-Child'" -ForegroundColor Gray

# Actually test it to verify it works
Write-Host "`n🧪 Testing predictor with configured models..." -ForegroundColor Yellow
try {
    $testResult = Get-CommandPrediction -InputLine "Get-Child"
    if ($testResult -and $testResult.Count -gt 0) {
        Write-Host "✅ Predictor test successful!" -ForegroundColor Green
        Write-Host "Sample predictions:" -ForegroundColor Cyan
        $testResult | Select-Object -First 3 | ForEach-Object { "  - $_" } | Write-Host -ForegroundColor Gray
    }
    else {
        Write-Host "⚠️ Predictor test returned no results" -ForegroundColor Yellow
        Write-Host "   This may be normal for new setups - try typing commands to build history" -ForegroundColor Gray
    }
}
catch {
    Write-Host "❌ Predictor test failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "   Check model configuration and Ollama connectivity" -ForegroundColor Gray
}

Write-Host "`n3. Check status anytime:" -ForegroundColor White
Write-Host "   Show-PredictorStatus" -ForegroundColor Gray

Write-Host "`n4. View detailed statistics:" -ForegroundColor White
Write-Host "   Get-PredictorStatistics" -ForegroundColor Gray

Write-Host "`n💡 Troubleshooting:" -ForegroundColor Yellow
Write-Host "- If predictions don't work, check: Show-PredictorStatus" -ForegroundColor Gray
Write-Host "- If SSH tunnel fails, verify SSH key and network connectivity" -ForegroundColor Gray
Write-Host "- Enable debug mode: Set-PredictorConfiguration -EnableDebug" -ForegroundColor Gray

Write-Host "`n🎯 Your PowerAuger Predictor is ready to use!" -ForegroundColor Green