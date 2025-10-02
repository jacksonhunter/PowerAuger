# PowerAuger AST-Based Architecture v2

## Executive Summary

PowerAuger uses AST-based validation to provide high-quality PowerShell command completions. The architecture leverages PSReadLine's already-parsed AST to:

1. **Validate completions** - Filter out assignments, if-statements, and invalid commands
2. **Preserve rich context** - Keep tooltips with parameter documentation for AI prompting
3. **Enable async enrichment** - Background validation doesn't block typing
4. **Build quality cache** - Only validated completions enter the cache/trie

**Current State:**

- ✅ Multi-layer caching with AST-based promise pattern
- ✅ Channel-based PowerShell pool (4 instances, thread-safe)
- ✅ Progressive enhancement (cache → async enrichment)
- ✅ Validation logic integrated and working
- ✅ OllamaService integration with tooltips implemented
- ✅ History loading with validation
- ✅ Fallback patterns removed

**Implementation Complete:**

All planned features have been successfully implemented as of 2025-10-02.

**Latest Updates (2025-10-02):**
- ✅ Multiline command support with backtick continuation
- ✅ Proper handling of ForEach-Object vs foreach statements
- ✅ CommandExpressionAst support for pure expressions
- ✅ Validated history loading with deduplication

## Core Principles

### 1. Use What PSReadLine Already Parsed

PSReadLine provides `PredictionContext` with:

- `context.InputAst` - Already parsed AST
- `context.Tokens` - Already tokenized
- `context.CursorPosition` - IScriptPosition with offset

Use AST overload: `CommandCompletion.CompleteInput(Ast, Token[], IScriptPosition, Hashtable, PowerShell)`

### 2. Validate Completions Before Caching

Filter TabExpansion2 results using AST analysis:

- Parse each completion suggestion
- Filter out assignments, if-statements (low learning value)
- Validate command existence in pipelines
- Keep only useful completions with tooltips

### 3. Preserve Rich Context

Tooltips from `CompletionResult.ToolTip` contain:

- Parameter syntax
- Command documentation
- Type information

Pass these to AI for better prompt context.

### 4. Progressive Enhancement Pattern

- First keystroke: Return cached results (may be empty)
- Background: Async AST completion populates cache
- Next keystroke: Results ready from previous enrichment

## Architecture Layers (Current Implementation)

```
┌────────────────────────────────────────────────────────────┐
│ PSReadLine                                                 │
│ Calls: GetSuggestion(PredictionContext)                   │
│ Provides: AST, Tokens, CursorPosition                     │
└────────────────┬───────────────────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────────────────────┐
│ PowerAugerPredictor (Entry Point)                         │
│ - Extract text for cache key only                         │
│ - Check sync caches → return immediately (0-2ms)          │
│ - Check pending async tasks → add if ready                │
│ - Start new async enrichment (don't wait)                 │
└────────────────┬───────────────────────────────────────────┘
                 │ Pass: AST, Tokens, Position
                 ▼
┌────────────────────────────────────────────────────────────┐
│ FastCompletionStore                                        │
│ ┌────────────────────────────────────────────────────────┐ │
│ │ Layer 1: Prediction Cache (3s TTL)                    │ │
│ │ Layer 2: Hot Cache (top 200 prefixes)                 │ │
│ │ Layer 3: CompletionPromiseCache (AST-based)           │ │
│ │ Layer 4: CompletionTrie (all history)                 │ │
│ │ Layer 5: Fallback patterns (to be removed)            │ │
│ └────────────────────────────────────────────────────────┘ │
└────────────────┬───────────────────────────────────────────┘
                 │ GetCompletionsFromAstAsync
                 ▼
┌────────────────────────────────────────────────────────────┐
│ CompletionPromiseCache (Embedded in FastCompletionStore)  │
│ - AsyncLazy<CommandCompletion> promise pattern            │
│ - Checkout PowerShell from pool                           │
│ - Call CommandCompletion.CompleteInput(AST overload)      │
│ - ⭐ Validate results using AST analysis                   │
│ - Return PowerShell to pool                                │
│ - Cache promise for 30s TTL                                │
└────────────────┬───────────────────────────────────────────┘
                 │
                 ▼
┌────────────────────────────────────────────────────────────┐
│ BackgroundProcessor (PowerShell Pool Manager)             │
│ - Channel<PowerShell> with 4 instances                    │
│ - Each has own Runspace (CreateDefault)                   │
│ - Pre-loads PSReadLine, Management, Utility               │
│ - CheckOut/CheckIn pattern with auto-cleanup              │
└────────────────────────────────────────────────────────────┘
```

## Key Components

### 1. PowerAugerPredictor (Current Implementation)

**File:** `PowerAugerPredictor.cs`

