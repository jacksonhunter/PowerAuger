@{
    RootModule = 'PowerAuger.psm1'
    ModuleVersion = '2.0.0'
    GUID = 'b8c9d0e1-f2a3-4b5c-d6e7-f8a9b0c1d2e3'
    Author = 'PowerAuger Team'
    CompanyName = 'PowerAuger'
    Copyright = '(c) 2025 PowerAuger. All rights reserved.'
    Description = 'High-performance AI-powered PowerShell command predictor using AST-based completions with Ollama'
    PowerShellVersion = '7.2'

    # Files to include
    FileList = @(
        'PowerAuger.psm1',
        'bin\PowerAuger.dll'
    )

    # Functions to export
    FunctionsToExport = @(
        'Enable-PowerAuger',
        'Disable-PowerAuger',
        'Get-PowerAugerStatus'
    )

    # Cmdlets to export
    CmdletsToExport = @()

    # Variables to export
    VariablesToExport = @()

    # Aliases to export
    AliasesToExport = @()

    # Private data
    PrivateData = @{
        PSData = @{
            Tags = @('PSReadLine', 'Predictor', 'AI', 'Ollama', 'Completion', 'AST')
            LicenseUri = ''
            ProjectUri = ''
            ReleaseNotes = @'
Version 2.0.0 - AST-Based Architecture
- PowerShell pool for async completions
- AST-based CommandCompletion.CompleteInput integration
- Promise-based completion caching
- Multi-layer cache system (ultra-hot, hot, trie, prediction)
- Fire-and-forget async pattern
- Simplified architecture without complex threading
'@
            RequireLicenseAcceptance = $false

            # Register as predictor subsystem
            SubsystemsToRegister = @('PowerAuger.PowerAugerPredictor')
        }
    }
}
