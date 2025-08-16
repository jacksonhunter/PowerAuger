# PowerAuger - Intelligent AI Command Predictor for PowerShell

<p align="center">
  <img src="https://i.imgur.com/O1lO3rA.png" alt="PowerAuger Logo" width="200"/>
</p>

> **🚀 Next-Generation AI Shell Assistant**
>
> PowerAuger v4.0+ is a sophisticated, multi-model AI command predictor featuring streaming completions, intelligent ranking, and JSON-first architecture. Built for both local development and enterprise remote AI deployment with Continue IDE integration.

**PowerAuger** transforms your PowerShell terminal into an intelligent, context-aware assistant powered by local or remote [Ollama](https://ollama.com/) models. Experience real-time command prediction with sophisticated context analysis, parallel model execution, and streaming completion filtering.

## ✨ Revolutionary Features

### 🧠 **Multi-Model AI Architecture**
- **Parallel Execution**: Simultaneous Autocomplete + Coder model calls for maximum responsiveness
- **Intelligent Ranking**: Built-in ranker model for relevance scoring and confidence assessment
- **JSON-First Design**: Structured outputs with comprehensive metadata and safety levels
- **Streaming Pipeline**: Real-time completion filtering with fuzzy logic and dynamic confidence scoring

### 🎯 **Advanced Context Intelligence**
- **Environment Awareness**: Git status, file structure, elevation, and directory context
- **Command Analysis**: Parse cmdlets, parameters, and intent for sophisticated suggestions
- **Smart Defaults**: Success/failure tracking with command pattern recognition
- **Directory Patterns**: Project-type detection (Node.js, Python, .NET, PowerShell)
- **Error Learning**: Recent error analysis for proactive suggestion improvement
- **Module Context**: Available commands and recently imported modules
- **@ Trigger System**: Context injection with `@files`, `@git`, `@history`, `@env`
- **Recent Pattern Learning**: Track successful commands for improved relevance
- **Project Context**: Repository-specific intelligence and workflow adaptation

### 🔐 **Enterprise-Grade Infrastructure**
- **SSH Tunnel Management**: Secure remote Ollama connections with auto-recovery
- **Performance Analytics**: Acceptance tracking, latency monitoring, and error analysis
- **State Persistence**: Configuration and cache in `~/.PowerAuger/` with JSON storage
- **Fallback Systems**: History-based suggestions when AI models are unavailable

### 🔧 **Continue IDE Integration**
- **Configuration Generator**: Seamless Continue IDE setup with PowerAuger-compatible models
- **Model Synchronization**: Shared model configurations between terminal and IDE
- **Development Workflow**: Unified AI assistance across PowerShell and VS Code

## 🏗️ Project Architecture

```
PowerAuger/
├── src/                          # Core AI prediction engine
│   ├── PowerAuger.psm1          # Main module (3000+ lines)
│   ├── PowerAuger.psd1          # Module manifest v4.0
│   └── PowerAuger.mermaid       # Architecture diagram
├── modelfiles/                   # Ollama model configurations
│   ├── Autocomplete-0.1.Modelfile  # Fast completion model
│   ├── Coder-0.1.Modelfile         # Context-aware coding model
│   └── Ranker-0.1.Modelfile        # Relevance scoring model
├── scripts/                      # Setup and automation
│   └── setup/
│       ├── setup.ps1            # Main installation script
│       └── continue/            # Continue IDE integration
│           ├── New-ContinueConfiguration.ps1
│           ├── README.md        # Continue setup guide
│           └── CLAUDE.md        # Development documentation
├── tests/                        # Testing and benchmarking
│   └── integration/
│       ├── Benchmark-PowerAuger.ps1      # Performance testing
│       ├── Daily-PowerAuger-Tests.ps1    # Automated test suite
│       └── Test-PowerAugerTracking.ps1   # Metrics validation
└── legacy/                       # Historical components
    ├── modelfiles/              # Previous model definitions
    ├── OllamaCommandPredictor/  # Legacy predictor module
    └── OllamaTunnelMonitor-Backup/
```

## 🚀 Quick Start

### Prerequisites
- PowerShell 7.0+
- [Ollama](https://ollama.com/) (local or remote)
- SSH access for remote deployments (optional)

### Installation

1. **Clone and Setup**
   ```powershell
   git clone https://github.com/username/PowerAuger.git
   cd PowerAuger
   .\scripts\setup\setup.ps1
   ```

2. **Configure Models**
   ```powershell
   # Pull required models (if using local Ollama)
   ollama create powershell-fast:latest -f modelfiles/Autocomplete-0.1.Modelfile
   ollama create powershell-context:latest -f modelfiles/Coder-0.1.Modelfile
   ollama create qwen3-reranker:latest -f modelfiles/Ranker-0.1.Modelfile
   ```

3. **Enable Predictions**
   ```powershell
   Set-PSReadLineOption -PredictionSource HistoryAndPlugin
   Import-Module .\src\PowerAuger.psm1
   ```

### Continue IDE Integration

Set up AI assistance in VS Code with PowerAuger-compatible models:

```powershell
cd scripts\setup\continue
.\New-ContinueConfiguration.ps1 -ModelType "PowerShell" -OutputPath "$env:USERPROFILE\.continue"
```

## 📖 Core Functionality

### Intelligent Command Prediction
```powershell
# Simple completions use fast autocomplete model
Get-Ch[TAB] → Get-ChildItem

# Complex completions use context-aware coder model  
Get-ChildItem C:\Projects -Recurse -Filter *.ps1 | Where-Object[TAB]
→ Get-ChildItem C:\Projects -Recurse -Filter *.ps1 | Where-Object { $_.Length -gt 1KB }

# @ Trigger system for context injection
@files[TAB] → Lists all files in current directory for selection
@git[TAB] → Shows git branch, status, and recent commits
@history[TAB] → Recent command history for pattern matching
@env[TAB] → Environment context (SSH, elevation, PowerShell version)
```

### Performance Monitoring
```powershell
# View real-time statistics
Show-PredictorStatus

# Detailed performance metrics
Get-PredictorStatistics

# Clear cache for fresh start
Clear-PowerAugerCache
```

### Advanced Configuration
```powershell
# Configure remote Ollama server
Set-PredictorConfiguration -LinuxHost "192.168.1.100" -EnableDebug

# Test connectivity
Test-OllamaConnection

# View prediction logs
Get-PredictionLog -Last 25
```

## 🛠️ Model Architecture

### Autocomplete Model (Fast Completion)
- **Purpose**: Lightning-fast command completion
- **Model**: Qwen3-4B with Q4_K_M quantization
- **Parameters**: Temperature 0.1, 2K context, Top-K 5
- **Response Time**: <200ms target
- **Output**: JSON with completions, confidence, and type classification

### Coder Model (Context-Aware)
- **Purpose**: Sophisticated command analysis with explanations
- **Model**: Qwen3-Coder-30B with extended context
- **Parameters**: Temperature 0.4, 32K context, Top-K 40
- **Features**: Safety levels, parameter analysis, intent recognition
- **Output**: JSON with suggestions, explanations, and context analysis

### Ranker Model (Relevance Scoring)
- **Purpose**: Evaluate and rank completion relevance
- **Model**: Qwen3-Reranker-4B for precise evaluation
- **Parameters**: Temperature 0.0, deterministic scoring
- **Features**: Syntax validation, context matching, practical utility
- **Output**: JSON with relevance scores and ranking factors

## 📊 Performance & Analytics

### Real-Time Metrics
- **Request Latency**: Average API response times per model
- **Cache Hit Rate**: Efficiency of intelligent caching system  
- **Acceptance Rate**: Percentage of predictions actually used
- **Error Tracking**: Monitor when accepted suggestions fail
- **Context Timing**: Performance breakdown by context provider

### Quality Assurance
- **Model Health**: Automatic model availability monitoring
- **Fallback Systems**: History-based suggestions when models fail
- **Context Validation**: Ensure environment analysis accuracy
- **Performance Thresholds**: Alert on degraded response times

## 🔧 Advanced Configuration

### SSH Tunnel Management
```powershell
# Configure secure remote connection
$global:OllamaConfig.Server.LinuxHost = "your-server.com"
$global:OllamaConfig.Server.SSHUser = "your-username" 
$global:OllamaConfig.Server.SSHKey = "~/.ssh/id_rsa"

# Start tunnel with auto-recovery
Start-OllamaTunnel

# Monitor tunnel health
Test-OllamaConnection
```

### Model Selection Tuning
```powershell
# Customize model selection criteria
$global:OllamaConfig.Models.FastCompletion.UseCase = "Quick completions <15 chars"
$global:OllamaConfig.Models.ContextAware.UseCase = "Complex completions with analysis"

# Adjust timeout and performance settings
$global:OllamaConfig.Performance.CacheTimeout = 600  # 10 minutes
$global:OllamaConfig.Performance.EnablePredictionLogging = $true
```

## 🗺️ Roadmap & Development

### Current Phase: Multi-Model Architecture (v4.0)
- ✅ **JSON-First Design**: Structured outputs with comprehensive schemas
- ✅ **Specialized Prompt Builders**: Model-specific optimization
- ✅ **Enhanced Modelfiles**: Built-in system prompts and parameters
- 🔄 **Parallel Execution**: Simultaneous model calls for maximum speed
- 🔄 **Streaming Pipeline**: Real-time filtering and ranking system
- 🔄 **Fuzzy Logic**: Advanced keystroke matching and confidence scoring

### Next Phase: Streaming Intelligence (v4.1)
- **Real-Time Context Daemon**: Background environment monitoring with change detection
- **Completion Queue Management**: Handle 512+ completions efficiently with priority scoring
- **Dynamic Confidence Scoring**: Time-based and pattern-based relevance with keystroke decay
- **Advanced Filtering**: Multi-stage completion refinement pipeline with fuzzy logic
- **Model Pre-warming**: Eliminate first-use latency with intelligent background loading
- **Dynamic Prompt Enrichment**: Feed accepted suggestions back to models for workflow learning

### Future Vision: Enterprise Integration (v5.0)
- **Asynchronous Prediction Pipeline**: Non-blocking UI with seamless background processing
- **Persistent Project-Level Context**: File-based context storage for repository-specific intelligence
- **Workflow Learning**: Advanced pattern recognition and user behavior adaptation
- **Team Intelligence**: Shared knowledge base across development teams
- **Repository Context**: Deep integration with project structures and patterns
- **Scalable Architecture**: Support for high-concurrency enterprise deployment

### Long-Term Goals
- **Custom Model Training**: Fine-tune models on organization-specific patterns
- **Advanced Analytics**: Detailed insights into development workflow efficiency and AI effectiveness
- **Multi-Language Support**: Extend beyond PowerShell to Bash, Zsh, and other shells
- **Enterprise Dashboard**: Team productivity metrics and AI assistance effectiveness
- **Real-Time Collaboration**: Shared context and suggestions across team members

## 🤝 Contributing

### Development Environment
1. **Clone Repository**: `git clone https://github.com/username/PowerAuger.git`
2. **Install Dependencies**: Ensure PowerShell 7+ and Ollama are available
3. **Run Tests**: `.\tests\integration\Daily-PowerAuger-Tests.ps1`
4. **Development Mode**: Set `$env:OLLAMA_PREDICTOR_DEV_MODE = $true`

### Areas for Contribution
- **Model Optimization**: Improve prompt engineering and model selection
- **Context Providers**: Add new environment awareness capabilities  
- **Performance**: Optimize caching, reduce latency, improve accuracy
- **Testing**: Expand integration tests and benchmarking scenarios
- **Documentation**: Enhance setup guides and troubleshooting

### Code Standards
- **PowerShell Style**: Follow PowerShell best practices and PSScriptAnalyzer rules
- **Error Handling**: Comprehensive try-catch blocks with meaningful messages
- **Performance**: Profile code changes and maintain sub-second response times
- **Documentation**: Include inline comments and update CLAUDE.md for architectural changes

## 📚 Continue IDE Integration Guide

PowerAuger includes comprehensive Continue IDE support for unified AI assistance across terminal and editor:

### Setup Continue with PowerAuger Models
```powershell
# Navigate to Continue setup
cd scripts\setup\continue

# Generate config for PowerShell development
.\New-ContinueConfiguration.ps1 -ModelType "PowerShell" -OllamaHost "localhost:11434"

# Generate config for multi-language development  
.\New-ContinueConfiguration.ps1 -ModelType "Universal" -OllamaHost "your-server.com:11434"
```

### Continue Configuration Features
- **Model Synchronization**: Use same models as PowerAuger terminal
- **Context Sharing**: Leverage PowerAuger's environment awareness
- **Performance Optimization**: Optimized settings for fast code completion
- **Multi-Model Support**: Separate models for chat vs. autocomplete

### Troubleshooting Continue Integration
```powershell
# Verify Continue config location
Get-ChildItem "$env:USERPROFILE\.continue" -Recurse

# Test model connectivity from Continue perspective
Test-Path "$env:USERPROFILE\.continue\config.json"

# Regenerate config if needed
.\New-ContinueConfiguration.ps1 -Force
```

For detailed Continue setup instructions, see: `scripts\setup\continue\README.md`

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Ollama Team**: For the fantastic local AI model deployment platform
- **Continue Dev**: For innovative IDE AI integration
- **Qwen Model Creators**: For high-quality, efficient language models
- **PowerShell Team**: For building an extensible, powerful shell platform

---

**PowerAuger** - *Intelligent AI Command Prediction for PowerShell*  
Transform your shell experience with next-generation AI assistance.