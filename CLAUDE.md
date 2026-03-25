# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TypeNo is a macOS voice input app that transcribes speech locally and pastes text into any active application. It's a Swift 6.2 application using SwiftUI, built with Swift Package Manager.

**Core Technology Stack:**
- Swift 6.2 + SwiftUI for UI
- AVFoundation for audio recording
- External CLI tool `coli` (@marswave/coli) for local speech recognition
- macOS Accessibility API for text insertion
- No backend/server dependencies

## Build Commands

```bash
# Build the application
swift build -c release

# Generate app icon (run once or after icon changes)
scripts/generate_icon.sh

# Build complete .app bundle (includes code signing + notarization if credentials available)
scripts/build_app.sh
```

The built app will be at `dist/TypeNo.app`. Move it to `/Applications/` for persistent permissions.

## Code Architecture

**Single-file architecture:** All application logic is in `Sources/Typeno/main.swift` (~1600 lines). Key components:

### Core Classes
- **AppDelegate**: App lifecycle, coordinates all components
- **AppState**: Observable state machine (permissions → recording → transcribing → confirmation)
- **ColiASRService**: Interfaces with `coli` CLI for transcription
- **StatusItemController**: Menu bar icon and menu
- **HotkeyMonitor**: Global keyboard event monitoring (Control key short-press)
- **OverlayPanelController**: Recording indicator overlay
- **PermissionManager**: Microphone + Accessibility permission checks
- **UpdateService**: GitHub release checking and auto-update

### Application Flow
1. **Permissions Phase**: Check/grant Microphone + Accessibility permissions
2. **Coli Install Phase**: Auto-detect or prompt to install `coli` via npm
3. **Idle → Recording**: User presses Control key (< 300ms)
4. **Recording → Transcribing**: Press Control again → stop recording → invoke `coli` CLI
5. **Transcribing → Confirmation**: Show transcript in overlay, user confirms or cancels
6. **Confirmation → Paste**: Use Accessibility API to insert text into active app

### Key Implementation Details

**Coli CLI Integration:**
- TypeNo searches for `coli` binary in common npm global paths
- Supports auto-install via `npm install -g @marswave/coli`
- Transcription runs as subprocess with 120-second timeout
- Must set up PATH environment for npm subprocess to find Node.js

**Permission Requirements:**
- **Microphone**: Required for audio capture
- **Accessibility**: Required for text insertion via CGEvent keyboard simulation
- App polls permission status every 2 seconds during setup phase

**Hotkey Detection:**
- Global monitor for Control key press
- Distinguishes short-press (< 300ms, no other keys) from normal usage
- Only triggers when app is in idle state

**Audio Recording:**
- Uses `AVAudioRecorder` with temporary `.m4a` file
- 44.1kHz sample rate, AAC encoding
- Also supports drag-and-drop audio files for transcription

## Development Notes

**Testing:**
- No automated tests in this project
- Manual testing: Run app, grant permissions, test Control key recording flow

**Code Signing:**
- Build script auto-detects Developer ID or Apple Development certificates
- Falls back to ad-hoc signature if no credentials found
- Notarization requires `notarytool` keychain profile named "notarytool"

**Common npm Global Paths:**
The app searches these paths for `coli` binary:
- `/opt/homebrew/bin` (Apple Silicon Homebrew)
- `/usr/local/bin` (Intel Homebrew)
- `~/.nvm/current/bin` (nvm)
- `~/.volta/bin` (Volta)
- `~/.local/share/fnm/aliases/default/bin` (fnm)

**Node.js Version Managers:**
When running npm subprocess, the app constructs PATH to include common Node.js version manager paths. If coli install fails, check that the user's Node.js setup is in one of these standard locations.

## Release Process

1. Update version in `App/Info.plist` (CFBundleShortVersionString and CFBundleVersion)
2. Update version in any README files if mentioned
3. Run `scripts/build_app.sh` to create signed, notarized build
4. Create GitHub release with `dist/TypeNo.app.zip`
5. App includes auto-update checking via GitHub releases API
