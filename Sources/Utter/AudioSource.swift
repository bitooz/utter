import AVFoundation
import ObjCCatch
import UtterCore

protocol AudioSource: AnyObject {
    /// Starts delivering 16 kHz mono Int16 chunks on a background thread.
    func start(_ onSamples: @escaping ([Int16]) -> Void) throws
    func stop()
}

/// Microphone through AVAudioEngine, converted to 16 kHz mono.
/// Every AVAudioEngine call goes through `ObjCCatch`, because the engine raises Objective-C exceptions
/// (no input device, a device that just changed) that would otherwise abort the app.
/// All methods run on `queue`, the controller's audio queue.
final class MicSource: AudioSource {
    private let queue: DispatchQueue
    private var engine = AVAudioEngine()
    private var stale = false
    private var onSamples: (([Int16]) -> Void)?
    private var observer: NSObjectProtocol?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(Audio.sampleRate), channels: 1, interleaved: true)!
    /// Why the mic last failed, for the menu; nil once it works.
    private(set) var lastError: String?

    init(queue: DispatchQueue) {
        self.queue = queue
        // Plugging in a headset or switching the input device stops the engine: rebuild it,
        // and keep a dictation that is in progress going on the new device.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] n in
            let changed = n.object as AnyObject?
            queue.async { self?.configurationChanged(changed) }
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Sets the engine up ahead of the first press so it starts faster. Only call once the mic is authorized.
    func prepare() {
        do {
            try ObjCCatch.run { [engine] in
                _ = engine.inputNode // the graph needs a node before prepare(), or prepare() raises
                engine.prepare()
            }
            lastError = nil
        } catch {
            fail(error)
        }
    }

    func start(_ onSamples: @escaping ([Int16]) -> Void) throws {
        if stale { engine = AVAudioEngine(); stale = false }
        do {
            try startEngine(onSamples)
            self.onSamples = onSamples
            lastError = nil
        } catch {
            fail(error)
            throw error
        }
    }

    func stop() {
        onSamples = nil
        try? ObjCCatch.run { [engine] in
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private func startEngine(_ onSamples: @escaping ([Int16]) -> Void) throws {
        var failure: Error?
        try ObjCCatch.run { [engine, outFormat] in
            let input = engine.inputNode
            let inFormat = input.outputFormat(forBus: 0)
            guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
                  let conv = AVAudioConverter(from: inFormat, to: outFormat)
            else { failure = MicError.noInput; return }
            conv.downmix = true
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buffer, _ in
                let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
                guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
                var given = false
                var err: NSError?
                conv.convert(to: out, error: &err) { _, status in
                    if given { status.pointee = .noDataNow; return nil }
                    given = true
                    status.pointee = .haveData
                    return buffer
                }
                let n = Int(out.frameLength)
                guard n > 0, let p = out.int16ChannelData?[0] else { return }
                onSamples(Array(UnsafeBufferPointer(start: p, count: n)))
            }
            engine.prepare()
            do { try engine.start() } catch { failure = error }
        }
        if let failure { throw failure }
    }

    private func configurationChanged(_ changed: AnyObject?) {
        guard changed == nil || changed === engine else { return }
        stale = true
        guard let cb = onSamples else { return }
        Log.shared("audio device changed; restarting the mic")
        stop()
        do { try start(cb) } catch { Log.shared("mic restart failed: \(error)") }
    }

    private func fail(_ error: Error) {
        stale = true // start over with a fresh engine next time
        lastError = "\(error)"
        Log.shared("mic: \(error)")
    }

    enum MicError: Error, CustomStringConvertible {
        case noInput
        var description: String { "no audio input device" }
    }
}

/// Plays a WAV file into the pipeline in real time, as if spoken into the mic (self-test, benchmarks).
/// After the file ends it keeps sending silence until stopped, like a quiet room.
final class FileSource: AudioSource {
    private let samples: [Int16]
    private var timer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "utter.filesource")

    init(url: URL) throws { samples = try Audio.readWav(url) }
    var duration: Double { Double(samples.count) / Double(Audio.sampleRate) }

    func start(_ onSamples: @escaping ([Int16]) -> Void) throws {
        var pos = 0
        let chunk = 1600 // 100 ms
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(2))
        t.setEventHandler { [samples] in
            if pos < samples.count {
                let end = min(pos + chunk, samples.count)
                var out = Array(samples[pos..<end])
                if out.count < chunk { out += [Int16](repeating: 0, count: chunk - out.count) }
                pos = end
                onSamples(out)
            } else {
                onSamples([Int16](repeating: 0, count: chunk))
            }
        }
        timer = t
        t.resume()
    }

    func stop() {
        q.sync { timer?.cancel(); timer = nil }
    }
}
