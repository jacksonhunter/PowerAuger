# OllamaTunnelMonitor.psm1 - Standalone SSH Tunnel and Ollama Server Monitoring
# ========================================================================================================
# PRODUCTION-READY SSH TUNNEL MONITORING - PowerAuger Integration Compatible
# Headless daemon and interactive dashboard for SSH tunnel and Ollama server monitoring
# ========================================================================================================

#Requires -Version 7.0

# --------------------------------------------------------------------------------------------------------
# GLOBAL CONFIGURATION AND STATE
# --------------------------------------------------------------------------------------------------------

$script:TunnelMonitorConfig = @{
    # Target Configuration (can be imported from PowerAuger)
    Target = @{
        LocalPort     = 11434
        RemoteHost    = "localhost"  # Remote target (usually localhost via SSH)
        RemotePort    = 11434
        SSHHost       = $null        # Will be loaded from PowerAuger or set manually
        SSHUser       = $null
        SSHKey        = $null
        OllamaApiUrl  = "http://localhost:11434"
    }
    
    # Monitoring Configuration
    Monitoring = @{
        Enabled           = $false
        IntervalSeconds   = 30
        HealthCheckCount  = 3
        TimeoutMs         = 5000
        RetryAttempts     = 3
        EnableLogging     = $true
        LogPath           = $null     # Will be set in data directory
    }
    
    # Dashboard Configuration
    Dashboard = @{
        RefreshInterval   = 5         # seconds
        ShowDetailedStats = $true
        AutoScroll        = $true
        ColorTheme        = "Dark"    # Dark, Light, Auto
    }
    
    # PowerAuger Integration
    PowerAuger = @{
        Available         = $false
        ConfigImported    = $false
        SharedMetrics     = $false
    }
}

# Global state containers
$script:TunnelMetrics = @{
    StartTime           = $null
    TotalChecks         = 0
    SuccessfulChecks    = 0
    FailedChecks        = 0
    AverageLatency      = 0
    LastCheckTime       = $null
    CurrentStatus       = "Unknown"
    StatusHistory       = @()
    Uptime              = [TimeSpan]::Zero
}

$script:MonitoringJob = $null
$script:IsMonitoring = $false

# --------------------------------------------------------------------------------------------------------
# DATA PERSISTENCE AND CONFIGURATION
# --------------------------------------------------------------------------------------------------------

$script:TunnelMonitorDataPath = Join-Path -Path $env:USERPROFILE -ChildPath ".OllamaTunnelMonitor"
$script:TunnelMonitorConfigFile = Join-Path $script:TunnelMonitorDataPath "config.json"
$script:TunnelMonitorLogFile = Join-Path $script:TunnelMonitorDataPath "monitor.log"

function Initialize-TunnelMonitorData {
    if (-not (Test-Path $script:TunnelMonitorDataPath)) {
        New-Item -Path $script:TunnelMonitorDataPath -ItemType Directory -Force | Out-Null
    }
    $script:TunnelMonitorConfig.Monitoring.LogPath = $script:TunnelMonitorLogFile
}

function Save-TunnelMonitorConfig {
    [CmdletBinding()]
    param()
    
    try {
        Initialize-TunnelMonitorData
        $script:TunnelMonitorConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $script:TunnelMonitorConfigFile -Encoding UTF8
    }
    catch {
        Write-Warning "Failed to save TunnelMonitor configuration: $($_.Exception.Message)"
    }
}

