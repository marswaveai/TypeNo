# Overlay UI + 实时波形 + 热词词典 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the recording overlay to Typeless-style (✕ | waveform | ✓), replace AVAudioRecorder with AVAudioEngine for real-time spectrum data, and add hotwords dictionary management with post-processing text correction.

**Architecture:** Replace AudioRecorder (AVAudioRecorder) with AudioEngine (AVAudioEngine + installTap) that provides real-time PCM samples for both waveform display and WAV file writing. Redesign OverlayView to show cancel/confirm buttons flanking an animated spectrum bar chart. Add HotwordsManager to persist user-defined hotwords and apply pinyin-based post-processing correction after ASR output.

**Tech Stack:** Swift 6.2, SwiftUI, AVFoundation (AVAudioEngine), Accelerate (vDSP FFT), AppKit (NSPanel)

---

## File Structure

- **Modify:** `Sources/Typeno/main.swift` — All changes are in this single file (project is single-file architecture). Sections affected:
  - `AudioRecorder` class → replace with `AudioEngine`
  - `OverlayView` struct → redesign with waveform + buttons
  - `AppState` class → add spectrum data, hotwords integration
  - `StatusItemController` → add "Manage Hotwords" menu item
  - `ColiASRService` → add post-processing correction
  - `AppDelegate` → wire up new components
  - `HotkeyMonitor` → no changes needed (Control toggle already works)

- **Create:** `~/.typeno/hotwords.txt` — User hotwords file (created at runtime)

---

### Task 1: Replace AudioRecorder with AVAudioEngine

**Files:**
- Modify: `Sources/Typeno/main.swift:542-622` (AudioRecorder class)
- Modify: `Sources/Typeno/main.swift:239-270` (AppState references)

Replace the `AudioRecorder` class with a new `AudioEngine` class that:
- Uses `AVAudioEngine` with `installTap` on input node
- Writes PCM samples to a WAV file for ASR
- Publishes real-time amplitude spectrum data (array of ~20 floats) for waveform display
- Uses Accelerate framework (vDSP) for FFT computation

- [ ] **Step 1: Write AudioEngine class**

Replace the `AudioRecorder` class (lines 542-622) with:

```swift
// MARK: - Audio Engine

@MainActor
final class AudioEngine: NSObject {
    @Published var spectrumData: [Float] = Array(repeating: 0, count: 20)

    private var engine: AVAudioEngine?
    private var outputFile: AVAudioFile?
    private var recordingURL: URL?
    private let barCount = 20

    func start() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // WAV file at 16kHz mono for ASR
        guard let wavFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw TypeNoError.noRecording
        }

        let outputFile = try AVAudioFile(forWriting: url, settings: wavFormat.settings)

        // Converter from input format to 16kHz mono
        guard let converter = AVAudioConverter(from: inputFormat, to: wavFormat) else {
            throw TypeNoError.noRecording
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            // 1. Compute spectrum from raw input buffer
            self?.computeSpectrum(buffer: buffer)

            // 2. Convert and write to WAV file
            let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate)
            guard frameCapacity > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: wavFormat, frameCapacity: frameCapacity) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if status != .error, convertedBuffer.frameLength > 0 {
                try? outputFile.write(from: convertedBuffer)
            }
        }

        try engine.start()

        self.engine = engine
        self.outputFile = outputFile
        self.recordingURL = url
        return url
    }

    func stop() -> URL? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        outputFile = nil
        spectrumData = Array(repeating: 0, count: barCount)
        return recordingURL
    }

    func cancel() {
        let url = stop()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
    }

    private func computeSpectrum(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Use vDSP for FFT
        let log2n = vDSP_Length(log2(Float(frameCount)))
        let n = Int(1 << log2n)
        guard n > 0, let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realPart = [Float](repeating: 0, count: n / 2)
        var imagPart = [Float](repeating: 0, count: n / 2)

        // Window the signal
        var windowed = [Float](repeating: 0, count: n)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        vDSP_vmul(channelData, 1, window, 1, &windowed, 1, vDSP_Length(n))

        // Pack into split complex
        windowed.withUnsafeMutableBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n / 2))
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        // Compute magnitudes
        var magnitudes = [Float](repeating: 0, count: n / 2)
        var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
        vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(n / 2))

        // Group into bars (logarithmic spacing, focus on voice frequencies)
        let usableBins = min(n / 2, 256)  // Focus on lower frequencies
        let binsPerBar = max(1, usableBins / barCount)
        var bars = [Float](repeating: 0, count: barCount)

        for i in 0..<barCount {
            let start = i * binsPerBar
            let end = min(start + binsPerBar, usableBins)
            guard start < end else { continue }
            var sum: Float = 0
            vDSP_sve(magnitudes + start, 1, &sum, vDSP_Length(end - start))
            bars[i] = sum / Float(end - start)
        }

        // Normalize to 0..1
        var maxVal: Float = 0
        vDSP_maxv(bars, 1, &maxVal, vDSP_Length(barCount))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(bars, 1, &scale, &bars, 1, vDSP_Length(barCount))
        }

        Task { @MainActor in
            self.spectrumData = bars
        }
    }
}
```

