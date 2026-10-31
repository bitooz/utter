import AppKit
import CoreGraphics
import UtterCore

/// What a hotkey press means to the controller.
struct Trigger {
    enum Kind { case holdBegan, holdEnded, holdTapped, holdInterrupted, handsFree, finish }
    var kind: Kind
    /// The mode whose key fired.
    var mode: Mode
    /// The hotkey that fired (for the HUD's "how to finish" hint).
    var hotkey: Hotkey?
}

/// Watches the dictation hotkeys system-wide with a CGEvent tap.
///
/// Each mode has its own key.
/// - A modifier on its own (fn by default, for Auto) goes through `ModifierGesture`: hold to talk, double-tap for hands-free.
///   The key and every shortcut that uses it pass through untouched.
/// - A key combination starts at once when pressed; let go to finish, or let go quickly to keep going hands-free.
///   Its key presses are swallowed so they don't type.
/// - Escape is swallowed only while `escapeActive` is set (cancel, while recording or writing).
/// - Events Utter posts itself (the ⌘V of a paste) go through untouched and change nothing.
/// Needs Accessibility permission.
final class HotkeyTap {
    static let escapeKey: Int64 = 53  // kVK_Escape

    var onTrigger: (Trigger) -> Void = { _ in }
    /// A watched modifier (or chord) went down alone: a dictation may follow (warms the connection, starts the mic early).
    var onArm: () -> Void = {}
    var onEscape: () -> Void = {}
    /// Set by the controller while recording or writing.
    var escapeActive = false
    /// Set while a hotkey field is recording: every key goes through and nothing starts.
    var paused = false { didSet { if paused != oldValue { reset() } } }

    /// A modifier key and the mode it starts (hold it, or double-tap it for hands-free).
    private struct Watch {
        var key: ModifierKey
        var mode: Mode
        var gesture = ModifierGesture()
    }
    private struct Combo { var keyCode: Int; var modifiers: UInt64; var mode: Mode; var hotkey: Hotkey }
    /// Two or more modifiers held together (fn ⇧, ⇧⌘): down while exactly these are held, up when any is let go.
    private struct Chord {
        var modifiers: UInt64
        var mode: Mode
        /// False once another modifier joined while the chord's keys were down: the chord counts again only after all
        /// its keys are let go (letting go of ⌥ in ⌥⇧⌘ doesn't make it a ⇧⌘ press).
        var armed = true
        var gesture: ModifierGesture = {
            var g = ModifierGesture()
            g.doubleTapGap = 0.5 // two keys to let go and press again
            return g
        }()
    }
    private var chords: [Chord] = []

    private var tap: CFMachPort?
    private var watches: [Watch] = []
    private var combos: [Combo] = []
    private var heldCombo: (combo: Combo, at: TimeInterval)?
    private var swallowUp = Set<Int>()
    private var bindings: [(Mode, Hotkey)] = []

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    /// Which modifiers are down right now (replaced in `HotkeyCheck`, which has no real keyboard).
    var currentFlags: () -> UInt64 = { CGEventSource.flagsState(.combinedSessionState).rawValue }

    /// Sets each mode's key. Where two modes share a key, the earlier one wins.
    func configure(_ bindings: [(Mode, Hotkey)]) {
        self.bindings = bindings
        watches = []
        combos = []
        chords = []
        for (mode, hotkey) in bindings {
            switch hotkey {
            case .chord(let mods):
                if !chords.contains(where: { $0.modifiers == mods }) { chords.append(Chord(modifiers: mods, mode: mode)) }
            case .modifier(let key):
                if !watches.contains(where: { $0.key == key }) { watches.append(Watch(key: key, mode: mode)) }
            case .combo(let code, let mods, _):
                if !combos.contains(where: { $0.keyCode == code && $0.modifiers == mods }) {
                    combos.append(Combo(keyCode: code, modifiers: mods, mode: mode, hotkey: hotkey))
                }
            }
        }
        heldCombo = nil
    }

