$predictorModuleSource = "C:\Users\jacks\experiments\VSCodeProjects\PowerShell\moduels\PowerAuger.psm1"

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

# Start with a clean screen
#Clear-Host

# Store the multi-line ASCII art in a "here-string"
f

# Get the escape character for building ANSI codes
$esc = [char]27

# Loop through each line and apply a color from the gradient
for ($i = 0; $i -lt $LineCount; $i++) {
    $colorIndex = [math]::Floor(($i / $LineCount) * $Gradient.Count)
    $hexColor = $Gradient[$colorIndex].TrimStart('#')
    
    $r = [System.Convert]::ToInt32($hexColor.Substring(0, 2), 16)
    $g = [System.Convert]::ToInt32($hexColor.Substring(2, 2), 16)
    $b = [System.Convert]::ToInt32($hexColor.Substring(4, 2), 16)
    
    $ansiColor = "$esc[38;2;${r};${g};${b}m"
    Write-Host "$ansiColor$($Lines[$i])"
}

Reset the color back to default when done


Write-Host "$esc[0m"
