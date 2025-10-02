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

namespace PowerAugerSharp
{
    public sealed class FastCompletionStore : IDisposable
    {
        // Hot cache for most common prefixes
        private readonly Dictionary<string, List<string>> _hotCache;
        private readonly ReaderWriterLockSlim _hotCacheLock;

        // Main storage using trie for comprehensive coverage
        private readonly CompletionTrie _trie;

        // AI prediction cache with TTL
        private readonly ConcurrentDictionary<string, CachedPrediction> _predictionCache;

        // Command history and patterns
        private readonly ConcurrentDictionary<string, CommandStats> _commandHistory;

        // Track prefix access frequency for promotion
        private readonly ConcurrentDictionary<string, int> _prefixAccessCount;

        // Promise cache for AST-based completions
        private readonly CompletionPromiseCache _promiseCache;

        // File paths for persistence
        private readonly string _cacheDirectory;
        private readonly string _historyFile;
        private readonly string _hotCacheFile;

        private readonly FastLogger _logger;
        private readonly BackgroundProcessor _pwshPool;
        private readonly Timer _persistenceTimer;
        private int _accessCount;

        public FastCompletionStore(FastLogger logger, BackgroundProcessor pwshPool)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _pwshPool = pwshPool ?? throw new ArgumentNullException(nameof(pwshPool));

            _hotCache = new Dictionary<string, List<string>>(200, StringComparer.OrdinalIgnoreCase);
            _hotCacheLock = new ReaderWriterLockSlim();

            _trie = new CompletionTrie();
            _predictionCache = new ConcurrentDictionary<string, CachedPrediction>(StringComparer.OrdinalIgnoreCase);
            _commandHistory = new ConcurrentDictionary<string, CommandStats>(StringComparer.OrdinalIgnoreCase);
            _prefixAccessCount = new ConcurrentDictionary<string, int>(StringComparer.OrdinalIgnoreCase);

            // Initialize promise cache with PowerShell pool
            _promiseCache = new CompletionPromiseCache(logger, pwshPool.GetPoolReader(), pwshPool);

            _cacheDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PowerAugerSharp");
            Directory.CreateDirectory(_cacheDirectory);

            _historyFile = Path.Combine(_cacheDirectory, "history.json");
            _hotCacheFile = Path.Combine(_cacheDirectory, "hotcache.json");

            LoadPersistedData();
            InitializeCommonCompletions();

            // Persist cache every 60 seconds
            _persistenceTimer = new Timer(_ => PersistData(), null, TimeSpan.FromSeconds(60), TimeSpan.FromSeconds(60));
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

            // Use AST text for cache key
            var cacheKey = $"{ast.Extent.Text}:{cursorPosition.Offset}";

            // Layer 1: Check prediction cache
            if (_predictionCache.TryGetValue(cacheKey, out var cached) && !cached.IsExpired)
            {
                return new List<string> { cached.Prediction };
            }

            // Layer 2: Check hot cache
            var prefix = ast.Extent.Text.Substring(0, Math.Min(ast.Extent.Text.Length, cursorPosition.Offset));
            _hotCacheLock.EnterReadLock();
            try
            {
                if (_hotCache.TryGetValue(prefix, out var hotCompletions))
                {
                    return hotCompletions.Take(maxResults).ToList();
                }
            }
            finally
            {
                _hotCacheLock.ExitReadLock();
            }

            // Layer 3: Use promise cache for AST-based completion
            try
            {
                var completion = await _promiseCache.GetCompletionFromAstAsync(
                    ast, tokens, cursorPosition);

                if (completion?.CompletionMatches?.Count > 0)
                {
                    var results = completion.CompletionMatches
                        .Take(maxResults)
                        .Select(m => m.CompletionText)
                        .ToList();

                    // Cache results in trie for future use
                    foreach (var result in results)
                    {
                        _trie.AddCompletion(prefix, result, 1.0f);
                    }

                    // Track access for hot cache promotion
                    TrackAndPromoteIfFrequent(prefix, results);

                    return results;
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning($"AST completion failed: {ex.Message}");
            }

            // Layer 4: Try trie lookup
            var trieCompletions = _trie.GetCompletions(prefix, maxResults);
            if (trieCompletions.Count > 0)
            {
                return trieCompletions;
            }

            // Layer 5: Return empty list (no fallback patterns for AST mode)
            return new List<string>();
        }

