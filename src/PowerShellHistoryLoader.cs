using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Language;

namespace PowerAugerSharp
{
    /// <summary>
    /// Loads and validates PowerShell command history
    /// </summary>
    public static class PowerShellHistoryLoader
    {
        /// <summary>
        /// Load and validate PowerShell command history
        /// </summary>
        public static List<string> LoadValidatedHistory(FastLogger? logger = null)
        {
            var validated = new List<string>();

            try
            {
                var historyPath = GetHistoryPath();

                if (!File.Exists(historyPath))
                {
                    logger?.LogWarning($"History file not found: {historyPath}");
                    return validated;
                }

                var lines = File.ReadAllLines(historyPath);
                logger?.LogInfo($"Loading {lines.Length} history entries from {historyPath}");

                var uniqueCommands = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                int filteredCount = 0;
                int duplicateCount = 0;
                int parseErrorCount = 0;
                int multilineCount = 0;

                // Handle multiline commands with backtick continuation
                var currentCommand = new System.Text.StringBuilder();

                for (int i = 0; i < lines.Length; i++)
                {
                    var line = lines[i];

                    // Skip empty lines and comments
                    if (string.IsNullOrWhiteSpace(line) || line.TrimStart().StartsWith("#"))
                    {
                        // If we have a command built up, process it
                        if (currentCommand.Length > 0)
                        {
                            var fullCommand = currentCommand.ToString().Trim();
                            ProcessCommand(fullCommand, uniqueCommands, validated,
                                ref filteredCount, ref duplicateCount, ref parseErrorCount, logger);
                            currentCommand.Clear();
                        }
                        continue;
                    }

                    // Check if this is a continuation line (ends with backtick)
                    if (line.EndsWith("`"))
                    {
                        // Remove the backtick and add to current command
                        currentCommand.AppendLine(line.Substring(0, line.Length - 1));
                        multilineCount++;
                    }
                    else if (currentCommand.Length > 0)
                    {
                        // This is the last line of a multiline command
                        currentCommand.AppendLine(line);
                        var fullCommand = currentCommand.ToString().Trim();
                        ProcessCommand(fullCommand, uniqueCommands, validated,
                            ref filteredCount, ref duplicateCount, ref parseErrorCount, logger);
                        currentCommand.Clear();
                    }
                    else
                    {
                        // Single line command
                        ProcessCommand(line, uniqueCommands, validated,
                            ref filteredCount, ref duplicateCount, ref parseErrorCount, logger);
                    }
                }

                // Don't forget the last command if it exists
                if (currentCommand.Length > 0)
                {
                    var fullCommand = currentCommand.ToString().Trim();
                    ProcessCommand(fullCommand, uniqueCommands, validated,
                        ref filteredCount, ref duplicateCount, ref parseErrorCount, logger);
                }

                logger?.LogInfo($"Loaded {validated.Count} validated commands from history");
                logger?.LogInfo($"Filtered: {filteredCount}, Duplicates: {duplicateCount}, Parse errors: {parseErrorCount}, Multiline: {multilineCount}");
            }
            catch (Exception ex)
            {
                logger?.LogError($"Failed to load history: {ex.Message}");
            }

            return validated;
        }

