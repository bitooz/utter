import Foundation

/// Appends timestamped lines to ~/Library/Logs/Utter/utter.log (and stderr).
/// Holds timings and errors, not what was said: block texts appear only as their length (unless `UtterLogTranscripts` is on).
/// Past `maxBytes` the log moves to utter.old.log (replacing the one before) and starts over.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    public static let maxBytes = 1_000_000
    public let url: URL
    private let q = DispatchQueue(label: "utter.log")
    private var handle: FileHandle?
    private let fmt: DateFormatter

    /// Debug setting: put each dictation's text in the log too.
    public static var logsTranscripts: Bool { UserDefaults.standard.bool(forKey: "UtterLogTranscripts") }

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Utter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("utter.log")
        Self.rotate(url, old: dir.appendingPathComponent("utter.old.log"))
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }

    public func callAsFunction(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        q.async { [self] in
            handle?.write(Data(line.utf8))
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    static func rotate(_ url: URL, old: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxBytes else { return }
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// Takes the dictated text out of log lines written before it was left out ("got block #0 in 900ms from X: <text>"
    /// becomes "…: 42 chars"). Rewrites the log files once, then does nothing (no line left to change).
    public func scrubTranscripts() {
        q.sync { [self] in
            for file in [url, url.deletingLastPathComponent().appendingPathComponent("utter.old.log")] {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let clean = Self.scrubbed(text)
                guard clean != text else { continue }
                try? clean.write(to: file, atomically: true, encoding: .utf8)
                if file == url { // the open handle points at the replaced file
                    handle = try? FileHandle(forWritingTo: url)
                    handle?.seekToEndOfFile()
                }
            }
        }
    }

    private static let transcriptLine = try! NSRegularExpression(
        pattern: #"^(.*\bgot (?:block|spec|tail) #\d+ in \d+ms(?: from [^:\n]+)?): (?!\d+ chars$)(.*)$"#, options: [.anchorsMatchLines])

    public static func scrubbed(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in transcriptLine.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += ns.substring(with: m.range(at: 1)) + ": \((ns.substring(with: m.range(at: 2))).count) chars"
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
