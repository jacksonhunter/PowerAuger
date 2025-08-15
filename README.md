<!-- @format -->

# PowerAuger - Experimental AI Command Predictor for PowerShell

<p align="center">
  <img src="https://i.imgur.com/O1lO3rA.png" alt="PowerAuger Logo" width="200"/>
</p>

> **⚠️ Experimental Software Notice ⚠️**
>
> PowerAuger is currently under active, rapid development. It is a proving ground for cutting-edge command-line AI assistance. Features may change, APIs may be refactored, and you may encounter bugs. Use with a spirit of adventure and help shape its future!

**PowerAuger** is an intelligent, context-aware command predictor for PowerShell, designed to transform your shell into a proactive assistant. Powered by local or remote [Ollama](https://ollama.com/) models, it goes far beyond simple history-based suggestions to provide completions that understand your environment, intent, and workflow.

---

## Core Features (What's Here Today)

Even in its experimental stage, PowerAuger is built on a production-grade foundation:

-   **🚀 Guided, Automated Setup**: A comprehensive `setup.ps1` script handles everything from initial configuration and connection testing to model auto-detection and profile setup.
-   **🔐 Secure Remote Connections**: Built-in SSH tunnel management for securely connecting to a remote Ollama instance, keeping your models and data firewalled.
-   **🧠 Stateful & Persistent**: Remembers your configuration, command history, and prediction cache across sessions, storing its state neatly in `~/.PowerAuger`.
-   **🤖 Intelligent Model Selection**: Automatically switches between a fast, lightweight model for simple completions and a powerful, context-aware model for complex commands, optimizing for both speed and accuracy.
-   **🧩 Modular Context Engine**: The engine understands your environment. It knows your current directory, whether you're in a Git repository (and if it's dirty), and the structure of the command you're typing.
-   **⚡ Robust Caching**: Reduces latency and API calls with an intelligent, time-aware cache, providing instant suggestions for repeated commands.
-   **📊 Full Diagnostics**: A suite of commands (`Show-PredictorStatus`, `Get-PredictorStatistics`, `Clear-PowerAugerCache`) to monitor and manage the engine's health and performance.

## Vision & Roadmap (What's Coming Next)

PowerAuger aims to be the most intelligent shell assistant available. The architecture is designed to support a future that is deeply integrated and contextually brilliant.

### 🌐 True Cross-Platform Mastery

While built on the cross-platform PowerShell 7+, future work will focus on first-class support and optimization for macOS and Linux environments, including context providers for `apt`, `brew`, and other platform-specific tooling.

### ✨ Expanded Context Providers

The modular engine is ready for expansion. Imagine PowerAuger understanding your:

-   Active `docker` containers and images
-   Current `kubectl` context and available namespaces
-   Authenticated AWS/Azure CLI profile and available resources
-   The contents of a file you've just referenced (`cat file.json | ...`)

### 📌 **Pinned Feature: Dynamic Prediction View**

This is the ultimate user experience goal. PowerAuger will intelligently switch its presentation style based on confidence and ambiguity.

-   **High Confidence**: A single, brilliant suggestion appears as subtle inline "ghost text".
-   **Multiple Possibilities**: When several good options exist, it will automatically switch to a full list view, allowing you to see all relevant predictions at a glance.

This adaptability will make the tool feel less like a simple autocompleter and more like a true pair-programmer for your shell.

---

## Installation

1.  Clone this repository to your local machine.
2.  Navigate to the `PowerAuger` module directory in PowerShell.
3.  Run the setup script:
    ```powershell
    .\setup.ps1
    ```
4.  Follow the on-screen prompts. The script will guide you through configuring your Ollama host, testing the connection, and setting up your PowerShell profile to auto-load the module.

## Basic Usage

Once the setup is complete, the predictor must be enabled in `PSReadLine`. The setup script provides this command, but you can run it manually:

```powershell
# Enable predictions from your history and from PowerAuger
Set-PSReadLineOption -PredictionSource HistoryAndPlugin
```

Now, simply start typing in your PowerShell terminal, and suggestions will appear automatically.

## Key Commands

-   `Show-PredictorStatus`: Display the current connection status, model configuration, and basic stats.
-   `Get-PredictorStatistics`: Get a detailed hashtable of performance and cache metrics.
-   `Set-PredictorConfiguration`: Modify core settings like the Ollama host or debug mode.
-   `Clear-PowerAugerCache`: Manually clear the in-memory and on-disk prediction cache.
-   `Test-OllamaConnection`: Manually test the SSH tunnel and API connectivity.
