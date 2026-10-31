import AppKit
import SwiftUI
import UtterCore

/// Opens the onboarding and Settings windows (one of each at most).
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    private let model = AppModel.shared
    private var onboarding: NSWindow?
    private var settings: NSWindow?

    func showOnboarding() {
        if let onboarding { bringUp(onboarding); return }
        model.reload()
        let view = OnboardingView(model: model, onFinish: { [weak self] in
            Settings.onboarded = true
            Log.shared("onboarding finished")
            self?.onboarding?.close()
        })
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: view)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.title = "Set Up Utter"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        onboarding = w
        model.windowOpened()
        Log.shared("onboarding shown")
        bringUp(w)
    }

    func showSettings(_ page: SettingsPage? = nil) {
        if let page { model.settingsPage = page }
        if let settings { bringUp(settings); return }
        model.reload()
        let host = NSHostingController(rootView: SettingsView(model: model, onSetup: { [weak self] in self?.showOnboarding() }))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentViewController = host
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Utter Settings"
        w.setContentSize(NSSize(width: 780, height: 560))
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        settings = w
        model.windowOpened()
        bringUp(w)
        // Don't start with the key field focused (its dots would show selected).
        DispatchQueue.main.async { w.makeFirstResponder(nil) }
    }

    var settingsWindow: NSWindow? { settings }
    var onboardingWindow: NSWindow? { onboarding }

    /// The app in front before Utter's window came up, to hand the keyboard back to.
    private var cameFrom: NSRunningApplication?

    private func bringUp(_ w: NSWindow) {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() { cameFrom = front }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        HotkeyRecorder.shared.stop()
        if w === onboarding {
            // Closing the setup with a working key counts as done; without one it shows again next launch.
            if model.savedKey != nil && !model.assumeTapRunning { Settings.onboarded = true } // not when --capture-ui closes it
            onboarding = nil
        } else if w === settings {
            settings = nil
        }
        model.windowClosed()
        // With no window left, give the keyboard back to the app the user came from: otherwise Utter stays the active
        // app without a window, and a ⌘Q meant for whatever is behind it quits Utter.
        if !model.assumeTapRunning {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.onboarding == nil, self.settings == nil, NSApp.isActive else { return }
                if let app = self.cameFrom, !app.isTerminated { app.activate() } else { NSApp.deactivate() }
                self.cameFrom = nil
            }
        }
    }
}

