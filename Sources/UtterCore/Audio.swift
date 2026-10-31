import Foundation

/// All audio inside Utter is 16 kHz mono signed 16-bit PCM.
public enum Audio {
    public static let sampleRate = 16_000
    public static let frameSamples = 320 // 20 ms

    /// Wraps PCM samples in a minimal WAV container.
    public static func wav(_ samples: ArraySlice<Int16>) -> Data {
        let dataBytes = samples.count * 2
        var d = Data(capacity: 44 + dataBytes)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { buf in
            for s in buf { withUnsafeBytes(of: s.littleEndian) { d.append(contentsOf: $0) } }
        }
        return d
    }

    /// Reads a 16 kHz mono 16-bit PCM WAV (the format `say --data-format=LEI16@16000` and Utter itself write).
    public static func readWav(_ url: URL) throws -> [Int16] {
        let d = try Data(contentsOf: url)
        guard d.count > 12, String(decoding: d[0..<4], as: UTF8.self) == "RIFF" else { throw AudioError.badWav("not RIFF") }
        var pos = 12
        var fmtOK = false
        while pos + 8 <= d.count {
            let id = String(decoding: d[pos..<pos + 4], as: UTF8.self)
            let size = Int(d[pos + 4]) | Int(d[pos + 5]) << 8 | Int(d[pos + 6]) << 16 | Int(d[pos + 7]) << 24
            let body = pos + 8
            if id == "fmt " {
                let fmt = Int(d[body]) | Int(d[body + 1]) << 8
                let ch = Int(d[body + 2]) | Int(d[body + 3]) << 8
                let sr = Int(d[body + 4]) | Int(d[body + 5]) << 8 | Int(d[body + 6]) << 16
                let bits = Int(d[body + 14]) | Int(d[body + 15]) << 8
                guard fmt == 1, ch == 1, sr == sampleRate, bits == 16 else {
                    throw AudioError.badWav("need 16 kHz mono 16-bit PCM, got fmt=\(fmt) ch=\(ch) sr=\(sr) bits=\(bits)")
                }
                fmtOK = true
            } else if id == "data" {
                guard fmtOK else { throw AudioError.badWav("data before fmt") }
                let end = min(body + size, d.count)
                var out = [Int16](repeating: 0, count: (end - body) / 2)
                d[body..<body + out.count * 2].withUnsafeBytes { raw in
                    for i in 0..<out.count { out[i] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) }
                }
                return out
            }
            pos = body + size + (size & 1)
        }
        throw AudioError.badWav("no data chunk")
    }

    /// Level of a frame in dBFS, clamped to -100.
    public static func dbfs(_ frame: ArraySlice<Int16>) -> Double {
        guard !frame.isEmpty else { return -100 }
        var sum = 0.0
        for s in frame { let v = Double(s); sum += v * v }
        let rms = (sum / Double(frame.count)).squareRoot() / 32768.0
        return rms > 0 ? max(-100, 20 * log10(rms)) : -100
    }
}

/// Audio ready to send: bytes plus the OpenRouter `input_audio.format` name.
public struct EncodedAudio {
    public var data: Data
    public var format: String
    /// Length of the audio.
    public var seconds: Double
    public init(data: Data, format: String, seconds: Double = 0) { self.data = data; self.format = format; self.seconds = seconds }

    /// AAC in M4A when it encodes (much smaller upload), otherwise WAV.
    public static func best(_ samples: ArraySlice<Int16>) -> EncodedAudio {
        if UserDefaults.standard.string(forKey: "UtterAudioFormat") != "wav", let aac = AACEncoder.encode(samples) {
            return EncodedAudio(data: aac, format: "m4a", seconds: Double(samples.count) / Double(Audio.sampleRate))
        }
        return EncodedAudio(data: Audio.wav(samples), format: "wav", seconds: Double(samples.count) / Double(Audio.sampleRate))
    }
}

public enum AudioError: Error, CustomStringConvertible {
    case badWav(String)
    public var description: String { switch self { case .badWav(let s): return "bad wav: \(s)" } }
}
