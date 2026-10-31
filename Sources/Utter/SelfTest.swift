import AppKit
import UtterCore

/// End-to-end check run inside the real app (so it uses Utter's own Accessibility permission):
/// holds or double-taps Option with synthetic key events while TestPad is focused, plays a WAV in place of the mic,
/// and reads back what landed in TestPad's field.
///
///   Utter --selftest --clip a.wav [--clip b.wav …] --pad-state /tmp/state.json --out result.json [--mode hold|handsfree]
///
/// Synthetic events are only posted while TestPad is the frontmost app with its window key;
/// the moment focus leaves, the run stops and nothing more is typed or pasted.
final class SelfTest {
    static let padBundleID = "dev.utter.TestPad"

    private let controller: Controller
    private var clips: [String] = []
    private var padState = ""
    private var out = ""
    private var mode = "hold"
    private var results: [[String: Any]] = []
    private var pendingOutcome: CheckedContinuation<Controller.Outcome, Never>?

    init(args: [String], controller: Controller) {
        self.controller = controller
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--clip": if let v = it.next() { clips.append(v) }
            case "--pad-state": padState = it.next() ?? ""
            case "--out": out = it.next() ?? ""
            case "--mode": mode = it.next() ?? mode
            default: break
            }
        }
        controller.mayPaste = { Self.padFocused() }
        controller.onOutcome = { [weak self] o in
            self?.pendingOutcome?.resume(returning: o)
            self?.pendingOutcome = nil
        }
    }

    static func padFocused() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == padBundleID else { return false }
        // TestPad records whether its window is key in its state file.
        return true
    }

    func run() {
        Task { @MainActor in
            var summary: [String: Any] = ["mode": mode]
            do {
                try await waitFor("hotkey tap (Accessibility permission)", 10) { self.controller.tap.isRunning }
                try await waitFor("Utter's OpenRouter key", 1) { self.controller.transcriber != nil }
                self.controller.transcriber?.warm()
                try await waitFor("TestPad focused", 10) { Self.padFocused() && self.padKeyWindow() }
                for clip in clips {
                    results.append(try await runClip(clip))
                }
                summary["ok"] = results.allSatisfy { ($0["ok"] as? Bool) == true }
            } catch {
                summary["ok"] = false
                summary["error"] = "\(error)"
            }
            summary["runs"] = results
            let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: out))
            Log.shared("selftest done: \(summary["ok"] ?? false)")
            try? await Task.sleep(nanoseconds: 800_000_000) // let the clipboard restore run
            NSApp.terminate(nil)
        }
    }

    private func runClip(_ path: String) async throws -> [String: Any] {
        let source = try FileSource(url: URL(fileURLWithPath: path))
        controller.makeSource = { source }
        let before = padText()
        try guardFocus()

        let outcome: Controller.Outcome = try await withCheckedThrowingContinuation { (c: CheckedContinuation<Controller.Outcome, Error>) in
            Task { @MainActor in
                let waiter = Task { @MainActor in await withCheckedContinuation { self.pendingOutcome = $0 } }
                do {
                    // Audio starts ~0.1 s after recording does; keep going until the clip has played plus a short beat.
                    let talk = source.duration + 0.35
                    if mode == "handsfree" {
                        try key(down: true); try await sleep(0.08); try key(down: false)
                        try await sleep(0.12)
                        try key(down: true); try await sleep(0.08); try key(down: false)
                        try await sleepGuarded(talk)
                        try key(down: true); try await sleep(0.08); try key(down: false)
                    } else {
                        try key(down: true)
                        try await sleepGuarded(0.3 + talk) // recording starts once Option has been held 0.3 s
                        try key(down: false)
                    }
                    c.resume(returning: await waiter.value)
                } catch {
                    // Focus left: let go of the key (Utter swallows it) and abandon this dictation.
                    _ = try? key(down: false, force: true)
                    controller.cancel()
                    waiter.cancel()
                    c.resume(throwing: error)
                }
            }
        }
        try await sleep(0.4) // let the pasted text settle into the field
        let after = padText()
        let inserted = after.hasPrefix(before) ? String(after.dropFirst(before.count)) : after
        let expected = outcome.text
        let ok = outcome.error == nil && !expected.isEmpty && inserted.contains(expected) && !after.contains("÷")
        Log.shared("selftest \(path): ok=\(ok) release→text=\(Int(outcome.releaseToText * 1000))ms inserted=\(inserted)")
        return [
            "clip": (path as NSString).lastPathComponent,
            "ok": ok,
            "release_to_text_ms": Int(outcome.releaseToText * 1000),
            "pieces": outcome.pieces,
            "transcript": expected,
            "inserted": inserted,
            "divide_sign_typed": after.contains("÷"),
            "error": outcome.error ?? "",
        ]
    }

    private func key(down: Bool, force: Bool = false) throws {
        if !force { try guardFocus() }
        // Option on its own arrives as a flags-changed event, not a key down/up.
        let src = CGEventSource(stateID: .hidSystemState)
        let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(58), keyDown: down)
        e?.type = .flagsChanged
        e?.flags = down ? .maskAlternate : []
        e?.post(tap: .cghidEventTap)
    }

    private func guardFocus() throws {
        guard Self.padFocused(), padKeyWindow() else { throw TestError.focusLost }
    }

    private func sleepGuarded(_ seconds: Double) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try guardFocus()
            try await sleep(0.05)
        }
        try guardFocus()
    }

    private func sleep(_ s: Double) async throws { try await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    private func waitFor(_ what: String, _ timeout: Double, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { throw TestError.timeout(what) }
            try await sleep(0.1)
        }
    }

    private func padJSON() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: padState),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    private func padKeyWindow() -> Bool { (padJSON()["key"] as? Bool) == true }
    private func padText() -> String { (padJSON()["text"] as? String) ?? "" }

    enum TestError: Error, CustomStringConvertible {
        case focusLost
        case timeout(String)
        var description: String {
            switch self {
            case .focusLost: return "focus left the TestPad window; stopped typing"
            case .timeout(let w): return "timed out waiting for \(w)"
            }
        }
    }
}