```csharp
public SuggestionPackage GetSuggestion(
    PredictionClient client,
    PredictionContext context,
    CancellationToken cancellationToken)
{
    // Extract AST and position from PSReadLine
    var ast = context.InputAst;
    var tokens = context.Tokens;  // Parse once in GetSuggestion for fallback
    var cursorPosition = context.CursorPosition;

    // Extract text for cache key ONLY
    var input = ast.Extent.Text;
    var currentCommand = ExtractCurrentCommand(input, cursorPosition.Offset);

    // Layer 1: Synchronous cache lookup (0-2ms fast path)
    var cached = _completionStore.GetCompletions(currentCommand, 3);
    var suggestions = cached.Select(c =>
        new PredictiveSuggestion(c, $"Cached: {c}")).ToList();

    // Layer 2: Check if previous async task completed
    var asyncKey = $"{input}:{cursorPosition.Offset}";
    if (_pendingCompletions.TryGetValue(asyncKey, out var pendingTask) &&
        pendingTask.IsCompletedSuccessfully)
    {
        var asyncResults = pendingTask.Result;
        foreach (var result in asyncResults.Take(3))
        {
            suggestions.Add(new PredictiveSuggestion(result, $"PS: {result}"));
        }
        _pendingCompletions.TryRemove(asyncKey, out _);
    }

    // Layer 3: Start new async enrichment if not pending
    if (!_pendingCompletions.ContainsKey(asyncKey) && tokens != null)
    {
        var completionTask = _completionStore.GetCompletionsFromAstAsync(
            ast, tokens, cursorPosition, maxResults: 5);

        _pendingCompletions[asyncKey] = completionTask;

        // Cleanup after delay
        _ = completionTask.ContinueWith(t => {
            Thread.Sleep(1000);
            _pendingCompletions.TryRemove(asyncKey, out _);
        });
    }

    return new SuggestionPackage(suggestions);
}
```

**Key Points:**

- Synchronous fast path returns immediately
- Async enrichment updates cache for next keystroke
- Text extraction only for cache keys
- AST/tokens passed directly to store

### 2. FastCompletionStore (Multi-Layer Cache)

**File:** `FastCompletionStore.cs`

```csharp
public async Task<List<string>> GetCompletionsFromAstAsync(
    Ast ast,
    Token[] tokens,
    IScriptPosition cursorPosition,
    int maxResults = 3)
{
    var cacheKey = $"{ast.Extent.Text}:{cursorPosition.Offset}";
    var prefix = ast.Extent.Text.Substring(0,
        Math.Min(ast.Extent.Text.Length, cursorPosition.Offset));

    // Layer 1: Prediction cache (3s TTL)
    if (_predictionCache.TryGetValue(cacheKey, out var cached) && !cached.IsExpired)
        return new List<string> { cached.Prediction };

    // Layer 2: Hot cache (200 most common prefixes)
    _hotCacheLock.EnterReadLock();
    try {
        if (_hotCache.TryGetValue(prefix, out var hotCompletions))
            return hotCompletions.Take(maxResults).ToList();
    }
    finally {
        _hotCacheLock.ExitReadLock();
    }

    // Layer 3: Promise cache with AST validation
    var completion = await _promiseCache.GetCompletionFromAstAsync(
        ast, tokens, cursorPosition);

    if (completion?.CompletionMatches?.Count > 0)
    {
        var results = completion.CompletionMatches
            .Take(maxResults)
            .Select(m => m.CompletionText)
            .ToList();

        // Cache in trie for future
        foreach (var result in results)
            _trie.AddCompletion(prefix, result, 1.0f);

        TrackAndPromoteIfFrequent(prefix, results);
        return results;
    }

    // Layer 4: Trie lookup
    return _trie.GetCompletions(prefix, maxResults);
}
```

### 3. CompletionPromiseCache (AST Validation)

**Embedded in:** `FastCompletionStore.cs`

