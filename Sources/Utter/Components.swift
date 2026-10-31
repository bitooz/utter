import AppKit
import AVFoundation
import SwiftUI
import UtterCore

// MARK: - Hotkey field

/// What the key fields are doing: which one is recording, what is held, the last error. Shown in one reserved line
/// under the rows (`KeyStatusSlot`), never inside a row, so nothing moves while recording.
@MainActor
final class KeyRecordingStatus: ObservableObject {
    static let shared = KeyRecordingStatus()
    /// The field recording now (`HotkeyField.id`), if any.
    @Published var field: String?
    /// What is held right now ("fn ⇧").
    @Published var live = ""
    @Published var error: String?
}

/// Records a key for one field: a modifier on its own (⌥, right ⌘, fn), two or more modifiers together (fn ⇧, ⇧⌘),
/// or modifiers with a key (⌃⌥D). While it records, the keys are paused so pressing them doesn't start a dictation.
@MainActor
final class HotkeyRecorder {
    static let shared = HotkeyRecorder()
    private let status = KeyRecordingStatus.shared
    private var monitor: Any?
    private var recording = HotkeyRecording()
    private var done: ((Hotkey) -> Void)?

    func start(_ id: String, _ done: @escaping (Hotkey) -> Void) {
        stop()
        self.done = done
        recording = HotkeyRecording()
        status.field = id
        status.live = ""
        status.error = nil
        AppModel.shared.controller.tap.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        done = nil
        if status.field != nil { status.field = nil; status.live = "" }
        AppModel.shared.controller.tap.paused = false
    }

    /// Returns true to swallow the event.
    private func handle(_ e: NSEvent) -> Bool {
        let flags = UInt64(e.modifierFlags.rawValue)
        let outcome: HotkeyRecording.Outcome?
        switch e.type {
        case .flagsChanged:
            status.live = HotkeyRecording.liveText(flags)
            outcome = recording.flagsChanged(keyCode: Int(e.keyCode), flags: flags)
        case .keyDown:
            let label = Hotkey.keyName(Int(e.keyCode)) ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
            outcome = recording.keyDown(keyCode: Int(e.keyCode), flags: flags, label: label)
        default:
            return false
        }
        switch outcome {
        case .hotkey(let h)?:
            let done = self.done
            status.error = nil
            stop()
            done?(h)
        case .problem(let p)?:
            status.error = p
        case .cancel?:
            status.error = nil
            stop()
        case nil:
            break
        }
        return true
    }
}

/// A key field of fixed size: the key (or a placeholder), with a reserved column for its clear button.
/// While recording it shows what is held, in the accent color; messages go to `KeyStatusSlot`.
struct HotkeyField: View {
    /// Which field this is, unique per window ("setup.auto").
    var id: String
    var hotkey: Hotkey?
    var placeholder = "No key"
    var onChange: (Hotkey?) -> Void
    @ObservedObject private var status = KeyRecordingStatus.shared

    private var recording: Bool { status.field == id }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? HotkeyRecorder.shared.stop() : HotkeyRecorder.shared.start(id) { onChange($0) }
            } label: {
                ZStack {
                    if recording {
                        Text(status.live.isEmpty ? "Press keys…" : status.live).foregroundStyle(Color.accentColor)
                    } else if let hotkey {
                        Text(hotkey.title(handsFree: false))
                    } else {
                        Text(placeholder).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .frame(width: 160)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(recording ? 0.8 : 0), lineWidth: 1.5))
            .help("Click, then press a modifier on its own, several modifiers together, or a key combination. Esc keeps the current one.")
            // Fixed column, so fields line up whether or not there is something to clear.
            Button { onChange(nil) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this key")
                .opacity(hotkey != nil && !recording ? 1 : 0)
                .disabled(hotkey == nil || recording)
                .frame(width: 16)
        }
        .animation(.easeInOut(duration: 0.15), value: recording)
        .onDisappear { if recording { HotkeyRecorder.shared.stop() } }
    }
}

/// One reserved line (two at most) under the key rows: what to press while recording, an error, a clash, a note,
/// or the default hint. Fixed height, so the rows above and anything below never move; changes fade.
struct KeyStatusSlot: View {
    @ObservedObject var model: AppModel
    var hint: String
    @ObservedObject private var status = KeyRecordingStatus.shared

