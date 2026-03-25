import Accelerate
import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers



@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItemController: StatusItemController?
    private var hotkeyMonitor: HotkeyMonitor?
    private var overlayController: OverlayPanelController?
    private var permissionsGranted = false
    private var pollTimer: Timer?
    private let updateService = UpdateService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        overlayController = OverlayPanelController(appState: appState)
        statusItemController = StatusItemController(appState: appState)
        hotkeyMonitor = HotkeyMonitor(onToggle: { [weak self] in
            self?.handleToggle()
        })

        appState.onToggleRequest = { [weak self] in
            self?.handleToggle()
        }

        appState.onPermissionOpen = { [weak self] kind in
            self?.openPermissionSettings(for: kind)
        }

        appState.onColiInstallHelpRequest = { [weak self] in
            self?.openColiInstallHelp()
        }

        appState.onCancel = { [weak self] in
            self?.cancelFlow()
        }

        appState.onConfirm = { [weak self] in
            self?.appState.confirmInsert()
        }

        appState.onUpdateRequest = { [weak self] in
            self?.performUpdate()
        }

        // Auto-poll permissions and coli install status
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollStatus()
            }
        }

        hotkeyMonitor?.start()

        // Silent update check on launch
        Task {
            if let release = await updateService.checkForUpdate() {
                statusItemController?.setUpdateAvailable(release.version)
            }
        }
    }

    private func pollStatus() {
        switch appState.phase {
        case .permissions:
            let missing = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: false)
            if missing.isEmpty {
                permissionsGranted = true
                appState.hidePermissions()
            } else {
                appState.showPermissions(missing)
            }
        case .missingColi:
            if ColiASRService.isInstalled {
                appState.hideColiGuidance()
            } else if ColiASRService.isNpmAvailable {
                // npm became available (user installed Node), trigger auto-install
                appState.autoInstallColi()
            }
        default:
            break
        }
    }

    private func handleToggle() {
        switch appState.phase {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .done:
            appState.confirmInsert()
        case .transcribing, .error:
            appState.cancel()
        case .downloadingModel:
            appState.cancel()
        case .permissions, .missingColi, .installingColi, .updating:
            break
        }
    }

    private func startRecording() {
        // Only check permissions if not previously granted this session
        if !permissionsGranted {
            let missing = PermissionManager.missingPermissions(requestMicrophoneIfNeeded: true, requestAccessibilityIfNeeded: true)
            if !missing.isEmpty {
                appState.showPermissions(missing)
                return
            }
            permissionsGranted = true
        }

        // Check if model is ready before recording
        if !ColiASRService.modelDirectoryExists {
            Task { @MainActor in
                await appState.downloadModelThenRecord()
            }
            return
        }

        do {
            try appState.startRecording()
        } catch {
            appState.showError(error.localizedDescription)
        }
    }

    private func stopRecording() {
        appState.stopRecording()
        Task { @MainActor in
            await appState.transcribeAndInsert()
        }
    }

    private func cancelFlow() {
        appState.cancel()
    }

    private func openPermissionSettings(for kind: PermissionKind) {
        PermissionManager.openPrivacySettings(for: [kind])
    }

    private func openColiInstallHelp() {
        guard let url = URL(string: "https://github.com/marswaveai/coli") else { return }
        NSWorkspace.shared.open(url)
    }

    private func performUpdate() {
        Task {
            appState.phase = .updating("Checking for updates")

            guard let release = await updateService.checkForUpdate() else {
                appState.phase = .idle
                // Show brief "up to date" message
                appState.showError("Already up to date")
                return
            }

            do {
                try await updateService.downloadAndInstall(from: release.downloadURL) { message in
                    self.appState.phase = .updating(message)
                }
            } catch {
                appState.showError("Update failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Model

enum PermissionKind: CaseIterable, Hashable {
    case microphone
    case accessibility

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        }
    }

    var explanation: String {
        switch self {
        case .microphone: "Required to capture your voice"
        case .accessibility: "Required to type text into apps"
        }
    }

    var icon: String {
        switch self {
        case .microphone: "mic.fill"
        case .accessibility: "hand.raised.fill"
        }
    }
}

enum AppPhase: Equatable {
    case idle
    case downloadingModel(progress: Double, text: String)  // 0.0-1.0, "42.5 / 155.5 MB"
    case recording
    case transcribing(String = "Transcribing")
    case done(String)        // transcription result, waiting for user confirm
    case permissions(Set<PermissionKind>)
    case missingColi
    case installingColi(String) // progress message
    case updating(String)    // progress message
    case error(String)

    var subtitle: String {
        switch self {
        case .idle: "Press Fn to start"
        case .downloadingModel(_, let text): text
        case .recording: "Listening"
        case .transcribing(let message): message
        case .done(let text): text
        case .permissions, .missingColi, .installingColi: ""
        case .updating(let message): message
        case .error(let message): message
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var phase: AppPhase = .idle
    @Published var transcript = ""

    var onPermissionOpen: ((PermissionKind) -> Void)?
    var onColiInstallHelpRequest: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onToggleRequest: (() -> Void)?
    var onUpdateRequest: (() -> Void)?

    let recorder = AudioEngine()
    private let asrService = ColiASRService()
    private var currentRecordingURL: URL?
    private var previousApp: NSRunningApplication?
    private var spectrumCancellable: AnyCancellable?

    init() {
        spectrumCancellable = recorder.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.objectWillChange.send()
            }
        }
    }

    /// Route progress messages to the correct UI — download or transcription
    func handleProgressMessage(_ message: String) {
        if message.contains("MB") || message.contains("Downloading") || message.contains("Extracting") || message.contains("ready") {
            // Model download progress → extract percentage for ring, pass text as-is
            let progress: Double
            if let pctRange = message.range(of: #"\([\d.]+%\)"#, options: .regularExpression),
               let pctVal = Double(message[pctRange].dropFirst().dropLast().replacingOccurrences(of: "%", with: "")) {
                progress = pctVal / 100.0
            } else if message.contains("Extracting") || message.contains("ready") {
                progress = 1.0
            } else {
                progress = 0
            }
            phase = .downloadingModel(progress: progress, text: message)
        } else {
            phase = .transcribing(message)
        }
    }

    func downloadModelThenRecord() async {
        phase = .downloadingModel(progress: 0, text: "Checking model")

        do {
            try await asrService.downloadModel { [weak self] message in
                self?.handleProgressMessage(message)
            }
            // Model ready, start recording directly (skip .idle to avoid flicker)
            try startRecording()
        } catch {
            showError("Model download failed: \(error.localizedDescription)")
        }
    }

    func startRecording() throws {
        transcript = ""
        previousApp = NSWorkspace.shared.frontmostApplication
        currentRecordingURL = try recorder.start()
        phase = .recording

    }

    func stopRecording() {
        currentRecordingURL = recorder.stop()
        phase = .transcribing()

    }

    func cancel() {
        recorder.cancel()
        asrService.cancelCurrentProcess()
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        transcript = ""
        phase = .idle

    }

    func showPermissions(_ missing: Set<PermissionKind>) {
        phase = .permissions(missing)

    }

    func hidePermissions() {
        phase = .idle

    }

    func showMissingColi() {
        // If npm is available, auto-install coli instead of showing manual guidance
        if ColiASRService.isNpmAvailable {
            autoInstallColi()
        } else {
            phase = .missingColi
    
        }
    }

    func autoInstallColi() {
        phase = .installingColi("Installing coli")


        Task {
            do {
                try await ColiASRService.installColi { [weak self] message in
                    self?.phase = .installingColi(message)
                }
                // Verify installation
                if ColiASRService.isInstalled {
                    phase = .idle
            
                } else {
                    // Fallback to manual guidance
                    phase = .missingColi
                }
            } catch {
                showError("Install failed: \(error.localizedDescription)")
            }
        }
    }

    func hideColiGuidance() {
        if case .missingColi = phase {
            phase = .idle
    
        }
    }

    func showError(_ message: String) {
        phase = .error(message)

    }

    func transcribeAndInsert() async {
        guard let url = currentRecordingURL else {
            showError("No recording")
            return
        }

        phase = .transcribing()

        // Progress timer: show elapsed time and warn near timeout
        let startTime = Date()
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let elapsed = Int(Date().timeIntervalSince(startTime))
                if elapsed >= 100 {
                    self?.phase = .transcribing("Timeout \(elapsed)s")
                } else if elapsed >= 10 {
                    self?.phase = .transcribing("Transcribing \(elapsed)s")
                }
            }
        }

        do {
            let text = try await asrService.transcribe(fileURL: url) { [weak self] message in
                self?.handleProgressMessage(message)
            }
            progressTimer.invalidate()
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            // Skip showing result in overlay — go straight to paste
            confirmInsert()
        } catch TypeNoError.coliNotInstalled {
            progressTimer.invalidate()
            showMissingColi()
        } catch {
            progressTimer.invalidate()
            let msg = error.localizedDescription
            if msg.contains("protobuf") || msg.contains("Failed to load model") {
                // Model is corrupt — delete and trigger re-download
                ColiASRService.deleteModelDirectory()
                await downloadModelThenRecord()
            } else {
                showError(msg)
            }
        }
    }

    func confirmInsert() {
        guard !transcript.isEmpty else {
            cancel()
            return
        }

        let text = transcript
        let targetApp = previousApp

        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Hide overlay


        // Activate previous app, then Cmd+V
        if let targetApp {
            targetApp.activate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let source = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            vDown?.flags = .maskCommand
            vUp?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)

            self?.resetState()
        }
    }

    private func resetState() {
        if let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        previousApp = nil
        transcript = ""
        phase = .idle

    }

    func transcribeFile(_ url: URL) async {
        previousApp = NSWorkspace.shared.frontmostApplication
        phase = .transcribing()


        let startTime = Date()
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                let elapsed = Int(Date().timeIntervalSince(startTime))
                if elapsed >= 100 {
                    self?.phase = .transcribing("Timeout \(elapsed)s")
                } else if elapsed >= 10 {
                    self?.phase = .transcribing("Transcribing \(elapsed)s")
                }
            }
        }

        do {
            let text = try await asrService.transcribe(fileURL: url) { [weak self] message in
                self?.handleProgressMessage(message)
            }
            progressTimer.invalidate()
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            confirmInsert()
        } catch TypeNoError.coliNotInstalled {
            progressTimer.invalidate()
            showMissingColi()
        } catch {
            progressTimer.invalidate()
            let msg = error.localizedDescription
            if msg.contains("protobuf") || msg.contains("Failed to load model") {
                // Model corrupt — re-download then retry once
                ColiASRService.deleteModelDirectory()
                phase = .downloadingModel(progress: 0, text: "Checking model")
                do {
                    try await asrService.downloadModel { [weak self] message in
                        self?.handleProgressMessage(message)
                    }
                    // Retry transcription once (no recursion)
                    phase = .transcribing()
                    let retryText = try await asrService.transcribe(fileURL: url)
                    transcript = retryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !transcript.isEmpty { confirmInsert() }
                    else { showError("No speech detected") }
                } catch {
                    showError("Model download failed")
                }
            } else {
                showError(msg)
            }
        }
    }
}

