using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Text.Json;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace PowerAuger
{
    public sealed class FastCompletionStore : IDisposable
    {
        // Use FrecencyStore as our storage backend
        private readonly FrecencyStore _frecencyStore;

        // Promise cache for AST-based completions (this validates and enriches)
        private readonly CompletionPromiseCache _promiseCache;

        // Ollama service for AI completions
        private readonly OllamaService _ollamaService;

        private readonly FastLogger _logger;
        private readonly BackgroundProcessor _pwshPool;
        private readonly CommandHistoryStore _commandHistory;

        public FastCompletionStore(FastLogger logger, BackgroundProcessor pwshPool, FrecencyStore frecencyStore, CommandHistoryStore commandHistory)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _pwshPool = pwshPool ?? throw new ArgumentNullException(nameof(pwshPool));
            _frecencyStore = frecencyStore ?? throw new ArgumentNullException(nameof(frecencyStore));
            _commandHistory = commandHistory ?? throw new ArgumentNullException(nameof(commandHistory));

            // Initialize Ollama service for AI completions
            _ollamaService = new OllamaService(logger);

            // Initialize promise cache with PowerShell pool, FrecencyStore, CommandHistory, and OllamaService
            _promiseCache = new CompletionPromiseCache(logger, pwshPool.GetPoolReader(), pwshPool, frecencyStore, commandHistory, _ollamaService);

            _logger.LogInfo("FastCompletionStore initialized with FrecencyStore backend");
        }

        /// <summary>
        /// Get completions using already-parsed AST from PSReadLine
        /// </summary>
        public async Task<List<string>> GetCompletionsFromAstAsync(
            Ast ast,
            Token[] tokens,
            IScriptPosition cursorPosition,
            int maxResults = 3)
        {
            if (ast == null)
                return new List<string>();

            try
            {
                // Try to get Ollama-enhanced completions
                var commandCompletion = await _promiseCache.GetCompletionFromAstAsync(ast, tokens, cursorPosition);

                if (commandCompletion?.CompletionMatches != null && commandCompletion.CompletionMatches.Count > 0)
                {
                    // Extract validated completion texts
                    var validatedResults = commandCompletion.CompletionMatches
                        .Select(m => m.CompletionText)
                        .Take(maxResults)
                        .ToList();

                    // Add validated Ollama results to FrecencyStore with high priority
                    foreach (var result in validatedResults)
                    {
                        _frecencyStore.AddCommand(result, 5.0f); // High initial rank for AI completions
                    }

                    _logger.LogDebug($"Returning {validatedResults.Count} Ollama completions");
                    return validatedResults;
                }

                // Ollama returned null - fall back to PowerShell native completions
                // Get native completions without Ollama
                var nativeCompletion = await GetNativeCompletionsAsync(ast, tokens, cursorPosition);

                if (nativeCompletion?.CompletionMatches != null && nativeCompletion.CompletionMatches.Count > 0)
                {
                    // Don't validate native completions - trust PowerShell
                    // Just take top results ordered by frecency if we have history
                    var results = nativeCompletion.CompletionMatches
                        .OrderByDescending(m => _frecencyStore.GetScore(m.CompletionText))
                        .Take(maxResults)
                        .Select(m => m.CompletionText)
                        .ToList();

                    // Add to cache with normal priority (not AI-enhanced)
                    foreach (var result in results)
                    {
                        _frecencyStore.AddCommand(result, 2.0f); // Normal priority for native completions
                    }

                    _logger.LogDebug($"Returning {results.Count} native completions (Ollama unavailable)");
                    return results;
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning($"Completion pipeline failed: {ex.Message}");
            }

            // No completions available
            return new List<string>();
        }

        /// <summary>
        /// Get native PowerShell completions without Ollama
        /// </summary>
        private async Task<CommandCompletion?> GetNativeCompletionsAsync(
            Ast ast,
            Token[] tokens,
            IScriptPosition cursorPosition)
        {
            PowerShell? pwsh = null;
            try
            {
                // Check out PowerShell instance from pool
                var poolReader = _pwshPool.GetPoolReader();
                pwsh = await poolReader.ReadAsync();

                // Get native PowerShell completions
                var completion = CommandCompletion.CompleteInput(
                    ast,
                    tokens,
                    cursorPosition,
                    new Hashtable(),
                    pwsh);

                return completion;
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to get native completions: {ex.Message}");
                return null;
            }
            finally
            {
                if (pwsh != null)
                {
                    _pwshPool.CheckIn(pwsh);
                }
            }
        }

        /// <summary>
        /// Get completions synchronously from FrecencyStore (fast path)
        /// </summary>
        public List<string> GetCompletions(string prefix, int maxResults = 3)
        {
            // Simply delegate to FrecencyStore
            return _frecencyStore.GetTopCommands(prefix, maxResults);
        }

        public void RecordAcceptance(string commandLine)
        {
            // Increment rank in FrecencyStore
            _frecencyStore.IncrementRank(commandLine, 2.0f);
        }

        public void RecordExecution(string commandLine)
        {
            // Higher rank for executed commands
            _frecencyStore.IncrementRank(commandLine, 3.0f);
        }

        public void RecordSuggestionAcceptance(string suggestion)
        {
            // Small boost for accepted suggestions
            _frecencyStore.IncrementRank(suggestion, 1.0f);
        }

        public void AddHistoryItem(string historyLine)
        {
            if (string.IsNullOrWhiteSpace(historyLine))
                return;

            // Add to FrecencyStore with base priority
            _frecencyStore.AddCommand(historyLine, 1.0f);
        }

        /// <summary>
        /// Get few-shot examples from history for a given input
        /// </summary>
        public List<string> GetFewShotExamples(string input, int maxExamples = 3)
        {
            // Try to find similar commands in history using FrecencyStore
            var prefix = ExtractCommandName(input);
            if (string.IsNullOrEmpty(prefix))
                prefix = input;

            // Get top commands from FrecencyStore based on prefix
            var examples = _frecencyStore.GetTopCommands(prefix, maxExamples);

            // If no matches with prefix, try with just the first word
            if (examples.Count == 0 && input.Contains(' '))
            {
                var firstWord = input.Split(' ')[0];
                examples = _frecencyStore.GetTopCommands(firstWord, maxExamples);
            }

            return examples;
        }

        private static string ExtractCommandName(string commandLine)
        {
            if (string.IsNullOrWhiteSpace(commandLine))
                return string.Empty;

            var spaceIndex = commandLine.IndexOf(' ');
            return spaceIndex > 0 ? commandLine.Substring(0, spaceIndex) : commandLine;
        }

        public void Dispose()
        {
            // Dispose of managed resources
            _ollamaService?.Dispose();
        }

        #region Embedded CompletionPromiseCache

        /// <summary>
        /// Promise-based cache for AST command completions
        /// </summary>
        private class CompletionPromiseCache
        {
            private readonly ConcurrentDictionary<string, AsyncLazy<CommandCompletion?>> _promises;
            private readonly ChannelReader<PowerShell> _pwshPoolReader;
            private readonly BackgroundProcessor _pwshPool;
            private readonly FrecencyStore _frecencyStore;
            private readonly CommandHistoryStore _commandHistory;
            private readonly OllamaService _ollamaService;
            private readonly FastLogger _logger;

            public CompletionPromiseCache(FastLogger logger, ChannelReader<PowerShell> pwshPoolReader, BackgroundProcessor pwshPool, FrecencyStore frecencyStore, CommandHistoryStore commandHistory, OllamaService ollamaService)
            {
                _logger = logger;
                _pwshPoolReader = pwshPoolReader;
                _pwshPool = pwshPool;
                _frecencyStore = frecencyStore;
                _commandHistory = commandHistory;
                _ollamaService = ollamaService;
                _promises = new ConcurrentDictionary<string, AsyncLazy<CommandCompletion?>>();
            }

            private async Task<string?[]> GetParallelOllamaCompletionsAsync(
                string input,
                CommandCompletion? tabCompletions,
                List<string> history)
            {
                _logger.LogDebug("Starting parallel Ollama calls (Generate + Chat)");

                var generateTask = _ollamaService.GetCompletionAsync(
                    input, tabCompletions, history,
                    CompletionMode.Generate, CancellationToken.None);

                var chatTask = _ollamaService.GetCompletionAsync(
                    input, tabCompletions, history,
                    CompletionMode.Chat, CancellationToken.None);

                var sw = System.Diagnostics.Stopwatch.StartNew();
                var results = await Task.WhenAll(generateTask, chatTask);
                sw.Stop();

                var successCount = results.Count(r => !string.IsNullOrEmpty(r));
                _logger.LogDebug($"Ollama calls completed in {sw.ElapsedMilliseconds}ms ({successCount}/{results.Length} succeeded)");

                return results;
            }

            private CommandCompletion? BuildOllamaCompletion(
                string?[] ollamaResults,
                CommandCompletion? tabCompletions,
                IScriptPosition cursorPosition)
            {
                var allMatches = ollamaResults
                    .Select((result, index) => new { result, mode = index == 0 ? "Generate" : "Chat" })
                    .Where(x => !string.IsNullOrEmpty(x.result))
                    .Select(x =>
                    {
                        var matchingTab = tabCompletions?.CompletionMatches
                            ?.FirstOrDefault(m => m.CompletionText.Equals(x.result,
                                StringComparison.OrdinalIgnoreCase));

                        var tooltip = matchingTab?.ToolTip ??
                            $"AI suggestion from Ollama ({x.mode} mode)";

                        return new CompletionResult(
                            x.result, x.result,
                            CompletionResultType.Command, tooltip);
                    })
                    .ToList();

                if (allMatches.Count == 0)
                {
                    _logger.LogDebug("No valid Ollama results returned");
                    return null;
                }

                _logger.LogInfo($"Built CommandCompletion from {allMatches.Count} Ollama suggestions");

                return new CommandCompletion(
                    new System.Collections.ObjectModel.Collection<CompletionResult>(allMatches),
                    0, cursorPosition.Offset, allMatches[0].CompletionText.Length);
            }

            public Task<CommandCompletion?> GetCompletionFromAstAsync(
                Ast ast,
                Token[] tokens,
                IScriptPosition cursorPosition)
            {
                // Use AST hash and cursor position for cache key
                var key = $"{ast.GetHashCode()}:{cursorPosition.Offset}";

                var asyncLazy = _promises.GetOrAdd(key, k =>
                    new AsyncLazy<CommandCompletion?>(async () =>
                    {
                        PowerShell? pwsh = null;
                        try
                        {
                            // Check out PowerShell instance from pool
                            pwsh = await _pwshPoolReader.ReadAsync();

                            // USE AST OVERLOAD - no parsing needed!
                            var completion = CommandCompletion.CompleteInput(
                                ast,                    // Already parsed from PSReadLine
                                tokens,                 // Already tokenized
                                cursorPosition,         // IScriptPosition from context
                                new Hashtable(),        // Options
                                pwsh);                  // PowerShell instance from pool

                            // Extract input string from AST up to cursor position
                            var input = ast.Extent.Text;
                            if (cursorPosition.Offset <= input.Length)
                            {
                                input = input.Substring(0, cursorPosition.Offset);
                            }

                            // Get recent unfiltered history (for context - what user is doing)
                            var recentHistory = _commandHistory.GetRecentCommands(10);

                            // Get relevant filtered examples (for patterns - what should be suggested)
                            var relevantExamples = _frecencyStore.GetTopCommands(input.Trim(), 5);

                            // Combine for current API
                            var combinedHistory = new List<string>();
                            combinedHistory.AddRange(recentHistory);
                            combinedHistory.AddRange(relevantExamples);

                            // Call BOTH Ollama modes in parallel (Generate + Chat)
                            _logger.LogDebug($"Calling Ollama with {recentHistory.Count} recent + {relevantExamples.Count} relevant examples");

                            var ollamaResults = await GetParallelOllamaCompletionsAsync(
                                input, completion, combinedHistory);

                            // Build CommandCompletion from all Ollama results
                            var ollamaCompletion = BuildOllamaCompletion(
                                ollamaResults, completion, cursorPosition);

                            if (ollamaCompletion == null)
                            {
                                _logger.LogInfo("No Ollama results returned, caller should use fallback");
                                return null;
                            }

                            // Validate all Ollama suggestions (sequential using same pwsh)
                            var validatedOllama = ValidateCompletions(ollamaCompletion, pwsh);

                            if (validatedOllama?.CompletionMatches?.Count > 0)
                            {
                                _logger.LogDebug($"Returning {validatedOllama.CompletionMatches.Count} validated Ollama suggestions");
                                return validatedOllama;
                            }

                            // IMPORTANT: We intentionally return null when Ollama fails/invalid
                            // This signals to the caller that no AI-enhanced completion is available
                            // The caller should then use fallback strategies (cache, native completions, etc.)
                            _logger.LogInfo("All Ollama suggestions failed validation, caller should use fallback");
                            return null;
                        }
                        catch (Exception ex)
                        {
                            _logger.LogError($"AST completion failed: {ex.Message}");
                            return null;
                        }
                        finally
                        {
                            // Return PowerShell to pool
                            if (pwsh != null)
                            {
                                _pwshPool.CheckIn(pwsh);
                            }

                            // Clean up promise after TTL
                            _ = Task.Delay(TimeSpan.FromSeconds(30))
                                .ContinueWith(_ =>
                                {
                                    AsyncLazy<CommandCompletion?>? removed;
                                    _promises.TryRemove(key, out removed);
                                });
                        }
                    })
                );

                return asyncLazy.Value;
            }

            /// <summary>
            /// Validates completions by filtering out assignments, if-statements, and invalid commands
            /// </summary>
            private CommandCompletion? ValidateCompletions(
                CommandCompletion? completion, PowerShell pwsh)
            {
                if (completion?.CompletionMatches == null || completion.CompletionMatches.Count == 0)
                    return completion;

                var validatedMatches = new List<CompletionResult>();

                foreach (var match in completion.CompletionMatches)
                {
                    try
                    {
                        // Parse completion to get AST
                        var parsedAst = Parser.ParseInput(
                            match.CompletionText, out _, out var errors);

                        if (errors.Length > 0)
                        {
                            _logger.LogDebug($"Skip completion with parse errors: {match.CompletionText}");
                            continue;
                        }

                        var firstStatement = parsedAst?.EndBlock?.Statements?.FirstOrDefault();
                        if (firstStatement == null)
                        {
                            _logger.LogDebug($"Skip completion with no statements: {match.CompletionText}");
                            continue;
                        }

                        // Filter by AST type
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
                                        _logger.LogDebug($"Skip invalid command: {cmdName} in {match.CompletionText}");
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
                    catch (Exception ex)
                    {
                        _logger.LogWarning($"Error validating completion '{match.CompletionText}': {ex.Message}");
                        // On error, skip this completion
                        continue;
                    }
                }

                _logger.LogInfo($"Validated {validatedMatches.Count}/{completion.CompletionMatches.Count} completions");

                // Create new CommandCompletion with validated matches
                return new CommandCompletion(
                    new System.Collections.ObjectModel.Collection<CompletionResult>(validatedMatches),
                    completion.CurrentMatchIndex,
                    completion.ReplacementIndex,
                    completion.ReplacementLength);
            }

            /// <summary>
            /// Checks if a command name is valid using Get-Command
            /// </summary>
            private bool IsValidCommand(string cmdName, PowerShell pwsh)
            {
                if (string.IsNullOrWhiteSpace(cmdName))
                    return false;

                try
                {
                    pwsh.Commands.Clear();
                    pwsh.AddCommand("Get-Command")
                        .AddParameter("Name", cmdName)
                        .AddParameter("ErrorAction", "SilentlyContinue");

                    var result = pwsh.Invoke();
                    pwsh.Commands.Clear();
                    pwsh.Streams.ClearStreams();

                    return result?.Count > 0;
                }
                catch (Exception ex)
                {
                    _logger.LogDebug($"Error checking command validity for '{cmdName}': {ex.Message}");
                    return false;
                }
            }
        }

        /// <summary>
        /// Async lazy initialization helper
        /// </summary>
        private class AsyncLazy<T> : Lazy<Task<T>>
        {
            public AsyncLazy(Func<Task<T>> taskFactory) :
                base(() => Task.Run(taskFactory),
                     LazyThreadSafetyMode.ExecutionAndPublication)
            { }
        }

        #endregion
    }
}