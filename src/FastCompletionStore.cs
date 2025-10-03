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

        public FastCompletionStore(FastLogger logger, BackgroundProcessor pwshPool, FrecencyStore frecencyStore)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _pwshPool = pwshPool ?? throw new ArgumentNullException(nameof(pwshPool));
            _frecencyStore = frecencyStore ?? throw new ArgumentNullException(nameof(frecencyStore));

            // Initialize promise cache with PowerShell pool and FrecencyStore
            _promiseCache = new CompletionPromiseCache(logger, pwshPool.GetPoolReader(), pwshPool, frecencyStore);

            // Initialize Ollama service for AI completions
            _ollamaService = new OllamaService(logger);

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

            // Get AST-validated completions only
            try
            {
                var commandCompletion = await _promiseCache.GetCompletionFromAstAsync(ast, tokens, cursorPosition);

                if (commandCompletion?.CompletionMatches != null && commandCompletion.CompletionMatches.Count > 0)
                {
                    // Extract validated completion texts
                    var validatedResults = commandCompletion.CompletionMatches
                        .Select(m => m.CompletionText)
                        .Take(maxResults)
                        .ToList();

                    // Add validated results to FrecencyStore with high priority
                    foreach (var result in validatedResults)
                    {
                        _frecencyStore.AddCommand(result, 5.0f); // High initial rank for validated completions
                    }

                    return validatedResults;
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning($"AST completion failed: {ex.Message}");
            }

            // No fallback - only return validated completions
            return new List<string>();
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
            private readonly FastLogger _logger;

            public CompletionPromiseCache(FastLogger logger, ChannelReader<PowerShell> pwshPoolReader, BackgroundProcessor pwshPool, FrecencyStore frecencyStore)
            {
                _logger = logger;
                _pwshPoolReader = pwshPoolReader;
                _pwshPool = pwshPool;
                _frecencyStore = frecencyStore;
                _promises = new ConcurrentDictionary<string, AsyncLazy<CommandCompletion?>>();
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

                            // Validate completions using AST analysis
                            var validated = ValidateCompletions(completion, pwsh);

                            return validated;
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