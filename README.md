# TypeNo

[中文](README_CN.md) | [日本語](README_JP.md)

**A free, open source, privacy-first voice input tool for macOS.**

![TypeNo hero image](assets/hero.webp)

A minimal macOS voice input app. TypeNo captures your voice, transcribes it locally, and pastes the result into whatever app you were using — all in under a second.

Official website: [https://typeno.com](https://typeno.com)

Special thanks to [marswave ai's coli project](https://github.com/marswaveai/coli) for powering local speech recognition.

## How It Works

1. **Configure your hotkey** via menu bar (Control/Option/Command/Shift)
2. **Choose trigger mode** (Single Tap or Double Tap)
3. **Trigger your hotkey** to start recording
4. **Trigger again** to stop
5. Text is automatically transcribed and pasted into your active app (also copied to clipboard)

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

TypeNo uses [coli](https://github.com/marswaveai/coli) for local speech recognition:

```bash
npm install -g @marswave/coli
```

If Coli is missing, TypeNo will show an in-app setup prompt with the install command.

### First Launch

TypeNo needs two one-time permissions:
- **Microphone** — to capture your voice
- **Accessibility** — to paste text into apps

The app will guide you through granting these on first launch.

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
| Configure hotkey | Menu bar → Hotkey → [Control/Option/Command/Shift] |
| Configure trigger mode | Menu bar → Trigger Mode → [Single Tap/Double Tap] |
| Start/stop recording (Single Tap) | Quick press your hotkey (< 300ms) |
| Start/stop recording (Double Tap) | Quick press your hotkey twice (< 500ms between taps) |
| Start/stop recording | Menu bar → Record |
| Transcribe a file | Drag `.m4a`/`.mp3`/`.wav`/`.aac` to the menu bar icon |
| Check for updates | Menu bar → Check for Updates... |
| Quit | Menu bar → Quit (`⌘Q`) |

**Trigger Modes:**
- **Single Tap**: Quick press and release your hotkey (< 300ms). Faster but may accidentally trigger.
- **Double Tap**: Press your hotkey twice in quick succession (< 500ms gap). More deliberate, fewer accidents.

## Design Philosophy

TypeNo does one thing: voice → text → paste. No extra UI, no preferences, no configuration. The fastest way to type is to not type at all.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=marswaveai/TypeNo&type=Date)](https://star-history.com/#marswaveai/TypeNo&Date)

## License

GNU General Public License v3.0
