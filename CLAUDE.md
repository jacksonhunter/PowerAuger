# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is **PowerAuger v3.1.0** - a production-ready Ollama PowerShell Predictor with AI-powered command completion, intelligent model selection, and advanced context awareness. The repository includes multiple specialized Ollama models, benchmarking tools, SSH tunnel management, and PowerShell theming.

## File Structure

### Core PowerAuger Module
- `modules/PowerAuger/PowerAuger.psm1` - Main prediction engine with JSON-first API, intelligent caching, and context awareness
- `modules/PowerAuger/PowerAuger.psd1` - Module manifest (v3.1.0) with PSReadLine integration
- `modules/PowerAuger/setup.ps1` - Module installation and configuration

### Ollama Model Definitions
- `modelfiles/PowerShell-Fast.Modelfile` - Ultra-fast completion (qwen3:4b-q4_K_M, <300ms target)
- `modelfiles/PowerShell-Completion.Modelfile` - JSON-structured completion for Continue IDE integration
- `modelfiles/PowerShell-Context.Modelfile` - Advanced context-aware completion with environment analysis
- `modelfiles/PowerShell-Adaptive.Modelfile` - Learning model that adapts to user patterns
- `modelfiles/PowerShell-Chat.Modelfile` - Conversational PowerShell assistance

### Benchmarking and Testing
- `Benchmark-PowerAuger.ps1` - Comprehensive performance testing and model comparison
- `Daily-PowerAuger-Tests.ps1` - Automated daily testing suite
- `Test-PowerAugerTracking.ps1` - Tracking and metrics validation

### PowerShell Profiles and Theming
- `profiles/Microsoft.PowerShell_profile.ps1` - Synthwave/cyberpunk "Blood Dragon" theme with PowerAuger integration
- `profiles/profile.ps1` - Conda environment initialization
- `profiles/theme_files/` - Theme assets and fonts

## Key Architecture

### PowerAuger Prediction Engine
1. **Intelligent Model Selection**: Automatically switches between fast and context-aware models based on input complexity
2. **Advanced Context Engine**: Environment awareness (git, files, directory state, elevation, command history)
3. **SSH Tunnel Management**: Secure connections to remote Ollama servers
4. **JSON-First API**: Structured responses compatible with Continue IDE and PSReadLine
5. **Intelligent Caching**: TTL-based caching with performance metrics
6. **Fallback Systems**: History-based suggestions when AI models are unavailable

### Model Selection Strategy
- **Simple completions** (<10 chars, no complex context) → PowerShell-Fast model
- **Complex completions** (parameters, file paths, pipelines) → PowerShell-Context model
- **Learning patterns** → PowerShell-Adaptive model (pattern recognition and user adaptation)

## Development Notes

### Testing and Benchmarking
- Use `Benchmark-PowerAuger.ps1` to test model performance and selection effectiveness
- Performance targets: Fast model <300ms, Context model <1000ms, Success rate >95%
- Benchmark covers both fast and context model scenarios with statistical analysis

### Configuration
- SSH tunnel configuration in `$global:OllamaConfig.Server`
- Model parameters match Modelfile specifications (temperature, top_p, timeouts)
- Context providers are extensible via `$global:ContextProviders` registry

### Model Development
- Models use different prompt templates: Fast uses "INPUT:", Context uses "CONTEXT: pwd=..., files=[...], command=..."
- Completion models output line-separated text, not JSON (except PowerShell-Completion)
- Custom model compatibility with 30-second timeouts for larger models

## PowerShell Profile Integration

- PowerAuger auto-initializes with SSH tunnel management
- Profiles include synthwave theming alongside AI prediction capabilities
- `profile.ps1` handles conda environment setup if available