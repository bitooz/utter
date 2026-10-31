import Foundation

/// What macOS does with the fn key on its own: System Settings › Keyboard, the fn key's own setting.
/// Anything but "Do Nothing" (emoji picker, input source, Apple Dictation) fires alongside Utter when Fn is the talk key.
public enum FnKey {
    public enum Action: Int {
        case doNothing = 0, changeInputSource = 1, showEmoji = 2, startDictation = 3

        public var title: String {
            switch self {
            case .doNothing: return "Do Nothing"
            case .changeInputSource: return "Change Input Source"
            case .showEmoji: return "Show Emoji & Symbols"
            case .startDictation: return "Start Dictation"
            }
        }
    }

    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString

    /// The current choice. Unset means macOS's default, which is not "Do Nothing".
    public static var action: Action? {
        CFPreferencesAppSynchronize(domain)
        guard let n = CFPreferencesCopyAppValue(key, domain) as? Int else { return nil }
        return Action(rawValue: n)
    }

    public static var isFree: Bool { action == .doNothing }

    /// Sets the fn key's action to "Do Nothing", the same preference System Settings writes. Returns whether it stuck.
    @discardableResult
    public static func setDoNothing() -> Bool {
        CFPreferencesSetAppValue(key, NSNumber(value: Action.doNothing.rawValue), domain)
        CFPreferencesAppSynchronize(domain)
        return isFree
    }
}
