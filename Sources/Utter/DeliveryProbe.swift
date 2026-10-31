import AppKit

/// `Utter --probe-delivery DIR`, started with `open -n build/Utter.app --args --probe-delivery DIR` so it runs with
/// Utter's Accessibility permission: brings each app forward in turn, reads the focus and delivers a test sentence through
/// the same code as a dictation (`Controller.deliver`), then checks that the sentence is either seen in a text field or
/// on the clipboard. A real ⌘V only where it can't touch the user's work: the desktop, a Finder window on DIR, Utter's own
/// test pages in Safari and Chrome, a scratch file in VS Code. In Filo it reads the focus and doesn't paste.
/// Puts the user's clipboard and front app back at the end, and writes DIR/delivery-probe.txt.
@MainActor
enum DeliveryProbe {
    struct Case {
        var name: String
        var bundle: String
        /// Opened with `open -a`; nil just brings the app forward.
        var app: String?
        var file: String?
        /// May post ⌘V here.
        var paste = true
        /// Moves the focus into the web page (off the address bar), as a click on the page would.
        var focusPage = false
        /// Closes what the case opened with ⌘W (and saves first with ⌘S).
        var close = false
        var save = false
    }

    static func run(to dir: String) async {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let blank = "\(dir)/probe-no-field.html", field = "\(dir)/probe-field.html", scratch = "\(dir)/probe-scratch.txt"
        try? "<title>Utter probe: no field</title><body style='font:20px system-ui;padding:40px'><h1>No text field here</h1><p>Utter's delivery probe.</p>"
            .write(toFile: blank, atomically: true, encoding: .utf8)
        try? "<title>Utter probe: field</title><body style='font:20px system-ui;padding:40px'><input id=f autofocus style='font:20px system-ui;width:80%'><script>f.focus()</script>"
            .write(toFile: field, atomically: true, encoding: .utf8)
        try? "Utter's delivery probe pastes below.\n".write(toFile: scratch, atomically: true, encoding: .utf8)

        let cases = [
            Case(name: "desktop (Finder, no window)", bundle: "com.apple.finder"),
            Case(name: "Finder window", bundle: "com.apple.finder", app: "Finder", file: dir, close: true),
            Case(name: "Safari, page with no field", bundle: "com.apple.Safari", app: "Safari", file: blank, focusPage: true, close: true),
            Case(name: "Safari, focused field", bundle: "com.apple.Safari", app: "Safari", file: field, close: true),
            Case(name: "Chrome, page with no field", bundle: "com.google.Chrome", app: "Google Chrome", file: blank, focusPage: true, close: true),
            Case(name: "Chrome, focused field", bundle: "com.google.Chrome", app: "Google Chrome", file: field, close: true),
            Case(name: "Filo (whatever has the focus; no paste)", bundle: "im.filo.desktop", paste: false),
            Case(name: "VS Code, scratch file in the editor", bundle: "com.microsoft.VSCode", app: "Visual Studio Code", file: scratch, close: true, save: true),
        ]

        let pb = NSPasteboard.general
        let userClipboard = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        let front = NSWorkspace.shared.frontmostApplication
        let wasRunning = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var lines = ["Utter delivery probe, \(Date())", "AX trusted: \(AXIsProcessTrusted())", ""]
        var allSafe = true

        for (i, c) in cases.enumerated() {
            if !bringUp(c) { lines.append("SKIP  \(c.name): not installed"); continue }
            let up = await waitFront(c.bundle, seconds: wasRunning.contains(c.bundle) ? 6 : 15)
            await pause(wasRunning.contains(c.bundle) ? 1.5 : 4) // the page or file loads and takes the focus
            if c.focusPage { focusWebArea(c.bundle); await pause(0.5) }
            let sentinel = "utter-probe-old-clipboard-\(i)"
            pb.clearContents(); pb.setString(sentinel, forType: .string)
            let text = "Utter delivery test \(i + 1)."
            let target = await read()
            await pause(0.3)
            let now = await read()
            var line: String
            if !up {
                line = "SKIP  \(c.name): didn't come to the front (front is \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))"
            } else if !c.paste && now.kind != .notText {
                line = "READ  \(c.name): \(now.summary) → would paste and, \(now.kind == .text ? "unless the field shows the text," : "with no field confirmed,") leave it on the clipboard (not pasted: the user's app)"
            } else {
                let (how, whereTo) = await withCheckedContinuation { k in
                    Controller.deliver(text, after: nil, target: target, now: now) { k.resume(returning: ($0, $1)) }
                }
                await pause(0.6) // a landed paste puts the old clipboard back after 0.25 s
                let clip = pb.string(forType: .string) ?? ""
                let safe = how == .pasted ? clip == sentinel : clip == text
                allSafe = allSafe && safe
                line = "\(safe ? "PASS" : "FAIL")  \(c.name): \(how) · \(whereTo) · clipboard now \(clip == text ? "the test sentence" : clip == sentinel ? "the old clipboard (put back)" : "\"\(clip.prefix(40))\"")"
            }
            lines.append(line)
            print(line)
            if c.close, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == c.bundle {
                if c.save { key(1, .maskCommand); await pause(0.6) } // ⌘S
                key(13, .maskCommand) // ⌘W: the tab, window or file this case opened
                await pause(0.6)
            }
        }
        // Apps the probe started go again.
        for b in Set(cases.map(\.bundle)) where !wasRunning.contains(b) {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: b) { app.terminate() }
        }
        pb.clearContents()
        let items: [NSPasteboardItem] = userClipboard.map { pairs in
            let item = NSPasteboardItem()
            for (t, d) in pairs { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        front?.activate()
        lines += ["", allSafe ? "No transcript lost: each one was seen in a text field or left on the clipboard." : "SOME TRANSCRIPT WAS LOST"]
        try? (lines.joined(separator: "\n") + "\n").write(toFile: "\(dir)/delivery-probe.txt", atomically: true, encoding: .utf8)
    }

    private static func bringUp(_ c: Case) -> Bool {
        if let app = c.app {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", app] + (c.file.map { [$0] } ?? [])
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: c.bundle).first else { return false }
        return app.activate()
    }

    /// Focuses the front window's web page through Accessibility.
    private static func focusWebArea(_ bundle: String) {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else { return }
        let app = AXUIElementCreateApplication(pid)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success, let w = win else { return }
        var queue: [AXUIElement] = [w as! AXUIElement]
        var seen = 0
        while !queue.isEmpty, seen < 400 {
            let e = queue.removeFirst()
            seen += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" {
                AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return
            }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success, let k = kids as? [AXUIElement] { queue += k }
        }
    }

    private static func waitFront(_ bundle: String, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle { return true }
            await pause(0.2)
        }
        return false
    }

    /// The focus, read off the main thread like a dictation does.
    private static func read() async -> Paster.Focus {
        await withCheckedContinuation { k in DispatchQueue.global().async { k.resume(returning: Paster.focus()) } }
    }

    private static func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.setIntegerValueField(.eventSourceUserData, value: Paster.eventMarker)
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
}
