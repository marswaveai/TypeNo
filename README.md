# TypeNo Agent

[中文](README_CN.md) | [日本語](README_JP.md)

**A privacy-first macOS voice input and rewrite tool based on TypeNo.**

![TypeNo Agent hero image](assets/hero.webp)

`TypeNo Agent` is a fork of `TypeNo` focused on real-world voice-driven workflows. It captures your voice, transcribes it locally, optionally rewrites the result with an LLM, and pastes it back into your active app.

Official website: [https://typeno.com](https://typeno.com)

Special thanks to [marswave ai's coli project](https://github.com/marswaveai/coli) for powering local speech recognition.

## How It Works

1. Use a modifier hotkey to start recording
2. Press the same hotkey again to stop
3. The app transcribes locally, optionally rewrites by mode, then pastes the result into your active app

Current default hotkeys:

- Left `Option` = current default mode
- Left `Control` = `Spoken Cleanup`
- Right `Control` = `Agent`

## Install

### Option 1 — Download the App Bundle

- Download the current `TypeNo Agent.app`
- Unzip it
- Move `TypeNo Agent.app` to `/Applications` or `~/Applications`
- Open `TypeNo Agent`

#### If macOS says the app is damaged

Current releases are not yet notarized by Apple, so macOS may block the app after download.

Try these steps in order:

1. Right-click `TypeNo Agent.app` in Finder and choose **Open**
2. If you see **System Settings → Privacy & Security → Open Anyway**, use that path
3. If macOS still blocks it, remove the quarantine flag in Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/TypeNo Agent.app"
```

4. Open `TypeNo Agent.app` again

### Install the speech engine

`TypeNo Agent` uses [coli](https://github.com/marswaveai/coli) for local speech recognition:

```bash
npm install -g @marswave/coli
```

If Coli is missing, the app will show an in-app setup prompt.

### First Launch

`TypeNo Agent` needs two one-time permissions:
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

The built app will be at `dist/TypeNo Agent.app`. Move it to `/Applications/` or `~/Applications/` for persistent permissions.

## Usage

| Action | Trigger |
|---|---|
| Start/stop recording in current default mode | Short-press left `Option` |
| Start/stop recording in `Spoken Cleanup` mode | Short-press left `Control` |
| Start/stop recording in `Agent` mode | Short-press right `Control` |
| Start/stop recording | Menu bar → Record |
| Transcribe a file | Drag `.m4a`/`.mp3`/`.wav`/`.aac` to the menu bar icon |
| Select rewrite mode | Menu bar → Default Mode |
| Select LLM provider | Menu bar → Provider |
| Check upstream core updates | Menu bar → Check Upstream Updates... |
| Quit | Menu bar → Quit (`⌘Q`) |

## Modes

Current modes:

- `Raw`
- `Agent`
- `Spoken Cleanup`
- `Zh-En Mix`
- `Anime Chuunibyou`
- `Old Internet Meme`
- `Movie Quote Style`
- `Philo-Soc Jargon`
- `Sarcastic Snark`

`Agent` mode is designed for structured prompts that can be pasted directly into an autonomous agent workflow.

## Project Notes

- This repository is the `TypeNo Agent` fork, not the original upstream app
- Historical version evolution should be read from `CHANGELOG.md`
- Current product baseline and maintenance guidance should be read from `UPDATE_MANUAL.md`

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=marswaveai/TypeNo&type=Date)](https://star-history.com/#marswaveai/TypeNo&Date)

## License

GNU General Public License v3.0
