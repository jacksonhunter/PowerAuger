# CLAUDE.md - PowerAuger Development Guide

This file provides guidance to Claude Code when working with PowerAuger - an intelligent AI command predictor for PowerShell using the ICommandPredictor interface with Ollama integration.

## ⚠️ CRITICAL ISSUES AND LEARNINGS (2025-09-25)

### PSReadLine Context Isolation Problem
**PowerAuger's GetSuggestion runs in an isolated context where:**
- `[PowerAugerPredictor]` class type is NOT accessible from jobs/background contexts
- Module functions like `Write-PowerAugerLog` CRASH SILENTLY in GetSuggestion
- Static properties cannot be accessed from the predictor context
- TabExpansion2 returns 0 results when called from background jobs (works in main session)

### Current Bugs Causing Complete Failure
1. **Write-PowerAugerLog crashes** - Cannot access `[PowerAugerPredictor]::LogLevel` in GetSuggestion
2. **No completions ever shown** - GetSuggestion crashes before returning suggestions
3. **Progressive slowdown** - Typing gets 100ms+ slower per keystroke over time
4. **GetSuggestion called rarely** - PSReadLine only calls it occasionally, not per keystroke

### Key Discoveries
- GetSuggestion IS being called but crashes after logging to test file
- PowerShell class methods need ALL parameters: `GetStandardizedContext($input, $pos, $null)` not `($input, $pos)`
- ResultType must use enum: `$_.ResultType -eq [System.Management.Automation.CompletionResultType]::Command`
- TabExpansion2 takes 70-130ms even for simple inputs
- Background runspace is NOT causing the slowdowns (tested by stopping it)
- `$context.InputAst.Extent.Text` contains ENTIRE input including comments, not just current command

### Required Fixes to Make It Work
1. **Replace all Write-PowerAugerLog calls** in GetSuggestion with direct file writes
2. **Skip TabExpansion2 entirely** or make it truly async - it's too slow (70-130ms)
3. **Make GetSuggestion self-contained** - no class property access, no module functions
4. **Always return a suggestion** - even hardcoded - to verify pipeline works
5. **Parse input correctly** - extract actual command being typed, not full line with comments

## 🏗️ Current Architecture

PowerAuger is a sophisticated PSReadLine predictor plugin that provides AI-powered command completions using a custom Qwen 2.5 0.5B autocomplete model through Ollama.

### **Core Features**

- **Single Model Architecture**: Uses `qwen2.5-0.5B-autocomplete-custom` for fast completions
- **FIM (Fill-in-Middle) API**: Leverages Ollama's `/api/generate` endpoint
- **Background Prediction Engine**: Asynchronous predictions with thread-safe message passing
- **Contextual Learning**: Tracks accepted completions with directory and git context

### **Core Components (src/PowerAuger.psm1)**

#### **PowerAugerPredictor Class**

Main ICommandPredictor implementation (971 lines) with:
- Static cache and configuration
- Background runspace for async predictions
- Thread-safe message queues (`BlockingCollection`) and channels
- Contextual history tracking (max 300 entries)
- Persistent cache storage in `$env:LOCALAPPDATA\PowerAuger`

#### **Core Class Methods**

- `GetSuggestion()` - Main PSReadLine entry point (3-parameter signature)
- `OnCommandLineAccepted()` - Tracks accepted completions for learning
- `OnCommandLineExecuted()` - Command execution callback
- `OnCommandLineCleared()` - Command line clear callback
- `GetStandardizedContext()` - Extracts context from TabExpansion2 and environment
- `BuildContextAwarePrompt()` - Creates FIM prompts with contextual examples
- `StartBackgroundPredictionEngine()` - Initializes background prediction runspace
- `LoadHistoryExamples()` - Pre-loads command history patterns

#### **Exported Functions**

- `Save-PowerAugerCache` - Persists AI cache to disk
- `Import-PowerAugerCache` - Loads cached completions
- `Get-PowerAugerState` - Returns current predictor state and metrics
- `Get-PowerAugerCat` - ASCII art cat with dynamic expressions (based on state)
- `Set-PowerAugerPrompt` - Updates PowerShell prompt with animated cat
- `Update-PowerAugerChannelMessages` - Processes channel updates
- `Update-PowerAugerFromChannel` - Reads from update channel
- `Reset-PowerAugerPrompt` - Restores original prompt
- `Add-PowerAugerHistory` - Manual history addition for training
- `Get-PowerAugerStatus` - Shows predictor status with cat animation
- `Stop-PowerAugerBackground` - Clean shutdown of background engine

**Total: 1 Class + 11 Functions**

## 🎯 Key Architecture Details

### **1. Background Prediction System**

```powershell
# Message passing architecture
[BlockingCollection[hashtable]] $MessageQueue       # Input requests
[ConcurrentDictionary[string,object]] $ResponseCache # Cached responses
[Channel[hashtable]] $UpdateChannel                # Real-time updates
```

### **2. FIM Prompt Format**

