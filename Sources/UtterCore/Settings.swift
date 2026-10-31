import Foundation

/// The user's choices, kept in UserDefaults. Read at the start of every dictation, so changes apply to the next one.
/// `UTTER_DEFAULTS_SUITE` points Utter at another defaults domain (a fresh first launch without touching the real one).
public enum Settings {
    public static let store: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["UTTER_DEFAULTS_SUITE"], let d = UserDefaults(suiteName: suite) { return d }
        return .standard
    }()

    private enum Key {
        static let mode = "UtterEngineMode" // the old menu choice, read only to tell an earlier install
        static let autoAfter = "UtterAutoAccurateAfter"
        static let prompt = "UtterSystemPrompt"
        static let extra = "UtterExtraInstructions"
        static let hold = "UtterHoldHotkey"
        static let handsFree = "UtterHandsFreeHotkey"
        static let onboarded = "UtterOnboarded"
        static let keyPerMode = "UtterKeyPerMode"
        static func model(_ t: Tier) -> String { "UtterModel." + t.rawValue }
        static func modeHotkey(_ m: Mode) -> String { "UtterModeHotkey." + m.rawValue }
    }

    /// In Auto, dictations at least this long (seconds) use the Accurate model.
    public static var autoAccurateAfter: Double {
        get { let v = store.double(forKey: Key.autoAfter); return v > 0 ? v : 20 }
        set { store.set(newValue, forKey: Key.autoAfter) }
    }

    public static func model(_ tier: Tier) -> Model {
        let id = store.string(forKey: Key.model(tier))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? tier.defaultModel : Model(id)
    }

    public static func setModel(_ model: Model?, for tier: Tier) {
        if let model, !model.id.isEmpty, model != tier.defaultModel { store.set(model.id, forKey: Key.model(tier)) }
        else { store.removeObject(forKey: Key.model(tier)) }
    }

    public static var models: ModelSet {
        ModelSet(fast: model(.fast), accurate: model(.accurate), veryAccurate: model(.veryAccurate))
    }

    /// The system prompt: the user's own, or `Transcriber.defaultSystemPrompt`. Setting the default (or "") clears it.
    public static var systemPrompt: String {
        get {
            let s = store.string(forKey: Key.prompt) ?? ""
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Transcriber.defaultSystemPrompt : s
        }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty || t == Transcriber.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                store.removeObject(forKey: Key.prompt)
            } else {
                store.set(newValue, forKey: Key.prompt)
            }
        }
    }

    public static var isDefaultSystemPrompt: Bool { store.string(forKey: Key.prompt) == nil }

    /// Older hidden setting, still appended to the prompt.
    public static var extraInstructions: String { store.string(forKey: Key.extra) ?? "" }

    /// A mode's key: hold it to talk in that mode, double-tap it (or press a combination quickly) for hands-free.
    /// A mode without one can't be started. New installs give Auto fn and the others none.
    public static func modeHotkey(_ mode: Mode) -> Hotkey? { hotkey(Key.modeHotkey(mode)) }

    public static func setModeHotkey(_ h: Hotkey?, for mode: Mode) {
        if let h { setHotkey(h, Key.modeHotkey(mode)) } else { store.removeObject(forKey: Key.modeHotkey(mode)) }
    }

    /// Every mode's key by name ("Auto's key"), for `Hotkey.clashes` and `Hotkey.sideNotes`.
    public static var namedHotkeys: [(name: String, hotkey: Hotkey?)] {
        Mode.allCases.map { ("\($0.title)'s key", modeHotkey($0)) }
    }

    /// Modes that have a key, in menu order.
    public static var startableModes: [Mode] { Mode.allCases.filter { modeHotkey($0) != nil } }

    private static func hotkey(_ key: String) -> Hotkey? {
        store.data(forKey: key).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
    }

    private static func setHotkey(_ h: Hotkey, _ key: String) {
        if let d = try? JSONEncoder().encode(h) { store.set(d, forKey: key) }
    }

    /// Once, before anything reads the keys: moves to one key per mode. Before, a main key (hold, plus a hands-free key)
    /// dictated in the mode chosen in the menu, and mode keys were extra. That main key becomes Auto's key; installs
    /// that never saved one used ⌥ Option. A new install gets fn for Auto. Mode keys already set stay as they are.
    public static func migrateToKeyPerMode() {
        guard store.object(forKey: Key.keyPerMode) == nil else { return }
        defer { store.set(true, forKey: Key.keyPerMode) }
        guard modeHotkey(.auto) == nil else { return }
        let earlier = [Key.mode, Key.onboarded, Key.prompt, Key.autoAfter, "UtterKeepRecordings"].contains { store.object(forKey: $0) != nil }
            || Tier.allCases.contains { store.object(forKey: Key.model($0)) != nil }
            || Mode.allCases.contains { store.object(forKey: Key.modeHotkey($0)) != nil }
        let main = hotkey(Key.hold) ?? (earlier ? .modifier(.option) : Hotkey.defaultAutoKey)
        // Unless another mode already owns that very key: then Auto starts without one.
        if !Mode.allCases.contains(where: { modeHotkey($0) == main }) { setModeHotkey(main, for: .auto) }
    }

    /// The first-run setup was finished (or skipped) once.
    public static var onboarded: Bool {
        get { store.bool(forKey: Key.onboarded) }
        set { store.set(newValue, forKey: Key.onboarded) }
    }
}
