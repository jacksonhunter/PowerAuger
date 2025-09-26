# build.ps1 - Build script for PowerAugerSharp

param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',

    [switch]$Clean,
    [switch]$Test,
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

# Paths
$projectRoot = $PSScriptRoot
$projectFile = Join-Path $projectRoot "PowerAugerSharp.csproj"
$outputDir = Join-Path $projectRoot "bin\$Configuration\net8.0"
$moduleDir = Join-Path $projectRoot "PowerShellModule"
$moduleBinDir = Join-Path $moduleDir "bin"

Write-Host "PowerAugerSharp Build Script" -ForegroundColor Cyan
Write-Host "============================" -ForegroundColor Cyan
Write-Host ""

# Clean if requested
if ($Clean) {
    Write-Host "Cleaning previous build..." -ForegroundColor Yellow
    if (Test-Path $outputDir) {
        Remove-Item $outputDir -Recurse -Force
    }
    if (Test-Path $moduleBinDir) {
        Remove-Item $moduleBinDir -Recurse -Force
    }
    dotnet clean $projectFile --configuration $Configuration
}

# Build the project
Write-Host "Building PowerAugerSharp ($Configuration)..." -ForegroundColor Green
try {
    dotnet build $projectFile --configuration $Configuration
    if ($LASTEXITCODE -ne 0) {
        throw "Build failed with exit code $LASTEXITCODE"
    }
}
catch {
    Write-Error "Build failed: $_"
    exit 1
}

# Copy built assembly to module directory
Write-Host "Copying assembly to module directory..." -ForegroundColor Green
if (-not (Test-Path $moduleBinDir)) {
    New-Item -ItemType Directory -Path $moduleBinDir -Force | Out-Null
}

$assemblyPath = Join-Path $outputDir "PowerAugerSharp.dll"
if (Test-Path $assemblyPath) {
    Copy-Item $assemblyPath -Destination $moduleBinDir -Force
    Write-Host "Assembly copied to: $moduleBinDir" -ForegroundColor Green
}
else {
    Write-Error "Assembly not found at: $assemblyPath"
    exit 1
}

# Run tests if requested
if ($Test) {
    Write-Host ""
    Write-Host "Running tests..." -ForegroundColor Yellow
    & (Join-Path $projectRoot "test.ps1")
}

# Install module if requested
if ($Install) {
    Write-Host ""
    Write-Host "Installing PowerAugerSharp module..." -ForegroundColor Yellow

    $userModulePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "PowerShell\Modules\PowerAugerSharp"

    if (Test-Path $userModulePath) {
        Write-Host "Removing existing module installation..." -ForegroundColor Yellow
        Remove-Item $userModulePath -Recurse -Force
    }

    Write-Host "Copying module to: $userModulePath" -ForegroundColor Green
    Copy-Item $moduleDir -Destination $userModulePath -Recurse -Force

    Write-Host ""
    Write-Host "Module installed successfully!" -ForegroundColor Green
    Write-Host "To use PowerAugerSharp, run:" -ForegroundColor Cyan
    Write-Host "  Import-Module PowerAugerSharp" -ForegroundColor White
    Write-Host "  Enable-PowerAugerSharp" -ForegroundColor White
}

Write-Host ""
Write-Host "Build completed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "1. Ensure Ollama is running: ollama serve" -ForegroundColor White
Write-Host "2. Ensure the autocomplete model exists: ollama pull qwen2.5:0.5b" -ForegroundColor White
Write-Host "3. Import the module: Import-Module $moduleDir\PowerAugerSharp.psd1" -ForegroundColor White
Write-Host "4. Enable the predictor: Enable-PowerAugerSharp" -ForegroundColor White