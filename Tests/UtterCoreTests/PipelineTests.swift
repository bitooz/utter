import XCTest
@testable import UtterCore

final class PipelineTests: XCTestCase {
    /// Small blocks so a few seconds of audio make several: cut at the first 0.3 s pause past 1 s.
    private var smallBlocks: Segmenter.Config {
        var c = Segmenter.Config()
        c.wholeLimit = 1; c.targetBlock = 1; c.minBlock = 0.5; c.liveMinBlock = 1; c.hardMaxBlock = 3
        c.minPause = 0.3; c.shortPause = 0.2; c.overlap = 0.2; c.minSpeech = 0.1
        return c
    }

    /// Loud bursts and near silence, like speech with pauses.
    private func speech(seconds: Double) -> [Int16] {
        var out: [Int16] = []
        while Double(out.count) < seconds * 16000 {
            out += (0..<12800).map { _ in Int16.random(in: -6000...6000) } // 0.8 s
            out += (0..<8000).map { _ in Int16.random(in: -3...3) }         // 0.5 s
        }
        return out
    }

    /// What the fake model was asked, per block.
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(index: Int, context: String, overlaps: Bool, model: String, at: Date)] = []
        func add(_ r: DictationPipeline.Request) {
            lock.lock(); list.append((r.index, r.context, r.overlapsContext, r.model.id, Date())); lock.unlock()
        }
        var all: [(index: Int, context: String, overlaps: Bool, model: String, at: Date)] { lock.lock(); defer { lock.unlock() }; return list }
    }

    private struct Boom: Error {}

    /// Feeds the audio in 100 ms chunks (as fast as it goes) and finishes.
    private func run(_ p: DictationPipeline, seconds: Double) async throws -> DictationPipeline.Result {
        let audio = speech(seconds: seconds)
        var i = 0
        while i < audio.count { p.append(Array(audio[i..<min(i + 1600, audio.count)])); i += 1600 }
        return try await p.finish()
    }

    /// The review's bug: block #2 waited for a slow block #1 far past the limit, then went without any context.
    /// Now it waits at most `contextWait`, and still gets block #0's text.
    func testSlowBlockDoesNotHoldUpContextPastTheLimit() async throws {
        let calls = Calls()
        let p = DictationPipeline(send: { r in
            calls.add(r)
            if r.index == 1 { try await Task.sleep(nanoseconds: 3_000_000_000) } // a slow block
            else { try await Task.sleep(nanoseconds: 50_000_000) }
            return Transcript(text: "block\(r.index) words", model: r.model)
        }, mode: .fast, segmenter: smallBlocks)
        p.contextWait = 0.4
        let started = Date()
        let r = try await run(p, seconds: 4)
        let byIndex = Dictionary(calls.all.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertGreaterThanOrEqual(byIndex.count, 3, "expected at least 3 blocks")
        let b2 = try XCTUnwrap(byIndex[2])
        let b1 = try XCTUnwrap(byIndex[1])
        XCTAssertLessThan(b2.at.timeIntervalSince(b1.at), 1.0, "block #2 waited past contextWait for slow block #1")
        XCTAssertTrue(b2.context.contains("block0"), "block #0's text was dropped from block #2's context: \(b2.context)")
        XCTAssertFalse(b2.overlaps, "block #1's text is missing, so the audio doesn't pick up where the context ends")
        XCTAssertTrue(byIndex[1]!.overlaps)
        XCTAssertTrue(r.text.hasPrefix("block0 words block1 words block2"), r.text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testFailedBlockIsRetriedOnceWithInstant() async throws {
        let calls = Calls()
        let p = DictationPipeline(send: { r in
            calls.add(r)
            if r.index == 1 && r.model.id != Model.lite.id { throw Boom() }
            return Transcript(text: "block\(r.index)", model: r.model)
        }, mode: .accurate, segmenter: smallBlocks)
        let r = try await run(p, seconds: 4)
        XCTAssertEqual(r.gaps, 0)
        XCTAssertFalse(r.text.contains(DictationPipeline.gapMark))
        XCTAssertEqual(calls.all.filter { $0.index == 1 }.map(\.model), [Model.flash.id, Model.lite.id])
    }

    func testBlockThatStillFailsLeavesAMarkedGapNotALostDictation() async throws {
        let p = DictationPipeline(send: { r in
            if r.index == 1 { throw Boom() }
            return Transcript(text: "block\(r.index).", model: r.model)
        }, mode: .fast, segmenter: smallBlocks)
        let r = try await run(p, seconds: 4)
        XCTAssertEqual(r.gaps, 1)
        XCTAssertTrue(r.text.hasPrefix("block0. \(DictationPipeline.gapMark) block2."), r.text)
    }

    func testEveryBlockFailingThrows() async {
        let p = DictationPipeline(send: { _ in throw Boom() }, mode: .fast, segmenter: smallBlocks)
        do { _ = try await run(p, seconds: 2); XCTFail("should throw") } catch {}
    }

    func testBlockTextIsNotLoggedUnlessAskedFor() async throws {
        let box = LogLines()
        let p = DictationPipeline(send: { r in Transcript(text: "secret words here", model: r.model) },
                                  mode: .fast, log: { box.add($0) })
        _ = try await run(p, seconds: 2)
        XCTAssertFalse(box.all.joined().contains("secret"), box.all.joined(separator: "\n"))
        XCTAssertTrue(box.all.contains { $0.contains("17 chars") })
    }

    private final class LogLines: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }
}

final class LogScrubTests: XCTestCase {
    func testTranscriptTextIsTakenOutOfOldLogLines() {
        let old = """
        2026-10-30 12:38:51.000 #1  7751ms got block #0 in 979ms from Gemini 3.1 Flash-Lite: Hello there, this is private.
        2026-10-29 10:00:00.000 #2  9559ms got spec #0 in 1335ms: Old format: with a colon.
        2026-10-29 10:00:01.000 #2 pasted 26 chars, release→text 900ms
        2026-10-31 13:00:00.000 #3   500ms got block #0 in 400ms from Gemini 3.8 Flash: 12 chars
        """
        let clean = Log.scrubbed(old)
        XCTAssertFalse(clean.contains("private"))
        XCTAssertFalse(clean.contains("Old format"))
        XCTAssertTrue(clean.contains("from Gemini 3.1 Flash-Lite: 29 chars"), clean)
        XCTAssertTrue(clean.contains("got spec #0 in 1335ms: 25 chars"), clean)
        XCTAssertTrue(clean.contains("#2 pasted 26 chars, release→text 900ms"))
        XCTAssertTrue(clean.contains("Gemini 3.8 Flash: 12 chars"))
        XCTAssertEqual(Log.scrubbed(clean), clean, "running it again changes nothing")
    }
}