- [ ] **Step 2: Add `import Accelerate` at top of file**

Add after line 1 (`import AppKit`):
```swift
import Accelerate
```

- [ ] **Step 3: Update AppState to use AudioEngine**

Replace `private let recorder = AudioRecorder()` (line 251) with:
```swift
let recorder = AudioEngine()
```

Update `startRecording()` (line 256-262):
```swift
func startRecording() throws {
    transcript = ""
    previousApp = NSWorkspace.shared.frontmostApplication
    currentRecordingURL = try recorder.start()
    phase = .recording
    onOverlayRequest?(true)
}
```

Update `stopRecording()` (line 264-270) — make it synchronous since AudioEngine.stop() is sync:
```swift
func stopRecording() {
    guard let url = recorder.stop() else {
        showError("No recording")
        return
    }
    currentRecordingURL = url
    phase = .transcribing()
    onOverlayRequest?(true)
}
```

Update `cancel()` (line 272-284):
```swift
func cancel() {
    recorder.cancel()
    asrService.cancelCurrentProcess()
    if let currentRecordingURL {
        try? FileManager.default.removeItem(at: currentRecordingURL)
    }
    currentRecordingURL = nil
    transcript = ""
    phase = .idle
    onOverlayRequest?(false)
}
```

- [ ] **Step 4: Update AppDelegate.stopRecording() to match new sync signature**

