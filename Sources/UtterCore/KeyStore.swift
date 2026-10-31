import Foundation

/// The OpenRouter key in the login Keychain (service "OpenRouter", account "dictation").
/// Reads and writes go through /usr/bin/security, which the item trusts, so no Keychain prompt appears;
/// the key is passed on its stdin, never on a command line.
public enum KeyStore {
    public static let service = "OpenRouter"
    public static let account = "dictation"

    public static func openRouterKey() throws -> String {
        let (status, out) = try security(["find-generic-password", "-s", service, "-a", account, "-w"])
        let key = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == 0, !key.isEmpty else { throw KeyError.missing }
        return key
    }

    /// Saves (or replaces) the key.
    public static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // OpenRouter keys are sk-or-… with letters, digits, - and _; anything else would break the command line below.
        guard looksValid(key) else { throw KeyError.malformed }
        let (status, _) = try security(["-i"], stdin: "add-generic-password -U -s \(service) -a \(account) -l \"OpenRouter (Utter)\" -w \(key)\n")
        guard status == 0, (try? openRouterKey()) == key else { throw KeyError.notSaved }
    }

    public static func looksValid(_ key: String) -> Bool {
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return key.count >= 20 && key.unicodeScalars.allSatisfy(ok.contains)
    }

    /// "sk-or-v1-…3f9a", for showing which key is saved.
    public static func masked(_ key: String) -> String {
        key.count > 14 ? "\(key.prefix(9))…\(key.suffix(4))" : String(repeating: "•", count: key.count)
    }

    private static func security(_ args: [String], stdin: String? = nil) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        p.standardInput = input
        try p.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    public enum KeyError: Error, CustomStringConvertible {
        case missing, malformed, notSaved
        public var description: String {
            switch self {
            case .missing: return "No OpenRouter key in Keychain (service \"\(service)\", account \"\(account)\")"
            case .malformed: return "That doesn't look like an OpenRouter key (sk-or-…)."
            case .notSaved: return "Couldn't save the key to Keychain."
            }
        }
    }
}
