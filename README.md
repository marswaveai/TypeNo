# TypeNo

[中文](README_CN.md) | [日本語](README_JP.md)

**A free, open source, privacy-first voice input tool for macOS.**

![TypeNo hero image](assets/hero.webp)

A minimal macOS voice input app. TypeNo captures your voice, transcribes it locally, and pastes the result into whatever app you were using — all in under a second.

Official website: [https://typeno.com](https://typeno.com)

Special thanks to [marswave ai's coli project](https://github.com/marswaveai/coli) for powering local speech recognition.

## How It Works

1. **Short-press Control** to start recording
2. **Short-press Control** again to stop
3. Text is automatically transcribed and pasted into your active app (also copied to clipboard)
4. While recording, the overlay shows segmented preview text about once per second; after you stop, TypeNo still runs a final full-file transcription before pasting

That's it. No windows, no settings, no accounts.

## Install

### Option 1 — Download the App

- [Download TypeNo for macOS](https://github.com/marswaveai/TypeNo/releases/latest)
- Download the latest `TypeNo.app.zip`
- Unzip it
- Move `TypeNo.app` to `/Applications`
- Open TypeNo

TypeNo is signed and notarized by Apple — it should open without any warnings.

### Install the speech engine

TypeNo uses [coli](https://github.com/marswaveai/coli) for local speech recognition.

**Prerequisites:**
- [Node.js](https://nodejs.org) (LTS recommended — install directly from nodejs.org for best compatibility)
- [ffmpeg](https://ffmpeg.org) — required for audio conversion: `brew install ffmpeg`

```bash
npm install -g @marswave/coli
```

This installs the `coli` CLI itself, but it does not pre-download the speech model.

If Coli is missing, TypeNo will show an in-app setup prompt with the install command.

> **Node 24+:** If you get a `sherpa-onnx-node` error, build from source:
> ```bash
> npm install -g @marswave/coli --build-from-source
> ```

### First Launch

TypeNo needs two one-time permissions:
- **Microphone** — to capture your voice
- **Accessibility** — to paste text into apps

The app will guide you through granting these on first launch.

On the first actual transcription, `coli` will also download its speech model into `~/.coli/models/`. That is a separate step from `npm install -g @marswave/coli`.

### Troubleshooting: Coli Model Download Fails

The speech model is downloaded from GitHub. If GitHub is inaccessible in your network, the first transcription can fail while `coli` is downloading the model.

**Fix:** Enable **TUN mode** (also called Enhanced Mode) in your proxy tool to ensure all system-level traffic is routed correctly. Then trigger another transcription so `coli` can retry the model download.

If `~/.coli/models/` contains a partial `.tar.bz2` archive from a failed download, delete the leftover files in that directory before retrying.

```bash
rm -rf ~/.coli/models
```

### Troubleshooting: Accessibility Permission Not Working

Some users find that enabling TypeNo in **System Settings → Privacy & Security → Accessibility** has no effect — a known macOS bug. The fix:

1. Select **TypeNo** in the list
2. Click **−** to remove it
3. Click **+** and re-add TypeNo from `/Applications`

![Accessibility permission fix](assets/accessibility-fix.gif)

### Option 2 — Build from Source

```bash
git clone https://github.com/marswaveai/TypeNo.git
cd TypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

The app will be at `dist/TypeNo.app`. Move it to `/Applications/` for persistent permissions.

## Usage

| Action | Trigger |
|---|---|
| Start/stop recording | Short-press `Control` (< 300ms, no other keys) |
| Start/stop recording | Menu bar → Record |
| Watch incremental transcription | Overlay updates about once per second while processing |
| Choose microphone | Menu bar → Microphone → Automatic / specific device |
| Transcribe a file | Drag `.m4a`/`.mp3`/`.wav`/`.aac` to the menu bar icon |
| Check for updates | Menu bar → Check for Updates... |
| Quit | Menu bar → Quit (`⌘Q`) |

## Design Philosophy

TypeNo does one thing: voice → text → paste. No extra UI, no preferences, no configuration. The fastest way to type is to not type at all.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=marswaveai/TypeNo&type=Date)](https://star-history.com/#marswaveai/TypeNo&Date)

## License

GNU General Public License v3.0
