import AppKit
import AVFoundation
import UtterCore

extension Notification.Name {
    /// Posted on the main thread after every dictation; `object` is the `Controller.Outcome`.
    static let utterOutcome = Notification.Name("UtterOutcome")
}

/// Hold a mode's key to talk and let go to paste; double-tap it for hands-free, then tap it once to finish.
/// Escape cancels, while recording and while writing.
/// A modifier hotkey used in a shortcut (with a key, another modifier, a click) never starts anything.
///
/// The mic starts the moment a mode's key goes down (not 0.3 s later, when the hold counts), so the first word isn't cut:
/// that audio waits in a `MicFeed` and is dropped if the key turns out to be part of a shortcut.
/// The text goes where the focus was at release: pasted into that text field, or left on the clipboard when there is
/// no text field or the focus has moved on.
final class Controller {
    enum Delivery: Equatable {
        case pasted
        /// No text field had the focus: the text is on the clipboard.
        case copiedNoField
        /// The focus moved after release: the text is on the clipboard, not pasted somewhere else.
        case copiedFocusMoved
    }

    struct Outcome {
        var text: String
        var releaseToText: TimeInterval
        var pieces: Int
        var audioSeconds: Double
        var model = ""
        var error: String?
        var delivery: Delivery = .pasted
        /// Parts that couldn't be transcribed even after a retry (marked in `text`).
        var gaps = 0
    }

    private enum Phase { case idle, holding, handsFree }

    static let maxRecording: TimeInterval = 6 * 60

    let tap = HotkeyTap()
    let hud = HUD()
    var transcriber: Transcriber?
    /// Audio for the next dictation; nil means the microphone.
    var makeSource: (() -> AudioSource)?
    /// Checked right before pasting; the self-test uses it to never type outside its window.
    var mayPaste: () -> Bool = { true }
    var onOutcome: (Outcome) -> Void = { _ in }
    var onChange: () -> Void = {}

    private(set) var lastOutcome: Outcome?
    private(set) var lastUse = Date.distantPast
    private var phase = Phase.idle
    private var session: (pipeline: DictationPipeline, source: AudioSource, id: Int, hotkey: Hotkey?, mode: Mode)?
    private var sessionCount = 0
    private static let audioQueue = DispatchQueue(label: "utter.audio", qos: .userInteractive)
    private let audioQ = Controller.audioQueue
    private let mic = MicSource(queue: Controller.audioQueue)
    /// The mic's audio while it runs: from key-down until the dictation ends (or the key turns out to be a shortcut).
    private var feed: MicFeed?
    private var armCount = 0
    private var handsFreeEnded = Date.distantPast
    /// Dictations sent off and not back yet, and those cancelled meanwhile.
    private var writing: [Int: DictationPipeline] = [:]
    private var cancelledWhileWriting = Set<Int>()
    /// The last dictation's audio when it failed or came back with a gap, for Retry (kept in memory only).
    private var retryAudio: (samples: [Int16], mode: Mode)?
    private let log = Log.shared

    var isRecording: Bool { session != nil }
    var canRetry: Bool { retryAudio != nil }
    /// Why the microphone last failed, for the menu.
    var micError: String? { audioQ.sync { mic.lastError } }

    /// Sets up the audio engine ahead of the first press (only once the mic is authorized).
    func prepareMic() { audioQ.async { [self] in mic.prepare() } }

    init() {
        tap.onTrigger = { [weak self] in self?.handle($0) }
        tap.onArm = { [weak self] in
            self?.transcriber?.warmIfIdle(10)
            self?.armMic()
        }
        tap.onEscape = { [weak self] in self?.cancel() }
        applyHotkeys()
    }

    /// Loads each mode's key from Settings into the tap (in menu order, so the earlier mode wins a clash).
    func applyHotkeys() {
        tap.configure(Mode.allCases.compactMap { m in Settings.modeHotkey(m).map { (m, $0) } })
    }

    /// Uses a new OpenRouter key from now on.
    func setKey(_ key: String) {
        let t = Transcriber(key: key, config: Transcriber.Config())
        t.log = { Log.shared($0) }
        t.warm()
        transcriber = t
    }

