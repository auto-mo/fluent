import AppKit
import ApplicationServices

/// Is the focused thing in an app somewhere text can go? Safe to call off the main thread.
enum FocusProbe {
    enum State: Sendable { case textBox, notText, unknown }

    /// For Chromium and Electron apps, "nothing focused" can also mean their accessibility is off,
    /// so it counts as unknown (type anyway) rather than "hold".
    static func state(pid: pid_t, chromium: Bool) -> State {
        let s = state(pid: pid)
        if chromium, s == .notText, noFocus(pid: pid) { return .unknown }
        return s
    }

    private static func noFocus(pid: pid_t) -> Bool {
        var focused: CFTypeRef?
        return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString, &focused) == .noValue
    }

    /// The focused element's role ("AXTextArea", "AXTextField"...), or nil when the app doesn't say.
    static func role(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(ref as! AXUIElement, kAXRoleAttribute as CFString, &roleRef)
        return roleRef as? String
    }

    /// One-line boxes (search, address and plain fields) never get line breaks or lists.
    static let singleLineRoles: Set<String> = [kAXTextFieldRole, "AXSearchField", kAXComboBoxRole]

    /// `.unknown` when the app doesn't answer; callers treat that like a text box, so apps that hide
    /// their text boxes from Accessibility still get the text.
    static func state(pid: pid_t) -> State {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
        if err == .noValue { return .notText }          // nothing has focus at all
        guard err == .success, let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return .unknown }
        let element = ref as! AXUIElement
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if FocusInspector.textRoles.contains(role) { return .textBox }
        for attr in [kAXValueAttribute, kAXSelectedTextAttribute] {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, attr as CFString, &settable) == .success, settable.boolValue {
                return .textBox
            }
        }
        // Hold only when the focus is plainly not somewhere to type. Anything else (a group, a scroll
        // area, a custom view) may be a text box the app describes badly: WhatsApp reports its search
        // field that way, so the text is typed rather than held.
        // The Finder and the desktop: pasting there makes a text clipping file, so hold instead.
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" { return .notText }
        return notTextRoles.contains(role) ? .notText : .unknown
    }

    /// Focused things that are never text boxes.
    static let notTextRoles: Set<String> = [
        kAXButtonRole, kAXListRole, kAXTableRole, kAXOutlineRole, kAXRowRole, kAXCellRole, kAXImageRole,
        kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXWindowRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXSliderRole, kAXTabGroupRole, kAXToolbarRole, kAXPopUpButtonRole, kAXDisclosureTriangleRole,
        kAXApplicationRole, "AXLink",
    ]
}
