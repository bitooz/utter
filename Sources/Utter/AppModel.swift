import AppKit
import AVFoundation
import SwiftUI
import UtterCore

/// Everything the onboarding and Settings windows show and change. Every change is saved and applied at once.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    var controller: Controller!

    // MARK: OpenRouter key

    enum KeyStatus: Equatable { case none, checking, ok(String), bad(String) }

    /// What is in the key field (the saved key to begin with).
    @Published var keyField = ""
    @Published private(set) var savedKey: String?
    @Published private(set) var keyStatus = KeyStatus.none
    private var checkTask: Task<Void, Never>?

    var keyWorks: Bool { if case .ok = keyStatus { return true }; return false }
    var keyIsSaved: Bool { savedKey != nil && savedKey == keyField.trimmingCharacters(in: .whitespacesAndNewlines) }

    func loadKey() {
        savedKey = try? KeyStore.openRouterKey()
        if let savedKey, keyField.isEmpty { keyField = savedKey }
    }

    /// Checks the key in the field with OpenRouter (after a short pause while typing).
    func checkKey(after delay: TimeInterval = 0) {
        checkTask?.cancel()
        let key = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { keyStatus = .none; return }
        guard KeyStore.looksValid(key) else { keyStatus = .bad("That doesn't look like an OpenRouter key. They start with sk-or-."); return }
        keyStatus = .checking
        checkTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            guard !Task.isCancelled else { return }
            do {
                let info = try await OpenRouter.check(key: key)
                guard !Task.isCancelled else { return }
                var s = "Key works"
                if let r = info.remaining { s += String(format: " · $%.2f credit left on it", r) }
                keyStatus = .ok(s)
            } catch {
                guard !Task.isCancelled else { return }
                keyStatus = .bad("\(error)")
            }
        }
    }

    /// Saves the checked key to Keychain and starts using it. Returns an error message, or nil.
    @discardableResult
    func saveKey() -> String? {
        let key = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == savedKey { return nil }
        do {
            try KeyStore.save(key)
            savedKey = key
            controller.setKey(key)
            Log.shared("key: saved a new OpenRouter key")
            NotificationCenter.default.post(name: .utterSettingsChanged, object: nil)
            return nil
        } catch {
            return "\(error)"
        }
    }

    // MARK: Permissions (polled while a window is open)

    @Published private(set) var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var tapRunning = false
    private var pollTimer: Timer?
    private var windowsOpen = 0

    func windowOpened() {
        windowsOpen += 1
        refreshPermissions()
        guard pollTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func windowClosed() {
        windowsOpen = max(0, windowsOpen - 1)
        if windowsOpen == 0 { pollTimer?.invalidate(); pollTimer = nil }
    }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != micStatus { micStatus = mic }
        refreshFn()
        let ax = AXIsProcessTrusted()
        if ax != axTrusted { axTrusted = ax }
        let tap = (controller?.tap.isRunning ?? false) || (assumeTapRunning && ax)
        if tap != tapRunning { tapRunning = tap }
    }

    var onRequestMic: () -> Void = {}

    func allowMicrophone() {
        if micStatus == .notDetermined {
            NSApp.activate(ignoringOtherApps: true)
            onRequestMic()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openInputMonitoring() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // MARK: Hotkeys

    @Published private(set) var modeHotkeys: [Mode: Hotkey] = Dictionary(uniqueKeysWithValues: Mode.allCases.compactMap { m in
        Settings.modeHotkey(m).map { (m, $0) }
    })

    func setModeHotkey(_ h: Hotkey?, for mode: Mode) {
        modeHotkeys[mode] = h
        Settings.setModeHotkey(h, for: mode)
        hotkeysChanged()
    }

    /// Either-side and one-side hotkeys on the same modifier: not a clash, but worth saying what each key does.
    var hotkeyNotes: [String] { Hotkey.sideNotes(Settings.namedHotkeys) }

    var clashes: [String] {
        var out = Hotkey.clashes(Settings.namedHotkeys)
        for (_, h) in Settings.namedHotkeys { if let c = h?.systemConflict, !out.contains(c) { out.append(c) } }
        return out
    }

    /// No mode has a key, so nothing can start a dictation.
    var noKeys: Bool { modeHotkeys.isEmpty }

    /// The key to name in hints: Auto's, or the first mode that has one.
    var hintKey: (mode: Mode, key: Hotkey)? {
        Mode.allCases.lazy.compactMap { m in self.modeHotkeys[m].map { (m, $0) } }.first
    }


    /// The fn key's macOS action is "Do Nothing", so fn reaches Utter alone.
    @Published private(set) var fnFree = FnKey.isFree
    @Published private(set) var fnAction = FnKey.action

    func freeFnKey() {
        FnKey.setDoNothing()
        refreshFn()
        Log.shared("fn key: set its macOS action to Do Nothing (\(fnFree ? "ok" : "didn't stick"))")
    }

    func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    func refreshFn() {
        let a = FnKey.action
        if a != fnAction { fnAction = a }
        if FnKey.isFree != fnFree { fnFree = FnKey.isFree }
    }

    var usesFn: Bool { Settings.namedHotkeys.contains { $0.hotkey?.modifierKey == .fn } }

    private func hotkeysChanged() {
        controller.applyHotkeys()
        NotificationCenter.default.post(name: .utterSettingsChanged, object: nil)
    }

    // MARK: Mode and models

    @Published private(set) var models = Settings.models
    @Published var autoAfter = Settings.autoAccurateAfter { didSet { Settings.autoAccurateAfter = autoAfter } }
    @Published private(set) var audioModels: [OpenRouter.ModelInfo] = OpenRouter.cachedAudioModels()
    @Published private(set) var modelListError: String?

    func setModel(_ id: String, for tier: Tier) {
        let m = Model(id)
        Settings.setModel(m.id.isEmpty ? nil : m, for: tier)
        models = Settings.models
        NotificationCenter.default.post(name: .utterSettingsChanged, object: nil)
    }

    func refreshModelList() {
        Task {
            do {
                audioModels = try await OpenRouter.audioModels()
                modelListError = nil
                models = Settings.models // names may have arrived
            } catch {
                if audioModels.isEmpty { modelListError = "Couldn't load OpenRouter's model list: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: Prompt and vocabulary

    @Published var systemPrompt = Settings.systemPrompt { didSet { Settings.systemPrompt = systemPrompt } }
    var promptIsDefault: Bool { systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) == Transcriber.defaultSystemPrompt }
    func resetPrompt() { systemPrompt = Transcriber.defaultSystemPrompt }

    @Published var vocabularyText = Vocabulary.text { didSet { Vocabulary.text = vocabularyText } }

    /// The system message a short dictation would send now: the prompt, then the vocabulary (Settings › Prompt preview).
    var promptPreview: String {
        let t = previewTranscriber
        t.systemPrompt = systemPrompt
        t.vocabulary = Vocabulary.parse(vocabularyText)
        return t.systemPrompt(context: nil, overlaps: false)
    }
    private lazy var previewTranscriber = Transcriber(key: "")

    /// Which mode's model picker is open (Settings › Modes), and the Prompt page's view (0 edit, 1 preview).
    @Published var pickerTier: Tier?
    @Published var promptTab = 0

    // MARK: Windows

    @Published var settingsPage = SettingsPage.general
    @Published var onboardingStep = OnboardingView.Step.welcome
    /// Set by `--capture-ui`, which runs beside the real app: the hotkey is the other process's, so trust Accessibility alone.
    var assumeTapRunning = false

    // MARK: Dictation state (for the test step)

    @Published private(set) var lastOutcome: Controller.Outcome?
    @Published private(set) var recording = false
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: .utterOutcome, object: nil, queue: .main) { [weak self] n in
            let o = n.object as? Controller.Outcome
            Task { @MainActor in self?.lastOutcome = o }
        })
    }

    /// The test step shows only dictations made while it is open.
    func clearLastOutcome() { lastOutcome = nil }

    func controllerChanged() {
        let r = controller.isRecording
        if r != recording { recording = r }
    }

    /// Re-reads everything (another window may have changed it).
    func reload() {
        loadKey()
        let keys = Dictionary(uniqueKeysWithValues: Mode.allCases.compactMap { m in Settings.modeHotkey(m).map { (m, $0) } })
        if keys != modeHotkeys { modeHotkeys = keys }
        models = Settings.models
        if systemPrompt != Settings.systemPrompt { systemPrompt = Settings.systemPrompt }
        let vocab = Vocabulary.text
        if vocabularyText != vocab { vocabularyText = vocab }
    }
}

extension Notification.Name {
    /// Something the menu shows changed (mode, hotkeys, models, key).
    static let utterSettingsChanged = Notification.Name("UtterSettingsChanged")
}
