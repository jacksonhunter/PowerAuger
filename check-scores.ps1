$data = Get-Content 'C:\Users\jacks\AppData\Local\PowerAuger\frecency.json' | ConvertFrom-Json
$ranks = $data.commands | Select-Object -ExpandProperty Rank | Sort-Object -Descending

Write-Host 'Score Distribution:' -ForegroundColor Cyan
Write-Host "Max Rank: $($ranks[0])" -ForegroundColor Green
Write-Host "Top 10 Ranks: $($ranks[0..9] -join ', ')" -ForegroundColor Yellow
Write-Host "Median Rank: $($ranks[[math]::Floor($ranks.Count/2)])" -ForegroundColor Blue
Write-Host "Min Rank: $($ranks[-1])" -ForegroundColor Magenta
Write-Host "Total Commands: $($ranks.Count)" -ForegroundColor White

# Show commands with rank > 10
$highFreq = $data.commands | Where-Object { $_.Rank -gt 10 } | Sort-Object -Property Rank -Descending

Write-Host "`nHigh frequency commands (rank > 10): $($highFreq.Count)" -ForegroundColor Cyan
$highFreq | Select-Object -First 20 | ForEach-Object {
    Write-Host "  $($_.Rank.ToString().PadLeft(3)): $($_.Command)" -ForegroundColor Gray
}