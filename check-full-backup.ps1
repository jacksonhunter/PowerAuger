# Force a save by importing the module
Import-Module ./PowerShellModule/PowerAuger.psd1 -Force

# Wait for async save
Start-Sleep -Seconds 2

# Check the backup
$jsonPath = "C:\Users\jacks\AppData\Local\PowerAuger\frecency.json"
$json = Get-Content $jsonPath | ConvertFrom-Json

Write-Host "JSON Backup Stats:" -ForegroundColor Cyan
Write-Host "  commandCount field: $($json.commandCount)" -ForegroundColor Yellow
Write-Host "  Actual commands in array: $($json.commands.Count)" -ForegroundColor Green
Write-Host "  Match: $($json.commandCount -eq $json.commands.Count)" -ForegroundColor Magenta

$fileInfo = Get-Item $jsonPath
Write-Host "  File size: $([math]::Round($fileInfo.Length / 1KB, 2)) KB" -ForegroundColor Blue

# Show some stats
$ranks = $json.commands | Select-Object -ExpandProperty Rank | Sort-Object -Descending
Write-Host "`nRank Distribution:" -ForegroundColor Cyan
Write-Host "  Commands with rank > 10: $(($ranks | Where-Object {$_ -gt 10}).Count)"
Write-Host "  Commands with rank > 5: $(($ranks | Where-Object {$_ -gt 5}).Count)"
Write-Host "  Commands with rank > 1: $(($ranks | Where-Object {$_ -gt 1}).Count)"
Write-Host "  Commands with rank = 1: $(($ranks | Where-Object {$_ -eq 1}).Count)"