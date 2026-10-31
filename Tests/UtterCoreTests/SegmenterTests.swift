import XCTest
@testable import UtterCore

final class SegmenterTests: XCTestCase {
    /// Synthetic "speech": loud noise bursts of `talk` seconds separated by `pause` seconds of near silence.
    private func recording(seconds: Double, talk: Double, pause: Double) -> [Int16] {
        var out: [Int16] = []
        let n = Int(seconds * 16000)
        while out.count < n {
            out += (0..<Int(talk * 16000)).map { _ in Int16.random(in: -6000...6000) }
            out += (0..<Int(pause * 16000)).map { _ in Int16.random(in: -3...3) }
        }
        return Array(out.prefix(n))
    }

    private func run(_ audio: [Int16], _ config: Segmenter.Config = .init()) -> [Range<Int>] {
        let s = Segmenter(config: config)
        var blocks: [Range<Int>] = []
        var i = 0
        while i < audio.count { // 100 ms chunks, like the mic
            blocks += s.append(Array(audio[i..<min(i + 1600, audio.count)]))
            i += 1600
        }
        if let last = s.finish() { blocks.append(last) }
        return blocks
    }

    func testUpTo45SecondsIsOneWholeBlock() {
        let audio = recording(seconds: 44, talk: 4, pause: 1)
        XCTAssertEqual(run(audio), [0..<audio.count])
    }

    func testLongRecordingSplitsAtRealPausesWithOverlap() {
        let audio = recording(seconds: 70, talk: 4, pause: 1)
        let blocks = run(audio)
        XCTAssertEqual(blocks.count, 3, "\(blocks)")
        XCTAssertEqual(blocks.first?.lowerBound, 0)
        XCTAssertEqual(blocks.last?.upperBound, audio.count)
        for (a, b) in zip(blocks, blocks.dropFirst()) {
            XCTAssertEqual(a.upperBound - b.lowerBound, 16000, "1 s overlap")
            // the cut sits inside a pause: the samples around it are quiet
            let cut = a.upperBound
            XCTAssertLessThan(Audio.dbfs(audio[(cut - 320)..<cut]), -60)
        }
        for b in blocks.dropLast() {
            let seconds = Double(b.count) / 16000
            XCTAssert((20...46).contains(seconds), "block of \(seconds) s")
        }
    }

    func testShortPausesAreNotCutPoints() { // only 0.4 s gaps: no cut until the hard limit
        let audio = recording(seconds: 90, talk: 3, pause: 0.4)
        XCTAssertEqual(run(audio).count, 1)
    }

    func testDropsPhrasesSaidTwice() {
        XCTAssertEqual(DictationPipeline.dropRepeatedPhrases("The menu, the menu will also say what's missing."),
                       "The menu will also say what's missing.")
        XCTAssertEqual(DictationPipeline.dropRepeatedPhrases("Send it to the team the team on Friday."), "Send it to the team on Friday.")
        XCTAssertEqual(DictationPipeline.dropRepeatedPhrases("It was very, very good. Bye bye."), "It was very, very good. Bye bye.")
        XCTAssertEqual(DictationPipeline.dropRepeatedPhrases("I think that that is fine."), "I think that that is fine.")
    }

    func testJoinDropsWordsRepeatedByTheOverlap() {
        XCTAssertEqual(DictationPipeline.join(["We meet on Thursday.", "Thursday, we ship the build."]),
                       "We meet on Thursday we ship the build.")
        XCTAssertEqual(DictationPipeline.join(["Then we write tests for the", "for the payment service."]),
                       "Then we write tests for the payment service.")
        XCTAssertEqual(DictationPipeline.join(["No overlap here.", "Next part.", ""]), "No overlap here. Next part.")
        XCTAssertEqual(DictationPipeline.join(["the settings page to show.", "which model is active."]),
                       "the settings page to show which model is active.")
    }
}
