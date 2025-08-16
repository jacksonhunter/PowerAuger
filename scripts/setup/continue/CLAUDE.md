# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is **PowerAuger v3.4.0+** - a production-ready Ollama PowerShell Predictor with AI-powered command completion, intelligent model selection, advanced context awareness, and comprehensive metrics tracking. The repository has been **reorganized into a clean, modular structure** with separate directories for source code, scripts, tests, and legacy components.

## Project Reorganization (2025)

### New Directory Structure
The project has been completely reorganized from a flat structure to a hierarchical, modular organization:

```
PowerAuger/
├── src/                          # Core module source code
│   ├── PowerAuger.psm1          # Main prediction engine (3000+ lines)
│   ├── PowerAuger.psd1          # Module manifest v3.4.0
│   └── PowerAuger.mermaid       # Architecture diagram
├── scripts/                      # Scripts and automation
│   └── setup/
│       ├── setup.ps1            # Main setup script
│       └── continue/            # Continue IDE integration
│           ├── New-ContinueConfiguration.ps1  # Config generator
│           ├── README.md        # Updated project documentation
│           └── CLAUDE.md        # This file
├── tests/                        # All testing and benchmarking
│   └── integration/
│       ├── Benchmark-PowerAuger.ps1
│       ├── Daily-PowerAuger-Tests.ps1
│       └── Test-PowerAugerTracking.ps1
├── legacy/                       # Historical components (not tracked)
│   ├── modelfiles/              # Previous Ollama model definitions
│   ├── OllamaCommandPredictor/  # Legacy predictor module
│   └── OllamaTunnelMonitor-Backup/
└── [Future Directories]
    ├── config/                   # Configuration templates
    ├── docs/                     # Documentation
    ├── modelfiles/               # New model definitions
    ├── rules/                    # Validation rules
    └── templates/                # Template files
```

### Key Changes Made
- **Source Consolidation**: Core PowerAuger module moved to `src/`
- **Script Organization**: Setup and configuration scripts moved to `scripts/setup/`
- **Test Centralization**: All testing moved to `tests/integration/`
- **Legacy Preservation**: Historical components moved to `legacy/` (untracked)
- **Continue Reintegration**: Continue IDE support reorganized as configuration generator

## Current Status & Next Priorities

### Immediate Development Tasks

1. **Continue IDE Integration Modernization**
   - Status: Continue support moved to `scripts/setup/continue/` as config generator
   - Task: Update `New-ContinueConfiguration.ps1` for new project structure
   - Need: Decision on new model strategy for Continue IDE compatibility

2. **Model Strategy Evaluation**
   - Current: Legacy modelfiles in `legacy/modelfiles/` (5 PowerShell + 2 Python models)
   - Decision Needed: Which models to modernize vs. create minimal modelfiles
   - Focus: Determine active model set for dynamic prompt building

3. **Dynamic Prompt Building Function**
   - Purpose: Adaptive prompt construction for active models
   - Integration: Works with current intelligent model selection system
   - Target: Enhanced context awareness and prediction relevance

4. **OllamaTunnelMonitor Development**
   - Status: Backup in `legacy/OllamaTunnelMonitor-Backup/`
   - Goal: Complete standalone tunnel monitoring module
   - Features: Real-time dashboard, headless monitoring, auto-import

5. **Roadmap Updates**
   - Reflect reorganization in project planning
   - Update installation paths and documentation
   - Align with new modular architecture

### Project Status (v3.4.0+ - 2025)
PowerAuger is in **active development** with production-grade core features and strategic reorganization:

**Completed Reorganization:**
- ✅ Modular directory structure implemented
- ✅ Source code consolidated in `src/`
- ✅ Scripts organized in `scripts/setup/`
- ✅ Tests centralized in `tests/integration/`
- ✅ Legacy components preserved in `legacy/`
- ✅ Continue IDE reintegrated as configuration generator

**Core Features (Stable):**
- ✅ Core prediction engine with intelligent model selection
- ✅ SSH tunnel management for secure remote Ollama connections
- ✅ Advanced context awareness (git, files, environment)
- ✅ Intelligent caching with TTL and performance metrics
- ✅ Comprehensive setup script with auto-configuration
- ✅ Acceptance rate tracking and error rate monitoring
- ✅ Model pre-warming to eliminate first-use latency

**Active Development Focus:**
- 🔄 Continue IDE config generator modernization
- 🔄 Model strategy evaluation and minimal modelfile decisions
- 🔄 Dynamic prompt building implementation
- 🔄 OllamaTunnelMonitor standalone module completion
- 🔄 Documentation updates for new structure

### Roadmap (Updated for Reorganized Structure)

**Immediate Priorities (v3.5.x):**
- Continue IDE integration with updated modelfile strategy
- Dynamic prompt building for active models
- OllamaTunnelMonitor completion
- Model evaluation and minimal modelfile decisions