```csharp
private class CompletionPromiseCache
{
    private readonly ConcurrentDictionary<string, AsyncLazy<CommandCompletion>> _promises;
    private readonly ChannelReader<PowerShell> _pwshPoolReader;
    private readonly BackgroundProcessor _pwshPool;

    public Task<CommandCompletion> GetCompletionFromAstAsync(
        Ast ast, Token[] tokens, IScriptPosition cursorPosition)
    {
        var key = $"{ast.GetHashCode()}:{cursorPosition.Offset}";

        var asyncLazy = _promises.GetOrAdd(key, k =>
            new AsyncLazy<CommandCompletion>(async () =>
            {
                PowerShell? pwsh = null;
                try
                {
                    // Checkout from pool
                    pwsh = await _pwshPoolReader.ReadAsync();

                    // USE AST OVERLOAD
                    var completion = CommandCompletion.CompleteInput(
                        ast, tokens, cursorPosition,
                        new Hashtable(), pwsh);

                    // ⭐ VALIDATE COMPLETIONS
                    var validated = ValidateCompletions(completion, pwsh);

                    return validated;
                }
                finally
                {
                    if (pwsh != null) _pwshPool.CheckIn(pwsh);

                    // TTL cleanup
                    _ = Task.Delay(TimeSpan.FromSeconds(30))
                        .ContinueWith(_ => _promises.TryRemove(key, out _));
                }
            })
        );

        return asyncLazy.Value;
    }

    private CommandCompletion ValidateCompletions(
        CommandCompletion completion, PowerShell pwsh)
    {
        if (completion?.CompletionMatches == null)
            return completion;

        var validatedMatches = new List<CompletionResult>();

        foreach (var match in completion.CompletionMatches)
        {
            // Parse completion to get AST
            var ast = Parser.ParseInput(
                match.CompletionText, out _, out var errors);

            if (errors.Length > 0) continue;

            var firstStatement = ast?.EndBlock?.Statements?.FirstOrDefault();
            if (firstStatement == null) continue;

            // Filter by AST type (like history validation)
            if (firstStatement is AssignmentStatementAst)
            {
                _logger.LogDebug($"Skip assignment: {match.CompletionText}");
                continue;
            }

            if (firstStatement is IfStatementAst)
            {
                _logger.LogDebug($"Skip if-statement: {match.CompletionText}");
                continue;
            }

            // Validate commands in pipelines
            if (firstStatement is PipelineAst pipeline)
            {
                bool allValid = true;
                foreach (var element in pipeline.PipelineElements)
                {
                    if (element is CommandAst cmd)
                    {
                        var cmdName = cmd.GetCommandName();
                        if (!IsValidCommand(cmdName, pwsh))
                        {
                            _logger.LogDebug($"Skip invalid cmd: {cmdName}");
                            allValid = false;
                            break;
                        }
                    }
                }
                if (!allValid) continue;
            }

            // Passed validation - keep with tooltip!
            validatedMatches.Add(match);
        }

        _logger.LogInfo($"Validated {validatedMatches.Count}/{completion.CompletionMatches.Count}");

        // Create new CommandCompletion with validated matches
        return new CommandCompletion(
            validatedMatches,
            completion.CurrentMatchIndex,
            completion.ReplacementIndex,
            completion.ReplacementLength);
    }

    private bool IsValidCommand(string cmdName, PowerShell pwsh)
    {
        if (string.IsNullOrWhiteSpace(cmdName)) return false;

        try
        {
            pwsh.Commands.Clear();
            pwsh.AddCommand("Get-Command")
                .AddParameter("Name", cmdName)
                .AddParameter("ErrorAction", "SilentlyContinue");

            var result = pwsh.Invoke();
            pwsh.Commands.Clear();

            return result?.Count > 0;
        }
        catch
        {
            return false;
        }
    }
}
```

**Key Points:**

- AsyncLazy pattern prevents duplicate work
- Validates each completion by parsing
- Filters by AST statement type
- Validates command existence in pipelines
- Preserves tooltips for AI context
- Returns new CommandCompletion with only validated matches

### 4. BackgroundProcessor (PowerShell Pool)

**File:** `BackgroundProcessor.cs`

```csharp
public class BackgroundProcessor : IDisposable
{
    private readonly Channel<PowerShell> _pwshPool;
    private readonly List<PowerShell> _instances;
    private readonly int _poolSize;

    public BackgroundProcessor(FastLogger logger, int poolSize = 4)
    {
        _pwshPool = Channel.CreateUnbounded<PowerShell>();

        // Initialize pool
        for (int i = 0; i < poolSize; i++)
        {
            var runspace = RunspaceFactory.CreateRunspace();
            runspace.Open();

            var pwsh = PowerShell.Create();
            pwsh.Runspace = runspace;

            // Pre-load common modules
            pwsh.AddScript(@"
                Import-Module PSReadLine -ErrorAction SilentlyContinue
                Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue
                Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
            ").Invoke();

            pwsh.Commands.Clear();
            pwsh.Streams.ClearStreams();

            _instances.Add(pwsh);
            _pwshPool.Writer.TryWrite(pwsh);
        }
    }

    public ChannelReader<PowerShell> GetPoolReader() => _pwshPool.Reader;

    public async Task<PowerShell> CheckOutAsync(CancellationToken ct = default)
    {
        return await _pwshPool.Reader.ReadAsync(ct);
    }

    public void CheckIn(PowerShell pwsh)
    {
        if (pwsh == null || _disposed) return;

        pwsh.Commands.Clear();
        pwsh.Streams.ClearStreams();
        _pwshPool.Writer.TryWrite(pwsh);
    }
}
```

**Key Points:**

- Channel-based pool (thread-safe)
- Each PowerShell has own runspace
- Pre-loads common modules
- Auto-cleanup on checkout/checkin
- No manual locking needed

## Data Flow Examples

### First keystroke "Get-C"

```
1. PSReadLine → GetSuggestion(context with AST for "Get-C")
2. PowerAugerPredictor:
   - Extract "Get-C" as cache key
   - Check hot cache → empty (first time)
   - Check trie → returns ["Get-ChildItem", "Get-Content", "Get-Command"] from InitializeCommonCompletions
   - Return these suggestions immediately
   - Parse tokens once for validation
   - Start async: GetCompletionsFromAstAsync(ast, tokens, pos)
3. CompletionPromiseCache (background):
   - Checkout PowerShell from pool
   - CommandCompletion.CompleteInput(AST overload)
   - Returns 15 completions
   - ValidateCompletions:
     * Parse each completion
     * Filter out: "$GetC = ..." (assignment)
     * Filter out: "if (Get-C..." (if-statement)
     * Validate: "Get-Command" → valid
     * Validate: "Get-ChildItem" → valid
     * Keep 12 validated completions with tooltips
   - Update trie with validated completions
   - Return PowerShell to pool
4. User sees: ["Get-ChildItem", "Get-Content", "Get-Command"] from common completions
```

