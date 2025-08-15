# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is **PowerAuger v3.4.0** - a production-ready Ollama PowerShell Predictor with AI-powered command completion, intelligent model selection, advanced context awareness, and comprehensive metrics tracking. The repository includes multiple specialized Ollama models, benchmarking tools, SSH tunnel management, and PowerShell theming.

## Project Status and Timeline

### Current State (v3.4.0 - 2025)
PowerAuger is in **active development** with production-grade features and experimental roadmap items. The project has evolved through several major releases:

**Released Features:**
- ✅ Core prediction engine with intelligent model selection
- ✅ SSH tunnel management for secure remote Ollama connections
- ✅ Advanced context awareness (git, files, environment)
- ✅ Intelligent caching with TTL and performance metrics
- ✅ Comprehensive setup script with auto-configuration
- ✅ Acceptance rate tracking and error rate monitoring
- ✅ Prediction logging and diagnostics
- ✅ Cache management and configuration persistence
- ✅ Model pre-warming to eliminate first-use latency

**Current Development Phase:**
- 🔧 JSON-first reliability improvements
- 🔧 SSH tunnel robustness enhancements (PowerAuger.psm1:186-394)
- 🔧 Performance optimization and refinements

### Feature Fork: OllamaTunnelMonitor (v1.0.0 - 2025)
**Parallel Development Track** - Standalone tunnel monitoring and management system

**Development Approach:**
- **Feature Fork Strategy**: Independent module development for focused tunnel management
- **PowerAuger Integration**: Compatible but standalone - can import PowerAuger config automatically
- **Separation of Concerns**: Monitoring/infrastructure vs prediction/AI functionality
- **Safe Development**: Changes don't affect core PowerAuger prediction reliability

**OllamaTunnelMonitor Released Features:**
- ✅ .NET socket-based connectivity testing (System.Net.Sockets integration)
- ✅ Real-time interactive dashboard with live metrics
- ✅ Headless monitoring daemon for background operation
- ✅ PowerAuger configuration auto-import
- ✅ Windows-optimized process management and cleanup
- ✅ Comprehensive tunnel and Ollama server health checks
- ✅ Background job monitoring for Continue IDE integration
- ✅ Modular architecture with independent versioning

**Integration Timeline:**
- **Phase 1 (Completed)**: Enhanced SSH tunnel management in PowerAuger (background processes, PID tracking, Windows shutdown handling)
- **Phase 2 (In Progress)**: Standalone OllamaTunnelMonitor module development
- **Phase 3 (Planned)**: Optional tight integration with shared state and metrics
- **Phase 4 (Future)**: Windows service option for system-level tunnel persistence

### Roadmap

**Short-Term Goals (Next Minor Releases):**
- Enhanced JSON-first approach with few-shot examples
- Improved SSH tunnel stability with industry-standard flags
- Advanced state tracking for model memory optimization

**Mid-Term Goals (v4.0 Major Release):**
- Dynamic prompt enrichment with workflow learning
- Persistent project-level context
- Advanced pattern recognition

**Long-Term Goals (Beyond v4.0):**
- Asynchronous prediction pipeline
- Non-blocking UI with background processing
- Real-time suggestion updates

## File Structure

### Core PowerAuger Module
- `modules/PowerAuger/PowerAuger.psm1` - Main prediction engine (3000+ lines) with intelligent caching, context awareness, and acceptance tracking
- `modules/PowerAuger/PowerAuger.psd1` - Module manifest (v3.4.0) with comprehensive function exports and PSReadLine integration
- `modules/PowerAuger/setup.ps1` - Interactive setup script with auto-configuration, model detection, and profile integration

### OllamaTunnelMonitor Module (Feature Fork)
- `modules/OllamaTunnelMonitor/OllamaTunnelMonitor.psm1` - Standalone tunnel monitoring engine with .NET socket integration
- `modules/OllamaTunnelMonitor/OllamaTunnelMonitor.psd1` - Module manifest (v1.0.0) with monitoring and dashboard functions
- **Key Features**: Real-time dashboard, headless monitoring, PowerAuger config auto-import, Windows process management

