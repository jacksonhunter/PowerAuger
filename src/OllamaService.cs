using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;

namespace PowerAuger
{
    public enum CompletionMode
    {
        Chat,      // /api/chat endpoint - conversational with context
        Generate   // /api/generate endpoint - FIM (fill-in-middle)
    }

    public sealed class OllamaService : IDisposable
    {
        private readonly HttpClient _httpClient;
        private readonly FastLogger _logger;
        private readonly string _fimModelName;
        private readonly string _chatModelName;
        private readonly string _generateApiUrl;
        private readonly string _chatApiUrl;
        private readonly SemaphoreSlim _throttle;

        // Circuit breaker
        private int _failureCount;
        private DateTime _lastFailure;
        private bool _isHalfOpen;
        private const int MaxFailures = 3;
        private const int CircuitBreakerResetMinutes = 5;

        public OllamaService(FastLogger logger)
        {
            _logger = logger;
            _fimModelName = "qwen2.5-0.5B-autocomplete-custom";
            _chatModelName = "Qwen3-Coder-30b-v0.2-custom:latest";
            _generateApiUrl = "http://127.0.0.1:11434/api/generate";
            _chatApiUrl = "http://127.0.0.1:11434/api/chat";

            _httpClient = new HttpClient
            {
                Timeout = TimeSpan.FromSeconds(10) // Longer for 30B model
            };

            _throttle = new SemaphoreSlim(1, 1);
        }

        #region Main Entry Point

        /// <summary>
        /// Get completion using validated command completions
        /// NOTE: Caller should implement retry logic to try both modes
        /// </summary>
        public async Task<string?> GetCompletionAsync(
            string input,
            CommandCompletion? tabCompletions,
            List<string> historyExamples,
            CompletionMode mode = CompletionMode.Generate,
            CancellationToken cancellationToken = default)
        {
            // Check circuit breaker
            if (_failureCount >= MaxFailures)
            {
                if ((DateTime.UtcNow - _lastFailure).TotalMinutes < CircuitBreakerResetMinutes)
                {
                    _logger.LogDebug("Circuit breaker open, skipping Ollama request");
                    return null;
                }

                _logger.LogDebug("Circuit breaker entering half-open state for recovery test");
                _isHalfOpen = true;
            }

            switch (mode)
            {
                case CompletionMode.Chat:
                    // For backwards compatibility - splits historyExamples into recent and relevant
                    var recentHistory = historyExamples.Take(10).ToList();
                    var relevantExamples = historyExamples.Skip(10).Take(5).ToList();
                    return await GetChatCompletionAsync(input, tabCompletions, recentHistory, relevantExamples, cancellationToken);

                case CompletionMode.Generate:
                    return await GetGenerateCompletionAsync(input, tabCompletions, historyExamples, cancellationToken);

                default:
                    return null;
            }
        }

        #endregion

        #region Chat Completion Overloads

        /// <summary>
        /// Standard chat completion with TabExpansion2 context
        /// </summary>
        public async Task<string?> GetChatCompletionAsync(
            string input,
            CommandCompletion? tabCompletions,
            List<string> recentHistory,
            List<string> relevantExamples,
            CancellationToken cancellationToken)
        {
            await _throttle.WaitAsync(cancellationToken);
            try
            {
                var systemPrompt = BuildChatSystemPrompt(input, tabCompletions, recentHistory);
                var messages = BuildChatMessages(systemPrompt, input, relevantExamples);

                return await ExecuteChatRequest(messages, cancellationToken);
            }
            finally
            {
                _throttle.Release();
            }
        }

        /// <summary>
        /// Warmup mode: Predict next command based on recent history
        /// </summary>
        public async Task<string?> GetNextCommandPredictionAsync(
            string[] lastTenCommands,
            List<string[]> historicalSequences,
            CancellationToken cancellationToken)
        {
            await _throttle.WaitAsync(cancellationToken);
            try
            {
                var systemPrompt = BuildWarmupSystemPrompt(lastTenCommands);
                var messages = BuildWarmupMessages(systemPrompt, lastTenCommands, historicalSequences);

                return await ExecuteChatRequest(messages, cancellationToken);
            }
            finally
            {
                _throttle.Release();
            }
        }

