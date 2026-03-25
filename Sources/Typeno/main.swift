import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Localization Helper

/// Returns `zh` when the system's first preferred language is Chinese, otherwise `en`.
func L(_ en: String, _ zh: String) -> String {
    Locale.preferredLanguages.first.map { $0.hasPrefix("zh") } == true ? zh : en
}

// MARK: - Hotkey Configuration

enum HotkeyModifier: String, Codable, CaseIterable {
    case leftControl  = "LeftControl"
    case rightControl = "RightControl"
    case leftOption   = "LeftOption"
    case rightOption  = "RightOption"
    case leftCommand  = "LeftCommand"
    case rightCommand = "RightCommand"
    case leftShift    = "LeftShift"
    case rightShift   = "RightShift"

    var symbol: String {
        switch self {
        case .leftControl,  .rightControl: "⌃"
        case .leftOption,   .rightOption:  "⌥"
        case .leftCommand,  .rightCommand: "⌘"
        case .leftShift,    .rightShift:   "⇧"
        }
    }

    var label: String {
        switch self {
        case .leftControl:  L("⌃ Left Control",  "⌃ 左 Control")
        case .rightControl: L("⌃ Right Control", "⌃ 右 Control")
        case .leftOption:   L("⌥ Left Option",   "⌥ 左 Option")
        case .rightOption:  L("⌥ Right Option",  "⌥ 右 Option")
        case .leftCommand:  L("⌘ Left Command",  "⌘ 左 Command")
        case .rightCommand: L("⌘ Right Command", "⌘ 右 Command")
        case .leftShift:    L("⇧ Left Shift",    "⇧ 左 Shift")
        case .rightShift:   L("⇧ Right Shift",   "⇧ 右 Shift")
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .leftControl,  .rightControl: .control
        case .leftOption,   .rightOption:  .option
        case .leftCommand,  .rightCommand: .command
        case .leftShift,    .rightShift:   .shift
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .leftControl:  59
        case .rightControl: 62
        case .leftOption:   58
        case .rightOption:  61
        case .leftCommand:  55
        case .rightCommand: 54
        case .leftShift:    56
        case .rightShift:   60
        }
    }
}

enum TriggerMode: String, Codable, CaseIterable {
    case singleTap = "SingleTap"
    case doubleTap = "DoubleTap"

    var label: String {
        switch self {
        case .singleTap: L("1× Single Tap", "1× 单击")
        case .doubleTap: L("2× Double Tap", "2× 双击")
        }
    }
}

extension UserDefaults {
    private static let modifierKey   = "ai.marswave.typeno.hotkeyModifier"
    private static let triggerKey    = "ai.marswave.typeno.triggerMode"

    var hotkeyModifier: HotkeyModifier {
        get {
            guard let raw = string(forKey: Self.modifierKey),
                  let v = HotkeyModifier(rawValue: raw) else { return .leftControl }
            return v
        }
        set { set(newValue.rawValue, forKey: Self.modifierKey) }
    }

    var triggerMode: TriggerMode {
        get {
            guard let raw = string(forKey: Self.triggerKey),
                  let v = TriggerMode(rawValue: raw) else { return .singleTap }
            return v
        }
        set { set(newValue.rawValue, forKey: Self.triggerKey) }
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Notification.Name {
    static let hotkeyConfigChanged = Notification.Name("ai.marswave.typeno.hotkeyConfigChanged")
}


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
        hotkeyMonitor = HotkeyMonitor(
            modifier: UserDefaults.standard.hotkeyModifier,
            triggerMode: UserDefaults.standard.triggerMode,
            onToggle: { [weak self] in self?.handleToggle() }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restartHotkeyMonitor),
            name: .hotkeyConfigChanged,
            object: nil
        )

        appState.onToggleRequest = { [weak self] in
            self?.handleToggle()
        }

