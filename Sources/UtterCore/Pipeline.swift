import Foundation

/// One dictation. Short ones (up to `Segmenter.Config.wholeLimit`) go to the model whole, in one request at release.
/// Longer ones are cut into overlapping blocks at real pauses; each block is sent as soon as it is complete,
/// with the text of the earlier blocks as context, and `finish()` joins the texts, dropping words the overlap repeated.
/// A block that fails is tried once more with the Instant model; if it still fails, the others are kept and the gap is marked.
public final class DictationPipeline: @unchecked Sendable {
    public struct Result {
        public var text: String
        public var pieces: Int
        public var audioSeconds: Double
        /// Model(s) whose text was used, e.g. "google/gemini-3.8-flash"; "+"-joined if blocks differed.
        public var model: String
        /// Why the Fast model's text was used in place of the chosen one's, if it was.
        public var fallback: String?
        /// Blocks that failed even after a retry; their place in `text` holds `gapMark`.
        public var gaps: Int
        public init(text: String, pieces: Int, audioSeconds: Double, model: String = "", fallback: String? = nil, gaps: Int = 0) {
            self.text = text; self.pieces = pieces; self.audioSeconds = audioSeconds; self.model = model; self.fallback = fallback
            self.gaps = gaps
        }
    }

    /// Stands in the text for a block that couldn't be transcribed.
    public static let gapMark = "[…]"

    /// One request: a block of audio and what goes with it.
    public struct Request: @unchecked Sendable {
        public var index: Int
        public var audio: EncodedAudio
        public var context: String
        public var overlapsContext: Bool
        public var continues: Bool
        public var model: Model
        public var backup: Model?
        public var slow: Bool
        public var raceAfter: TimeInterval?
    }
    public typealias Send = @Sendable (Request) async throws -> Transcript

    /// How long a block may wait for the earlier blocks' text before it is sent with what has arrived.
    public var contextWait: TimeInterval = 2.5

    private let q = DispatchQueue(label: "utter.pipeline")
    private let seg: Segmenter
    private let send: Send
    private let mode: Mode
    private let models: ModelSet
    private let autoAfter: Double
    private let log: (String) -> Void
    private let logText: Bool
    private let t0 = Date()
    private let texts = BlockTexts()

    // Owned by `q`.
    private var blocks: [Task<Transcript, Error>] = []
    private var finished = false

    /// Latest input level in dBFS, for a meter. Called on the pipeline queue.
    public var onLevel: ((Double) -> Void)?

    /// `logText`: put each block's text in the log (off: only its length).
    public convenience init(transcriber: Transcriber, mode: Mode = .default, models: ModelSet = .init(), autoAccurateAfter: Double = 20,
                            segmenter: Segmenter.Config = .init(), logText: Bool = false, log: @escaping (String) -> Void = { _ in }) {
        self.init(send: { r in
            try await transcriber.transcribe(audio: r.audio, context: r.context, overlapsContext: r.overlapsContext, continues: r.continues,
                                             model: r.model, backup: r.backup, slow: r.slow, raceAfter: r.raceAfter)
        }, mode: mode, models: models, autoAccurateAfter: autoAccurateAfter, segmenter: segmenter, logText: logText, log: log)
    }

    /// With any way of sending a block (the tests use a fake one).
    public init(send: @escaping Send, mode: Mode = .default, models: ModelSet = .init(), autoAccurateAfter: Double = 20,
                segmenter: Segmenter.Config = .init(), logText: Bool = false, log: @escaping (String) -> Void = { _ in }) {
        self.send = send
        self.mode = mode
        self.models = models
        autoAfter = autoAccurateAfter
        seg = Segmenter(config: segmenter)
        self.logText = logText
        self.log = log
    }

    private func ms(_ d: Date = Date()) -> String { String(format: "%5.0fms", d.timeIntervalSince(t0) * 1000) }
    private func sec(_ r: Range<Int>) -> String { String(format: "%.2f–%.2fs", Double(r.lowerBound) / 16000, Double(r.upperBound) / 16000) }