        /// <summary>
        /// Parameter refinement: Improve parameters on a full command
        /// </summary>
        public async Task<string?> RefineParametersAsync(
            string fullCommand,
            List<string> similarCommands,
            CancellationToken cancellationToken)
        {
            await _throttle.WaitAsync(cancellationToken);
            try
            {
                var systemPrompt = BuildParameterRefinementSystemPrompt(fullCommand, similarCommands);
                var messages = BuildParameterRefinementMessages(systemPrompt, fullCommand, similarCommands);

                return await ExecuteChatRequest(messages, cancellationToken);
            }
            finally
            {
                _throttle.Release();
            }
        }

        /// <summary>
        /// Pipeline building: Suggest pipeline additions
        /// </summary>
        public async Task<string?> BuildPipelineAsync(
            string partialPipeline,
            List<string> pipelineExamples,
            CancellationToken cancellationToken)
        {
            await _throttle.WaitAsync(cancellationToken);
            try
            {
                var systemPrompt = BuildPipelineSystemPrompt(partialPipeline, pipelineExamples);
                var messages = BuildPipelineMessages(systemPrompt, partialPipeline, pipelineExamples);

                return await ExecuteChatRequest(messages, cancellationToken);
            }
            finally
            {
                _throttle.Release();
            }
        }

        #endregion

        #region Chat System Prompts

        private string BuildChatSystemPrompt(string input, CommandCompletion? tabCompletions, List<string> recentHistory)
        {
            var sb = new StringBuilder();

            sb.AppendLine("You are a PowerShell autocomplete engine.");
            sb.AppendLine();
            sb.AppendLine($"TASK: Complete the command starting with: {input}");
            sb.AppendLine();

            // Recent context
            if (recentHistory.Count > 0)
            {
                sb.AppendLine("CONTEXT - Recent commands executed:");
                foreach (var cmd in recentHistory.Take(10))
                {
                    var preview = cmd.Length > 60 ? cmd.Substring(0, 60) + "..." : cmd;
                    sb.AppendLine($"- {preview}");
                }
                sb.AppendLine();
            }

            // Valid completions with ResultType and ToolTip
            if (tabCompletions?.CompletionMatches != null && tabCompletions.CompletionMatches.Count > 0)
            {
                sb.AppendLine("VALID COMPLETIONS from TabExpansion2:");
                foreach (var match in tabCompletions.CompletionMatches.Take(10))
                {
                    sb.Append($"- {match.CompletionText} [{match.ResultType}]");

                    if (!string.IsNullOrEmpty(match.ToolTip))
                    {
                        var tooltip = match.ToolTip.Replace("\n", " ").Replace("\r", "");
                        if (tooltip.Length > 80)
                            tooltip = tooltip.Substring(0, 80) + "...";
                        sb.Append($" - {tooltip}");
                    }

                    sb.AppendLine();
                }
                sb.AppendLine();
            }

            sb.AppendLine("RULES:");
            sb.AppendLine("1. Choose from the valid TabExpansion2 completions listed above");
            sb.AppendLine("2. Output ONLY the completed command");
            sb.AppendLine("3. No explanations or alternatives");
            sb.AppendLine("4. Prefer the most commonly used completion (usually first in list)");

            return sb.ToString();
        }

        private string BuildWarmupSystemPrompt(string[] lastTenCommands)
        {
            var sb = new StringBuilder();

            sb.AppendLine("You are a PowerShell command predictor.");
            sb.AppendLine("Given a sequence of recent commands, predict the next most likely command.");
            sb.AppendLine();
            sb.AppendLine("RECENT COMMANDS:");
            for (int i = 0; i < lastTenCommands.Length; i++)
            {
                sb.AppendLine($"{i + 1}. {lastTenCommands[i]}");
            }
            sb.AppendLine();
            sb.AppendLine("RULES:");
            sb.AppendLine("1. Output ONLY the predicted next command");
            sb.AppendLine("2. No explanations");
            sb.AppendLine("3. Base prediction on command patterns and workflow");

            return sb.ToString();
        }

