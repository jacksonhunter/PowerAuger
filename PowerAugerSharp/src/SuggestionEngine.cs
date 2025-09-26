using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Management.Automation.Subsystem.Prediction;
using System.Runtime.CompilerServices;
using System.Text.RegularExpressions;

namespace PowerAugerSharp
{
    public sealed class SuggestionEngine
    {
        private readonly FastCompletionStore _completionStore;
        private readonly FastLogger _logger;

        // Pre-compiled regex patterns for common scenarios
        private static readonly Regex CommandPattern = new(@"^[A-Z][a-z]+\-", RegexOptions.Compiled | RegexOptions.IgnoreCase);
        private static readonly Regex ParameterPattern = new(@"^\-[A-Za-z]", RegexOptions.Compiled);
        private static readonly Regex PathPattern = new(@"[\\\/]", RegexOptions.Compiled);
        private static readonly Regex VariablePattern = new(@"^\$", RegexOptions.Compiled);

        // Quick lookup tables for common patterns
        private readonly Dictionary<string, string[]> _quickPatterns;
        private readonly Dictionary<string, Func<string, List<string>>> _patternGenerators;

        public SuggestionEngine(FastCompletionStore completionStore, FastLogger logger)
        {
            _completionStore = completionStore;
            _logger = logger;

            _quickPatterns = InitializeQuickPatterns();
            _patternGenerators = InitializePatternGenerators();
        }