        appState.onOverlayRequest = { [weak self] visible in
            if visible {
                self?.overlayController?.show()
            } else {
                self?.overlayController?.hide()
            }
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
        case .permissions, .missingColi, .installingColi, .updating:
            break
        }
    }

    @objc private func restartHotkeyMonitor() {
        hotkeyMonitor?.stop()
        hotkeyMonitor = HotkeyMonitor(
            modifier: UserDefaults.standard.hotkeyModifier,
            triggerMode: UserDefaults.standard.triggerMode,
            onToggle: { [weak self] in self?.handleToggle() }
        )
        hotkeyMonitor?.start()
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

        // Check model before recording
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
        Task { @MainActor in
            do {
                try await appState.stopRecording()
                await appState.transcribeAndInsert()
            } catch is CancellationError {
                // User canceled; keep app in reset state
            } catch {
                appState.showError(error.localizedDescription)
            }
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
            appState.phase = .updating(L("Checking for updates...", "检查更新..."))
            appState.onOverlayRequest?(true)

            switch await updateService.checkForUpdateDetailed() {
            case .upToDate:
                appState.phase = .updating(L("Already up to date", "已是最新版本"))
                try? await Task.sleep(for: .seconds(2))
                appState.phase = .idle
                appState.onOverlayRequest?(false)

            case .rateLimited:
                appState.showError(L("GitHub rate limit — try again later", "GitHub 请求限制，请稍后重试"))

            case .failed:
                appState.showError(L("Could not check for updates", "无法检查更新"))

            case .updateAvailable(let release):
                appState.phase = .updating(L("v\(release.version) available", "v\(release.version) 可更新"))
                appState.onOverlayRequest?(true)
                try? await Task.sleep(for: .seconds(1.5))
                appState.phase = .idle
                appState.onOverlayRequest?(false)
                NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateService.repoOwner)/\(UpdateService.repoName)/releases/latest")!)
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
        case .microphone: L("Microphone", "麦克风")
        case .accessibility: L("Accessibility", "辅助功能")
        }
    }

    var explanation: String {
        switch self {
        case .microphone: L("Required to capture your voice", "用于捕获语音")
        case .accessibility: L("Required to type text into apps", "用于向应用输入文字")
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
    case recording
    case transcribing(String = "Transcribing...")
    case done(String)        // transcription result, waiting for user confirm
    case permissions(Set<PermissionKind>)
    case missingColi
    case installingColi(String) // progress message
    case updating(String)    // progress message
    case error(String)

    var subtitle: String {
        switch self {
        case .idle: L("Press Fn to start", "按 Fn 开始")
        case .recording: L("Listening...", "录音中...")
        case .transcribing(let message):
            message == "Transcribing..." ? L("Transcribing...", "转录中...") : message
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

    var onOverlayRequest: ((Bool) -> Void)?
    var onPermissionOpen: ((PermissionKind) -> Void)?
    var onColiInstallHelpRequest: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onToggleRequest: (() -> Void)?
    var onUpdateRequest: (() -> Void)?

    private let recorder = AudioRecorder()
    private let asrService = ColiASRService()
    private var currentRecordingURL: URL?
    private var previousApp: NSRunningApplication?
    private var recordingTimer: Timer?
    private var cancelled = false
    private var activeProgressTimer: Timer?
    @Published var recordingElapsedSeconds: Int = 0

    var recordingElapsedStr: String {
        let m = recordingElapsedSeconds / 60
        let s = recordingElapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Download model with progress shown in existing transcribing overlay
    func downloadModelThenRecord() async {
        cancelled = false
        phase = .transcribing(L("Checking model...", "检测模型中..."))
        onOverlayRequest?(true)

        do {
            _ = try await asrService.transcribe(fileURL: Self.ensureSilentWAV()) { [weak self] message in
                self?.phase = .transcribing(message)
            }
        } catch {
            guard !cancelled else { return }
            showError(L("Model download failed", "模型下载失败"))
            return
        }

        // Model ready, start recording
        guard !cancelled else { return }
        do {
            try startRecording()
        } catch {
            showError(L("Recording failed", "录音失败"))
        }
    }

    /// Create or return path to a tiny silent WAV for triggering model download
    static func ensureSilentWAV() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coli-init.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            var header = Data()
            let dataSize: UInt32 = 3200
            let fileSize: UInt32 = 36 + dataSize
            header.append(contentsOf: "RIFF".utf8)
            header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
            header.append(contentsOf: "WAVE".utf8)
            header.append(contentsOf: "fmt ".utf8)
            header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt32(16000).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt32(32000).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
            header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
            header.append(contentsOf: "data".utf8)
            header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
            header.append(Data(count: Int(dataSize)))
            try? header.write(to: url)
        }
        return url
    }

    func startRecording() throws {
        cancelled = false
        transcript = ""
        previousApp = NSWorkspace.shared.frontmostApplication
        currentRecordingURL = try recorder.start()
        recordingElapsedSeconds = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recordingElapsedSeconds += 1 }
        }
        phase = .recording
        onOverlayRequest?(true)
    }

    func stopRecording() async throws {
        recordingTimer?.invalidate()
        recordingTimer = nil
        phase = .transcribing()
        onOverlayRequest?(true)

        let url = try await recorder.stop()
        currentRecordingURL = url
    }

    func cancel() {
        cancelled = true
        recordingTimer?.invalidate()
        recordingTimer = nil
        activeProgressTimer?.invalidate()
        activeProgressTimer = nil
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

    func showPermissions(_ missing: Set<PermissionKind>) {
        phase = .permissions(missing)
        onOverlayRequest?(true)
    }

    func hidePermissions() {
        phase = .idle
        onOverlayRequest?(false)
    }

    func showMissingColi() {
        // If npm is available, auto-install coli instead of showing manual guidance
        if ColiASRService.isNpmAvailable {
            autoInstallColi()
        } else {
            phase = .missingColi
            onOverlayRequest?(true)
        }
    }

    func autoInstallColi() {
        phase = .installingColi(L("Installing coli...", "安装中..."))
        onOverlayRequest?(true)

        Task {
            do {
                try await ColiASRService.installColi { [weak self] message in
                    self?.phase = .installingColi(message)
                }
                // Verify installation
                if ColiASRService.isInstalled {
                    phase = .idle
                    onOverlayRequest?(false)
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
            onOverlayRequest?(false)
        }
    }

    func showError(_ message: String) {
        phase = .error(message)
        onOverlayRequest?(true)
    }

    func transcribeAndInsert() async {
        guard !cancelled, let url = currentRecordingURL else {
            return
        }

        phase = .transcribing()

        let startTime = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                let elapsed = Int(Date().timeIntervalSince(startTime))
                if elapsed >= 120 {
                    self.phase = .transcribing(L("Long audio, please wait...", "长音频，请稍候..."))
                }
            }
        }
        activeProgressTimer = timer

        do {
            let text = try await asrService.transcribe(fileURL: url) { [weak self] message in
                self?.phase = .transcribing(message)
            }
            timer.invalidate()
            activeProgressTimer = nil
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            phase = .done(transcript)
            onOverlayRequest?(true)
            confirmInsert()
        } catch TypeNoError.coliNotInstalled {
            timer.invalidate()
            activeProgressTimer = nil
            showMissingColi()
        } catch {
            timer.invalidate()
            activeProgressTimer = nil
            guard !cancelled else { return }
            let msg = error.localizedDescription
            if msg.contains("protobuf") || msg.contains("Failed to load model") {
                // Preserve user's recording, re-download model, then retry
                ColiASRService.deleteModelDirectory()
                phase = .transcribing(L("Checking model...", "检测模型中..."))
                do {
                    _ = try await asrService.transcribe(fileURL: Self.ensureSilentWAV()) { [weak self] message in
                        self?.phase = .transcribing(message)
                    }
                    guard !cancelled else { return }
                    phase = .transcribing()
                    let retryText = try await asrService.transcribe(fileURL: url)
                    transcript = retryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !transcript.isEmpty {
                        phase = .done(transcript)
                        onOverlayRequest?(true)
                        confirmInsert()
                    } else {
                        showError(L("No speech detected", "未检测到语音"))
                    }
                } catch {
                    guard !cancelled else { return }
                    showError(L("Model download failed", "模型下载失败"))
                }
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
        onOverlayRequest?(false)

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
        onOverlayRequest?(false)
    }

    func transcribeFile(_ url: URL) async {
        cancelled = false
        previousApp = NSWorkspace.shared.frontmostApplication
        phase = .transcribing()
        onOverlayRequest?(true)

        let startTime = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }
                let elapsed = Int(Date().timeIntervalSince(startTime))
                if elapsed >= 120 {
                    self.phase = .transcribing(L("Long audio, please wait...", "长音频，请稍候..."))
                }
            }
        }
        activeProgressTimer = timer

        do {
            let text = try await asrService.transcribe(fileURL: url) { [weak self] message in
                self?.phase = .transcribing(message)
            }
            timer.invalidate()
            activeProgressTimer = nil
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            phase = .done(transcript)
            onOverlayRequest?(true)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(transcript, forType: .string)
            try? await Task.sleep(for: .seconds(2))
            cancel()
        } catch TypeNoError.coliNotInstalled {
            timer.invalidate()
            activeProgressTimer = nil
            showMissingColi()
        } catch {
            timer.invalidate()
            activeProgressTimer = nil
            guard !cancelled else { return }
            let msg = error.localizedDescription
            if msg.contains("protobuf") || msg.contains("Failed to load model") {
                ColiASRService.deleteModelDirectory()
                phase = .transcribing(L("Checking model...", "检测模型中..."))
                do {
                    _ = try await asrService.transcribe(fileURL: Self.ensureSilentWAV()) { [weak self] message in
                        self?.phase = .transcribing(message)
                    }
                    guard !cancelled else { return }
                    phase = .transcribing()
                    let retryText = try await asrService.transcribe(fileURL: url)
                    transcript = retryText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !transcript.isEmpty {
                        phase = .done(transcript)
                        onOverlayRequest?(true)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(transcript, forType: .string)
                        try? await Task.sleep(for: .seconds(2))
                        cancel()
                    } else {
                        showError(L("No speech detected", "未检测到语音"))
                    }
                } catch {
                    guard !cancelled else { return }
                    showError(L("Model download failed", "模型下载失败"))
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

// MARK: - Audio Recorder

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var stopContinuation: CheckedContinuation<URL, Error>?

    func start() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.record()

        self.recorder = recorder
        self.recordingURL = url
        return url
    }

    func stop() async throws -> URL {
        guard let recordingURL else {
            throw TypeNoError.noRecording
        }
        guard let recorder else {
            return recordingURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation
            recorder.stop()
            self.recorder = nil
        }
    }

    func cancel() {
        finishStop(with: .failure(CancellationError()))
        recorder?.stop()
        recorder = nil
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if flag, let recordingURL {
                finishStop(with: .success(recordingURL))
            } else {
                finishStop(with: .failure(TypeNoError.noRecording))
            }
            recordingURL = nil
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor in
            finishStop(with: .failure(error ?? TypeNoError.noRecording))
            recordingURL = nil
        }
    }

    private func finishStop(with result: Result<URL, Error>) {
        guard let stopContinuation else { return }
        self.stopContinuation = nil
        switch result {
        case .success(let url): stopContinuation.resume(returning: url)
        case .failure(let err): stopContinuation.resume(throwing: err)
        }
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

    /// Check if the ASR model directory has required files
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

    static var isNpmAvailable: Bool {
        findNpmPath() != nil
    }

    /// Auto-install coli via npm. Reports progress via callback.
    static func installColi(onProgress: @MainActor @Sendable @escaping (String) -> Void) async throws {
        guard let npmPath = findNpmPath() else {
            throw TypeNoError.npmNotFound
        }

        await onProgress("Installing coli...")

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

                    var env = ProcessInfo.processInfo.environment
                    let home = env["HOME"] ?? ""
                    let extraPaths = [
                        "/opt/homebrew/bin",
                        "/usr/local/bin",
                        home + "/.nvm/versions/node/",
                        home + "/.bun/bin",
                        home + "/.npm-global/bin",
                        "/opt/homebrew/opt/node/bin"
                    ]
                    let existingPath = env["PATH"] ?? "/usr/bin:/bin"
                    env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")

                    if env["HTTP_PROXY"] == nil && env["HTTPS_PROXY"] == nil && env["http_proxy"] == nil {
                        if let proxyURL = Self.systemHTTPSProxyURL() {
                            env["HTTPS_PROXY"] = proxyURL
                            env["HTTP_PROXY"] = proxyURL
                            env["https_proxy"] = proxyURL
                            env["http_proxy"] = proxyURL
                        }
                    }

                    process.environment = env

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    let stdoutBuf = LockedData()
                    let stderrBuf = LockedData()
                    let stdoutHandle = stdout.fileHandleForReading
                    let stderrHandle = stderr.fileHandleForReading

                    // Track last output activity for smart idle timeout
                    let lastActivity = AtomicTimestamp()
                    // Throttle progress updates to once per second
                    let lastProgressUpdate = AtomicTimestamp()

                    // Parse download progress from stdout (\r-separated lines)
                    @Sendable func forwardProgress(_ data: Data) {
                        guard let onProgress, let text = String(data: data, encoding: .utf8) else { return }
                        let line = text.components(separatedBy: "\r").last?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !line.isEmpty else { return }
                        guard line.contains("MB") || line.contains("Downloading") || line.contains("Extracting") || line.contains("ready") else { return }

                        guard lastProgressUpdate.elapsed() > 1.5 else { return }
                        lastProgressUpdate.update()

                        // "42.5 MB / 155.5 MB (27.3%)" → "42.5MB / 27%"
                        let display: String
                        if line.contains("MB") && line.contains("%") {
                            // Extract downloaded MB (first number before "MB")
                            let downloaded = line.trimmingCharacters(in: .whitespaces)
                                .components(separatedBy: " MB")[0]
                                .trimmingCharacters(in: .whitespaces)
                            // Extract percentage
                            if let pctRange = line.range(of: #"\d+\.?\d*%"#, options: .regularExpression) {
                                display = "\(downloaded)MB / \(line[pctRange])"
                            } else {
                                display = "\(downloaded)MB"
                            }
                        } else if line.contains("Extracting") {
                            display = L("Extracting...", "解压中...")
                        } else if line.contains("ready") {
                            display = L("Model ready", "模型就绪")
                        } else {
                            display = L("Downloading model...", "下载模型中...")
                        }
                        Task { @MainActor in onProgress(display) }
                    }

                    stdoutHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            stdoutBuf.append(data)
                            lastActivity.update()
                            forwardProgress(data)
                        }
                    }
                    stderrHandle.readabilityHandler = { handle in
                        let data = handle.availableData
                        if !data.isEmpty {
                            stderrBuf.append(data)
                            lastActivity.update()
                            forwardProgress(data)
                        }
                    }

                    self?.processLock.lock()
                    self?.currentProcess = process
                    self?.processLock.unlock()

                    try process.run()

                    // Smart idle timeout: kill if no output for 120s.
                    // While downloading (output active), wait indefinitely.
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

                    // Extract actual transcription from stdout (skip \r progress lines)
                    let realLines = output.components(separatedBy: "\n")
                        .map { $0.components(separatedBy: "\r").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                        .filter { !$0.isEmpty }
                    let result = realLines.last ?? ""
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Returns the macOS system HTTPS proxy as an "http://host:port" string, or nil if none is set.
    static func systemHTTPSProxyURL() -> String? {
        guard let proxySettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        // Check HTTPS proxy first, fall back to HTTP proxy
        if let httpsEnabled = proxySettings[kCFNetworkProxiesHTTPSEnable as String] as? Int, httpsEnabled == 1,
           let host = proxySettings[kCFNetworkProxiesHTTPSProxy as String] as? String,
           let port = proxySettings[kCFNetworkProxiesHTTPSPort as String] as? Int, !host.isEmpty {
            return "http://\(host):\(port)"
        }
        if let httpEnabled = proxySettings[kCFNetworkProxiesHTTPEnable as String] as? Int, httpEnabled == 1,
           let host = proxySettings[kCFNetworkProxiesHTTPProxy as String] as? String,
           let port = proxySettings[kCFNetworkProxiesHTTPPort as String] as? Int, !host.isEmpty {
            return "http://\(host):\(port)"
        }
        return nil
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

// MARK: - Hotkey Monitor

@MainActor
final class HotkeyMonitor {
    private let modifier: HotkeyModifier
    private let triggerMode: TriggerMode
    private let onToggle: () -> Void
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var localKeyMonitor: Any?
    private var keyDownAt: Date?
    private var firstTapAt: Date?
    private var otherKeyPressed = false

    init(modifier: HotkeyModifier = .leftControl, triggerMode: TriggerMode = .singleTap, onToggle: @escaping () -> Void) {
        self.modifier = modifier
        self.triggerMode = triggerMode
        self.onToggle = onToggle
    }

    func stop() {
        [flagsMonitor, keyMonitor, localFlagsMonitor, localKeyMonitor]
            .compactMap { $0 }
            .forEach { NSEvent.removeMonitor($0) }
        flagsMonitor = nil; keyMonitor = nil
        localFlagsMonitor = nil; localKeyMonitor = nil
    }

    func start() {
        // Track key presses while modifier is held (both global and local)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] _ in
            self?.otherKeyPressed = true
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.otherKeyPressed = true
            return event
        }

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event: event) }
            return event
        }
    }

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62]

    private func handle(event: NSEvent) {
        var others: NSEvent.ModifierFlags = [.shift, .option, .command, .control, .function]
        others.remove(modifier.flag)
        let hasOtherModifier = !event.modifierFlags.intersection(others).isEmpty

        if event.keyCode == modifier.keyCode {
            if keyDownAt == nil {
                // Key press — modifier flag becomes set
                if event.modifierFlags.contains(modifier.flag) && !hasOtherModifier {
                    keyDownAt = Date()
                    otherKeyPressed = false
                }
            } else if let downAt = keyDownAt {
                // Key release — modifier flag clears
                let elapsed = Date().timeIntervalSince(downAt)
                let isQuickRelease = elapsed < 0.3 && !otherKeyPressed && !hasOtherModifier
                if isQuickRelease {
                    switch triggerMode {
                    case .singleTap:
                        onToggle()
                    case .doubleTap:
                        if let firstTap = firstTapAt {
                            if Date().timeIntervalSince(firstTap) < 0.5 {
                                onToggle()
                                firstTapAt = nil
                            } else {
                                firstTapAt = Date()
                            }
                        } else {
                            firstTapAt = Date()
                        }
                    }
                }
                keyDownAt = nil
                otherKeyPressed = false
            }
        } else if keyDownAt != nil && Self.modifierKeyCodes.contains(event.keyCode) {
            // Another modifier pressed while ours is held — mark as chord, don't trigger
            otherKeyPressed = true
        }
    }
}

