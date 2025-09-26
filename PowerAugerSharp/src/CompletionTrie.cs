using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading;

namespace PowerAugerSharp
{
    public sealed class CompletionTrie
    {
        private class TrieNode
        {
            // Use array for ASCII printable chars (space to ~, 32-126 = 95 chars)
            // Much faster than Dictionary for single-char lookups
            public readonly TrieNode?[] Children = new TrieNode?[95];

            // Store completions directly at node (not just at leaves)
            // Sorted by score for fast access
            public List<CompletionEntry>? Completions;

            // Lock for thread-safe updates
            public readonly ReaderWriterLockSlim Lock = new();

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public TrieNode? GetChild(char c)
            {
                int index = c - 32;
                return (index >= 0 && index < 95) ? Children[index] : null;
            }

            [MethodImpl(MethodImplOptions.AggressiveInlining)]
            public void SetChild(char c, TrieNode node)
            {
                int index = c - 32;
                if (index >= 0 && index < 95)
                {
                    Children[index] = node;
                }
            }
        }

        private struct CompletionEntry : IComparable<CompletionEntry>
        {
            public string Text;
            public float Score;
            public CompletionType Type;
            public int LastUsedTicks;

            public int CompareTo(CompletionEntry other)
            {
                // Sort by score descending
                return other.Score.CompareTo(Score);
            }
        }

        private enum CompletionType : byte
        {
            Command = 0,
            Parameter = 1,
            Path = 2,
            History = 3,
            AI = 4
        }

        private readonly TrieNode _root = new();
        private readonly ReaderWriterLockSlim _rootLock = new();

        // Statistics
        private int _nodeCount;
        private int _completionCount;

        public void AddCompletion(string prefix, string completion, float score)
        {
            if (string.IsNullOrEmpty(prefix) || string.IsNullOrEmpty(completion))
                return;

            // Normalize prefix to lowercase for case-insensitive matching
            prefix = prefix.ToLowerInvariant();

            _rootLock.EnterReadLock();
            try
            {
                var node = _root;
                var nodesToUpdate = new List<TrieNode> { _root };

                // Traverse/create path
                foreach (char c in prefix)
                {
                    var child = node.GetChild(c);
                    if (child == null)
                    {
                        // Need to upgrade to write lock to create new node
                        _rootLock.ExitReadLock();
                        _rootLock.EnterWriteLock();
                        try
                        {
                            // Double-check after acquiring write lock
                            child = node.GetChild(c);
                            if (child == null)
                            {
                                child = new TrieNode();
                                node.SetChild(c, child);
                                Interlocked.Increment(ref _nodeCount);
                            }
                        }
                        finally
                        {
                            _rootLock.ExitWriteLock();
                            _rootLock.EnterReadLock();
                        }
                    }

                    node = child;
                    nodesToUpdate.Add(node);
                }

                // Add completion to this node
                node.Lock.EnterWriteLock();
                try
                {
                    if (node.Completions == null)
                    {
                        node.Completions = new List<CompletionEntry>();
                    }

                    // Check if completion already exists
                    var existingIndex = node.Completions.FindIndex(e => e.Text == completion);
                    if (existingIndex >= 0)
                    {
                        // Update score if higher
                        var existing = node.Completions[existingIndex];
                        if (score > existing.Score)
                        {
                            existing.Score = score;
                            existing.LastUsedTicks = Environment.TickCount;
                            node.Completions[existingIndex] = existing;
                        }
                    }
                    else
                    {
                        // Add new completion
                        node.Completions.Add(new CompletionEntry
                        {
                            Text = completion,
                            Score = score,
                            Type = DetermineType(completion),
                            LastUsedTicks = Environment.TickCount
                        });

                        Interlocked.Increment(ref _completionCount);
                    }

                    // Keep list sorted by score
                    node.Completions.Sort();

                    // Limit to top 20 completions per node
                    if (node.Completions.Count > 20)
                    {
                        node.Completions.RemoveRange(20, node.Completions.Count - 20);
                    }
                }
                finally
                {
                    node.Lock.ExitWriteLock();
                }

                // Also add to parent nodes for partial matches (with reduced score)
                var parentScore = score * 0.8f;
                for (int i = nodesToUpdate.Count - 2; i >= 0 && i >= nodesToUpdate.Count - 4; i--)
                {
                    var parent = nodesToUpdate[i];
                    parent.Lock.EnterWriteLock();
                    try
                    {
                        if (parent.Completions == null)
                        {
                            parent.Completions = new List<CompletionEntry>();
                        }

                        var exists = parent.Completions.Any(e => e.Text == completion);
                        if (!exists && parent.Completions.Count < 10)
                        {
                            parent.Completions.Add(new CompletionEntry
                            {
                                Text = completion,
                                Score = parentScore,
                                Type = DetermineType(completion),
                                LastUsedTicks = Environment.TickCount
                            });
                            parent.Completions.Sort();
                        }
                    }
                    finally
                    {
                        parent.Lock.ExitWriteLock();
                    }

                    parentScore *= 0.8f;
                }
            }
            finally
            {
                _rootLock.ExitReadLock();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveOptimization)]
        public List<string> GetCompletions(string prefix, int maxResults = 3)
        {
            if (string.IsNullOrEmpty(prefix))
                return new List<string>();

            // Normalize prefix to lowercase
            prefix = prefix.ToLowerInvariant();

            _rootLock.EnterReadLock();
            try
            {
                var node = _root;

                // Traverse to prefix node
                foreach (char c in prefix)
                {
                    node = node.GetChild(c);
                    if (node == null)
                    {
                        return new List<string>();
                    }
                }

                // Get completions from this node
                node.Lock.EnterReadLock();
                try
                {
                    if (node.Completions == null || node.Completions.Count == 0)
                    {
                        return new List<string>();
                    }

                    // Return top completions by score
                    return node.Completions
                        .Take(maxResults)
                        .Select(e => e.Text)
                        .ToList();
                }
                finally
                {
                    node.Lock.ExitReadLock();
                }
            }
            finally
            {
                _rootLock.ExitReadLock();
            }
        }

