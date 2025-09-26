@{
    RootModule = 'PowerAugerSharp.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'b8c9d0e1-f2a3-4b5c-d6e7-f8a9b0c1d2e3'
    Author = 'PowerAugerSharp'
    CompanyName = 'PowerAugerSharp'
    Copyright = '(c) 2025 PowerAugerSharp. All rights reserved.'
    Description = 'High-performance AI-powered command predictor for PowerShell using C# and Ollama'
    PowerShellVersion = '7.2'

    # Files to include
    FileList = @(
        'PowerAugerSharp.psm1',
        'bin\PowerAugerSharp.dll'
    )

    # Functions to export
    FunctionsToExport = @(
        'Enable-PowerAugerSharp',
        'Disable-PowerAugerSharp',
        'Get-PowerAugerSharpStatus',
        'Set-PowerAugerSharpLogLevel'
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
            Tags = @('PSReadLine', 'Predictor', 'AI', 'Ollama', 'Completion')
            LicenseUri = ''
            ProjectUri = ''
            ReleaseNotes = 'Initial release of PowerAugerSharp - C# implementation of PowerAuger'
            RequireLicenseAcceptance = $false

            # Register as predictor subsystem
            SubsystemsToRegister = @('PowerAugerSharp.PowerAugerPredictor')
        }
    }
}