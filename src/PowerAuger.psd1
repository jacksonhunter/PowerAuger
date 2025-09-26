# PowerAuger.psd1

@{
    RootModule = 'PowerAuger.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'b1c2d3e4-f5a6-7890-bcde-fa1234567890'
    Author = 'PowerAuger'
    Description = 'Ollama-powered PSReadLine predictor with contextual learning'
    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'Save-PowerAugerCache',
        'Import-PowerAugerCache',
        'Get-PowerAugerState',
        'Get-PowerAugerCat',
        'Set-PowerAugerPrompt',
        'Set-PowerAugerLogLevel',
        'Update-PowerAugerChannelMessages',
        'Update-PowerAugerFromChannel',
        'Reset-PowerAugerPrompt',
        'Add-PowerAugerHistory',
        'Get-PowerAugerStatus',
        'Stop-PowerAugerBackground'
    )

    PrivateData = @{
        PSData = @{
            # This is where SubsystemsToRegister belongs in PowerShell 7.4+
            SubsystemsToRegister = @('PowerAuger.PowerAugerPredictor')
        }
    }
}