        /// <summary>
        /// Get completions synchronously from cache (for fast path)
        /// </summary>
        public List<string> GetCompletions(string prefix, int maxResults = 3)
        {
            Interlocked.Increment(ref _accessCount);

            // Layer 1: Hot cache
            _hotCacheLock.EnterReadLock();
            try
            {
                if (_hotCache.TryGetValue(prefix, out var hotCompletions))
                {
                    return hotCompletions.Take(maxResults).ToList();
                }
            }
            finally
            {
                _hotCacheLock.ExitReadLock();
            }

            // Layer 2: Check prediction cache
            if (_predictionCache.TryGetValue(prefix, out var cached) && !cached.IsExpired)
            {
                return new List<string> { cached.Prediction };
            }

            // Layer 3: Trie lookup
            var trieCompletions = _trie.GetCompletions(prefix, maxResults * 2);
            if (trieCompletions.Count > 0)
            {
                var results = trieCompletions.Take(maxResults).ToList();

                // Promote to hot cache if accessed frequently
                if (_accessCount % 10 == 0)
                {
                    PromoteToHotCache(prefix, results);
                }

                return results;
            }

            // No fallback patterns - return empty list
            return new List<string>();
        }

        public void CachePrediction(string input, string prediction)
        {
            _predictionCache[input] = new CachedPrediction
            {
                Prediction = prediction,
                Timestamp = DateTime.UtcNow
            };

            // Also add to trie for permanent storage
            _trie.AddCompletion(input, prediction, 1.0f);
        }

        public void RecordAcceptance(string commandLine)
        {
            var key = ExtractCommandName(commandLine);
            _commandHistory.AddOrUpdate(key,
                k => new CommandStats { Command = commandLine, AcceptCount = 1, LastUsed = DateTime.UtcNow },
                (k, v) => { v.AcceptCount++; v.LastUsed = DateTime.UtcNow; return v; });

            // Add to trie with increased weight
            _trie.AddCompletion(key, commandLine, 2.0f);
        }

        public void RecordExecution(string commandLine)
        {
            var key = ExtractCommandName(commandLine);
            _commandHistory.AddOrUpdate(key,
                k => new CommandStats { Command = commandLine, ExecuteCount = 1, LastUsed = DateTime.UtcNow },
                (k, v) => { v.ExecuteCount++; v.LastUsed = DateTime.UtcNow; return v; });
        }

        public void RecordSuggestionAcceptance(string suggestion)
        {
            // Track which suggestions are being accepted
            var key = ExtractCommandName(suggestion);
            _commandHistory.AddOrUpdate(key,
                k => new CommandStats { Command = suggestion, SuggestionAcceptCount = 1, LastUsed = DateTime.UtcNow },
                (k, v) => { v.SuggestionAcceptCount++; v.LastUsed = DateTime.UtcNow; return v; });
        }

        public void AddHistoryItem(string historyLine)
        {
            if (string.IsNullOrWhiteSpace(historyLine))
                return;

            var key = ExtractCommandName(historyLine);
            _trie.AddCompletion(key, historyLine, 0.5f);
        }

