import Foundation
import UtterCore

// Feeds WAV files through the same pipeline the app uses, in real time, and measures
// release-to-text: the time from the simulated key release (end of audio) to the full transcript.
//
//   utter-bench [--reps N] [--hold-after S] [--cold] [--verbose] [--mode auto|fast|accurate|veryAccurate]
//               [--model tier=openrouter/id] clip.wav ...
//
// --hold-after S: seconds of silence appended before release (people let go a beat after the last word).
// --cold: new connection for each run and no warm-up on press (worst case).

var reps = 3, holdAfter = 0.3, cold = false, verbose = false, raw = false, rawRace = false
var files: [String] = []
var config = Transcriber.Config()
var mode = Mode.default
var models = ModelSet()
var transcriptDir: String?
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--reps": reps = Int(args.popFirst() ?? "") ?? reps
    case "--hold-after": holdAfter = Double(args.popFirst() ?? "") ?? holdAfter
    case "--cold": cold = true
    case "--verbose": verbose = true
    case "--raw": raw = true
    case "--raw-race": raw = true; rawRace = true
    case "--encode": // utter-bench --encode in.wav out.m4a: the exact upload the app would make, for probing
        let src = args.popFirst() ?? "", dst = args.popFirst() ?? ""
        let audio = EncodedAudio.best(try Audio.readWav(URL(fileURLWithPath: src))[...])
        try audio.data.write(to: URL(fileURLWithPath: dst)); print("\(audio.format) \(audio.data.count) bytes"); exit(0)
    case "--transcripts": transcriptDir = args.popFirst() // writes <clip>.<run>.txt for scripts/compare.py
    case "--mode", "--engine":
        let m = args.popFirst() ?? ""
        guard let e = Mode(rawValue: m) else { print("unknown mode \(m); use auto, fast, accurate or veryAccurate"); exit(2) }
        mode = e
    case "--model": // --model accurate=google/gemini-3.7-flash
        let parts = (args.popFirst() ?? "").split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let tier = Tier(rawValue: parts[0]) else { print("use --model fast|accurate|veryAccurate=<id>"); exit(2) }
        models[tier] = Model(parts[1])
    default: files.append(a)
    }
}
guard !files.isEmpty else {
    print("usage: utter-bench [--reps N] [--hold-after S] [--cold] [--verbose] [--mode auto|fast|accurate|veryAccurate] [--model tier=id] [--transcripts DIR] clip.wav ...")
    exit(2)
}

let key = try KeyStore.openRouterKey()
let vocabulary = Vocabulary.load() // the app's list, so the bench sends what the app sends
var shared = Transcriber(key: key, config: config)
shared.vocabulary = vocabulary
if verbose { shared.log = { print("    " + $0) } }
print("mode: \(mode.title) (\(mode.detail(models, autoAfter: 20)))")
let chunk = 1600 // 100 ms, about what the mic tap delivers

/// A random 0–40 ms of silence in front, so no two runs upload identical bytes (rules out any caching).
/// Not added noise: faint white noise over the whole clip makes Gemini 3.8 Flash refuse it (SAFETY) and hurts accuracy.
func lead() -> [Int16] { [Int16](repeating: 0, count: Int.random(in: 0...640)) }

func run(_ samples: [Int16]) async throws -> (Double, DictationPipeline.Result) {
    if raw { // one plain request for the whole clip, no pipeline: isolates network + model time
        let audio = EncodedAudio.best((lead() + samples)[...])
        let t = Date()
        let tier = mode.tier(forSeconds: Double(samples.count) / 16000, autoAfter: 20)
        let tr = try await shared.transcribe(audio: audio, model: models[tier], backup: tier == .fast ? nil : models.fast,
                                             slow: tier == .veryAccurate, raceAfter: rawRace ? 0 : nil)
        return (Date().timeIntervalSince(t), .init(text: tr.text, pieces: 1, audioSeconds: 0, model: tr.model.id, fallback: tr.fallbackReason))
    }
    if cold { shared = Transcriber(key: key, config: config); shared.vocabulary = vocabulary } else { shared.warmIfIdle(20) } // the app warms on key press
    let p = DictationPipeline(transcriber: shared, mode: mode, models: models, log: verbose ? { print("    " + $0) } : { _ in })
    let all = lead() + samples + [Int16](repeating: 0, count: Int(holdAfter * 16000))
    let start = Date()
    var i = 0
    while i < all.count {
        let j = min(i + chunk, all.count)
        p.append(Array(all[i..<j]))
        i = j
        let due = start.addingTimeInterval(Double(i) / 16000)
        let wait = due.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
    let release = Date()
    let r = try await p.finish()
    return (Date().timeIntervalSince(release), r)
}

print(String(format: "mode=%@ hold-after=%.2fs reps=%d", cold ? "cold" : "warm", holdAfter, reps))
var all: [Double] = []
for f in files {
    let samples = try Audio.readWav(URL(fileURLWithPath: f))
    var times: [Double] = []
    var text = ""
    var info = ""
    for rep in 0..<reps {
        if cold { try await Task.sleep(nanoseconds: 1_000_000_000) }
        let (dt, r) = try await run(samples)
        times.append(dt); text = r.text
        if let dir = transcriptDir {
            let base = ((f as NSString).lastPathComponent as NSString).deletingPathExtension
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try r.text.write(toFile: "\(dir)/\(base).\(rep + 1).txt", atomically: true, encoding: .utf8)
        }
        info = "requests=\(r.pieces) model=\(r.model)"
        if let why = r.fallback { print("    run \(rep + 1) used Instant's text as the backup: \(why)") }
    }
    all += times
    let name = (f as NSString).lastPathComponent
    let ts = times.map { String(format: "%.0f", $0 * 1000) }.joined(separator: " ")
    print(String(format: "%-14@ %5.1fs audio  release→text ms: %@  (%@)\n    %@", name, Double(samples.count) / 16000, ts, info, text))
}
all.sort()
func pct(_ p: Double) -> Double { all[min(all.count - 1, Int(Double(all.count - 1) * p))] }
print(String(format: "ALL n=%d  median=%.0fms  p90=%.0fms  max=%.0fms", all.count, pct(0.5) * 1000, pct(0.9) * 1000, all.last! * 1000))
