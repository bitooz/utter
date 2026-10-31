import AVFoundation

/// Encodes 16 kHz mono PCM to AAC-LC in an M4A (MP4) file in memory, about a tenth the size of WAV.
///
/// Not a raw ADTS stream: Gemini drops the end of ADTS audio (about 1 s of a 23 s clip, 3 s of a 66 s clip,
/// even with silence appended), while the same AAC in an M4A container comes through complete.
public enum AACEncoder {
    public static func encode(_ samples: ArraySlice<Int16>, bitRate: Int = 32_000) -> Data? {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Audio.sampleRate),
                                                                  channels: 1, interleaved: true)!,
                                           frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.int16ChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utter-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try write(input, to: url, bitRate: bitRate) // the file is finished once this returns and releases it
            return try Data(contentsOf: url)
        } catch {
            return nil
        }
    }

    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL, bitRate: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Audio.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitRate,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }
}