        /// <summary>
        /// Get few-shot examples from history for a given input
        /// </summary>
        public List<string> GetFewShotExamples(string input, int maxExamples = 3)
        {
            var examples = new List<string>();

            // Try to find similar commands in history
            var prefix = ExtractCommandName(input);
            if (string.IsNullOrEmpty(prefix))
                prefix = input;

            // Get from command history first
            var relevantCommands = _commandHistory
                .Where(kvp => kvp.Key.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(kvp => kvp.Value.GetWeight())
                .Take(maxExamples)
                .Select(kvp => kvp.Value.Command);

            examples.AddRange(relevantCommands);

            // If not enough, get from trie
            if (examples.Count < maxExamples)
            {
                var trieExamples = _trie.GetCompletions(prefix, maxExamples - examples.Count);
                examples.AddRange(trieExamples);
            }

            return examples.Take(maxExamples).ToList();
        }

        private void InitializeCommonCompletions()
        {
            // Pre-populate with common PowerShell commands
            var commonPrefixes = new Dictionary<string, List<string>>
            {
                ["Get-"] = new List<string> { "Get-ChildItem", "Get-Content", "Get-Process", "Get-Service", "Get-Help" },
                ["Set-"] = new List<string> { "Set-Location", "Set-Content", "Set-Variable", "Set-ExecutionPolicy" },
                ["New-"] = new List<string> { "New-Item", "New-Object", "New-Variable", "New-PSDrive" },
                ["Remove-"] = new List<string> { "Remove-Item", "Remove-Variable", "Remove-PSDrive" },
                ["Test-"] = new List<string> { "Test-Path", "Test-Connection", "Test-NetConnection" },
                ["Start-"] = new List<string> { "Start-Process", "Start-Service", "Start-Transcript", "Start-Sleep" },
                ["Stop-"] = new List<string> { "Stop-Process", "Stop-Service", "Stop-Transcript" },
                ["g"] = new List<string> { "git", "Get-ChildItem", "Get-Content" },
                ["cd"] = new List<string> { "cd", "cd ..", "cd ~" },
                ["ls"] = new List<string> { "ls", "ls -la", "ls -Force" }
            };

            _hotCacheLock.EnterWriteLock();
            try
            {
                foreach (var kvp in commonPrefixes)
                {
                    _hotCache[kvp.Key] = kvp.Value;

                    // Also add to trie
                    foreach (var completion in kvp.Value)
                    {
                        _trie.AddCompletion(kvp.Key, completion, 1.5f);
                    }
                }
            }
            finally
            {
                _hotCacheLock.ExitWriteLock();
            }
        }

        private void TrackAndPromoteIfFrequent(string prefix, List<string> completions)
        {
            var count = _prefixAccessCount.AddOrUpdate(prefix, 1, (k, v) => v + 1);

            // Promote to hot cache after 5 accesses
            if (count == 5)
            {
                PromoteToHotCache(prefix, completions);
            }
        }

        private void PromoteToHotCache(string prefix, List<string> completions)
        {
            _hotCacheLock.EnterWriteLock();
            try
            {
                if (_hotCache.Count >= 200)
                {
                    // Remove least recently used
                    var toRemove = _hotCache.Keys.First();
                    _hotCache.Remove(toRemove);
                }
                _hotCache[prefix] = completions;
            }
            finally
            {
                _hotCacheLock.ExitWriteLock();
            }
        }


        private static string ExtractCommandName(string commandLine)
        {
            if (string.IsNullOrWhiteSpace(commandLine))
                return string.Empty;

            var spaceIndex = commandLine.IndexOf(' ');
            return spaceIndex > 0 ? commandLine.Substring(0, spaceIndex) : commandLine;
        }

        private void LoadPersistedData()
        {
            try
            {
                if (File.Exists(_historyFile))
                {
                    var json = File.ReadAllText(_historyFile);
                    var history = JsonSerializer.Deserialize<Dictionary<string, CommandStats>>(json);
                    if (history != null)
                    {
                        foreach (var kvp in history)
                        {
                            _commandHistory[kvp.Key] = kvp.Value;
                            _trie.AddCompletion(kvp.Key, kvp.Value.Command, kvp.Value.GetWeight());
                        }
                    }
                }

                if (File.Exists(_hotCacheFile))
                {
                    var json = File.ReadAllText(_hotCacheFile);
                    var hotCache = JsonSerializer.Deserialize<Dictionary<string, List<string>>>(json);
                    if (hotCache != null)
                    {
                        _hotCacheLock.EnterWriteLock();
                        try
                        {
                            foreach (var kvp in hotCache.Take(200))
                            {
                                _hotCache[kvp.Key] = kvp.Value;
                            }
                        }
                        finally
                        {
                            _hotCacheLock.ExitWriteLock();
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to load persisted data: {ex.Message}");
            }
        }

        private void PersistData()
        {
            try
            {
                var historyJson = JsonSerializer.Serialize(_commandHistory.ToDictionary(k => k.Key, v => v.Value));
                File.WriteAllText(_historyFile, historyJson);

                _hotCacheLock.EnterReadLock();
                try
                {
                    var hotCacheJson = JsonSerializer.Serialize(_hotCache);
                    File.WriteAllText(_hotCacheFile, hotCacheJson);
                }
                finally
                {
                    _hotCacheLock.ExitReadLock();
                }
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to persist data: {ex.Message}");
            }
        }

        public void Dispose()
        {
            _persistenceTimer?.Dispose();
            PersistData();
            _hotCacheLock?.Dispose();
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
            private readonly FastLogger _logger;

            public CompletionPromiseCache(FastLogger logger, ChannelReader<PowerShell> pwshPoolReader, BackgroundProcessor pwshPool)
            {
                _logger = logger;
                _pwshPoolReader = pwshPoolReader;
                _pwshPool = pwshPool;
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

        private class CachedPrediction
        {
            public string Prediction { get; set; } = string.Empty;
            public DateTime Timestamp { get; set; }
            public bool IsExpired => (DateTime.UtcNow - Timestamp).TotalSeconds > 3;
        }

        private class CommandStats
        {
            public string Command { get; set; } = string.Empty;
            public int AcceptCount { get; set; }
            public int ExecuteCount { get; set; }
            public int SuggestionAcceptCount { get; set; }
            public DateTime LastUsed { get; set; }

            public float GetWeight()
            {
                var daysSinceUse = (DateTime.UtcNow - LastUsed).TotalDays;
                var recencyFactor = Math.Max(0.1f, 1.0f - (float)(daysSinceUse / 30));
                return (AcceptCount * 2 + ExecuteCount * 3 + SuggestionAcceptCount) * recencyFactor;
            }
        }
    }
}