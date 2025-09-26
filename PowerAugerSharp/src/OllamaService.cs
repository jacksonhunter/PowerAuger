using System;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace PowerAugerSharp
{
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

        public async Task<string?> GetCompletionAsync(string input, CancellationToken cancellationToken)
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

            await _throttle.WaitAsync(cancellationToken);
            try
            {
                var prompt = BuildFimPrompt(input);
                var requestBody = new
                {
                    model = _modelName,
                    prompt = prompt,
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

                        // Clean up the completion
                        if (!string.IsNullOrWhiteSpace(completion))
                        {
                            completion = completion.Trim();

                            // If completion starts with input, return full completion
                            if (completion.StartsWith(input, StringComparison.OrdinalIgnoreCase))
                            {
                                return completion;
                            }

                            // Otherwise, append to input
                            return input + completion;
                        }
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
                _logger.LogDebug("Ollama request timeout");
                RecordFailure("Timeout");
                return null;
            }
            catch (HttpRequestException ex)
            {
                _logger.LogDebug($"Ollama connection failed: {ex.Message}");
                RecordFailure($"Connection: {ex.Message}");
                return null;
            }
            catch (Exception ex)
            {
                _logger.LogError($"Ollama request failed: {ex.Message}");
                RecordFailure($"Error: {ex.Message}");
                return null;
            }
            finally
            {
                _throttle.Release();
            }
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