        [MethodImpl(MethodImplOptions.AggressiveOptimization)]
        public List<PredictiveSuggestion> GetSuggestions(string input, int maxResults = 3)
        {
            var stopwatch = Stopwatch.StartNew();
            var suggestions = new List<PredictiveSuggestion>();

            try
            {
                // Trim input for processing
                input = input.Trim();
                if (string.IsNullOrEmpty(input))
                {
                    return suggestions;
                }

                // Step 1: Check completion store (fastest)
                var completions = _completionStore.GetCompletions(input, maxResults * 2);
                foreach (var completion in completions.Take(maxResults))
                {
                    suggestions.Add(new PredictiveSuggestion(completion, GetTooltip(input, completion)));
                }

                if (suggestions.Count >= maxResults)
                {
                    stopwatch.Stop();
                    _logger.LogDebug($"SuggestionEngine returned {suggestions.Count} suggestions in {stopwatch.ElapsedMilliseconds}ms (cache hit)");
                    return suggestions;
                }

                // Step 2: Pattern-based suggestions
                var patternSuggestions = GetPatternSuggestions(input, maxResults - suggestions.Count);
                foreach (var suggestion in patternSuggestions)
                {
                    if (!suggestions.Any(s => s.SuggestionText == suggestion))
                    {
                        suggestions.Add(new PredictiveSuggestion(suggestion, "Pattern match"));
                    }
                }

                if (suggestions.Count >= maxResults)
                {
                    stopwatch.Stop();
                    _logger.LogDebug($"SuggestionEngine returned {suggestions.Count} suggestions in {stopwatch.ElapsedMilliseconds}ms (pattern)");
                    return suggestions.Take(maxResults).ToList();
                }

                // Step 3: Generate smart completions
                var smartCompletions = GenerateSmartCompletions(input, maxResults - suggestions.Count);
                foreach (var completion in smartCompletions)
                {
                    if (!suggestions.Any(s => s.SuggestionText == completion))
                    {
                        suggestions.Add(new PredictiveSuggestion(completion, "Smart completion"));
                    }
                }

                stopwatch.Stop();
                _logger.LogDebug($"SuggestionEngine returned {suggestions.Count} suggestions in {stopwatch.ElapsedMilliseconds}ms (full)");

                return suggestions.Take(maxResults).ToList();
            }
            catch (Exception ex)
            {
                _logger.LogError($"SuggestionEngine error: {ex.Message}");
                return suggestions;
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private List<string> GetPatternSuggestions(string input, int maxResults)
        {
            var results = new List<string>();

            // Check quick patterns first
            if (_quickPatterns.TryGetValue(input.ToLowerInvariant(), out var quickResults))
            {
                results.AddRange(quickResults.Take(maxResults));
                return results;
            }

            // Check pattern generators
            foreach (var generator in _patternGenerators)
            {
                if (input.StartsWith(generator.Key, StringComparison.OrdinalIgnoreCase))
                {
                    var generated = generator.Value(input);
                    results.AddRange(generated.Take(maxResults - results.Count));

                    if (results.Count >= maxResults)
                        break;
                }
            }

            return results;
        }

        private List<string> GenerateSmartCompletions(string input, int maxResults)
        {
            var completions = new List<string>();

            // Detect input type and generate appropriate completions
            if (CommandPattern.IsMatch(input))
            {
                // PowerShell command pattern
                completions.AddRange(GenerateCommandCompletions(input, maxResults));
            }
            else if (ParameterPattern.IsMatch(input))
            {
                // Parameter completion
                completions.AddRange(GenerateParameterCompletions(input, maxResults));
            }
            else if (PathPattern.IsMatch(input))
            {
                // Path completion
                completions.AddRange(GeneratePathCompletions(input, maxResults));
            }
            else if (VariablePattern.IsMatch(input))
            {
                // Variable completion
                completions.AddRange(GenerateVariableCompletions(input, maxResults));
            }
            else if (input.Length == 1)
            {
                // Single character - provide common commands starting with that letter
                completions.AddRange(GenerateSingleCharCompletions(input[0], maxResults));
            }

            return completions;
        }

        private List<string> GenerateCommandCompletions(string input, int maxResults)
        {
            var completions = new List<string>();

            // Extract the verb part
            var dashIndex = input.IndexOf('-');
            if (dashIndex > 0)
            {
                var verb = input.Substring(0, dashIndex);
                var noun = dashIndex < input.Length - 1 ? input.Substring(dashIndex + 1) : "";

                // Common PowerShell nouns for each verb
                var commonNouns = verb.ToLowerInvariant() switch
                {
                    "get" => new[] { "ChildItem", "Content", "Process", "Service", "Help", "Command", "Location", "Item" },
                    "set" => new[] { "Location", "Content", "Variable", "ExecutionPolicy", "Item", "ItemProperty" },
                    "new" => new[] { "Item", "Object", "Variable", "PSDrive", "Module", "Alias" },
                    "remove" => new[] { "Item", "Variable", "PSDrive", "Module", "Job" },
                    "start" => new[] { "Process", "Service", "Transcript", "Sleep", "Job" },
                    "stop" => new[] { "Process", "Service", "Transcript", "Computer", "Job" },
                    "test" => new[] { "Path", "Connection", "NetConnection", "ComputerSecureChannel" },
                    _ => Array.Empty<string>()
                };

                foreach (var commonNoun in commonNouns)
                {
                    if (commonNoun.StartsWith(noun, StringComparison.OrdinalIgnoreCase))
                    {
                        completions.Add($"{verb}-{commonNoun}");
                        if (completions.Count >= maxResults)
                            break;
                    }
                }
            }

            return completions;
        }

        private List<string> GenerateParameterCompletions(string input, int maxResults)
        {
            var completions = new List<string>();

            // Common PowerShell parameters
            var commonParams = new[]
            {
                "-Path", "-Name", "-Force", "-Recurse", "-Filter",
                "-Include", "-Exclude", "-WhatIf", "-Confirm",
                "-Verbose", "-Debug", "-ErrorAction", "-WarningAction",
                "-OutVariable", "-OutBuffer", "-PassThru"
            };

            var paramStart = input.Substring(1);
            foreach (var param in commonParams)
            {
                if (param.StartsWith(input, StringComparison.OrdinalIgnoreCase))
                {
                    completions.Add(param);
                    if (completions.Count >= maxResults)
                        break;
                }
            }

            return completions;
        }

        private List<string> GeneratePathCompletions(string input, int maxResults)
        {
            var completions = new List<string>();

            // Basic path completions - in real implementation, would check file system
            if (input.EndsWith("\\") || input.EndsWith("/"))
            {
                completions.Add(input + "Users");
                completions.Add(input + "Program Files");
                completions.Add(input + "Windows");
            }

            return completions.Take(maxResults).ToList();
        }

        private List<string> GenerateVariableCompletions(string input, int maxResults)
        {
            var completions = new List<string>();

            // Common PowerShell automatic variables
            var commonVars = new[]
            {
                "$PSVersionTable", "$HOME", "$PWD", "$Host",
                "$Error", "$LastExitCode", "$?", "$true", "$false",
                "$null", "$env:", "$PSScriptRoot", "$MyInvocation"
            };

            foreach (var var in commonVars)
            {
                if (var.StartsWith(input, StringComparison.OrdinalIgnoreCase))
                {
                    completions.Add(var);
                    if (completions.Count >= maxResults)
                        break;
                }
            }

            return completions;
        }

        private List<string> GenerateSingleCharCompletions(char c, int maxResults)
        {
            var completions = new List<string>();

            var suggestions = char.ToLowerInvariant(c) switch
            {
                'g' => new[] { "git", "Get-ChildItem", "Get-Process", "Get-Content" },
                's' => new[] { "Set-Location", "Start-Process", "Stop-Process" },
                'c' => new[] { "cd", "Clear-Host", "Copy-Item" },
                'r' => new[] { "Remove-Item", "Rename-Item", "Restart-Computer" },
                'n' => new[] { "New-Item", "notepad", "npm" },
                'i' => new[] { "ipconfig", "Invoke-WebRequest", "Import-Module" },
                't' => new[] { "Test-Path", "Test-Connection", "type" },
                'e' => new[] { "echo", "exit", "explorer" },
                'd' => new[] { "dir", "docker", "dotnet" },
                'p' => new[] { "pwd", "ping", "python", "powershell" },
                _ => Array.Empty<string>()
            };

            completions.AddRange(suggestions.Take(maxResults));
            return completions;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
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

        private Dictionary<string, string[]> InitializeQuickPatterns()
        {
            return new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
            {
                ["cd"] = new[] { "cd ..", "cd ~", "cd -" },
                ["ls"] = new[] { "ls -la", "ls -Force", "ls -Recurse" },
                ["git"] = new[] { "git status", "git add .", "git commit -m", "git push", "git pull" },
                ["docker"] = new[] { "docker ps", "docker images", "docker run", "docker build" },
                ["npm"] = new[] { "npm install", "npm run", "npm start", "npm test" },
                ["dotnet"] = new[] { "dotnet build", "dotnet run", "dotnet test", "dotnet publish" },
                ["pip"] = new[] { "pip install", "pip list", "pip freeze" },
                ["python"] = new[] { "python -m", "python script.py", "python -c" }
            };
        }

        private Dictionary<string, Func<string, List<string>>> InitializePatternGenerators()
        {
            return new Dictionary<string, Func<string, List<string>>>(StringComparer.OrdinalIgnoreCase)
            {
                ["get-"] = input => GenerateCommandCompletions(input, 5),
                ["set-"] = input => GenerateCommandCompletions(input, 5),
                ["new-"] = input => GenerateCommandCompletions(input, 5),
                ["remove-"] = input => GenerateCommandCompletions(input, 5),
                ["test-"] = input => GenerateCommandCompletions(input, 5),
                ["start-"] = input => GenerateCommandCompletions(input, 5),
                ["stop-"] = input => GenerateCommandCompletions(input, 5)
            };
        }
    }
}