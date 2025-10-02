# PowerAuger

High-performance PowerShell command predictor with AST-based validation and AI completions.

## Features

- 🚀 **AST-Based Validation** - Filters out low-value suggestions (assignments, if-statements)
- 🧠 **AI-Powered Completions** - Ollama integration with context-aware prompts
- ⚡ **Multi-Layer Caching** - Sub-millisecond response times with progressive enhancement
- 📝 **Multiline Support** - Handles PowerShell backtick continuation properly
- 🔍 **Smart History Loading** - Validates and deduplicates command history
- 🎯 **Rich Context Preservation** - Maintains PowerShell tooltips for better AI prompts

## Quick Start

### Prerequisites

- .NET 8.0 SDK
- PowerShell 7.0+
- (Optional) Ollama for AI completions

### Build

```bash
dotnet build --configuration Release
```

### Install

```powershell
# Import the module
Import-Module ./bin/Release/net8.0/PowerAuger.dll

# Register with PSReadLine
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
```

## Architecture Overview

PowerAuger uses a multi-layer architecture for fast, high-quality completions:

```
PSReadLine
    ↓ (AST, Tokens, Position)
PowerAugerPredictor
    ↓ Sync: Cache lookup (0-2ms)
    ↓ Async: Background enrichment
FastCompletionStore
    ├── Layer 1: Prediction Cache (3s TTL)
    ├── Layer 2: Hot Cache (200 prefixes)
    ├── Layer 3: Promise Cache (AST-validated)
    └── Layer 4: Trie (all history)
```

### Key Components

| Component | Purpose | File |
|-----------|---------|------|
| **PowerAugerPredictor** | PSReadLine integration point | `src/PowerAugerPredictor.cs` |
| **FastCompletionStore** | Multi-layer cache system | `src/FastCompletionStore.cs` |
| **CompletionPromiseCache** | AST validation pipeline | Embedded in FastCompletionStore |
| **BackgroundProcessor** | Thread-safe PowerShell pool | `src/BackgroundProcessor.cs` |
| **OllamaService** | AI completion provider | `src/OllamaService.cs` |
| **PowerShellHistoryLoader** | Validated history loading | `src/PowerShellHistoryLoader.cs` |

## AST Validation Rules

### ✅ Allowed (Useful for Completions)

- **Commands**: `Get-ChildItem`, `Set-Location`
- **Pipelines**: `Get-Process | Where-Object { $_.CPU -gt 10 }`
- **ForEach-Object**: `$items | ForEach-Object { $_.Name }`
- **Expressions**: `2 + 2`, `[math]::PI`, `$true`
- **Multiline**: Commands with backtick continuation

### ❌ Filtered (Low Learning Value)

- **Assignments**: `$var = Get-ChildItem`
- **If-Statements**: `if ($condition) { ... }`
- **Loop Blocks**: `foreach ($x in $y) { ... }`, `while`, `for`
- **Try-Catch**: `try { ... } catch { ... }`
- **Invalid Commands**: Non-existent cmdlets

## Performance Characteristics

| Operation | Target | Actual |
|-----------|--------|--------|
| Sync GetSuggestion | <5ms | 0-2ms |
| AST Validation | <15ms | ~10ms |
| Background Enrichment | <60ms | ~40ms |
| Cache Hit Rate | >70% | ~85% |

## Configuration

### PowerShell Pool Size

Adjust in `BackgroundProcessor` constructor:
```csharp
new BackgroundProcessor(logger, poolSize: 4)  // Default: 4
```

### Cache Sizes

Configure in `FastCompletionStore`:
- Hot Cache: 200 prefixes
- Prediction Cache TTL: 3 seconds
- Promise Cache TTL: 30 seconds

### Ollama Settings

Configure in `OllamaService`:
```csharp
_modelName = "qwen2.5-0.5B-autocomplete-custom";
_apiUrl = "http://127.0.0.1:11434/api/generate";
```

## Testing

### Run Integration Tests

```powershell
# Full integration test suite
.\test\Test-IntegrationComplete.ps1

# AST validation tests
.\test\Test-ASTValidation.ps1

# AST type analysis
.\test\Test-ASTTypes.ps1
```

### Verify Completions

See test files in `/test` directory for examples.

## Development

### Project Structure

```
PowerAuger/
├── src/
│   ├── PowerAugerPredictor.cs    # Entry point
│   ├── FastCompletionStore.cs    # Cache layers
│   ├── BackgroundProcessor.cs    # PS pool
│   ├── OllamaService.cs          # AI provider
│   └── PowerShellHistoryLoader.cs # History
├── test/
│   └── Test-*.ps1                 # Test scripts
├── PowerShellModule/
│   └── PowerAugerSharp.psd1      # Module manifest
└── CLAUDE.md                      # Architecture details
```

### Adding Features

1. **New Validation Rules**: Modify `ValidateCompletions()` in `FastCompletionStore.cs`
2. **New Cache Layer**: Add to `GetCompletionsFromAstAsync()`
3. **New AI Provider**: Implement interface similar to `OllamaService`

## Troubleshooting

### No Completions Appearing

1. Check if module is loaded: `Get-Module PowerAuger`
2. Verify PSReadLine settings: `Get-PSReadLineOption`
3. Check logs in: `%LOCALAPPDATA%\PowerAugerSharp\`

### Poor Completion Quality

1. Rebuild history cache: Delete cache files and restart
2. Check Ollama connection: `Test-NetConnection localhost -Port 11434`
3. Review filtered commands in debug logs

## Contributing

See [CLAUDE.md](CLAUDE.md) for detailed architecture documentation.

## License

[License Type] - See LICENSE file for details

## Acknowledgments

- Built on PowerShell's AST and TabExpansion2
- Uses PSReadLine's prediction framework
- AI completions powered by Ollama