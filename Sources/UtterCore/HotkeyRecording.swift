import Foundation

/// What the hotkey recorder makes of the keys pressed: fed modifier changes and key presses, it returns the hotkey
/// once one is complete. Pure, so it can be tested without a keyboard.
///
/// - One modifier pressed and released alone → `.modifier` (with its side: Left ⌥, Right ⌘…; fn has none).
/// - Two or more modifiers held together and released → `.chord` (fn ⇧, ⇧⌘…), recorded once all are let go.
/// - Modifiers and a regular key → `.combo` (⌃⌥D), or a reason it can't be one.
public struct HotkeyRecording {
    /// Every modifier held at once during this press (either side).
    private var peak: UInt64 = 0
    /// The first modifier pressed, with its side, while it was the only one.
    private var single: ModifierKey?
    /// A regular key was pressed: the release of the modifiers records nothing more.
    private var keyUsed = false

    public init() {}

    public enum Outcome: Equatable { case hotkey(Hotkey), problem(String), cancel }

    /// What is held right now, for the field to show while recording ("fn ⇧").
    public static func liveText(_ flags: UInt64) -> String { Hotkey.chordText(flags & ModifierKey.allFamilies) }

    /// A modifier went down or up. `keyCode`: the modifier's key; `flags`: the flags after the change.
    public mutating func flagsChanged(keyCode: Int, flags: UInt64) -> Outcome? {
        let held = flags & ModifierKey.allFamilies
        if held & ~peak != 0 {
            let wasEmpty = peak == 0
            peak |= held
            if wasEmpty, Hotkey.modifierCount(held) == 1 { single = ModifierKey(keyCode: keyCode) ?? Self.key(for: held) }
        }
        guard held == 0 else { return nil }
        defer { peak = 0; single = nil; keyUsed = false }
        if keyUsed || peak == 0 { return nil }
        if Hotkey.modifierCount(peak) == 1 { return single.map { .hotkey(.modifier($0)) } }
        return .hotkey(.chord(modifiers: peak))
    }

    /// A regular key went down with these flags.
    public mutating func keyDown(keyCode: Int, flags: UInt64, label: String) -> Outcome {
        keyUsed = true
        let mods = flags & Hotkey.comboMasks
        if keyCode == 53, mods == 0 { return .cancel } // Esc: keep the old one
        if let problem = Hotkey.problem(keyCode: keyCode, modifiers: mods) { return .problem(problem) }
        return .hotkey(.combo(keyCode: keyCode, modifiers: mods, key: label))
    }

    private static func key(for mask: UInt64) -> ModifierKey? {
        ModifierKey.allCases.first { $0.familyMask == mask && $0 == $0.family }
    }
}
