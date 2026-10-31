import AVFoundation
import SwiftUI
import UtterCore

// MARK: - Pieces shared with the onboarding

/// A key field for each mode, in rows of one fixed height: hold the key to talk in that mode, double-tap it for
/// hands-free. Messages go to the `KeyStatusSlot` below, so rows never move.
struct ModeKeyRows: View {
    @ObservedObject var model: AppModel
    /// Field ids are "<context>.<mode>", unique per window.
    var context = "setup"
    var placeholder = "No key"

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Mode.allCases.enumerated()), id: \.element) { i, m in
                if i > 0 { Divider() }
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title).font(.headline)
                        Text(m.detail(model.models, autoAfter: model.autoAfter)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    HotkeyField(id: "\(context).\(m.rawValue)", hotkey: model.modeHotkeys[m], placeholder: placeholder) {
                        model.setModeHotkey($0, for: m)
                    }
                }
                .frame(height: 50)
                .trackFrame("\(context) row \(m.title)")
            }
        }
    }
}

/// The four modes as cards, each with its key: information, nothing to select.
struct ModeCards: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Mode.allCases, id: \.self) { m in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.title).font(.headline)
                        Text(blurb(m)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    KeyBadge(hotkey: model.modeHotkeys[m])
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
            }
        }
    }

    private func blurb(_ m: Mode) -> String {
        let ms = model.models
        switch m {
        case .auto: return "\(ms.fast.name) under \(Int(model.autoAfter)) s, \(ms.accurate.name) for longer"
        case .fast: return "\(ms.fast.name) · quickest, about a second"
        case .accurate: return "\(ms.accurate.name) · better with names and long dictations"
        case .veryAccurate: return "\(ms.veryAccurate.name) · the strongest, a few seconds slower"
        }
    }
}

/// A mode's key as a small label, or "No key".
struct KeyBadge: View {
    var hotkey: Hotkey?
    var body: some View {
        if let hotkey {
            Text(hotkey.title(handsFree: false))
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
        } else {
            Text("No key").font(.callout).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Settings window

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, hotkeys, modes, prompt, vocabulary
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .hotkeys: return "Hotkeys"
        case .modes: return "Modes"
        case .prompt: return "Prompt"
        case .vocabulary: return "Vocabulary"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .hotkeys: return "keyboard.fill"
        case .modes: return "dial.medium.fill"
        case .prompt: return "text.bubble.fill"
        case .vocabulary: return "character.book.closed.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .hotkeys: return .blue
        case .modes: return .purple
        case .prompt: return .orange
        case .vocabulary: return .green
        }
    }
}

/// Settings, laid out like System Settings: a sidebar of pages, each a grouped form.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var onSetup: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                Text(model.settingsPage.title)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 28)
                    .padding(.top, 10)
                    .padding(.horizontal, 22)
                page
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
        .frame(width: 780, height: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 46) // the window buttons sit here
            ForEach(SettingsPage.allCases) { p in
                Button { model.settingsPage = p } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.tint.gradient))
                        Text(p.title)
                            .foregroundStyle(model.settingsPage == p ? Color.white : Color.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(model.settingsPage == p ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 8) {
                AppGlyph(size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Utter").font(.system(size: 12, weight: .semibold))
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterial())
    }

    @ViewBuilder private var page: some View {
        switch model.settingsPage {
        case .general: GeneralPage(model: model, onSetup: onSetup)
        case .hotkeys: HotkeysPage(model: model)
        case .modes: ModesPage(model: model)
        case .prompt: PromptPage(model: model)
        case .vocabulary: VocabularyPage(model: model)
        }
    }
}

