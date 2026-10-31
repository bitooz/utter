import Foundation

/// The user's word list (names, products, jargon), one entry per line in a plain text file they can edit.
/// It is read again before every dictation, so edits apply right away.
public enum Vocabulary {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Utter/vocabulary.txt")

    static let seed = """
    # Utter vocabulary: names and terms Gemini should spell exactly as written here.
    # One per line. Lines starting with # are ignored. Changes apply to the next dictation.
    Filo
    Utter
    Retype
    Claude Code
    OpenRouter
    Gemini

    """

    /// Creates the file with the starting list if there is none yet.
    @discardableResult
    public static func ensureFile() -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? seed.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// The file as written, for editing in Settings.
    public static var text: String {
        get { ensureFile(); return (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        set { ensureFile(); try? newValue.write(to: url, atomically: true, encoding: .utf8) }
    }

    public static func load() -> [String] { parse(text) }

    /// The text with these terms added at the end (comma-separated input gives several; ones already there are skipped).
    public static func adding(_ input: String, to text: String) -> String {
        var have = Set(parse(text).map { $0.lowercased() })
        var out = text
        for t in input.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !t.isEmpty && !t.hasPrefix("#") {
            guard have.insert(t.lowercased()).inserted else { continue }
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            out += t + "\n"
        }
        return out
    }

    /// The text without this term (every line that is exactly it, ignoring case); notes and other lines stay as written.
    public static func removing(_ term: String, from text: String) -> String {
        let key = term.trimmingCharacters(in: .whitespaces).lowercased()
        let lines = text.components(separatedBy: "\n")
        return lines.filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != key }.joined(separator: "\n")
    }

    /// Entries in a vocabulary text: one per line, # comments and repeats dropped.
    public static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && seen.insert($0.lowercased()).inserted }
    }
}
