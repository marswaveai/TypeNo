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
        case .permissions, .missingColi, .updating:
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
            appState.phase = .updating("Checking for updates...")
            appState.onOverlayRequest?(true)

            guard let release = await updateService.checkForUpdate() else {
                appState.phase = .idle
                appState.onOverlayRequest?(false)
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
    case recording
    case transcribing
    case done(String)        // transcription result, waiting for user confirm
    case permissions(Set<PermissionKind>)
    case missingColi
    case updating(String)    // progress message
    case error(String)

    var subtitle: String {
        switch self {
        case .idle: "Press Fn to start"
        case .recording: "Listening..."
        case .transcribing: "Transcribing..."
        case .done(let text): text
        case .permissions, .missingColi: ""
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

    func startRecording() throws {
        transcript = ""
        previousApp = NSWorkspace.shared.frontmostApplication
        currentRecordingURL = try recorder.start()
        phase = .recording
        onOverlayRequest?(true)
    }

    func stopRecording() async throws {
        phase = .transcribing
        onOverlayRequest?(true)

        let url = try await recorder.stop()
        currentRecordingURL = url
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
        phase = .missingColi
        onOverlayRequest?(true)
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
        guard let url = currentRecordingURL else {
            showError("No recording")
            return
        }

        phase = .transcribing

        do {
            let text = try await asrService.transcribe(fileURL: url)
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            // Show result briefly, then auto-insert
            phase = .done(transcript)
            onOverlayRequest?(true)
            confirmInsert()
        } catch TypeNoError.coliNotInstalled {
            showMissingColi()
        } catch {
            showError(error.localizedDescription)
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
        previousApp = NSWorkspace.shared.frontmostApplication
        phase = .transcribing
        onOverlayRequest?(true)

        do {
            let text = try await asrService.transcribe(fileURL: url)
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)

            guard transcript.isEmpty == false else {
                throw TypeNoError.emptyTranscript
            }

            phase = .done(transcript)
            onOverlayRequest?(true)
            confirmInsert()
        } catch TypeNoError.coliNotInstalled {
            showMissingColi()
        } catch {
            showError(error.localizedDescription)
        }
    }
}

// MARK: - Errors

enum TypeNoError: LocalizedError {
    case noRecording
    case emptyTranscript
    case coliNotInstalled
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecording: "No recording"
        case .emptyTranscript: "No speech detected"
        case .coliNotInstalled: "TypeNo needs the local Coli engine. Install it with: npm install -g @marswave/coli"
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

final class ColiASRService: @unchecked Sendable {
    static var isInstalled: Bool {
        findColiPath() != nil
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

    func transcribe(fileURL: URL) async throws -> String {
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

                    self?.processLock.lock()
                    self?.currentProcess = process
                    self?.processLock.unlock()

                    try process.run()

                    // 30-second timeout
                    let timeoutItem = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)

                    process.waitUntilExit()
                    timeoutItem.cancel()

                    self?.processLock.lock()
                    self?.currentProcess = nil
                    self?.processLock.unlock()

                    guard process.terminationReason != .uncaughtSignal else {
                        throw TypeNoError.transcriptionFailed("Transcription timed out")
                    }

                    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                    guard process.terminationStatus == 0 else {
                        let msg = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw TypeNoError.transcriptionFailed(msg.isEmpty ? "coli failed" : msg)
                    }

                    continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v \(command)"]

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
        case .recording: "Rec"
        case .transcribing: "..."
        case .done: "✓"
        case .updating: "↓"
        case .permissions, .missingColi: "!"
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
            } else {
                Text(appState.phase.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }

            if case .error = appState.phase {
                Button("OK") {
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

                    Button("Open Settings") {
                        appState.onPermissionOpen?(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            HStack {
                Text("Checking automatically...")
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
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Install Coli to continue")
                        .font(.system(size: 13, weight: .medium))
                    Text("TypeNo uses the local Coli speech engine.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open Guide") {
                    appState.onColiInstallHelpRequest?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text("npm install -g @marswave/coli")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 36)

                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("npm install -g @marswave/coli", forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }

            HStack {
                Text("Checking automatically...")
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
        await onProgress("Downloading update...")

        // Download zip to temp
        let (zipURL, _) = try await URLSession.shared.download(from: downloadURL)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TypeNo-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let zipDest = tempDir.appendingPathComponent(Self.assetName)
        if FileManager.default.fileExists(atPath: zipDest.path) {
            try FileManager.default.removeItem(at: zipDest)
        }
        try FileManager.default.moveItem(at: zipURL, to: zipDest)

        await onProgress("Installing update...")

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

        await onProgress("Restarting...")

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
