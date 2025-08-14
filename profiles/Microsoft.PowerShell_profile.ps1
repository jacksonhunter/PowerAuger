$predictorModuleSource = "C:\Users\jacks\experiments\VSCodeProjects\PowerShell\moduels\PowerAuger.psd1"

# ====================================================================================================
# NIGHTDRIVE - SYNTHWAVE TERMINAL (FINAL v2)
# ====================================================================================================

# The "Nightdrive" theme palette, inspired by your images
$Theme = @{
    Primary   = '#F92672' # Neon Pink
    Secondary = '#66D9EF' # Electric Cyan
    Accent    = '#E6DB74' # Glowing Yellow
    Text      = '#F8F8F2' # Clean Off-white
    Success   = '#A6E22E' # Lime Green
    Error     = '#FD971F' # Sunset Orange
    Info      = '#AE81FF' # Rich Purple
    Muted     = '#401A4C' # Deep Indigo
}

# --- Configuration for Command OUTPUT (e.g., Get-ChildItem) ---
# This helper function is only needed for the $PSStyle settings below.
function Convert-HexToPsStyleColor {
    param([string]$HexColor)
    $hex = $HexColor.TrimStart('#')
    $r = [System.Convert]::ToInt32($hex.Substring(0, 2), 16)
    $g = [System.Convert]::ToInt32($hex.Substring(2, 2), 16)
    $b = [System.Convert]::ToInt32($hex.Substring(4, 2), 16)
    return $PSStyle.Foreground.FromRgb($r, $g, $b)
}
$PSStyle.Formatting.FormatAccent = Convert-HexToPsStyleColor -HexColor $Theme.Primary
$PSStyle.Formatting.TableHeader = Convert-HexToPsStyleColor -HexColor $Theme.Secondary
$PSStyle.Progress.Style = Convert-HexToPsStyleColor -HexColor $Theme.Primary

# --- Configuration for Interactive INPUT (Syntax Highlighting) ---
# Create a hashtable of colors using the correct PSReadLine color property names
$PSReadLineColors = @{
    Command                = $Theme.Secondary
    Comment                = $Theme.Muted
    ContinuationPrompt     = $Theme.Accent
    Default                = $Theme.Text
    Emphasis               = $Theme.Secondary
    Error                  = $Theme.Error
    Keyword                = $Theme.Primary
    Member                 = $Theme.Text
    Number                 = '#87CEEB' # Unique Sky Blue
    Operator               = $Theme.Info
    Parameter              = $Theme.Accent
    String                 = $Theme.Success
    Type                   = $Theme.Secondary
    Variable               = $Theme.Info
    # Prediction colors (new in PSReadLine 2.2+)
    InlinePrediction       = $Theme.Muted
    ListPrediction         = $Theme.Text
    ListPredictionSelected = $Theme.Primary
}

# Apply the colors using the -Colors parameter
Set-PSReadLineOption -Colors $PSReadLineColors

#load ASCII art
Get-Content -Path "$HOME\Documents\powershell_splash.txt" | Write-Host

# Get the escape character for building ANSI codes
$esc = [char]27

Write-Host "$esc[0m"
# Import module (if not auto-loading)
Import-Module $predictorModuleSource

# Enable predictions
Set-PSReadLineOption -PredictionSource HistoryAndPlugin