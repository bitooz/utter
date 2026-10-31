import Foundation

/// A modifier key used on its own as a hotkey: held to talk, or double-tapped for hands-free.
/// The plain cases (`.option`, …) accept either side; the others only that key.
public enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case option, leftOption, rightOption
    case command, leftCommand, rightCommand
    case control, leftControl, rightControl
    case shift, leftShift, rightShift
    case fn

    // CGEventFlags bits, kept here as raw values so the core needs no CoreGraphics.
    public static let shiftMask: UInt64 = 0x20000, controlMask: UInt64 = 0x40000, optionMask: UInt64 = 0x80000
    public static let commandMask: UInt64 = 0x100000, fnMask: UInt64 = 0x800000
    static let familyMasks: [UInt64] = [shiftMask, controlMask, optionMask, commandMask, fnMask]
    /// All five modifier flags (either side), for chords.
    public static let allFamilies: UInt64 = shiftMask | controlMask | optionMask | commandMask | fnMask

    /// The same key, either side.
    public var family: ModifierKey {
        switch familyMask {
        case Self.optionMask: return .option
        case Self.commandMask: return .command
        case Self.controlMask: return .control
        case Self.shiftMask: return .shift
        default: return .fn
        }
    }

    /// The family's device-independent flag.
    public var familyMask: UInt64 {
        switch self {
        case .option, .leftOption, .rightOption: return Self.optionMask
        case .command, .leftCommand, .rightCommand: return Self.commandMask
        case .control, .leftControl, .rightControl: return Self.controlMask
        case .shift, .leftShift, .rightShift: return Self.shiftMask
        case .fn: return Self.fnMask
        }
    }

    /// Device-dependent bit (NX_DEVICE…KEYMASK) for one side, nil for either side.
    var sideMask: UInt64? {
        switch self {
        case .leftControl: return 0x1
        case .leftShift: return 0x2
        case .rightShift: return 0x4
        case .leftCommand: return 0x8
        case .rightCommand: return 0x10
        case .leftOption: return 0x20
        case .rightOption: return 0x40
        case .rightControl: return 0x2000
        default: return nil
        }
    }

    /// The other side's bit: holding it too means a shortcut, not this hotkey.
    var otherSideMask: UInt64? {
        switch self {
        case .leftControl: return 0x2000
        case .rightControl: return 0x1
        case .leftShift: return 0x4
        case .rightShift: return 0x2
        case .leftCommand: return 0x10
        case .rightCommand: return 0x8
        case .leftOption: return 0x40
        case .rightOption: return 0x20
        default: return nil
        }
    }

    /// Only one side (Left ⌥, Right ⌘…), not either.
    public var isOneSide: Bool { sideMask != nil }

    /// The same key on the other side of the keyboard, for a one-side key.
    public var otherSide: ModifierKey? {
        switch self {
        case .leftOption: return .rightOption
        case .rightOption: return .leftOption
        case .leftCommand: return .rightCommand
        case .rightCommand: return .leftCommand
        case .leftControl: return .rightControl
        case .rightControl: return .leftControl
        case .leftShift: return .rightShift
        case .rightShift: return .leftShift
        default: return nil
        }
    }

    /// Does a hotkey for one side (Left ⌥) take presses from this either-side hotkey (⌥)? It does: the more specific wins.
    public func yields(to other: ModifierKey) -> Bool {
        !isOneSide && other.isOneSide && other.familyMask == familyMask
    }

    /// Is this key down, given an event's flags?
    public func isDown(_ flags: UInt64) -> Bool {
        guard flags & familyMask != 0 else { return false }
        return sideMask.map { flags & $0 != 0 } ?? true
    }

    /// Is nothing but this key held?
    public func isAlone(_ flags: UInt64) -> Bool {
        for m in Self.familyMasks where m != familyMask && flags & m != 0 { return false }
        if let o = otherSideMask, flags & o != 0 { return false }
        return true
    }

    /// The key a flagsChanged event with this virtual key code is about.
    public init?(keyCode: Int) {
        switch keyCode {
        case 58: self = .leftOption
        case 61: self = .rightOption
        case 55: self = .leftCommand
        case 54: self = .rightCommand
        case 59: self = .leftControl
        case 62: self = .rightControl
        case 56: self = .leftShift
        case 60: self = .rightShift
        case 63, 179: self = .fn // 179: the fn key on newer keyboards
        default: return nil
        }
    }

    public var symbol: String {
        switch familyMask {
        case Self.optionMask: return "⌥"
        case Self.commandMask: return "⌘"
        case Self.controlMask: return "⌃"
        case Self.shiftMask: return "⇧"
        default: return "fn"
        }
    }

    /// "⌥ Option", "Right ⌘ Command", "fn".
    public var title: String {
        let base: String
        switch familyMask {
        case Self.optionMask: base = "⌥ Option"
        case Self.commandMask: base = "⌘ Command"
        case Self.controlMask: base = "⌃ Control"
        case Self.shiftMask: base = "⇧ Shift"
        default: return "fn"
        }
        switch self {
        case .leftOption, .leftCommand, .leftControl, .leftShift: return "Left " + base
        case .rightOption, .rightCommand, .rightControl, .rightShift: return "Right " + base
        default: return base
        }
    }

    /// Short form for hints: "⌥", "right ⌘", "fn".
    public var short: String {
        switch self {
        case .leftOption, .leftCommand, .leftControl, .leftShift: return "left " + symbol
        case .rightOption, .rightCommand, .rightControl, .rightShift: return "right " + symbol
        default: return symbol
        }
    }
}

