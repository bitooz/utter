import Foundation

/// A model on OpenRouter that Utter transcribes with, by its OpenRouter id (any audio-input model works).
/// The models Utter ships with carry tuned settings: which Vertex routes to race, and how little to reason.
public struct Model: Hashable, Sendable {
    public let id: String

    public init(_ id: String) { self.id = id.trimmingCharacters(in: .whitespacesAndNewlines) }

    public static let lite = Model("google/gemini-3.1-flash-lite")
    public static let flash = Model("google/gemini-3.8-flash")
    public static let argon = Model("google/gemini-4-argon")

    private struct Tuning { var name: String; var reasoning: [String: Any]; var routes: (primary: String, race: [String])? }

    private static let tuned: [String: Tuning] = [
        lite.id: Tuning(name: "Gemini 3.1 Flash-Lite", reasoning: ["enabled": false],
                        routes: ("google-vertex/global", ["google-vertex/global/priority", "google-vertex/eu"])),
        flash.id: Tuning(name: "Gemini 3.8 Flash", reasoning: ["effort": "minimal", "exclude": true],
                         routes: ("google-vertex/global", ["google-vertex/global/priority", "google-vertex/us"])),
        argon.id: Tuning(name: "Gemini 4 Argon", reasoning: ["effort": "minimal", "exclude": true], // reasoning can't be turned off
                         routes: ("google-vertex/global", ["google-vertex/global/priority", "google-vertex/us"])),
    ]

    /// Names of other models, from OpenRouter's model list (see `OpenRouter.audioModels`).
    public static var knownNames: [String: String] {
        get { namesLock.lock(); defer { namesLock.unlock() }; return _names }
        set { namesLock.lock(); _names = newValue; namesLock.unlock() }
    }
    private static var _names: [String: String] = [:]
    private static let namesLock = NSLock()

    public var name: String {
        if let t = Self.tuned[id] { return t.name }
        if let n = Self.knownNames[id] { return n }
        return id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Other models get the smallest reasoning effort: some can't turn it off, and models without reasoning ignore it.
    var reasoning: [String: Any] { Self.tuned[id]?.reasoning ?? ["effort": "minimal", "exclude": true] }

    /// Pinned first route and the routes raced against it; nil leaves routing to OpenRouter.
    var routes: (primary: String, race: [String])? { Self.tuned[id]?.routes }
}

/// The three model slots the user fills.
public enum Tier: String, CaseIterable, Sendable {
    case fast, accurate, veryAccurate

    public var title: String {
        switch self {
        case .fast: return "Instant"
        case .accurate: return "Balanced"
        case .veryAccurate: return "Thorough"
        }
    }

    public var defaultModel: Model {
        switch self {
        case .fast: return .lite
        case .accurate: return .flash
        case .veryAccurate: return .argon
        }
    }
}

/// The model chosen for each tier.
public struct ModelSet: Sendable, Equatable {
    public var fast: Model, accurate: Model, veryAccurate: Model

    public init(fast: Model = Tier.fast.defaultModel, accurate: Model = Tier.accurate.defaultModel,
                veryAccurate: Model = Tier.veryAccurate.defaultModel) {
        self.fast = fast; self.accurate = accurate; self.veryAccurate = veryAccurate
    }

    public subscript(tier: Tier) -> Model {
        get {
            switch tier {
            case .fast: return fast
            case .accurate: return accurate
            case .veryAccurate: return veryAccurate
            }
        }
        set {
            switch tier {
            case .fast: fast = newValue
            case .accurate: accurate = newValue
            case .veryAccurate: veryAccurate = newValue
            }
        }
    }
}

/// What the Mode menu offers: a tier, or Auto, which picks Fast or Accurate by length.
public enum Mode: String, CaseIterable, Sendable {
    case auto, fast, accurate, veryAccurate

    public static let `default` = Mode.auto

    public var title: String {
        switch self {
        case .auto: return "Auto"
        case .fast: return Tier.fast.title
        case .accurate: return Tier.accurate.title
        case .veryAccurate: return Tier.veryAccurate.title
        }
    }

    /// One line on what the mode does, with the model(s) behind it.
    public func detail(_ models: ModelSet, autoAfter: Double) -> String {
        switch self {
        case .auto: return "Instant under \(Int(autoAfter)) s, Balanced for longer"
        case .fast: return models.fast.name
        case .accurate: return models.accurate.name
        case .veryAccurate: return models.veryAccurate.name
        }
    }

    /// The tier for a dictation (or block) of this many seconds.
    public func tier(forSeconds seconds: Double, autoAfter: Double) -> Tier {
        switch self {
        case .fast: return .fast
        case .accurate: return .accurate
        case .veryAccurate: return .veryAccurate
        case .auto: return seconds >= autoAfter ? .accurate : .fast
        }
    }
}