### Second keystroke "Get-Ch"

```
1. PSReadLine → GetSuggestion(context with AST for "Get-Ch")
2. PowerAugerPredictor:
   - Extract "Get-Ch" as cache key
   - Check hot cache → empty
   - Check prediction cache → HIT! (from previous async)
   - Return ["Get-ChildItem"] immediately (0ms)
   - Previous async task already validated and cached it
   - Start new async enrichment for "Get-Ch"
3. User sees: instant suggestion from validated cache
```

### Validation Flow Detail

```
CommandCompletion returns 20 matches:
1. "Get-ChildItem"              → Valid (CommandAst, exists)         ✓
2. "Get-ChildItem -Path"        → Valid (CommandAst, exists)         ✓
3. "$GetCh = Get-ChildItem"     → Invalid (AssignmentStatementAst)   ✗
4. "Get-Command"                → Valid (CommandAst, exists)         ✓
5. "Get-Chocolate"              → Invalid (command doesn't exist)    ✗
6. "if (Get-Ch) { }"            → Invalid (IfStatementAst)           ✗
7. "Get-ChildItem | Where..."   → Valid (PipelineAst, all valid)    ✓
8. "Get-Ch-NonExistent"         → Invalid (command doesn't exist)    ✗
9. "Get-Checkpoint"             → Valid (CommandAst, exists)         ✓
...

Result: 12 validated completions with tooltips preserved
Cache: Only these 12 go into trie/hot cache
```

## OllamaService Integration (Planned)

### Chat Mode vs Generate Mode

```csharp
public enum CompletionMode
{
    Chat,      // /api/chat endpoint - conversational with context
    Generate   // /api/generate endpoint - FIM (fill-in-middle)
}

public async Task<string?> GetCompletionAsync(
    string input,
    CommandCompletion tabCompletions,  // Validated completions with tooltips
    List<string> historyExamples,
    CompletionMode mode = CompletionMode.Chat)
{
    switch (mode)
    {
        case CompletionMode.Chat:
            return await GetChatCompletionAsync(input, tabCompletions, historyExamples);

        case CompletionMode.Generate:
            return await GetGenerateCompletionAsync(input, tabCompletions, historyExamples);

        default:
            return null;
    }
}
```

### Chat Mode - Rich Context from Tooltips

```csharp
private async Task<string?> GetChatCompletionAsync(
    string input,
    CommandCompletion tabCompletions,
    List<string> historyExamples)
{
    // Build context from validated completions
    var contextBuilder = new StringBuilder();
    contextBuilder.AppendLine("Available PowerShell completions:");

    foreach (var match in tabCompletions.CompletionMatches.Take(10))
    {
        contextBuilder.AppendLine($"- {match.CompletionText}");

        // Tooltip has rich context: parameter syntax, types, documentation
        if (!string.IsNullOrEmpty(match.ToolTip))
        {
            contextBuilder.AppendLine($"  Info: {match.ToolTip}");
        }
    }

    // Add similar commands from history
    if (historyExamples.Count > 0)
    {
        contextBuilder.AppendLine("\nSimilar commands from your history:");
        foreach (var example in historyExamples.Take(3))
        {
            contextBuilder.AppendLine($"- {example}");
        }
    }

    // Build chat messages
    var messages = new[]
    {
        new {
            role = "system",
            content = "You are a PowerShell completion assistant. Suggest the most likely command completion based on available completions and history."
        },
        new {
            role = "user",
            content = contextBuilder.ToString()
        },
        new {
            role = "user",
            content = $"Complete this command: {input}"
        }
    };

    var requestBody = new
    {
        model = _modelName,
        messages = messages,
        stream = false,
        options = new
        {
            num_predict = 80,
            temperature = 0.2,
            top_p = 0.9
        }
    };

    // Call /api/chat endpoint
    var response = await _httpClient.PostAsJsonAsync(
        "http://127.0.0.1:11434/api/chat",
        requestBody,
        cancellationToken);

    // Parse response...
    return completion;
}
```

### Generate Mode - FIM with Context

