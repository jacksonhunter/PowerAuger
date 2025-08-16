# ========================================================================================================
# NEW-CONTINUECONFIGURATION.PS1
# Generate Continue IDE configuration for PowerContinue project
# Supports existing PowerShell and Python JSON models
# ========================================================================================================

function New-ContinueConfiguration {
    <#
    .SYNOPSIS
    Generates Continue IDE configuration for PowerContinue models
    
    .DESCRIPTION
    Creates a complete Continue IDE config.yaml file that integrates with PowerContinue
    Ollama models. Based on existing user configuration with enhanced PowerShell/Python 
    models, comprehensive context providers, and proper role assignments.
    
    .PARAMETER OllamaEndpoint
    The Ollama server endpoint URL. Default: http://localhost:11434
    
    .PARAMETER IncludePython
    Include Python models in the configuration. Default: $true
    
    .PARAMETER IncludeReranker
    Include a reranker model for improved context retrieval. Default: $true
    
    .PARAMETER CreateSlashCommands
    Create .prompt files for custom PowerShell slash commands. Default: $true
    
    
    .PARAMETER ModelVersion
    Version tag for PowerContinue models. Default: v1.0
    
    .PARAMETER IncludeMorphApply
    Include Morph v3 apply model with API key. Default: $true
    
    .PARAMETER MorphApiKey
    API key for Morph v3 apply model. If not provided, will prompt for input
    
    .PARAMETER OutputPath
    Path to save the generated config.yaml file. If not specified, returns the YAML string.
    
    .EXAMPLE
    New-ContinueConfiguration
    
    .EXAMPLE
    New-ContinueConfiguration -OllamaEndpoint "http://localhost:11434" -OutputPath "~/.continue/config.yaml"
    
    .EXAMPLE
    $config = New-ContinueConfiguration -IncludePython $false -ModelVersion "v2.0"
    #>
    
    param(
        [string]$OllamaEndpoint = "http://localhost:11434",
        [bool]$IncludePython = $true,
        [bool]$IncludeReranker = $true,
        [bool]$CreateSlashCommands = $true,
        [string]$ModelVersion = "v1.0",
        [bool]$IncludeMorphApply = $true,
        [string]$MorphApiKey = $null,
        [string]$OutputPath = $null
    )
    
    Write-Host "🎯 Generating Continue IDE configuration (YAML format)..." -ForegroundColor Cyan
    Write-Host "📡 Ollama Endpoint: $OllamaEndpoint" -ForegroundColor Gray
    Write-Host "🏷️  Model Version: $ModelVersion" -ForegroundColor Gray
    
    # PowerContinue specialized models - Natural text optimized for Continue IDE
    $models = @(
        @{
            name            = "PowerShell Completion"
            provider        = "ollama"
            model           = "powershell-completion:$ModelVersion"
            apiBase         = $OllamaEndpoint
            roles           = @("autocomplete")
            capabilities    = @("tool_use")
            promptTemplates = @{
                autocomplete = "<|fim_prefix|>{{{prefix}}}<|fim_suffix|>{{{suffix}}}<|fim_middle|>"
            }
        },
        @{
            name         = "PowerShell Chat"
            provider     = "ollama"
            model        = "powershell-chat:$ModelVersion"
            apiBase      = $OllamaEndpoint
            roles        = @("chat", "edit")
            capabilities = @("tool_use")
        }
    )
    
    # Add Python models if requested
    if ($IncludePython) {
        $pythonModels = @(
            @{
                name            = "Python Completion"
                provider        = "ollama"
                model           = "python-completion:$ModelVersion"
                apiBase         = $OllamaEndpoint
                roles           = @("autocomplete")
                capabilities    = @("tool_use")
                promptTemplates = @{
                    autocomplete = "<|fim_prefix|>{{{prefix}}}<|fim_suffix|>{{{suffix}}}<|fim_middle|>"
                }
            },
            @{
                name         = "Python Chat"
                provider     = "ollama"
                model        = "python-chat:$ModelVersion"
                apiBase      = $OllamaEndpoint
                roles        = @("chat", "edit")
                capabilities = @("tool_use")
            }
        )
        $models += $pythonModels
    }
    
    # Add Morph apply model if requested
    if ($IncludeMorphApply) {
        if (-not $MorphApiKey) {
            $MorphApiKey = Read-Host -Prompt "Enter Morph API Key" -AsSecureString
            $MorphApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($MorphApiKey))
        }
        
        $morphModel = @{
            name                     = "Morph Fast Apply"
            provider                 = "openai"
            model                    = "morph-v3-large"
            apiKey                   = $MorphApiKey
            apiBase                  = "https://api.morphllm.com/v1/"
            roles                    = @("apply")
            promptTemplates          = @{
                apply = "<code>{{{ original_code }}}</code>`n<update>{{{ new_code }}}</update>"
            }
            defaultCompletionOptions = @{
                maxTokens   = 16000
                temperature = 0
            }
        }
        $models += $morphModel
        Write-Host "✅ Added Morph v3 apply model" -ForegroundColor Green
    }

    # Add reranker model if requested
    if ($IncludeReranker) {
        $rerankerModel = @{
            name     = "Qwen3 Reranker"
            provider = "ollama"
            model    = "auditaid/qwen3_reranker:0.6b_fp16"
            apiBase  = $OllamaEndpoint
            roles    = @("rerank")
        }
        $models += $rerankerModel
        Write-Host "✅ Added Qwen3 Reranker model for context optimization" -ForegroundColor Green
    }
    

    
    # Context providers (based on user's proven configuration)
    $contextProviders = @(
        @{ provider = "file" },
        @{ provider = "currentFile" },
        @{ provider = "code" },
        @{ provider = "docs" },
        @{ provider = "diff" },
        @{
            provider = "web"
            params   = @{ n = 5 }
        },
        @{ provider = "search" },
        @{ provider = "terminal" },
        @{ provider = "problems" },
        @{ provider = "folder" },
        @{ provider = "codebase" },
        @{ provider = "clipboard" },
        @{ provider = "url" },
        @{
            provider = "open"
            params   = @{ onlyPinned = $true }
        },
        @{ provider = "tree" },
        @{
            provider = "debugger"
            params   = @{ stackDepth = 3 }
        },
        @{
            provider = "terminal"
            params   = @{ commandHistory = 10 }
        },
        @{
            provider = "repo-map"
            params   = @{ includeSignatures = $true }
        },
        @{ provider = "os" }
    )
    
    # Documentation sources
    $docs = @(
        @{
            name     = "Powershell"
            startUrl = "https://learn.microsoft.com/en-us/powershell/"
        },
        @{
            name       = "Continue"
            faviconUrl = ""
            startUrl   = "https://docs.continue.dev/"
        }
    )
    
    if ($IncludePython) {
        $docs += @{
            name     = "Python"
            startUrl = "https://docs.python.org/"
        }
    }
    
    # Build the complete YAML-compatible configuration
    $continueConfig = @{
        name    = "PowerContinue Assistant"
        version = "1.0.0"
        schema  = "v1"
        models  = $models
        context = $contextProviders
        docs    = $docs
    }
    
    # Convert to YAML-like format (PowerShell doesn't have native YAML, so we'll format as structured text)
    $yamlConfig = @"