Update `stopRecording()` in AppDelegate (lines 134-145):
```swift
private func stopRecording() {
    appState.stopRecording()
    Task { @MainActor in
        await appState.transcribeAndInsert()
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `cd /Users/zhou/Documents/TypeNo && swift build 2>&1`
Expected: Build complete

- [ ] **Step 6: Commit**

```bash
git add Sources/Typeno/main.swift
git commit -m "feat: replace AVAudioRecorder with AVAudioEngine for real-time spectrum"
```

---

### Task 2: Redesign OverlayView with Waveform + Cancel/Confirm Buttons

**Files:**
- Modify: `Sources/Typeno/main.swift:1265-1331` (OverlayView)
- Modify: `Sources/Typeno/main.swift:212-234` (AppPhase)

- [ ] **Step 1: Redesign OverlayView compactView**

Replace the `compactView` computed property (lines 1286-1331) with:

```swift
var compactView: some View {
    HStack(spacing: 0) {
        // Cancel button
        if case .recording = appState.phase {
            Button(action: { appState.onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }

        // Center content
        Group {
            if case .recording = appState.phase {
                // Real-time spectrum waveform
                spectrumView
            } else if case .transcribing(let msg) = appState.phase {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                }
            } else if case .done(let text) = appState.phase {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            } else if case .error(let msg) = appState.phase {
                HStack(spacing: 8) {
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Button("OK") { appState.onCancel?() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
            } else if case .updating(let msg) = appState.phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                }
            } else {
                Text(appState.phase.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
        }
        .frame(minWidth: 160)

        // Confirm button
        if case .recording = appState.phase {
            Button(action: { appState.onToggleRequest?() }) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop & Transcribe")
        }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
}

var spectrumView: some View {
    HStack(spacing: 2) {
        ForEach(0..<appState.recorder.spectrumData.count, id: \.self) { i in
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.primary.opacity(0.6))
                .frame(width: 3, height: max(3, CGFloat(appState.recorder.spectrumData[i]) * 28))
                .animation(.easeOut(duration: 0.08), value: appState.recorder.spectrumData[i])
        }
    }
    .frame(height: 32)
}
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/zhou/Documents/TypeNo && swift build 2>&1`
Expected: Build complete

- [ ] **Step 3: Commit**

```bash
git add Sources/Typeno/main.swift
git commit -m "feat: redesign overlay with spectrum waveform and cancel/confirm buttons"
```

---

### Task 3: Fix Recording Flow — Don't Auto-Paste, Wait for Confirm

**Files:**
- Modify: `Sources/Typeno/main.swift:345-380` (transcribeAndInsert)
- Modify: `Sources/Typeno/main.swift:101-113` (handleToggle)

Currently `transcribeAndInsert()` calls `confirmInsert()` immediately after ASR. Change it so the flow is:
- Control press 1: start recording, show overlay with waveform
- Control press 2 (or ✓ button): stop recording → ASR → auto-paste result

The ✓ button during recording already triggers `onToggleRequest` which calls `handleToggle()`, which calls `stopRecording()`. The ✕ button calls `onCancel` which calls `cancelFlow()`. This is already correct.

The only issue is the current flow already auto-pastes after ASR, which is what the user wants to keep. No change needed here — the overlay just needs to be visible during recording (Task 2 handles this).

- [ ] **Step 1: Verify the flow is correct**

Trace the flow:
1. Control press → `handleToggle()` → `startRecording()` → `phase = .recording` → overlay shows with waveform
2. Control press again → `handleToggle()` → `stopRecording()` → ASR → `confirmInsert()` → paste
3. ✕ button → `onCancel` → `cancelFlow()` → `cancel()` → reset
4. ✓ button → `onToggleRequest` → `handleToggle()` → same as Control press again

This flow is already correct. No code changes needed for this task.

- [ ] **Step 2: Commit (skip if no changes)**

No commit needed.

---

### Task 4: Add HotwordsManager for Dictionary Persistence

**Files:**
- Modify: `Sources/Typeno/main.swift` — Add new class after ColiASRService

- [ ] **Step 1: Write HotwordsManager class**

Add after the ColiASRService section (after line ~830):

```swift
// MARK: - Hotwords Manager

@MainActor
final class HotwordsManager: ObservableObject {
    static let shared = HotwordsManager()

    @Published var hotwords: [String] = []

    private let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".typeno", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hotwords.txt")
    }()

    private init() {
        load()
    }

    func load() {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            hotwords = []
            return
        }
        hotwords = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func save() {
        let content = hotwords.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func add(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !hotwords.contains(trimmed) else { return }
        hotwords.append(trimmed)
        save()
    }

    func remove(at offsets: IndexSet) {
        hotwords.remove(atOffsets: offsets)
        save()
    }

    func remove(_ word: String) {
        hotwords.removeAll { $0 == word }
        save()
    }

    /// Apply hotwords-based post-processing correction to ASR output.
    /// Matches by substring and common misrecognition patterns.
    func correct(_ text: String) -> String {
        var result = text
        for hotword in hotwords {
            // If the hotword is already in the text, skip
            if result.contains(hotword) { continue }

            // Try character-level fuzzy match:
            // Find substrings of same character count that differ by ≤1 character
            let hwChars = Array(hotword)
            let len = hwChars.count
            guard len > 0 else { continue }

            let resultChars = Array(result)
            guard resultChars.count >= len else { continue }

            for startIdx in 0...(resultChars.count - len) {
                let candidate = resultChars[startIdx..<(startIdx + len)]
                var diffCount = 0
                for (a, b) in zip(candidate, hwChars) {
                    if a != b { diffCount += 1 }
                }
                // Replace if only 1 character differs and word length >= 2
                if diffCount == 1 && len >= 2 {
                    let range = result.index(result.startIndex, offsetBy: startIdx)..<result.index(result.startIndex, offsetBy: startIdx + len)
                    result.replaceSubrange(range, with: hotword)
                    break
                }
            }
        }
        return result
    }
}
```

- [ ] **Step 2: Integrate correction into ASR output**

In `transcribeAndInsert()`, after getting the transcript, apply correction. Change (around line 363):

```swift
// Before:
transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

// After:
let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
transcript = HotwordsManager.shared.correct(raw)
```

- [ ] **Step 3: Do the same for `transcribeFile()` method**

Find the similar line in `transcribeFile()` and apply the same correction.

- [ ] **Step 4: Build and verify**

Run: `cd /Users/zhou/Documents/TypeNo && swift build 2>&1`
Expected: Build complete

- [ ] **Step 5: Commit**

```bash
git add Sources/Typeno/main.swift
git commit -m "feat: add HotwordsManager with persistence and post-processing correction"
```

---

### Task 5: Add Hotwords Settings Window in Menu

**Files:**
- Modify: `Sources/Typeno/main.swift:1080-1105` (StatusItemController.configureMenu)
- Modify: `Sources/Typeno/main.swift` — Add HotwordsSettingsView

- [ ] **Step 1: Add HotwordsSettingsView**

Add before the `// MARK: - Entry Point` section:

```swift
// MARK: - Hotwords Settings

@MainActor
final class HotwordsWindowController {
    static let shared = HotwordsWindowController()
    private var window: NSWindow?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HotwordsSettingsView()
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hotwords Dictionary"
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

struct HotwordsSettingsView: View {
    @ObservedObject var manager = HotwordsManager.shared
    @State private var newWord = ""

    var body: some View {
        VStack(spacing: 0) {
            // Add bar
            HStack {
                TextField("Add hotword...", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addWord() }

                Button(action: addWord) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            Divider()

            // Word list
            if manager.hotwords.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No hotwords yet")
                        .foregroundStyle(.secondary)
                    Text("Add words that are often misrecognized\n(names, technical terms, etc.)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            } else {
                List {
                    ForEach(manager.hotwords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Button(action: { manager.remove(word) }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { offsets in
                        manager.remove(at: offsets)
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 300)
    }

    private func addWord() {
        manager.add(newWord)
        newWord = ""
    }
}
```

- [ ] **Step 2: Add menu item in StatusItemController**

In `configureMenu()` (around line 1091), add after the "Transcribe File..." item:

```swift
let hotwordsItem = NSMenuItem(title: "Manage Hotwords...", action: #selector(openHotwords), keyEquivalent: "")
hotwordsItem.target = self
menu.addItem(hotwordsItem)
```

Add the action method to `StatusItemController`:

```swift
@objc private func openHotwords() {
    HotwordsWindowController.shared.show()
}
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/zhou/Documents/TypeNo && swift build 2>&1`
Expected: Build complete

- [ ] **Step 4: Build .app and test**

Run: `cd /Users/zhou/Documents/TypeNo && bash scripts/build_app.sh 2>&1`
Expected: Built TypeNo.app

- [ ] **Step 5: Commit**

```bash
git add Sources/Typeno/main.swift
git commit -m "feat: add hotwords settings window with add/delete UI"
```

---

### Task 6: Integration Test — Full Build and Manual Test

- [ ] **Step 1: Kill existing instance and launch new build**

```bash
pkill -f TypeNo; sleep 1; open /Users/zhou/Documents/TypeNo/dist/TypeNo.app
```

- [ ] **Step 2: Manual test checklist**

1. Click menu bar icon → verify "Manage Hotwords..." menu item exists
2. Open Hotwords settings → add a test word (e.g., "周伟强")
3. Verify `~/.typeno/hotwords.txt` contains the word
4. Press Control → verify overlay shows with ✕ | waveform | ✓
5. Speak → verify waveform animates with voice
6. Press Control again → verify ASR runs and text is pasted
7. Press Control, then click ✕ → verify recording is canceled

- [ ] **Step 3: Push branch**

```bash
git push -u origin feature/dynamic-dictionary
```