/// A dictation hotkey: a modifier on its own, or a key with modifiers (a combination).
///
/// Each mode has at most one. Hold it to talk; double-tap a modifier (or press a combination quickly) for hands-free,
/// and the same key again finishes.
public enum Hotkey: Codable, Equatable, Sendable {
    case modifier(ModifierKey)
    /// `keyCode`: virtual key code; `modifiers`: CGEventFlags bits (⌘⌃⌥⇧); `key`: how the key is shown.
    case combo(keyCode: Int, modifiers: UInt64, key: String)
    /// Two or more modifiers held together, no other key (fn ⇧, ⇧⌘): `modifiers` are their flags (either side).
    case chord(modifiers: UInt64)

    /// Auto's key on a new install: fn on its own, like Wispr Flow, a key nothing else uses while typing.
    public static let defaultAutoKey = Hotkey.modifier(.fn)

    public static let comboMasks: UInt64 = ModifierKey.commandMask | ModifierKey.controlMask | ModifierKey.optionMask | ModifierKey.shiftMask

    public var modifierKey: ModifierKey? { if case .modifier(let m) = self { return m }; return nil }

    /// "⌃⌥Space".
    public static func comboText(_ modifiers: UInt64, _ key: String) -> String {
        var s = ""
        if modifiers & ModifierKey.controlMask != 0 { s += "⌃" }
        if modifiers & ModifierKey.optionMask != 0 { s += "⌥" }
        if modifiers & ModifierKey.shiftMask != 0 { s += "⇧" }
        if modifiers & ModifierKey.commandMask != 0 { s += "⌘" }
        return s + key
    }

    /// As it reads in a hotkey field. `handsFree` names the double tap.
    public func title(handsFree: Bool) -> String {
        switch self {
        case .modifier(let m): return handsFree ? "Double-tap \(m.title)" : m.title
        case .combo(_, let mods, let key): return Self.comboText(mods, key)
        case .chord(let mods): return (handsFree ? "Double-tap " : "") + Self.chordText(mods)
        }
    }

    /// "⇧⌘", "fn ⇧", "fn ⌃⌥".
    public static func chordText(_ mods: UInt64) -> String {
        let rest = comboText(mods & comboMasks, "")
        return mods & ModifierKey.fnMask != 0 ? (rest.isEmpty ? "fn" : "fn " + rest) : rest
    }

    /// How many modifiers a chord holds.
    public static func modifierCount(_ mods: UInt64) -> Int {
        ModifierKey.familyMasks.filter { mods & $0 != 0 }.count
    }

    /// "Hold fn to talk, let go to paste".
    public static func holdHint(_ h: Hotkey) -> String {
        switch h {
        case .modifier(let m): return "Hold \(m.short) to talk, let go to paste"
        case .combo, .chord: return "Hold \(h.title(handsFree: false)) to talk, let go to paste"
        }
    }

    /// "Double-tap fn for hands-free, tap fn to finish".
    public static func handsFreeHint(_ h: Hotkey) -> String {
        switch h {
        case .modifier(let m): return "Double-tap \(m.short) for hands-free, tap \(m.short) to finish"
        case .chord(let mods): return "Double-tap \(chordText(mods)) for hands-free, tap it to finish"
        case .combo: return "Press \(h.title(handsFree: true)) quickly for hands-free, press it again to finish"
        }
    }

    /// What the HUD shows while hands-free: how to finish.
    public static func finishHint(_ h: Hotkey) -> String {
        switch h {
        case .modifier(let m): return "tap \(m.short)"
        case .chord(let mods): return "tap \(chordText(mods))"
        case .combo: return h.title(handsFree: true)
        }
    }

