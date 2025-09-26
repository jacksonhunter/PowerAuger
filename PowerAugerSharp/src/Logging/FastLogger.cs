using System;
using System.Collections.Concurrent;
using System.IO;
using System.Runtime.CompilerServices;
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
        private StreamWriter? _writer;
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

            var timestamp = DateTime.Now.ToString("yyyyMMdd");
            _logFile = Path.Combine(_logDirectory, $"powerauger_{timestamp}.log");

            _logChannel = Channel.CreateUnbounded<LogEntry>(new UnboundedChannelOptions
            {
                SingleReader = true,
                SingleWriter = false
            });

            _shutdownTokenSource = new CancellationTokenSource();
            _logTask = Task.Run(() => ProcessLogQueue(_shutdownTokenSource.Token));

            InitializeWriter();
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void LogDebug(string message)
        {
            if (MinimumLevel <= LogLevel.Debug)
                Log(LogLevel.Debug, message);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void LogInfo(string message)
        {
            if (MinimumLevel <= LogLevel.Info)
                Log(LogLevel.Info, message);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void LogWarning(string message)
        {
            if (MinimumLevel <= LogLevel.Warning)
                Log(LogLevel.Warning, message);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public void LogError(string message)
        {
            if (MinimumLevel <= LogLevel.Error)
                Log(LogLevel.Error, message);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
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

        private void InitializeWriter()
        {
            try
            {
                lock (_writerLock)
                {
                    _writer = new StreamWriter(_logFile, append: true, encoding: Encoding.UTF8)
                    {
                        AutoFlush = false
                    };
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Failed to initialize log writer: {ex.Message}");
            }
        }

        private async Task ProcessLogQueue(CancellationToken cancellationToken)
        {
            var reader = _logChannel.Reader;
            var buffer = new StringBuilder(1024);
            var flushTimer = new PeriodicTimer(TimeSpan.FromSeconds(1));

            try
            {
                while (!cancellationToken.IsCancellationRequested)
                {
                    // Process batch of log entries
                    var hasEntries = false;

                    while (reader.TryRead(out var entry))
                    {
                        FormatLogEntry(buffer, entry);
                        hasEntries = true;

                        // Flush if buffer gets large
                        if (buffer.Length > 8192)
                        {
                            await WriteBuffer(buffer);
                            buffer.Clear();
                        }
                    }

                    if (hasEntries && buffer.Length > 0)
                    {
                        await WriteBuffer(buffer);
                        buffer.Clear();
                    }

                    // Wait for more entries or timeout
                    var readTask = reader.WaitToReadAsync(cancellationToken).AsTask();
                    var flushTask = flushTimer.WaitForNextTickAsync(cancellationToken).AsTask();

                    await Task.WhenAny(readTask, flushTask);

                    // Flush periodically even if no new entries
                    if (flushTask.IsCompletedSuccessfully)
                    {
                        lock (_writerLock)
                        {
                            _writer?.Flush();
                        }
                    }
                }
            }
            catch (OperationCanceledException)
            {
                // Expected during shutdown
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Log processing error: {ex.Message}");
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

                lock (_writerLock)
                {
                    _writer?.Flush();
                }

                flushTimer?.Dispose();
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
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

        private Task WriteBuffer(StringBuilder buffer)
        {
            if (buffer.Length == 0)
                return Task.CompletedTask;

            try
            {
                lock (_writerLock)
                {
                    if (_writer != null)
                    {
                        _writer.Write(buffer.ToString());
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Failed to write log: {ex.Message}");
            }

            return Task.CompletedTask;
        }

        public void Dispose()
        {
            try
            {
                _shutdownTokenSource?.Cancel();
                _logChannel?.Writer.TryComplete();

                // Wait for log task to complete
                _logTask?.Wait(TimeSpan.FromSeconds(2));

                lock (_writerLock)
                {
                    _writer?.Flush();
                    _writer?.Dispose();
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"Error during logger disposal: {ex.Message}");
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