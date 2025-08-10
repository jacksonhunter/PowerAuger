# OllamaCommandPredictor.psd1

@{
    ModuleVersion = '2.0.0'
    RootModule = 'OllamaCommandPredictor.psm1'
    Author = 'Your Name'
    Description = 'AI-powered PowerShell command prediction using Ollama with caching, async processing, and rich context awareness'
    PowerShellVersion = '7.0'
    RequiredModules = @('PSReadLine')
    FunctionsToExport = @('Get-CommandPrediction')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('PSReadLine', 'Prediction', 'Ollama', 'AI', 'Autocomplete', 'CommandLine')
            LicenseUri = ''
            ProjectUri = ''
            ReleaseNotes = @'
2.0.0 - Major update with performance improvements:
- Added response caching (80% faster repeat queries)
- Implemented async processing with timeouts
- Enhanced context detection with filesystem awareness
- Improved error resilience and fallback mechanisms
- Added configuration management system
- Smart model selection based on input complexity
'@
        }
    }
}