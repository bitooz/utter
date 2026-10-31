import AVFoundation
import SwiftUI
import UtterCore

/// First-run setup: welcome, OpenRouter key, permissions, hotkeys, mode and models, a test dictation.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, key, permissions, hotkeys, mode, test
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .key: return "OpenRouter Key"
            case .permissions: return "Permissions"
            case .hotkeys: return "Hotkeys"
            case .mode: return "Modes"
            case .test: return "Try It"
            }
        }
    }

    @ObservedObject var model: AppModel
    private var step: Step { model.onboardingStep }
    @State private var saveError: String?
    var onFinish: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if step != .welcome { progress.padding(.top, 34).padding(.horizontal, 40) }
            ZStack {
                content
                    .padding(.horizontal, 48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: step == .welcome ? .center : .top)
                    .padding(.top, step == .welcome ? 0 : 26)
                    .id(step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 720, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.22), value: step)
    }

    // MARK: Chrome

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases.dropFirst(), id: \.self) { s in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    Text(s.title)
                        .font(.caption.weight(s == step ? .semibold : .regular))
                        .foregroundStyle(s == step ? .primary : .secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { go(-1) }.controlSize(.large).keyboardShortcut(.cancelAction)
            }
            if let saveError {
                Label(saveError, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            }
            Spacer()
            switch step {
            case .welcome:
                Button("Get Started") { go(1) }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            case .key:
                Button("Continue") {
                    if let e = model.saveKey() { saveError = e } else { saveError = nil; go(1) }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .disabled(!(model.keyWorks || (model.keyIsSaved && model.keyStatus != .checking))) // saved key: OpenRouter may just be unreachable
            case .permissions:
                Button(model.micStatus == .authorized && model.axTrusted ? "Continue" : "Continue Anyway") { go(1) }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            case .test:
                Button("Finish") { onFinish() }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            default:
                Button("Continue") { go(1) }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func go(_ d: Int) {
        saveError = nil
        if let s = Step(rawValue: step.rawValue + d) { model.onboardingStep = s }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .key: keyStep
        case .permissions: permissions
        case .hotkeys: hotkeys
        case .mode: modeStep
        case .test: TestStep(model: model)
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            AppGlyph(size: 96)
            VStack(spacing: 8) {
                Text("Welcome to Utter").font(.system(size: 34, weight: .bold))
                Text("Talk instead of type, in any app. Hold a key, speak,\nlet go, and your words appear where you're typing.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 14) {
                feature("bolt.fill", .orange, "Quick", "Text lands about a second after you let go.")
                feature("sparkles", .purple, "Clean", "Ums, repeats and self-corrections are left out; your names are spelled right.")
                feature("key.fill", .blue, "Yours", "Runs on your own OpenRouter key; audio goes only to the model you pick.")
            }
            .padding(.top, 6)
            .frame(width: 470)
        }
    }

    private func feature(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(color).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Connect OpenRouter", "Utter sends your speech to Gemini through OpenRouter, on your own key. It is kept in your Mac's Keychain.")
            VStack(alignment: .leading, spacing: 10) {
                Text("OpenRouter API key").font(.headline)
                KeyField(model: model)
                KeyStatusLine(status: model.keyStatus).font(.callout)
                if model.keyIsSaved, model.keyWorks {
                    Text("This is the key already saved in your Keychain.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                Link("No key yet? Create one at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!)
            }
            .font(.callout)
        }
        .onAppear { model.loadKey(); model.checkKey() }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 22) {
            header("Allow two things", "macOS asks you once for each. The status here updates as soon as you switch them on.")
            VStack(spacing: 0) {
                PermissionRow(icon: "mic.fill", title: "Microphone", detail: "To hear you while you hold the hotkey. Nothing is recorded otherwise.",
                              ok: model.micStatus == .authorized, okText: "Allowed",
                              button: model.micStatus == .notDetermined ? "Allow…" : "Open Settings…") { model.allowMicrophone() }
                    .padding(16)
                Divider().padding(.leading, 66)
                PermissionRow(icon: "keyboard.fill", title: "Accessibility",
                              detail: "To notice the hotkey in any app and paste the text where you're typing. Switch on Utter in the list.",
                              ok: model.axTrusted, okText: "Allowed", button: "Open Settings…") { model.openAccessibility() }
                    .padding(16)
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            if model.axTrusted && !model.tapRunning {
                Label("Accessibility is on, but the hotkey hasn't started yet. If it stays like this, allow Utter under Input Monitoring.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                Button("Open Input Monitoring…") { model.openInputMonitoring() }
            }
        }
    }

    private var hotkeys: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("A key per mode", "Hold a mode's key anywhere you can type, speak, and let go: your words appear where the cursor is. Double-tap it for hands-free.")
            ModeKeyRows(model: model, context: "setup", placeholder: "Record key")
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            KeyStatusSlot(model: model, hint: "Click a field, then press one modifier (fn, ⌥, right ⌘…), several together (fn ⇧, ⇧⌘) or a key combination (⌃⌥D). A mode without a key can't be started.")
                .trackFrame("setup status")
            // Reserved whether or not fn is used, so nothing below the rows moves.
            ZStack(alignment: .leading) {
                if model.usesFn { FnKeyCallout(model: model, compact: true).transition(.opacity) }
            }
            .frame(height: 22)
            .animation(.easeInOut(duration: 0.18), value: model.usesFn)
        }
    }

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Four modes, one key each", "Auto picks Instant for short dictations and Balanced for longer ones. Models can be changed in Settings › Modes.")
            ModeCards(model: model)
        }
    }
}

