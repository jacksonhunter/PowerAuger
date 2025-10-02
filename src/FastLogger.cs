using System;
using System.Collections.Concurrent;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace PowerAugerSharp
{
    public sealed class FastLogger : IDisposable
    {
        private readonly string _logDirectory;
        private readonly string _logFile;
        private readonly Channel<LogEntry> _logChannel;
        private readonly Task _logTask;
        private readonly CancellationTokenSource _shutdownTokenSource;
        private readonly object _writerLock = new object();

        public enum LogLevel
        {
            Debug = 0,
            Info = 1,
            Warning = 2,
            Error = 3
        }

        public LogLevel MinimumLevel { get; set; } = LogLevel.Info;

        public FastLogger()
        {
            _logDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "PowerAugerSharp",
                "logs");
            Directory.CreateDirectory(_logDirectory);

            // Clean up old log files (keep last 7 days)
            CleanupOldLogs();

            // Use session-unique filename to avoid locking issues
            var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
            var pid = Environment.ProcessId;
            _logFile = Path.Combine(_logDirectory, $"powerauger_{timestamp}_pid{pid}.log");

            _logChannel = Channel.CreateUnbounded<LogEntry>(new UnboundedChannelOptions
            {
                SingleReader = true,
                SingleWriter = false
            });

            _shutdownTokenSource = new CancellationTokenSource();
            _logTask = Task.Run(() => ProcessLogQueue(_shutdownTokenSource.Token));

            InitializeWriter();
        }

        public void LogDebug(string message)
        {
            if (MinimumLevel <= LogLevel.Debug)
                Log(LogLevel.Debug, message);
        }

        public void LogInfo(string message)
        {
            if (MinimumLevel <= LogLevel.Info)
                Log(LogLevel.Info, message);
        }

        public void LogWarning(string message)
        {
            if (MinimumLevel <= LogLevel.Warning)
                Log(LogLevel.Warning, message);
        }

        public void LogError(string message)
        {
            if (MinimumLevel <= LogLevel.Error)
                Log(LogLevel.Error, message);
        }

        private void Log(LogLevel level, string message)
        {
            var entry = new LogEntry
            {
                Timestamp = DateTime.UtcNow,
                Level = level,
                Message = message,
                ThreadId = Thread.CurrentThread.ManagedThreadId
            };

            // Fire and forget - don't wait
            _logChannel.Writer.TryWrite(entry);
        }

        private void CleanupOldLogs()
        {
            try
            {
                var cutoffDate = DateTime.Now.AddDays(-7);
                var logFiles = Directory.GetFiles(_logDirectory, "powerauger_*.log");

                foreach (var logFile in logFiles)
                {
                    try
                    {
                        var fileInfo = new FileInfo(logFile);
                        if (fileInfo.LastWriteTime < cutoffDate)
                        {
                            File.Delete(logFile);
                        }
                    }
                    catch
                    {
                        // Skip files we can't delete (in use, permissions, etc.)
                    }
                }
            }
            catch
            {
                // Silently fail - cleanup is best-effort
            }
        }

        private void InitializeWriter()
        {
            // No longer keep file open - we'll use File.AppendAllText instead
            // This avoids file locking issues entirely
            try
            {
                // Just ensure file exists
                if (!File.Exists(_logFile))
                {
                    File.WriteAllText(_logFile, $"Log started at {DateTime.UtcNow:yyyy-MM-dd HH:mm:ss.fff}\n");
                }
            }
            catch
            {
                // Silently fail - don't pollute console output
                // Logger errors were appearing in PSReadLine predictions!
            }
        }

        private async Task ProcessLogQueue(CancellationToken cancellationToken)
        {
            var reader = _logChannel.Reader;
            var buffer = new StringBuilder(1024);
            var lastFlushTime = DateTime.UtcNow;

            try
            {
                while (!cancellationToken.IsCancellationRequested)
                {
                    var hasEntries = false;

                    // Process all available entries
                    while (reader.TryRead(out var entry))
                    {
                        FormatLogEntry(buffer, entry);
                        hasEntries = true;

                        // Flush if buffer gets large
                        if (buffer.Length > 8192)
                        {
                            if (await WriteBuffer(buffer))
                            {
                                buffer.Clear();
                                lastFlushTime = DateTime.UtcNow;
                            }
                        }
                    }

                    // Flush if we have entries or it's been a while
                    var timeSinceFlush = DateTime.UtcNow - lastFlushTime;
                    if ((hasEntries && buffer.Length > 0) || (buffer.Length > 0 && timeSinceFlush.TotalSeconds > 5))
                    {
                        if (await WriteBuffer(buffer))
                        {
                            buffer.Clear();
                            lastFlushTime = DateTime.UtcNow;
                        }
                    }

                    // Wait for more entries or timeout
                    try
                    {
                        await reader.WaitToReadAsync(cancellationToken).AsTask().WaitAsync(TimeSpan.FromSeconds(1), cancellationToken);
                    }
                    catch (TimeoutException)
                    {
                        // Periodic wakeup for flush check
                    }
                }
            }
            catch (OperationCanceledException)
            {
                // Expected during shutdown
            }
            catch
            {
                // Silently fail - don't pollute console output
            }
            finally
            {
                // Flush remaining entries
                while (reader.TryRead(out var entry))
                {
                    FormatLogEntry(buffer, entry);
                }

                if (buffer.Length > 0)
                {
                    await WriteBuffer(buffer);
                }
            }
        }

        private static void FormatLogEntry(StringBuilder buffer, LogEntry entry)
        {
            buffer.Append(entry.Timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff"));
            buffer.Append(" [");
            buffer.Append(entry.Level.ToString().ToUpper());
            buffer.Append("] [T");
            buffer.Append(entry.ThreadId);
            buffer.Append("] ");
            buffer.AppendLine(entry.Message);
        }

        private async Task<bool> WriteBuffer(StringBuilder buffer)
        {
            if (buffer.Length == 0)
                return true;

            try
            {
                // Use FileShare.ReadWrite to allow multiple processes/threads
                using (var stream = new FileStream(_logFile, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                using (var writer = new StreamWriter(stream))
                {
                    await writer.WriteAsync(buffer.ToString());
                }
                return true;
            }
            catch
            {
                // Silently fail - don't pollute console output
                // Try to write to alternate file on failure
                try
                {
                    var fallbackFile = _logFile.Replace(".log", "_fallback.log");
                    await File.AppendAllTextAsync(fallbackFile, buffer.ToString());
                    return true;
                }
                catch
                {
                    return false; // Indicate write failed
                }
            }
        }

        public void Dispose()
        {
            try
            {
                _shutdownTokenSource?.Cancel();
                _logChannel?.Writer.TryComplete();

                // Wait for log task to complete
                _logTask?.Wait(TimeSpan.FromSeconds(2));

                // No writer to dispose - we use File.AppendAllText
            }
            catch
            {
                // Silently fail - don't pollute console output during disposal
            }
            finally
            {
                _shutdownTokenSource?.Dispose();
            }
        }

        private struct LogEntry
        {
            public DateTime Timestamp;
            public LogLevel Level;
            public string Message;
            public int ThreadId;
        }
    }
}