import AppKit
import ApplicationServices
import Observation

/// What macOS Accessibility reports about the focused UI element.
/// Phase 0 uses this to learn, per app and per browser, whether a text box can be
/// found, read and located on screen. The same reads become the focus tracker later.
struct FocusSnapshot: Identifiable, Equatable {
    let id = UUID()
    let time: Date
    let app: String
    let bundleID: String
    let role: String
    let subrole: String
    let isTextInput: Bool
    let valueReadable: Bool
    let valueSettable: Bool
    let selectionReadable: Bool
    let caretBounds: CGRect?
    let frame: CGRect?
    let screen: String

    static func == (a: FocusSnapshot, b: FocusSnapshot) -> Bool {
        a.bundleID == b.bundleID && a.role == b.role && a.subrole == b.subrole
            && a.isTextInput == b.isTextInput && a.valueReadable == b.valueReadable
            && a.frame == b.frame
    }

    var markdownRow: String {
        func yn(_ b: Bool) -> String { b ? "yes" : "no" }
        return "| \(app) | \(role)\(subrole.isEmpty ? "" : "/\(subrole)") | \(yn(isTextInput)) | \(yn(valueReadable)) | \(yn(valueSettable)) | \(yn(selectionReadable)) | \(yn(caretBounds != nil)) | \(yn(frame != nil)) | \(screen) |"
    }

    static let markdownHeader = """
    | App | Role | Text box | Read text | Write text | Selection | Caret position | Box position | Screen |
    |---|---|---|---|---|---|---|---|---|
    """
}

@MainActor
@Observable
final class FocusInspector {
    private(set) var current: FocusSnapshot?
    private(set) var log: [FocusSnapshot] = []
    private var timer: Timer?

    nonisolated static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in self.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func clear() { log.removeAll() }

    var report: String {
        ([FocusSnapshot.markdownHeader] + log.map(\.markdownRow)).joined(separator: "\n")
    }

    func sample() {
        guard let snap = Self.snapshot() else { return }
        // Fluent's own window is not interesting; keep what was focused before it.
        if snap.bundleID == Bundle.main.bundleIdentifier { return }
        current = snap
        if log.last != snap { log.append(snap) }
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    static func snapshot() -> FocusSnapshot? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        return snapshot(of: front)
    }

    /// Reads the focused element of one app. Each app keeps its own focus, so this also
    /// works for an app that is not in front (used by the --probe-apps check).
    static func snapshot(of app: NSRunningApplication) -> FocusSnapshot {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        ChromiumAccess.enable(for: app, element: appElement)

        // Ask the app itself; the system-wide query often comes back empty for Chromium apps.
        var focused: CFTypeRef?
        var err = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused)
        if err != .success {
            err = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
        }
        if err == .noValue { ChromiumAccess.escalate(for: app, element: appElement) }
        guard err == .success, let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return FocusSnapshot(time: .now, app: app.localizedName ?? "?", bundleID: app.bundleIdentifier ?? "",
                                 role: "none (\(err.rawValue))", subrole: "", isTextInput: false, valueReadable: false,
                                 valueSettable: false, selectionReadable: false, caretBounds: nil, frame: nil,
                                 screen: screenName(for: nil))
        }
        let element = ref as! AXUIElement

        let role = string(element, kAXRoleAttribute) ?? "?"
        let subrole = string(element, kAXSubroleAttribute) ?? ""
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        var anyValue: CFTypeRef?
        let valueReadable = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &anyValue) == .success
        let range = selectedRange(element)
        let caret = range.flatMap { caretBounds(element, at: $0) }
        let frame = elementFrame(element)
        let isText = textRoles.contains(role) || (role == "AXWebArea" && settable.boolValue)
            || (settable.boolValue && range != nil)

        return FocusSnapshot(time: .now, app: app.localizedName ?? "?", bundleID: app.bundleIdentifier ?? "",
                             role: role, subrole: subrole, isTextInput: isText, valueReadable: valueReadable,
                             valueSettable: settable.boolValue, selectionReadable: range != nil,
                             caretBounds: caret, frame: frame, screen: screenName(for: caret ?? frame))
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func selectedRange(_ e: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let value = v, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func caretBounds(_ e: AXUIElement, at range: CFRange) -> CGRect? {
        var r = CFRange(location: range.location, length: max(range.length, 0))
        guard let param = AXValueCreate(.cfRange, &r) else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, param, &v) == .success,
              let value = v, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero else { return nil }
        return rect
    }

    private static func elementFrame(_ e: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success,
              let pv = p, let sv = s else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Accessibility rects are in global coordinates with the origin at the top-left of the
    /// main display; NSScreen frames use a bottom-left origin, so flip before matching.
    private static func screenName(for rect: CGRect?) -> String {
        guard let rect, let main = NSScreen.screens.first else {
            let mouse = NSEvent.mouseLocation
            return (NSScreen.screens.first { $0.frame.contains(mouse) }?.localizedName ?? "?") + " (pointer)"
        }
        let flipped = CGPoint(x: rect.midX, y: main.frame.maxY - rect.midY)
        return NSScreen.screens.first { $0.frame.contains(flipped) }?.localizedName ?? "?"
    }
}

