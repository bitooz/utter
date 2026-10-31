import AppKit

/// `Utter --probe-delivery DIR`, started with `open -n build/Utter.app --args --probe-delivery DIR` so it runs with
/// Utter's Accessibility permission: brings each app forward in turn, reads the focus and delivers a test sentence through
/// the same code as a dictation (`Controller.deliver`), then checks that the sentence is either seen in a text field or
/// on the clipboard. A real ⌘V only where it can't touch the user's work: the desktop, a Finder window on DIR, Utter's own
/// test pages in Safari and Chrome, a scratch file in VS Code, and TestPad's web views (one hidden from Accessibility
/// like Filo's, with and without a field). In Filo itself it reads the focus and doesn't paste.
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
        /// Nothing there can take text: "pasted" (and the old clipboard put back) would lose the sentence.
        var noField = false
        /// TestPad's `--field` mode: a fresh TestPad, whose state file shows what landed in its field.
        var pad: String?
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
            Case(name: "desktop (Finder, no window)", bundle: "com.apple.finder", noField: true),
            Case(name: "Finder window", bundle: "com.apple.finder", app: "Finder", file: dir, close: true, noField: true),
            Case(name: "Safari, page with no field", bundle: "com.apple.Safari", app: "Safari", file: blank, focusPage: true, close: true, noField: true),
            Case(name: "Safari, focused field", bundle: "com.apple.Safari", app: "Safari", file: field, close: true),
            Case(name: "Chrome, page with no field", bundle: "com.google.Chrome", app: "Google Chrome", file: blank, focusPage: true, close: true, noField: true),
            Case(name: "Chrome, focused field", bundle: "com.google.Chrome", app: "Google Chrome", file: field, close: true),
            Case(name: "Filo (whatever has the focus; no paste)", bundle: "im.filo.desktop", paste: false),
            Case(name: "TestPad web view with a field", bundle: "dev.utter.TestPad", pad: "web"),
            Case(name: "TestPad web view hidden from Accessibility (like Filo), with a field", bundle: "dev.utter.TestPad", pad: "web-hidden"),
            Case(name: "TestPad web view hidden from Accessibility (like Filo), no field", bundle: "dev.utter.TestPad", noField: true, pad: "web-hidden-empty"),
            Case(name: "VS Code, scratch file in the editor", bundle: "com.microsoft.VSCode", app: "Visual Studio Code", file: scratch, close: true, save: true),
        ]

        let pb = NSPasteboard.general
        let userClipboard = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        let front = NSWorkspace.shared.frontmostApplication
        let wasRunning = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var lines = ["Utter delivery probe, \(Date())", "AX trusted: \(AXIsProcessTrusted())", ""]
        var allSafe = true

        let only = ProcessInfo.processInfo.environment["UTTER_PROBE_ONLY"] // runs just the cases whose name has this
        for (i, c) in cases.enumerated() where only.map({ c.name.contains($0) }) ?? true {
            if !bringUp(c, dir: dir) { lines.append("SKIP  \(c.name): not installed"); continue }
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
                let start = Date()
                var pillEnd: TimeInterval?
                let (how, whereTo) = await withCheckedContinuation { k in
                    Controller.deliver(text, after: nil, target: target, now: now, sent: { pillEnd = Date().timeIntervalSince(start) }) {
                        k.resume(returning: ($0, $1))
                    }
                }
                let settled = Date().timeIntervalSince(start)
                await pause(0.6) // a landed paste puts the old clipboard back after 0.25 s
                let clip = pb.string(forType: .string) ?? ""
                var safe = how == .pasted ? clip == sentinel && !c.noField : clip == text
                var landed = ""
                if let mode = c.pad, mode != "web-hidden-empty" {
                    let state = (try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/pad-\(mode).json")))
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    let holds = (state?["text"] as? String)?.contains(text) == true
                    if how == .pasted && !holds { safe = false }
                    landed = " · TestPad's field \(holds ? "holds the sentence" : "does NOT hold the sentence")"
                }
                allSafe = allSafe && safe
                line = "\(safe ? "PASS" : "FAIL")  \(c.name): \(how) · \(whereTo) · clipboard now \(clip == text ? "the test sentence" : clip == sentinel ? "the old clipboard (put back)" : "\"\(clip.prefix(40))\"")"
                line += landed
                // The pill ends at ⌘V (a paste) or at once (a copy); the check behind it may take up to 1.5 s more.
                line += " · pill ended after \(Int((pillEnd ?? settled) * 1000)) ms, settled after \(Int(settled * 1000)) ms"
            }
            if c.pad != nil { for app in NSRunningApplication.runningApplications(withBundleIdentifier: c.bundle) { app.terminate() } }
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
        lines += ["", allSafe ? "No transcript lost: each one landed in a text field (old clipboard put back) or is on the clipboard."
                              : "SOME TRANSCRIPT WAS LOST (said pasted where nothing took it)"]
        try? (lines.joined(separator: "\n") + "\n").write(toFile: "\(dir)/delivery-probe.txt", atomically: true, encoding: .utf8)
    }

    private static func bringUp(_ c: Case, dir: String) -> Bool {
        if let mode = c.pad {
            let pad = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("TestPad.app").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", pad, "--args", "--state", "\(dir)/pad-\(mode).json", "--field", mode]
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
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

/// `Utter --probe-ax BUNDLE FILE` (started with `open -n`): brings the app forward and writes how its Accessibility tree
/// answers "what has the focus?" before and after each way of asking it to build its tree. Roles and focus flags only,
/// never titles or values (no one's text ends up in the file).
@MainActor
enum AXProbe {
    static func run(bundle: String, to file: String) async {
        var out: [String] = []
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
        app.activate()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let el = AXUIElementCreateApplication(app.processIdentifier)
        func report(_ title: String) {
            out.append("== \(title)")
            out.append("system-wide focus: \(describe(systemFocus()))")
            out.append("app AXFocusedUIElement: \(describe(attr(el, kAXFocusedUIElementAttribute)))")
            if let w = attr(el, kAXFocusedWindowAttribute) {
                out.append("tree of the focused window (role [subrole] *focused):")
                dump(w as! AXUIElement, depth: 0, into: &out)
            }
        }
        report("as is")
        // Every window, and what hit-testing finds at points across the focused one.
        let windows = attr(el, kAXWindowsAttribute) as? [AXUIElement] ?? []
        out.append("== windows: \(windows.count)")
        for w in windows {
            out.append("window \(describe(w)), children \((attr(w, kAXChildrenAttribute) as? [AXUIElement])?.count ?? -1)")
        }
        if let w = attr(el, kAXFocusedWindowAttribute), let f = frame(w as! AXUIElement) {
            out.append("== hit tests in the focused window \(f)")
            for fy in stride(from: 0.1, through: 0.95, by: 0.17) {
                for fx in [0.2, 0.5, 0.8] {
                    var hit: AXUIElement?
                    let p = CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)
                    let r = AXUIElementCopyElementAtPosition(el, Float(p.x), Float(p.y), &hit)
                    var chain: [String] = []
                    var cur = hit
                    while let c = cur, chain.count < 8 {
                        chain.append((attr(c, kAXRoleAttribute) as? String ?? "?") + (attr(c, kAXFocusedAttribute) as? Bool == true ? "*" : ""))
                        cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
                    }
                    out.append(String(format: "(%.2f, %.2f) err %d: ", fx, fy, r.rawValue) + chain.joined(separator: " < "))
                    if let h = hit, (attr(h, kAXRoleAttribute) as? String) == "AXWebArea" || fy > 0.85 {
                        out.append("   \(describe(h)); its AXFocusedUIElement: \(describe(attr(h, kAXFocusedUIElementAttribute)))")
                    }
                }
            }
        }
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            let r = AXUIElementSetAttributeValue(el, name as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 600_000_000)
            report("after setting \(name) (\(r.rawValue))")
        }
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        try? (out.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var point = CGPoint.zero, size = CGSize.zero
        guard let p = attr(e, kAXPositionAttribute), let z = attr(e, kAXSizeAttribute) else { return nil }
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(z as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func systemFocus() -> CFTypeRef? { attr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    private static func describe(_ ref: CFTypeRef?) -> String {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return "none" }
        let e = ref as! AXUIElement
        let role = attr(e, kAXRoleAttribute) as? String ?? "?"
        let sub = attr(e, kAXSubroleAttribute) as? String
        var names: CFArray?
        AXUIElementCopyAttributeNames(e, &names)
        let has = (names as? [String] ?? []).filter { ["AXSelectedTextRange", "AXNumberOfCharacters", "AXFocusedUIElement", "AXSelectedTextMarkerRange"].contains($0) }
        // Button titles only (a dialog's choices), never other text.
        let title = role == "AXButton" ? (attr(e, kAXTitleAttribute) as? String).map { " \"\($0)\"" } ?? "" : ""
        return "\(role)\(sub.map { " [\($0)]" } ?? "")\(title) attrs:\(has)"
    }

    private static func dump(_ e: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth < 14, out.count < 400 else { return }
        let focused = attr(e, kAXFocusedAttribute) as? Bool == true
        out.append(String(repeating: "  ", count: depth) + describe(e) + (focused ? " *focused" : ""))
        guard let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for k in kids.prefix(12) { dump(k, depth: depth + 1, into: &out) }
    }
}
