import SwiftUI

/// Phase 0 window: permissions, and a live check of what Accessibility can see in the
/// focused app. Monochrome, SF Pro, icons with tooltips (see design/app.html).
struct SetupView: View {
    let permissions: Permissions
    let inspector: FocusInspector
    let dictation: DictationController
    @State private var savedTo: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            permissionsSection
            inspectorSection
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { permissions.startWatching(); inspector.start() }
        .onDisappear { permissions.stopWatching(); inspector.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up Fluent").font(.system(size: 22, weight: .semibold))
            Text("Three permissions, then a quick check of the apps you type in.")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        VStack(spacing: 0) {
            ForEach(Permissions.Kind.allCases) { kind in
                PermissionRow(kind: kind, state: permissions.states[kind] ?? .notAsked) {
                    permissions.request(kind)
                }
                if kind != Permissions.Kind.allCases.last { Divider().padding(.leading, 44) }
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var inspectorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Text box check").font(.system(size: 15, weight: .semibold))
                    Text("Click into text boxes in other apps and browsers. Each one is logged.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                HoverIconButton(symbol: "trash", help: "Clear the log") { inspector.clear() }
                HoverIconButton(symbol: "doc.on.doc", help: "Copy the log as a table") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(inspector.report, forType: .string)
                }
                HoverIconButton(symbol: "square.and.arrow.down", help: "Save the log to a file") {
                    savedTo = DiagnosticModes.saveReport(inspector.report)
                }
            }
            if let current = inspector.current { CurrentCard(snap: current) }
            LogTable(rows: inspector.log)
            if let savedTo {
                Text("Saved to \(savedTo.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

/// Shows the dictation key, lets you pick another by pressing it, and lists what the
/// keyboard actually sends, so a key that macOS never receives is obvious.
struct KeyCard: View {
    @Bindable var hotkey: HotkeyMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Glyph(symbol: "keyboard")
                VStack(alignment: .leading, spacing: 1) {
                    Text("Dictation key").fontWeight(.medium)
                    Text(hotkey.isCapturing ? "Press the key you want to use." : "Hold to talk, or tap once for hands-free.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if hotkey.isCapturing {
                    Button("Cancel") { hotkey.isCapturing = false }.buttonStyle(GhostButtonStyle())
                } else {
                    Text(hotkey.key.label)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                    Button("Change") { hotkey.isCapturing = true }.buttonStyle(PrimaryButtonStyle())
                }
            }
            // While picking a key, show what macOS actually receives, so a key it never sees is obvious.
            if hotkey.isCapturing {
                VStack(alignment: .leading, spacing: 3) {
                    if hotkey.recent.isEmpty {
                        Text("Nothing received yet. A key that never shows up here can't be used.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(hotkey.recent.prefix(4)) { e in
                        HStack(spacing: 10) {
                            Text(e.name).frame(width: 110, alignment: .leading)
                            Text(e.kind).frame(width: 80, alignment: .leading)
                            Text("code \(e.keyCode)").monospacedDigit()
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 38)
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .animation(.easeOut(duration: 0.15), value: hotkey.isCapturing)
    }
}

private struct PermissionRow: View {
    let kind: Permissions.Kind
    let state: Permissions.State
    let action: () -> Void

    var symbol: String {
        switch kind {
        case .microphone: "mic.fill"
        case .accessibility: "accessibility"
        case .inputMonitoring: "keyboard"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Glyph(symbol: symbol)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).fontWeight(.medium)
                Text(kind.why).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .granted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.primary)
                    .help("Allowed")
            } else {
                Button("Allow", action: action).buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

private struct CurrentCard: View {
    let snap: FocusSnapshot

    var body: some View {
        HStack(spacing: 16) {
            Fact(label: "App", value: snap.app)
            Fact(label: "Element", value: snap.role)
            Fact(label: "Text box", value: snap.isTextInput ? "Yes" : "No")
            Fact(label: "Caret found", value: snap.caretBounds != nil ? "Yes" : "No")
            Fact(label: "Screen", value: snap.screen)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

private struct Fact: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium)).lineLimit(1)
        }
    }
}

private struct LogTable: View {
    let rows: [FocusSnapshot]

    var body: some View {
        Table(rows.reversed()) {
            TableColumn("Time") { Text($0.time, format: .dateTime.hour().minute().second()).monospacedDigit() }
                .width(70)
            TableColumn("App", value: \.app)
            TableColumn("Element") { Text($0.role + ($0.subrole.isEmpty ? "" : " / \($0.subrole)")) }
            TableColumn("Text box") { mark($0.isTextInput) }.width(60)
            TableColumn("Read") { mark($0.valueReadable) }.width(44)
            TableColumn("Caret") { mark($0.caretBounds != nil) }.width(44)
            TableColumn("Screen", value: \.screen)
        }
        .frame(minHeight: 200)
    }

    private func mark(_ ok: Bool) -> some View {
        Image(systemName: ok ? "checkmark" : "minus").foregroundStyle(ok ? .primary : .tertiary)
    }
}
