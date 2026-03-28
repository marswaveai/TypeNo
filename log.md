# Change log

## v1.4.0 — 2026-03-28
- **Streaming live preview**: while recording, TypeNo feeds live microphone PCM into `coli asr-stream` for about-once-per-second overlay text preview. Final paste still uses full-file `coli asr` pass.
- **New overlay design**: dark solid background (not translucent), fixed 360pt width, rounded rectangle, breathing dot indicator. Replaces old capsule-shaped overlay.
- **Bug fix**: second recording now correctly gets streaming preview (fixed `previewState` cleanup in `finishPreviewStream`).
- **Bug fix**: overlay position no longer jumps between phases (fixed center positioning for compactView).
- **Bug fix**: Swift concurrency errors in `captureOutput` audio data delegate (actor isolation fix with lock-protected dictionary).
- **Code cleanup**: removed 2 unused imports, 3 dead methods, 5 dead properties, 1 dead callback. Reduced unnecessary `@Published` usage.
- **Docs synced**: updated README (EN/CN/JP) to describe streaming preview feature.

## v1.3.1 — 2026-03-27
- **Better error messages**: detect and surface actionable fixes for three common setup failures:
  - Missing `ffmpeg` → prompt `brew install ffmpeg` instead of spinning until timeout
  - Node.js not in PATH (`env:node: No such file`) → prompt user to install Node.js from nodejs.org
  - Node 24 + `sherpa-onnx-node` incompatibility → suggest `--build-from-source`
- **README updates**: added `ffmpeg` and Node.js as explicit prerequisites in EN/CN/JP docs; added Node 24 workaround note.

## v1.3.0 — 2026-03-26
- **Esc to cancel**: press Esc during recording or transcription to abort and return to idle. Focus is restored to the previous app.
- **Universal Binary**: app now runs natively on both Apple Silicon and Intel Macs (arm64 + x86_64).
- **Better timeout diagnostics**: on transcription timeout, coli's recent output is included in the error message instead of a generic "Timeout".
- **Incomplete model detection**: if coli's model archive exists but failed to extract, a clear error is shown with the fix command instead of timing out silently.
- **Accessibility permission fix**: added troubleshooting guide (with GIF) to all READMEs for the macOS bug where toggling the permission has no effect (fix: remove with − then re-add with +).

## 2026-03-26
- Added Accessibility permission troubleshooting section to all three READMEs (EN/CN/JP).
  - macOS bug: enabling TypeNo in Accessibility settings sometimes has no effect.
  - Fix: remove (−) then re-add (+) TypeNo in the list.
  - Added `assets/accessibility-fix.gif` screen recording to illustrate the steps.

## v1.2.6 — 2026-03-25
- Menu bar idle icon: replaced hotkey modifier symbol (⌃/⌥/⌘/⇧) with ◎, rendered as NSImage (16pt medium, 22×22) for precise vertical centering. `isTemplate = true` for light/dark mode support.
- Added left/right specific modifier hotkeys: 8 options total (Left/Right × Control/Option/Command/Shift), replaced original 4 generic ones. Detection via `event.keyCode` on `flagsChanged` NSEvent.
- Fixed long recording (>2 min) transcription failure: dynamic timeout `max(120s, duration×2)` via AVAudioFile, recording elapsed timer in overlay (e.g. `1:32`), ⚠ warning at 1:45.
- Auto-update redirects to GitHub releases page instead of in-place install (avoids macOS quarantine/Gatekeeper issues).

## v1.2.2 — 2026-03-25
- Fixed long recording (>2 min) transcription failure:
  - **Dynamic timeout**: coli subprocess timeout is now `max(120s, audio_duration × 2)` instead of fixed 120s — reads actual audio file length via `AVAudioFile`.
  - **Recording timer**: overlay now shows elapsed recording time (e.g., `1:32`) as a live counter instead of static "Listening...".
  - **Cleaner transcription progress**: removed confusing "转录中...10s / 15s" elapsed counter — just shows "转录中..." with spinner; "Long audio, please wait..." only appears after 2+ minutes of transcription.

## 2026-03-25
- Fixed `TypeError: fetch failed` when coli downloads ASR models from within the GUI app.
  - Root cause: macOS system proxy (192.168.31.144:7890) is active but Node.js fetch (undici) only reads `HTTP_PROXY`/`HTTPS_PROXY` env vars, which are unset in GUI app subprocess context.
  - Fix: added `systemHTTPSProxyURL()` helper in `TranscriptionEngine` that reads `CFNetworkCopySystemProxySettings()` and injects `HTTP_PROXY`/`HTTPS_PROXY` into the coli subprocess environment when they're not already set.
## 2026-03-25
- Cleaned up all README files: single language per file, language switcher at top, hero image after one-line intro, removed redundant copy.
- Fixed outdated coli package name in README_JP.md (`@coli.codes/coli` → `@marswave/coli`).
- Added "Check for Updates" to usage tables across all README versions.
- Added in-app auto-update mechanism via GitHub Releases API.
  - Menu item "Check for Updates..." downloads and replaces app in-place.
  - In-place replacement preserves macOS Accessibility and Microphone permissions (no re-authorization needed).
  - Downloads zip, removes quarantine xattr, backs up old app, replaces, relaunches.
  - Silent update check on launch — marks menu item with version if update available.
  - Progress shown in overlay: Downloading → Installing → Restarting.
