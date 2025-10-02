using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation.Language;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;
using System.Threading;
using System.Threading.Tasks;

namespace PowerAugerSharp
{
    public sealed class PowerAugerPredictor : ICommandPredictor
    {
        private static readonly Lazy<PowerAugerPredictor> _instance =
            new(() => new PowerAugerPredictor());

        public static PowerAugerPredictor Instance => _instance.Value;

        public Guid Id { get; } = new Guid("a7b2c3d4-e5f6-4789-abcd-ef0123456789");
        public string Name => "PowerAugerSharp";
        public string Description => "High-performance AI-powered command predictor with AST-based completions";

        private readonly BackgroundProcessor _pwshPool;
        private readonly FastCompletionStore _completionStore;
        private readonly SuggestionEngine _suggestionEngine;
        private readonly OllamaService _ollamaService;
        private readonly FastLogger _logger;
        private readonly ConcurrentDictionary<string, Task<List<string>>> _pendingCompletions;
        private readonly CancellationTokenSource _shutdownTokenSource;

        private PowerAugerPredictor()
        {
            _logger = new FastLogger();
            _logger.MinimumLevel = FastLogger.LogLevel.Debug;

            // Create PowerShell pool manager
            _pwshPool = new BackgroundProcessor(_logger, poolSize: 4);

            // Create completion store with promise support
            _completionStore = new FastCompletionStore(_logger, _pwshPool);

            // Create suggestion engine with completion store
            _suggestionEngine = new SuggestionEngine(_completionStore, _logger);

            // Create Ollama service for AI completions
            _ollamaService = new OllamaService(_logger);

            // Initialize pending completions tracker
            _pendingCompletions = new ConcurrentDictionary<string, Task<List<string>>>();

            _shutdownTokenSource = new CancellationTokenSource();

            // Load validated history asynchronously
            InitializeHistoryCache();

            _logger.LogInfo("PowerAugerSharp initialized with AST-based completions");
        }

        public SuggestionPackage GetSuggestion(
            PredictionClient client,
            PredictionContext context,
            CancellationToken cancellationToken)
        {
            try
            {
                var ast = context.InputAst;
                var cursorPosition = context.CursorPosition;

                if (ast == null)
                {
                    return new SuggestionPackage(new List<PredictiveSuggestion>());
                }

                var input = ast.Extent.Text;
                var currentCommand = ExtractCurrentCommand(input, cursorPosition.Offset);

                if (string.IsNullOrEmpty(currentCommand))
                {
                    return new SuggestionPackage(new List<PredictiveSuggestion>());
                }

                var suggestions = new List<PredictiveSuggestion>();

                // 1. Try synchronous caches first
                var quickResults = _completionStore.GetCompletions(currentCommand, 3);
                if (quickResults.Count > 0)
                {
                    foreach (var result in quickResults)
                    {
                        suggestions.Add(new PredictiveSuggestion(
                            result,
                            $"Cached: {result}"));
                    }

                    return new SuggestionPackage(suggestions);
                }

                // 2. Parse tokens for AST completion
                Token[]? tokens = null;
                ParseError[]? errors = null;
                var tempAst = Parser.ParseInput(input, out tokens, out errors);

                // 3. Check if we have a pending async completion ready
                var asyncKey = $"{input}:{cursorPosition.Offset}";

                if (_pendingCompletions.TryGetValue(asyncKey, out var pendingTask) &&
                    pendingTask.IsCompletedSuccessfully)
                {
                    var asyncResults = pendingTask.Result;
                    foreach (var result in asyncResults.Take(3))
                    {
                        suggestions.Add(new PredictiveSuggestion(
                            result,
                            $"PS: {result}"));
                    }

                    _pendingCompletions.TryRemove(asyncKey, out _);

                    if (suggestions.Count > 0)
                    {
                        return new SuggestionPackage(suggestions);
                    }
                }

                // 4. Start new async AST-based completion if not already pending
                if (!_pendingCompletions.ContainsKey(asyncKey) && tokens != null && errors.Length == 0)
                {
                    var completionTask = _completionStore.GetCompletionsFromAstAsync(
                        ast,
                        tokens,
                        cursorPosition,
                        5);

                    _pendingCompletions[asyncKey] = completionTask;

                    _ = completionTask.ContinueWith(t =>
                    {
                        Thread.Sleep(1000);
                        _pendingCompletions.TryRemove(asyncKey, out _);
                    });
                }

                // 5. Try suggestion engine patterns as fallback
                var engineSuggestions = _suggestionEngine.GetSuggestions(currentCommand, 3);
                if (engineSuggestions.Count > 0)
                {
                    foreach (var suggestion in engineSuggestions)
                    {
                        suggestions.Add(suggestion);
                    }
                }

                return new SuggestionPackage(suggestions);
            }
            catch (Exception ex)
            {
                _logger.LogError($"GetSuggestion failed: {ex.Message}");
                return new SuggestionPackage(new List<PredictiveSuggestion>());
            }
        }