// MARK: - Errors

enum TypeNoError: LocalizedError {
    case noRecording
    case emptyTranscript
    case coliNotInstalled
    case npmNotFound
    case coliInstallFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecording: "No recording"
        case .emptyTranscript: "No speech detected"
        case .coliNotInstalled: "TypeNo needs the local Coli engine. Install it with: npm install -g @marswave/coli"
        case .npmNotFound: "Node.js is required. Install it from https://nodejs.org"
        case .coliInstallFailed(let message): "Coli install failed: \(message)"
        case .transcriptionFailed(let message): message
        }
    }
}

// MARK: - Permission Manager

enum PermissionManager {
    static func missingPermissions(requestMicrophoneIfNeeded: Bool, requestAccessibilityIfNeeded: Bool = false) -> Set<PermissionKind> {
        var missing = Set<PermissionKind>()

        switch microphoneStatus(requestIfNeeded: requestMicrophoneIfNeeded) {
        case .authorized:
            break
        default:
            missing.insert(.microphone)
        }

        if !accessibilityStatus(requestIfNeeded: requestAccessibilityIfNeeded) {
            missing.insert(.accessibility)
        }

        return missing
    }

    static func microphoneStatus(requestIfNeeded: Bool) -> AVAuthorizationStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined, requestIfNeeded {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        return status
    }