        public List<(string completion, float score)> GetCompletionsWithScores(string prefix, int maxResults = 3)
        {
            if (string.IsNullOrEmpty(prefix))
                return new List<(string, float)>();

            prefix = prefix.ToLowerInvariant();

            _rootLock.EnterReadLock();
            try
            {
                var node = _root;

                foreach (char c in prefix)
                {
                    node = node.GetChild(c);
                    if (node == null)
                    {
                        return new List<(string, float)>();
                    }
                }

                node.Lock.EnterReadLock();
                try
                {
                    if (node.Completions == null || node.Completions.Count == 0)
                    {
                        return new List<(string, float)>();
                    }

                    return node.Completions
                        .Take(maxResults)
                        .Select(e => (e.Text, e.Score))
                        .ToList();
                }
                finally
                {
                    node.Lock.ExitReadLock();
                }
            }
            finally
            {
                _rootLock.ExitReadLock();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private static CompletionType DetermineType(string completion)
        {
            if (completion.StartsWith("-"))
                return CompletionType.Parameter;

            if (completion.Contains("\\") || completion.Contains("/"))
                return CompletionType.Path;

            if (completion.Contains("-") && !completion.StartsWith("-"))
                return CompletionType.Command;

            return CompletionType.History;
        }

        public void Clear()
        {
            _rootLock.EnterWriteLock();
            try
            {
                ClearNode(_root);
                _nodeCount = 0;
                _completionCount = 0;
            }
            finally
            {
                _rootLock.ExitWriteLock();
            }
        }

        private void ClearNode(TrieNode node)
        {
            node.Lock.EnterWriteLock();
            try
            {
                node.Completions?.Clear();

                for (int i = 0; i < node.Children.Length; i++)
                {
                    if (node.Children[i] != null)
                    {
                        ClearNode(node.Children[i]!);
                        node.Children[i] = null;
                    }
                }
            }
            finally
            {
                node.Lock.ExitWriteLock();
            }
        }

        public (int nodeCount, int completionCount) GetStatistics()
        {
            return (_nodeCount, _completionCount);
        }
    }
}