```csharp
private async Task<string?> GetGenerateCompletionAsync(
    string input,
    CommandCompletion tabCompletions,
    List<string> historyExamples)
{
    // Build FIM prompt with few-shot examples
    var promptBuilder = new StringBuilder();
    promptBuilder.AppendLine($"# PowerShell - {Environment.CurrentDirectory}");

    // Add few-shot examples from history
    foreach (var example in historyExamples.Take(3))
    {
        promptBuilder.AppendLine($"<|fim_prefix|>{ExtractPrefix(example)}<|fim_suffix|><|fim_middle|>{example}");
    }

    // Add context from validated completions
    if (tabCompletions.CompletionMatches.Count > 0)
    {
        promptBuilder.AppendLine("# Available completions:");
        foreach (var match in tabCompletions.CompletionMatches.Take(5))
        {
            promptBuilder.AppendLine($"# - {match.CompletionText}");
        }
    }

    // Add actual FIM prompt
    promptBuilder.AppendLine($"<|fim_prefix|>{input}<|fim_suffix|><|fim_middle|>");

    var requestBody = new
    {
        model = _modelName,
        prompt = promptBuilder.ToString(),
        stream = false,
        options = new
        {
            num_predict = 80,
            temperature = 0.2,
            top_p = 0.9
        }
    };

    // Call /api/generate endpoint
    var response = await _httpClient.PostAsJsonAsync(
        "http://127.0.0.1:11434/api/generate",
        requestBody,
        cancellationToken);

    // Parse response...
    return completion;
}
```

### History Integration

```csharp
// In PowerAugerPredictor or OllamaService
private List<string> GetFewShotExamples(string input, FastCompletionStore store)
{
    // Get similar commands from history
    var examples = store.GetFewShotExamples(input, maxExamples: 3);

    // Filter using same validation logic
    var validated = new List<string>();
    foreach (var example in examples)
    {
        var ast = Parser.ParseInput(example, out _, out var errors);
        if (errors.Length > 0) continue;

        var firstStatement = ast?.EndBlock?.Statements?.FirstOrDefault();
        if (firstStatement == null) continue;

        // Skip assignments and if-statements
        if (firstStatement is AssignmentStatementAst) continue;
        if (firstStatement is IfStatementAst) continue;

        validated.Add(example);
    }

    return validated;
}
```

**Key Points:**

- Tooltips provide parameter syntax and documentation
- History examples are validated before use
- Chat mode gets conversational context
- Generate mode uses FIM with few-shot examples
- Both modes benefit from AST validation

## Thread Safety Model

### Current: BackgroundProcessor with Channel Pool

```csharp
Channel<PowerShell> _pwshPool;  // Thread-safe by design

// Checkout
var pwsh = await _pwshPool.Reader.ReadAsync();  // Blocks if pool empty

// Use (single thread has exclusive access)
var completion = CommandCompletion.CompleteInput(..., pwsh);

// Return
_pwshPool.Writer.TryWrite(pwsh);  // Make available to other threads
```

**Benefits:**

- No manual locking needed - Channel handles all synchronization
- Multiple async tasks can run concurrently (up to pool size of 4)
- Automatic queuing when pool exhausted
- Explicit checkout/checkin pattern
- Better observability (can track pool usage)

**Current Implementation:**

- 4 PowerShell instances in pool
- Each has own Runspace (CreateDefault)
- Pre-loads PSReadLine, Management, Utility modules
- CheckOut/CheckIn with automatic cleanup

**Trade-offs:**

- Each PowerShell instance has own runspace
- Runspaces created with InitialSessionState.CreateDefault()
- Missing some context from interactive session (66% success rate observed)
- But: Still provides validated completions with tooltips

### Alternative: RunspacePool

RunspacePool was considered but BackgroundProcessor + Channel provides same thread safety with more control:

- Explicit lifecycle management
- Better error handling
- Can extend with metrics/logging
- Same thread safety guarantees

Both patterns are valid - current implementation uses Channel for flexibility.

## Implementation Plan

### Current State (Already Implemented)

✅ **Core Infrastructure:**

- BackgroundProcessor with Channel<PowerShell> pool (4 instances)
- FastCompletionStore with multi-layer caching
- CompletionPromiseCache using AST overload
- AsyncLazy pattern for promise caching
- PowerAugerPredictor with async enrichment pattern

✅ **AST Integration:**

- GetCompletionsFromAstAsync using AST overload
- Tokens parsed once in GetSuggestion
- Progressive enhancement (cache → async enrichment)

### Phase 1: Add AST Validation (Next)

**Task 1.1:** Add ValidateCompletions to CompletionPromiseCache

```csharp
// In FastCompletionStore.cs, CompletionPromiseCache class
private CommandCompletion ValidateCompletions(
    CommandCompletion completion, PowerShell pwsh)
{
    // Filter assignments, if-statements
    // Validate commands in pipelines
    // Return new CommandCompletion with validated matches
}

private bool IsValidCommand(string cmdName, PowerShell pwsh)
{
    // Use Get-Command to verify existence
}
```

**Task 1.2:** Update GetCompletionFromAstAsync to call validation

```csharp
var completion = CommandCompletion.CompleteInput(ast, tokens, cursorPosition, new Hashtable(), pwsh);
var validated = ValidateCompletions(completion, pwsh);  // ⭐ Add this
return validated;
```

**Testing:**

- Verify assignments filtered out
- Verify if-statements filtered out
- Verify invalid commands filtered out
- Verify valid completions kept with tooltips intact
- Check logs for validation statistics

