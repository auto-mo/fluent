import ServiceManagement

/// Open at login, through macOS's own login-item service (shown in System Settings, General,
/// Login Items, where it can also be switched off).
@MainActor
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Fluent: login item change failed: \(error.localizedDescription)")
        }
    }
}