    private func reset() { configure(bindings) }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ctx in
                let me = Unmanaged<HotkeyTap>.fromOpaque(ctx!).takeUnretainedValue()
                return me.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // Runs on the main run loop for every key press, click and scroll in the session: keep it tiny.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            resync()
            return Unmanaged.passUnretained(event)
        }
        // Utter's own ⌘V (a paste): not the user's input, so it neither breaks a held key nor triggers anything.
        if paused || Paster.isOwn(event) { return Unmanaged.passUnretained(event) }
        switch type {
        case .flagsChanged:
            let flags = event.flags.rawValue
            for i in watches.indices {
                let key = watches[i].key
                // A hotkey for one side (Left ⌥) claims that side from a hotkey for either side (⌥): the general one
                // doesn't see the press at all, so it neither starts nor breaks anything.
                let claimed = watches.contains { key.yields(to: $0.key) && $0.key.isDown(flags) }
                let down = key.isDown(flags) && !claimed, alone = key.isAlone(flags)
                if down && !watches[i].gesture.isDown {
                    emit(i, watches[i].gesture.optionDown(alone: alone, at: now))
                    if alone && watches[i].gesture.isDown {
                        DispatchQueue.main.async(execute: onArm)
                        scheduleHoldTimer(i)
                    }
                } else if !down && watches[i].gesture.isDown {
                    emit(i, watches[i].gesture.optionUp(at: now))
                } else if !alone || !down {
                    // Another modifier went down or up: the key is part of a shortcut, or it breaks a double tap.
                    emit(i, watches[i].gesture.otherInput(at: now))
                }
            }
            // Chords: exactly their modifiers held. A modifier outside the chord makes it a shortcut; letting go of
            // the chord's own keys one by one doesn't (so a double tap survives the release).
            let held = flags & ModifierKey.allFamilies
            for i in chords.indices {
                let mods = chords[i].modifiers
                let full = held == mods
                if held & mods == 0 { chords[i].armed = true }
                if held & ~mods != 0 && held & mods != 0 { chords[i].armed = false }
                if full && !chords[i].gesture.isDown && chords[i].armed {
                    emitChord(i, chords[i].gesture.optionDown(alone: true, at: now))
                    if chords[i].gesture.isDown {
                        DispatchQueue.main.async(execute: onArm)
                        scheduleChordTimer(i)
                    }
                } else if !full && chords[i].gesture.isDown {
                    if held & ~mods != 0 { emitChord(i, chords[i].gesture.otherInput(at: now)) }
                    emitChord(i, chords[i].gesture.optionUp(at: now))
                } else if held & ~mods != 0 {
                    emitChord(i, chords[i].gesture.otherInput(at: now))
                }
            }
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if escapeActive, code == Self.escapeKey {
                DispatchQueue.main.async(execute: onEscape)
                return nil
            }
            for i in watches.indices { emit(i, watches[i].gesture.otherInput(at: now)) }
            for i in chords.indices { emitChord(i, chords[i].gesture.otherInput(at: now)) } // ⇧⌘4 is a shortcut
            let mods = event.flags.rawValue & Hotkey.comboMasks
            if let c = combos.first(where: { $0.keyCode == code && $0.modifiers == mods }) {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { comboDown(c) }
                swallowUp.insert(code)
                return nil
            }
        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if let h = heldCombo, h.combo.keyCode == code {
                heldCombo = nil
                // Let go quickly: that was a press, not a hold, so keep listening hands-free.
                send(now - h.at < ModifierGesture().holdDelay ? .holdTapped : .holdEnded, h.combo)
            }
            if swallowUp.remove(code) != nil { return nil }
        default: // clicks and scrolls
            for i in watches.indices { emit(i, watches[i].gesture.otherInput(at: now)) }
            for i in chords.indices { emitChord(i, chords[i].gesture.otherInput(at: now)) }
        }
        return Unmanaged.passUnretained(event)
    }

    private func comboDown(_ c: Combo) {
        heldCombo = (c, now)
        send(.holdBegan, c)
    }

    private func send(_ kind: Trigger.Kind, _ c: Combo) {
        let t = Trigger(kind: kind, mode: c.mode, hotkey: c.hotkey)
        DispatchQueue.main.async { [weak self] in self?.onTrigger(t) }
    }

    private func scheduleHoldTimer(_ i: Int) {
        let g = watches[i].gesture.generation
        let key = watches[i].key
        DispatchQueue.main.asyncAfter(deadline: .now() + watches[i].gesture.holdDelay) { [weak self] in
            guard let self, i < watches.count, watches[i].key == key else { return }
            // If the tap missed the key's release (it was briefly disabled), don't start a dictation.
            if currentFlags() & key.familyMask == 0 { resync(); return }
            emit(i, watches[i].gesture.holdTimer(generation: g, at: now))
        }
    }

    private func scheduleChordTimer(_ i: Int) {
        let g = chords[i].gesture.generation
        let mods = chords[i].modifiers
        DispatchQueue.main.asyncAfter(deadline: .now() + chords[i].gesture.holdDelay) { [weak self] in
            guard let self, i < chords.count, chords[i].modifiers == mods else { return }
            if currentFlags() & mods != mods { resync(); return }
            emitChord(i, chords[i].gesture.holdTimer(generation: g, at: now))
        }
    }

    /// Catches up with a release the tap may have missed.
    private func resync() {
        let flags = currentFlags()
        for i in watches.indices where watches[i].gesture.isDown && flags & watches[i].key.familyMask == 0 {
            emit(i, watches[i].gesture.optionUp(at: now))
        }
        for i in chords.indices where chords[i].gesture.isDown && flags & chords[i].modifiers != chords[i].modifiers {
            emitChord(i, chords[i].gesture.optionUp(at: now))
        }
    }

    private func emitChord(_ i: Int, _ events: [ModifierGesture.Event]) {
        let c = chords[i]
        let hotkey = Hotkey.chord(modifiers: c.modifiers)
        for e in events {
            let kind: Trigger.Kind
            switch e {
            case .holdBegan: kind = .holdBegan
            case .holdEnded: kind = .holdEnded
            case .interrupted: kind = .holdInterrupted
            case .tap: kind = .finish
            case .doubleTap: kind = .handsFree
            }
            let t = Trigger(kind: kind, mode: c.mode, hotkey: hotkey)
            DispatchQueue.main.async { [weak self] in self?.onTrigger(t) }
        }
    }

    private func emit(_ i: Int, _ events: [ModifierGesture.Event]) {
        let w = watches[i]
        let hotkey = Hotkey.modifier(w.key)
        for e in events {
            let t: Trigger?
            switch e {
            case .holdBegan: t = Trigger(kind: .holdBegan, mode: w.mode, hotkey: hotkey)
            case .holdEnded: t = Trigger(kind: .holdEnded, mode: w.mode, hotkey: hotkey)
            case .interrupted: t = Trigger(kind: .holdInterrupted, mode: w.mode, hotkey: hotkey)
            case .tap: t = Trigger(kind: .finish, mode: w.mode, hotkey: hotkey)
            case .doubleTap: t = Trigger(kind: .handsFree, mode: w.mode, hotkey: hotkey)
            }
            if let t { DispatchQueue.main.async { [weak self] in self?.onTrigger(t) } }
        }
    }
}
