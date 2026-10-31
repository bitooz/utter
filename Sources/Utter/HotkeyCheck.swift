import AppKit
import UtterCore

/// `Utter --check-hotkeys`: feeds made-up key events straight to a `HotkeyTap` (never posted, no event tap, no window)
/// and prints what each scenario triggered. Checks the hotkey logic without a keyboard.
@MainActor
enum HotkeyCheck {
    static func run() -> Bool {
        let opt: UInt64 = 0x80000, cmd: UInt64 = 0x100000, ctrl: UInt64 = 0x40000
        let leftOpt = opt | 0x20, rightCmd = cmd | 0x10, leftCmd = cmd | 0x8
        let tap = HotkeyTap()
        var flagsNow: UInt64 = 0
        tap.currentFlags = { flagsNow }
        var got: [String] = []
        tap.onTrigger = { t in got.append("\(t.kind)(\(t.mode.title))") }
        var swallowed: [String] = []

        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func flags(_ code: CGKeyCode, _ f: UInt64) {
            flagsNow = f
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
            e.type = .flagsChanged
            e.flags = CGEventFlags(rawValue: f)
            _ = tap.handle(.flagsChanged, e)
        }
        func key(_ code: CGKeyCode, _ down: Bool, _ f: UInt64, label: String) {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
            e.flags = CGEventFlags(rawValue: f)
            if tap.handle(down ? .keyDown : .keyUp, e) == nil { swallowed.append(label + (down ? "↓" : "↑")) }
        }

        var ok = true
        func scenario(_ name: String, expect: [String], swallow: [String] = [], _ body: () -> Void) {
            got = []; swallowed = []
            body()
            wait(0.1)
            let pass = got == expect && swallowed == swallow
            ok = ok && pass
            print("\(pass ? "PASS" : "FAIL") \(name): \(got.joined(separator: ", "))\(swallowed.isEmpty ? "" : " · swallowed \(swallowed.joined(separator: " "))")"
                  + (pass ? "" : "   (expected \(expect.joined(separator: ", ")) · \(swallow.joined(separator: " ")))"))
            wait(0.5) // let double-tap windows expire
        }

        // This user's keys: Auto on ⌥ (either side), Instant fn, Balanced left ⌃, Thorough left ⌥, Thorough also ⌃⌥V.
        let rightOpt = opt | 0x40, leftCtrl = ctrl | 0x1
        tap.configure([(.auto, .modifier(.option)), (.fast, .modifier(.fn)), (.accurate, .modifier(.leftControl)),
                       (.veryAccurate, .modifier(.leftOption))])
        scenario("hold right ⌥ → Auto", expect: ["holdBegan(Auto)", "holdEnded(Auto)"]) { flags(61, rightOpt); wait(0.5); flags(61, 0) }
        scenario("double-tap right ⌥ → Auto hands-free", expect: ["finish(Auto)", "handsFree(Auto)"]) {
            flags(61, rightOpt); wait(0.08); flags(61, 0); wait(0.1); flags(61, rightOpt); wait(0.08); flags(61, 0)
        }
        scenario("hold left ⌥ → Thorough (one side wins over either side)", expect: ["holdBegan(Thorough)", "holdEnded(Thorough)"]) {
            flags(58, leftOpt); wait(0.5); flags(58, 0)
        }
        scenario("double-tap left ⌥ → Thorough hands-free", expect: ["finish(Thorough)", "handsFree(Thorough)"]) {
            flags(58, leftOpt); wait(0.08); flags(58, 0); wait(0.1); flags(58, leftOpt); wait(0.08); flags(58, 0)
        }
        scenario("left ⌥ then right ⌥ is not a double tap", expect: ["finish(Thorough)", "finish(Auto)"]) {
            flags(58, leftOpt); wait(0.08); flags(58, 0); wait(0.1); flags(61, rightOpt); wait(0.08); flags(61, 0)
        }
        scenario("hold fn → Instant", expect: ["holdBegan(Instant)", "holdEnded(Instant)"]) { flags(63, 0x800000); wait(0.5); flags(63, 0) }
        scenario("double-tap fn → Instant hands-free", expect: ["finish(Instant)", "handsFree(Instant)"]) {
            flags(63, 0x800000); wait(0.08); flags(63, 0); wait(0.1); flags(63, 0x800000); wait(0.08); flags(63, 0)
        }
        scenario("hold left ⌃ → Balanced", expect: ["holdBegan(Balanced)", "holdEnded(Balanced)"]) { flags(59, leftCtrl); wait(0.5); flags(59, 0) }
        scenario("hold left ⌘ (no mode's key)", expect: []) { flags(55, leftCmd); wait(0.5); flags(55, 0) }
        scenario("left ⌥← word jump is not a dictation", expect: []) {
            flags(58, leftOpt); key(123, true, leftOpt, label: "←"); key(123, false, leftOpt, label: "←"); flags(58, 0)
        }
        scenario("right ⌥← word jump is not a dictation", expect: []) {
            flags(61, rightOpt); key(123, true, rightOpt, label: "←"); key(123, false, rightOpt, label: "←"); flags(61, 0)
        }
        scenario("fn+↑ (Page Up) is not a dictation", expect: []) {
            flags(63, 0x800000); key(126, true, 0x800000, label: "↑"); key(126, false, 0x800000, label: "↑"); wait(0.4); flags(63, 0)
        }
        scenario("⌘C with left ⌃ held is not a dictation", expect: []) {
            flags(59, leftCtrl); key(8, true, leftCtrl, label: "C"); key(8, false, leftCtrl, label: "C"); flags(59, 0)
        }
        scenario("Utter's own ⌘V (a paste) while fn is held doesn't break the hold", expect: ["holdBegan(Instant)", "holdEnded(Instant)"]) {
            flags(63, 0x800000); wait(0.45)
            if let v = Paster.commandV() {
                if tap.handle(.keyDown, v.down) == nil { swallowed.append("own ⌘V↓") }
                if tap.handle(.keyUp, v.up) == nil { swallowed.append("own ⌘V↑") }
            }
            wait(0.05); flags(63, 0)
        }
        scenario("the user's ⌘V while fn is held is a shortcut", expect: ["holdBegan(Instant)", "holdInterrupted(Instant)"]) {
            flags(63, 0x800000); wait(0.45); key(9, true, 0x800000 | cmd, label: "V"); key(9, false, 0x800000 | cmd, label: "V"); flags(63, 0)
        }
        scenario("paused while recording a key", expect: []) {
            tap.paused = true; flags(61, rightOpt); wait(0.5); flags(61, 0); tap.paused = false
        }

        // A new install: Auto on fn, no other keys. Modes without a key can't start.
        tap.configure([(.auto, .modifier(.fn))])
        scenario("new install: hold fn → Auto", expect: ["holdBegan(Auto)", "holdEnded(Auto)"]) { flags(63, 0x800000); wait(0.5); flags(63, 0) }
        scenario("new install: hold ⌥ does nothing", expect: []) { flags(58, leftOpt); wait(0.5); flags(58, 0) }

        // Chords: two modifiers held together, beside fn alone and a one-side ⌥.
        let fnF: UInt64 = 0x800000, sh: UInt64 = 0x20000, lsh = sh | 0x2, lcmd = cmd | 0x8
        tap.configure([(.auto, .modifier(.fn)), (.fast, .chord(modifiers: fnF | sh)), (.accurate, .chord(modifiers: sh | cmd)),
                       (.veryAccurate, .modifier(.leftOption))])
        scenario("hold fn then ⇧ → Instant (fn ⇧), not Auto", expect: ["holdBegan(Instant)", "holdEnded(Instant)"]) {
            flags(63, fnF); wait(0.05); flags(56, fnF | lsh); wait(0.5); flags(56, fnF); wait(0.05); flags(63, 0)
        }
        scenario("hold ⇧ then fn → Instant", expect: ["holdBegan(Instant)", "holdEnded(Instant)"]) {
            flags(56, lsh); wait(0.05); flags(63, fnF | lsh); wait(0.5); flags(63, lsh); wait(0.05); flags(56, 0)
        }
        scenario("double-tap fn ⇧ → Instant hands-free", expect: ["finish(Instant)", "handsFree(Instant)"]) {
            flags(63, fnF); flags(56, fnF | lsh); wait(0.08); flags(56, fnF); flags(63, 0); wait(0.15)
            flags(63, fnF); flags(56, fnF | lsh); wait(0.08); flags(56, fnF); flags(63, 0)
        }
        scenario("hold ⇧⌘ → Balanced", expect: ["holdBegan(Balanced)", "holdEnded(Balanced)"]) {
            flags(56, lsh); flags(55, lsh | lcmd); wait(0.5); flags(55, lsh); flags(56, 0)
        }
        scenario("hold fn alone → Auto still", expect: ["holdBegan(Auto)", "holdEnded(Auto)"]) { flags(63, fnF); wait(0.5); flags(63, 0) }
        scenario("⇧⌘4 (screenshot) passes through, nothing starts", expect: []) {
            flags(56, lsh); flags(55, lsh | lcmd); wait(0.05); key(21, true, sh | cmd, label: "4"); key(21, false, sh | cmd, label: "4")
            wait(0.4); flags(55, lsh); flags(56, 0)
        }
        scenario("⇧⌘ then a click is not a dictation", expect: []) {
            flags(56, lsh); flags(55, lsh | lcmd); wait(0.05)
            _ = tap.handle(.leftMouseDown, CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!)
            wait(0.4); flags(55, lsh); flags(56, 0)
        }
        scenario("⌥⇧⌘ (one more than the chord) is not Balanced", expect: []) {
            flags(56, lsh); flags(55, lsh | lcmd); flags(61, lsh | lcmd | opt | 0x40); wait(0.5); flags(61, lsh | lcmd); flags(55, lsh); flags(56, 0)
        }
        scenario("hold ⇧ alone does nothing", expect: []) { flags(56, lsh); wait(0.5); flags(56, 0) }
        scenario("hold left ⌥ → Thorough still", expect: ["holdBegan(Thorough)", "holdEnded(Thorough)"]) { flags(58, leftOpt); wait(0.5); flags(58, 0) }

        // Key combinations: hold to talk, a quick press for hands-free; their keys don't type.
        tap.configure([(.auto, .modifier(.fn)), (.veryAccurate, .combo(keyCode: 9, modifiers: ctrl | opt, key: "V"))])
        scenario("hold ⌃⌥V → Thorough", expect: ["holdBegan(Thorough)", "holdEnded(Thorough)"], swallow: ["V↓", "V↑"]) {
            key(9, true, ctrl | opt, label: "V"); wait(0.5); key(9, false, ctrl | opt, label: "V")
        }
        scenario("press ⌃⌥V quickly → Thorough hands-free", expect: ["holdBegan(Thorough)", "holdTapped(Thorough)"], swallow: ["V↓", "V↑"]) {
            key(9, true, ctrl | opt, label: "V"); wait(0.1); key(9, false, ctrl | opt, label: "V")
        }
        scenario("⌥V types ◊ as usual", expect: []) {
            flags(58, leftOpt); key(9, true, opt, label: "V"); key(9, false, opt, label: "V"); flags(58, 0)
        }
        print(ok ? "ALL PASS" : "SOME FAILED")
        return ok
    }
}