function Load-TunnelMonitorConfig {
    [CmdletBinding()]
    param()
    
    if (Test-Path $script:TunnelMonitorConfigFile) {
        try {
            $loadedConfig = Get-Content -Path $script:TunnelMonitorConfigFile -Raw | ConvertFrom-Json -AsHashtable
            # Merge with defaults
            foreach ($key in $loadedConfig.Keys) {
                if ($script:TunnelMonitorConfig.ContainsKey($key)) {
                    foreach ($subKey in $loadedConfig[$key].Keys) {
                        $script:TunnelMonitorConfig[$key][$subKey] = $loadedConfig[$key][$subKey]
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to load TunnelMonitor configuration: $($_.Exception.Message)"
        }
    }
}

# --------------------------------------------------------------------------------------------------------
# CORE CONNECTIVITY TESTING (.NET Socket Integration)
# --------------------------------------------------------------------------------------------------------

function Test-PortConnectivity {
    [CmdletBinding()]
    param(
        [string]$HostName = "127.0.0.1",
        [int]$Port,
        [int]$TimeoutMs = 3000
    )
    
    try {
        # Use .NET TcpClient for more reliable port testing
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $connectTask = $tcpClient.ConnectAsync($HostName, $Port)
        
        # Wait for connection with timeout
        $completed = $connectTask.Wait($TimeoutMs)
        
        if ($completed -and $tcpClient.Connected) {
            $tcpClient.Close()
            return $true
        }
        else {
            $tcpClient.Close()
            return $false
        }
    }
    catch {
        return $false
    }
}

function Get-TunnelPortStatus {
    [CmdletBinding()]
    param(
        [int]$LocalPort = $script:TunnelMonitorConfig.Target.LocalPort
    )
    
    $startTime = Get-Date
    
    try {
        # Method 1: Check if port is listening using .NET
        $tcpConnections = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        $isListening = $tcpConnections | Where-Object { 
            $_.Port -eq $LocalPort -and 
            ($_.Address -eq [System.Net.IPAddress]::Loopback -or $_.Address -eq [System.Net.IPAddress]::Any)
        }
        
        # Method 2: Test actual connectivity
        $canConnect = Test-PortConnectivity -Port $LocalPort -TimeoutMs $script:TunnelMonitorConfig.Monitoring.TimeoutMs
        
        # Method 3: Find associated process (SSH tunnel)
        $tunnelProcess = Find-TunnelProcess -LocalPort $LocalPort
        
        $latencyMs = ((Get-Date) - $startTime).TotalMilliseconds
        
        $status = if ($isListening -and $canConnect) { "Healthy" } 
                 elseif ($isListening) { "Listening" }
                 elseif ($canConnect) { "Connected" }
                 else { "Unavailable" }
        
        return @{
            Port        = $LocalPort
            IsListening = $null -ne $isListening
            CanConnect  = $canConnect
            HasProcess  = $null -ne $tunnelProcess
            ProcessInfo = $tunnelProcess
            Status      = $status
            LatencyMs   = [math]::Round($latencyMs, 2)
            Timestamp   = Get-Date
        }
    }
    catch {
        return @{
            Port        = $LocalPort
            IsListening = $false
            CanConnect  = $false
            HasProcess  = $false
            ProcessInfo = $null
            Status      = "Error"
            LatencyMs   = -1
            Timestamp   = Get-Date
            Error       = $_.Exception.Message
        }
    }
}

function Find-TunnelProcess {
    [CmdletBinding()]
    param(
        [int]$LocalPort
    )
    
    try {
        # Use netstat to find process listening on port
        $netstatOutput = & cmd /c "netstat -ano" 2>$null
        
        foreach ($line in $netstatOutput) {
            if ($line -match "TCP\s+127\.0\.0\.1:$LocalPort\s+.*\s+LISTENING\s+(\d+)") {
                $pid = $matches[1]
                
                try {
                    $process = Get-Process -Id $pid -ErrorAction SilentlyContinue
                    if ($process) {
                        return @{
                            ProcessId   = $process.Id
                            ProcessName = $process.ProcessName
                            StartTime   = $process.StartTime
                            IsSSH       = $process.ProcessName -like "*ssh*"
                        }
                    }
                }
                catch {
                    # Process might have exited
                }
            }
        }
        return $null
    }
    catch {
        return $null
    }
}

# --------------------------------------------------------------------------------------------------------
# OLLAMA SERVER MONITORING
# --------------------------------------------------------------------------------------------------------

function Get-OllamaServerStatus {
    [CmdletBinding()]
    param(
        [string]$ApiUrl = $script:TunnelMonitorConfig.Target.OllamaApiUrl,
        [int]$TimeoutMs = $script:TunnelMonitorConfig.Monitoring.TimeoutMs
    )
    
    $startTime = Get-Date
    
    try {
        # Test basic connectivity first
        $portStatus = Get-TunnelPortStatus
        
        if ($portStatus.Status -ne "Healthy") {
            return @{
                Status      = "Unreachable"
                Error       = "Tunnel port not healthy: $($portStatus.Status)"
                LatencyMs   = -1
                Timestamp   = Get-Date
                TunnelInfo  = $portStatus
            }
        }
        
        # Test Ollama API endpoints
        $versionResponse = $null
        $modelsResponse = $null
        
        try {
            $versionResponse = Invoke-RestMethod -Uri "$ApiUrl/api/version" -Method Get -TimeoutSec ($TimeoutMs / 1000) -ErrorAction Stop
        }
        catch {
            $versionError = $_.Exception.Message
        }
        
        try {
            $modelsResponse = Invoke-RestMethod -Uri "$ApiUrl/api/tags" -Method Get -TimeoutSec ($TimeoutMs / 1000) -ErrorAction Stop
        }
        catch {
            $modelsError = $_.Exception.Message
        }
        
        $latencyMs = ((Get-Date) - $startTime).TotalMilliseconds
        
        if ($versionResponse -and $modelsResponse) {
            $status = "Healthy"
            $modelCount = if ($modelsResponse.models) { $modelsResponse.models.Count } else { 0 }
        }
        elseif ($versionResponse) {
            $status = "Partial"
        }
        else {
            $status = "Error"
        }
        
        return @{
            Status       = $status
            Version      = $versionResponse.version
            ModelCount   = $modelCount
            Models       = if ($modelsResponse.models) { $modelsResponse.models.name } else { @() }
            LatencyMs    = [math]::Round($latencyMs, 2)
            Timestamp    = Get-Date
            TunnelInfo   = $portStatus
            VersionError = $versionError
            ModelsError  = $modelsError
        }
    }
    catch {
        return @{
            Status      = "Error"
            Error       = $_.Exception.Message
            LatencyMs   = -1
            Timestamp   = Get-Date
            TunnelInfo  = $portStatus
        }
    }
}

# --------------------------------------------------------------------------------------------------------
# POWERAUGER INTEGRATION
# --------------------------------------------------------------------------------------------------------

function Test-PowerAugerIntegration {
    [CmdletBinding()]
    param()
    
    try {
        # Check if PowerAuger module is available
        $powerAugerModule = Get-Module -Name "PowerAuger" -ErrorAction SilentlyContinue
        
        if (-not $powerAugerModule) {
            $powerAugerModule = Get-Module -Name "PowerAuger" -ListAvailable -ErrorAction SilentlyContinue
        }
        
        $result = @{
            ModuleAvailable = $null -ne $powerAugerModule
            ModuleLoaded    = $null -ne (Get-Module -Name "PowerAuger")
            Version         = if ($powerAugerModule) { $powerAugerModule.Version } else { $null }
            ConfigAccess    = $false
            SharedState     = $false
        }
        
        # Test access to PowerAuger configuration
        if ($result.ModuleLoaded) {
            try {
                if (Get-Variable -Name "OllamaConfig" -Scope Global -ErrorAction SilentlyContinue) {
                    $result.ConfigAccess = $true
                    $result.SharedState = $true
                }
            }
            catch {
                # PowerAuger might not be initialized
            }
        }
        
        $script:TunnelMonitorConfig.PowerAuger.Available = $result.ModuleAvailable
        
        return $result
    }
    catch {
        return @{
            ModuleAvailable = $false
            ModuleLoaded    = $false
            Version         = $null
            ConfigAccess    = $false
            SharedState     = $false
            Error           = $_.Exception.Message
        }
    }
}

function Import-PowerAugerConfig {
    [CmdletBinding()]
    param()
    
    $integration = Test-PowerAugerIntegration
    
    if (-not $integration.ConfigAccess) {
        Write-Warning "PowerAuger configuration not accessible. Using standalone configuration."
        return $false
    }
    
    try {
        $powerAugerConfig = $global:OllamaConfig
        
        # Import relevant configuration
        $script:TunnelMonitorConfig.Target.LocalPort = $powerAugerConfig.Server.LocalPort
        $script:TunnelMonitorConfig.Target.SSHHost = $powerAugerConfig.Server.LinuxHost
        $script:TunnelMonitorConfig.Target.SSHUser = $powerAugerConfig.Server.SSHUser
        $script:TunnelMonitorConfig.Target.SSHKey = $powerAugerConfig.Server.SSHKey
        $script:TunnelMonitorConfig.Target.OllamaApiUrl = $powerAugerConfig.Server.ApiUrl
        
        $script:TunnelMonitorConfig.PowerAuger.ConfigImported = $true
        
        Write-Host "✅ PowerAuger configuration imported successfully" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to import PowerAuger configuration: $($_.Exception.Message)"
        return $false
    }
}

# --------------------------------------------------------------------------------------------------------
# MONITORING DAEMON
# --------------------------------------------------------------------------------------------------------

function Start-TunnelMonitor {
    [CmdletBinding()]
    param(
        [switch]$Headless,
        [int]$IntervalSeconds = $script:TunnelMonitorConfig.Monitoring.IntervalSeconds
    )
    
    if ($script:IsMonitoring) {
        Write-Warning "Tunnel monitor is already running"
        return
    }
    
    # Try to import PowerAuger configuration
    Import-PowerAugerConfig | Out-Null
    
    $script:TunnelMonitorConfig.Monitoring.IntervalSeconds = $IntervalSeconds
    $script:TunnelMetrics.StartTime = Get-Date
    
    if ($Headless) {
        # Start background monitoring job
        $script:MonitoringJob = Start-Job -ScriptBlock {
            param($config, $dataPath)
            
            # Import this module in the job context
            Import-Module "$using:PSScriptRoot\OllamaTunnelMonitor.psm1" -Force
            
            while ($true) {
                try {
                    $portStatus = Get-TunnelPortStatus -LocalPort $config.Target.LocalPort
                    $ollamaStatus = Get-OllamaServerStatus -ApiUrl $config.Target.OllamaApiUrl
                    
                    $logEntry = @{
                        Timestamp    = Get-Date
                        PortStatus   = $portStatus.Status
                        OllamaStatus = $ollamaStatus.Status
                        LatencyMs    = $ollamaStatus.LatencyMs
                    }
                    
                    # Log to file
                    if ($config.Monitoring.EnableLogging) {
                        $logLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Port: $($portStatus.Status), Ollama: $($ollamaStatus.Status), Latency: $($ollamaStatus.LatencyMs)ms"
                        Add-Content -Path $config.Monitoring.LogPath -Value $logLine -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    $errorLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - ERROR: $($_.Exception.Message)"
                    Add-Content -Path $config.Monitoring.LogPath -Value $errorLine -ErrorAction SilentlyContinue
                }
                
                Start-Sleep -Seconds $config.Monitoring.IntervalSeconds
            }
        } -ArgumentList $script:TunnelMonitorConfig, $script:TunnelMonitorDataPath
        
        $script:IsMonitoring = $true
        Write-Host "🚀 Tunnel monitor started in headless mode (Job ID: $($script:MonitoringJob.Id))" -ForegroundColor Green
    }
    else {
        # Start interactive dashboard
        Show-TunnelDashboard
    }
}

function Stop-TunnelMonitor {
    [CmdletBinding()]
    param()
    
    if ($script:MonitoringJob) {
        Stop-Job -Job $script:MonitoringJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:MonitoringJob -ErrorAction SilentlyContinue
        $script:MonitoringJob = $null
    }
    
    $script:IsMonitoring = $false
    Write-Host "🛑 Tunnel monitor stopped" -ForegroundColor Yellow
}

# --------------------------------------------------------------------------------------------------------
# INTERACTIVE DASHBOARD
# --------------------------------------------------------------------------------------------------------

function Show-TunnelDashboard {
    [CmdletBinding()]
    param(
        [int]$RefreshInterval = $script:TunnelMonitorConfig.Dashboard.RefreshInterval
    )
    
    Write-Host "🔍 Ollama Tunnel Monitor Dashboard" -ForegroundColor Cyan
    Write-Host "Press 'q' to quit, 'r' to refresh, 'p' to toggle PowerAuger info" -ForegroundColor Gray
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
    
    $showPowerAuger = $false
    $script:IsMonitoring = $true
    
    try {
        while ($script:IsMonitoring) {
            Clear-Host
            
            # Header
            Write-Host "🔍 Ollama Tunnel Monitor Dashboard - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
            Write-Host "Press 'q' to quit, 'r' to refresh, 'p' to toggle PowerAuger info" -ForegroundColor Gray
            Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
            
            # Configuration Info
            Write-Host "`n📋 Configuration:" -ForegroundColor White
            Write-Host "   Local Port: $($script:TunnelMonitorConfig.Target.LocalPort)" -ForegroundColor Gray
            Write-Host "   SSH Target: $($script:TunnelMonitorConfig.Target.SSHUser)@$($script:TunnelMonitorConfig.Target.SSHHost)" -ForegroundColor Gray
            Write-Host "   API URL: $($script:TunnelMonitorConfig.Target.OllamaApiUrl)" -ForegroundColor Gray
            
            # Port Status
            $portStatus = Get-TunnelPortStatus
            Write-Host "`n🔌 Tunnel Port Status:" -ForegroundColor White
            $statusColor = switch ($portStatus.Status) {
                "Healthy" { "Green" }
                "Listening" { "Yellow" }
                "Connected" { "Cyan" }
                default { "Red" }
            }
            Write-Host "   Status: $($portStatus.Status)" -ForegroundColor $statusColor
            Write-Host "   Port: $($portStatus.Port) | Listening: $($portStatus.IsListening) | Can Connect: $($portStatus.CanConnect)" -ForegroundColor Gray
            if ($portStatus.ProcessInfo) {
                Write-Host "   Process: $($portStatus.ProcessInfo.ProcessName) (PID: $($portStatus.ProcessInfo.ProcessId))" -ForegroundColor Gray
            }
            Write-Host "   Latency: $($portStatus.LatencyMs)ms" -ForegroundColor Gray
            
            # Ollama Server Status
            $ollamaStatus = Get-OllamaServerStatus
            Write-Host "`n🤖 Ollama Server Status:" -ForegroundColor White
            $ollamaColor = switch ($ollamaStatus.Status) {
                "Healthy" { "Green" }
                "Partial" { "Yellow" }
                default { "Red" }
            }
            Write-Host "   Status: $($ollamaStatus.Status)" -ForegroundColor $ollamaColor
            if ($ollamaStatus.Version) {
                Write-Host "   Version: $($ollamaStatus.Version)" -ForegroundColor Gray
            }
            if ($ollamaStatus.ModelCount -ge 0) {
                Write-Host "   Models: $($ollamaStatus.ModelCount) available" -ForegroundColor Gray
            }
            Write-Host "   API Latency: $($ollamaStatus.LatencyMs)ms" -ForegroundColor Gray
            
            # PowerAuger Integration (if toggled)
            if ($showPowerAuger) {
                $integration = Test-PowerAugerIntegration
                Write-Host "`n🔗 PowerAuger Integration:" -ForegroundColor White
                Write-Host "   Module Available: $($integration.ModuleAvailable)" -ForegroundColor Gray
                Write-Host "   Module Loaded: $($integration.ModuleLoaded)" -ForegroundColor Gray
                Write-Host "   Config Access: $($integration.ConfigAccess)" -ForegroundColor Gray
                if ($integration.Version) {
                    Write-Host "   Version: $($integration.Version)" -ForegroundColor Gray
                }
            }
            
            Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Gray
            
            # Check for user input
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.KeyChar) {
                    'q' { $script:IsMonitoring = $false }
                    'r' { continue }
                    'p' { $showPowerAuger = -not $showPowerAuger }
                }
            }
            
            if ($script:IsMonitoring) {
                Start-Sleep -Seconds $RefreshInterval
            }
        }
    }
    finally {
        $script:IsMonitoring = $false
    }
}

# --------------------------------------------------------------------------------------------------------
# METRICS AND REPORTING
# --------------------------------------------------------------------------------------------------------

function Get-TunnelMetrics {
    [CmdletBinding()]
    param()
    
    return $script:TunnelMetrics
}

function Export-TunnelReport {
    [CmdletBinding()]
    param(
        [string]$OutputPath = (Join-Path $script:TunnelMonitorDataPath "tunnel_report_$(Get-Date -Format 'yyyyMMdd_HHmmss').json")
    )
    
    $report = @{
        GeneratedAt    = Get-Date
        Configuration  = $script:TunnelMonitorConfig
        CurrentStatus  = @{
            Port   = Get-TunnelPortStatus
            Ollama = Get-OllamaServerStatus
        }
        Metrics        = $script:TunnelMetrics
        PowerAuger     = Test-PowerAugerIntegration
    }
    
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Host "📄 Report exported to: $OutputPath" -ForegroundColor Green
    return $OutputPath
}

# --------------------------------------------------------------------------------------------------------
# MODULE INITIALIZATION
# --------------------------------------------------------------------------------------------------------

function Get-SSHTunnelStatus {
    [CmdletBinding()]
    param()
    
    $portStatus = Get-TunnelPortStatus
    $ollamaStatus = Get-OllamaServerStatus
    
    return @{
        Overall     = if ($portStatus.Status -eq "Healthy" -and $ollamaStatus.Status -eq "Healthy") { "Operational" } else { "Issues" }
        Port        = $portStatus
        Ollama      = $ollamaStatus
        LastChecked = Get-Date
    }
}

# Initialize module
Initialize-TunnelMonitorData
Load-TunnelMonitorConfig

# Export functions
Export-ModuleMember -Function @(
    'Test-PortConnectivity',
    'Get-TunnelPortStatus',
    'Get-OllamaServerStatus',
    'Get-SSHTunnelStatus',
    'Start-TunnelMonitor',
    'Stop-TunnelMonitor',
    'Show-TunnelDashboard',
    'Get-TunnelMetrics',
    'Test-PowerAugerIntegration',
    'Import-PowerAugerConfig',
    'Export-TunnelReport'
)

Write-Host "🔍 OllamaTunnelMonitor module loaded" -ForegroundColor Green