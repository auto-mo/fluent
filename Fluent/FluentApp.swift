import SwiftUI

@main
struct FluentApp: App {
    @State private var permissions = Permissions()
    @State private var inspector = FocusInspector()
    @State private var dictation: DictationController

    init() {
        // Command-line modes used by scripts/ (run via `open --args`, so macOS attributes
        // permissions to Fluent itself rather than to the terminal that started it).
        DiagnosticModes.runIfRequested()
        let dictation = DictationController()
        _dictation = State(initialValue: dictation)
        if !DiagnosticModes.isDiagnosticRun { dictation.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(dictation: dictation)
        } label: {
            MenuBarLabel(dictation: dictation)
        }
        .menuBarExtraStyle(.window)

        Window("Fluent", id: "setup") {
            MainWindow(permissions: permissions, inspector: inspector, dictation: dictation)
        }
        .windowResizability(.contentSize)
        // Open the setup window by itself until every permission is granted.
        .defaultLaunchBehavior(permissions.allGranted && !CommandLine.arguments.contains(where: { $0 == "--capture-window" || $0 == "--show-window" }) ? .suppressed : .presented)
    }
}

/// The menu bar icon: the picked style, its recording form while you talk, and a system symbol
/// while the model loads or something needs attention.
private struct MenuBarLabel: View {
    let dictation: DictationController
    @AppStorage("menuIcon") private var style = MenuBarIcon.comb.rawValue

    var body: some View {
        switch dictation.modelState {
        case .ready:
            Image(nsImage: (MenuBarIcon(rawValue: style) ?? .comb).image(recording: dictation.isRecording))
        default:
            Image(systemName: dictation.menuSymbol)
        }
    }
}