        public void OnCommandLineAccepted(string commandLine)
        {
            try
            {
                _completionStore.RecordAcceptance(commandLine);
            }
            catch (Exception ex)
            {
                _logger.LogError($"OnCommandLineAccepted failed: {ex.Message}");
            }
        }

        public void OnCommandLineExecuted(string commandLine)
        {
            try
            {
                _completionStore.RecordExecution(commandLine);
            }
            catch (Exception ex)
            {
                _logger.LogError($"OnCommandLineExecuted failed: {ex.Message}");
            }
        }

        public void OnSuggestionDisplayed(string suggestion)
        {
        }

        public void OnSuggestionAccepted(string suggestion)
        {
            try
            {
                _completionStore.RecordSuggestionAcceptance(suggestion);
            }
            catch (Exception ex)
            {
                _logger.LogError($"OnSuggestionAccepted failed: {ex.Message}");
            }
        }

        public void OnHistory(string historyLine)
        {
            try
            {
                _completionStore.AddHistoryItem(historyLine);
            }
            catch (Exception ex)
            {
                _logger.LogError($"OnHistory failed: {ex.Message}");
            }
        }

        private static string ExtractCurrentCommand(string input, int cursorPosition)
        {
            if (string.IsNullOrEmpty(input))
                return string.Empty;

            // Find the start of the current command (after last semicolon or pipe)
            var commandStart = 0;
            for (var i = Math.Min(cursorPosition - 1, input.Length - 1); i >= 0; i--)
            {
                if (input[i] == ';' || input[i] == '|')
                {
                    commandStart = i + 1;
                    break;
                }
            }

            // Extract from start to cursor position
            var length = Math.Min(cursorPosition - commandStart, input.Length - commandStart);
            if (length <= 0)
                return string.Empty;

            return input.Substring(commandStart, length).TrimStart();
        }

        /// <summary>
        /// Initialize the history cache with validated commands
        /// </summary>
        private void InitializeHistoryCache()
        {
            _ = Task.Run(() =>
            {
                try
                {
                    _logger.LogInfo("Loading validated history...");

                    // Load validated history using the new PowerShellHistoryLoader
                    var history = PowerShellHistoryLoader.LoadValidatedHistory(_logger);

                    if (history.Count > 0)
                    {
                        foreach (var line in history)
                        {
                            // Only validate and add to cache if it passes AST validation
                            if (PowerShellHistoryLoader.IsValidHistoryCommand(line, _logger))
                            {
                                _completionStore.AddHistoryItem(line);
                            }
                        }

                        _logger.LogInfo($"Loaded {history.Count} validated history commands into cache");
                    }
                    else
                    {
                        _logger.LogWarning("No validated history commands found");
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogError($"Failed to initialize history cache: {ex.Message}");
                }
            });
        }

        public void Dispose()
        {
            _shutdownTokenSource?.Cancel();
            _shutdownTokenSource?.Dispose();
            _pendingCompletions?.Clear();
            _pwshPool?.Dispose();
            _completionStore?.Dispose();
            _ollamaService?.Dispose();
            _logger?.Dispose();
        }
    }
}
