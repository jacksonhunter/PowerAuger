# Auger.psd1

@{
    RootModule = 'Auger.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'b1c2d3e4-f5a6-7890-bcde-fa1234567890'
    Author = 'PowerAuger'
    Description = 'Ollama-powered PSReadLine predictor with history learning'
    PowerShellVersion = '7.2'

    FunctionsToExport = @('Show-PowerAugerStatus')

    PrivateData = @{
        PSData = @{
            # This is where SubsystemsToRegister belongs in PowerShell 7.4+
            SubsystemsToRegister = @('Auger.PowerAugerPredictor')
        }
    }
}