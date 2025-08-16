# PowerAuger - Intelligent AI Command Predictor for PowerShell

<p align="center">
  <img src="https://i.imgur.com/O1lO3rA.png" alt="PowerAuger Logo" width="200"/>
</p>

> **🚀 Production-Ready AI Shell Assistant**
>
> PowerAuger v3.4.0+ is a mature, production-grade command predictor with intelligent model selection, advanced context awareness, and comprehensive tunnel management. Designed for both local development and enterprise remote AI deployment.

**PowerAuger** is an intelligent, context-aware command predictor for PowerShell, designed to transform your shell into a proactive assistant. Powered by local or remote [Ollama](https://ollama.com/) models, it provides completions that understand your environment, intent, and workflow.

## Project Structure

```
PowerAuger/
├── src/                           # Core PowerAuger module
│   ├── PowerAuger.psm1           # Main prediction engine (3000+ lines)
│   ├── PowerAuger.psd1           # Module manifest v3.4.0
│   └── PowerAuger.mermaid        # Architecture diagram
├── scripts/                       # Setup and configuration scripts
│   └── setup/
│       ├── setup.ps1             # Main setup script
│       └── continue/             # Continue IDE integration
│           ├── New-ContinueConfiguration.ps1  # Config generator
│           ├── README.md         # This file
│           └── CLAUDE.md         # Development documentation
├── tests/                        # Testing and benchmarking
│   └── integration/
│       ├── Benchmark-PowerAuger.ps1
│       ├── Daily-PowerAuger-Tests.ps1
│       └── Test-PowerAugerTracking.ps1
├── legacy/                       # Historical components
│   ├── modelfiles/              # Previous Ollama model definitions
│   ├── OllamaCommandPredictor/  # Legacy predictor module
│   └── OllamaTunnelMonitor-Backup/
└── [config/, docs/, modelfiles/, rules/, templates/]  # Planned directories
```

## Core Features

-   **🚀 Guided Setup**: Comprehensive `setup.ps1` script with auto-configuration and testing
-   **🔐 SSH Tunnel Management**: Secure remote Ollama connections with background process monitoring
-   **🧠 Persistent State**: Configuration and cache stored in `~/.PowerAuger/`
-   **🤖 Intelligent Model Selection**: Fast vs context-aware model switching based on complexity
-   **🧩 Advanced Context Engine**: Git status, file awareness, environment detection
-   **⚡ Performance Caching**: TTL-based intelligent caching with size management
-   **📊 Comprehensive Metrics**: Acceptance tracking, error monitoring, performance analytics
-   **🔧 OllamaTunnelMonitor**: Standalone tunnel monitoring with real-time dashboard

## Roadmap & Next Steps

### Immediate Priorities

-   **🔄 Continue Integration**: Reintegrate Continue IDE as a config.json generator with updated modelfiles
-   **📝 Model Strategy Decision**: Evaluate current models and determine minimal modelfile requirements
-   **🔄 Dynamic Prompt Building**: Implement adaptive prompt construction for active models
-   **📡 TunnelMonitor Development**: Complete standalone tunnel monitoring module
-   **📋 Configuration Management**: Streamline model and connection configuration

### Short-Term Goals (v3.5.x)

-   **JSON-First Reliability**: Enhanced structured output with few-shot examples
-   **Model Pre-warming**: Eliminate first-use latency with background model loading
-   **SSH Robustness**: Industry-standard tunnel flags and connection stability
-   **Dynamic Context**: Real-time environment and workflow adaptation

### Mid-Term Goals (v4.0)

-   **Workflow Learning**: Feed accepted suggestions back to improve relevance
-   **Project Context**: Persistent, file-based context for repository-specific intelligence
-   **Pattern Recognition**: Advanced user behavior analysis and prediction

### Long-Term Vision

-   **Asynchronous Pipeline**: Non-blocking UI with background processing
-   **Real-time Updates**: Seamless suggestion updates without interruption
-   **Enterprise Integration**: Advanced remote deployment and management features

## Installation & Setup

1. Clone the repository
2. Navigate to the project root
3. Run the setup script:
   ```powershell
   .\scripts\setup\setup.ps1
   ```
4. Follow guided configuration for Ollama host, SSH tunnels, and model selection
5. Enable PSReadLine integration:
   ```powershell
   Set-PSReadLineOption -PredictionSource HistoryAndPlugin
   ```

## Key Commands

-   `Show-PredictorStatus`: Connection status, model configuration, and stats
-   `Get-PredictorStatistics`: Detailed performance and cache metrics
-   `Set-PredictorConfiguration`: Modify Ollama host, debug mode, and settings
-   `Clear-PowerAugerCache`: Clear prediction cache
-   `Test-OllamaConnection`: Manual connectivity testing

## Continue IDE Integration

The Continue IDE integration has been reorganized as a configuration generator:

- **Location**: `scripts/setup/continue/`
- **Purpose**: Generate `config.json` files for Continue IDE with PowerAuger-compatible models
- **Status**: Needs updating for new model strategy and project structure
- **Script**: `New-ContinueConfiguration.ps1` generates IDE-compatible configurations
