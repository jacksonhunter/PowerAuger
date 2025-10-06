using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Language;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PowerAuger
{
    /// <summary>
    /// Represents a single command execution with metadata
    /// </summary>
    public sealed record CommandHistoryEntry(
        string Command,
        string? WorkingDirectory = null,
        DateTime? Timestamp = null,
        bool? Success = null,
        string? AstType = null)
    {
        [JsonPropertyName("command")]
        public string Command { get; init; } = Command;

        [JsonPropertyName("workingDirectory")]
        public string? WorkingDirectory { get; init; }

        [JsonPropertyName("timestamp")]
        public DateTime? Timestamp { get; init; }

        [JsonPropertyName("success")]
        public bool? Success { get; init; }

        [JsonPropertyName("astType")]
        public string? AstType { get; init; }
    }

    /// <summary>
    /// Tracks raw, unfiltered command execution history for context and sequence analysis
    /// Separate from FrecencyStore which only tracks validated commands
    /// </summary>
    public sealed class CommandHistoryStore
    {
        private readonly List<CommandHistoryEntry> _history;
        private int _maxSize;
        private readonly FastLogger _logger;
        private readonly object _lock = new();
        private readonly string _storageFilePath;

        public CommandHistoryStore(FastLogger logger, int maxSize = 10000)
        {
            _logger = logger;
            _maxSize = maxSize;
            _history = new List<CommandHistoryEntry>(maxSize);

            // Set up storage path: %LOCALAPPDATA%\PowerAuger\command-history.json
            var powerAugerDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PowerAuger");
            Directory.CreateDirectory(powerAugerDir);
            _storageFilePath = Path.Combine(powerAugerDir, "command-history.json");

            // Try to load existing history from JSON
            LoadFromJson();

            // If JSON was empty/missing, load from PSReadLine history file
            if (_history.Count == 0)
            {
                _logger.LogInfo("JSON history empty, loading from PSReadLine history file");
                var entries = PowerShellHistoryLoader.LoadHistoryWithMetadata(_maxSize, _logger);
                lock (_lock)
                {
                    _history.AddRange(entries);
                }
                _logger.LogInfo($"Loaded {_history.Count} entries from PSReadLine history file");

                // Save immediately so we don't have to reprocess
                _ = SaveToJsonAsync();
            }
        }


        /// <summary>
        /// Record a command execution (unfiltered, no validation)
        /// </summary>
        public void RecordCommand(string command, string? workingDirectory, bool? success = null, string? astType = null)
        {
            if (string.IsNullOrWhiteSpace(command))
                return;

            var entry = new CommandHistoryEntry(command, workingDirectory, DateTime.UtcNow, success, astType);

            lock (_lock)
            {
                _history.Add(entry);

                // Maintain max size by removing oldest
                while (_history.Count > _maxSize)
                {
                    _history.RemoveAt(0);
                }
            }

            // Save to JSON asynchronously
            _ = SaveToJsonAsync();

            _logger.LogDebug($"Recorded command to history: {command}");
        }

        /// <summary>
        /// Get the most recent N commands (unfiltered)
        /// Used for Chat mode context - shows what user is currently doing
        /// </summary>
        public List<string> GetRecentCommands(int count = 10)
        {
            lock (_lock)
            {
                return _history
                    .Skip(Math.Max(0, _history.Count - count))
                    .Select(e => e.Command)
                    .ToList();
            }
        }

        /// <summary>
        /// Get command sequences ending with a specific command
        /// Used for warmup mode - finds patterns like "command X often follows Y"
        /// </summary>
        /// <param name="endCommand">The command that ends the sequence</param>
        /// <param name="sequenceLength">How many commands in each sequence</param>
        /// <param name="maxSequences">Maximum number of sequences to return</param>
        public List<string[]> GetSequencesEndingWith(string endCommand, int sequenceLength = 10, int maxSequences = 5)
        {
            var sequences = new List<string[]>();

            if (string.IsNullOrWhiteSpace(endCommand))
                return sequences;

            lock (_lock)
            {
                // Find all occurrences of endCommand
                for (int i = _history.Count - 1; i >= 0 && sequences.Count < maxSequences; i--)
                {
                    if (_history[i].Command.Equals(endCommand, StringComparison.OrdinalIgnoreCase))
                    {
                        // Ensure there's a command AFTER the match for warmup prediction
                        if (i + 1 < _history.Count)
                        {
                            // Extract: [commands before] + [match at i] + [command after at i+1]
                            var startIndex = Math.Max(0, i - sequenceLength + 2);
                            var endIndex = i + 1;
                            var length = endIndex - startIndex + 1;

                            if (length >= 2) // Need at least 2 commands for a meaningful sequence
                            {
                                var sequence = _history
                                    .Skip(startIndex)
                                    .Take(length)
                                    .Select(e => e.Command)
                                    .ToArray();

                                sequences.Add(sequence);
                            }
                        }
                    }
                }
            }

            _logger.LogDebug($"Found {sequences.Count} sequences ending with '{endCommand}'");
            return sequences;
        }

        /// <summary>
        /// Get recent command sequences of a specific length
        /// Used for general pattern learning
        /// </summary>
        public List<string[]> GetCommandSequences(int sequenceLength = 10, int maxSequences = 10)
        {
            var sequences = new List<string[]>();

            lock (_lock)
            {
                if (_history.Count < sequenceLength)
                {
                    // Not enough history yet, return what we have
                    if (_history.Count >= 2)
                    {
                        sequences.Add(_history.Select(e => e.Command).ToArray());
                    }
                    return sequences;
                }

                // Extract sliding windows of sequenceLength
                var step = Math.Max(1, _history.Count / maxSequences); // Sample evenly

                for (int i = _history.Count - sequenceLength; i >= 0 && sequences.Count < maxSequences; i -= step)
                {
                    var sequence = _history
                        .Skip(i)
                        .Take(sequenceLength)
                        .Select(e => e.Command)
                        .ToArray();

                    sequences.Add(sequence);
                }
            }

            _logger.LogDebug($"Extracted {sequences.Count} command sequences of length {sequenceLength}");
            return sequences;
        }

        /// <summary>
        /// Get total number of commands in history
        /// </summary>
        public int Count
        {
            get
            {
                lock (_lock)
                {
                    return _history.Count;
                }
            }
        }

        /// <summary>
        /// Load history from JSON storage
        /// </summary>
        private void LoadFromJson()
        {
            try
            {
                if (!File.Exists(_storageFilePath))
                {
                    _logger.LogInfo("No existing command history JSON found");
                    return;
                }

                var json = File.ReadAllText(_storageFilePath);
                var options = new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true,
                    WriteIndented = true
                };

                var data = JsonSerializer.Deserialize<CommandHistoryData>(json, options);
                if (data != null)
                {
                    lock (_lock)
                    {
                        _history.Clear();
                        _history.AddRange(data.Commands ?? new List<CommandHistoryEntry>());
                        if (data.MaxSize > 0)
                        {
                            _maxSize = data.MaxSize;
                        }
                    }

                    _logger.LogInfo($"Loaded {_history.Count} commands from JSON (maxSize: {_maxSize})");
                }
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to load command history from JSON: {ex.Message}");
            }
        }

        /// <summary>
        /// Save history to JSON storage asynchronously
        /// </summary>
        private async System.Threading.Tasks.Task SaveToJsonAsync()
        {
            try
            {
                List<CommandHistoryEntry> snapshot;
                int maxSize;

                lock (_lock)
                {
                    snapshot = new List<CommandHistoryEntry>(_history);
                    maxSize = _maxSize;
                }

                var data = new CommandHistoryData
                {
                    MaxSize = maxSize,
                    Commands = snapshot
                };

                var options = new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true,
                    WriteIndented = true
                };

                var json = JsonSerializer.Serialize(data, options);
                await File.WriteAllTextAsync(_storageFilePath, json);

                _logger.LogDebug($"Saved {snapshot.Count} commands to JSON");
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to save command history to JSON: {ex.Message}");
            }
        }

        /// <summary>
        /// Clear all history (for testing)
        /// </summary>
        public void Clear()
        {
            lock (_lock)
            {
                _history.Clear();
            }
            _logger.LogInfo("Command history cleared");
        }
    }

    /// <summary>
    /// JSON storage format for command history
    /// </summary>
    internal class CommandHistoryData
    {
        [JsonPropertyName("maxSize")]
        public int MaxSize { get; set; }

        [JsonPropertyName("commands")]
        public List<CommandHistoryEntry> Commands { get; set; } = new();
    }
}