    private func handle(_ t: Trigger) {
        switch (phase, t.kind) {
        case (.idle, .holdBegan):
            begin(handsFree: false, mode: t.mode, hotkey: t.hotkey)
        case (.idle, .handsFree):
            // A double tap right after a tap ended hands-free is the user finishing twice, not starting again.
            guard Date().timeIntervalSince(handsFreeEnded) > 0.8 else { return }
            begin(handsFree: true, mode: t.mode, hotkey: t.hotkey)
        case (.holding, .holdEnded):
            end()
        case (.holding, .holdTapped):
            // A key combination pressed and let go quickly: keep listening, hands-free.
            phase = .handsFree
            hud.set(.handsFree(finishHint))
            log("#\(session?.id ?? 0) hands-free")
        case (.holding, .holdInterrupted):
            // The key turned out to be part of a shortcut: drop the recording quietly.
            cancel(message: nil)
        case (.handsFree, .finish), (.handsFree, .holdEnded), (.handsFree, .handsFree), (.handsFree, .holdBegan):
            handsFreeEnded = Date()
            end()
        default:
            break
        }
    }

    /// How to finish hands-free: the key that started it.
    private var finishHint: String { session?.hotkey.map(Hotkey.finishHint) ?? "Esc cancels" }

    // MARK: Mic from key-down

    private var micReady: Bool {
        makeSource == nil && transcriber != nil && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// A mode's key went down on its own: start listening now, in case it's held. If no dictation has started a moment
    /// after the hold would have counted (a shortcut, a tap), the audio is dropped and the mic stops.
    private func armMic() {
        guard session == nil, micReady else { return }
        armCount += 1
        let n = armCount
        if feed == nil { startMic(MicFeed()) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, armCount == n, session == nil, feed != nil else { return }
            stopMic()
        }
    }

    private func startMic(_ f: MicFeed) {
        feed = f
        audioQ.async { [weak self] in
            guard let self else { return }
            do {
                try mic.start { f.push($0) }
            } catch {
                DispatchQueue.main.async {
                    self.log("mic start failed: \(error)")
                    guard self.feed === f else { return }
                    self.feed = nil
                    if self.session != nil { self.cancel(message: "Microphone unavailable") }
                }
            }
        }
    }

    private func stopMic() {
        feed = nil
        audioQ.async { [mic] in mic.stop() }
    }

    // MARK: Dictation

    private func begin(handsFree: Bool, mode: Mode, hotkey: Hotkey?) {
        guard let tx = transcriber else { hud.set(.message("Add your OpenRouter key in Settings")); return }
        tx.warmIfIdle(10)
        tx.vocabulary = Vocabulary.load()
        tx.systemPrompt = Settings.systemPrompt
        sessionCount += 1
        let id = sessionCount
        let pipeline = makePipeline(tx, mode: mode, id: id)
        pipeline.onLevel = { [weak self] db in DispatchQueue.main.async { self?.hud.level(db) } }
        var early = 0
        let source: AudioSource
        if let make = makeSource {
            source = make()
            audioQ.async { [weak self] in
                do { try source.start { pipeline.append($0) } } catch {
                    DispatchQueue.main.async {
                        self?.log("#\(id) audio start failed: \(error)")
                        if self?.session?.id == id { self?.cancel(message: "Microphone unavailable") }
                    }
                }
            }
        } else {
            source = mic
            let f = feed ?? MicFeed()
            if feed == nil { startMic(f) }
            early = f.attach { pipeline.append($0) }
        }
        session = (pipeline, source, id, hotkey, mode)
        phase = handsFree ? .handsFree : .holding
        updateEscape()
        hud.set(handsFree ? .handsFree(finishHint) : .listening)
        onChange()
        log("#\(id) start (\(handsFree ? "hands-free" : "hold"), mode \(mode.title)"
            + (early > 0 ? String(format: ", %.2f s heard since key-down", Double(early) / Double(Audio.sampleRate)) : "") + ")")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxRecording) { [weak self] in
            if self?.session?.id == id { self?.end() }
        }
    }

    private func makePipeline(_ tx: Transcriber, mode: Mode, id: Int) -> DictationPipeline {
        DictationPipeline(transcriber: tx, mode: mode, models: Settings.models, autoAccurateAfter: Settings.autoAccurateAfter,
                          logText: Log.logsTranscripts, log: { [log] in log("#\(id) \($0)") })
    }

