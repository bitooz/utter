import AppKit
import ApplicationServices
import UtterCore

/// Puts text into the focused field: clipboard + synthetic Cmd+V (works in native, web and Electron apps), then restores
/// whatever was on the clipboard before, but only once the text is seen in the field. Whenever that can't be confirmed
/// (no text field, an app that doesn't say what has the focus, a field that shows no change), the text stays on the
/// clipboard: a transcript is never lost.
enum Paster {
    /// What sits just before the caret in the focused field, if Accessibility can tell.
    /// Called at key release, while the transcript is still on its way.
    static func characterBeforeCaret() -> Character? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        let element = el as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.15)
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range), range.location > 0 else { return nil }
        var param = CFRange(location: range.location - 1, length: 1)
        guard let p = AXValueCreate(.cfRange, &param) else { return nil }
        var strRef: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, p, &strRef) == .success,
           let s = strRef as? String, let c = s.last {
            return c
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else { return nil }
        let ns = value as NSString
        guard range.location <= ns.length else { return nil }
        return (ns.substring(with: NSRange(location: range.location - 1, length: 1))).last
    }

    /// Adds a leading space when dictating right after a word, like typing would.
    static func spaced(_ text: String, after prev: Character?) -> String {
        guard let prev, let first = text.first else { return text }
        if prev.isWhitespace || "([{\"'“‘/-".contains(prev) { return text }
        if ".,;:!?)]}…".contains(first) { return text }
        return " " + text
    }

    // MARK: Utter's own key events

    /// Stamped on every event Utter posts (the ⌘V of a paste), so Utter's own key tap lets it through untouched:
    /// a paste landing while the next dictation's key is held must not count as "another key pressed".
    static let eventMarker: Int64 = 0x5554_5452 // "UTTR"

    /// The ⌘V that pastes, marked as Utter's own.
    static func commandV() -> (down: CGEvent, up: CGEvent)? {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return nil }
        for e in [down, up] {
            e.flags = .maskCommand
            e.setIntegerValueField(.eventSourceUserData, value: eventMarker)
        }
        return (down, up)
    }

    static func isOwn(_ event: CGEvent) -> Bool { event.getIntegerValueField(.eventSourceUserData) == eventMarker }

    // MARK: Where the text goes

    /// What has the keyboard focus: the app, the element, and whether it takes text.
    struct Focus {
        enum Kind { case text, notText, unknown }
        var pid: pid_t?
        var bundle: String?
        var element: AXUIElement?
        var role: String?
        var frame: CGRect?
        var kind: Kind

        /// Same app and same field (or, where the app hands out a new reference each time, the same kind of element in the same place).
        func isSame(as other: Focus) -> Bool {
            guard let pid, pid == other.pid else { return pid == nil && other.pid == nil }
            guard let a = element, let b = other.element else { return true }
            if CFEqual(a, b) { return true }
            return role == other.role && frame != nil && frame == other.frame
        }

        /// For the log: "com.apple.Safari, AXTextField, text".
        var summary: String { "\(bundle ?? pid.map { "pid \($0)" } ?? "no app"), \(role ?? (element == nil ? "no focused element" : "no role")), \(kind)" }
    }

    /// Roles that never take typed text: a focused one of these means there is no text field to paste into.
    private static let nonTextRoles: Set<String> = [
        "AXWebArea", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXButton", "AXImage", "AXScrollArea", "AXStaticText",
        "AXLink", "AXRow", "AXCell", "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuButton", "AXToolbar", "AXSplitGroup",
        "AXTabGroup", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXGrid", "AXDisclosureTriangle",
        "AXColumn", "AXSplitter", "AXProgressIndicator", "AXLevelIndicator", "AXHeading", "AXDockItem",
    ]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Apps where nothing is focused when no window is, and whose only text fields have text roles (Finder: the desktop
    /// reports an AXGroup that looks editable, but the only fields are rename, search and Go to Folder).
    private static let noFocusMeansNoField: Set<String> = ["com.apple.finder"]

    /// Electron apps (Slack, VS Code…) build their Accessibility tree only when asked to; asked once per app.
    private static var askedForTree = Set<pid_t>()
    private static let askedLock = NSLock()

    /// Reads the focus through Accessibility. Off the main thread: an app (or Utter itself) may take a moment to answer.
    /// Anything Accessibility can't tell (an app that doesn't expose its fields) counts as `.unknown`: it still pastes,
    /// and the text stays on the clipboard too.
    static func focus() -> Focus {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var appRef: CFTypeRef?
        var pid: pid_t?
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
           let a = appRef, CFGetTypeID(a) == AXUIElementGetTypeID() {
            var p: pid_t = 0
            if AXUIElementGetPid(a as! AXUIElement, &p) == .success { pid = p }
        }
        if pid == nil { pid = NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let bundle = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        var focused: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        if err != .success || focused.map({ role(of: $0) == kAXWindowRole }) == true, let pid, pid != getpid(), askedLock.withLock({ askedForTree.insert(pid).inserted }) {
            // Maybe an Electron app with its tree off: switch it on and look again.
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.2)
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                Thread.sleep(forTimeInterval: 0.15)
                err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
            }
        }
        guard err == .success, let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else {
            let none = err == .noValue && bundle.map(noFocusMeansNoField.contains) == true
            return Focus(pid: pid, bundle: bundle, element: nil, kind: none ? .notText : .unknown)
        }
        let element = el as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        var f = Focus(pid: pid, bundle: bundle, element: element, role: string(element, kAXRoleAttribute), frame: frame(element), kind: .unknown)
        var settable: DarwinBoolean = false
        var range: CFTypeRef?
        if let role = f.role, textRoles.contains(role) {
            f.kind = .text
        } else if bundle.map(noFocusMeansNoField.contains) == true {
            f.kind = .notText
        } else if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
                    || (AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
                        && string(element, kAXValueAttribute) != nil) {
            f.kind = .text
        } else if let role = f.role, nonTextRoles.contains(role) {
            f.kind = .notText
        }
        return f
    }

    private static func role(of ref: CFTypeRef) -> String? {
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return string(ref as! AXUIElement, kAXRoleAttribute)
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let pv = p, let sv = s, CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &point)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// How much text the field holds and where the caret is: a change means the paste landed.
    private static func fieldState(_ e: AXUIElement) -> [Int]? {
        var n: CFTypeRef?, r: CFTypeRef?
        var out: [Int] = []
        if AXUIElementCopyAttributeValue(e, kAXNumberOfCharactersAttribute as CFString, &n) == .success, let c = n as? Int { out.append(c) }
        if AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &r) == .success, let rv = r,
           CFGetTypeID(rv) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &range) { out += [range.location, range.length] }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Clipboard

    /// Remote desktops and virtual machines pass the clipboard on to another computer before it pastes: give them longer.
    private static let slowPasteApps = ["com.microsoft.rdc", "com.parsec", "com.vmware", "com.parallels", "com.citrix", "com.realvnc",
                                        "com.teamviewer", "com.utmapp", "com.anydesk", "org.virtualbox", "com.p5sys.jump", "com.apple.ScreenSharing"]

    /// The user's clipboard while a paste borrows it, and which paste it waits for.
    private static var borrowed: (items: [[(NSPasteboard.PasteboardType, Data)]], generation: Int)?
    private static var generation = 0

    /// Leaves the text on the clipboard, as if the user had copied it (no field to paste into, or focus moved).
    static func copy(_ text: String) {
        generation += 1
        borrowed = nil // the user's old clipboard is replaced on purpose now
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// How a paste went: landed (and how Utter knows), or not confirmed (and why), in which case the text was left on
    /// the clipboard.
    enum Check: Equatable {
        case landed(String)
        case unconfirmed(String)
    }

    /// Hands the text out only when an app asks for it, and says so. Clipboard managers don't read it (the entry carries
    /// the nspasteboard.org "ignore me" marks), so a read right after Utter's ⌘V is the front app handling the paste.
    /// That alone doesn't mean a field took the text: Chrome and web views (WKWebView) read the clipboard on ⌘V even
    /// with no field focused, asking for the same thing either way. So a read counts only when Accessibility shows a
    /// text field with the focus, one that doesn't show its changes (VS Code's editor).
    private final class Promise: NSObject, NSPasteboardItemDataProvider {
        let text: String
        private let lock = NSLock()
        private var count = 0
        init(_ text: String) { self.text = text }
        var reads: Int { lock.withLock { count } }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            lock.withLock { count += 1 }
        }
    }

    /// Pastes with ⌘V through the clipboard (works in native, web and Electron apps), then waits up to 1.5 s for a sign it
    /// landed: the app reading the clipboard, or the field showing the change through Accessibility. Then the user's
    /// clipboard is put back. Without a sign, the text stays on the clipboard as a normal entry. Call on the main
    /// thread; `sent` (as soon as ⌘V is posted) and `done` (once the wait is over) come on the main thread too.
    static func paste(_ text: String, into target: Focus, sent: @escaping () -> Void = {}, done: @escaping (Check) -> Void) {
        let pb = NSPasteboard.general
        // A paste right after another one: the clipboard still holds the last transcript, the user's is the one saved then.
        let saved = borrowed?.items ?? (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        // Remote desktops and virtual machines read the clipboard as soon as it changes, to pass it on: no sign there.
        let slow = slowPasteApps.contains { (target.bundle ?? "").hasPrefix($0) }
        let element = target.kind == .text ? target.element : nil
        let field = target.role.map(textRoles.contains) == true
        generation += 1
        let gen = generation
        pb.clearContents()
        let promise = Promise(text)
        if slow {
            borrowed = nil // the text replaces the user's clipboard, as a normal copy
            pb.setString(text, forType: .string)
        } else {
            borrowed = (saved, gen)
            let item = NSPasteboardItem()
            item.setDataProvider(promise, forTypes: [.string])
            // Tells clipboard managers to ignore this entry: it's only there for the paste.
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
            pb.writeObjects([item])
        }
        let ours = pb.changeCount

        // Off the main thread: the app answers in its own time, and asks the main thread for the promised text.
        DispatchQueue.global(qos: .userInitiated).async {
            let before = slow ? nil : element.flatMap(fieldState)
            if let v = commandV() {
                v.down.post(tap: .cghidEventTap)
                v.up.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.async(execute: sent)
            var sign: String?
            let start = Date()
            while !slow, sign == nil, Date().timeIntervalSince(start) < 1.5 {
                Thread.sleep(forTimeInterval: 0.04)
                if let element, let before, let now = fieldState(element), now != before { sign = "seen in the field" }
                else if field, promise.reads > 0 { sign = "the app read the clipboard" }
            }
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            DispatchQueue.main.async {
                withExtendedLifetime(promise) {}
                if let sign {
                    // A moment more for apps that read the clipboard twice.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { restore(saved, gen: gen, ours: ours) }
                    done(.landed("\(sign) after \(ms) ms"))
                } else {
                    keep(text, gen: gen, ours: ours, rewrite: !slow)
                    done(.unconfirmed(slow ? "remote desktop or virtual machine"
                        : promise.reads > 0 ? "the app read the clipboard, but no text field is known to have the focus"
                        : "no read of the clipboard and no change seen in 1.5 s"))
                }
            }
        }
    }

    /// Puts the user's clipboard back after a paste that landed.
    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], gen: Int, ours: Int) {
        let pb = NSPasteboard.general
        guard generation == gen else { return } // a later paste or copy took over
        borrowed = nil
        guard pb.changeCount == ours else { return } // something else copied meanwhile
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { pairs in
            let item = NSPasteboardItem()
            for (t, d) in pairs { item.setData(d, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// Leaves the text of a paste that couldn't be confirmed on the clipboard, as a normal entry.
    private static func keep(_ text: String, gen: Int, ours: Int, rewrite: Bool) {
        guard generation == gen else { return }
        borrowed = nil
        // Written again as plain text without the "ignore me" marks, so clipboard managers keep it too.
        guard rewrite, NSPasteboard.general.changeCount == ours else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
