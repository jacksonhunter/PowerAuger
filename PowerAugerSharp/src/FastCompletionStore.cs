using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading;

namespace PowerAugerSharp
{
    public sealed class FastCompletionStore : IDisposable
    {
        // Ultra-hot cache for top 20 prefixes (linear scan is faster than hash for small N)
        private readonly (string prefix, List<string> completions)[] _ultraHotCache;
        private readonly ReaderWriterLockSlim _ultraHotLock;

        // Hot cache for next 100 most common prefixes
        private readonly Dictionary<string, List<string>> _hotCache;
        private readonly ReaderWriterLockSlim _hotCacheLock;

        // Main storage using trie for comprehensive coverage
        private readonly CompletionTrie _trie;

        // AI prediction cache with TTL
        private readonly ConcurrentDictionary<string, CachedPrediction> _predictionCache;

        // Command history and patterns
        private readonly ConcurrentDictionary<string, CommandStats> _commandHistory;

        // File paths for persistence
        private readonly string _cacheDirectory;
        private readonly string _historyFile;
        private readonly string _hotCacheFile;

        private readonly FastLogger _logger;
        private readonly Timer _persistenceTimer;
        private int _accessCount;

        public FastCompletionStore(FastLogger logger)
        {
            _logger = logger;

            _ultraHotCache = new (string, List<string>)[20];
            _ultraHotLock = new ReaderWriterLockSlim();

            _hotCache = new Dictionary<string, List<string>>(100, StringComparer.OrdinalIgnoreCase);
            _hotCacheLock = new ReaderWriterLockSlim();

            _trie = new CompletionTrie();
            _predictionCache = new ConcurrentDictionary<string, CachedPrediction>(StringComparer.OrdinalIgnoreCase);
            _commandHistory = new ConcurrentDictionary<string, CommandStats>(StringComparer.OrdinalIgnoreCase);

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

        [MethodImpl(MethodImplOptions.AggressiveOptimization)]
        public List<string> GetCompletions(string prefix, int maxResults = 3)
        {
            Interlocked.Increment(ref _accessCount);

            // Layer 1: Ultra-hot cache (fastest)
            _ultraHotLock.EnterReadLock();
            try
            {
                for (int i = 0; i < _ultraHotCache.Length; i++)
                {
                    if (_ultraHotCache[i].prefix == prefix && _ultraHotCache[i].completions != null)
                    {
                        _logger.LogDebug($"Ultra-hot hit for: {prefix}");
                        return _ultraHotCache[i].completions.Take(maxResults).ToList();
                    }
                }
            }
            finally
            {
                _ultraHotLock.ExitReadLock();
            }

            // Layer 2: Hot cache
            _hotCacheLock.EnterReadLock();
            try
            {
                if (_hotCache.TryGetValue(prefix, out var hotCompletions))
                {
                    _logger.LogDebug($"Hot cache hit for: {prefix}");
                    UpdateUltraHotCache(prefix, hotCompletions);
                    return hotCompletions.Take(maxResults).ToList();
                }
            }
            finally
            {
                _hotCacheLock.ExitReadLock();
            }

            // Layer 3: Check prediction cache
            if (_predictionCache.TryGetValue(prefix, out var cached) && !cached.IsExpired)
            {
                _logger.LogDebug($"Prediction cache hit for: {prefix}");
                return new List<string> { cached.Prediction };
            }

            // Layer 4: Trie lookup
            var trieCompletions = _trie.GetCompletions(prefix, maxResults * 2);
            if (trieCompletions.Count > 0)
            {
                _logger.LogDebug($"Trie hit for: {prefix}");
                var results = trieCompletions.Take(maxResults).ToList();

                // Promote to hot cache if accessed frequently
                if (_accessCount % 10 == 0)
                {
                    PromoteToHotCache(prefix, results);
                }

                return results;
            }

            // Layer 5: Fallback patterns
            return GetFallbackCompletions(prefix, maxResults);
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

            // Initialize ultra-hot with most common
            _ultraHotLock.EnterWriteLock();
            try
            {
                _ultraHotCache[0] = ("Get-", commonPrefixes["Get-"]);
                _ultraHotCache[1] = ("g", commonPrefixes["g"]);
                _ultraHotCache[2] = ("Set-", commonPrefixes["Set-"]);
            }
            finally
            {
                _ultraHotLock.ExitWriteLock();
            }
        }

        private void UpdateUltraHotCache(string prefix, List<string> completions)
        {
            _ultraHotLock.EnterWriteLock();
            try
            {
                // Shift everything down and add new entry at top
                for (int i = _ultraHotCache.Length - 1; i > 0; i--)
                {
                    _ultraHotCache[i] = _ultraHotCache[i - 1];
                }
                _ultraHotCache[0] = (prefix, completions);
            }
            finally
            {
                _ultraHotLock.ExitWriteLock();
            }
        }

        private void PromoteToHotCache(string prefix, List<string> completions)
        {
            _hotCacheLock.EnterWriteLock();
            try
            {
                if (_hotCache.Count >= 100)
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

        private List<string> GetFallbackCompletions(string prefix, int maxResults)
        {
            var results = new List<string>();

            // Basic PowerShell command patterns
            if (prefix.StartsWith("Get-", StringComparison.OrdinalIgnoreCase))
            {
                results.Add("Get-ChildItem");
                results.Add("Get-Content");
                results.Add("Get-Process");
            }
            else if (prefix.Length == 1)
            {
                switch (char.ToLower(prefix[0]))
                {
                    case 'g':
                        results.Add("git");
                        results.Add("Get-ChildItem");
                        break;
                    case 's':
                        results.Add("Set-Location");
                        results.Add("Start-Process");
                        break;
                    case 'c':
                        results.Add("cd");
                        results.Add("Clear-Host");
                        break;
                }
            }

            return results.Take(maxResults).ToList();
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
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
                            foreach (var kvp in hotCache.Take(100))
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
            _ultraHotLock?.Dispose();
            _hotCacheLock?.Dispose();
        }

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