- Synced Info.plist version from `0.1.0` to `1.0.3` to match GitHub releases.
- Enabled HTTPS enforcement for typeno.com (re-provisioned SSL certificate via GitHub Pages API).
- Fixed transcription timeout issue (#7): pipe buffer deadlock — stdout/stderr read after `waitUntilExit()` caused coli to block when output exceeded 64KB. Changed to async `readabilityHandler`. Timeout 30s → 120s. Added live progress indicator (elapsed time + "Almost timeout..." warning).
- Fixed coli detection for GUI apps (#6): `resolveViaShell` now uses interactive shell (`-l -i`) so nvm/fnm/volta init scripts load. Added `resolveNpmGlobalBin()` for custom npm prefix.
- Bumped version to 1.0.6, published release with both fixes.
- Added Star History chart to all READMEs (star-history.com SVG, no auth).
- Simplified README tagline: blockquote → bold text, kept only core positioning, removed operation instructions.

## 2026-03-24 (Night)
- Reverted commit `d3d2821` that accidentally deleted app icon assets, `generate_icon.sh`, and build config.
- Restored full v1.0.2 source code from GitHub release (iCloud sync had overwritten local repo with old code, losing: Control key trigger, bottom overlay, auto-transcribe, drag-and-drop, coli install guidance, file transcription).
- Merged v1.0.3 coli shell fallback fix (`resolveViaShell`) into restored code.
- Fixed macOS icon sizing: added 10% padding and superellipse rounded corners per Apple HIG, keeping original brand design (blue gradient + ⌃).
- Closed PR #4 (icon sizing from ShellMonster) — addressed the feedback ourselves.
- Improved first-run UX:
  - Auto-poll permissions every 2s, auto-dismiss overlay when granted (no more manual "Try Again").
  - Auto-detect coli installation, auto-dismiss overlay when found.
  - Moved permission/coli overlays from screen center to top-right corner (no longer blocks System Settings).
  - Added copy button for `npm install -g @marswave/coli` command.
  - Allow Control key to cancel stuck transcribing/error states.
  - Added 30s timeout for coli process to prevent infinite hang.
  - Cancel now terminates running coli process.
- Enabled HTTPS enforcement for typeno.com GitHub Pages (re-provisioned SSL certificate).
- Rebuilt and updated v1.0.3 release with all fixes.

## 2026-03-24 (Evening)
- Changed the project license from MIT to GNU General Public License v3.0.
- Updated `LICENSE`, `README.md`, `README_CN.md`, and `README_JP.md` to reflect GPLv3.
- Rewrote install sections across all README language versions for novice users.
- Prioritized GitHub Releases download flow, with source build kept as a secondary option.
- Added direct latest release links, unzip/install steps, macOS security note, and clearer first-launch guidance.
- Added troubleshooting for the macOS "app is damaged" Gatekeeper case across all README language versions.
- Added beginner-friendly in-app guidance for missing `coli`, reusing the centered onboarding overlay with install help and retry.
- Updated Coli install instructions to `npm install -g @marswave/coli`.
- Adjusted the Gatekeeper troubleshooting again after confirming Open Anyway now appears, and focused the main documentation strategy on English + Chinese.
- Updated `scripts/build_app.sh` to ad-hoc sign the packaged app bundle after assembling it.
- Rebuilt the app package and replaced the `v1.0.0` GitHub release zip with the refreshed build.
- Added `https://typeno.com` to all README language versions as the official website.
- Added a top-of-page hero image (`assets/hero.webp`) across all README language versions.
- Replaced the hero image asset with a new version for the project homepage.
- Added thanks/credit to marswave ai's `coli` project across the README language versions.
- Moved `coli` installation into its own step in the install flow.
- Added short promotional positioning copy near the top of all README language versions so the repository homepage also works as launch marketing.
- Adjusted the English README top section to a bilingual first screen so it matches the Chinese hero image while keeping English as the primary language.
- Filled the GitHub repository About metadata with description, website, and topics.
- Packaged `dist/TypeNo.app` into `dist/TypeNo.app.zip` for distribution.
- Pushed release-prep changes to `main` and created GitHub release `v1.0.0` with the app zip attached.
- Moved overlay panel from top to bottom of screen for better UX.
- Redesigned overlay: removed red recording indicator, made it smaller (280x44), single-line, more elegant with subtle gray dot.
- Auto-start transcription after recording stops (removed manual Complete button step).
- Improved coli not found error message with installation command: `npm i -g @coli.codes/coli`.
- Fixed privacy settings deep links for microphone and accessibility permissions.
- Added app icon: blue gradient with "Fn" text, generated via `scripts/generate_icon.sh`.
- Added drag-and-drop support: drag audio files (.m4a, .mp3, .wav, .aac) to menu bar icon for transcription.

## 2026-03-24 (Earlier)
- Updated visible branding from Typeno to TypeNo.
- Renamed the project folder from `sayit` to `typeno`.
- Renamed the product from SayIt to TypeNo.
- Updated Swift package name, executable product, source target path, bundle identifier, and microphone permission text.
- Renamed the main source path to `Sources/Typeno/main.swift` and updated in-app labels and error type names.
- Scaffolded a minimal native macOS TypeNo app with Swift Package Manager.
- Added `App/Info.plist` for accessory app behavior and microphone permission text.
- Implemented core app flow in `Sources/Typeno/main.swift`:
  - global Fn-based toggle listener
  - temporary audio recording
  - tiny floating overlay with Cancel / Complete
  - `coli asr` invocation for transcription
  - text insertion via Accessibility with paste fallback
  - minimal status item for quit/privacy access
- Verified the project builds successfully with `swift build`.
- Verified app packaging with `scripts/build_app.sh`, producing `dist/TypeNo.app` and launching it successfully.
- Improved first-run permission guidance with clearer microphone/accessibility onboarding, settings deep links, and retry actions.