### Phase 2: Integrate OllamaService with Validated Completions

**Task 2.1:** Update OllamaService signature

```csharp
public enum CompletionMode { Chat, Generate }

public async Task<string?> GetCompletionAsync(
    string input,
    CommandCompletion tabCompletions,  // Change from List<string>
    List<string> historyExamples,
    CompletionMode mode = CompletionMode.Chat)
```

**Task 2.2:** Implement GetChatCompletionAsync

```csharp
private async Task<string?> GetChatCompletionAsync(
    string input,
    CommandCompletion tabCompletions,
    List<string> historyExamples)
{
    // Build context using tooltips from validated completions
    // Call /api/chat endpoint
}
```

**Task 2.3:** Implement GetGenerateCompletionAsync

```csharp
private async Task<string?> GetGenerateCompletionAsync(
    string input,
    CommandCompletion tabCompletions,
    List<string> historyExamples)
{
    // Build FIM prompt with few-shot examples
    // Include validated completions as context
    // Call /api/generate endpoint
}
```

**Task 2.4:** Add GetFewShotExamples with validation

```csharp
private List<string> GetFewShotExamples(string input, FastCompletionStore store)
{
    var examples = store.GetFewShotExamples(input, maxExamples: 3);
    // Validate using same AST logic
    return validated;
}
```

**Testing:**

- Test Chat mode with tooltip context
- Test Generate mode with FIM
- Verify history examples are validated
- Check prompt quality improvements

### Phase 3: History Loading and Cache Building

**Task 3.1:** Restore PowerShellHistoryLoader functionality

```csharp
public class PowerShellHistoryLoader
{
    public static List<string> LoadValidatedHistory()
    {
        var historyPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            "AppData\\Roaming\\Microsoft\\Windows\\PowerShell\\PSReadLine\\ConsoleHost_history.txt");

        var lines = File.ReadAllLines(historyPath);
        var validated = new List<string>();

        foreach (var line in lines)
        {
            var ast = Parser.ParseInput(line, out _, out var errors);
            if (errors.Length > 0) continue;

            var firstStatement = ast?.EndBlock?.Statements?.FirstOrDefault();
            if (firstStatement == null) continue;

            // Filter assignments, if-statements
            if (firstStatement is AssignmentStatementAst) continue;
            if (firstStatement is IfStatementAst) continue;

            // Validate commands
            if (firstStatement is PipelineAst pipeline)
            {
                bool allValid = true;
                foreach (var element in pipeline.PipelineElements)
                {
                    if (element is CommandAst cmd)
                    {
                        if (!IsCommandValid(cmd.GetCommandName()))
                        {
                            allValid = false;
                            break;
                        }
                    }
                }
                if (!allValid) continue;
            }

            validated.Add(line);
        }

        return validated;
    }
}
```

**Task 3.2:** Populate FastCompletionStore on startup

```csharp
// In PowerAugerPredictor constructor
private void InitializeHistoryCache()
{
    _ = Task.Run(async () =>
    {
        var history = PowerShellHistoryLoader.LoadValidatedHistory();
        foreach (var line in history)
        {
            _completionStore.AddHistoryItem(line);
        }
        _logger.LogInfo($"Loaded {history.Count} validated history commands");
    });
}
```

**Testing:**

- Verify history file loads correctly
- Check validation filters work
- Verify trie populated with history
- Test GetFewShotExamples uses validated history

### Phase 4: Remove Fallback Patterns

**Task 4.1:** Remove GetFallbackCompletions from FastCompletionStore

```csharp
// Delete this method - rely only on validated completions
```

**Task 4.2:** Update GetCompletions to return empty instead of fallback

```csharp
// Layer 4: Trie lookup
var trieCompletions = _trie.GetCompletions(prefix, maxResults);
if (trieCompletions.Count > 0)
    return trieCompletions;

// No Layer 5 fallback - return empty
return new List<string>();
```

**Testing:**

- Verify no hardcoded patterns returned
- Check that validated completions fill gaps
- Test behavior with empty cache (initial state)

### Phase 5: Performance Tuning and Monitoring

**Task 5.1:** Add metrics collection

```csharp
public class CompletionMetrics
{
    public int CacheHits { get; set; }
    public int CacheMisses { get; set; }
    public int ValidationFiltered { get; set; }
    public int ValidationPassed { get; set; }
    public TimeSpan AvgValidationTime { get; set; }
}
```

**Task 5.2:** Log validation statistics

```csharp
// In ValidateCompletions
var sw = Stopwatch.StartNew();
// ... validation logic ...
sw.Stop();
_logger.LogInfo($"Validated {validatedMatches.Count}/{completion.CompletionMatches.Count} in {sw.ElapsedMilliseconds}ms");
```

**Task 5.3:** Monitor pool utilization

```csharp
// In BackgroundProcessor
public int AvailableInstances => _pwshPool.Reader.Count;
```

**Testing:**

- Collect baseline metrics
- Identify performance bottlenecks
- Tune pool size if needed
- Optimize validation if too slow

