# PowerAuger AST-Based Architecture v3

## Current State (2025-10-03)
✅ **Fully refactored and optimized**
- Simplified architecture with FrecencyStore as single source of truth
- Zsh-z scoring algorithm for intelligent ranking
- AST validation for all completions
- Fixed Unicode escape handling for Windows paths
- Comprehensive error logging throughout

## Core Principles
1. **AST-First**: Use PSReadLine's parsed AST for validation
2. **Quality Over Quantity**: Only store/suggest validated commands
3. **Performance**: Sub-5ms response times with async enrichment
4. **Simplicity**: Single storage backend (FrecencyStore) instead of multiple caches

## Architecture
```
PSReadLine → PowerAugerPredictor → FastCompletionStore → FrecencyStore
                                        ↓
                            CompletionPromiseCache (AST validation)
                                        ↓
                            BackgroundProcessor (PowerShell pool)
```

## Key Components

### CommandHistoryStore
- **Unfiltered command history** with rich metadata tracking
- Persistent JSON storage at `%LOCALAPPDATA%\PowerAuger\command-history.json`
- Records: command text, working directory, timestamp, success status, AST type
- Automatically loads from PSReadLine history file on first run
- Supports here-string parsing and multiline commands
- Used for context and sequence analysis (not for completions)
- Default max size: 10,000 entries

### FrecencyStore
- **Primary storage** with zsh-z frecency algorithm
- Combines frequency + recency for intelligent ranking
- Persistent storage with binary + JSON backup
- Only stores validated commands
- Automatic aging and maintenance

### FastCompletionStore
- Orchestrates completions between FrecencyStore and AST validation
- Manages CompletionPromiseCache for async enrichment
- Integrates with OllamaService for AI suggestions

### CompletionPromiseCache
- AsyncLazy pattern prevents duplicate validation work
- Validates via PowerShell AST
- Filters out: assignments, if-statements, invalid commands
- Preserves rich tooltips for context

### BackgroundProcessor
- Channel-based PowerShell pool (4 instances)
- Thread-safe checkout/checkin pattern
- Pre-loaded modules for performance

## Validation Rules
✅ **Keep**:
- CommandAst, PipelineAst (with valid commands)
- Commands that exist and are executable

❌ **Filter**:
- AssignmentStatementAst (`$var = ...`)
- IfStatementAst (`if (...) {...}`)
- LoopStatementAst (`while`, `for`, `foreach`)
- TryStatementAst (`try {...} catch {...}`)
- Commands < 2 characters (likely typos)
- Path-like commands (contain `/` or `\`)

## Recent Improvements (2025-10-03)

### Fixed Issues
1. **Unicode Escape Handling**: Now uses `JsonSerializer.Deserialize` instead of `Regex.Unescape`
2. **Frecency Scoring**: Restored proper frequency-based ranking from history
3. **Error Logging**: Added logging to all catch blocks for better debugging
4. **Code Cleanup**: Removed ~500 lines of dead code (CompletionTrie.cs, unused methods)

### Performance Optimizations
- Removed artificial 1000-command limit in JSON backup
- Simplified from multi-layer caching to single FrecencyStore
- Eliminated redundant validation passes

## OllamaService Integration
- **Chat Mode**: Conversational completions with full context
- **Generate Mode**: Fill-in-middle with few-shot examples
- Both modes use validated completions only
- Graceful fallback when Ollama unavailable

## Key Advantages
1. **Simplicity**: Single source of truth (FrecencyStore)
2. **Intelligence**: Zsh-z algorithm ranks by actual usage patterns
3. **Quality**: Only validated, executable commands
4. **Reliability**: Comprehensive error handling and logging
5. **Performance**: <5ms sync path, async enrichment
6. **Correctness**: Handles Windows paths and Unicode properly

# Future Features
See [plan.md](plan.md) for detailed roadmap

