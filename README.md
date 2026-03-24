# TypeNo

A minimal macOS voice input app. Press Control, speak, done.

TypeNo captures your voice, transcribes it locally, and pastes the result into whatever app you were using — all in under a second.

## How It Works

1. **Short-press Control** to start recording
2. **Short-press Control** again to stop
3. Text is automatically transcribed and pasted into your active app (also copied to clipboard)

That's it. No windows, no settings, no accounts.

## Install

### Option 1 — Download the App

For most users, the easiest way is to download the latest release:

- [Download TypeNo for macOS](https://github.com/nicepkg/TypeNo/releases/latest)
- Download the latest `TypeNo.app.zip`
- Unzip it
- Move `TypeNo.app` to `/Applications`
- Open TypeNo

If macOS blocks the app the first time, go to **System Settings → Privacy & Security** and allow it to open.

### Install the speech engine

TypeNo uses [coli](https://github.com/nicepkg/coli) for local speech recognition:

```bash
npm i -g @anthropic-ai/coli
```

### First Launch

TypeNo needs two one-time permissions:
- **Microphone** — to capture your voice
- **Accessibility** — to paste text into apps

The app will guide you through granting these on first launch.

### Option 2 — Build from Source

If you prefer to build it yourself:

```bash
git clone https://github.com/nicepkg/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

The app will be at `dist/TypeNo.app`. Move it to `/Applications/` for persistent permissions.

## Usage

| Action | Trigger |
|---|---|
| Start/stop recording | Short-press `Control` (< 300ms, no other keys) |
| Start/stop recording | Menu bar → Record (`⌃R`) |
| Transcribe a file | Drag `.m4a`/`.mp3`/`.wav`/`.aac` to the menu bar icon |
| Quit | Menu bar → Quit (`⌘Q`) |

## Design Philosophy

TypeNo does one thing: voice → text → paste. No extra UI, no preferences, no configuration. The fastest way to type is to not type at all.

## Internationalization

- [中文说明](README_CN.md)
- [日本語の説明](README_JP.md)

## License

GNU General Public License v3.0