```powershell
# Context-aware prompt with examples from history
"# Dir:PowerShell (used 5x)"
"<|fim_prefix|>Get-Ch<|fim_suffix|><|fim_middle|>Get-ChildItem"
"# Context: [Command,Parameter,Path]"
"<|fim_prefix|>$inputText<|fim_suffix|><|fim_middle|>"
```

### **3. Contextual Learning**

```powershell
# Hashtable key format: "command|path"
$ContextualHistory = @{
    "Get-ChildItem|C:\Projects" = @{
        FullCommand = "Get-ChildItem -Recurse"
        Input = "Get-Ch"
        Completion = "Get-ChildItem -Recurse"
        Context = @{ DirName = "Projects"; IsGitRepo = $true }
        AcceptedCount = 3
        LastUsed = [DateTime]
    }
}
```

### **4. API Configuration**

```powershell
# Ollama API settings
$body = @{
    model = "qwen2.5-0.5B-autocomplete-custom"
    prompt = $fimPrompt
    stream = $false
    options = @{
        num_predict = 80
        temperature = 0.2
        top_p = 0.9
    }
} | ConvertTo-Json -Depth 3
```

## 🚀 Current Implementation Status

### **✅ Completed Features**

- ICommandPredictor implementation with proper 3-parameter GetSuggestion signature
- Background prediction engine with thread-safe message passing
- Persistent cache with JSON serialization
- Contextual history learning (tracks accepted completions)
- TabExpansion2 integration for context awareness
- ASCII art cat with dynamic expressions in prompt
- Real-time status updates via channels
- Graceful shutdown with mutex synchronization

### **🔄 Active Components**

- Single model: `qwen2.5-0.5B-autocomplete-custom`
- API endpoint: `http://127.0.0.1:11434/api/generate`
- Cache location: `$env:LOCALAPPDATA\PowerAuger\ai_cache.json`
- Max contextual history: 300 entries
- Cache timeout: 3 seconds
- Prediction timeout: 500ms

### **📋 Known Limitations**

- No multi-model support (simplified from v4.0 plans)
- No SSH tunnel management
- No ranker or coder models
- No streaming completions (uses synchronous API)
- Limited to local Ollama instance

## 🛠️ Development Guidelines

### **Model Configuration**

Currently using a single autocomplete model setup via shell script:

```bash
# modelfiles/setup-ollama-models.sh
# Creates custom models from base Ollama models:
- qwen3-autocomplete-custom (from Qwen3_4b_instruct)
- qwen3-coder-30b-custom (optional, 17GB)
- qwen3-reranker-0.6b-custom (from Qwen3_Reranker)
- embeddinggemma-custom (from embeddinggemma:300m)
```

**Note**: Modelfiles referenced in the script are currently missing from the repository.

### **Testing Scripts (tests/)**

- **test_api_integration.ps1**: Tests prompt builders and API calls
- **Test-Auger.ps1**: Basic predictor functionality tests
- **debug_powerauger_function.ps1**: Function debugging utilities
- **test_ollama_direct.ps1**: Direct Ollama API testing

### **Performance Targets**

- **GetSuggestion**: Must return within 20ms for PSReadLine
- **Background predictions**: 500ms timeout for API calls
- **Cache TTL**: 3 seconds for prediction cache
- **Context history**: Max 300 entries

### **Continue IDE Integration (scripts/setup/continue/)**

- **New-ContinueConfiguration.ps1**: Generate VS Code config.json
- **Note**: Continue integration planned but not implemented

## 🔍 Critical Architecture Components

### **Static Class Properties**

```powershell
# Cache and configuration
[hashtable] $Cache = [hashtable]::Synchronized(@{})
[datetime] $CacheTime = [DateTime]::MinValue
[int] $CacheTimeoutSeconds = 3

# Model configuration
[string] $Model = "qwen2.5-0.5B-autocomplete-custom"
[string] $ApiUrl = "http://127.0.0.1:11434"

# Persistent storage
[string] $CachePath = "$env:LOCALAPPDATA\PowerAuger\ai_cache.json"

# History and learning
[ConcurrentBag[object]] $HistoryExamples
[hashtable] $ContextualHistory = [hashtable]::Synchronized(@{})
[int] $MaxContextualHistorySize = 300

# Background infrastructure
[Runspace] $PredictionRunspace
[PowerShell] $PredictionPowerShell
[BlockingCollection[hashtable]] $MessageQueue
[ConcurrentDictionary[string,object]] $ResponseCache
[Channel[hashtable]] $UpdateChannel
[CancellationTokenSource] $CancellationSource
[Mutex] $ShutdownMutex
```

### **Context Structure**

```powershell
# Standardized context from TabExpansion2
@{
    Groups = @{          # Completion groups by type
        'Command' = @('Get-ChildItem', 'Get-Process')
        'Parameter' = @('-Path', '-Recurse')
        'Path' = @('C:\\', 'D:\\')
    }
    Directory = $PWD.Path
    IsGitRepo = (Test-Path ".git")
    DirName = (Split-Path $PWD -Leaf)
    Timestamp = Get-Date
}
```

## 📚 Integration Points

### **PSReadLine Integration**

