import FluidAudio
import SwiftUI

/// The Fluent window (design/app.html): History first, then settings. Monochrome, SF Pro
/// throughout, the pill's icons (Controls.swift), tooltips for minor actions.
struct MainWindow: View {
    let permissions: Permissions
    let inspector: FocusInspector
    let dictation: DictationController
    @State private var section: Section? = {
        // `--pane <name>` opens a given section (used by the window capture check).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--pane"), i + 1 < args.count { return Section(rawValue: args[i + 1]) }
        return .history
    }()

    private static let menuPreview: Bool = {
        let args = CommandLine.arguments
        return args.firstIndex(of: "--pane").map { $0 + 1 < args.count && args[$0 + 1] == "menu" } ?? false
    }()

    enum Section: String, CaseIterable, Identifiable {
        case history, transcribe, dictionary, snippets, dictation, appearance, models, setup
        var id: String { rawValue }
        var title: String {
            switch self {
            case .history: "History"
            case .transcribe: "Transcribe a file"
            case .dictionary: "Dictionary"
            case .snippets: "Snippets"
            case .dictation: "Dictation"
            case .appearance: "Appearance"
            case .models: "Models"
            case .setup: "Setup"
            }
        }
        var symbol: String {
            switch self {
            case .history: "clock.arrow.circlepath"
            case .transcribe: "waveform.badge.plus"
            case .dictionary: "character.book.closed"
            case .snippets: "text.badge.plus"
            case .dictation: "mic.fill"
            case .appearance: "circle.lefthalf.filled"
            case .models: "cpu"
            case .setup: "checkmark.shield"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    StatusChip(dictation: dictation).padding(.bottom, 10)
                    item(.history, count: dictation.history.entries.count)
                    item(.transcribe)
                    item(.dictionary, count: dictation.dictionary.entries.count)
                    item(.snippets, count: dictation.snippets.items.count)
                    Text("Settings").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.leading, 10).padding(.top, 14).padding(.bottom, 4)
                    ForEach([Section.dictation, .appearance, .models, .setup]) { item($0) }
                }
                .padding(.horizontal, 10)
            }
            .padding(.top, 8)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Group {
                if Self.menuPreview {
                    // `--pane menu`: the menu bar panel, so the window capture can check it.
                    MenuPanel(dictation: dictation)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 12))
                        .padding(40)
                } else {
                switch section ?? .history {
                case .history: HistoryPane(history: dictation.history, dictation: dictation)
                case .transcribe: TranscribePane(dictation: dictation)
                case .dictionary: DictionaryPane(dictionary: dictation.dictionary)
                case .snippets: SnippetsPane(snippets: dictation.snippets, hotkey: dictation.hotkey)
                case .dictation: DictationPane(dictation: dictation)
                case .appearance: AppearancePane()
                case .models: ModelsPane(dictation: dictation)
                case .setup: ScrollView { SetupView(permissions: permissions, inspector: inspector, dictation: dictation) }
                }
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 820, minHeight: 560)
        .tint(.primary)
        .onAppear {
            // A menu bar app has no Dock icon; show one while this window is open.
            NSApp.setActivationPolicy(.regular)
            DiagnosticModes.captureWindowIfRequested()
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }

    private func item(_ s: Section, count: Int? = nil) -> some View {
        SidebarItem(title: s.title, symbol: s.symbol, count: count, selected: (section ?? .history) == s) { section = s }
    }
}

