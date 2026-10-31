import Foundation

/// Decides where a recording is split, as rarely as possible: each cut is a place where words can be lost or doubled.
///
/// - Up to `wholeLimit` seconds the recording stays one block, sent whole at release.
/// - Past that, blocks of about `targetBlock` seconds are cut at real pauses (`minPause` of silence or more).
///   The first cut looks back for the pause nearest `targetBlock`; later ones take the first real pause once a
///   block is `liveMinBlock` long. With no real pause at all, a block grows to `hardMaxBlock` and is then cut at
///   its longest shorter pause.
/// - Each block after the first starts `overlap` seconds before the previous one ended, so nothing falls in the gap.
///
/// Works on 20 ms frames with an energy VAD whose threshold follows the noise floor.
public final class Segmenter {
    public struct Config {
        public var wholeLimit = 45.0     // s: recordings up to this long are never split
        public var targetBlock = 30.0    // s
        public var minBlock = 15.0       // s: shortest block the look-back cut may make
        public var liveMinBlock = 25.0   // s: once split, cut at the first real pause past this
        public var hardMaxBlock = 120.0  // s: no real pause by now, cut at the longest shorter one
        public var minPause = 0.8        // s of silence that counts as a real pause
        public var shortPause = 0.3      // s: shorter pauses are only used past `hardMaxBlock`
        public var overlap = 1.0         // s of audio repeated at the start of the next block
        public var minSpeech = 0.20      // s of new speech for a block to be worth sending
        public init() {}
    }

    public let config: Config
    public private(set) var samples: [Int16] = []
    /// Most recent frame level in dBFS (for meters).
    public private(set) var lastLevel: Double = -100

    private var speech: [Bool] = []          // per 20 ms frame
    private var blockStart = 0               // frame where the current block's audio starts (overlap included)
    private var freshStart = 0               // frame where its new audio starts (the previous cut)
    private var split = false                // the recording passed `wholeLimit`
    private var floorDb: Double?
    private var silenceRun = 0               // trailing silent frames
    private var pauses: [(start: Int, end: Int)] = [] // finished pauses ≥ shortPause in the current block

    private let F = Audio.frameSamples
    private func frames(_ seconds: Double) -> Int { Int((seconds * Double(Audio.sampleRate) / Double(Audio.frameSamples)).rounded()) }

    public init(config: Config = Config()) {
        self.config = config
        samples.reserveCapacity(Audio.sampleRate * 60)
    }

    /// Adds audio; returns the sample ranges of any blocks that are now complete.
    public func append(_ chunk: [Int16]) -> [Range<Int>] {
        samples.append(contentsOf: chunk)
        var blocks: [Range<Int>] = []
        while (speech.count + 1) * F <= samples.count {
            let i = speech.count
            let db = Audio.dbfs(samples[i * F ..< (i + 1) * F])
            lastLevel = db
            var floor = floorDb ?? db
            floor = db < floor ? db : floor + 0.05 // drops instantly, rises ~2.5 dB/s
            floorDb = floor
            let isSpeech = db > max(floor + 12, -52)
            speech.append(isSpeech)
            if let b = step(frame: i, isSpeech: isSpeech) { blocks.append(b) }
        }
        return blocks
    }

    private func step(frame i: Int, isSpeech: Bool) -> Range<Int>? {
        let end = i + 1
        if isSpeech {
            if silenceRun >= frames(config.shortPause) { pauses.append((end - 1 - silenceRun, end - 1)) }
            silenceRun = 0
        } else {
            silenceRun += 1
        }
        if !split && end >= frames(config.wholeLimit) {
            split = true
            if let c = lookBackCut(now: end) { return cut(at: c) }
        }
        guard split else { return nil }
        let length = end - blockStart
        if !isSpeech && silenceRun == frames(config.minPause) && length >= frames(config.liveMinBlock) {
            return cut(at: end)
        }
        if length >= frames(config.hardMaxBlock) {
            let longest = pauses.filter { $0.start > freshStart }.max { ($0.end - $0.start) < ($1.end - $1.start) }
            return cut(at: longest.map(cutPoint) ?? end)
        }
        return nil
    }

    /// The real pause whose cut gives a block nearest `targetBlock` (between `minBlock` and now).
    private func lookBackCut(now end: Int) -> Int? {
        var candidates = pauses.filter { $0.end - $0.start >= frames(config.minPause) }.map(cutPoint)
        if silenceRun >= frames(config.minPause) { candidates.append(end) }
        let target = blockStart + frames(config.targetBlock)
        return candidates
            .filter { $0 - blockStart >= frames(config.minBlock) }
            .min { abs($0 - target) < abs($1 - target) }
    }

    /// Cut late in a pause: the block keeps the whole last word, the overlap reaches back over it.
    private func cutPoint(_ p: (start: Int, end: Int)) -> Int { p.end - min(frames(0.2), (p.end - p.start) / 2) }

    private func cut(at c: Int) -> Range<Int>? {
        let range = speechCount(freshStart, c) >= frames(config.minSpeech) ? (blockStart * F)..<(c * F) : nil
        freshStart = c
        blockStart = max(0, c - frames(config.overlap))
        pauses.removeAll { $0.end <= c }
        return range
    }

    private func speechCount(_ a: Int, _ b: Int) -> Int {
        guard b > a else { return 0 }
        var n = 0
        for j in a..<b where speech[j] { n += 1 }
        return n
    }

    /// Range of the last block (to the end of the recording), or nil if it holds no new speech.
    public func finish() -> Range<Int>? {
        let total = speech.count
        defer { freshStart = total; blockStart = total }
        guard speechCount(freshStart, total) >= frames(config.minSpeech) else { return nil }
        return (blockStart * F)..<samples.count
    }

    /// True once the recording has been cut into blocks.
    public var isSplit: Bool { split }
}