// MARK: - Status Item

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 28)
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

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let aboutItem = NSMenuItem(title: "TypeNo  v\(version)", action: nil, keyEquivalent: "")
        aboutItem.isEnabled = false
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let mod = UserDefaults.standard.hotkeyModifier
        let recordItem = NSMenuItem(title: L("Record  \(mod.symbol)", "录音  \(mod.symbol)"), action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        recordItem.tag = 100
        menu.addItem(recordItem)

        let transcribeItem = NSMenuItem(title: L("Transcribe File to Clipboard...", "转录文件到剪贴板..."), action: #selector(transcribeFile), keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

        menu.addItem(NSMenuItem.separator())

        // Hotkey sub-menu
        let hotkeyItem = NSMenuItem(title: L("Hotkey", "快捷键"), action: nil, keyEquivalent: "")
        let hotkeySub = NSMenu()
        for (i, m) in HotkeyModifier.allCases.enumerated() {
            let item = NSMenuItem(title: m.label, action: #selector(changeHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 300 + i
            item.state = m == mod ? .on : .off
            hotkeySub.addItem(item)
        }
        menu.setSubmenu(hotkeySub, for: hotkeyItem)
        menu.addItem(hotkeyItem)

        // Trigger Mode sub-menu
        let triggerItem = NSMenuItem(title: L("Trigger Mode", "触发方式"), action: nil, keyEquivalent: "")
        let triggerSub = NSMenu()
        let curTrigger = UserDefaults.standard.triggerMode
        for (i, t) in TriggerMode.allCases.enumerated() {
            let item = NSMenuItem(title: t.label, action: #selector(changeTriggerMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 400 + i
            item.state = t == curTrigger ? .on : .off
            triggerSub.addItem(item)
        }
        menu.setSubmenu(triggerSub, for: triggerItem)
        menu.addItem(triggerItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(title: L("Check for Updates...", "检查更新..."), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.tag = 200
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem(title: L("Open Privacy Settings", "打开隐私设置"), action: #selector(openPrivacySettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: L("Quit TypeNo", "退出 TypeNo"), action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func updateRecordMenuItem(for phase: AppPhase) {
        guard let item = statusItem.menu?.item(withTag: 100) else { return }
        let sym = UserDefaults.standard.hotkeyModifier.symbol
        switch phase {
        case .recording:
            item.title = L("Stop Recording", "停止录音")
        default:
            item.title = L("Record  \(sym)", "录音  \(sym)")
        }
    }

    private func makeSymbolImage(_ symbol: String) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size, flipped: false) { rect in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.black
            ]
            let str = symbol as NSString
            let strSize = str.size(withAttributes: attrs)
            let pt = NSPoint(
                x: (rect.width - strSize.width) / 2,
                y: (rect.height - strSize.height) / 2
            )
            str.draw(at: pt, withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    private func updateTitle(for phase: AppPhase) {
        guard let button = statusItem.button else { return }
        switch phase {
        case .idle:
            button.image = makeSymbolImage("◎")
            button.imagePosition = .imageOnly
            button.title = ""
        default:
            button.image = nil
            button.imagePosition = .noImage
            button.title = switch phase {
            case .recording: "Rec"
            case .transcribing: "..."
            case .done: "✓"
            case .updating: "↓"
            default: "!"
            }
        }
    }

    @objc private func changeHotkey(_ sender: NSMenuItem) {
        let idx = sender.tag - 300
        guard let mod = HotkeyModifier.allCases[safe: idx] else { return }
        UserDefaults.standard.hotkeyModifier = mod
        // Update checkmarks
        sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        // Refresh title + record item
        if let phase = appState?.phase {
            updateTitle(for: phase)
            updateRecordMenuItem(for: phase)
        }
        NotificationCenter.default.post(name: .hotkeyConfigChanged, object: nil)
    }

    @objc private func changeTriggerMode(_ sender: NSMenuItem) {
        let idx = sender.tag - 400
        guard let mode = TriggerMode.allCases[safe: idx] else { return }
        UserDefaults.standard.triggerMode = mode
        sender.menu?.items.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        NotificationCenter.default.post(name: .hotkeyConfigChanged, object: nil)
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
        item.title = L("Update Available (v\(version))", "有新版本 (v\(version))")
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
        panel.message = "Choose an audio file — result will be copied to clipboard"

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
    }

    func show() {
        hostingView.invalidateIntrinsicContentSize()
        let idealSize = hostingView.fittingSize
        let width = max(idealSize.width, 240)
        let height = max(idealSize.height, 44)

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let x: CGFloat
            let y: CGFloat

            if case .permissions = appState.phase {
                // Onboarding: top-right corner, below menu bar
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if case .missingColi = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else if case .installingColi = appState.phase {
                x = frame.maxX - width - 16
                y = frame.maxY - height - 16
            } else {
                // Recording/transcription bar: center bottom
                x = frame.midX - width / 2
                y = frame.minY + 48
            }

            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        } else {
            panel.setContentSize(NSSize(width: width, height: height))
        }
        panel.orderFrontRegardless()
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

    var compactView: some View {
        HStack(spacing: 10) {
            if case .recording = appState.phase {
                Circle()
                    .fill(Color.primary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }

            if case .transcribing = appState.phase {
                ProgressView()
                    .controlSize(.small)
            }

            if case .updating = appState.phase {
                ProgressView()
                    .controlSize(.small)
            }

            if case .done(let text) = appState.phase {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            } else if case .recording = appState.phase {
                let nearLimit = appState.recordingElapsedSeconds >= 105  // 1:45
                Text(nearLimit
                     ? L("⚠ \(appState.recordingElapsedStr)", "⚠ \(appState.recordingElapsedStr)")
                     : appState.recordingElapsedStr)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(nearLimit ? Color.orange : Color.primary)
            } else {
                Text(appState.phase.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }

            if case .error = appState.phase {
                Button(L("OK", "好")) {
                    appState.onCancel?()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
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

                    Button(L("Open Settings", "打开设置")) {
                        appState.onPermissionOpen?(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack {
                Text(L("Checking automatically...", "自动检测中..."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("Cancel", "取消")) {
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
                    Text(L("Node.js Required", "需要 Node.js"))
                        .font(.system(size: 13, weight: .medium))
                    Text(L("Install Node.js first, then TypeNo will set up automatically.", "请先安装 Node.js，TypeNo 将自动配置。"))
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
                Text(L("Checking automatically...", "自动检测中..."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L("Cancel", "取消")) {
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
                    Text(L("Setting up speech engine", "配置语音引擎"))
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

    enum CheckResult {
        case updateAvailable(ReleaseInfo)
        case upToDate
        case rateLimited
        case failed
    }

    func checkForUpdate() async -> ReleaseInfo? {
        switch await checkForUpdateDetailed() {
        case .updateAvailable(let info): return info
        default: return nil
        }
    }

    func checkForUpdateDetailed() async -> CheckResult {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases/latest") else {
            return .failed
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("TypeNo/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed
            }

            // GitHub rate limit error
            if json["message"] as? String != nil && json["tag_name"] == nil {
                return .rateLimited
            }

            guard let tagName = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                return .failed
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            guard Self.isNewer(remote: remoteVersion, current: currentVersion) else {
                return .upToDate
            }

            guard let asset = assets.first(where: { ($0["name"] as? String) == Self.assetName }),
                  let downloadURLString = asset["browser_download_url"] as? String,
                  let downloadURL = URL(string: downloadURLString) else {
                return .failed
            }

            return .updateAvailable(ReleaseInfo(version: remoteVersion, downloadURL: downloadURL))
        } catch {
            return .failed
        }
    }

    func downloadAndInstall(from downloadURL: URL, onProgress: @MainActor @Sendable (String) -> Void) async throws {
        await onProgress(L("Downloading update...", "下载更新..."))

        // Download zip to temp
        let (zipURL, _) = try await URLSession.shared.download(from: downloadURL)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipDest = tempDir.appendingPathComponent(Self.assetName)
        if FileManager.default.fileExists(atPath: zipDest.path) {
            try FileManager.default.removeItem(at: zipDest)
        }
        try FileManager.default.moveItem(at: zipURL, to: zipDest)

        await onProgress(L("Installing update...", "安装更新..."))

        // Use ditto --noqtn to unzip the app bundle — ditto is the macOS-native tool
        // for copying app bundles and --noqtn prevents quarantine from being propagated
        // to the extracted app (unlike /usr/bin/unzip which inherits quarantine).
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", "--noqtn", zipDest.path, tempDir.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()

        guard ditto.terminationStatus == 0 else {
            throw UpdateError.unzipFailed
        }

        let newAppURL = tempDir.appendingPathComponent("TypeNo.app")
        guard FileManager.default.fileExists(atPath: newAppURL.path) else {
            throw UpdateError.appNotFound
        }

        // Belt-and-suspenders: also remove quarantine recursively from the extracted app
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

        // Remove quarantine from the final location AFTER the move.
        // Some macOS versions re-add quarantine during FileManager.moveItem;
        // cleaning here ensures the relocated app is trusted when opened.
        let xattrFinal = Process()
        xattrFinal.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattrFinal.arguments = ["-cr", currentAppURL.path]   // -c clears all xattrs, -r recursive
        xattrFinal.standardOutput = FileHandle.nullDevice
        xattrFinal.standardError = FileHandle.nullDevice
        try? xattrFinal.run()
        xattrFinal.waitUntilExit()

        // Clean up backup and temp
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.removeItem(at: tempDir)

        await onProgress("Restarting...")

        // Relaunch: strip quarantine one final time right before open so
        // any attribute reapplied between here and the actual launch is cleared.
        let appPath = currentAppURL.path
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "sleep 1 && xattr -cr \"\(appPath)\" && open \"\(appPath)\""]
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
