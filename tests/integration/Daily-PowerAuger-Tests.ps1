# Daily-PowerAuger-Tests.ps1
# Daily testing scenarios to generate realistic tracking data
# Run these tasks daily to build meaningful metrics over time

Write-Host "📅 Daily PowerAuger Testing Scenarios" -ForegroundColor Cyan
Write-Host "Goal: Generate realistic usage patterns for tracking analysis" -ForegroundColor Gray
Write-Host "=" * 60

# Scenario 1: Morning Development Workflow
Write-Host "`n🌅 SCENARIO 1: Morning Development Workflow" -ForegroundColor Yellow
Write-Host "Simulate starting a development session" -ForegroundColor Gray

Write-Host "1. Check project status (type these partially, accept suggestions):"
Write-Host "   - Type 'git st' → accept 'git status'" -ForegroundColor Cyan
Write-Host "   - Type 'git br' → accept 'git branch'" -ForegroundColor Cyan
Write-Host "   - Type 'ls' → accept 'Get-ChildItem' if suggested" -ForegroundColor Cyan

Write-Host "`n2. Navigate project structure:"
Write-Host "   - Type 'cd mod' → accept path completion" -ForegroundColor Cyan
Write-Host "   - Type 'dir' → accept any completion" -ForegroundColor Cyan
Write-Host "   - Type 'cd ..' → accept completion" -ForegroundColor Cyan

# Scenario 2: PowerShell Module Development
Write-Host "`n🔧 SCENARIO 2: PowerShell Module Development" -ForegroundColor Yellow
Write-Host "Test module-related commands and completions" -ForegroundColor Gray

Write-Host "1. Module operations:"
Write-Host "   - Type 'Import-Mod' → accept 'Import-Module'" -ForegroundColor Cyan
Write-Host "   - Type 'Get-Comm' → accept 'Get-Command'" -ForegroundColor Cyan
Write-Host "   - Type 'Test-Mod' → accept 'Test-ModuleManifest'" -ForegroundColor Cyan

Write-Host "`n2. File operations:"
Write-Host "   - Type '.\setup' → accept script completion" -ForegroundColor Cyan
Write-Host "   - Type 'code .' → accept if suggested" -ForegroundColor Cyan

# Scenario 3: Git Workflow Testing
Write-Host "`n📚 SCENARIO 3: Git Workflow Testing" -ForegroundColor Yellow
Write-Host "Test git command predictions and context awareness" -ForegroundColor Gray

Write-Host "1. Git status and staging:"
Write-Host "   - Type 'git st' → accept 'git status'" -ForegroundColor Cyan
Write-Host "   - Type 'git add' → accept parameter suggestions" -ForegroundColor Cyan
Write-Host "   - Type 'git diff' → accept completion" -ForegroundColor Cyan

Write-Host "`n2. Git commit workflow:"
Write-Host "   - Type 'git comm' → accept 'git commit'" -ForegroundColor Cyan
Write-Host "   - Type 'git push' → accept completion" -ForegroundColor Cyan

# Scenario 4: System Administration
Write-Host "`n⚙️ SCENARIO 4: System Administration" -ForegroundColor Yellow
Write-Host "Test system cmdlets and admin tasks" -ForegroundColor Gray

Write-Host "1. Service management:"
Write-Host "   - Type 'Get-Serv' → accept 'Get-Service'" -ForegroundColor Cyan
Write-Host "   - Type 'Get-Proc' → accept 'Get-Process'" -ForegroundColor Cyan
Write-Host "   - Type 'Stop-Serv' → accept 'Stop-Service'" -ForegroundColor Cyan

Write-Host "`n2. File system operations:"
Write-Host "   - Type 'Get-Child' → accept 'Get-ChildItem'" -ForegroundColor Cyan
Write-Host "   - Type 'Set-Loc' → accept 'Set-Location'" -ForegroundColor Cyan

# Scenario 5: Context-Heavy Operations
Write-Host "`n🎯 SCENARIO 5: Context-Heavy Operations" -ForegroundColor Yellow
Write-Host "Test context awareness in different directories" -ForegroundColor Gray

Write-Host "1. Change to different directories and test predictions:"
Write-Host "   - cd C:\Windows\System32" -ForegroundColor Cyan
Write-Host "   - Type 'Get-' → should suggest system-relevant cmdlets" -ForegroundColor Cyan
Write-Host "   - cd back to project directory" -ForegroundColor Cyan
Write-Host "   - Type 'Get-' → should suggest dev-relevant cmdlets" -ForegroundColor Cyan

Write-Host "`n2. File type awareness:"
Write-Host "   - In .ps1 directory: Type 'Import-' or 'Test-'" -ForegroundColor Cyan
Write-Host "   - In git repo: Type 'git ' commands" -ForegroundColor Cyan

# Performance Testing
Write-Host "`n⚡ SCENARIO 6: Performance Stress Test" -ForegroundColor Yellow
Write-Host "Generate rapid predictions to test performance" -ForegroundColor Gray

Write-Host "1. Rapid fire completions (type quickly):"
Write-Host "   - Get-Ch, Get-Pr, Get-Se, Import-M, Test-P" -ForegroundColor Cyan
Write-Host "   - git st, git br, git lo, git pu, git co" -ForegroundColor Cyan

Write-Host "`n2. Pipeline completions:"
Write-Host "   - Type 'Get-Process | Where-Object' → accept suggestions" -ForegroundColor Cyan
Write-Host "   - Type 'Get-ChildItem | Sort-Object' → accept suggestions" -ForegroundColor Cyan

# Daily Tracking Tasks
Write-Host "`n📊 DAILY TRACKING TASKS" -ForegroundColor Magenta
Write-Host "=" * 30

Write-Host "`nAfter completing scenarios above, run these commands:"
Write-Host "1. Show-PredictorStatus -Detailed" -ForegroundColor Green
Write-Host "2. Export-PredictorMetrics -IncludeHistory" -ForegroundColor Green
Write-Host "3. Check acceptance rates for different models" -ForegroundColor Green

# Weekly Analysis Tasks
Write-Host "`n📈 WEEKLY ANALYSIS (Fridays)" -ForegroundColor Magenta
Write-Host "=" * 35

Write-Host "Compare metrics over time:"
Write-Host "1. Review exported metrics files" -ForegroundColor Yellow
Write-Host "2. Look for patterns in acceptance rates" -ForegroundColor Yellow
Write-Host "3. Identify which contexts improve predictions most" -ForegroundColor Yellow
Write-Host "4. Note any performance degradation" -ForegroundColor Yellow

# Specific Commands to Test
Write-Host "`n🎮 QUICK TEST COMMANDS" -ForegroundColor Magenta
Write-Host "Copy/paste these for immediate testing:" -ForegroundColor Gray
Write-Host @"

# Test basic completions
Get-Ch    # Should suggest Get-ChildItem
Import-M  # Should suggest Import-Module
git st    # Should suggest git status

# Test context awareness
cd C:\Windows\System32
Get-      # Note suggestions here
cd ~
Get-      # Compare suggestions

# Test model performance
Get-Process | Where-Object    # Context model test
dir                          # Fast model test

# Check results
Show-PredictorStatus -Detailed
"@ -ForegroundColor Cyan

Write-Host "`n✅ Daily testing guide ready!" -ForegroundColor Green
Write-Host "💡 Tip: Use Tab completion naturally and accept suggestions to build realistic data." -ForegroundColor Gray