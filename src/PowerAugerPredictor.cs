using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation.Language;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;
using System.Threading;
using System.Threading.Tasks;

namespace PowerAuger
{
    public sealed class PowerAugerPredictor : ICommandPredictor
    {
        private static readonly Lazy<PowerAugerPredictor> _instance =
            new(() => new PowerAugerPredictor());

        public static PowerAugerPredictor Instance => _instance.Value;

        public Guid Id { get; } = new Guid("a7b2c3d4-e5f6-4789-abcd-ef0123456789");
        public string Name => "PowerAuger";
        public string Description => "High-performance AI-powered command predictor with AST-based completions";

        private readonly BackgroundProcessor _pwshPool;
        private readonly FrecencyStore _frecencyStore;
        private readonly CommandHistoryStore _commandHistory;
        private readonly FastCompletionStore _completionStore;
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

            // Create frecency store for storage and scoring
            _logger.LogInfo("Initializing FrecencyStore with Terminal/Transit pattern");
            _frecencyStore = new FrecencyStore(_logger, _pwshPool);
            _frecencyStore.Initialize();

            // Create unfiltered command history store (loads from JSON or PSReadLine history file)
            _logger.LogInfo("Initializing CommandHistoryStore");
            _commandHistory = new CommandHistoryStore(_logger);

            // Create completion store for AST validation and Ollama integration
            _completionStore = new FastCompletionStore(_logger, _pwshPool, _frecencyStore, _commandHistory);

            // Create Ollama service for AI completions
            _ollamaService = new OllamaService(_logger);

            // Initialize pending completions tracker
            _pendingCompletions = new ConcurrentDictionary<string, Task<List<string>>>();

            _shutdownTokenSource = new CancellationTokenSource();

            // History is already loaded by FrecencyStore.Initialize()
            // No need for duplicate loading

            _logger.LogInfo("PowerAuger initialized with AST-based completions");
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

                    // Trigger background Ollama enrichment for future requests
                    // Fire-and-forget - don't wait for it, user gets cached results immediately
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            Token[]? bgTokens = null;
                            ParseError[]? bgErrors = null;
                            var bgAst = Parser.ParseInput(input, out bgTokens, out bgErrors);

                            if (bgErrors?.Length == 0 && bgTokens != null)
                            {
                                _logger.LogDebug("Cache hit - triggering background Ollama enrichment");
                                // This will call Ollama and update FrecencyStore with AI suggestions
                                await _completionStore.GetCompletionsFromAstAsync(bgAst, bgTokens, cursorPosition, 3);
                            }
                        }
                        catch (Exception ex)
                        {
                            _logger.LogDebug($"Background enrichment failed: {ex.Message}");
                            // Swallow exceptions - this is best-effort enrichment
                        }
                    });

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
                if (!_pendingCompletions.ContainsKey(asyncKey) && tokens != null && errors?.Length == 0)
                {
                    var completionTask = _completionStore.GetCompletionsFromAstAsync(
                        ast,
                        tokens,
                        cursorPosition,
                        5);

                    _pendingCompletions[asyncKey] = completionTask;

                    _ = completionTask.ContinueWith(async t =>
                    {
                        await Task.Delay(1000);
                        _pendingCompletions.TryRemove(asyncKey, out _);
                    });
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
                // Both stores handle this
                _frecencyStore.IncrementRank(commandLine, 2.0f);
                _completionStore.RecordAcceptance(commandLine);
            }
            catch (Exception ex)
            {
                _logger.LogError($"OnCommandLineAccepted failed: {ex.Message}");
            }
        }

        public void OnCommandLineExecuted(PredictionClient client, string commandLine, bool success)
        {
            try
            {
                // Extract working directory
                var workingDirectory = Environment.CurrentDirectory;

                // Parse AST to get type
                string? astType = null;
                try
                {
                    Token[] tokens;
                    ParseError[] errors;
                    var ast = Parser.ParseInput(commandLine, out tokens, out errors);

                    if (errors == null || errors.Length == 0)
                    {
                        // Get the primary AST type
                        var firstStatement = ast?.EndBlock?.Statements?.FirstOrDefault();
                        if (firstStatement != null)
                        {
                            astType = firstStatement.GetType().Name;
                        }
                    }
                }
                catch
                {
                    // If AST parsing fails, continue without AST type
                }

                // Record to unfiltered history with full metadata
                _commandHistory.RecordCommand(commandLine, workingDirectory, success, astType);

                // Record to frecency store (validated commands only)
                _frecencyStore.IncrementRank(commandLine, 3.0f);
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
                // Both stores handle this
                _frecencyStore.IncrementRank(suggestion, 1.0f);
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
                // Both stores handle history
                _frecencyStore.IncrementRank(historyLine, 1.0f);
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


        public void Dispose()
        {
            _shutdownTokenSource?.Cancel();
            _shutdownTokenSource?.Dispose();
            _pendingCompletions?.Clear();
            _pwshPool?.Dispose();
            _frecencyStore?.Dispose();
            _completionStore?.Dispose();
            _ollamaService?.Dispose();
            _logger?.Dispose();
        }
    }
}
