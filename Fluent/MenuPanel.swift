import SwiftUI

/// What opens from the menu bar icon: a small card in the app's own style (Controls.swift) rather
/// than a system menu. Status, the three quick switches, recent dictations, then the way out.
struct MenuPanel: View {
    let dictation: DictationController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("cleanup") private var cleanup = true
    @State private var copied: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusChip(dictation: dictation)
            Text("Hold \(dictation.hotkey.key.label) to talk, or tap it for hands-free.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(spacing: 10) {
                row("Mode") {
                    MonoSegmented(selection: Binding(get: { dictation.mode }, set: { dictation.setMode($0) }),
                                  options: DictationController.Mode.allCases.map { ($0, $0.label) })
                }
                row("Language") {
                    MonoSegmented(selection: Binding(get: { dictation.language }, set: { dictation.setLanguage($0) }),
                                  options: [(.english, "English"), (.multilingual, "Auto")])
                }
                row("Clean up") {
                    Toggle("", isOn: $cleanup).toggleStyle(MonoSwitch()).labelsHidden()
                        .disabled(!Cleaner.isAvailable)
                        .onChange(of: cleanup) { dictation.refreshWidgetSettings() }
                        .help(Cleaner.isAvailable ? "Removes ums, fixes numbers" : "Needs Apple Intelligence")
                }
            }
            .padding(.horizontal, 4)

            let recent = Array(dictation.history.entries.filter { !$0.text.isEmpty }.prefix(5))
            if !recent.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.bottom, 2)
                    ForEach(recent) { e in recentRow(e) }
                }
            }

            Divider()
            HStack(spacing: 4) {
                Button("Undo last") { dictation.undoLast() }
                    .buttonStyle(GhostButtonStyle()).disabled(dictation.lastInsert == nil)
                Spacer()
                Button("Settings") {
                    NSApp.activate()
                    openWindow(id: "setup")
                }
                .buttonStyle(GhostButtonStyle())
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(GhostButtonStyle()).keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 300)
        .tint(.primary)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            control()
        }
    }

    private func recentRow(_ e: HistoryStore.Entry) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(e.text, forType: .string)
            copied = e.id
            Task { try? await Task.sleep(for: .seconds(1.2)); if copied == e.id { copied = nil } }
        } label: {
            HStack(spacing: 8) {
                Text(e.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if copied == e.id {
                    Label("Copied", systemImage: "checkmark").labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                        .transition(.opacity)
                } else {
                    Text(e.date.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .hoverHighlight(cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(Press())
        .help("Click to copy")
        .animation(.easeOut(duration: 0.15), value: copied)
    }
}
