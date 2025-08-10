# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a PowerShell profile configuration repository containing custom terminal theming and initialization scripts. The repository focuses on creating a synthwave/cyberpunk "Blood Dragon" theme for PowerShell terminals.

## File Structure

- `Microsoft.PowerShell_profile.ps1` - Main PowerShell profile with synthwave theme, ASCII art splash screen, and color customizations using modern PSStyle formatting
- `profile.ps1` - Simple profile that initializes conda environment if available
- `Microsoft.PowerShell_profile.ps1.old` - Backup of previous profile configuration

## Key Architecture

The main profile (`Microsoft.PowerShell_profile.ps1`) implements:

1. **Theme System**: Centralized color palette using a PowerShell hashtable for consistent theming
2. **Modern Color Management**: Uses `$PSStyle` for setting colors (preferred over legacy host settings)
3. **Gradient ASCII Art**: Implements ANSI color codes to create gradient effects on ASCII art
4. **Error Visibility Fix**: Specifically addresses unreadable error messages by setting high-contrast colors

## Development Notes

- This is a PowerShell configuration repository, not a traditional software project
- No build/test/lint commands are available as this contains configuration scripts
- The main profile uses ANSI escape sequences and RGB color conversion for terminal styling
- Color themes are defined in hex format and converted to RGB for ANSI codes

## PowerShell Profile Loading

- `Microsoft.PowerShell_profile.ps1` loads automatically for PowerShell sessions
- `profile.ps1` handles conda environment initialization if Anaconda is installed

## Theme Customization

The color theme is centralized in the `$Theme` hashtable at the top of `Microsoft.PowerShell_profile.ps1`. Colors can be modified by changing the hex values in this structure.