        private string BuildParameterRefinementSystemPrompt(string fullCommand, List<string> similarCommands)
        {
            var sb = new StringBuilder();

            sb.AppendLine("You are a PowerShell parameter optimization expert.");
            sb.AppendLine($"Improve the parameters for: {fullCommand}");
            sb.AppendLine();

            if (similarCommands.Count > 0)
            {
                sb.AppendLine("SIMILAR COMMANDS from history:");
                foreach (var cmd in similarCommands.Take(5))
                {
                    sb.AppendLine($"- {cmd}");
                }
                sb.AppendLine();
            }

            sb.AppendLine("RULES:");
            sb.AppendLine("1. Suggest better parameter values or additional useful parameters");
            sb.AppendLine("2. Output ONLY the improved command");
            sb.AppendLine("3. Keep the base command and cmdlet the same");
            sb.AppendLine("4. No explanations");

            return sb.ToString();
        }

        private string BuildPipelineSystemPrompt(string partialPipeline, List<string> pipelineExamples)
        {
            var sb = new StringBuilder();

            sb.AppendLine("You are a PowerShell pipeline builder.");
            sb.AppendLine($"Extend this pipeline: {partialPipeline}");
            sb.AppendLine();

            if (pipelineExamples.Count > 0)
            {
                sb.AppendLine("PIPELINE EXAMPLES from history:");
                foreach (var example in pipelineExamples.Take(5))
                {
                    sb.AppendLine($"- {example}");
                }
                sb.AppendLine();
            }

            sb.AppendLine("RULES:");
            sb.AppendLine("1. Add the next most useful cmdlet to the pipeline");
            sb.AppendLine("2. Output ONLY the complete extended pipeline");
            sb.AppendLine("3. No explanations");
            sb.AppendLine("4. Focus on common PowerShell patterns");

            return sb.ToString();
        }

        #endregion

        #region Chat Message Builders

        private List<object> BuildChatMessages(string systemPrompt, string input, List<string> relevantExamples)
        {
            var messages = new List<object>
            {
                new { role = "system", content = systemPrompt }
            };

            // Build few-shot examples from history
            foreach (var example in relevantExamples.Take(3))
            {
                // Split at natural boundary (space or dash)
                var parts = example.Split(new[] { ' ', '-' }, 2);
                if (parts.Length > 0 && parts[0].Length > 2)
                {
                    var prefix = parts[0].Substring(0, Math.Min(parts[0].Length - 2, parts[0].Length));
                    messages.Add(new { role = "user", content = $"Complete: {prefix}" });
                    messages.Add(new { role = "assistant", content = example });
                }
            }

            // Actual request
            messages.Add(new { role = "user", content = $"Complete: {input}" });

            return messages;
        }

        private List<object> BuildWarmupMessages(string systemPrompt, string[] lastTenCommands, List<string[]> historicalSequences)
        {
            var messages = new List<object>
            {
                new { role = "system", content = systemPrompt }
            };

            // Build few-shot from historical sequences
            foreach (var sequence in historicalSequences.Take(3))
            {
                if (sequence.Length >= 2)
                {
                    var context = string.Join("\n", sequence.Take(sequence.Length - 1).Select((cmd, i) => $"{i + 1}. {cmd}"));
                    var nextCmd = sequence.Last();

                    messages.Add(new { role = "user", content = $"Recent commands:\n{context}\n\nPredict next command:" });
                    messages.Add(new { role = "assistant", content = nextCmd });
                }
            }

            // Actual prediction request
            messages.Add(new { role = "user", content = "Predict next command:" });

            return messages;
        }

        private List<object> BuildParameterRefinementMessages(string systemPrompt, string fullCommand, List<string> similarCommands)
        {
            var messages = new List<object>
            {
                new { role = "system", content = systemPrompt }
            };

            // Build few-shot from similar commands
            foreach (var similar in similarCommands.Take(3))
            {
                // Extract base cmdlet
                var parts = similar.Split(new[] { ' ' }, 2);
                if (parts.Length == 2)
                {
                    var baseParts = fullCommand.Split(new[] { ' ' }, 2);
                    if (baseParts.Length == 2 && baseParts[0] == parts[0])
                    {
                        messages.Add(new { role = "user", content = $"Improve: {baseParts[0]} {baseParts[1]}" });
                        messages.Add(new { role = "assistant", content = similar });
                    }
                }
            }

            // Actual refinement request
            messages.Add(new { role = "user", content = $"Improve: {fullCommand}" });

            return messages;
        }