    static func accessibilityStatus(requestIfNeeded: Bool) -> Bool {
        guard requestIfNeeded else {
            return AXIsProcessTrusted()
        }
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openPrivacySettings(for permissions: Set<PermissionKind>) {
        let urlString: String
        if permissions.contains(.accessibility) {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        } else if permissions.contains(.microphone) {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        } else {
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Audio Engine

final class AudioEngine: ObservableObject, @unchecked Sendable {
    @Published var spectrumData: [Float] = Array(repeating: 0, count: 20)

    private var engine: AVAudioEngine?
    private var recordingURL: URL?
    private var outputFile: AVAudioFile?
    private let fftSize: Int = 1024
    private var fftSetup: FFTSetup?
    private let fftLock = NSLock()

    func start() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16 kHz mono for converter
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw TypeNoError.noRecording
        }

        // Write as m4a (AAC) — same as original AVAudioRecorder, coli handles it
        let fileSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.outputFile = file

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw TypeNoError.noRecording
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

            let spectrum = self.computeSpectrum(buffer: buffer)

            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * 16_000 / inputFormat.sampleRate
            )
            guard frameCapacity > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity + 16) else {
                return
            }

            var error: NSError?
            var allConsumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if allConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                allConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, convertedBuffer.frameLength > 0 {
                try? file.write(from: convertedBuffer)
            }

            DispatchQueue.main.async {
                self.spectrumData = spectrum
            }
        }

