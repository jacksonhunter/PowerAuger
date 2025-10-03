# PowerAuger

An AST-based PowerShell command completion predictor that provides high-quality, validated suggestions with AI enrichment capabilities.

## Features

### ✅ Implemented
- **AST-Based Validation** - Filters out assignments, if-statements, and invalid commands
- **Multi-Layer Caching** - Progressive enhancement with prediction cache, hot cache, and trie
- **Async Architecture** - Never blocks typing with background enrichment
- **PowerShell Pool** - Thread-safe execution with 4 concurrent instances
- **Rich Tooltips** - Preserves parameter documentation for AI context
- **History Integration** - Loads and validates command history
- **Multiline Support** - Handles backtick continuation and complex statements

### 🚀 Performance
- **Synchronous Path**: <5ms for cached results
- **Background Validation**: ~60ms with AST analysis
- **Cache Hit Rate**: >70% after warmup
- **Zero Blocking**: Async enrichment updates cache for next keystroke

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

## How It Works

PowerAuger uses a progressive enhancement pattern with multiple caching layers:

```
User Types → PSReadLine → PowerAugerPredictor
                              ↓
                    Check Cache Layers (0-2ms)
                              ↓
                    Return Immediate Results
                              ↓
                    Start Async Enrichment (background)
                              ↓
                    Validate with AST Analysis
                              ↓
                    Update Cache for Next Keystroke
```

### Core Components

1. **PowerAugerPredictor** - Entry point that manages sync/async flow
2. **FastCompletionStore** - Multi-layer cache system
3. **CompletionPromiseCache** - AST validation with AsyncLazy pattern
4. **BackgroundProcessor** - Channel-based PowerShell pool
5. **OllamaService** - AI enrichment with chat/generate modes

## Quality Features

### AST Validation
```powershell
# These are filtered out:
$var = Get-ChildItem     # Assignment - not useful
if (Get-Ch) { }          # If-statement - low value
Get-NonExistent          # Invalid command

# These are kept:
Get-ChildItem            # Valid command
Get-ChildItem -Path      # With parameters
Get-ChildItem | Where    # Pipeline completion
```

### Tooltip Preservation
Completions retain rich documentation:
- Parameter syntax and types
- Command descriptions
- Used for AI prompt context

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

## Future Features

See [plan.md](plan.md) for roadmap including:
- Frecency-based hot item prediction
- PowerType-style dictionary system
- Smart file completion with patterns
- Persistent learning database

### The Magic Combination
- **zsh-z's frecency** for learning what's "hot"
- **PowerType's dictionaries** for rich command-specific completions
- **DirectoryPredictor's patterns** for flexible file matching
- **CompletionPredictor's filtering** to avoid expensive operations
- **PowerAuger's AST validation** to ensure quality

This creates a completion system that:
1. Learns from usage (frecency)
2. Knows command syntax (dictionaries)
3. Validates suggestions (AST)
4. Never blocks (async everything)
5. Gets faster over time (caching + learning)

## Troubleshooting

### No Completions Appearing

1. Check if module is loaded: `Get-Module PowerAuger`
2. Verify PSReadLine settings: `Get-PSReadLineOption`
3. Check logs in: `%LOCALAPPDATA%\PowerAugerSharp\`

### Poor Completion Quality

1. Rebuild history cache: Delete cache files and restart
2. Check Ollama connection: `Test-NetConnection localhost -Port 11434`
3. Review filtered commands in debug logs

## Technical Details

### Thread Safety
- Channel-based PowerShell pool
- No manual locking required
- Automatic queuing when pool exhausted

### Caching Strategy
1. **Prediction Cache** - 3 second TTL for recent inputs
2. **Hot Cache** - Top 200 most frequent prefixes
3. **Promise Cache** - 30 second TTL for async results
4. **Trie** - All validated history commands

### Known Limitations
- Background runspace context: 66% success rate (missing some interactive session modules)
- First keystroke may be empty if cache cold
- Validation overhead: 5-15ms per completion set

## Contributing

See [CLAUDE.md](CLAUDE.md) for architecture details. Key areas for improvement:
- Additional command dictionaries
- Performance optimizations
- Enhanced AI prompting
- Cross-platform testing

## License

MIT License - See LICENSE file for details

## Acknowledgments

Built on insights from:
- [CompletionPredictor](https://github.com/PowerShell/CompletionPredictor) - AST usage patterns
- [PowerType](https://github.com/AnderssonPeter/PowerType) - Dictionary architecture
- [DirectoryPredictor](https://github.com/Ink230/DirectoryPredictor) - Pattern matching
- [zsh-z](https://github.com/agkozak/zsh-z) - Frecency algorithm