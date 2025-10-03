using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Management.Automation;
using System.Management.Automation.Language;

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
        private readonly string _modelName;
        private readonly string _apiUrl;
        private readonly SemaphoreSlim _throttle;

        // Circuit breaker
        private int _failureCount;
        private DateTime _lastFailure;
        private const int MaxFailures = 3;
        private const int CircuitBreakerResetMinutes = 5;

        public OllamaService(FastLogger logger)
        {
            _logger = logger;
            _modelName = "qwen2.5-0.5B-autocomplete-custom";
            _apiUrl = "http://127.0.0.1:11434/api/generate";

            _httpClient = new HttpClient
            {
                Timeout = TimeSpan.FromMilliseconds(500)
            };

            _throttle = new SemaphoreSlim(1, 1);
        }

        /// <summary>
        /// Get completion using validated command completions with tooltips
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

                // Reset circuit breaker
                _failureCount = 0;
            }

            switch (mode)
            {
                case CompletionMode.Chat:
                    return await GetChatCompletionAsync(input, tabCompletions, historyExamples, cancellationToken);

                case CompletionMode.Generate:
                    return await GetGenerateCompletionAsync(input, tabCompletions, historyExamples, cancellationToken);

                default:
                    return null;
            }
        }

        /// <summary>
        /// Get completion using chat mode with rich context from tooltips
        /// </summary>
        private async Task<string?> GetChatCompletionAsync(
            string input,
            CommandCompletion? tabCompletions,
            List<string> historyExamples,
            CancellationToken cancellationToken)
        {
            await _throttle.WaitAsync(cancellationToken);
            try
            {
                // Build context from validated completions
                var contextBuilder = new StringBuilder();
                contextBuilder.AppendLine("Available PowerShell completions:");

                if (tabCompletions?.CompletionMatches != null)
                {
                    foreach (var match in tabCompletions.CompletionMatches.Take(10))
                    {
                        contextBuilder.AppendLine($"- {match.CompletionText}");

                        // Tooltip has rich context: parameter syntax, types, documentation
                        if (!string.IsNullOrEmpty(match.ToolTip))
                        {
                            contextBuilder.AppendLine($"  Info: {match.ToolTip}");
                        }
                    }
                }

                // Add similar commands from history
                if (historyExamples.Count > 0)
                {
                    contextBuilder.AppendLine("\nSimilar commands from your history:");
                    foreach (var example in historyExamples.Take(3))
                    {
                        contextBuilder.AppendLine($"- {example}");
                    }
                }

                // Build chat messages
                var messages = new[]
                {
                    new {
                        role = "system",
                        content = "You are a PowerShell completion assistant. Suggest the most likely command completion based on available completions and history."
                    },
                    new {
                        role = "user",
                        content = contextBuilder.ToString()
                    },
                    new {
                        role = "user",
                        content = $"Complete this command: {input}"
                    }
                };

                var requestBody = new
                {
                    model = _modelName,
                    messages = messages,
                    stream = false,
                    options = new
                    {
                        num_predict = 80,
                        temperature = 0.2,
                        top_p = 0.9
                    }
                };

                var json = JsonSerializer.Serialize(requestBody);
                var content = new StringContent(json, Encoding.UTF8, "application/json");

                using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                cts.CancelAfter(TimeSpan.FromMilliseconds(500));

                var chatApiUrl = "http://127.0.0.1:11434/api/chat";
                var response = await _httpClient.PostAsync(chatApiUrl, content, cts.Token);

                if (response.IsSuccessStatusCode)
                {
                    var responseJson = await response.Content.ReadAsStringAsync();
                    var responseData = JsonDocument.Parse(responseJson);

                    if (responseData.RootElement.TryGetProperty("message", out var messageElement) &&
                        messageElement.TryGetProperty("content", out var contentElement))
                    {
                        var completion = contentElement.GetString();

                        // Reset failure count on success
                        _failureCount = 0;

                        return CleanCompletion(input, completion);
                    }
                }
                else
                {
                    RecordFailure($"HTTP {response.StatusCode}");
                }

                return null;
            }
            catch (TaskCanceledException)
            {
                _logger.LogDebug("Ollama chat request timeout");
                RecordFailure("Timeout");
                return null;
            }
            catch (Exception ex)
            {
                _logger.LogError($"Ollama chat request failed: {ex.Message}");
                RecordFailure($"Error: {ex.Message}");
                return null;
            }
            finally
            {
                _throttle.Release();
            }
        }

        /// <summary>
        /// Get completion using generate mode with FIM (fill-in-middle)
        /// </summary>
        private async Task<string?> GetGenerateCompletionAsync(
            string input,
            CommandCompletion? tabCompletions,
            List<string> historyExamples,
            CancellationToken cancellationToken)
        {
            await _throttle.WaitAsync(cancellationToken);
            try
            {
                // Build FIM prompt with few-shot examples
                var promptBuilder = new StringBuilder();
                promptBuilder.AppendLine($"# PowerShell - {Environment.CurrentDirectory}");

                // Add few-shot examples from validated history
                foreach (var example in historyExamples.Take(3))
                {
                    var prefix = ExtractPrefix(example);
                    promptBuilder.AppendLine($"<|fim_prefix|>{prefix}<|fim_suffix|><|fim_middle|>{example}");
                }

                // Add context from validated completions
                if (tabCompletions?.CompletionMatches != null && tabCompletions.CompletionMatches.Count > 0)
                {
                    promptBuilder.AppendLine("# Available completions:");
                    foreach (var match in tabCompletions.CompletionMatches.Take(5))
                    {
                        promptBuilder.AppendLine($"# - {match.CompletionText}");
                    }
                }

                // Add actual FIM prompt
                promptBuilder.AppendLine($"<|fim_prefix|>{input}<|fim_suffix|><|fim_middle|>");

                var requestBody = new
                {
                    model = _modelName,
                    prompt = promptBuilder.ToString(),
                    stream = false,
                    options = new
                    {
                        num_predict = 80,
                        temperature = 0.2,
                        top_p = 0.9
                    }
                };

                var json = JsonSerializer.Serialize(requestBody);
                var content = new StringContent(json, Encoding.UTF8, "application/json");

                using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                cts.CancelAfter(TimeSpan.FromMilliseconds(500));

                var response = await _httpClient.PostAsync(_apiUrl, content, cts.Token);

                if (response.IsSuccessStatusCode)
                {
                    var responseJson = await response.Content.ReadAsStringAsync();
                    var responseData = JsonDocument.Parse(responseJson);

                    if (responseData.RootElement.TryGetProperty("response", out var responseElement))
                    {
                        var completion = responseElement.GetString();

                        // Reset failure count on success
                        _failureCount = 0;

                        return CleanCompletion(input, completion);
                    }
                }
                else
                {
                    RecordFailure($"HTTP {response.StatusCode}");
                }

                return null;
            }
            catch (TaskCanceledException)
            {
                _logger.LogDebug("Ollama generate request timeout");
                RecordFailure("Timeout");
                return null;
            }
            catch (Exception ex)
            {
                _logger.LogError($"Ollama generate request failed: {ex.Message}");
                RecordFailure($"Error: {ex.Message}");
                return null;
            }
            finally
            {
                _throttle.Release();
            }
        }

        /// <summary>
        /// Get validated few-shot examples from history
        /// </summary>
        public List<string> GetFewShotExamples(string input, FastCompletionStore store)
        {
            // Get similar commands from history
            var examples = store.GetFewShotExamples(input, maxExamples: 5);

            // Filter using same validation logic
            var validated = new List<string>();
            foreach (var example in examples)
            {
                var ast = Parser.ParseInput(example, out _, out var errors);
                if (errors.Length > 0) continue;

                var firstStatement = ast?.EndBlock?.Statements?.FirstOrDefault();
                if (firstStatement == null) continue;

                // Skip assignments and if-statements
                if (firstStatement is AssignmentStatementAst) continue;
                if (firstStatement is IfStatementAst) continue;

                validated.Add(example);
                if (validated.Count >= 3) break;
            }

            return validated;
        }

        /// <summary>
        /// Clean up completion response
        /// </summary>
        private string? CleanCompletion(string input, string? completion)
        {
            if (string.IsNullOrWhiteSpace(completion))
                return null;

            completion = completion.Trim();

            // If completion starts with input, return full completion
            if (completion.StartsWith(input, StringComparison.OrdinalIgnoreCase))
            {
                return completion;
            }

            // Otherwise, append to input
            return input + completion;
        }

        /// <summary>
        /// Extract prefix from a complete command for FIM examples
        /// </summary>
        private string ExtractPrefix(string command)
        {
            if (command.Length <= 3)
                return command;

            // Take first few characters as prefix
            var prefixLength = Math.Min(command.Length / 3, 10);
            return command.Substring(0, prefixLength);
        }

        private string BuildFimPrompt(string input)
        {
            // FIM (Fill-in-Middle) format for Qwen2.5
            var currentDir = Environment.CurrentDirectory;
            var dirName = System.IO.Path.GetFileName(currentDir);

            // Build context-aware prompt
            var prompt = $"# PowerShell - Dir: {dirName}\n";

            // Add some context examples (these would ideally come from history)
            prompt += GetContextExamples(input);

            // Add the actual FIM prompt
            prompt += $"<|fim_prefix|>{input}<|fim_suffix|><|fim_middle|>";

            return prompt;
        }

        private string GetContextExamples(string input)
        {
            // In production, this would pull from actual command history
            // For now, provide relevant static examples based on input pattern

            if (input.StartsWith("Get-", StringComparison.OrdinalIgnoreCase))
            {
                return "<|fim_prefix|>Get-Ch<|fim_suffix|><|fim_middle|>Get-ChildItem\n" +
                       "<|fim_prefix|>Get-Co<|fim_suffix|><|fim_middle|>Get-Content\n";
            }

            if (input.StartsWith("git", StringComparison.OrdinalIgnoreCase))
            {
                return "<|fim_prefix|>git st<|fim_suffix|><|fim_middle|>git status\n" +
                       "<|fim_prefix|>git co<|fim_suffix|><|fim_middle|>git commit -m\n";
            }

            if (input.Length == 1)
            {
                switch (char.ToLowerInvariant(input[0]))
                {
                    case 'g':
                        return "<|fim_prefix|>g<|fim_suffix|><|fim_middle|>git status\n";
                    case 's':
                        return "<|fim_prefix|>s<|fim_suffix|><|fim_middle|>Set-Location\n";
                    case 'c':
                        return "<|fim_prefix|>c<|fim_suffix|><|fim_middle|>cd\n";
                }
            }

            // Default examples
            return "<|fim_prefix|>Get-<|fim_suffix|><|fim_middle|>Get-ChildItem\n";
        }

        private void RecordFailure(string reason)
        {
            _failureCount++;
            _lastFailure = DateTime.UtcNow;
            _logger.LogDebug($"Ollama failure #{_failureCount}: {reason}");

            if (_failureCount >= MaxFailures)
            {
                _logger.LogWarning($"Ollama circuit breaker opened after {MaxFailures} failures");
            }
        }

        public void Dispose()
        {
            _httpClient?.Dispose();
            _throttle?.Dispose();
        }
    }
}