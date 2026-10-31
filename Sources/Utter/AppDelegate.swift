import AppKit
import AVFoundation
import UtterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let controller = Controller()
    private var statusItem: NSStatusItem!
    private var axTimer: Timer?
    private var warmTimer: Timer?
    private var selfTest: SelfTest?
    private let windows = Windows()
    private let model = AppModel.shared

    func applicationDidFinishLaunching(_ note: Notification) {
        let args = CommandLine.arguments
        model.controller = controller
        if let i = args.firstIndex(of: "--capture-ui"), i + 1 < args.count {
            // Runs beside the real app: no menu bar item, no hotkey, no dictation, just the two windows.
            NSApp.mainMenu = Self.mainMenu()
            if let key = try? KeyStore.openRouterKey() { controller.setKey(key) }
            let dir = args[i + 1]
            Task { @MainActor in
                await UICapture.run(windows, to: dir)
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--capture-hud"), i + 1 < args.count { // the pill, recorded off screen
            HUDCapture.run(to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--probe-delivery"), i + 1 < args.count { // where test sentences land, app by app
            let dir = args[i + 1]
            Task { @MainActor in
                await DeliveryProbe.run(to: dir)
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--make-icons"), i + 1 < args.count {
            Logo.writeFiles(to: args[i + 1])
            exit(0)
        }
        if args.contains("--print-menu") { // the menu bar menu as text (✓ marks the chosen mode)
            if let key = try? KeyStore.openRouterKey() { controller.setKey(key) }
            let menu = NSMenu()
            menuNeedsUpdate(menu)
            for i in menu.items {
                print(i.isSeparatorItem ? "────" : "\(i.state == .on ? "✓ " : "  ")\(i.title)\(i.keyEquivalent.isEmpty ? "" : "   ⌘\(i.keyEquivalent.uppercased())")")
            }
            exit(0)
        }
        if args.contains("--check-hotkeys") {
            let ok = HotkeyCheck.run()
            exit(ok ? 0 : 1)
        }
        if args.contains("--selftest") { selfTest = SelfTest(args: args, controller: controller) }
        Log.shared.scrubTranscripts()
        logSignals()
        // First launch: the setup window asks for each permission in turn, so don't ask at launch.
        let firstRun = !Settings.onboarded && selfTest == nil

        NSApp.mainMenu = Self.mainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        controller.onChange = { [weak self] in
            self?.updateIcon()
            self?.model.controllerChanged()
        }
        model.onRequestMic = { [weak self] in self?.requestMic() }
        startTapWhenTrusted(prompt: selfTest == nil && !firstRun)

        if let key = try? KeyStore.openRouterKey() {
            controller.setKey(key)
            let keys = Mode.allCases.map { m in "\(m.title) \(Settings.modeHotkey(m)?.title(handsFree: false) ?? "no key")" }
            Log.shared("keys: \(keys.joined(separator: ", ")) · models: Instant \(Settings.models.fast.id), Balanced \(Settings.models.accurate.id), Thorough \(Settings.models.veryAccurate.id)")
        } else {
            Log.shared("key: none in Keychain")
        }
        _ = OpenRouter.cachedAudioModels() // names for custom models in the menu
        // The icon was first drawn before the key loaded: redraw it now, after every settings change, and every few
        // seconds (permissions change in System Settings without telling us).
        updateIcon()
        NotificationCenter.default.addObserver(forName: .utterSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        let iconTimer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateIcon() } }
        RunLoop.main.add(iconTimer, forMode: .common)

        // Keep the TLS connection open while Utter is in use, so the first request skips the handshake.
        warmTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.controller.lastUse) < 30 * 60 else { return }
                self.controller.transcriber?.warmIfIdle(18)
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: controller.prepareMic()
        case .notDetermined where selfTest == nil && !firstRun: requestMic()
        default: break
        }
        Log.shared("Utter started (\(Bundle.main.bundlePath))")
        selfTest?.run()
        if firstRun { windows.showOnboarding() }
    }

    /// A menu bar app has no menus of its own, but ⌘V, ⌘C, ⌘A and ⌘W in its windows go through the main menu:
    /// without this, pasting a key (or the test dictation's own paste) does nothing.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let m = NSMenu(title: title)
            for (t, sel, key, mods) in items {
                let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
                i.keyEquivalentModifierMask = mods
                m.addItem(i)
            }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
        }
        sub("Utter", [("Quit Utter", #selector(AppDelegate.quitFromKeyboard), "q", .command)])
        sub("Edit", [
            ("Undo", Selector(("undo:")), "z", .command),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", .command),
            ("Copy", #selector(NSText.copy(_:)), "c", .command),
            ("Paste", #selector(NSText.paste(_:)), "v", .command),
            ("Select All", #selector(NSText.selectAll(_:)), "a", .command),
        ])
        sub("Window", [("Close", #selector(NSWindow.performClose(_:)), "w", .command)])
        return main
    }

    private func startTapWhenTrusted(prompt: Bool) {
        if AXIsProcessTrusted(), controller.tap.start() {
            Log.shared("hotkey tap on")
            updateIcon()
            return
        }
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        axTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), self.controller.tap.start() else { return }
                t.invalidate()
                Log.shared("hotkey tap on")
                self.updateIcon()
                self.model.refreshPermissions()
            }
        }
        RunLoop.main.add(timer, forMode: .common) // keeps polling while the menu is open
        axTimer = timer
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                if ok { self.controller.prepareMic() }
                self.updateIcon()
                self.model.refreshPermissions()
            }
        }
    }

    /// Slashed only when Utter can't dictate at all: no hotkey (Accessibility), no OpenRouter key, no microphone, or no mode
    /// with a key. Notes like the fn key's macOS action are text in the menu and Settings, not a problem icon.
    private func updateIcon() {
        guard let statusItem else { return }
        let state: Logo.State
        let cantDictate = !controller.tap.isRunning || controller.transcriber == nil
            || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized || Settings.startableModes.isEmpty
        if controller.isRecording { state = .recording }
        else if cantDictate { state = .problem }
        else { state = .idle }
        guard state != iconState || statusItem.button?.image == nil else { return }
        if state != .recording, state != iconState { Log.shared("menu bar icon: \(state == .problem ? "can't dictate (slashed)" : "ready")") }
        iconState = state
        statusItem.button?.image = Logo.menuBarIcon(state)
    }
    private var iconState: Logo.State?

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func action(_ s: String, _ sel: Selector, key: String = "") {
            let i = NSMenuItem(title: s, action: sel, keyEquivalent: key); i.target = self; menu.addItem(i)
        }
        info("Hold a mode's key to talk, let go to paste")
        info("Double-tap it for hands-free · Esc cancels")
        // Say exactly what is missing, each with the button that fixes it.
        var problems = false
        func problem(_ text: String, _ fix: String, _ sel: Selector) {
            if !problems { menu.addItem(.separator()); problems = true }
            info("⚠︎ \(text)")
            action("    \(fix)", sel)
        }
        if controller.transcriber == nil {
            problem("No OpenRouter key yet", "Add Your Key…", #selector(openSettings))
        }
        if Settings.startableModes.isEmpty {
            problem("No mode has a key, so nothing can start a dictation", "Set Keys…", #selector(openKeys))
        }
        if !AXIsProcessTrusted() {
            problem("Accessibility is off: the hotkey and pasting need it", "Open Accessibility Settings…", #selector(openAccessibility))
        } else if !controller.tap.isRunning {
            problem("Hotkey couldn't start even with Accessibility on", "Open Input Monitoring Settings…", #selector(openInputMonitoring))
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            if let e = controller.micError { info("⚠︎ Microphone: \(e)") ; problems = true }
        case .notDetermined:
            problem("Microphone access not asked yet", "Allow Microphone…", #selector(openMicrophone))
        default:
            problem("Microphone access is off", "Open Microphone Settings…", #selector(openMicrophone))
        }
        if let o = controller.lastOutcome {
            menu.addItem(.separator())
            info(String(format: "Last: %.2f s release→text · %.1f s audio · %d request%@ · %@", o.releaseToText, o.audioSeconds, o.pieces,
                        o.pieces == 1 ? "" : "s", ModelNames.text(o.model)))
            if !o.text.isEmpty { action("Copy Last Transcript", #selector(copyLast)) }
        }
        if controller.canRetry {
            if controller.lastOutcome == nil { menu.addItem(.separator()) }
            action("Retry Last Dictation", #selector(retryLast))
        }
        menu.addItem(.separator())
        info("Modes and their keys")
        let models = Settings.models, after = Settings.autoAccurateAfter
        for mode in Mode.allCases {
            let key = Settings.modeHotkey(mode)?.title(handsFree: false) ?? "no key"
            info("\(mode.title): \(key) · \(mode.detail(models, autoAfter: after))")
        }
        menu.addItem(.separator())
        action("Settings…", #selector(openSettings), key: ",")
        action("Edit Vocabulary…", #selector(openVocabulary))
        action("Set Up Utter…", #selector(openSetup))
        let keep = NSMenuItem(title: "Keep Recordings for Benchmarks", action: #selector(toggleKeep), keyEquivalent: "")
        keep.target = self
        keep.state = UserDefaults.standard.bool(forKey: "UtterKeepRecordings") ? .on : .off
        menu.addItem(keep)
        action("Open Log", #selector(openLog))
        menu.addItem(.separator())
        action("Quit Utter", #selector(quit), key: "q")
    }

    @objc private func openAccessibility() { model.openAccessibility() }
    @objc private func openInputMonitoring() { model.openInputMonitoring() }
    @objc private func openMicrophone() { model.allowMicrophone() }

    @objc private func copyLast() {
        guard let t = controller.lastOutcome?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    @objc private func openKeys() { windows.showSettings(.hotkeys) }

    @objc private func toggleKeep() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "UtterKeepRecordings"), forKey: "UtterKeepRecordings")
    }

    @objc private func openSettings() { windows.showSettings() }
    @objc private func openVocabulary() { windows.showSettings(.vocabulary) }
    @objc private func openSetup() { windows.showOnboarding() }
    @objc private func openLog() { NSWorkspace.shared.open(Log.shared.url) }
    @objc private func retryLast() { controller.retryLast() }

    @objc private func quit() {
        Log.shared("quit from the menu bar menu")
        NSApp.terminate(nil)
    }

    /// ⌘Q while one of Utter's windows is in front.
    @objc func quitFromKeyboard() {
        Log.shared("quit with ⌘Q (\(NSApp.keyWindow?.title ?? "no window") in front)")
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ note: Notification) {
        Log.shared("Utter quitting")
    }

    /// A quit from outside (`kill`, logout, an updater) leaves a line in the log too.
    private var signalSources: [DispatchSourceSignal] = []
    private func logSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Log.shared("quit by signal \(sig == SIGTERM ? "SIGTERM" : sig == SIGINT ? "SIGINT" : "SIGHUP") from outside")
                // Let the log line reach the file, then go.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