/// The last step: a field to dictate into, and what happened.
struct TestStep: View {
    @ObservedObject var model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var startCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Try it").font(.system(size: 26, weight: .bold))
                Text(model.hintKey.map { "\(Hotkey.holdHint($0.key)). Say a sentence or two." } ?? "Give a mode a key first (go back to Hotkeys).")
                    .font(.title3).foregroundStyle(.secondary)
            }
            if let missing {
                Label(missing, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.title3)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(10)
                if text.isEmpty {
                    Text(model.recording ? "Listening…" : "Your words will appear here.")
                        .font(.title3).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 170)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.recording ? Color.red.opacity(0.7) : .clear, lineWidth: 2))
            result
            Text(model.hintKey.map { "\(Hotkey.handsFreeHint($0.key)). Esc cancels." } ?? "")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { focused = true; model.clearLastOutcome(); model.refreshPermissions() }
    }

    private var missing: String? {
        if model.savedKey == nil { return "Add your OpenRouter key first (go back to OpenRouter Key)." }
        if model.micStatus != .authorized { return "Utter can't hear you yet: allow the Microphone under Permissions." }
        if !model.axTrusted { return "The hotkey needs Accessibility: switch it on under Permissions." }
        if !model.tapRunning { return "The hotkey hasn't started yet: check Input Monitoring under Permissions." }
        return nil
    }

    @ViewBuilder private var result: some View {
        if let o = model.lastOutcome {
            if let e = o.error {
                Label("That didn't work: \(e)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else if o.text.isEmpty {
                Label("Didn't catch any words. Hold the key a little longer and speak up.", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            } else if o.delivery != .pasted {
                Label(o.delivery == .copiedNoField ? "No text field had the focus, so the text is on the clipboard."
                      : o.delivery == .copiedUnconfirmed ? "Utter couldn't see the text arrive in a field, so it's on the clipboard too."
                      : "The focus moved, so the text is on the clipboard instead.",
                      systemImage: "doc.on.clipboard").foregroundStyle(.orange)
            } else {
                Label(String(format: "Done in %.2f s after you let go, with %@.", o.releaseToText, ModelNames.text(o.model)),
                      systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } else {
            Text(" ")
        }
    }
}

enum ModelNames {
    /// "google/a+google/b" → "Gemini A + Gemini B".
    static func text(_ ids: String) -> String {
        ids.split(separator: "+").map { Model(String($0)).name }.joined(separator: " + ")
    }
}

/// The app icon (see `Logo`) as a bare tile `size` points wide, for Utter's own windows.
struct AppGlyph: View {
    var size: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 185 / 824, style: .continuous)
        // The tile alone, no shadow: the icon grid's shadow shows as a box at small sizes. A hairline edge keeps the dark
        // tile apart from a dark sidebar.
        Image(nsImage: Logo.appIcon(size: max(64, size * 2), framed: false))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
    }
}
