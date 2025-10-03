using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace PowerAuger
{
    /// <summary>
    /// Single-source-of-truth frecency-based command store using zsh-z algorithm
    /// </summary>
    public sealed class FrecencyStore : IDisposable
    {
        private readonly Dictionary<int, CommandEntry> _commands = new();
        private readonly FrecencyTrie _trie = new();
        private readonly ConcurrentDictionary<string, Task<List<string>>> _pendingEnrichments = new();
        private readonly BackgroundProcessor _pwshPool;
        private readonly FastLogger _logger;
        private readonly Timer _persistenceTimer;
        private readonly string _cacheDirectory;
        private readonly string _dataPath;
        private readonly string _backupPath;

        private int _nextId = 1;
        private float _totalScore;
        private long _lastAgedTicks;
        private int _operationCount;

        // Configuration
        private const float MAX_TOTAL_SCORE = 9000f;
        private const float AGING_FACTOR = 0.99f;
        private const float MIN_RANK = 1.0f;
        private const int MAX_COMMANDS = 10000;
        private const int MAX_PREFIX_DEPTH = 50;
        private const int PERSIST_INTERVAL_SECONDS = 60;

        public FrecencyStore(FastLogger logger, BackgroundProcessor pwshPool)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _pwshPool = pwshPool ?? throw new ArgumentNullException(nameof(pwshPool));

            _cacheDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PowerAuger");
            Directory.CreateDirectory(_cacheDirectory);

            _dataPath = Path.Combine(_cacheDirectory, "frecency.dat");
            _backupPath = Path.Combine(_cacheDirectory, "frecency.json");

            // Persist periodically
            _persistenceTimer = new Timer(_ => PersistToDisk(), null,
                TimeSpan.FromSeconds(PERSIST_INTERVAL_SECONDS),
                TimeSpan.FromSeconds(PERSIST_INTERVAL_SECONDS));
        }

        /// <summary>
        /// Initialize the store from disk or history
        /// </summary>
        public void Initialize()
        {
            // Try to load from persistence
            if (LoadFromDisk())
            {
                _logger.LogInfo($"Loaded {_commands.Count} commands from disk");
                return;
            }

            // No persistence? Load validated history with frequencies
            _logger.LogInfo("No persisted data found, loading history with frequencies");
            var historyWithFrequencies = PowerShellHistoryLoader.LoadHistoryWithFrequencies(_logger);

            foreach (var kvp in historyWithFrequencies)
            {
                // LoadHistoryWithFrequencies already validates commands (filters assignments, if-statements, etc.)
                // Use the actual frequency count as the initial rank for proper zsh-z scoring
                AddCommand(kvp.Key, initialRank: (float)kvp.Value, logNormalizationErrors: true);
            }

            _logger.LogInfo($"Loaded {_commands.Count} validated commands from history with frequency scores");

            // Save immediately so we don't have to reprocess
            PersistToDisk();
        }

        /// <summary>
        /// Add a new command or update existing
        /// </summary>
        public void AddCommand(string command, float initialRank = 1.0f, bool logNormalizationErrors = false)
        {
            if (string.IsNullOrWhiteSpace(command))
                return;

            // Normalize Unicode escapes and clean up the command
            command = NormalizeCommand(command, logNormalizationErrors);

            // Check if command already exists
            var existing = _commands.Values.FirstOrDefault(c =>
                c.Command.Equals(command, StringComparison.OrdinalIgnoreCase));

            if (existing != null)
            {
                existing.IncrementRank(initialRank);
                return;
            }

            // Create new entry
            var entry = new CommandEntry
            {
                Id = _nextId++,
                Command = command,
                Rank = initialRank,
                LastUsedTicks = DateTime.UtcNow.Ticks
            };

            _commands[entry.Id] = entry;

            // Add to trie - stores FULL command path, not prefixes
            _trie.AddCommand(command, entry.Id);

            _totalScore += initialRank;
        }

        /// <summary>
        /// Get top commands for a prefix
        /// </summary>
        public List<string> GetTopCommands(string prefix, int count = 5)
        {
            if (string.IsNullOrEmpty(prefix))
                return new List<string>();

            var commandIds = _trie.GetCommandIds(prefix);
            if (commandIds == null || commandIds.Count == 0)
                return new List<string>();

            // Sort by current frecency (changes over time)
            var sorted = commandIds
                .Select(id => _commands.TryGetValue(id, out var cmd) ? cmd : null)
                .Where(cmd => cmd != null)
                .OrderByDescending(cmd => cmd!.GetFrecency())
                .Take(count)
                .Select(cmd => cmd!.Command)
                .ToList();

            return sorted;
        }

        /// <summary>
        /// Normalize command string to handle Unicode escapes and other formatting
        /// </summary>
        private string NormalizeCommand(string command, bool logErrors = false)
        {
            if (string.IsNullOrEmpty(command))
                return command;

            try
            {
                // Wrap in quotes to make it valid JSON, then deserialize
                // This will decode Unicode escapes like \u0022 but leave Windows paths alone
                var jsonString = "\"" + command + "\"";
                command = JsonSerializer.Deserialize<string>(jsonString) ?? command;
            }
            catch (Exception ex)
            {
                // If JSON parsing fails, just use the original command
                // This handles cases where the command contains invalid JSON syntax (like Windows paths)
                if (logErrors)
                {
                    _logger.LogDebug($"JSON normalization skipped for: {command.Substring(0, Math.Min(50, command.Length))}... - {ex.GetType().Name}");
                }
            }

            // Remove excessive whitespace
            command = System.Text.RegularExpressions.Regex.Replace(command, @"\s+", " ").Trim();

            return command;
        }

        /// <summary>
        /// Increment rank when command is used
        /// </summary>
        public void IncrementRank(string command, float increment = 1.0f)
        {
            command = NormalizeCommand(command);

            var existing = _commands.Values.FirstOrDefault(c =>
                c.Command.Equals(command, StringComparison.OrdinalIgnoreCase));

            if (existing != null)
            {
                existing.IncrementRank(increment);
                _totalScore += increment;
            }
            else
            {
                // New command discovered through usage
                AddCommand(command, initialRank: increment);
            }

            // Periodic maintenance
            if (++_operationCount % 100 == 0)
            {
                _ = Task.Run(() => PerformMaintenance());
            }
        }

        /// <summary>
        /// Perform aging if total score exceeds threshold
        /// </summary>
        private void AgeIfNeeded()
        {
            if (_totalScore > MAX_TOTAL_SCORE)
            {
                _logger.LogInfo($"Aging database (total score: {_totalScore:F1})");

                // Age all entries
                foreach (var cmd in _commands.Values)
                {
                    cmd.Age(AGING_FACTOR);
                }

                // Recalculate total and remove very low rank entries
                _totalScore = 0;
                var toRemove = new List<int>();

                foreach (var kvp in _commands)
                {
                    if (kvp.Value.Rank < MIN_RANK)
                    {
                        toRemove.Add(kvp.Key);
                    }
                    else
                    {
                        _totalScore += kvp.Value.Rank;
                    }
                }

                // Remove low rank commands
                foreach (var id in toRemove)
                {
                    RemoveCommand(id);
                }

                _lastAgedTicks = DateTime.UtcNow.Ticks;
                _logger.LogInfo($"Aged database, removed {toRemove.Count} commands, new total: {_totalScore:F1}");
            }
        }

        /// <summary>
        /// Remove a command from the store
        /// </summary>
        private void RemoveCommand(int id)
        {
            if (_commands.TryGetValue(id, out var cmd))
            {
                _commands.Remove(id);
                _trie.RemoveCommand(id);
                _totalScore -= cmd.Rank;
            }
        }

        /// <summary>
        /// Tree shake to remove stale entries
        /// </summary>
        private void TreeShake()
        {
            // Remove excess commands if over limit
            if (_commands.Count > MAX_COMMANDS)
            {
                var toKeep = _commands.Values
                    .OrderByDescending(c => c.GetFrecency())
                    .Take(MAX_COMMANDS)
                    .Select(c => c.Id)
                    .ToHashSet();

                var toRemove = _commands.Keys
                    .Where(id => !toKeep.Contains(id))
                    .ToList();

                foreach (var id in toRemove)
                {
                    RemoveCommand(id);
                }

                _logger.LogInfo($"Tree shake removed {toRemove.Count} low-scoring commands");
            }

            // Prune trie of unreferenced commands
            _trie.Prune(_commands.Keys.ToHashSet());
        }

        /// <summary>
        /// Perform periodic maintenance
        /// </summary>
        private void PerformMaintenance()
        {
            try
            {
                AgeIfNeeded();
                TreeShake();
                PersistToDisk();
            }
            catch (Exception ex)
            {
                _logger.LogError($"Maintenance failed: {ex.Message}");
            }
        }

        /// <summary>
        /// Load from disk
        /// </summary>
        private bool LoadFromDisk()
        {
            try
            {
                if (!File.Exists(_dataPath))
                    return false;

                using var fs = new FileStream(_dataPath, FileMode.Open, FileAccess.Read);
                using var reader = new BinaryReader(fs);

                var version = reader.ReadInt32();
                if (version != 2)
                {
                    _logger.LogWarning($"Unknown data version {version}, starting fresh");
                    return false;
                }

                _totalScore = reader.ReadSingle();
                _lastAgedTicks = reader.ReadInt64();
                var commandCount = reader.ReadInt32();

                _commands.Clear();
                _trie.Clear();

                for (int i = 0; i < commandCount; i++)
                {
                    var id = reader.ReadInt32();
                    var command = reader.ReadString();
                    var rank = reader.ReadSingle();
                    var lastUsedTicks = reader.ReadInt64();

                    // Normalize command when loading from disk (enable logging to catch issues)
                    command = NormalizeCommand(command, logErrors: true);

                    var entry = new CommandEntry
                    {
                        Id = id,
                        Command = command,
                        Rank = rank,
                        LastUsedTicks = lastUsedTicks
                    };

                    _commands[id] = entry;
                    _nextId = Math.Max(_nextId, id + 1);

                    // Rebuild trie - store full command, not prefixes
                    _trie.AddCommand(command, id);
                }

                return true;
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to load from disk: {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Save to disk
        /// </summary>
        private void PersistToDisk()
        {
            try
            {
                // Binary format for speed
                using (var fs = new FileStream(_dataPath + ".tmp", FileMode.Create))
                using (var writer = new BinaryWriter(fs))
                {
                    writer.Write(2); // Version
                    writer.Write(_totalScore);
                    writer.Write(_lastAgedTicks);
                    writer.Write(_commands.Count);

                    foreach (var cmd in _commands.Values)
                    {
                        writer.Write(cmd.Id);
                        writer.Write(cmd.Command);
                        writer.Write(cmd.Rank);
                        writer.Write(cmd.LastUsedTicks);
                    }
                }

                // Atomic replace
                if (File.Exists(_dataPath))
                    File.Delete(_dataPath);
                File.Move(_dataPath + ".tmp", _dataPath);

                // JSON backup (async, don't block)
                _ = Task.Run(() => SaveJsonBackup());
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to persist to disk: {ex.Message}");
            }
        }

        /// <summary>
        /// Save JSON backup for debugging
        /// </summary>
        private void SaveJsonBackup()
        {
            try
            {
                var backup = new
                {
                    version = 2,
                    totalScore = _totalScore,
                    lastAged = new DateTime(_lastAgedTicks),
                    savedAt = DateTime.UtcNow,
                    commandCount = _commands.Count,
                    commands = _commands.Values
                        .OrderByDescending(c => c.GetFrecency())
                        .Select(c => new
                        {
                            c.Command,
                            c.Rank,
                            LastUsed = new DateTime(c.LastUsedTicks),
                            Frecency = c.GetFrecency()
                        })
                };

                var json = JsonSerializer.Serialize(backup, new JsonSerializerOptions
                {
                    WriteIndented = true
                });
                File.WriteAllText(_backupPath, json);
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to save JSON backup: {ex.Message}");
            }
        }

        public void Dispose()
        {
            _persistenceTimer?.Dispose();
            PerformMaintenance();
        }
    }

    /// <summary>
    /// Command entry with zsh-z style frecency
    /// </summary>
    public class CommandEntry
    {
        public int Id { get; set; }
        public string Command { get; set; } = string.Empty;
        public float Rank { get; set; } = 1.0f;
        public long LastUsedTicks { get; set; }

        /// <summary>
        /// Calculate frecency using zsh-z algorithm
        /// </summary>
        public float GetFrecency()
        {
            var secondsSinceUse = (DateTime.UtcNow.Ticks - LastUsedTicks) / (double)TimeSpan.TicksPerSecond;
            var decay = 3.75 / ((0.0001 * secondsSinceUse + 1) + 0.25);
            return Rank * (float)decay;
        }

        /// <summary>
        /// Increment rank when command is used
        /// </summary>
        public void IncrementRank(float increment = 1.0f)
        {
            Rank += increment;
            LastUsedTicks = DateTime.UtcNow.Ticks;
        }

        /// <summary>
        /// Age the rank for database maintenance
        /// </summary>
        public void Age(float factor = 0.99f)
        {
            Rank *= factor;
        }
    }

    /// <summary>
    /// Trie structure for prefix matching with command IDs
    /// </summary>
    public class FrecencyTrie
    {
        private class TrieNode
        {
            private const int MaxCommandsPerNode = 20;

            // Commands that END at this exact prefix
            private HashSet<int>? _terminalCommandIds;

            // Commands that PASS THROUGH this prefix (for lookup only)
            private HashSet<int>? _transitCommandIds;

            private Dictionary<char, TrieNode>? _children;

            public HashSet<int> TerminalCommandIds => _terminalCommandIds ??= new HashSet<int>();
            public HashSet<int> TransitCommandIds => _transitCommandIds ??= new HashSet<int>();
            public Dictionary<char, TrieNode> Children => _children ??= new Dictionary<char, TrieNode>();

            public void AddTerminalCommand(int id)
            {
                TerminalCommandIds.Add(id);
            }

            public void AddTransitCommand(int id)
            {
                TransitCommandIds.Add(id);
            }

            public void RemoveCommand(int id)
            {
                _terminalCommandIds?.Remove(id);
                _transitCommandIds?.Remove(id);
            }

            public bool IsEmpty =>
                (_terminalCommandIds?.Count ?? 0) == 0 &&
                (_transitCommandIds?.Count ?? 0) == 0 &&
                (_children?.Count ?? 0) == 0;
        }

        private readonly TrieNode _root = new();

        /// <summary>
        /// Add a command to the trie (stores full command path)
        /// </summary>
        public void AddCommand(string command, int commandId)
        {
            var node = _root;

            // Add as transit to all nodes along the path
            foreach (char c in command.ToLowerInvariant())
            {
                if (!node.Children.TryGetValue(c, out var child))
                {
                    child = new TrieNode();
                    node.Children[c] = child;
                }
                child.AddTransitCommand(commandId);
                node = child;
            }

            // Mark as terminal at the final node (full command)
            node.AddTerminalCommand(commandId);
        }

        /// <summary>
        /// Get command IDs that match a prefix (all commands passing through)
        /// </summary>
        public HashSet<int>? GetCommandIds(string prefix)
        {
            var node = FindNode(prefix.ToLowerInvariant());
            return node?.TransitCommandIds;
        }

        /// <summary>
        /// Remove a command ID from all nodes
        /// </summary>
        public void RemoveCommand(int commandId)
        {
            RemoveFromNode(_root, commandId);
        }

        private void RemoveFromNode(TrieNode node, int commandId)
        {
            node.RemoveCommand(commandId);

            if (node.Children != null)
            {
                foreach (var child in node.Children.Values)
                {
                    RemoveFromNode(child, commandId);
                }
            }
        }

        /// <summary>
        /// Find a node by prefix
        /// </summary>
        private TrieNode? FindNode(string prefix)
        {
            var node = _root;
            foreach (char c in prefix)
            {
                if (node.Children == null || !node.Children.TryGetValue(c, out var child))
                    return null;
                node = child;
            }
            return node;
        }

        /// <summary>
        /// Prune nodes that reference non-existent commands
        /// </summary>
        public void Prune(HashSet<int> validIds)
        {
            PruneNode(_root, validIds);
        }

        private bool PruneNode(TrieNode node, HashSet<int> validIds)
        {
            // Remove invalid command IDs from both terminal and transit sets
            if (node.TerminalCommandIds != null)
            {
                node.TerminalCommandIds.RemoveWhere(id => !validIds.Contains(id));
            }

            if (node.TransitCommandIds != null)
            {
                node.TransitCommandIds.RemoveWhere(id => !validIds.Contains(id));
            }

            // Recursively prune children
            if (node.Children != null)
            {
                var toRemove = new List<char>();
                foreach (var kvp in node.Children)
                {
                    if (PruneNode(kvp.Value, validIds))
                    {
                        toRemove.Add(kvp.Key);
                    }
                }

                foreach (var key in toRemove)
                {
                    node.Children.Remove(key);
                }
            }

            return node.IsEmpty;
        }

        /// <summary>
        /// Clear the trie
        /// </summary>
        public void Clear()
        {
            _root.Children?.Clear();
            _root.TerminalCommandIds?.Clear();
            _root.TransitCommandIds?.Clear();
        }
    }
}