    /// Why a combination can't be a hotkey, or nil if it can. Plain typing keys need ⌘, ⌃ or ⌥ so typing still works.
    public static func problem(keyCode: Int, modifiers: UInt64) -> String? {
        let fKeys: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        if keyCode == 53 { return "Esc cancels a dictation, so it can't start one." }
        if fKeys.contains(keyCode) { return nil }
        let strong = ModifierKey.commandMask | ModifierKey.controlMask | ModifierKey.optionMask
        return modifiers & strong == 0 ? "Add ⌘, ⌃ or ⌥ to that key, or use modifiers only (fn, ⇧⌘…)." : nil
    }

    /// Names for keys that don't print a character.
    public static func keyName(_ keyCode: Int) -> String? {
        let names: [Int: String] = [
            49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete", 117: "⌦", 53: "Esc",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        ]
        return names[keyCode]
    }
}

extension Hotkey {
    /// Do the two press the same key(s)? "⌥ Option" (either side) overlaps "Right ⌥ Option".
    public func overlaps(_ other: Hotkey) -> Bool {
        switch (self, other) {
        case (.modifier(let a), .modifier(let b)):
            return a.familyMask == b.familyMask && (a.sideMask == nil || b.sideMask == nil || a == b)
        case (.combo(let k1, let m1, _), .combo(let k2, let m2, _)):
            return k1 == k2 && m1 == m2
        case (.chord(let a), .chord(let b)):
            return a == b
        default:
            return false
        }
    }

    /// Clashes among named keys (one per mode), as sentences: two modes on the same key, where only the first works.
    /// An either-side key next to a one-side key of the same modifier is not a clash (see `sideNotes`).
    public static func clashes(_ named: [(name: String, hotkey: Hotkey?)]) -> [String] {
        var out: [String] = []
        for i in named.indices {
            guard let a = named[i].hotkey else { continue }
            for j in named.indices where j > i {
                guard let b = named[j].hotkey, a.overlaps(b) else { continue }
                if Self.sideSplit(a, b) != nil { continue } // the one-side key wins its side
                let first = named[i].name
                if a == b {
                    out.append("\(first) and \(named[j].name) are both \(a.title(handsFree: false)): only \(first) works.")
                } else {
                    out.append("\(first) (\(a.title(handsFree: false))) and \(named[j].name) (\(b.title(handsFree: false))) share a key.")
                }
            }
        }
        return out
    }

    /// Either-side and one-side hotkeys on the same modifier (⌥ Option and Left ⌥ Option): (either, one side).
    static func sideSplit(_ a: Hotkey, _ b: Hotkey) -> (ModifierKey, ModifierKey)? {
        guard let x = a.modifierKey, let y = b.modifierKey else { return nil }
        if x.yields(to: y) { return (x, y) }
        if y.yields(to: x) { return (y, x) }
        return nil
    }

    /// What happens where an either-side hotkey meets a one-side one: the one side goes to the specific hotkey,
    /// and the general one keeps only the other side. One sentence per overlap, in the same order as `clashes`.
    public static func sideNotes(_ named: [(name: String, hotkey: Hotkey?)]) -> [String] {
        var out: [String] = []
        for i in named.indices {
            guard let a = named[i].hotkey else { continue }
            for j in named.indices where j > i {
                guard let b = named[j].hotkey else { continue }
                guard let (either, side) = sideSplit(a, b) else { continue }
                let aName = named[i].name
                let (eitherName, sideName) = a.modifierKey == either ? (aName, named[j].name) : (named[j].name, aName)
                let rest = side.otherSide?.title ?? "The other side"
                out.append("\(side.title) is \(sideName); \(rest) stays with \(eitherName).")
            }
        }
        return out.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// A macOS shortcut this combination would take over, if it is a well-known one.
    public var systemConflict: String? {
        guard case .combo(let code, let mods, _) = self else { return nil }
        let cmd = ModifierKey.commandMask, ctrl = ModifierKey.controlMask
        switch (code, mods) {
        case (49, cmd): return "⌘Space opens Spotlight."
        case (49, ctrl): return "⌃Space switches input sources."
        case (49, ctrl | cmd): return "⌃⌘Space opens the emoji picker."
        case (48, cmd): return "⌘Tab switches apps."
        default:
            if mods == cmd, Hotkey.keyName(code) == nil { return "⌘ with a letter is usually an app's own shortcut." }
            return nil
        }
    }
}