### Ollama Model Definitions
- `modelfiles/PowerShell-Fast.Modelfile` - Ultra-fast completion (qwen3:4b-q4_K_M, <300ms target)
- `modelfiles/PowerShell-Completion.Modelfile` - JSON-structured completion for Continue IDE integration
- `modelfiles/PowerShell-Context.Modelfile` - Advanced context-aware completion with environment analysis
- `modelfiles/PowerShell-Adaptive.Modelfile` - Learning model that adapts to user patterns
- `modelfiles/PowerShell-Chat.Modelfile` - Conversational PowerShell assistance

### Benchmarking and Testing
- `Benchmark-PowerAuger.ps1` - Comprehensive performance testing with acceptance rate analysis
- `Daily-PowerAuger-Tests.ps1` - Automated daily testing suite
- `Test-PowerAugerTracking.ps1` - Tracking and metrics validation

### PowerShell Profiles and Theming
- `profiles/Microsoft.PowerShell_profile.ps1` - Synthwave/cyberpunk "Blood Dragon" theme with PowerAuger integration
- `profiles/profile.ps1` - Conda environment initialization
- `profiles/theme_files/` - Theme assets and fonts

## Key Architecture

### PowerAuger Prediction Engine (PowerAuger.psm1:1-1131)
1. **Intelligent Model Selection**: Automatically switches between fast and context-aware models based on input complexity
2. **Advanced Context Engine**: Environment awareness (git, files, directory state, elevation, command history)
3. **SSH Tunnel Management**: Secure connections to remote Ollama servers with background process management
4. **Performance Tracking**: Comprehensive metrics including acceptance rates, error rates, and latency monitoring
5. **Intelligent Caching**: TTL-based caching with size management and performance optimization
6. **Fallback Systems**: History-based suggestions when AI models are unavailable
7. **State Persistence**: Configuration and history stored in `~/.PowerAuger/` directory
8. **Model Pre-warming**: Background jobs warm models at startup to eliminate first-use latency

### Model Selection Strategy
- **Simple completions** (<10 chars, no complex context) → powershell-fast:latest model
- **Complex completions** (parameters, file paths, pipelines) → powershell-context:latest model
- **Timeout handling**: 30-second timeouts for custom models
- **Fallback logic**: History-based suggestions when models fail

### Metrics and Monitoring
- **Acceptance Tracking**: Monitors which predictions are actually used by users
- **Error Rate Tracking**: Tracks when accepted predictions result in command failures
- **Performance Metrics**: Request latency, cache hit rates, success rates
- **Prediction Logging**: Optional detailed logging of all predictions for troubleshooting

## Development Notes

### Testing and Benchmarking
- Use `Benchmark-PowerAuger.ps1` to test model performance and acceptance rates
- Performance targets: Fast model <300ms, Context model <1000ms, Acceptance rate >30%
- Benchmark includes statistical analysis and model comparison

### Configuration Management
- Configuration stored in `~/.PowerAuger/config.json`
- SSH tunnel configuration in `$global:OllamaConfig.Server`
- Model parameters match Modelfile specifications (temperature: 0.1-0.4, top_p: 0.8-0.85)
- Context providers are extensible via `$global:ContextProviders` registry

### Model Integration
- Models use different prompt templates: Fast uses "INPUT:", Context uses "CONTEXT: pwd=..., files=[...], command=..."
- Models output line-separated text, not JSON (except PowerShell-Completion)
- Custom model compatibility with intelligent timeout handling
- Model pre-warming via background jobs in `Initialize-OllamaPredictor` (PowerAuger.psm1:1000-1032)

### Setup and Installation
- Interactive `setup.ps1` script handles complete configuration
- Auto-detects SSH keys and available models
- Configures PowerShell profile for auto-loading
- Tests connectivity and provides diagnostics

## PowerShell Profile Integration

- PowerAuger auto-initializes with SSH tunnel management
- Profiles include synthwave theming alongside AI prediction capabilities
- `profile.ps1` handles conda environment setup if available
- Auto-loader added to `$PROFILE` for seamless integration