**Short-Term Goals (v3.5.x):**
- JSON-first reliability with enhanced structured output
- SSH tunnel robustness with industry-standard flags
- Advanced state tracking for model memory optimization
- Configuration management streamlining

**Mid-Term Goals (v4.0):**
- Dynamic prompt enrichment with workflow learning
- Persistent project-level context
- Advanced pattern recognition and user behavior analysis

**Long-Term Vision (Beyond v4.0):**
- Asynchronous prediction pipeline
- Non-blocking UI with background processing
- Enterprise integration features

## Key Architecture (Updated for New Structure)

### Core PowerAuger Engine (src/PowerAuger.psm1:1-3000+)
1. **Intelligent Model Selection**: Automatically switches between fast and context-aware models based on input complexity
2. **Advanced Context Engine**: Environment awareness (git, files, directory state, elevation, command history)
3. **SSH Tunnel Management**: Secure connections to remote Ollama servers with background process management
4. **Performance Tracking**: Comprehensive metrics including acceptance rates, error rates, and latency monitoring
5. **Intelligent Caching**: TTL-based caching with size management and performance optimization
6. **Fallback Systems**: History-based suggestions when AI models are unavailable
7. **State Persistence**: Configuration and history stored in `~/.PowerAuger/` directory
8. **Model Pre-warming**: Background jobs warm models at startup to eliminate first-use latency

### Model Strategy (Needs Evaluation)
**Current Legacy Models** (in `legacy/modelfiles/`):
- PowerShell-Fast.Modelfile (qwen3:4b-q4_K_M, <300ms target)
- PowerShell-Context.Modelfile (Advanced context-aware completion)
- PowerShell-Completion.Modelfile (JSON-structured for Continue IDE)
- PowerShell-Adaptive.Modelfile (Learning model)
- PowerShell-Chat.Modelfile (Conversational assistance)
- Python-Chat.Modelfile, Python-Completion.Modelfile

**Decision Required**: Which models to modernize vs. create minimal modelfiles for current needs.

### Model Selection Strategy (Current Implementation)
- **Simple completions** (<10 chars, no complex context) → powershell-fast:latest model
- **Complex completions** (parameters, file paths, pipelines) → powershell-context:latest model
- **Timeout handling**: 30-second timeouts for custom models
- **Fallback logic**: History-based suggestions when models fail

### Metrics and Monitoring
- **Acceptance Tracking**: Monitors which predictions are actually used by users
- **Error Rate Tracking**: Tracks when accepted predictions result in command failures
- **Performance Metrics**: Request latency, cache hit rates, success rates
- **Prediction Logging**: Optional detailed logging of all predictions for troubleshooting

## Development Guidelines (Updated Paths)

### Testing and Benchmarking
- **Location**: `tests/integration/`
- **Main Scripts**: 
  - `Benchmark-PowerAuger.ps1` - Performance and acceptance rate testing
  - `Daily-PowerAuger-Tests.ps1` - Automated testing suite
  - `Test-PowerAugerTracking.ps1` - Metrics validation
- **Performance Targets**: Fast model <300ms, Context model <1000ms, Acceptance rate >30%

### Configuration Management
- **Core Module**: `src/PowerAuger.psm1` and `src/PowerAuger.psd1`
- **Setup Script**: `scripts/setup/setup.ps1`
- **User Config**: `~/.PowerAuger/config.json`
- **SSH Config**: `$global:OllamaConfig.Server`
- **Model Parameters**: Match legacy Modelfile specifications (temperature: 0.1-0.4, top_p: 0.8-0.85)

### Continue IDE Integration (Modernized)
- **Location**: `scripts/setup/continue/`
- **Generator**: `New-ContinueConfiguration.ps1`
- **Purpose**: Generate `config.json` files for Continue IDE
- **Status**: Needs updating for new model strategy and project structure
- **Integration**: Compatible with PowerAuger's model selection system

### Installation Process (Updated Paths)
1. Clone repository
2. Run `scripts/setup/setup.ps1` for guided configuration
3. Auto-detection of SSH keys and available models
4. PowerShell profile configuration for auto-loading
5. Connectivity testing and diagnostics

### Development Workflow
- **Source Code**: All core development in `src/`
- **Scripts**: Setup and configuration in `scripts/`
- **Testing**: Integration tests in `tests/integration/`
- **Legacy**: Historical components preserved in `legacy/` (untracked)
- **Documentation**: Centralized in `scripts/setup/continue/` for now

## Next Steps for Development

1. **Update Continue IDE Generator**: Modernize `New-ContinueConfiguration.ps1` for new structure
2. **Model Strategy Decision**: Evaluate legacy models and determine active set
3. **Dynamic Prompt Building**: Implement adaptive prompt construction
4. **OllamaTunnelMonitor**: Complete standalone module from backup
5. **Path Updates**: Update all references to use new directory structure