        /// <summary>
        /// Process a single command for validation and adding to the collection
        /// </summary>
        private static void ProcessCommand(
            string command,
            HashSet<string> uniqueCommands,
            List<string> validated,
            ref int filteredCount,
            ref int duplicateCount,
            ref int parseErrorCount,
            FastLogger? logger)
        {
            // Skip empty
            if (string.IsNullOrWhiteSpace(command))
                return;

            // Skip duplicates
            if (uniqueCommands.Contains(command))
            {
                duplicateCount++;
                return;
            }

            // Parse the command to get AST
            var ast = Parser.ParseInput(command, out _, out var errors);

            if (errors.Length > 0)
            {
                parseErrorCount++;
                logger?.LogDebug($"Skip history with parse errors: {command}");
                return;
            }

            var firstStatement = ast?.EndBlock?.Statements?.FirstOrDefault();
            if (firstStatement == null)
            {
                logger?.LogDebug($"Skip history with no statements: {command}");
                return;
            }

            // Filter assignments
            if (firstStatement is AssignmentStatementAst)
            {
                filteredCount++;
                logger?.LogDebug($"Skip assignment in history: {command}");
                return;
            }

            // Filter if-statements
            if (firstStatement is IfStatementAst)
            {
                filteredCount++;
                logger?.LogDebug($"Skip if-statement in history: {command}");
                return;
            }

            // Filter while/for/foreach loops
            if (firstStatement is LoopStatementAst)
            {
                filteredCount++;
                logger?.LogDebug($"Skip loop statement in history: {command}");
                return;
            }

            // Filter try-catch blocks
            if (firstStatement is TryStatementAst)
            {
                filteredCount++;
                logger?.LogDebug($"Skip try-catch in history: {command}");
                return;
            }

            // For pipeline commands, validate each command exists
            if (firstStatement is PipelineAst pipeline)
            {
                bool skipPipeline = false;

                foreach (var element in pipeline.PipelineElements)
                {
                    if (element is CommandAst cmd)
                    {
                        var cmdName = cmd.GetCommandName();

                        // Skip very short command names (likely typos)
                        if (string.IsNullOrWhiteSpace(cmdName) || cmdName.Length < 2)
                        {
                            skipPipeline = true;
                            logger?.LogDebug($"Skip short command in history: {cmdName}");
                            break;
                        }

                        // Skip commands that look like file paths
                        if (cmdName.Contains('/') || cmdName.Contains('\\'))
                        {
                            skipPipeline = true;
                            logger?.LogDebug($"Skip path-like command in history: {cmdName}");
                            break;
                        }
                    }
                }

                if (skipPipeline)
                {
                    filteredCount++;
                    return;
                }
            }

            // Passed all validation
            validated.Add(command);
            uniqueCommands.Add(command);
        }

        /// <summary>
        /// Validate a single command using AST analysis
        /// </summary>
        public static bool IsValidHistoryCommand(string command, FastLogger? logger = null)
        {
            if (string.IsNullOrWhiteSpace(command))
                return false;

            try
            {
                var ast = Parser.ParseInput(command, out _, out var errors);

                if (errors.Length > 0)
                    return false;

                var firstStatement = ast?.EndBlock?.Statements?.FirstOrDefault();
                if (firstStatement == null)
                    return false;

                // Check for unwanted statement types
                if (firstStatement is AssignmentStatementAst ||
                    firstStatement is IfStatementAst ||
                    firstStatement is LoopStatementAst ||
                    firstStatement is TryStatementAst)
                {
                    return false;
                }

                return true;
            }
            catch (Exception ex)
            {
                logger?.LogDebug($"Error validating command '{command}': {ex.Message}");
                return false;
            }
        }

        /// <summary>
        /// Get the path to the PowerShell history file
        /// </summary>
        private static string GetHistoryPath()
        {
            // Try PSReadLine history first (most common)
            var psReadLinePath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                "AppData", "Roaming", "Microsoft", "Windows", "PowerShell",
                "PSReadLine", "ConsoleHost_history.txt");

            if (File.Exists(psReadLinePath))
                return psReadLinePath;

            // Try alternative locations for different PowerShell versions
            var paths = new[]
            {
                // PowerShell Core on Windows
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".local", "share", "powershell", "PSReadLine", "ConsoleHost_history.txt"),

                // PowerShell Core on Linux/Mac
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    ".local", "share", "powershell", "PSReadLine", "Microsoft.PowerShell_profile.ps1_history.txt"),

                // Legacy Windows PowerShell
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    "AppData", "Roaming", "Microsoft", "Windows", "PowerShell",
                    "PSReadLine", "Microsoft.PowerShell_profile.ps1_history.txt")
            };

            foreach (var path in paths)
            {
                if (File.Exists(path))
                    return path;
            }

            // Return default path even if not found
            return psReadLinePath;
        }

        /// <summary>
        /// Load a subset of recent validated history
        /// </summary>
        public static List<string> LoadRecentValidatedHistory(int maxItems = 100, FastLogger? logger = null)
        {
            var allHistory = LoadValidatedHistory(logger);

            // Take the most recent items (history file typically has newest at end)
            if (allHistory.Count > maxItems)
            {
                return allHistory.Skip(allHistory.Count - maxItems).ToList();
            }

            return allHistory;
        }
    }
}