### Success Criteria

**Validation Working:**

- [ ] Assignments filtered out (0% in cache)
- [ ] If-statements filtered out (0% in cache)
- [ ] Invalid commands filtered out
- [ ] Valid completions kept with tooltips
- [ ] Validation takes <15ms per completion set

**AI Integration Working:**

- [ ] Chat mode uses tooltip context
- [ ] Generate mode uses FIM with examples
- [ ] History examples validated before use
- [ ] AI suggestions improve over baseline

**Performance Acceptable:**

- [ ] GetSuggestion returns in <5ms (synchronous path)
- [ ] Background validation completes in <60ms
- [ ] Cache hit rate >70% after warmup
- [ ] No typing lag introduced

**User Experience:**

- [ ] First keystroke shows cached/common completions
- [ ] Subsequent keystrokes show validated TabExpansion2 results
- [ ] AI suggestions are contextually appropriate
- [ ] No junk suggestions (assignments, if-statements)

## Testing Strategy

### Unit Tests

```csharp
[Test]
public void TestAstValidation_FiltersAssignments()
{
    var completion = CreateMockCompletion(new[] {
        "Get-ChildItem",
        "$var = Get-ChildItem",  // Should be filtered
        "Get-Content"
    });

    var validated = ValidateCompletions(completion, pwsh);

    Assert.AreEqual(2, validated.CompletionMatches.Count);
    Assert.False(validated.CompletionMatches.Any(m => m.CompletionText.Contains("$var")));
}

[Test]
public void TestAstValidation_FiltersInvalidCommands()
{
    var completion = CreateMockCompletion(new[] {
        "Get-ChildItem",
        "Get-NonExistentCommand",  // Should be filtered
        "Get-Content"
    });

    var validated = ValidateCompletions(completion, pwsh);

    Assert.AreEqual(2, validated.CompletionMatches.Count);
    Assert.False(validated.CompletionMatches.Any(m => m.CompletionText.Contains("NonExistent")));
}

[Test]
public void TestAstValidation_PreservesTooltips()
{
    var completion = CommandCompletion.CompleteInput("Get-Ch", 6, null, pwsh);
    var validated = ValidateCompletions(completion, pwsh);

    // Verify tooltips not lost during validation
    foreach (var match in validated.CompletionMatches)
    {
        Assert.IsNotNull(match.ToolTip);
        Assert.IsNotEmpty(match.ToolTip);
    }
}

[Test]
public async Task TestChannelPoolThreadSafety()
{
    // Start 10 concurrent validation tasks
    var tasks = Enumerable.Range(0, 10).Select(_ =>
        Task.Run(async () =>
        {
            var pwsh = await _pwshPool.CheckOutAsync();
            var completion = CommandCompletion.CompleteInput("Get-Ch", 6, null, pwsh);
            _pwshPool.CheckIn(pwsh);
            return completion.CompletionMatches.Count;
        })
    ).ToArray();

    var results = await Task.WhenAll(tasks);

    // All should succeed
    Assert.True(results.All(r => r > 0));
}
```

### Integration Tests

```csharp
[Test]
public async Task TestEndToEndFlow()
{
    var predictor = PowerAugerPredictor.Instance;

    // Simulate PSReadLine calling GetSuggestion
    var input = "Get-Ch";
    var ast = Parser.ParseInput(input, out var tokens, out _);
    var context = new PredictionContext
    {
        InputAst = ast,
        Tokens = tokens,
        CursorPosition = ast.Extent.EndScriptPosition
    };

    // First call - may return cached/common completions
    var result1 = predictor.GetSuggestion(null, context, CancellationToken.None);

    // Wait for async enrichment
    await Task.Delay(100);

    // Second call - should have validated TabExpansion2 results
    var result2 = predictor.GetSuggestion(null, context, CancellationToken.None);

    Assert.Greater(result2.SuggestionEntries.Count, 0);
    Assert.True(result2.SuggestionEntries.Any(s => s.SuggestionText == "Get-ChildItem"));
}

[Test]
public void TestHistoryValidation()
{
    var history = new[]
    {
        "Get-ChildItem",
        "$var = 123",  // Should be filtered
        "if ($true) { }",  // Should be filtered
        "Get-Content test.txt",
        "Get-NonExistent",  // Should be filtered
    };

    var validated = new List<string>();
    foreach (var line in history)
    {
        var ast = Parser.ParseInput(line, out _, out var errors);
        if (errors.Length > 0) continue;

        var firstStatement = ast?.EndBlock?.Statements?.FirstOrDefault();
        if (firstStatement is AssignmentStatementAst) continue;
        if (firstStatement is IfStatementAst) continue;

        validated.Add(line);
    }

    Assert.AreEqual(2, validated.Count);  // Only Get-ChildItem and Get-Content
}
```

### Performance Benchmarks

