# OllamaTunnelMonitor.psd1 - Module Manifest

@{
    # Script module or binary module file associated with this manifest
    RootModule = 'OllamaTunnelMonitor.psm1'
    
    # Version number of this module
    ModuleVersion = '1.0.0'
    
    # Supported PSEditions
    CompatiblePSEditions = @('Core')
    
    # ID used to uniquely identify this module
    GUID = '87654321-4321-4321-4321-123456789087'
    
    # Author of this module
    Author = 'PowerAuger Team'
    
    # Company or vendor of this module
    CompanyName = 'Unknown'
    
    # Copyright statement for this module
    Copyright = '(c) 2025 PowerAuger Team. All rights reserved.'
    
    # Description of the functionality provided by this module
    Description = 'Standalone SSH tunnel and Ollama server monitoring module with dashboard and headless monitoring capabilities. PowerAuger-aware but independently functional.'
    
    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '7.0'
    
    # Functions to export from this module
    FunctionsToExport = @(
        'Test-PortConnectivity',           # Core connectivity testing
        'Get-TunnelPortStatus',            # Detailed port status analysis
        'Get-OllamaServerStatus',          # Remote Ollama server monitoring
        'Get-SSHTunnelStatus',             # SSH tunnel process monitoring
        'Start-TunnelMonitor',             # Start monitoring daemon
        'Stop-TunnelMonitor',              # Stop monitoring daemon
        'Show-TunnelDashboard',            # Interactive dashboard
        'Get-TunnelMetrics',               # Performance metrics
        'Test-PowerAugerIntegration',      # Check PowerAuger compatibility
        'Import-PowerAugerConfig',         # Load PowerAuger configuration
        'Export-TunnelReport'              # Generate monitoring reports
    )
    
    # Cmdlets to export from this module
    CmdletsToExport = @()
    
    # Variables to export from this module
    VariablesToExport = @()
    
    # Aliases to export from this module
    AliasesToExport = @()
    
    # List of all files packaged with this module
    FileList = @('OllamaTunnelMonitor.psm1', 'OllamaTunnelMonitor.psd1')
    
    # Private data to pass to the module
    PrivateData = @{
        PSData = @{
            # Tags applied to this module
            Tags = @('SSH', 'Tunnel', 'Ollama', 'Monitoring', 'Dashboard', 'PowerAuger', 'Network', 'Socket', 'Headless')
            
            # ReleaseNotes of this module
            ReleaseNotes = @'
1.0.0 - Initial Release:
- Standalone SSH tunnel monitoring with .NET socket integration
- Real-time dashboard with tunnel and Ollama server status
- Headless monitoring daemon for background operation
- PowerAuger integration with configuration import/export
- Comprehensive network connectivity testing
- Windows-optimized process management
- Performance metrics and reporting
- Cross-platform compatibility (Windows focus)
'@
        }
    }
}