        try engine.start()
        self.engine = engine
        self.recordingURL = url
        return url
    }

    func stop() -> URL? {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        outputFile = nil
        fftLock.lock()
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
            fftSetup = nil
        }
        fftLock.unlock()
        let url = recordingURL
        recordingURL = nil
        spectrumData = Array(repeating: 0, count: 20)
        return url
    }

    func cancel() {
        let url = stop()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func computeSpectrum(buffer: AVAudioPCMBuffer) -> [Float] {
        let fftSize = 1024
        guard let channelData = buffer.floatChannelData?[0] else {
            return Array(repeating: 0, count: 20)
        }

        let frameLength = Int(buffer.frameLength)
        let count = min(frameLength, fftSize)

        var windowed = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(channelData, 1, &window, 1, &windowed, 1, vDSP_Length(count))

        let halfN = fftSize / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                windowed.withUnsafeBufferPointer { windowedBuf in
                    windowedBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                let log2n = vDSP_Length(log2(Double(fftSize)))
                self.fftLock.lock()
                if self.fftSetup == nil {
                    self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
                }
                let setup = self.fftSetup
                self.fftLock.unlock()
                if let setup {
                    vDSP_fft_zrip(setup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                }

                var magnitudes = [Float](repeating: 0, count: halfN)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))

                var one: Float = 1.0
                var dbMagnitudes = [Float](repeating: 0, count: halfN)
                vDSP_vdbcon(&magnitudes, 1, &one, &dbMagnitudes, 1, vDSP_Length(halfN), 1)
                magnitudes = dbMagnitudes

                let barCount = 20
                var bars = [Float](repeating: 0, count: barCount)
                let sampleRate = buffer.format.sampleRate
                let binResolution = sampleRate / Double(fftSize)
                let lowBin = max(1, Int(80.0 / binResolution))
                let highBin = min(halfN, Int(4000.0 / binResolution))
                let voiceBins = highBin - lowBin
                guard voiceBins > 0 else { return }

                for i in 0..<barCount {
                    let startBin = lowBin + (i * voiceBins) / barCount
                    let endBin = lowBin + ((i + 1) * voiceBins) / barCount
                    let clampedEnd = min(endBin, highBin)
                    if startBin < clampedEnd {
                        var sum: Float = 0
                        magnitudes.withUnsafeBufferPointer { buf in
                            vDSP_meanv(buf.baseAddress! + startBin, 1, &sum, vDSP_Length(clampedEnd - startBin))
                        }
                        bars[i] = sum
                    }
                }

                let minVal: Float = -80
                let maxVal: Float = 0
                for i in 0..<barCount {
                    bars[i] = (max(minVal, min(maxVal, bars[i])) - minVal) / (maxVal - minVal)
                }

                for i in 0..<barCount {
                    realBuf[i] = bars[i]
                }
            }
        }

        return Array(realp.prefix(20))
    }
}

// MARK: - ASR Service

/// Thread-safe mutable data buffer for pipe reading.
private final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func read() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Thread-safe timestamp for tracking last activity.
private final class AtomicTimestamp: @unchecked Sendable {
    private var value: TimeInterval = Date().timeIntervalSince1970
    private let lock = NSLock()
    func update() { lock.lock(); value = Date().timeIntervalSince1970; lock.unlock() }
    func elapsed() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince1970 - value }
}

final class ColiASRService: @unchecked Sendable {
    static var isInstalled: Bool {
        findColiPath() != nil
    }

    /// Check if the ASR model directory exists (basic check)
    static var modelDirectoryExists: Bool {
        let modelDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coli/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17")
        let modelFile = modelDir.appendingPathComponent("model.int8.onnx")
        let tokensFile = modelDir.appendingPathComponent("tokens.txt")
        return FileManager.default.fileExists(atPath: modelFile.path)
            && FileManager.default.fileExists(atPath: tokensFile.path)
    }