```csharp
[Benchmark]
public void BenchmarkValidation()
{
    var completion = CommandCompletion.CompleteInput("Get-Ch", 6, null, pwsh);
    var validated = ValidateCompletions(completion, pwsh);
}

[Benchmark]
public void BenchmarkCacheLookup()
{
    var completions = _completionStore.GetCompletions("Get-Ch", 3);
}

[Benchmark]
public async Task BenchmarkAsyncCompletion()
{
    var ast = Parser.ParseInput("Get-Ch", out var tokens, out _);
    var pos = ast.Extent.EndScriptPosition;
    var completions = await _completionStore.GetCompletionsFromAstAsync(ast, tokens, pos, 5);
}
```

**Target Benchmarks:**

- Cache lookup: <2ms
- Validation: <15ms for 20 completions
- Async completion (full cycle): <60ms

## Key Advantages

1. **AST-Based Validation** - Only cache useful completions, filter out noise

   - No assignments, if-statements in suggestions
   - Only valid commands that actually exist
   - Preserves tooltips with parameter documentation

2. **Rich Context for AI** - Tooltips provide syntax and documentation

   - Better prompt engineering with actual parameter info
   - Few-shot examples validated before use
   - Both Chat and Generate modes benefit

3. **Multi-Layer Caching** - Progressive enhancement without blocking

   - Prediction cache (3s TTL) for recent
   - Hot cache (200 prefixes) for common
   - Trie for comprehensive history
   - All layers populated with validated completions only

4. **Thread-Safe by Design** - Channel-based pool, no manual locking

   - 4 PowerShell instances available concurrently
   - Automatic queuing and checkout
   - No race conditions or deadlocks

5. **Async-First Pattern** - Never blocks user typing

   - Synchronous fast path <5ms
   - Background enrichment updates cache
   - Results available on next keystroke

6. **Quality Over Quantity** - Validated completions only
   - History loader filters before caching
   - TabExpansion2 results validated before caching
   - No junk completions from hardcoded patterns

## Limitations and Trade-offs

### Current Known Issues

1. **Background Runspace Context** - 66% success rate observed

   - Background runspaces created with InitialSessionState.CreateDefault()
   - Missing some modules/context from interactive session
   - Still provides validated completions, but not all possible ones
   - Acceptable trade-off for thread safety

2. **First Keystroke May Be Empty** - Progressive enhancement

   - If cache cold and prefix unknown, first keystroke returns nothing
   - Background enrichment populates cache for subsequent keystrokes
   - Mitigated by InitializeCommonCompletions for Get-, Set-, etc.

3. **Validation Overhead** - 5-15ms per completion set

   - Each completion must be parsed for AST analysis
   - Command validation requires Get-Command per unique command
   - Acceptable cost given async background execution

4. **Memory Overhead** - 4 PowerShell instances + runspaces
   - Each instance ~10-20MB
   - Total pool overhead ~40-80MB
   - Acceptable for modern systems

### Design Trade-offs

**AST Context vs String Keys:**

- Using string prefixes for cache keys
- AST context partially lost (can't serialize ASTs)
- But enables persistence and simple trie structure
- Trade-off accepted for simplicity

**Validation Strictness:**

- Current: Filter assignments, if-statements, invalid commands
- Future: Could add more sophisticated heuristics
- Balance quality vs. over-filtering

**Pool Size:**

- Current: 4 instances
- Could increase for higher concurrency
- Could decrease to reduce memory
- 4 seems optimal for typical usage

## Questions to Validate

### Performance Questions

1. ✅ **Is async pattern working?**

   - Yes - GetSuggestion returns <5ms, background enrichment doesn't block

2. ⚠️ **Is background runspace 66% success acceptable?**

   - Currently yes - still provides validated completions
   - Could investigate importing more modules to improve
   - May need to test if module loading impacts performance

3. **Is validation overhead acceptable?**

   - Need to benchmark: Current estimate 5-15ms per set
   - Target: <15ms for 20 completions
   - Need actual measurement

4. **What's optimal pool size?**
   - Current: 4 instances
   - Need to test under heavy typing load
   - Monitor pool exhaustion rate

### Quality Questions

1. **Does validation improve suggestions?**

   - Need A/B testing: with vs without validation
   - Measure: % of accepted suggestions
   - Measure: User satisfaction

2. **Are tooltips improving AI context?**

   - Test Chat mode with vs without tooltips
   - Measure prompt effectiveness
   - Qualitative assessment of AI suggestions

3. **Is history validation effective?**
   - Measure: % of history commands filtered
   - Verify: No junk in few-shot examples
   - Test: AI suggestions using validated history

### UX Questions

1. **Is progressive enhancement acceptable?**

   - First keystroke: May show common completions or nothing
   - Second keystroke: Shows validated results
   - Need user testing: Is delay noticeable/annoying?

2. **Are common completions sufficient for cold start?**

   - InitializeCommonCompletions provides Get-, Set-, cd, ls, etc.
   - Is this enough for first keystroke experience?

3. **Is validation filtering too aggressive?**
   - Are we filtering out useful completions?
   - Should we keep some assignments (e.g., common patterns)?
   - Need usage data to tune filter rules

# lint when done