        private List<object> BuildPipelineMessages(string systemPrompt, string partialPipeline, List<string> pipelineExamples)
        {
            var messages = new List<object>
            {
                new { role = "system", content = systemPrompt }
            };

            // Build few-shot from pipeline examples
            foreach (var example in pipelineExamples.Take(3))
            {
                var pipes = example.Split(new[] { '|' });
                if (pipes.Length >= 2)
                {
                    var partial = string.Join(" | ", pipes.Take(pipes.Length - 1)).Trim();
                    messages.Add(new { role = "user", content = $"Extend: {partial} |" });
                    messages.Add(new { role = "assistant", content = example });
                }
            }

            // Actual pipeline request
            messages.Add(new { role = "user", content = $"Extend: {partialPipeline} |" });

            return messages;
        }

        #endregion

        #region Chat Execution

        private async Task<string?> ExecuteChatRequest(List<object> messages, CancellationToken cancellationToken)
        {
            try
            {
                var requestBody = new
                {
                    model = _chatModelName,
                    messages = messages.ToArray(),
                    stream = false,
                    options = new
                    {
                        temperature = 0.0,  // Deterministic
                        num_predict = 80,
                        top_p = 0.9
                    }
                };

                var json = JsonSerializer.Serialize(requestBody);
                var content = new StringContent(json, Encoding.UTF8, "application/json");

                using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                cts.CancelAfter(TimeSpan.FromSeconds(5));

                var response = await _httpClient.PostAsync(_chatApiUrl, content, cts.Token);

                if (response.IsSuccessStatusCode)
                {
                    var responseJson = await response.Content.ReadAsStringAsync();
                    var responseData = JsonDocument.Parse(responseJson);

                    if (responseData.RootElement.TryGetProperty("message", out var messageElement) &&
                        messageElement.TryGetProperty("content", out var contentElement))
                    {
                        var completion = contentElement.GetString()?.Trim();

                        // Reset circuit breaker on success
                        if (_isHalfOpen)
                        {
                            _logger.LogDebug("Circuit breaker closing after successful test");
                            _isHalfOpen = false;
                        }
                        _failureCount = 0;

                        if (!string.IsNullOrEmpty(completion))
                        {
                            _logger.LogInfo($"Chat completion: '{completion}'");
                            return completion; // Return full command from chat
                        }
                    }
                }
                else
                {
                    RecordFailure($"HTTP {response.StatusCode}");
                }
            }
            catch (TaskCanceledException)
            {
                RecordFailure("Timeout");
            }
            catch (Exception ex)
            {
                RecordFailure($"Error: {ex.Message}");
            }

            return null;
        }

        #endregion

        #region FIM (Generate) Implementation

        private async Task<string?> GetGenerateCompletionAsync(
            string input,
            CommandCompletion? tabCompletions,
            List<string> historyExamples,
            CancellationToken cancellationToken)
        {
            await _throttle.WaitAsync(cancellationToken);
            try
            {
                var systemPrompt = BuildFIMSystemPrompt(input, tabCompletions);
                var prompt = BuildFIMPrompt(input, historyExamples);

                var requestBody = new
                {
                    model = _fimModelName,
                    prompt = prompt,
                    system = systemPrompt,
                    stream = false,
                    raw = false,
                    options = new
                    {
                        num_predict = 80,
                        temperature = 0.1,
                        top_p = 0.9,
                        stop = new[] {
                            "<|fim_prefix|>",
                            "<|fim_suffix|>",
                            "<|fim_middle|>",
                            "<|endoftext|>"
                        }
                    }
                };

                var json = JsonSerializer.Serialize(requestBody);
                var content = new StringContent(json, Encoding.UTF8, "application/json");

                using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                cts.CancelAfter(TimeSpan.FromSeconds(5));

                var response = await _httpClient.PostAsync(_generateApiUrl, content, cts.Token);

                if (response.IsSuccessStatusCode)
                {
                    var responseJson = await response.Content.ReadAsStringAsync();
                    var responseData = JsonDocument.Parse(responseJson);

                    if (responseData.RootElement.TryGetProperty("response", out var responseElement))
                    {
                        var completion = responseElement.GetString();

                        // Reset circuit breaker on success
                        if (_isHalfOpen)
                        {
                            _logger.LogDebug("Circuit breaker closing after successful test");
                            _isHalfOpen = false;
                        }
                        _failureCount = 0;

                        return CleanCompletion(input, completion);
                    }
                }
                else
                {
                    RecordFailure($"HTTP {response.StatusCode}");
                }
            }
            catch (TaskCanceledException)
            {
                RecordFailure("Timeout");
            }
            catch (Exception ex)
            {
                RecordFailure($"Error: {ex.Message}");
            }
            finally
            {
                _throttle.Release();
            }

            return null;
        }