/// Chromium-based apps build their accessibility tree only when asked. Electron apps
/// (Claude, Slack, VS Code) honour AXManualAccessibility; Chromium browsers honour
/// AXEnhancedUserInterface. Each app is switched on once per launch.
@MainActor
enum ChromiumAccess {
    private static var done: Set<pid_t> = []

    static let browserPrefixes = [
        "com.google.Chrome", "org.chromium.Chromium", "company.thebrowser", "com.brave.Browser",
        "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Apps whose accessibility mode Fluent switched on, so it can switch it off again.
    private static var switchedOn: [pid_t: String] = [:]
    private static var releaseTask: Task<Void, Never>?

    /// Chromium apps do extra work while their accessibility mode is on, so Fluent turns it off
    /// again after `quietSeconds` without dictation, and back on when you next dictate.
    static let quietSeconds = 90.0

    static func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task {
            try? await Task.sleep(for: .seconds(quietSeconds))
            guard !Task.isCancelled else { return }
            for (pid, attr) in switchedOn {
                AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), attr as CFString, kCFBooleanFalse)
            }
            switchedOn.removeAll()
            done.removeAll()
            escalated.removeAll()
        }
    }

    static func enable(for app: NSRunningApplication, element: AXUIElement) {
        let pid = app.processIdentifier
        releaseTask?.cancel()
        guard !done.contains(pid) else { return }
        done.insert(pid)
        if isElectron(app) {
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            switchedOn[pid] = "AXManualAccessibility"
        } else if let id = app.bundleIdentifier, browserPrefixes.contains(where: id.hasPrefix) {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            switchedOn[pid] = "AXEnhancedUserInterface"
        }
    }

    private static var escalated: Set<pid_t> = []

    /// Some Electron builds (the Claude app among them) ignore AXManualAccessibility and only
    /// expose their text boxes with AXEnhancedUserInterface. Used only when the first switch
    /// produced no focused element, because it can make window moves by tools like Rectangle animate.
    static func escalate(for app: NSRunningApplication, element: AXUIElement) {
        let pid = app.processIdentifier
        guard isElectron(app), !escalated.contains(pid) else { return }
        escalated.insert(pid)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        switchedOn[pid] = "AXEnhancedUserInterface"   // the one to switch off later
    }

    /// Chromium browsers and Electron apps.
    static func isChromium(_ app: NSRunningApplication) -> Bool {
        if isElectron(app) { return true }
        guard let id = app.bundleIdentifier else { return false }
        return browserPrefixes.contains(where: id.hasPrefix)
    }

    static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }
}