name: PowerContinue Assistant
version: 1.0.0
schema: v1
models:
"@

    foreach ($model in $models) {
        $yamlConfig += "`n  - name: $($model.name)"
        $yamlConfig += "`n    provider: $($model.provider)"
        $yamlConfig += "`n    model: $($model.model)"
        if ($model.apiKey) {
            $yamlConfig += "`n    apiKey: $($model.apiKey)"
        }
        $yamlConfig += "`n    apiBase: $($model.apiBase)"
        $yamlConfig += "`n    roles:"
        foreach ($role in $model.roles) {
            $yamlConfig += "`n      - $role"
        }
        if ($model.capabilities) {
            $yamlConfig += "`n    capabilities:"
            foreach ($capability in $model.capabilities) {
                $yamlConfig += "`n      - $capability"
            }
        }
        if ($model.promptTemplates) {
            $yamlConfig += "`n    promptTemplates:"
            foreach ($template in $model.promptTemplates.GetEnumerator()) {
                $yamlConfig += "`n      $($template.Key): |-"
                $yamlConfig += "`n        $($template.Value)"
            }
        }
        if ($model.defaultCompletionOptions) {
            $yamlConfig += "`n    defaultCompletionOptions:"
            foreach ($option in $model.defaultCompletionOptions.GetEnumerator()) {
                $yamlConfig += "`n      $($option.Key): $($option.Value)"
            }
        }
    }

    $yamlConfig += "`ncontext:"
    foreach ($context in $contextProviders) {
        $yamlConfig += "`n  - provider: $($context.provider)"
        if ($context.params) {
            $yamlConfig += "`n    params:"
            foreach ($param in $context.params.GetEnumerator()) {
                if ($param.Value -is [array]) {
                    $yamlConfig += "`n      $($param.Key):"
                    foreach ($item in $param.Value) {
                        $yamlConfig += "`n        - $item"
                    }
                }
                else {
                    $yamlConfig += "`n      $($param.Key): $($param.Value)"
                }
            }
        }
    }

    $yamlConfig += "`ndocs:"
    foreach ($doc in $docs) {
        $yamlConfig += "`n  - name: $($doc.name)"
        if ($doc.faviconUrl) {
            $yamlConfig += "`n    faviconUrl: `"$($doc.faviconUrl)`""
        }
        $yamlConfig += "`n    startUrl: $($doc.startUrl)"
    }
    
    # Save to file if path specified
    if ($OutputPath) {
        try {
            # Ensure directory exists
            $directory = Split-Path $OutputPath -Parent
            if ($directory -and -not (Test-Path $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            
            $yamlConfig | Set-Content -Path $OutputPath -Encoding UTF8
            Write-Host "✅ Continue configuration saved to: $OutputPath" -ForegroundColor Green

            # Create slash commands as individual .prompt files (modern approach)
            if ($CreateSlashCommands) {
                $slashCommands = @(
                    @{
                        name        = "ps-explain"
                        description = "Explain the selected PowerShell code"
                        prompt      = 'Explain the following PowerShell code snippet. Provide a clear, concise explanation of what it does, its parameters, and an example of how to use it. Do not suggest alternatives unless the code is flawed or deprecated. Code: "{{{selection}}}"'
                        model       = "powershell-chat:$ModelVersion"
                    },
                    @{
                        name        = "ps-optimize"
                        description = "Optimize the selected PowerShell code"
                        prompt      = 'Review and optimize the following PowerShell code for performance, readability, and PowerShell best practices. Provide the improved code in a markdown block. Explain the key changes you made. Code: "{{{selection}}}"'
                        model       = "powershell-chat:$ModelVersion"
                    }
                )

                $continueDir = Split-Path $OutputPath -Parent
                $promptsDir = Join-Path $continueDir "prompts"
                if (-not (Test-Path $promptsDir)) {
                    New-Item -ItemType Directory -Path $promptsDir -Force | Out-Null
                    Write-Host "📁 Created prompts directory: $promptsDir" -ForegroundColor Gray
                }

                foreach ($command in $slashCommands) {
                    $promptFileName = "$($command.name).prompt"
                    $promptFilePath = Join-Path $promptsDir $promptFileName
                    
                    # Content for the .prompt file with YAML front matter
                    $promptFileContent = @"
---
title: /$($command.name)
description: $($command.description)
model: $($command.model)
---
$($command.prompt)
"@
                    $promptFileContent | Set-Content -Path $promptFilePath -Encoding UTF8
                }
                Write-Host "✅ Slash commands created as .prompt files in '$promptsDir'" -ForegroundColor Green
            }

            Write-Host "📋 Models included: $(($models | ForEach-Object { $_.name }) -join ', ')" -ForegroundColor Gray
        }
        catch {
            Write-Error "❌ Failed to save configuration: $_"
            return $null
        }
    }
    else {
        Write-Host "✅ Continue configuration generated successfully" -ForegroundColor Green
        Write-Host "📋 Models included: $(($models | ForEach-Object { $_.name }) -join ', ')" -ForegroundColor Gray
    }
    
    return $yamlConfig
}

# Note: Export-ModuleMember only works in .psm1 modules, not .ps1 scripts
# Function is available when dot-sourcing this script: . .\New-ContinueConfiguration.ps1

# Check if script is being run directly (not dot-sourced)
if ($MyInvocation.MyCommand.Path -eq $PSCommandPath) {
    Write-Host "🚀 PowerContinue Configuration Generator" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Parse command line arguments
    $OutputPath = $null
    $OllamaEndpoint = "http://localhost:11434"
    $IncludePython = $true
    $ModelVersion = "v1.0"
    $IncludeReranker = $true
    $CreateSlashCommands = $true
    $IncludeMorphApply = $true
    $MorphApiKey = $null

    # Override defaults with named arguments if provided
    foreach ($i in 0..($args.Count - 1)) {
        switch -Wildcard ($args[$i]) {
            "-OutputPath" { $OutputPath = $args[$i + 1] }
            "-OllamaEndpoint" { $OllamaEndpoint = $args[$i + 1] }
            "-IncludePython" { $IncludePython = [bool]::Parse($args[$i + 1]) }
            "-ModelVersion" { $ModelVersion = $args[$i + 1] }
            "-IncludeReranker" { $IncludeReranker = [bool]::Parse($args[$i + 1]) }
            "-CreateSlashCommands" { $CreateSlashCommands = [bool]::Parse($args[$i + 1]) }
            "-IncludeMorphApply" { $IncludeMorphApply = [bool]::Parse($args[$i + 1]) }
            "-MorphApiKey" { $MorphApiKey = $args[$i + 1] }
        }
    }

    # Generate configuration with parameters
    if ($OutputPath) {
        Write-Host "📁 Saving configuration to: $OutputPath" -ForegroundColor Green
        $config = New-ContinueConfiguration -OutputPath $OutputPath -OllamaEndpoint $OllamaEndpoint -IncludePython $IncludePython -ModelVersion $ModelVersion -IncludeMorphApply $IncludeMorphApply -IncludeReranker $IncludeReranker -CreateSlashCommands $CreateSlashCommands -MorphApiKey $MorphApiKey
    }
    else {
        Write-Host "📋 Generating configuration (preview mode):" -ForegroundColor Yellow
        $config = New-ContinueConfiguration -OllamaEndpoint $OllamaEndpoint -IncludePython $IncludePython -ModelVersion $ModelVersion -IncludeMorphApply $IncludeMorphApply -IncludeReranker $IncludeReranker -CreateSlashCommands $CreateSlashCommands -MorphApiKey $MorphApiKey
        
        Write-Host "`n📝 Generated Configuration Preview:" -ForegroundColor Yellow
        Write-Host ($config -split "`n" | Select-Object -First 25 | Out-String) -ForegroundColor Gray
        Write-Host "... (truncated - use -OutputPath to save full config)" -ForegroundColor Gray
    }
    
    Write-Host "`n💡 Usage Examples:" -ForegroundColor Yellow
    Write-Host "  Save to Continue config: .\New-ContinueConfiguration.ps1 -OutputPath `"~/.continue/config.yaml`"" -ForegroundColor Gray
    Write-Host "  Custom endpoint: .\New-ContinueConfiguration.ps1 -OllamaEndpoint `"http://localhost:11434`"" -ForegroundColor Gray
    Write-Host "  PowerShell only: .\New-ContinueConfiguration.ps1 -IncludePython `$false" -ForegroundColor Gray
    Write-Host "  Custom version: .\New-ContinueConfiguration.ps1 -ModelVersion `"v2.0`"" -ForegroundColor Gray
}