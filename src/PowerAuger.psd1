# PowerAuger.psd1 - Module Manifest

@{
    # Script module or binary module file associated with this manifest
    RootModule = 'PowerAuger.psm1'
    
    # Version number of this module
    ModuleVersion = '3.4.0'
    
    # Supported PSEditions
    CompatiblePSEditions = @('Core')
    
    # ID used to uniquely identify this module
    GUID                 = '12345678-1234-1234-1234-123456789012'
    
    # Author of this module
    Author               = 'PowerAuger Team'
    
    # Company or vendor of this module
    CompanyName          = 'Unknown'
    
    # Copyright statement for this module
    Copyright            = '(c) 2025 PowerAuger Team. All rights reserved.'
    
    # Description of the functionality provided by this module
    Description          = 'Production-ready Ollama PowerShell Predictor with JSON-first API, intelligent caching, SSH tunnel management, and advanced context awareness for PSReadLine integration.'
    
    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion    = '7.0'
    
    # Name of the PowerShell host required by this module
    # PowerShellHostName = ''
    
    # Minimum version of the PowerShell host required by this module
    # PowerShellHostVersion = ''
    
    # Minimum version of Microsoft .NET Framework required by this module
    # DotNetFrameworkVersion = ''
    
    # Minimum version of the common language runtime (CLR) required by this module
    # ClrVersion = ''
    
    # Processor architecture (None, X86, Amd64) required by this module
    # ProcessorArchitecture = ''
    
    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules      = @('PSReadLine')
    
    # Assemblies that must be loaded prior to importing this module
    # RequiredAssemblies = @()
    
    # Script files (.ps1) that are run in the caller's environment prior to importing this module
    # ScriptsToProcess = @()
    
    # Type files (.ps1xml) to be loaded when importing this module
    # TypesToProcess = @()
    
    # Format files (.ps1xml) to be loaded when importing this module
    # FormatsToProcess = @()
    
    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
    # NestedModules = @()
    
    # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export
    FunctionsToExport    = @(
        'Get-CommandPrediction',           # Main PSReadLine predictor function
        'Initialize-OllamaPredictor',      # Setup and initialization
        'Set-PredictorConfiguration',      # Configuration management
        'Start-OllamaTunnel',             # SSH tunnel management
        'Stop-OllamaTunnel',              # SSH tunnel management
        'Test-OllamaConnection',          # Connection testing
        'Show-PredictorStatus',           # Status display
        'Get-PredictorStatistics',        # Performance metrics
        'Get-PredictionLog',              # NEW: Prediction logging for troubleshooting
        'Save-PowerAugerState',           # NEW: State persistence for setup script
        'Clear-PowerAugerCache'           # NEW: Diagnostic function to clear the cache
    )
    
    # Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export
    CmdletsToExport      = @()
    
    # Variables to export from this module
    VariablesToExport    = @()
    
    # Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export
    AliasesToExport      = @()
    
    # DSC resources to export from this module
    # DscResourcesToExport = @()
    
    # List of all modules packaged with this module
    # ModuleList = @()
    
    # List of all files packaged with this module
    FileList             = @('PowerAuger.psm1', 'PowerAuger.psd1', 'setup.ps1')
    
    # Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
    PrivateData          = @{
        PSData = @{
            # Tags applied to this module. These help with module discovery in online galleries
            Tags         = @('PSReadLine', 'Prediction', 'Ollama', 'AI', 'Autocomplete', 'CommandLine', 'SSH', 'JSON', 'Cache', 'Context')
            
            # A URL to the license for this module
            LicenseUri   = ''
            
            # A URL to the main website for this project
            ProjectUri   = ''
            
            # A URL to an icon representing this module
            # IconUri = ''
            
            # ReleaseNotes of this module
            ReleaseNotes = @'
3.4.0 - Advanced Metrics & Reliability Release:
- NEW: Implemented Acceptance Rate tracking to measure how often suggestions are used.
- NEW: Implemented Error Rate tracking for accepted suggestions to measure model reliability.
- ENHANCED: `Show-PredictorStatus` now displays detailed acceptance and error rates per model.
- FIXED: Updated `Benchmark-PowerAuger.ps1` to work with the new advanced metrics.
- FIXED: Hardened `setup.ps1` with updated fallback logic for improved resilience.

3.3.0 - Diagnostics & Usability Release:
- NEW: Added `Clear-PowerAugerCache` function to manually clear the prediction cache.
- ENHANCED: `Show-PredictorStatus` now displays the currently configured model names for easier diagnostics.

3.2.0 - State Persistence & Setup Script Release:
- NEW: Interactive `setup.ps1` script for guided installation and configuration.
- NEW: Configuration is now loaded from `~/.PowerAuger/config.json`.
- NEW: Module state (history, cache, targets, log) is persisted to JSON files in `~/.PowerAuge`r.
- ENHANCED: Context engine refactored into a modular, extensible provider-based architecture.

3.1.0 - Custom Model Compatibility Release:
- FIXED: Native support for custom Ollama model templates
- FIXED: Proper prompt formats for fast vs context models  
- FIXED: Line-separated text parsing (removed JSON requirement)
- FIXED: Model-specific parameter usage (temperature, top_p)
- FIXED: 30-second timeouts for larger custom models
- FIXED: Removed problematic PSConsoleReadLine.Invalidate() calls
- ENHANCED: Model-aware prompt building
- ENHANCED: Contextual prompt formatting for powershell-context model
- TESTED: Works with custom powershell-fast and powershell-context models

3.0.0 - Production-ready PowerAuger release:
- Complete rewrite with production-grade architecture
- SSH tunnel management for secure remote Ollama connections
- JSON-first API design with structured responses
- Intelligent model selection (fast vs context-aware)
- Advanced context engine with environment awareness
- Performance monitoring and diagnostics
- Intelligent caching system with TTL and size management
- Fallback prediction system for offline scenarios
- Continue-compatible cross-platform design
- Enhanced error handling and resilience
- Configuration persistence and management
- Real-time performance metrics
- Git, file system, and environment context integration
'@
            
            # Prerelease string of this module
            # Prerelease = ''
            
            # Flag to indicate whether the module requires explicit user acceptance for install/update/save
            # RequireLicenseAcceptance = $false
            
            # External dependent modules of this module
            # ExternalModuleDependencies = @()
        } # End of PSData hashtable
    } # End of PrivateData hashtable
    
    # HelpInfo URI of this module
    # HelpInfoURI = ''
    
    # Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix
    # DefaultCommandPrefix = ''
}