using System;
using System.Collections.Generic;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace PowerAugerSharp
{
    /// <summary>
    /// Manages a pool of PowerShell instances for async command completion
    /// </summary>
    public class BackgroundProcessor : IDisposable
    {
        private readonly Channel<PowerShell> _pwshPool;
        private readonly FastLogger _logger;
        private readonly int _poolSize;
        private readonly List<PowerShell> _instances = new();
        private bool _disposed;

        public BackgroundProcessor(FastLogger logger, int poolSize = 4)
        {
            _logger = logger ?? throw new ArgumentNullException(nameof(logger));
            _poolSize = poolSize;
            _pwshPool = Channel.CreateUnbounded<PowerShell>();

            InitializePool();
        }

        private void InitializePool()
        {
            for (int i = 0; i < _poolSize; i++)
            {
                var runspace = RunspaceFactory.CreateRunspace();
                runspace.Open();

                var pwsh = PowerShell.Create();
                pwsh.Runspace = runspace;

                // Pre-load common modules
                pwsh.AddScript(@"
                    Import-Module PSReadLine -ErrorAction SilentlyContinue
                    Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue
                    Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
                ").Invoke();

                pwsh.Commands.Clear();
                pwsh.Streams.ClearStreams();

                _instances.Add(pwsh);
                _pwshPool.Writer.TryWrite(pwsh);
            }

            _logger.LogInfo($"Initialized PowerShell pool with {_poolSize} instances");
        }

        /// <summary>
        /// Get the channel reader for the pool
        /// </summary>
        public ChannelReader<PowerShell> GetPoolReader() => _pwshPool.Reader;

        /// <summary>
        /// Check out a PowerShell instance from the pool
        /// </summary>
        public async Task<PowerShell> CheckOutAsync(CancellationToken cancellationToken = default)
        {
            return await _pwshPool.Reader.ReadAsync(cancellationToken);
        }

        /// <summary>
        /// Return a PowerShell instance to the pool
        /// </summary>
        public void CheckIn(PowerShell pwsh)
        {
            if (pwsh == null || _disposed)
                return;

            // Clear state for reuse
            pwsh.Commands.Clear();
            pwsh.Streams.ClearStreams();

            _pwshPool.Writer.TryWrite(pwsh);
        }

        public void Dispose()
        {
            if (_disposed)
                return;

            _disposed = true;

            // Complete the channel
            _pwshPool.Writer.TryComplete();

            // Dispose all PowerShell instances and their runspaces
            foreach (var pwsh in _instances)
            {
                try
                {
                    pwsh.Runspace?.Close();
                    pwsh.Runspace?.Dispose();
                    pwsh.Dispose();
                }
                catch (Exception ex)
                {
                    _logger.LogError($"Error disposing PowerShell instance: {ex.Message}");
                }
            }

            _instances.Clear();
            _logger.LogInfo("BackgroundProcessor disposed");
        }
    }
}