        private string BuildFIMSystemPrompt(string input, CommandCompletion? tabCompletions)
        {
            var sb = new StringBuilder();

            sb.AppendLine("PowerShell command completion using FIM (Fill-In-Middle).");
            sb.AppendLine("Given: <|fim_prefix|>PARTIAL_COMMAND<|fim_suffix|><|fim_middle|>");
            sb.AppendLine("Return: ONLY the completion text to append after PARTIAL_COMMAND");
            sb.AppendLine("Do NOT repeat the prefix. Do NOT add explanations or multiple options.");
            sb.AppendLine();

            if (tabCompletions?.CompletionMatches != null && tabCompletions.CompletionMatches.Count > 0)
            {
                sb.AppendLine("Valid completions from PowerShell:");
                foreach (var match in tabCompletions.CompletionMatches.Take(5))
                {
                    sb.AppendLine($"  • {match.CompletionText}");
                }
                sb.AppendLine();
                sb.AppendLine("Choose the most likely completion from the list above.");
            }

            return sb.ToString();
        }

        private string BuildFIMPrompt(string input, List<string> historyExamples)
        {
            var sb = new StringBuilder();

            // Build few-shot examples - split at arbitrary points for FIM training
            foreach (var example in historyExamples.Take(3))
            {
                if (example.Length > input.Length)
                {
                    var prefix = example.Substring(0, input.Length);
                    var middle = example.Substring(input.Length);

                    sb.Append("<|fim_prefix|>");
                    sb.Append(prefix);
                    sb.Append("<|fim_suffix|>");
                    sb.Append("<|fim_middle|>");
                    sb.Append(middle);
                    sb.AppendLine("<|endoftext|>");
                }
            }

            // Main prompt
            sb.Append("<|fim_prefix|>");
            sb.Append(input);
            sb.Append("<|fim_suffix|>");
            sb.Append("<|fim_middle|>");

            return sb.ToString();
        }

        private string? CleanCompletion(string input, string? completion)
        {
            if (string.IsNullOrWhiteSpace(completion))
                return null;

            completion = completion.Trim();

            // Remove FIM tokens
            completion = completion.Replace("<|endoftext|>", "")
                                  .Replace("<|fim_prefix|>", "")
                                  .Replace("<|fim_suffix|>", "")
                                  .Replace("<|fim_middle|>", "")
                                  .Trim();

            if (string.IsNullOrWhiteSpace(completion))
                return null;

            // Chat returns full command, FIM returns suffix
            if (completion.StartsWith(input, StringComparison.OrdinalIgnoreCase))
            {
                return completion;
            }

            return input + completion;
        }

        #endregion

        #region Circuit Breaker

        private void RecordFailure(string reason)
        {
            if (_isHalfOpen)
            {
                _isHalfOpen = false;
                _failureCount = MaxFailures; // Maintain open state
                _lastFailure = DateTime.UtcNow;
                _logger.LogWarning($"Ollama circuit breaker re-opened after half-open test failure: {reason}");
                return;
            }

            _failureCount++;
            _lastFailure = DateTime.UtcNow;
            _logger.LogDebug($"Ollama failure #{_failureCount}: {reason}");

            if (_failureCount >= MaxFailures)
            {
                _logger.LogWarning($"Ollama circuit breaker opened after {MaxFailures} failures");
            }
        }

        #endregion

        public void Dispose()
        {
            _httpClient?.Dispose();
            _throttle?.Dispose();
        }
    }
}