    public func append(_ samples: [Int16]) {
        q.async { [self] in
            guard !finished else { return }
            for r in seg.append(samples) {
                // Sent while the user keeps talking; a second route joins if it is slow.
                // Blocks only exist past 45 s, so this is a long dictation.
                let tier = mode.tier(forSeconds: seg.config.wholeLimit, autoAfter: autoAfter)
                blocks.append(start(r, index: blocks.count, tier: tier, continues: true, raceAfter: 1.5))
            }
            onLevel?(seg.lastLevel)
        }
    }

    /// The tier's model, with the Fast model as its backup when it is a different one.
    private func start(_ r: Range<Int>, index: Int, tier: Tier, continues: Bool = false, raceAfter: TimeInterval?) -> Task<Transcript, Error> {
        let model = models[tier]
        let backup = tier == .fast ? nil : models.fast
        let audio = EncodedAudio.best(seg.samples[r])
        let wait = contextWait
        log("\(ms()) audio block #\(index) \(sec(r)) \(audio.data.count / 1024)KB \(audio.format) → \(model.name)")
        return Task { [self, texts] in
            // Earlier blocks' text goes along as context so names, wording and language stay consistent,
            // and so the model knows where the overlapping audio picks up.
            let waited = Date()
            let (context, hasPrevious) = await texts.context(before: index, maxWait: wait)
            try Task.checkCancellation()
            let started = Date()
            let waitMs = Int(started.timeIntervalSince(waited) * 1000)
            log("\(ms()) send block #\(index)\(waitMs > 5 ? " after \(waitMs)ms context wait" : "") ctx=\(context.count)ch")
            var req = Request(index: index, audio: audio, context: context, overlapsContext: hasPrevious, continues: continues,
                              model: model, backup: backup, slow: tier == .veryAccurate, raceAfter: raceAfter)
            do {
                let t: Transcript
                do {
                    t = try await send(req)
                } catch where !(error is CancellationError) && !Task.isCancelled {
                    // One more go, on the Instant model's routes all at once.
                    log("\(ms()) block #\(index) failed (\(error)); trying again with \(models.fast.name)")
                    req.model = models.fast; req.backup = nil; req.slow = false; req.raceAfter = 0
                    t = try await send(req)
                }
                if let why = t.fallbackReason { log("\(ms()) block #\(index): used \(t.model.name) instead, because \(why)") }
                log("\(ms()) got block #\(index) in \(Int(Date().timeIntervalSince(started) * 1000))ms from \(t.model.name): "
                    + (logText ? t.text : "\(t.text.count) chars"))
                texts.set(index, t.text)
                return t
            } catch {
                texts.set(index, nil)
                throw error
            }
        }
    }