    private func updateEscape() { tap.escapeActive = session != nil || !writing.isEmpty }

    private func end() {
        guard let s = session else { phase = .idle; return }
        let released = Date()
        session = nil
        phase = .idle
        if s.source === mic { feed = nil }
        lastUse = released
        log("#\(s.id) release")
        audioQ.async { s.source.stop() }
        write(s.id, s.pipeline, mode: s.mode, released: released)
    }

    /// Waits for the text and puts it where the user was at `released` (pasted, or on the clipboard).
    private func write(_ id: Int, _ pipeline: DictationPipeline, mode: Mode, released: Date) {
        writing[id] = pipeline
        updateEscape()
        hud.set(.transcribing)
        onChange()
        let keep = UserDefaults.standard.bool(forKey: "UtterKeepRecordings")

        Task.detached { [weak self] in
            // Where the user is right now; the text should land there.
            async let atRelease = Paster.focus()
            async let before = Paster.characterBeforeCaret()
            var outcome = Outcome(text: "", releaseToText: 0, pieces: 0, audioSeconds: 0)
            // Wait for the mic queue to stop so every captured sample reached the pipeline.
            await withCheckedContinuation { c in self?.audioQ.async { c.resume() } ?? c.resume() }
            do {
                let r = try await pipeline.finish()
                outcome.text = r.text
                outcome.pieces = r.pieces
                outcome.audioSeconds = r.audioSeconds
                outcome.model = r.model
                outcome.gaps = r.gaps
                if let why = r.fallback { self?.log("#\(id) used Instant's text as the backup: \(why)") }
            } catch {
                outcome.error = "\(error)"
            }
            let target = await atRelease
            let now = outcome.text.isEmpty ? target : Paster.focus()
            let prev = await before
            let result = outcome
            await MainActor.run { [weak self] in
                guard let self else { return }
                writing[id] = nil
                updateEscape()
                if cancelledWhileWriting.remove(id) != nil {
                    log("#\(id) cancelled while writing; nothing pasted")
                    onChange()
                    return
                }
                var o = result
                if o.error == nil, !o.text.isEmpty {
                    if !mayPaste() {
                        o.error = "focus left the target; not pasted"
                    } else if !now.isSame(as: target) {
                        Paster.copy(o.text)
                        o.delivery = .copiedFocusMoved
                    } else if now.kind == .notText {
                        Paster.copy(o.text)
                        o.delivery = .copiedNoField
                    } else {
                        Paster.paste(Paster.spaced(o.text, after: prev), into: now)
                    }
                }
                o.releaseToText = Date().timeIntervalSince(released)
                finish(id, o, pipeline: pipeline, mode: mode, keep: keep)
            }
        }
    }

    private func finish(_ id: Int, _ o: Outcome, pipeline: DictationPipeline, mode: Mode, keep: Bool) {
        lastOutcome = o
        let failed = o.error != nil && !o.error!.hasPrefix("focus")
        retryAudio = failed || o.gaps > 0 ? (pipeline.recording(), mode) : nil
        if let e = o.error {
            log("#\(id) FAILED after \(ms(o.releaseToText)): \(e)")
            hud.set(.message(failed ? "Transcription failed · Retry in the menu" : "Not pasted: focus moved"))
        } else if o.text.isEmpty {
            log("#\(id) no speech (\(ms(o.releaseToText)))")
            hud.set(.message("Didn't catch that"))
        } else {
            let how: String
            switch o.delivery {
            case .pasted: how = "pasted"
            case .copiedNoField: how = "copied (no text field focused)"
            case .copiedFocusMoved: how = "copied (focus moved since release)"
            }
            log("#\(id) \(how) \(o.text.count) chars, release→text \(ms(o.releaseToText)), audio \(String(format: "%.1f", o.audioSeconds))s, "
                + "requests \(o.pieces)\(o.gaps > 0 ? ", \(o.gaps) part(s) missing" : "")")
            if isRecording {
                hud.set(phase == .handsFree ? .handsFree(finishHint) : .listening)
            } else if o.gaps > 0 {
                hud.set(.message("Part missing · Retry in the menu"))
            } else if o.delivery == .copiedNoField {
                hud.set(.message("Copied to clipboard"))
            } else if o.delivery == .copiedFocusMoved {
                hud.set(.message("Copied, not pasted: focus moved"))
            } else {
                hud.set(.hidden)
            }
        }
        Stats.record(o)
        if keep { // failed ones too, but only when the user keeps recordings
            let samples = pipeline.recording()
            DispatchQueue.global(qos: .utility).async { Stats.save(samples, failed: o.error != nil) }
        }
        onOutcome(o)
        NotificationCenter.default.post(name: .utterOutcome, object: o)
        onChange()
    }