/// `Utter --capture-ui DIR`: opens the real Settings and setup windows (one at a time), goes through every page and
/// step in light and dark, and saves each as the window draws itself, title bar included (no screen capture,
/// so no Screen Recording permission). `layout.txt` records each window's size against what its content needs.
@MainActor
enum UICapture {
    static func run(_ windows: Windows, to dir: String) async {
        let model = AppModel.shared
        model.assumeTapRunning = true
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var layout: [String] = []
        var rows: [String] = []
        // The key-row states change keys for a moment (a clash), so only in a scratch settings domain.
        let scratch = ProcessInfo.processInfo.environment["UTTER_DEFAULTS_SUITE"] != nil
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let suffix = dark ? "-dark" : ""
            windows.showSettings(.general)
            if let w = windows.settingsWindow { awayFromPointer(w) }
            for page in SettingsPage.allCases {
                model.settingsPage = page
                await pause(1.2)
                if let w = windows.settingsWindow {
                    layout.append(check(w, "settings \(page.rawValue)\(suffix)"))
                    save(w, to: "\(dir)/settings-\(SettingsPage.allCases.firstIndex(of: page)! + 1)-\(page.rawValue)\(suffix).png")
                    if page == .hotkeys, scratch { await keyStates(w, context: "settings", name: "settings-2-hotkeys", dir: dir, suffix: suffix, log: &rows) }
                    if page == .modes {
                        // The model picker opens in its own popover window.
                        model.pickerTier = .accurate
                        await pause(1.5)
                        if let pop = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
                            save(pop, to: "\(dir)/settings-3-modes-picker\(suffix).png", contentOnly: true)
                        }
                        model.pickerTier = nil
                        await pause(0.4)
                    }
                    if page == .prompt {
                        model.promptTab = 1
                        await pause(0.8)
                        save(w, to: "\(dir)/settings-4-prompt-preview\(suffix).png")
                        model.promptTab = 0
                    }
                }
            }
            windows.settingsWindow?.close()
            await pause(0.4)
            model.onboardingStep = .welcome
            windows.showOnboarding()
            if let w = windows.onboardingWindow { awayFromPointer(w) }
            for step in OnboardingView.Step.allCases {
                model.onboardingStep = step
                await pause(1.2)
                if let w = windows.onboardingWindow {
                    layout.append(check(w, "setup \(step)\(suffix)"))
                    save(w, to: "\(dir)/setup-\(step.rawValue + 1)-\(step)\(suffix).png")
                    if step == .hotkeys, scratch { await keyStates(w, context: "setup", name: "setup-4-hotkeys", dir: dir, suffix: suffix, log: &rows) }
                }
            }
            windows.onboardingWindow?.close()
            await pause(0.4)
        }
        NSApp.appearance = nil
        // The icon macOS shows for Utter.app (Finder, Settings), as the system serves it.
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 512, height: 512)
        if let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/app-icon-as-macos-shows-it.png"))
        }
        try? (layout.joined(separator: "\n") + "\n").write(toFile: "\(dir)/layout.txt", atomically: true, encoding: .utf8)
        if !rows.isEmpty { try? (rows.joined(separator: "\n") + "\n").write(toFile: "\(dir)/row-positions.txt", atomically: true, encoding: .utf8) }
        print(layout.joined(separator: "\n"))
    }

    private static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Puts the window on the side of the screen away from the pointer, so the close and minimize buttons draw plain
    /// (under the pointer they show their hover symbols). Doesn't move the pointer.
    private static func awayFromPointer(_ w: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? w.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = w.frame
        f.origin.x = mouse.x < vf.midX ? vf.maxX - f.width - 8 : vf.minX + 8
        f.origin.y = mouse.y < vf.midY ? vf.maxY - f.height - 8 : vf.minY + 8
        if !f.contains(mouse) { w.setFrame(f, display: true) }
    }

    /// The key rows in four states (idle, recording, an error, a clash), each saved, with every row's position logged:
    /// the rows and the status line must sit in the same place in all of them.
    private static func keyStates(_ w: NSWindow, context: String, name: String, dir: String, suffix: String, log: inout [String]) async {
        let status = KeyRecordingStatus.shared
        let model = AppModel.shared
        var snaps: [(String, [String: CGRect])] = []
        func snap(_ state: String) async {
            await pause(0.7)
            save(w, to: "\(dir)/\(name)-\(state)\(suffix).png")
            snaps.append((state, FrameLog.frames.filter { $0.key.hasPrefix(context) }))
        }
        await snap("idle")
        status.field = "\(context).accurate"; status.live = "⇧⌘"
        await snap("recording")
        status.error = "Add ⌘, ⌃ or ⌥ to that key, or use modifiers only (fn, ⇧⌘…)."
        await snap("error")
        status.field = nil; status.live = ""; status.error = nil
        let saved = model.modeHotkeys[.fast]
        model.setModeHotkey(model.modeHotkeys[.auto], for: .fast)
        await snap("clash")
        model.setModeHotkey(saved, for: .fast)
        await pause(0.3)
        // One line per row: its y and height in each state, and whether it ever moved.
        for key in snaps[0].1.keys.sorted() {
            let ys = snaps.map { s in s.1[key].map { String(format: "%.1f/%.1f", $0.minY, $0.height) } ?? "-" }
            let same = Set(ys).count == 1
            log.append("\(same ? "same " : "MOVED") \(name)\(suffix) \(key): " + zip(snaps.map(\.0), ys).map { "\($0) \($1)" }.joined(separator: ", "))
        }
    }

    /// The window's content size, and the smallest size its SwiftUI content can take: content wider than the window is clipped.
    private static func check(_ w: NSWindow, _ name: String) -> String {
        let have = w.contentLayoutRect.size
        let need = w.contentViewController?.view.fittingSize ?? .zero
        let ok = need.width <= w.frame.width + 0.5
        return String(format: "%@ %@: window %.0f×%.0f, content needs %.0f×%.0f", ok ? "fits " : "CLIPS", name, have.width, have.height, need.width, need.height)
    }

    /// The whole window as it draws itself: title bar, toolbar, sidebar and content.
    private static func save(_ w: NSWindow, to path: String, contentOnly: Bool = false) {
        // A popover's frame draws its material arrow badly offscreen: its content alone, on the window color.
        guard let frame = contentOnly ? w.contentView : w.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        let bounds = frame.bounds
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frame.cacheDisplay(in: bounds, to: rep)
        // Translucent parts (sidebar, title bar) blend with what's behind the window; put the window color behind them.
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        w.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        }
        rep.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