/// The translucent sidebar material of System Settings and Finder.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct GeneralPage: View {
    @ObservedObject var model: AppModel
    var onSetup: () -> Void
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("API key") { KeyField(model: model).labelsHidden().frame(maxWidth: 280) }
                LabeledContent {
                    if model.keyWorks && !model.keyIsSaved {
                        Button("Save to Keychain") { saveError = model.saveKey() }
                    } else if model.keyIsSaved {
                        Text("Saved in Keychain").foregroundStyle(.secondary)
                    }
                } label: {
                    KeyStatusLine(status: model.keyStatus)
                }
                if let saveError { Text(saveError).foregroundStyle(.red) }
            } header: {
                Text("OpenRouter")
            } footer: {
                Link("Get a key at openrouter.ai/keys", destination: URL(string: "https://openrouter.ai/keys")!)
                    .font(.callout)
            }

            Section {
                ForEach(Mode.allCases, id: \.self) { m in
                    LabeledContent {
                        KeyBadge(hotkey: model.modeHotkeys[m])
                    } label: {
                        Text(m.title)
                        Text(m.detail(model.models, autoAfter: model.autoAfter))
                    }
                }
                if model.noKeys { NoKeysWarning() }
                LabeledContent("") { Button("Change Keys…") { model.settingsPage = .hotkeys } }
            } header: {
                Text("A key per mode")
            } footer: {
                Text("Hold a mode's key to talk, let go to paste. Double-tap it for hands-free.")
            }

            Section("Permissions") {
                permission("Microphone", "mic.fill", ok: model.micStatus == .authorized,
                           button: model.micStatus == .notDetermined ? "Allow…" : "Open Settings…") { model.allowMicrophone() }
                permission("Accessibility", "accessibility", ok: model.axTrusted, button: "Open Settings…") { model.openAccessibility() }
            }

            Section {
                LabeledContent("Setup") { Button("Run Setup Again…", action: onSetup) }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadKey(); model.checkKey() }
    }

    private func permission(_ title: String, _ symbol: String, ok: Bool, button: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            if ok {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(button, action: action)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

struct HotkeysPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(Mode.allCases, id: \.self) { m in
                    LabeledContent {
                        HotkeyField(id: "settings.\(m.rawValue)", hotkey: model.modeHotkeys[m]) { model.setModeHotkey($0, for: m) }
                    } label: {
                        Text(m.title)
                        Text(m.detail(model.models, autoAfter: model.autoAfter))
                    }
                    .frame(height: 36)
                    .trackFrame("settings row \(m.title)")
                }
            } header: {
                Text("A key per mode")
            } footer: {
                KeyStatusSlot(model: model, hint: "Hold a mode's key to talk, double-tap it for hands-free. Click a field, then press one modifier (fn, ⌥, right ⌘), several together (fn ⇧, ⇧⌘) or a key combination (⌃⌥D).")
                    .trackFrame("settings status")
            }
            // The fn note sits after everything, so it never moves the rows; it only depends on the keys set.
            if model.usesFn {
                Section { FnKeyCallout(model: model, compact: true) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shown when no mode has a key: nothing can start a dictation.
struct NoKeysWarning: View {
    var body: some View {
        Label("No mode has a key, so Utter can't be started. Give at least one mode a key.", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ModesPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            ForEach(Tier.allCases, id: \.self) { t in
                Section {
                    LabeledContent("Model") { ModelPickerButton(tier: t, model: model) }
                } header: {
                    Text(t.title)
                } footer: {
                    ModelCaption(tier: t, model: model)
                }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text("\(Int(model.autoAfter)) s").monospacedDigit()
                        Stepper("Seconds", value: $model.autoAfter, in: 5...60, step: 5).labelsHidden()
                    }
                } label: {
                    Text("Switch to Balanced after")
                    Text("Shorter dictations use Instant")
                }
            } header: {
                Text("Auto")
            } footer: {
                Text("Balanced and Thorough run Instant's model alongside as a backup: if theirs fails or is slow, Instant's text is pasted.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshModelList() }
    }
}

struct PromptPage: View {
    @ObservedObject var model: AppModel
    private var tab: Int { model.promptTab }
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Picker("View", selection: $model.promptTab) {
                    Text("Edit").tag(0)
                    Text("Preview what's sent").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Same height in both views, so switching moves nothing.
                ZStack(alignment: .topLeading) {
                    if tab == 0 {
                        TextEditor(text: $model.systemPrompt)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .transition(.opacity)
                    } else {
                        ScrollView {
                            Text(model.promptPreview)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(height: 300)
                .animation(.easeInOut(duration: 0.15), value: tab)
            } header: {
                HStack {
                    Text("Instructions sent with every dictation")
                    Spacer()
                    Text(model.promptIsDefault ? "Default" : "Edited")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(model.promptIsDefault ? Color.secondary.opacity(0.15) : Color.accentColor.opacity(0.2)))
                }
            } footer: {
                Text(tab == 0
                     ? "\(model.systemPrompt.count) characters. Your vocabulary (\(Vocabulary.parse(model.vocabularyText).count) terms), and on long dictations the text so far, are added after these."
                     : "The full system message for a short dictation: your instructions, then your vocabulary. Long dictations also carry the text so far.")
            }
            Section {
                LabeledContent(model.promptIsDefault ? "Using the default prompt" : "Using your own prompt") {
                    Button("Reset to Default…") { confirmReset = true }.disabled(model.promptIsDefault)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Replace your prompt with the default?", isPresented: $confirmReset) {
            Button("Reset to Default", role: .destructive) { model.resetPrompt() }
        } message: {
            Text("Your edits to the instructions will be lost.")
        }
    }
}

struct VocabularyPage: View {
    @ObservedObject var model: AppModel
    @State private var newTerm = ""
    @State private var asText = false

    private var terms: [String] { Vocabulary.parse(model.vocabularyText) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Add", text: $newTerm, prompt: Text("Add a name or term (commas add several)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Names and terms")
            } footer: {
                Text("Spelled exactly as written in every dictation, even where a common word sounds the same.")
            }
            Section {
                if terms.isEmpty {
                    Text("No words yet.").foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(terms, id: \.self) { t in
                            TokenChip(text: t) { withAnimation(.easeInOut(duration: 0.15)) { model.vocabularyText = Vocabulary.removing(t, from: model.vocabularyText) } }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("\(terms.count) \(terms.count == 1 ? "entry" : "entries"). Changes apply to the next dictation.")
            }
            Section {
                DisclosureGroup("Edit as text", isExpanded: $asText) {
                    TextEditor(text: $model.vocabularyText)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(height: 150)
                }
            } footer: {
                if asText { Text("One per line. Lines starting with # are notes.") }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let t = newTerm.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.vocabularyText = Vocabulary.adding(t, to: model.vocabularyText) }
        newTerm = ""
    }
}

/// A vocabulary word as a removable chip.
struct TokenChip: View {
    var text: String
    var onRemove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .help("Remove “\(text)”")
        }
        .font(.callout)
        .padding(.leading, 10).padding(.trailing, 7).padding(.vertical, 4)
        .background(Capsule().fill(Color.accentColor.opacity(hover ? 0.22 : 0.14)))
        .onHover { hover = $0 }
    }
}

/// Lays out views left to right, wrapping to new lines (the vocabulary chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