/// One sidebar entry: the whole row is clickable, lights up on hover, and the pill's round icon.
private struct SidebarItem: View {
    let title: String
    let symbol: String
    let count: Int?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Glyph(symbol: symbol, size: 24, strong: selected)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                Spacer(minLength: 4)
                if let count, count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(selected ? 0.09 : hovering ? 0.05 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Sidebar status

/// Small black tile with seven idle comb lines, plus what Fluent is doing.
struct StatusChip: View {
    let dictation: DictationController
    /// Only animate while you're recording and this window is on screen: SwiftUI keeps the window's
    /// views alive after it closes, and a running animation there cost ~12% CPU around the clock.
    @State private var onScreen = false

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !(onScreen && dictation.isRecording))) { context in
                Canvas { ctx, size in
                    let t = context.date.timeIntervalSinceReferenceDate
                    var comb = Path()
                    let gap = 3.2, x0 = size.width / 2 - 3 * gap
                    for i in 0..<7 {
                        let env = sin(Double.pi * (Double(i) + 0.5) / 7)
                        let swell = dictation.isRecording ? 0.5 + 0.5 * sin(t * 9 - Double(i)) : 0.5 + 0.5 * sin(t * 1.6 - Double(i) * 0.75)
                        let h = 1.2 + env * (2.2 + (dictation.isRecording ? 7 : 4.2) * swell)
                        comb.move(to: CGPoint(x: x0 + Double(i) * gap, y: size.height / 2 - h))
                        comb.addLine(to: CGPoint(x: x0 + Double(i) * gap, y: size.height / 2 + h))
                    }
                    ctx.stroke(comb, with: .color(.white.opacity(0.88)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text(headline).font(.system(size: 13, weight: .semibold))
                Text(ModelCatalog.model(dictation.modelID).name + (ModelCatalog.model(dictation.modelID).isServer ? " · server" : " · on device"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    private var headline: String {
        switch dictation.modelState {
        case .failed: "Needs attention"
        case .loading: "Loading model"
        case .ready: dictation.isRecording ? "Listening" : dictation.pending > 0 ? "Transcribing" : "Ready"
        }
    }
}

// MARK: - History

private struct HistoryPane: View {
    let history: HistoryStore
    let dictation: DictationController
    @State private var query = ""

    private var filtered: [HistoryStore.Entry] {
        query.isEmpty ? history.entries
            : history.entries.filter { $0.text.localizedCaseInsensitiveContains(query) || $0.app.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "History") {
                TextField("Search what you've said", text: $query)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
            if !history.entries.isEmpty, query.isEmpty { DashboardView(stats: DashboardStats(history.entries)) }
            if let held = dictation.held {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Waiting for a text box", systemImage: "pin").font(.caption).foregroundStyle(.secondary)
                    Text(held.text).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Button("Drop in next box I click") {}.buttonStyle(PrimaryButtonStyle()).disabled(true)
                            .help("Click into any text box; Fluent asks once, then drops it in.")
                        RowButton(symbol: "doc.on.doc", help: "Copy") { dictation.copyHeld() }
                        RowButton(symbol: "trash", help: "Discard (kept in History)") { dictation.discardHeld() }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 24).padding(.bottom, 8)
            }
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Nothing dictated yet" : "No matches",
                                       systemImage: "waveform",
                                       description: Text(query.isEmpty ? "Everything you dictate shows up here, with where it went." : "Try a different word."))
            } else {
                List {
                    ForEach(groupedByDay, id: \.0) { day, entries in
                        SwiftUI.Section(day) {
                            ForEach(entries) { HistoryRow(entry: $0, onDelete: { history.delete($0) }) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var groupedByDay: [(String, [HistoryStore.Entry])] {
        let cal = Calendar.current
        var groups: [(String, [HistoryStore.Entry])] = []
        for e in filtered {
            let label = cal.isDateInToday(e.date) ? "Today" : cal.isDateInYesterday(e.date) ? "Yesterday"
                : e.date.formatted(.dateTime.weekday(.wide).month().day())
            if groups.last?.0 == label { groups[groups.count - 1].1.append(e) } else { groups.append((label, [e])) }
        }
        return groups
    }
}

private struct HistoryRow: View {
    let entry: HistoryStore.Entry
    let onDelete: (HistoryStore.Entry) -> Void
    @State private var hovering = false
    @State private var showRaw = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(entry.date.formatted(.dateTime.hour().minute()))
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(showRaw ? entry.raw : entry.text).textSelection(.enabled)
                HStack(spacing: 12) {
                    Label(entry.app, systemImage: "arrow.turn.down.right")
                    Label(String(format: "%.2fs", entry.seconds), systemImage: "bolt")
                        .monospacedDigit()
                        .help("From the end of speaking to the text arriving")
                    if entry.method.hasPrefix("Pasted") {
                        Image(systemName: "doc.on.clipboard").help(entry.method)
                    }
                    if entry.raw != entry.text {
                        Image(systemName: "wand.and.stars").help("Cleaned up. Show what was heard with the code icon.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                RowButton(symbol: "doc.on.doc", help: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }
                if entry.raw != entry.text {
                    RowButton(symbol: "chevron.left.forwardslash.chevron.right", help: showRaw ? "Show what was typed" : "Show what was heard") {
                        showRaw.toggle()
                    }
                }
                RowButton(symbol: "trash", help: "Delete") { onDelete(entry) }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        HoverIconButton(symbol: symbol, help: help, action: action)
    }
}

// MARK: - Settings panes

private struct PaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            Text(title).font(.system(size: 20, weight: .semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 10)
    }
}

private struct SettingRow<Content: View>: View {
    let title: String
    var symbol: String? = nil
    var detail: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let symbol { Glyph(symbol: symbol) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(width: 210, alignment: .leading)
            Spacer(minLength: 12)
            content.frame(alignment: .trailing)
        }
        .padding(.vertical, 12)
    }
}

private extension Divider {
    /// Rule between setting rows, starting under the text rather than the icon.
    var inset: some View { padding(.leading, 38) }
}

private struct DictationPane: View {
    let dictation: DictationController
    @AppStorage("cleanup") private var cleanup = true
    @AppStorage("keepRecordings") private var keepRecordings = true
    @AppStorage("formatLists") private var formatLists = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader(title: "Dictation") { EmptyView() }
                VStack(spacing: 0) {
                    KeyCard(hotkey: dictation.hotkey).padding(.bottom, 8)
                    SettingRow(title: "Mode", symbol: "hand.tap.fill", detail: dictation.mode.help) {
                        MonoSegmented(selection: Binding(get: { dictation.mode }, set: { dictation.setMode($0) }),
                                      options: DictationController.Mode.allCases.map { ($0, $0.label) })
                    }
                    Divider().inset
                    SettingRow(title: "Language", symbol: "globe", detail: dictation.language.help) {
                        MonoSegmented(selection: Binding(get: { dictation.language }, set: { dictation.setLanguage($0) }),
                                      options: [(.english, "English"), (.multilingual, "Multilingual")])
                    }
                    Divider().inset
                    SettingRow(title: "Clean up", symbol: "wand.and.stars",
                               detail: Cleaner.isAvailable
                                ? "Removes fillers, applies \"no wait\" corrections, writes addresses and numbers. Runs on this Mac. Skipped in terminals and code editors."
                                : "Needs Apple Intelligence (System Settings, Apple Intelligence & Siri).") {
                        Toggle("", isOn: $cleanup).toggleStyle(MonoSwitch()).labelsHidden().disabled(!Cleaner.isAvailable)
                            .onChange(of: cleanup) { dictation.refreshWidgetSettings() }
                    }
                    Divider().inset
                    SettingRow(title: "Lists", symbol: "list.bullet", detail: "In email and everything else, \"one... two...\" or \"first... second...\" becomes a numbered list, and email gets its greeting and sign-off on their own lines. Never in messages, AI chats or one-line boxes like search.") {
                        Toggle("", isOn: $formatLists).toggleStyle(MonoSwitch()).labelsHidden()
                    }
                    Divider().inset
                    ForEach(AppCategory.allCases) { StyleRow(category: $0) }
                    SettingRow(title: "Open at login", symbol: "power", detail: "Start Fluent when you log in to this Mac.") {
                        Toggle("", isOn: Binding(get: { LoginItem.isOn }, set: { LoginItem.set($0) }))
                            .toggleStyle(MonoSwitch()).labelsHidden()
                    }
                    Divider().inset
                    SettingRow(title: "Recordings", symbol: "waveform", detail: "Keep your last \(Recordings.keep) recordings on this Mac, to check accuracy against your real voice. Never uploaded.") {
                        HStack {
                            Button("Show in Finder") { NSWorkspace.shared.open(Recordings.folder) }.buttonStyle(GhostButtonStyle())
                            Toggle("", isOn: $keepRecordings).toggleStyle(MonoSwitch()).labelsHidden()
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

/// One app category's writing style (Wispr Flow's Styles): punctuation and capitals only.
private struct StyleRow: View {
    let category: AppCategory
    @AppStorage private var style: String

    init(category: AppCategory) {
        self.category = category
        _style = AppStorage(wrappedValue: category.defaultStyle.rawValue, "style.\(category.rawValue)")
    }

    private var symbol: String {
        switch category {
        case .personal: "message.fill"
        case .work: "briefcase.fill"
        case .email: "envelope.fill"
        case .other: "doc.text.fill"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(title: category.title, symbol: symbol,
                       detail: category.examples + ". " + (WritingStyle(rawValue: style) ?? category.defaultStyle).help) {
                MonoSegmented(selection: $style, options: category.styles.map { ($0.rawValue, $0.label) })
            }
            Divider().inset
        }
    }
}

private struct AppearancePane: View {
    @AppStorage("showPillWhenIdle") private var showPillWhenIdle = false
    @AppStorage("widgetUnderTextBox") private var underTextBox = false
    @AppStorage("menuIcon") private var menuIcon = MenuBarIcon.comb.rawValue
    @AppStorage("waveStyle") private var waveStyle = CombWave.Style.comb.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Appearance") { EmptyView() }
            VStack(spacing: 0) {
                SettingRow(title: "Pill position", symbol: "capsule.fill", detail: "Where the pill appears while you dictate.") {
                    MonoSegmented(selection: $underTextBox, options: [(false, "Bottom of the screen"), (true, "Under the text box")])
                }
                Divider().inset
                SettingRow(title: "When not dictating", symbol: "eye.slash", detail: "Keep a small pill at the bottom of the screen that expands on hover.") {
                    Toggle("", isOn: $showPillWhenIdle).toggleStyle(MonoSwitch()).labelsHidden()
                }
                Divider().inset
                SettingRow(title: "Menu bar icon", symbol: "menubar.rectangle", detail: "Shown in the menu bar; it changes while you're recording.") {
                    Picker("", selection: $menuIcon) {
                        ForEach(MenuBarIcon.allCases) { icon in
                            Label { Text(icon.label) } icon: { Image(nsImage: icon.image(recording: false)) }.tag(icon.rawValue)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider().inset
                SettingRow(title: "Waveform", symbol: "waveform", detail: "How the pill moves while you talk. Each preview plays as if you were speaking.") {
                    HStack(spacing: 10) {
                        ForEach(CombWave.Style.allCases) { style in
                            WavePreview(style: style, selected: waveStyle == style.rawValue) { waveStyle = style.rawValue }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }
}

/// One waveform choice, drawn live on a small pill so you can see it move before picking it.
private struct WavePreview: View {
    let style: CombWave.Style
    let selected: Bool
    let action: () -> Void
    @State private var wave = CombWave()
    @State private var hovering = false
    /// Animate only while the pane is on screen; the window's views outlive it being closed.
    @State private var onScreen = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !onScreen)) { context in
                    Canvas { ctx, size in
                        let t = context.date.timeIntervalSinceReferenceDate
                        // A made-up voice: syllables riding on phrases, with short pauses.
                        let speech = max(0, sin(t * 2.1)) * (0.55 + 0.45 * abs(sin(t * 7.3)))
                        wave.style = style
                        wave.step(level: Float(speech * 0.6), now: context.date)
                        wave.draw(in: ctx, size: size)
                    }
                }
                .frame(width: 92, height: 22)
                .padding(.horizontal, 10).frame(height: 34)
                .background(Capsule().fill(Color(white: 0.05).opacity(0.92)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0.9 : hovering ? 0.3 : 0), lineWidth: 1.5).padding(-3))
                Text(style.label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .accessibilityLabel("\(style.label) waveform")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ModelsPane: View {
    let dictation: DictationController
    @State private var showingAdd = false
    @State private var custom = ModelCatalog.custom

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Models") {
                Button { showingAdd = true } label: { Label("Add model", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
            }
            recommendationCard
            List {
                ForEach(["English", "Many languages", "Asian languages", "Built into macOS"], id: \.self) { group in
                    let models = ModelCatalog.builtIn.filter { $0.group == group }
                    if !models.isEmpty {
                        SwiftUI.Section(group) { ForEach(models) { row($0) } }
                    }
                }
                if !custom.isEmpty {
                    SwiftUI.Section("Yours") {
                        ForEach(custom) { m in
                            row(m).contextMenu {
                                Button("Remove") {
                                    custom.removeAll { $0.id == m.id }
                                    ModelCatalog.custom = custom
                                    if dictation.modelID == m.id { dictation.setModel(ModelCatalog.english) }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            Text("Models download the first time you pick them. Removing one you added: right-click it.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 10)
        }
        .sheet(isPresented: $showingAdd) {
            AddModelSheet { m in
                custom = ModelCatalog.custom.filter { $0.id != m.id } + [m]
                ModelCatalog.custom = custom
                dictation.setModel(m.id)
            }
        }
    }

    private var recommendationCard: some View {
        let rec = ModelCatalog.recommendation()
        let model = ModelCatalog.model(rec.id)
        return HStack(alignment: .top, spacing: 12) {
            Glyph(symbol: "sparkles", strong: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended for this Mac: \(model.name)").fontWeight(.medium)
                Text(rec.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if dictation.modelID == rec.id {
                Text("In use").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Use it") { dictation.setModel(rec.id) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .padding(.horizontal, 24).padding(.bottom, 6)
    }

    private func row(_ m: ModelInfo) -> some View {
        let inUse = dictation.modelID == m.id
        return HStack(spacing: 14) {
            Glyph(symbol: inUse ? "checkmark" : m.kind == .apple ? "apple.logo" : "cpu", strong: inUse)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.name).fontWeight(.medium)
                    if m.id == ModelCatalog.recommendation().id {
                        Text("Recommended").font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                Text(m.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if inUse, case .loading(let p) = dictation.modelState {
                Text(p > 0 && p < 1 ? "Downloading \(Int(p * 100))%" : "Loading").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(inUse ? "In use" : m.kind == .apple ? "Built in" : m.isDownloaded ? "Downloaded" : "Download")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .hoverHighlight()
        .contentShape(Rectangle())
        .onTapGesture { dictation.setModel(m.id) }
        .help(inUse ? "In use" : "Use this model")
    }
}

private struct AddModelSheet: View {
    let onAdd: (ModelInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var checking = false
    @State private var result: ModelCatalog.Check?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a model").font(.system(size: 16, weight: .semibold))
            Text("Paste a Hugging Face model page, or the address of a server that speaks the OpenAI transcription API (for example one running on another computer at home).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("huggingface.co/org/model  or  http://192.168.1.20:8000", text: $link).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Model name on the server (optional)", text: $modelName).textFieldStyle(.roundedBorder)
                SecureField("API key (optional, kept in Keychain)", text: $apiKey).textFieldStyle(.roundedBorder)
            }
            if let result {
                Group {
                    switch result {
                    case .known(let m): Label("\(m.name) works with Fluent.", systemImage: "checkmark.circle")
                    case .server(let m): Label("Server answered. \(m.detail)", systemImage: "checkmark.circle")
                    case .unsupported(let why): Label(why, systemImage: "exclamationmark.circle")
                    }
                }
                .font(.callout).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle())
                if let result, let m = addable(result) {
                    Button("Use it") { onAdd(m); dismiss() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button(checking ? "Checking…" : "Check") {
                        checking = true
                        Task {
                            result = await ModelCatalog.check(link, model: modelName, apiKey: apiKey)
                            checking = false
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle()).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || checking)
                }
            }
        }
        .padding(20).frame(width: 520)
    }

    private func addable(_ r: ModelCatalog.Check) -> ModelInfo? {
        switch r {
        case .known(let m), .server(let m): return m
        case .unsupported: return nil
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPane: View {
    let dictionary: WordDictionary
    @State private var newWord = ""
    @State private var useCommon = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Dictionary") {
                HStack(spacing: 8) {
                    TextField("Add a name or word", text: $newWord)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .onSubmit(add)
                    Button("Add", action: add).buttonStyle(PrimaryButtonStyle()).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("Fluent writes these exactly as listed. It also learns them when you correct a word right after it types, for example \"cooper netties\" to \"Kubernetes\".")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 8)
            List {
                ForEach(dictionary.entries) { DictionaryRow(entry: $0, onDelete: { dictionary.delete($0) }) }
                SwiftUI.Section {
                    Toggle(isOn: $useCommon) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Well-known names")
                            Text("Companies, apps and products like OpenAI, LinkedIn, PayPal, Duolingo, written the right way. From Wikidata, the open database behind Wikipedia, refreshed about once a week.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                Text(syncLine).font(.caption).foregroundStyle(.tertiary)
                                Button(dictionary.syncing ? "Updating…" : "Update now") { dictionary.refreshWorldNames(force: true) }
                                    .buttonStyle(GhostButtonStyle()).disabled(dictionary.syncing || !useCommon)
                            }
                        }
                    }
                    .toggleStyle(MonoSwitch())
                    .onChange(of: useCommon) { dictionary.useCommonNames = useCommon }
                }
            }
            .listStyle(.inset)
        }
        .onAppear { useCommon = dictionary.useCommonNames }
    }

    private var syncLine: String {
        if let error = dictionary.syncError { return error }
        guard let d = dictionary.worldNamesUpdated else { return "Not updated yet." }
        return "Updated " + d.formatted(.relative(presentation: .named)) + "."
    }

    private func add() {
        dictionary.add(newWord)
        newWord = ""
    }
}

private struct DictionaryRow: View {
    let entry: WordDictionary.Entry
    let onDelete: (WordDictionary.Entry) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.term).fontWeight(.medium)
                if !entry.heard.isEmpty {
                    Text("Also catches: " + entry.heard.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if entry.source == .learned {
                Text(entry.count >= 2 ? "Learned · everywhere" : "Learned · \(entry.apps.first ?? "one app")")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(entry.count >= 2 ? "Seen twice, so it applies in every app." : "Applies in this app until you make the same fix once more.")
            }
            Text(entry.source == .yours ? "Yours" : entry.source == .learned ? "Learned" : "Starter")
                .font(.caption2.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            RowButton(symbol: "trash", help: "Remove") { onDelete(entry) }.opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Snippets

private struct SnippetsPane: View {
    let snippets: Snippets
    let hotkey: HotkeyMonitor
    @State private var trigger = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Snippets") { EmptyView() }
            Text("Say the phrase while dictating and Fluent types the text instead. Give one a shortcut to type it anywhere, any time.")
                .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 10)
            HStack(alignment: .top, spacing: 8) {
                TextField("Say… (e.g. my email)", text: $trigger).textFieldStyle(.roundedBorder).frame(width: 170)
                TextField("…to type (e.g. you@example.com)", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button("Add") { snippets.add(trigger: trigger, text: text); trigger = ""; text = "" }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
            if snippets.items.isEmpty {
                ContentUnavailableView("No snippets yet", systemImage: "text.badge.plus",
                                       description: Text("Good first ones: your email, your phone number, your address, a sign-off."))
            } else {
                List(snippets.items) { s in SnippetRow(snippet: s, snippets: snippets, hotkey: hotkey) }
                    .listStyle(.inset)
            }
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippets.Snippet
    let snippets: Snippets
    @Bindable var hotkey: HotkeyMonitor
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(snippet.trigger)”").fontWeight(.medium)
                Text(snippet.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if hotkey.capturingSnippet == snippet.id {
                Text("Press a shortcut, e.g. ⌃⌥E").font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { hotkey.capturingSnippet = nil }.buttonStyle(GhostButtonStyle())
            } else if let label = snippet.shortcutLabel {
                Text(label).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                RowButton(symbol: "xmark", help: "Remove shortcut") { snippets.clearShortcut(snippet.id) }
            } else {
                Button("Add shortcut") { hotkey.capturingSnippet = snippet.id }.buttonStyle(GhostButtonStyle())
            }
            RowButton(symbol: "trash", help: "Delete") { snippets.delete(snippet) }.opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
