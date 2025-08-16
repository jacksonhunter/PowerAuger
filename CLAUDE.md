# CLAUDE.md - PowerAuger v4.0 Development Guide

This file provides guidance to Claude Code when working with PowerAuger - an intelligent AI command predictor for PowerShell featuring multi-model architecture, streaming completions, and JSON-first design.

## 🏗️ Current Architecture (v4.0)

PowerAuger has been completely transformed into a sophisticated multi-model AI system with the following key components:

### **Multi-Model Architecture**
- **3 Specialized Models**: Autocomplete (fast), Coder (context-aware), Ranker (evaluation)
- **JSON-First Design**: All models output structured JSON with comprehensive schemas
- **Parallel Execution**: Simultaneous model calls for maximum responsiveness
- **Streaming Pipeline**: Real-time completion filtering and ranking

### **Core Function Organization (src/PowerAuger.psm1)**

#### **Core Infrastructure (Lines 86-180)**
- `Merge-Hashtables` (86) - Deep hashtable merging for configuration
- `Load-PowerAugerConfiguration` (100) - JSON config file loading
- `Load-PowerAugerState` (115) - Persistent state restoration
- `Save-PowerAugerState` (146) - State persistence to JSON files
- `Save-PowerAugerConfiguration` (168) - Config file management

#### **SSH Tunnel Management (Lines 186-410)**
- `Find-SSHTunnelProcess` (186) - Robust tunnel process detection
- `Start-OllamaTunnel` (259) - Secure tunnel establishment
- `Stop-OllamaTunnel` (326) - Clean tunnel termination
- `Test-OllamaConnection` (396) - Connectivity validation

#### **Context Intelligence (Lines 415-590)**
- ~~`Select-OptimalModel` (REMOVED)~~ - **Replaced with parallel execution**
- `_Get-EnvironmentContext` (436) - Directory, git, elevation detection
- `_Get-CommandContext` (447) - Command parsing and analysis
- `_Get-FileTargetContext` (471) - File path extraction and validation
- `_Get-GitContext` (495) - Repository status integration
- `Get-EnhancedContext` (516) - **Main context orchestrator**
- `Update-RecentTargets` (560) - Success pattern tracking

#### **JSON-First API Integration (Lines 592-810)**
- `Invoke-OllamaCompletion` (592) - **Simplified execution engine**
- `Build-AutocompletePrompt` (675) - Fast completion payloads
- `Build-CoderPrompt` (698) - Context-rich analysis payloads  
- `Build-RankerPrompt` (770) - Evaluation scoring payloads

#### **Caching & Prediction (Lines 815-920)**
- `Get-CachedPrediction` (744) - Intelligent TTL-based caching
- `Get-HistoryBasedSuggestions` (787) - Fallback prediction system
- `Get-CommandPrediction` (822) - **Main prediction orchestrator**

#### **History & Feedback (Lines 928-995)**
- `Add-CommandToHistory` (928) - Acceptance tracking and learning
- `Clear-PowerAugerCache` (977) - Cache management

#### **Monitoring & Diagnostics (Lines 1001-1105)**
- `Get-PredictorStatistics` (1001) - Performance analytics
- `Show-PredictorStatus` (1047) - Real-time status display
- `Get-PredictionLog` (1089) - Detailed prediction logging

#### **Initialization & Configuration (Lines 1110-1370)**
- `Register-PowerAugerCleanupEvents` (1110) - Comprehensive cleanup
- `Initialize-OllamaPredictor` (1220) - Module initialization
- `Set-PredictorConfiguration` (1304) - Runtime configuration

**Total: 30 Functions** (Streamlined from previous architecture)

## 🎯 Key Architectural Changes (v4.0)

### **1. Multi-Model System**
```powershell
# OLD: Single model selection
Select-OptimalModel → Single model → Build-ContextualPrompt

# NEW: Parallel multi-model execution
Get-EnhancedContext → Build-AutocompletePrompt + Build-CoderPrompt → Parallel execution → Ranking/Filtering
```

### **2. JSON-First Design**
```json
// Autocomplete Output
{
  "completions": [
    {
      "text": "Get-ChildItem",
      "confidence": 0.95,
      "type": "cmdlet",
      "partial_match": true
    }
  ]
}

// Coder Output  
{
  "suggestions": [
    {
      "command": "Get-ChildItem -Path C:\\Projects -Recurse",
      "explanation": "Recursively list all files in Projects directory",
      "confidence": 0.88,
      "safety_level": "safe",
      "parameters": ["Path", "Recurse"]
    }
  ],
  "context_analysis": {
    "environment": "PowerShell development environment",
    "complexity": "medium",
    "intent": "file_exploration"
  }
}
```

### **3. Specialized Prompt Builders**
- **Build-AutocompletePrompt**: Fast, deterministic completions
- **Build-CoderPrompt**: Rich context analysis with safety levels
- **Build-RankerPrompt**: Relevance evaluation and scoring

### **4. Streamlined API Execution**
- **Invoke-OllamaCompletion**: Pure execution engine accepting complete payloads
- **Endpoint Optimization**: `/api/chat` vs `/api/generate` based on use case
- **Error Handling**: Comprehensive timeout and recovery mechanisms

## 🚀 Current Development Status

### **✅ Completed (v4.0)**
- Multi-model architecture implementation
- JSON-first prompt builder system  
- Enhanced modelfiles with built-in schemas
- Streamlined API execution engine
- Comprehensive README with Continue integration

### **🔄 In Progress**
- Parallel execution implementation
- Streaming completion pipeline
- Ranker model integration
- Fuzzy logic filtering system
- Dynamic confidence scoring