    /// Delete model directory (used when model is corrupt)
    static func deleteModelDirectory() {
        let modelDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".coli/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17")
        try? FileManager.default.removeItem(atPath: modelDir.path)
    }

    /// Download model by running a tiny transcription (coli auto-downloads on first use)
    func downloadModel(onProgress: @MainActor @Sendable @escaping (String) -> Void) async throws {
        guard let coliPath = Self.findColiPath() else {
            throw TypeNoError.coliNotInstalled
        }

        // Create a tiny silent WAV file to trigger coli's model download
        let silentURL = FileManager.default.temporaryDirectory.appendingPathComponent("coli-init.wav")
        if !FileManager.default.fileExists(atPath: silentURL.path) {
            // Minimal WAV: 16kHz mono, 0.1s silence
            var header = Data()
            let dataSize: UInt32 = 3200  // 0.1s * 16000 * 2 bytes
            let fileSize: UInt32 = 36 + dataSize
            header.append(contentsOf: "RIFF".utf8)
            header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
            header.append(contentsOf: "WAVE".utf8)
            header.append(contentsOf: "fmt ".utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM
            header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // mono
            header.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) }) // sample rate
            header.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Array($0) }) // byte rate
            header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })   // block align
            header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })  // bits per sample
            header.append(contentsOf: "data".utf8)
            header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
            header.append(Data(count: Int(dataSize)))  // silence
            try header.write(to: silentURL)
        }

        // Run coli asr on the silent file — this triggers model download
        _ = try await transcribe(fileURL: silentURL, onProgress: onProgress)
    }

    static var isNpmAvailable: Bool {
        findNpmPath() != nil
    }

    /// Auto-install coli via npm. Reports progress via callback.
    static func installColi(onProgress: @MainActor @Sendable @escaping (String) -> Void) async throws {
        guard let npmPath = findNpmPath() else {
            throw TypeNoError.npmNotFound
        }

        await onProgress("Installing coli")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: npmPath)
                    process.arguments = ["install", "-g", "@marswave/coli"]

                    // Set up PATH so npm can find node
                    let npmDir = (npmPath as NSString).deletingLastPathComponent
                    let env = ProcessInfo.processInfo.environment
                    let home = env["HOME"] ?? ""
                    let extraPaths = [
                        npmDir,
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        home + "/.nvm/current/bin",
                        home + "/.volta/bin",
                        home + "/.local/share/fnm/aliases/default/bin"
                    ]
                    var processEnv = env
                    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                    processEnv["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                    process.environment = processEnv

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    // Read pipe data asynchronously to avoid deadlock
                    let stderrBuf = LockedData()
                    let stderrHandle = stderr.fileHandleForReading

                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty { stderrBuf.append(data) }
                    }

                    try process.run()

                    // 120-second timeout for install
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning { process.terminate() }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    stderrHandle.readabilityHandler = nil

                    guard process.terminationStatus == 0 else {
                        let errorOutput = String(data: stderrBuf.read(), encoding: .utf8) ?? ""
                        let msg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TypeNoError.coliInstallFailed(msg.isEmpty ? "npm install failed" : msg)
                    }

                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private var currentProcess: Process?
    private let processLock = NSLock()

    func cancelCurrentProcess() {
        processLock.lock()
        let proc = currentProcess
        currentProcess = nil
        processLock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    func transcribe(fileURL: URL, onProgress: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> String {
        guard let coliPath = Self.findColiPath() else {
            throw TypeNoError.coliNotInstalled
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: coliPath)
                    process.arguments = ["asr", fileURL.path]

                    // Inherit a proper PATH so node/bun can be found
                    var env = ProcessInfo.processInfo.environment
                    let home = env["HOME"] ?? ""
                    let extraPaths = [
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        home + "/.nvm/versions/node/",  // nvm
                        home + "/.bun/bin",
                        home + "/.npm-global/bin",
                        "/opt/homebrew/opt/node/bin"
                    ]
                    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                    env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
                    process.environment = env

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    // Read pipe data asynchronously to avoid deadlock when buffer fills up
                    let stdoutBuf = LockedData()
                    let stderrBuf = LockedData()
                    let stdoutHandle = stdout.fileHandleForReading
                    let stderrHandle = stderr.fileHandleForReading

                    // Track last activity — reset on any stderr output (download progress)
                    let lastActivity = AtomicTimestamp()

                    // Throttle: only update UI when percentage changes by >= 1%
                    let lastReportedPct = AtomicTimestamp()  // reuse as atomic double storage

                    // Parse progress from a chunk of output (may contain \r-separated lines)
                    @Sendable func parseProgress(_ data: Data) {
                        guard let onProgress, let text = String(data: data, encoding: .utf8) else { return }
                        let line = text.components(separatedBy: "\r").last?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !line.isEmpty else { return }

                        // Only forward progress-related lines, pass data as-is
                        if line.contains("MB") && line.contains("%") {
                            if let pctRange = line.range(of: #"[\d.]+"#, options: .regularExpression, range: (line.range(of: "(")?.upperBound ?? line.startIndex)..<line.endIndex),
                               let pct = Double(line[pctRange]) {
                                let elapsed = lastReportedPct.elapsed()
                                guard elapsed > 1.0 else { return }
                                lastReportedPct.update()
                            }
                        } else if !line.contains("Downloading") && !line.contains("Extracting") && !line.contains("ready") {
                            return
                        }
                        Task { @MainActor in
                            onProgress(line)
                        }
                    }

                    stdoutHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            stdoutBuf.append(data)
                            lastActivity.update()
                            parseProgress(data)
                        }
                    }
                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            stderrBuf.append(data)
                            lastActivity.update()
                            parseProgress(data)
                        }
                    }

                    self?.processLock.lock()
                    self?.currentProcess = process
                    self?.processLock.unlock()

                    try process.run()

                    // Idle timeout: kill if no output for 120s
                    // If downloading (stderr active), keeps waiting indefinitely
                    let timeoutCheck = DispatchSource.makeTimerSource(queue: .global())
                    timeoutCheck.schedule(deadline: .now() + 10, repeating: 10)
                    timeoutCheck.setEventHandler {
                        if lastActivity.elapsed() > 120 && process.isRunning {
                            process.terminate()
                        }
                    }
                    timeoutCheck.resume()

                    process.waitUntilExit()
                    timeoutCheck.cancel()

                    // Stop reading handlers
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil

                    self?.processLock.lock()
                    self?.currentProcess = nil
                    self?.processLock.unlock()

                    let output = String(data: stdoutBuf.read(), encoding: .utf8) ?? ""
                    let errorOutput = String(data: stderrBuf.read(), encoding: .utf8) ?? ""

                    guard process.terminationReason != .uncaughtSignal else {
                        // Check if crash was due to corrupt model
                        if errorOutput.contains("protobuf") || errorOutput.contains("Failed to load model") {
                            throw TypeNoError.transcriptionFailed("Failed to load model")
                        }
                        throw TypeNoError.transcriptionFailed("Transcription timed out")
                    }

                    guard process.terminationStatus == 0 else {
                        let msg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TypeNoError.transcriptionFailed(msg.isEmpty ? "coli failed" : msg)
                    }

                    // stdout may contain download progress before the actual result
                    // The transcription is always the last non-empty line
                    let lines = output.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && !$0.contains("MB /") && !$0.contains("Downloading") && !$0.contains("Extracting") && !$0.contains("ready.") }
                    let result = lines.last ?? ""
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func findNpmPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""

        if let pathInEnv = executableInPath(named: "npm", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            "/opt/homebrew/bin/npm",
            "/usr/local/bin/npm",
            home + "/.nvm/current/bin/npm",
            home + "/.volta/bin/npm",
            home + "/.local/share/fnm/aliases/default/bin/npm",
            home + "/.bun/bin/npm"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        return resolveViaShell("npm")
    }

    private static func findColiPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? ""

        // Check current environment PATH first
        if let pathInEnv = executableInPath(named: "coli", path: env["PATH"]) {
            return pathInEnv
        }

        let candidates = [
            home + "/.local/bin/coli",
            "/opt/homebrew/bin/coli",
            "/usr/local/bin/coli",
            home + "/.npm-global/bin/coli",
            home + "/.bun/bin/coli",
            home + "/.volta/bin/coli",
            home + "/.nvm/current/bin/coli",
            "/opt/homebrew/opt/node/bin/coli"
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // Check fnm/nvm managed Node installs
        let managedRoots: [(root: String, rel: String)] = [
            (home + "/.local/share/fnm/node-versions", "installation/bin/coli"),
            (home + "/.nvm/versions/node", "bin/coli")
        ]
        for managed in managedRoots {
            if let path = newestManagedBinary(under: managed.root, relativePath: managed.rel) {
                return path
            }
        }

        // Use npm to find global bin directory (works even when coli is in a custom prefix)
        if let npmGlobalBin = resolveNpmGlobalBin(), !npmGlobalBin.isEmpty {
            let coliViaNpm = npmGlobalBin + "/coli"
            if FileManager.default.isExecutableFile(atPath: coliViaNpm) {
                return coliViaNpm
            }
        }

        // GUI apps don't inherit terminal PATH, so spawn a login shell to resolve coli
        return resolveViaShell("coli")
    }

    private static func executableInPath(named name: String, path: String?) -> String? {
        guard let path else { return nil }
        for dir in path.split(separator: ":") {
            let full = String(dir) + "/\(name)"
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    private static func newestManagedBinary(under rootPath: String, relativePath: String) -> String? {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let sorted = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d1 != d2 ? d1 > d2 : $0.lastPathComponent > $1.lastPathComponent
            }

        for dir in sorted {
            let path = dir.path + "/" + relativePath
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func resolveViaShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Use -i (interactive) so nvm/fnm/volta init scripts in .zshrc are loaded
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let path, !path.isEmpty,
                  FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        } catch {
            return nil
        }
    }

    /// Resolve the npm global bin directory by asking npm itself via a login shell.
    private static func resolveNpmGlobalBin() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "npm bin -g 2>/dev/null || npm prefix -g 2>/dev/null"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // npm bin -g returns the bin path directly
            // npm prefix -g returns the prefix, bin is prefix/bin
            if output.hasSuffix("/bin") {
                return output
            } else if !output.isEmpty {
                return output + "/bin"
            }
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - Hotkey Monitor (short-press Control only)

@MainActor
final class HotkeyMonitor {
    private let onToggle: () -> Void
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var controlDownAt: Date?
    private var otherKeyPressed = false

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    func start() {
        // Track key presses while Control is held (both global and local)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.otherKeyPressed = true
            return event
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
            return event
        }
    }

    private func handle(event: NSEvent) {
        let controlPressed = event.modifierFlags.contains(.control)
        // If any other modifier is also held, it's a combo — ignore
        let otherModifiers: NSEvent.ModifierFlags = [.shift, .option, .command, .function]
        let hasOtherModifier = !event.modifierFlags.intersection(otherModifiers).isEmpty

        if controlPressed && !hasOtherModifier {
            // Pure Control just went down
            if controlDownAt == nil {
                controlDownAt = Date()
                otherKeyPressed = false
            }
        } else {
            // Control released or another modifier involved
            if let downAt = controlDownAt {
                let elapsed = Date().timeIntervalSince(downAt)
                if elapsed < 0.3 && !otherKeyPressed && !hasOtherModifier {
                    onToggle()
                }
            }
            controlDownAt = nil
            otherKeyPressed = false
        }
    }
}

