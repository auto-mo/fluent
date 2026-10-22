import AVFoundation
import ApplicationServices
import AppKit
import Observation

/// The three macOS privacy permissions Fluent needs, read live.
@MainActor
@Observable
final class Permissions {
    enum State: String { case granted, denied, notAsked }

    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, inputMonitoring
        var id: String { rawValue }

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .accessibility: "Accessibility"
            case .inputMonitoring: "Input Monitoring"
            }
        }

        var why: String {
            switch self {
            case .microphone: "To hear you while the dictation key is down."
            case .accessibility: "To find the text box you're in and type into it."
            case .inputMonitoring: "To notice the dictation key in any app."
            }
        }

        /// Deep link to the matching System Settings pane.
        var settingsURL: URL {
            let anchor = switch self {
            case .microphone: "Privacy_Microphone"
            case .accessibility: "Privacy_Accessibility"
            case .inputMonitoring: "Privacy_ListenEvent"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    private(set) var states: [Kind: State] = [:]

    var allGranted: Bool { Kind.allCases.allSatisfy { states[$0] == .granted } }
    private var timer: Timer?

    init() { refresh() }

    func refresh() {
        states[.microphone] = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
        states[.accessibility] = AXIsProcessTrusted() ? .granted : .denied
        states[.inputMonitoring] = CGPreflightListenEventAccess() ? .granted : .denied
    }

    func request(_ kind: Kind) {
        switch kind {
        case .microphone:
            if states[.microphone] == .notAsked {
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in self.refresh() }
                }
            } else {
                NSWorkspace.shared.open(kind.settingsURL)
            }
        case .accessibility:
            // Adds Fluent to the list in System Settings so the owner only has to flip the switch.
            // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt, which Swift 6
            // rejects as a non-Sendable global.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(kind.settingsURL) }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { NSWorkspace.shared.open(kind.settingsURL) }
        }
        refresh()
    }

    /// Re-read while the setup window is open; granting happens in System Settings, which sends no callback.
    func startWatching() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }
}