### **✅ Recently Enhanced (from Legacy Analysis)**
- Smart defaults tracking with success/failure patterns
- Directory pattern recognition (Node.js, Python, .NET, PowerShell)
- Error history context for proactive improvement
- Module context with command source analysis
- @ Trigger system for dynamic context injection
- Enhanced context providers with streaming capabilities

### **📋 Next Priorities**
- Context daemon for real-time environment monitoring
- Completion queue management (512+ completions)
- Advanced filtering pipeline with ranking
- Model pre-warming and state tracking
- Dynamic prompt enrichment with feedback loops
- Asynchronous prediction pipeline development

## 🛠️ Development Guidelines

### **Model Configuration (modelfiles/)**
Each model has specialized configuration:

```modelfile
# Autocomplete-0.1.Modelfile
PARAMETER temperature 0.1    # High determinism
PARAMETER top_k 5           # Restrict to most likely tokens  
PARAMETER num_ctx 2048      # Fast processing
SYSTEM """JSON schema with completion types"""

# Coder-0.1.Modelfile  
PARAMETER temperature 0.4    # Balanced creativity
PARAMETER top_k 40          # More variety
PARAMETER num_ctx 32768     # Large context
SYSTEM """JSON schema with safety levels"""

# Ranker-0.1.Modelfile
PARAMETER temperature 0.0    # Pure evaluation
PARAMETER seed 42           # Reproducible scoring
SYSTEM """JSON schema for relevance scoring"""
```

### **Testing & Benchmarking (tests/integration/)**
- **Benchmark-PowerAuger.ps1**: Performance and acceptance testing
- **Daily-PowerAuger-Tests.ps1**: Automated regression testing  
- **Test-PowerAugerTracking.ps1**: Metrics validation

### **Performance Targets**
- **Autocomplete**: <200ms response time, >90% accuracy
- **Coder**: <1000ms response time, >80% relevance
- **Ranker**: <500ms evaluation time, consistent scoring
- **Overall Acceptance Rate**: >40% user adoption

### **Continue IDE Integration (scripts/setup/continue/)**
- **New-ContinueConfiguration.ps1**: Generate VS Code config.json
- **Model Synchronization**: Share PowerAuger models with Continue
- **Unified Experience**: Consistent AI assistance across terminal and IDE

## 🔍 Critical Architecture Components

### **Enhanced Context Providers System**
```powershell
$global:ContextProviders = [ordered]@{
    'Environment'      = { param($Context) _Get-EnvironmentContext -Context $Context }
    'Command'          = { param($Context) _Get-CommandContext -Context $Context }
    'FileTarget'       = { param($Context) _Get-FileTargetContext -Context $Context }
    'Git'              = { param($Context) _Get-GitContext -Context $Context }
    'SmartDefaults'    = { param($Context) _Get-SmartDefaultsContext -Context $Context }
    'DirectoryPattern' = { param($Context) _Get-DirectoryPatternContext -Context $Context }
    'ErrorHistory'     = { param($Context) _Get-ErrorHistoryContext -Context $Context }
    'ModuleContext'    = { param($Context) _Get-ModuleContext -Context $Context }
    'TriggerContext'   = { param($Context) _Get-TriggerContext -Context $Context }
}

# Smart Defaults for Advanced Learning
$global:SmartDefaults = @{
    CommandSuccess    = @{}    # Success/failure tracking
    DirectoryPatterns = @{}    # Command patterns per directory type
    RecentCommands    = @()    # Command history with success tracking
    ErrorHistory      = @()    # Failed commands for learning
    TriggerProviders  = @{     # @ trigger system
        'files', 'dirs', 'git', 'history', 'errors', 'modules', 'env'
    }
}
```

### **Model Registry**
```powershell
$global:ModelRegistry = @{
    'AutocompleteModel' = $global:OllamaConfig.Models.FastCompletion
    'CoderModel'        = $global:OllamaConfig.Models.ContextAware  
    'RankerModel'       = $global:OllamaConfig.Models.Ranker
}
```

### **Performance Metrics**
```powershell
$global:PerformanceMetrics = @{
    RequestCount       = 0
    CacheHits          = 0
    AverageLatency     = 0
    SuccessRate        = 1.0
    AcceptanceTracking = @{} # Per-model acceptance rates
    ProviderTimings    = @{} # Context provider performance
}
```

## 📚 Integration Points

### **PSReadLine Integration**
- **Main Entry Point**: `Get-CommandPrediction` function
- **Prediction Format**: Array of completion strings
- **Real-Time Updates**: Streaming suggestions as user types

### **Continue IDE Integration**  
- **Config Generation**: PowerAuger models → Continue config.json
- **Model Sharing**: Same Ollama models for terminal and IDE
- **Context Synchronization**: Environment awareness across tools

### **Remote Deployment**
- **SSH Tunneling**: Secure connections to remote Ollama servers
- **Connection Management**: Auto-recovery and health monitoring
- **Enterprise Features**: Multi-user support and configuration management

## 🎯 Future Architecture (v5.0 Vision)

### **Streaming Intelligence**
- **Real-Time Context Daemon**: Background environment monitoring
- **Completion Queue**: Manage 512+ simultaneous completions
- **Dynamic Filtering**: Multi-stage refinement pipeline
- **Adaptive Learning**: User pattern recognition and model adaptation

### **Enterprise Scale**
- **Team Intelligence**: Shared knowledge base across developers
- **Repository Context**: Deep project structure understanding  
- **Custom Training**: Fine-tune models on organization patterns
- **Analytics Dashboard**: Team productivity and AI effectiveness metrics

PowerAuger v4.0 represents a complete architectural transformation from simple completion to sophisticated AI-powered development assistance. The foundation is now in place for advanced streaming intelligence and enterprise-scale deployment.