// MARK: - Status Item

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellable: AnyCancellable?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        configureMenu()
        configureDragDrop()
        updateTitle(for: appState.phase)
        cancellable = appState.$phase.sink { [weak self] phase in
            self?.updateTitle(for: phase)
            self?.updateRecordMenuItem(for: phase)
        }
    }

    private func configureDragDrop() {
        guard let button = statusItem.button else { return }
        button.window?.registerForDraggedTypes([.fileURL])
        button.window?.delegate = self
    }

    private func configureMenu() {
        let menu = NSMenu()

        let recordItem = NSMenuItem(title: "Record  ⌃", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.tag = 100
        menu.addItem(recordItem)

        let transcribeItem = NSMenuItem(title: "Transcribe File...", action: #selector(transcribeFile), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.tag = 200
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem(title: "Open Privacy Settings", action: #selector(openPrivacySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit TypeNo", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func updateRecordMenuItem(for phase: AppPhase) {
        guard let item = statusItem.menu?.item(withTag: 100) else { return }
        switch phase {
        case .recording:
            item.title = "Stop Recording"
        default:
            item.title = "Record"
        }
    }

    private func updateTitle(for phase: AppPhase) {
        statusItem.button?.title = switch phase {
        case .idle: "⌃"
        case .downloadingModel: "⇣"
        case .recording: "Rec"
        case .transcribing: "·"
        case .done: "✓"
        case .updating: "↓"
        case .permissions, .missingColi, .installingColi: "!"
        case .error: "!"
        }
    }

    @objc private func openPrivacySettings() {
        PermissionManager.openPrivacySettings(for: [])
    }

    @objc private func toggleRecording() {
        appState?.onToggleRequest?()
    }

    @objc private func checkForUpdates() {
        appState?.onUpdateRequest?()
    }

    func setUpdateAvailable(_ version: String) {
        guard let item = statusItem.menu?.item(withTag: 200) else { return }
        item.title = "Update Available (v\(version))"
    }

    @objc private func transcribeFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "m4a")!,
            .init(filenameExtension: "mp3")!,
            .init(filenameExtension: "wav")!,
            .init(filenameExtension: "aac")!
        ]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to transcribe"

        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await appState?.transcribeFile(url)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSWindowDelegate {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first,
              ["m4a", "mp3", "wav", "aac"].contains(url.pathExtension.lowercased()) else {
            return []
        }
        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              let url = items.first else {
            return false
        }

        Task { @MainActor in
            await appState?.transcribeFile(url)
        }
        return true
    }
}

