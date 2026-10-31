import AVFoundation
import XCTest
@testable import UtterCore

final class AACEncoderTests: XCTestCase {
    /// The whole recording must survive encoding: a lost tail means lost last words.
    func testKeepsTheWholeRecording() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../bench/clips/mid25.wav").standardized
        let samples = try Audio.readWav(url)
        let aac = try XCTUnwrap(AACEncoder.encode(samples[...]))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("utter-aac-test.m4a")
        try aac.write(to: out)
        let file = try AVAudioFile(forReading: out)
        let decoded = Double(file.length) / file.processingFormat.sampleRate
        let original = Double(samples.count) / 16000
        print("original \(original) s, AAC decodes to \(decoded) s, \(aac.count / 1024) KB")
        XCTAssertGreaterThan(decoded, original - 0.1)
    }
}
