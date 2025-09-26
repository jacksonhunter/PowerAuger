using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Management.Automation.Subsystem;
using System.Management.Automation.Subsystem.Prediction;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Channels;
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
        public string Description => "High-performance AI-powered command predictor";

        private readonly FastCompletionStore _completionStore;
        private readonly SuggestionEngine _suggestionEngine;
        private readonly OllamaService _ollamaService;
        private readonly Channel<PredictionRequest> _requestChannel;
        private readonly FastLogger _logger;
        private readonly CancellationTokenSource _shutdownTokenSource;
        private readonly Task _backgroundTask;

        private PowerAugerPredictor()
        {
            _logger = new FastLogger();
            _logger.MinimumLevel = FastLogger.LogLevel.Debug;  // Enable debug logging
            _completionStore = new FastCompletionStore(_logger);
            _suggestionEngine = new SuggestionEngine(_completionStore, _logger);
            _ollamaService = new OllamaService(_logger);

            _requestChannel = Channel.CreateBounded<PredictionRequest>(new BoundedChannelOptions(10)
            {
                FullMode = BoundedChannelFullMode.Wait,
                SingleReader = true,
                SingleWriter = false
            });

            _shutdownTokenSource = new CancellationTokenSource();
            _backgroundTask = Task.Run(() => ProcessPredictionRequests(_shutdownTokenSource.Token));

            _logger.LogInfo("PowerAugerSharp initialized");
        }

        public SuggestionPackage GetSuggestion(
            PredictionClient client,
            PredictionContext context,
            CancellationToken cancellationToken)
        {
            var stopwatch = Stopwatch.StartNew();
            try
            {
                var input = context.InputAst.Extent.Text;
                var cursorPosition = context.CursorPosition.Offset;

                // Extract just the current command being typed
                var currentCommand = ExtractCurrentCommand(input, cursorPosition);
                if (string.IsNullOrEmpty(currentCommand))
                {
                    return new SuggestionPackage(new List<PredictiveSuggestion>());
                }

                // Get suggestions from our fast engine
                var suggestions = _suggestionEngine.GetSuggestions(currentCommand, 3);

                // Queue background prediction if we have capacity
                if (_requestChannel.Writer.TryWrite(new PredictionRequest
                {
                    Input = currentCommand,
                    Timestamp = DateTime.UtcNow
                }))
                {
                    _logger.LogDebug($"Queued prediction for: {currentCommand}");
                }

                stopwatch.Stop();
                _logger.LogDebug($"GetSuggestion completed in {stopwatch.ElapsedMilliseconds}ms with {suggestions.Count} suggestions");

                if (suggestions.Count > 0)
                {
                    return new SuggestionPackage(suggestions);
                }

                return new SuggestionPackage(new List<PredictiveSuggestion>());
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
                _logger.LogDebug($"Command accepted: {commandLine}");
            }
            catch (Exception ex)
            {
                _logger.LogError($"OnCommandLineAccepted failed: {ex.Message}");
            }
        }

        public void OnCommandLineExecuted(string commandLine)
        {
            // Track executed commands for learning
            _completionStore.RecordExecution(commandLine);
        }

        public void OnSuggestionDisplayed(string suggestion)
        {
            // Track which suggestions are shown
            _logger.LogDebug($"Suggestion displayed: {suggestion}");
        }

        public void OnSuggestionAccepted(string suggestion)
        {
            // Track accepted suggestions for improving predictions
            _completionStore.RecordSuggestionAcceptance(suggestion);
            _logger.LogInfo($"Suggestion accepted: {suggestion}");
        }

        public void OnHistory(string historyLine)
        {
            // Process history for learning patterns
            _completionStore.AddHistoryItem(historyLine);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
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

        private async Task ProcessPredictionRequests(CancellationToken cancellationToken)
        {
            var reader = _requestChannel.Reader;

            while (!cancellationToken.IsCancellationRequested)
            {
                try
                {
                    if (await reader.WaitToReadAsync(cancellationToken))
                    {
                        while (reader.TryRead(out var request))
                        {
                            // Skip if request is too old
                            if ((DateTime.UtcNow - request.Timestamp).TotalMilliseconds > 500)
                                continue;

                            // Get Ollama prediction
                            var prediction = await _ollamaService.GetCompletionAsync(
                                request.Input,
                                cancellationToken);

                            if (!string.IsNullOrEmpty(prediction))
                            {
                                _completionStore.CachePrediction(request.Input, prediction);
                            }
                        }
                    }
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    _logger.LogError($"Background prediction error: {ex.Message}");
                }
            }
        }

        public void Dispose()
        {
            _shutdownTokenSource?.Cancel();
            _backgroundTask?.Wait(TimeSpan.FromSeconds(1));
            _shutdownTokenSource?.Dispose();
            _requestChannel?.Writer.TryComplete();
            _completionStore?.Dispose();
            _ollamaService?.Dispose();
            _logger?.Dispose();
        }

        private class PredictionRequest
        {
            public string Input { get; set; } = string.Empty;
            public DateTime Timestamp { get; set; }
        }
    }
}