- **PowerAuger.psm1**: Single module file with ICommandPredictor implementation
- **Main Class**: `PowerAugerPredictor` inherits from `ICommandPredictor`
- **Registration**: Via `SubsystemManager.RegisterSubsystem()`
- **Module Manifest**: PowerAuger.psd1 with PSData.SubsystemsToRegister
- **Real-Time Requirement**: GetSuggestion must return within 20ms

### **Ollama Integration**

- **API Endpoint**: `http://127.0.0.1:11434/api/generate`
- **Model**: `qwen2.5-0.5B-autocomplete-custom`
- **Request Format**: FIM prompts with context examples
- **Response Parsing**: Simple text extraction from JSON response
- **Timeout**: 500ms for background predictions

### **Planned Features (Not Implemented)**

- Continue IDE integration
- SSH tunnel management
- Multi-model architecture
- Streaming completions
- Remote deployment

## 🎯 Future Enhancements

### **Potential Improvements**

- **Multi-Model Support**: Add coder and ranker models as originally planned
- **Streaming Completions**: Implement streaming API for faster response
- **SSH Tunnel Support**: Remote Ollama server connections
- **Enhanced Context**: More sophisticated context extraction
- **Performance Optimization**: Reduce GetSuggestion latency further

### **Current Priorities**

- Fix missing modelfiles in repository
- Improve cache persistence reliability
- Add comprehensive error handling
- Optimize background prediction timing
- Enhance contextual learning accuracy

PowerAuger is currently a functional PSReadLine predictor with AI-powered completions. The simplified architecture focuses on reliability and performance over the originally planned multi-model complexity.

## 📖 PSReadLine Predictor Plugin Reference

### **Creating a Custom ICommandPredictor Implementation**

Here's the correct interface implementation for PowerShell 7.4+:

```powershell
# MyPredictor.psm1
using namespace System.Management.Automation.Subsystem
using namespace System.Management.Automation.Subsystem.Prediction

class MyPredictor : ICommandPredictor {
    # Required properties (must be public, not hidden)
    [guid] $Id = [guid]::new('unique-guid-here')
    [string] $Name = 'My Predictor'
    [string] $Description = 'Custom predictor description'

    # CORRECT METHOD SIGNATURE - requires 3 parameters
    [SuggestionPackage] GetSuggestion(
        [PredictionClient] $client,           # Parameter 1: The client
        [PredictionContext] $context,         # Parameter 2: The context
        [System.Threading.CancellationToken] $cancellationToken  # Parameter 3: Cancellation token
    ) {
        # Get the current input
        $input = $context.InputAst.Extent.Text

        # Create suggestions list
        $suggestions = [System.Collections.Generic.List[PredictiveSuggestion]]::new()

        # Add suggestions based on input
        if ($input -match '^Get-') {
            $suggestions.Add([PredictiveSuggestion]::new(
                'Get-ChildItem',
                'List directory contents'
            ))
        }

        # Return SuggestionPackage or null
        return [SuggestionPackage]::new($suggestions)
    }

    # Required callback methods
    [void] OnCommandLineAccepted([string] $commandLine) {
        # Called when user accepts a command
    }

    [void] OnCommandLineExecuted([string] $commandLine) {
        # Called after command execution
    }

    [void] OnCommandLineCleared() {
        # Called when command line is cleared
    }
}

# Register the predictor
$predictor = [MyPredictor]::new()
[System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem(
    [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor,
    $predictor
)
```

### **Module Manifest Configuration**

```powershell
# MyPredictor.psd1
@{
    RootModule = 'MyPredictor.psm1'
    ModuleVersion = '1.0.0'
    GUID = 'module-guid-here'
    PowerShellVersion = '7.2'

    # For PowerShell 7.4+, SubsystemsToRegister goes in PrivateData.PSData
    PrivateData = @{
        PSData = @{
            SubsystemsToRegister = @('MyPredictor.MyPredictor')
        }
    }

    FunctionsToExport = @()
}
```

### **Key Implementation Notes**

1. **Method Name**: `GetSuggestion` (singular, not GetSuggestions)
2. **Parameters**: Must include all three parameters in the exact order
3. **Return Type**: `SuggestionPackage` or `null`
4. **Performance**: Must return within 20ms or predictions won't display
5. **Registration**: Can be done via manifest or explicitly with SubsystemManager

- ## REFERENCE
### Use this working Invoke-RestMethod function as a starting point:
function Get-CodeCompletion {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Prefix,
        
        [Parameter(Mandatory=$true)]
        [string]$Suffix,
        
        [int]$MaxTokens = 256
    )
    
    $prompt = "<|fim_prefix|>$Prefix<|fim_suffix|>$Suffix<|fim_middle|>"
    
    $body = @{
        model = "qwen2.5-0.5B-autocomplete-custom"
        prompt = $prompt
        stream = $false
        options = @{
            num_predict = $MaxTokens
            temperature = 0.2
            top_p = 0.9
        }
    } | ConvertTo-Json -Depth 3
    
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/generate" `
                                  -Method Post -Body $body -ContentType 'application/json'
    return $response.response
}
- ## REMEMBER
-Default user profile script calls 'Set-PSReadLineOption -PredictionSource HistoryAndPlugin'