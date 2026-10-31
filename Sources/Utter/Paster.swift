import AppKit
import ApplicationServices
import UtterCore

/// Puts text into the focused field: clipboard + synthetic Cmd+V (works in native, web and Electron apps),
/// then restores whatever was on the clipboard before. With no text field focused, leaves the text on the clipboard instead.
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
    }

    /// Roles that never take typed text: a focused one of these means there is no text field to paste into.
    private static let nonTextRoles: Set<String> = [
        "AXWebArea", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXButton", "AXImage", "AXScrollArea", "AXStaticText",
        "AXLink", "AXRow", "AXCell", "AXMenu", "AXMenuBar", "AXMenuItem", "AXMenuButton", "AXToolbar", "AXSplitGroup",
        "AXTabGroup", "AXCheckBox", "AXRadioButton", "AXSlider", "AXPopUpButton", "AXGrid", "AXDisclosureTriangle",
        "AXColumn", "AXSplitter", "AXProgressIndicator", "AXLevelIndicator", "AXHeading", "AXDockItem",
    ]
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Apps where nothing is focused when no window is (the desktop): no text field.
    private static let noFocusMeansNoField: Set<String> = ["com.apple.finder"]

    /// Reads the focus through Accessibility. Off the main thread: an app (or Utter itself) may take a moment to answer.
    /// Anything Accessibility can't tell (an app that doesn't expose its fields) counts as `.unknown`, which still pastes.
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
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else {
            let bundle = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            let none = err == .noValue && bundle.map(noFocusMeansNoField.contains) == true
            return Focus(pid: pid, element: nil, kind: none ? .notText : .unknown)
        }
        let element = el as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        var f = Focus(pid: pid, element: element, role: string(element, kAXRoleAttribute), frame: frame(element), kind: .unknown)
        var settable: DarwinBoolean = false
        var range: CFTypeRef?
        if let role = f.role, textRoles.contains(role) {
            f.kind = .text
        } else if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success
                    || (AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
                        && string(element, kAXValueAttribute) != nil) {
            f.kind = .text
        } else if let role = f.role, nonTextRoles.contains(role) {
            f.kind = .notText
        }
        return f
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

    /// Pastes with ⌘V through the clipboard (works in native, web and Electron apps), then puts the user's clipboard back
    /// once the text has landed: when the field shows the change through Accessibility, otherwise after a wait long enough
    /// for slow apps. Call on the main thread.
    static func paste(_ text: String, into target: Focus) {
        let pb = NSPasteboard.general
        // A paste right after another one: the clipboard still holds the last transcript, the user's is the one saved then.
        let saved = borrowed?.items ?? (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        generation += 1
        let gen = generation
        borrowed = (saved, gen)
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Tells clipboard managers to ignore this short-lived entry.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let ours = pb.changeCount

        let element = target.kind == .text && target.pid != getpid() ? target.element : nil
        let bundle = target.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier } ?? ""
        let slow = slowPasteApps.contains { bundle.hasPrefix($0) }
        let before = element.flatMap(fieldState)

        guard let v = commandV() else { return }
        v.down.post(tap: .cghidEventTap)
        v.up.post(tap: .cghidEventTap)

        let restore = {
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
        let fallback: TimeInterval = slow ? 5 : (element == nil ? 1.5 : 3)
        guard let element, let before, !slow else {
            DispatchQueue.main.asyncAfter(deadline: .now() + fallback, execute: restore)
            return
        }
        // Watch the field (off the main thread: the app answers in its own time) until the text shows up.
        DispatchQueue.global(qos: .userInitiated).async {
            let start = Date()
            var landed = false
            while Date().timeIntervalSince(start) < fallback {
                Thread.sleep(forTimeInterval: 0.05)
                if let now = fieldState(element), now != before { landed = true; break }
            }
            // The app has read the clipboard once the text shows; a moment more for apps that read it twice.
            DispatchQueue.main.asyncAfter(deadline: .now() + (landed ? 0.25 : 0)) {
                if !landed { Log.shared("paste: no change seen in the field after \(Int(fallback)) s; clipboard restored anyway") }
                restore()
            }
        }
    }
}