    /// Sends the last failed (or partly failed) dictation again, and puts the text where the focus is now.
    func retryLast() {
        guard let r = retryAudio, let tx = transcriber, session == nil else { return }
        retryAudio = nil
        tx.vocabulary = Vocabulary.load()
        tx.systemPrompt = Settings.systemPrompt
        sessionCount += 1
        let id = sessionCount
        log("#\(id) retry of the last dictation (\(String(format: "%.1f", Double(r.samples.count) / Double(Audio.sampleRate))) s, mode \(r.mode.title))")
        let pipeline = makePipeline(tx, mode: r.mode, id: id)
        pipeline.append(r.samples)
        write(id, pipeline, mode: r.mode, released: Date())
    }

    /// Escape: stops the recording, or else drops the text still being written (nothing is pasted).
    func cancel(message: String? = "Cancelled") {
        if let s = session {
            session = nil
            phase = .idle
            if s.source === mic { stopMic() } else { audioQ.async { s.source.stop() } }
            s.pipeline.cancel()
            updateEscape()
            hud.set(message.map { .message($0) } ?? .hidden)
            log("#\(s.id) cancelled")
            onChange()
        } else if !writing.isEmpty {
            for (id, p) in writing { cancelledWhileWriting.insert(id); p.cancel() }
            writing = [:]
            updateEscape()
            hud.set(.message("Cancelled"))
            onChange()
        }
    }

    private func ms(_ t: TimeInterval) -> String { "\(Int(t * 1000))ms" }
}

/// Mic audio from key-down on: kept (the last second of it) until a dictation takes it, then passed straight on.
final class MicFeed: @unchecked Sendable {
    static let keep = Audio.sampleRate // 1 s
    private let lock = NSLock()
    private var buffer: [Int16] = []
    private var sink: (([Int16]) -> Void)?

    func push(_ samples: [Int16]) {
        lock.lock(); defer { lock.unlock() }
        if let sink { sink(samples); return }
        buffer += samples
        if buffer.count > Self.keep { buffer.removeFirst(buffer.count - Self.keep) }
    }

    /// Hands what was heard so far to `sink`, then everything after it. Returns how many samples were waiting.
    @discardableResult
    func attach(_ sink: @escaping ([Int16]) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        let early = buffer
        buffer = []
        if !early.isEmpty { sink(early) }
        self.sink = sink
        return early.count
    }
}

/// Timings of every dictation (numbers only) and, when enabled, the audio, for benchmarking on real use.
enum Stats {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Utter")

    static let header = "time,audio_s,pieces,speculative_tail,release_to_text_ms,chars,error,model"

    static func record(_ o: Controller.Outcome) {
        let url = dir.appendingPathComponent("timings.csv")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old = try? String(contentsOf: url, encoding: .utf8) {
            // Files from before the model column: add it to the header (older rows leave it empty).
            if let first = old.split(separator: "\n", maxSplits: 1).first, !first.hasSuffix(",model") {
                try? (header + old.dropFirst(first.count)).write(to: url, atomically: true, encoding: .utf8)
            }
        } else {
            try? (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let line = String(format: "%@,%.2f,%d,%d,%.0f,%d,%@,%@\n", ISO8601DateFormatter().string(from: Date()), o.audioSeconds, o.pieces,
                          0, o.releaseToText * 1000, o.text.count, o.error == nil ? "" : "1", o.model)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    }

    static func save(_ samples: [Int16], failed: Bool) {
        let sub = dir.appendingPathComponent(failed ? "failed" : "recordings")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        try? Audio.wav(samples[...]).write(to: sub.appendingPathComponent("\(f.string(from: Date())).wav"))
    }
}
