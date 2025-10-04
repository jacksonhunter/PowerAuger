using System;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;


namespace PowerAuger    
{
    /// <summary>
    /// Tracks raw, unfiltered command execution history for context and sequence analysis
    /// Separate from FrecencyStore which only tracks validated commands
    /// </summary>
    public sealed class CommandHistoryStore
    {
        private readonly List<string> _history;
        private readonly int _maxSize;
        private readonly FastLogger _logger;
        private readonly object _lock = new();

        public CommandHistoryStore(FastLogger logger, int maxSize = 1000)
        {
            _logger = logger;
            _maxSize = maxSize;
            _history = new List<string>(maxSize);
        }

        /// <summary>
        /// Load existing history from PSReadLine on module initialization
        /// </summary>
        public void LoadFromPSReadLine(PowerShell ps)
        {
            try
            {
                ps.Commands.Clear();
                ps.AddScript("[Microsoft.PowerShell.PSConsoleReadLine]::GetHistoryItems()");

                var results = ps.Invoke();

                if (ps.HadErrors)
                {
                    _logger.LogError("Failed to get PSReadLine history items");
                    return;
                }

                lock (_lock)
                {
                    _history.Clear();

                    // Take most recent commands up to maxSize
                    var recentItems = results
                        .Skip(Math.Max(0, results.Count - _maxSize))
                        .Take(_maxSize);

                    foreach (var item in recentItems)
                    {
                        var commandLine = item?.Properties["CommandLine"]?.Value?.ToString();
                        if (!string.IsNullOrWhiteSpace(commandLine))
                        {
                            _history.Add(commandLine);
                        }
                    }
                }

                _logger.LogInfo($"Loaded {_history.Count} commands from PSReadLine history");
            }
            catch (Exception ex)
            {
                _logger.LogError($"Failed to load PSReadLine history: {ex.Message}");
            }
        }

        /// <summary>
        /// Record a command execution (unfiltered, no validation)
        /// </summary>
        public void RecordCommand(string command)
        {
            if (string.IsNullOrWhiteSpace(command))
                return;

            lock (_lock)
            {
                _history.Add(command);

                // Maintain max size by removing oldest
                while (_history.Count > _maxSize)
                {
                    _history.RemoveAt(0);
                }
            }

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
                    if (_history[i].Equals(endCommand, StringComparison.OrdinalIgnoreCase))
                    {
                        // Extract sequence ending at this position
                        var startIndex = Math.Max(0, i - sequenceLength + 1);
                        var length = i - startIndex + 1;

                        if (length >= 2) // Need at least 2 commands for a meaningful sequence
                        {
                            var sequence = _history
                                .Skip(startIndex)
                                .Take(length)
                                .ToArray();

                            sequences.Add(sequence);
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
                        sequences.Add(_history.ToArray());
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
}