// MARK: - Overlay Panel

@MainActor
final class OverlayPanelController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<OverlayView>
    private let appState: AppState
    private var phaseCancellable: AnyCancellable?

    init(appState: AppState) {
        self.appState = appState
        let overlayView = OverlayView(appState: appState)
        hostingView = NSHostingView(rootView: overlayView)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView

        // Single source of truth: phase drives show/hide/layout
        // One async hop to let SwiftUI render before measuring
        phaseCancellable = appState.$phase.sink { [weak self] phase in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .idle = phase {
                    self.hide()
                } else {
                    self.updateLayout()
                    self.panel.orderFrontRegardless()
                }
            }
        }
    }

    func show() {
        updateLayout()
        panel.orderFrontRegardless()
    }

    private func updateLayout() {
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        let idealSize = hostingView.fittingSize
        let width = idealSize.width
        let height = idealSize.height

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x: CGFloat
            let y: CGFloat

            if case .permissions = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if case .missingColi = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if case .installingColi = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else {
                x = frame.midX - width / 2
                y = frame.minY + 48
            }

            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        } else {
            panel.setContentSize(NSSize(width: width, height: height))
        }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

// MARK: - Overlay View

struct OverlayView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Group {
            switch appState.phase {
            case .permissions(let missing):
                permissionView(missing: missing)
            case .missingColi:
                missingColiView
            case .installingColi(let message):
                installingColiView(message: message)
            case .idle:
                EmptyView()
            default:
                compactView
            }
        }
        .fixedSize()
    }

    private let barHeight: CGFloat = 32

    private func raisedCircleButton(_ icon: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                Circle()
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(primary ? .primary : .secondary)
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }

    var compactView: some View {
        Group {
            if case .recording = appState.phase {
                HStack(spacing: 8) {
                    raisedCircleButton("xmark") { appState.onCancel?() }
                    spectrumView
                    raisedCircleButton("checkmark", primary: true) { appState.onToggleRequest?() }
                }
            } else if case .downloadingModel(let progress, let text) = appState.phase {
                HStack(spacing: 8) {
                    // Circular progress ring like App Store
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.15), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: progress)
                    }
                    .frame(width: 18, height: 18)

                    Text(Self.formatDownloadText(text))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(width: 120, alignment: .leading)

                    raisedCircleButton("xmark") { appState.onCancel?() }
                }
            } else if case .transcribing(let message) = appState.phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.system(size: 12)).foregroundStyle(.primary)
                }
            } else if case .done(let text) = appState.phase {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(text).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(2)
                }
            } else if case .error(let message) = appState.phase {
                HStack(spacing: 8) {
                    Text(message).font(.system(size: 12)).foregroundStyle(.primary)
                    raisedCircleButton("xmark") { appState.onCancel?() }
                }
            } else if case .updating(let message) = appState.phase {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.system(size: 12)).foregroundStyle(.primary)
                }
            }
        }
        .frame(height: barHeight)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    /// Format raw coli output for display — extract "42.5 / 155.5 MB" from progress lines
    static func formatDownloadText(_ raw: String) -> String {
        // "  42.5 MB / 155.5 MB (27.3%)" → "42.5 / 155.5 MB"
        if raw.contains("MB") && raw.contains("%") {
            let beforePct = raw.components(separatedBy: "(")[0].trimmingCharacters(in: .whitespaces)
            return beforePct
                .replacingOccurrences(of: " MB / ", with: " / ")
                .replacingOccurrences(of: " MB", with: "") + " MB"
        }
        // Strip trailing dots for display only
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    var spectrumView: some View {
        let raw = appState.recorder.spectrumData
        let displayCount = 14
        let source = Array(raw.prefix(displayCount))
        var bars = [Float](repeating: 0, count: displayCount)
        let mid = displayCount / 2
        for i in 0..<source.count {
            if i % 2 == 0 {
                bars[mid + i / 2] = source[i]
            } else {
                bars[mid - 1 - i / 2] = source[i]
            }
        }

        return HStack(spacing: 1.5) {
            ForEach(0..<bars.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 2.5, height: max(2, CGFloat(bars[index]) * 18))
            }
        }
        .frame(height: 20)
        .animation(.easeOut(duration: 0.08), value: raw)
    }

    func permissionView(missing: Set<PermissionKind>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(missing.sorted { $0.title < $1.title }), id: \.self) { kind in
                HStack(spacing: 12) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(kind.explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Open Settings") {
                        appState.onPermissionOpen?(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack {
                Text("Checking automatically")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    var missingColiView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Node.js Required")
                        .font(.system(size: 13, weight: .medium))
                    Text("Install Node.js first, then TypeNo will set up automatically.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Text("https://nodejs.org")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)

                Button(action: {
                    if let url = URL(string: "https://nodejs.org") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Open nodejs.org")
            }

            HStack {
                Text("Checking automatically")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    func installingColiView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Setting up speech engine")
                        .font(.system(size: 13, weight: .medium))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(width: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Update Service

final class UpdateService: @unchecked Sendable {
    static let repoOwner = "marswaveai"
    static let repoName = "TypeNo"
    static let assetName = "TypeNo.app.zip"

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL
    }

    func checkForUpdate() async -> ReleaseInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                return nil
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            guard Self.isNewer(remote: remoteVersion, current: currentVersion) else {
                return nil
            }

            guard let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
                  let downloadURLString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                return nil
            }

            return ReleaseInfo(version: remoteVersion, downloadURL: downloadURL)
        } catch {
            return nil
        }
    }

    func downloadAndInstall(from downloadURL: URL, onProgress: @MainActor @Sendable (String) -> Void) async throws {
        await onProgress("Downloading update")

        // Download zip to temp
        let (zipURL, _) = try await URLSession.shared.download(from: downloadURL)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipDest = tempDir.appendingPathComponent(Self.assetName)
        if FileManager.default.fileExists(atPath: zipDest.path) {
            try FileManager.default.removeItem(at: zipDest)
        }
        try FileManager.default.moveItem(at: zipURL, to: zipDest)

        await onProgress("Installing update")

        // Unzip
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", zipDest.path, "-d", tempDir.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()

        guard unzip.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        let newAppURL = tempDir.appendingPathComponent("TypeNo.app")
        guard FileManager.default.fileExists(atPath: newAppURL.path) else {
            throw UpdateError.appNotFound
        }

        // Remove quarantine
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-rd", "com.apple.quarantine", newAppURL.path]
        xattr.standardOutput = FileHandle.nullDevice
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()

        // Replace current app
        let currentAppURL = Bundle.main.bundleURL
        let appParent = currentAppURL.deletingLastPathComponent()
        let backupURL = appParent.appendingPathComponent("TypeNo.app.bak")

        // Remove old backup if exists
        if FileManager.default.fileExists(atPath: backupURL.path) {
            try FileManager.default.removeItem(at: backupURL)
        }

        // Move current → backup
        try FileManager.default.moveItem(at: currentAppURL, to: backupURL)

        // Move new → current
        do {
            try FileManager.default.moveItem(at: newAppURL, to: currentAppURL)
        } catch {
            // Rollback if move fails
            try? FileManager.default.moveItem(at: backupURL, to: currentAppURL)
            throw UpdateError.replaceFailed
        }

        // Clean up backup and temp
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: tempDir)

        await onProgress("Restarting")

        // Relaunch
        let appPath = currentAppURL.path
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 1 && open \"\(appPath)\""]
        try script.run()

        await MainActor.run {
            NSApp.terminate(nil)
        }
    }

    private static func isNewer(remote: String, current: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let c = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, c.count) {
            let rv = i < r.count ? r[i] : 0
            let cv = i < c.count ? c[i] : 0
            if rv > cv { return true }
            if rv < cv { return false }
        }
        return false
    }
}

enum UpdateError: LocalizedError {
    case unzipFailed
    case appNotFound
    case replaceFailed

    var errorDescription: String? {
        switch self {
        case .unzipFailed: "Failed to unzip update"
        case .appNotFound: "Update package is invalid"
        case .replaceFailed: "Failed to replace app"
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