    private var line: (text: String, icon: String?, color: Color) {
        if status.field != nil {
            if let e = status.error { return (e, "exclamationmark.triangle.fill", .orange) }
            return ("Hold one modifier, or several together (fn ⇧, ⇧⌘), and let go; or press a key combination. Esc keeps the current key.",
                    "record.circle", .accentColor)
        }
        if model.noKeys { return ("No mode has a key, so Utter can't be started. Give at least one mode a key.", "exclamationmark.triangle.fill", .orange) }
        let clashes = model.clashes
        if let c = clashes.first {
            return (c + (clashes.count > 1 ? " (and \(clashes.count - 1) more)" : ""), "exclamationmark.triangle.fill", .orange)
        }
        if let n = model.hotkeyNotes.first { return (n, "info.circle.fill", .blue) }
        return (hint, nil, .secondary)
    }

    var body: some View {
        let l = line
        HStack(alignment: .top, spacing: 6) {
            if let icon = l.icon { Image(systemName: icon).foregroundStyle(l.color) }
            Text(l.text).foregroundStyle(l.icon == nil ? Color.secondary : l.color == .blue ? Color.secondary : l.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .id(l.text)
        .transition(.opacity)
        .frame(height: 36, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.18), value: l.text)
    }
}

/// Records a view's frame in the window under a name, so `--capture-ui` can show that rows don't move between states.
enum FrameLog {
    @MainActor static var frames: [String: CGRect] = [:]
}

extension View {
    func trackFrame(_ name: String) -> some View {
        background(GeometryReader { g in
            Color.clear
                .onAppear { FrameLog.frames[name] = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in FrameLog.frames[name] = f }
        })
    }
}

// MARK: - Model field

/// The model behind a mode: a button showing it, opening a searchable picker.
struct ModelPickerButton: View {
    let tier: Tier
    @ObservedObject var model: AppModel
    private var open: Binding<Bool> {
        Binding(get: { model.pickerTier == tier }, set: { model.pickerTier = $0 ? tier : nil })
    }