    /// Call after the last `append`. Sends what is left and returns the joined transcript.
    /// Throws only when every block failed; otherwise failed blocks become `gapMark`.
    public func finish() async throws -> Result {
        let (tasks, seconds): ([Task<Transcript, Error>], Double) = q.sync {
            finished = true
            var tasks = blocks
            let seconds = Double(seg.samples.count) / Double(Audio.sampleRate)
            if let tail = seg.finish() {
                log("\(ms()) release: sending \(seg.isSplit ? "last block" : "whole recording") \(sec(tail))")
                tasks.append(start(tail, index: tasks.count, tier: mode.tier(forSeconds: seconds, autoAfter: autoAfter), raceAfter: 0))
            } else {
                log("\(ms()) release: nothing left to send (\(tasks.count) blocks in flight or done)")
            }
            return (tasks, seconds)
        }
        var parts: [Transcript?] = []
        var firstError: Error?
        for (i, t) in tasks.enumerated() {
            do { parts.append(try await t.value) } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                log("\(ms()) block #\(i) lost: \(error)")
                firstError = firstError ?? error
                parts.append(nil)
            }
        }
        let got = parts.compactMap { $0 }
        if got.isEmpty, let firstError { throw firstError }
        var models: [String] = []
        for p in got where !models.contains(p.model.id) { models.append(p.model.id) }
        return Result(text: Self.dropRepeatedPhrases(Self.join(parts.map { $0?.text ?? Self.gapMark })), pieces: tasks.count,
                      audioSeconds: seconds, model: models.joined(separator: "+"), fallback: got.compactMap(\.fallbackReason).first,
                      gaps: parts.count - got.count)
    }

    public func cancel() {
        q.async { [self] in
            finished = true
            blocks.forEach { $0.cancel() }
        }
    }

    /// Whole recording so far (for saving).
    public func recording() -> [Int16] { q.sync { seg.samples } }

    /// Removes a phrase of two or more words said twice in a row ("the menu, the menu will say" → "the menu will say"),
    /// a slip the model sometimes keeps. Single repeated words ("very, very") are left alone: they are often meant.
    public static func dropRepeatedPhrases(_ text: String) -> String {
        var w = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        var i = 0
        while i < w.count {
            var removed = false
            for k in stride(from: min(6, (w.count - i) / 2), through: 2, by: -1) {
                let a = w[i..<(i + k)].map(norm), b = w[(i + k)..<(i + 2 * k)].map(norm)
                guard a == b, !a.contains("") else { continue }
                // Keep the second copy (its punctuation fits what follows) with the first copy's capital letter.
                if let f = w[i].first, f.isUppercase { w[i + k] = w[i + k].prefix(1).uppercased() + w[i + k].dropFirst() }
                w.removeSubrange(i..<(i + k))
                removed = true
                break
            }
            if !removed { i += 1 }
        }
        return w.joined(separator: " ")
    }

    /// Joins block texts. Blocks overlap by about a second of audio, so a block may begin with words the
    /// previous one ended on; the longest such run (up to 12 words, compared without case or punctuation) is dropped.
    public static func join(_ texts: [String]) -> String {
        var words: [Substring] = []
        for t in texts {
            var next = t.split(whereSeparator: \.isWhitespace)
            guard !next.isEmpty else { continue }
            let norm: (Substring) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
            var drop = 0
            for k in stride(from: min(12, words.count, next.count), through: 1, by: -1) {
                if zip(words.suffix(k), next.prefix(k)).allSatisfy({ norm($0) == norm($1) && !norm($0).isEmpty }) { drop = k; break }
            }
            next.removeFirst(drop)
            // A block cut mid-sentence may still end with a period; drop it when the next block carries on in lowercase.
            if let last = words.last, last.hasSuffix("."), !last.hasSuffix(".."),
               let first = next.first?.first, first.isLowercase {
                words[words.count - 1] = last.dropLast()
            }
            words += next
        }
        return words.joined(separator: " ")
    }
}

/// The text of each finished block, for the context of later ones.
/// A block waits for the earlier ones until all are done or `maxWait` runs out, whichever is first, then goes with
/// what has arrived: a slow block never holds up the others past the limit, and never costs them the context they have.
final class BlockTexts: @unchecked Sendable {
    private let lock = NSLock()
    /// Finished blocks: their text, or nil if they failed.
    private var done: [Int: String?] = [:]
    private var waiters: [(before: Int, once: Once)] = []

    /// Resumes a continuation exactly once, whoever gets there first.
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var c: CheckedContinuation<Void, Never>?
        init(_ c: CheckedContinuation<Void, Never>) { self.c = c }
        func fire() {
            lock.lock(); let c = self.c; self.c = nil; lock.unlock()
            c?.resume()
        }
    }

    func set(_ index: Int, _ text: String?) {
        lock.lock()
        done[index] = .some(text)
        let ready = waiters.filter { allDone(before: $0.before) }
        waiters.removeAll { allDone(before: $0.before) }
        lock.unlock()
        ready.forEach { $0.once.fire() }
    }

    private func allDone(before i: Int) -> Bool { (0..<i).allSatisfy { done[$0] != nil } }

    /// The joined text of the blocks before `index` (waiting up to `maxWait` for those still running), and whether the
    /// block just before it is among them (only then does the overlapping audio pick up where the text ends).
    func context(before index: Int, maxWait: TimeInterval) async -> (String, Bool) {
        guard index > 0 else { return ("", false) }
        let once = Box<Once>()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let o = Once(c)
                once.set(o)
                lock.lock()
                if allDone(before: index) { lock.unlock(); o.fire(); return }
                waiters.append((index, o))
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + maxWait) { o.fire() }
            }
        } onCancel: { once.get()?.fire() }
        return snapshot(before: index)
    }

    private func snapshot(before index: Int) -> (String, Bool) {
        lock.lock(); defer { lock.unlock() }
        let texts = (0..<index).compactMap { done[$0] ?? nil }
        return (DictationPipeline.join(texts), (done[index - 1] ?? nil) != nil)
    }
}
