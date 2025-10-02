using System;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation.Subsystem.Prediction;

namespace PowerAugerSharp
{
    public sealed class SuggestionEngine
    {
        private readonly FastCompletionStore _completionStore;
        private readonly FastLogger _logger;

        public SuggestionEngine(FastCompletionStore completionStore, FastLogger logger)
        {
            _completionStore = completionStore;
            _logger = logger;
        }

        public List<PredictiveSuggestion> GetSuggestions(string input, int maxResults = 3)
        {
            var suggestions = new List<PredictiveSuggestion>();

            try
            {
                input = input.Trim();
                if (string.IsNullOrEmpty(input))
                {
                    return suggestions;
                }

                var completions = _completionStore.GetCompletions(input, maxResults);
                foreach (var completion in completions)
                {
                    suggestions.Add(new PredictiveSuggestion(completion, GetTooltip(input, completion)));
                }

                return suggestions;
            }
            catch (Exception ex)
            {
                _logger.LogError($"SuggestionEngine error: {ex.Message}");
                return suggestions;
            }
        }

        private static string GetTooltip(string input, string completion)
        {
            if (completion.StartsWith(input, StringComparison.OrdinalIgnoreCase))
            {
                var remaining = completion.Substring(input.Length);
                if (!string.IsNullOrEmpty(remaining))
                {
                    return $"Complete: {remaining}";
                }
            }

            return "Suggestion";
        }
    }
}