    var body: some View {
        let current = model.models[tier]
        Button { model.pickerTier = tier } label: {
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(current.name)
                    Text(current.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .popover(isPresented: open, arrowEdge: .bottom) {
            ModelPickerList(tier: tier, model: model) { model.pickerTier = nil }
        }
    }
}

/// Search OpenRouter's audio-input models: recommended ones first, each with its name, id, price and audio support.
/// Any model id can also be typed.
struct ModelPickerList: View {
    let tier: Tier
    @ObservedObject var model: AppModel
    var close: () -> Void
    @State private var query = ""
    @State private var custom = ""

    /// The three models Utter is tuned for (routes, reasoning), whatever the tier.
    private static let recommended: [(Model, String)] = [(.lite, "Instant's default"), (.flash, "Balanced's default"), (.argon, "Thorough's default")]

    private func matches(_ id: String, _ name: String) -> Bool {
        query.isEmpty || id.localizedCaseInsensitiveContains(query) || name.localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        let current = model.models[tier].id
        let rec = Self.recommended.filter { matches($0.0.id, $0.0.name) }
        let recIDs = Set(Self.recommended.map(\.0.id))
        let others = model.audioModels.filter { !recIDs.contains($0.id) && matches($0.id, $0.name) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $query).textFieldStyle(.plain).multilineTextAlignment(.leading)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.1)))
            .padding(10)
            List {
                if !rec.isEmpty {
                    Section("Recommended") {
                        ForEach(rec, id: \.0.id) { m, note in
                            row(id: m.id, name: m.name, info: model.audioModels.first { $0.id == m.id }, note: note, current: current)
                        }
                    }
                }
                Section(model.audioModels.isEmpty ? (model.modelListError ?? "Loading OpenRouter's models…") : "All models that take audio") {
                    ForEach(others, id: \.id) { m in row(id: m.id, name: m.name, info: m, note: nil, current: current) }
                }
            }
            .listStyle(.inset)
            .frame(height: 300)
            Divider()
            HStack(spacing: 8) {
                TextField("Or type a model id", text: $custom, prompt: Text("Or type any model id (provider/model)"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(useCustom)
                Button("Use", action: useCustom).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .frame(width: 460)
        .onAppear { model.refreshModelList() }
    }

    private func row(id: String, name: String, info: OpenRouter.ModelInfo?, note: String?, current: String) -> some View {
        Button { model.setModel(id, for: tier); close() } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor).opacity(id == current ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(name).fontWeight(.medium)
                        if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let p = info?.audioPricePerMillion ?? info?.pricePerMillion {
                    Text(String(format: "$%.2f/M", p)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Dollars per million audio input tokens")
                }
                Label("Audio", systemImage: "waveform").labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                    .foregroundStyle(.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func useCustom() {
        let id = custom.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        model.setModel(id, for: tier)
        close()
    }
}

/// What the saved model for a tier is: its name, default or not, its price; or a warning for an unknown id.
struct ModelCaption: View {
    let tier: Tier
    @ObservedObject var model: AppModel

    var body: some View {
        let id = model.models[tier].id
        let info = model.audioModels.first { $0.id == id }
        let known = model.audioModels.isEmpty || info != nil || id == tier.defaultModel.id
        if known {
            Text(Model(id).name + (id == tier.defaultModel.id ? " (default)" : "")
                 + ((info?.audioPricePerMillion ?? info?.pricePerMillion).map { String(format: " · $%.2f per million audio input tokens", $0) } ?? ""))
        } else {
            Text("Not in OpenRouter's list of audio models: check the id.").foregroundStyle(.orange)
        }
    }
}

// MARK: - Small pieces

struct StatusDot: View {
    var ok: Bool
    var body: some View {
        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? .green : .orange)
            .imageScale(.large)
    }
}

struct PermissionRow: View {
    var icon: String
    var title: String
    var detail: String
    var ok: Bool
    var okText: String
    var button: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9).fill(ok ? Color.green.gradient : Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if ok {
                Label(okText, systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            } else {
                Button(button, action: action).controlSize(.large)
            }
        }
    }
}

struct KeyStatusLine: View {
    var status: AppModel.KeyStatus
    var body: some View {
        switch status {
        case .none: EmptyView()
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking with OpenRouter…").foregroundStyle(.secondary) }
        case .ok(let s):
            Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .bad(let s):
            Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// The key field with a show/hide toggle.
struct KeyField: View {
    @ObservedObject var model: AppModel
    @State private var reveal = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if reveal {
                    TextField("API key", text: $model.keyField, prompt: Text("sk-or-v1-…"))
                } else {
                    SecureField("API key", text: $model.keyField, prompt: Text("sk-or-v1-…"))
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .onChange(of: model.keyField) { _, _ in model.checkKey(after: 0.5) }
            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(reveal ? "Hide the key" : "Show the key")
        }
    }
}

/// Hotkey clashes (orange: only one of them will work), then side notes (blue: both work, each on its own side).
struct ClashList: View {
    var clashes: [String]
    var notes: [String] = []
    var body: some View {
        if !clashes.isEmpty || !notes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(clashes, id: \.self) { c in
                    Label(c, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(notes, id: \.self) { n in
                    Label { Text(n).foregroundStyle(.secondary) } icon: { Image(systemName: "info.circle.fill").foregroundStyle(.blue) }
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// When fn is a mode's key: whether macOS's own fn action is off, and a button that turns it off.
/// `compact`: one line and small buttons, for the setup and Settings rows.
struct FnKeyCallout: View {
    @ObservedObject var model: AppModel
    var compact = false

    var body: some View {
        if model.fnFree {
            Label("fn is set to “Do Nothing” in macOS, so it only talks to Utter.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(compact ? .callout : .body)
        } else if compact {
            HStack(spacing: 8) {
                Label("fn also opens a macOS popup.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).lineLimit(1)
                Spacer(minLength: 4)
                Button("Set fn to Do Nothing") { model.freeFnKey() }
                Button("Keyboard Settings…") { model.openKeyboardSettings() }
            }
            .font(.callout)
            .controlSize(.small)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.fnAction.map { "In macOS, the fn key also does “\($0.title)”" } ?? "In macOS, the fn key also opens a popup")
                            .fontWeight(.semibold)
                        Text("Set it to “Do Nothing” so holding fn doesn't also open the emoji picker or Apple Dictation.")
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Set fn to Do Nothing") { model.freeFnKey() }.buttonStyle(.borderedProminent)
                    Button("Open Keyboard Settings…") { model.openKeyboardSettings() }
                }
                .padding(.leading, 26)
            }
        }
    }
}
