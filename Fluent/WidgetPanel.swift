import AppKit
import SwiftUI

/// The floating pill. A non-activating panel, so clicking it never takes focus from the app you
/// are typing in; shown on every Space and over full-screen apps. It rests as a small pill at the
/// bottom of the screen you're using and expands on hover.
@MainActor
final class WidgetPanel {
    let model = WidgetModel()
    private let panel: NSPanel
    private let host: HoverHostingView<WidgetView>
    private var settleTask: Task<Void, Never>?
    private var followTimer: Timer?
    private var idleTimer: Timer?
    private var anchorScreen: NSScreen?
    private var lastFocusRect: NSRect?
    private var lastFocusScreen: NSScreen?
    private var lookupInFlight = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 20),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // Set after isFloatingPanel, which resets the level to plain "floating".
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        host = HoverHostingView(rootView: WidgetView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        host.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        // Switching apps (or Spaces) must never take the pill away while it's in use.
        let reshow: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.keepVisible() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main, using: reshow)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: reshow)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reshow)
        model.onLayoutChange = { [weak self] in
            // Let SwiftUI lay out the new state first, then fit the panel around it.
            DispatchQueue.main.async { self?.reanchor() }
        }
    }

    // MARK: States

    func showIdle() {
        settleTask?.cancel()
        followTimer?.invalidate()
        model.mode = .idle
        anchorScreen = Self.screenUnderPointer()
        reanchor()
        panel.orderFrontRegardless()
        // At rest, follow the pointer to whichever screen you're on (cheap: no Accessibility calls).
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                guard self.model.mode == .idle, !self.model.hovered else { return }
                let screen = Self.screenUnderPointer()
                if screen != self.anchorScreen { self.anchorScreen = screen; self.reanchor() }
            }
        }
    }

    func show(_ mode: WidgetModel.Mode, follow: Bool = false) {
        settleTask?.cancel()
        idleTimer?.invalidate()
        model.mode = mode
        // Show at once on the last known screen; the focus lookup below moves it if needed.
        if anchorScreen == nil || !panel.isVisible { anchorScreen = lastFocusScreen ?? Self.screenUnderPointer() }
        reanchor()
        panel.orderFrontRegardless()
        DispatchQueue.main.async { self.reanchor() }   // and again once SwiftUI has drawn it
        refreshFocus()
        followTimer?.invalidate()
        if follow {
            // While you talk, move to the screen of whichever text box has focus.
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in self.refreshFocus() }
            }
        }
    }

    /// Show a state briefly, then rest.
    func flash(_ mode: WidgetModel.Mode, for seconds: Double) {
        show(mode)
        settleTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            rest()
        }
    }

    /// When you're not dictating: gone, unless "Show the pill when idle" is on.
    func rest() {
        if UserDefaults.standard.bool(forKey: "showPillWhenIdle") { showIdle(); return }
        settleTask?.cancel()
        followTimer?.invalidate()
        idleTimer?.invalidate()
        model.hovered = false
        model.mode = .idle
        panel.orderOut(nil)
    }

    /// True while the pill should be on screen (dictating, showing a result, holding text, or idle
    /// with "show when not dictating" on).
    private var shouldBeVisible: Bool {
        model.mode != .idle || UserDefaults.standard.bool(forKey: "showPillWhenIdle")
    }

    private func keepVisible() {
        guard shouldBeVisible else { return }
        panel.level = .statusBar
        reanchor()
        panel.orderFrontRegardless()
    }

    var frame: NSRect { panel.frame }

    /// The pill as drawn, for the --widget-test check.
    func snapshotPNG() -> Data? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Layout

    private func hoverChanged(_ inside: Bool) {
        if inside { model.hovered = true; return }
        // Resizing can briefly put the pointer outside; only collapse if it stays out.
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            let mouse = NSEvent.mouseLocation
            if !panel.frame.insetBy(dx: -2, dy: -2).contains(mouse) { model.hovered = false }
        }
    }

    /// Bottom centre of the anchor screen, or under the text box with that setting on.
    func reanchor() {
        host.layoutSubtreeIfNeeded()   // measure the state being shown, not the previous one
        let size = host.fittingSize
        let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        var origin = NSPoint(x: vis.midX - size.width / 2, y: vis.minY + 14)

        if UserDefaults.standard.bool(forKey: "widgetUnderTextBox"), model.mode != .idle,
           let target = lastFocusRect {
            origin = NSPoint(x: target.minX, y: target.minY - 8 - size.height)
            if origin.y < vis.minY { origin.y = target.maxY + 8 }
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
        }
        let target = NSRect(origin: origin, size: size)
        // Grow and shrink smoothly when the pill is already showing (hover, hands-free); jump otherwise.
        if panel.isVisible, panel.frame.size != target.size, !WidgetView.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private static func screenUnderPointer() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    /// Finds the focused text box off the main thread, so a slow app never stalls the
    /// waveform animation, then moves the pill to that box's screen.
    private func refreshFocus() {
        guard !lookupInFlight, let app = NSWorkspace.shared.frontmostApplication else { return }
        ChromiumAccess.enable(for: app, element: AXUIElementCreateApplication(app.processIdentifier))
        let pid = app.processIdentifier
        lookupInFlight = true
        Task.detached {
            let ax = FocusLocator.textBoxRect(pid: pid)
            await MainActor.run {
                self.lookupInFlight = false
                guard let ax, let primary = NSScreen.screens.first else { return }
                // Accessibility uses a top-left origin on the primary display; AppKit uses bottom-left.
                let rect = NSRect(x: ax.minX, y: primary.frame.maxY - ax.maxY, width: ax.width, height: ax.height)
                let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
                self.lastFocusRect = rect
                self.lastFocusScreen = screen
                guard self.model.mode != .idle, let screen else { return }
                if screen != self.anchorScreen || UserDefaults.standard.bool(forKey: "widgetUnderTextBox") {
                    self.anchorScreen = screen
                    self.reanchor()
                }
            }
        }
    }
}

/// Accessibility reads for the widget, safe to run on any thread.
enum FocusLocator {
    /// The caret, or the focused text box (its bottom edge when it is tall), in Accessibility
    /// coordinates; nil when nothing typeable has focus or the app doesn't answer in time.
    static func textBoxRect(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard FocusInspector.textRoles.contains(role) || settable.boolValue else { return nil }

        if let caret = caretRect(element) { return caret }
        var p: CFTypeRef?, sz: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sz) == .success,
              let pv = p, let sv = sz else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sv as! AXValue, .cgSize, &size)
        let frame = CGRect(origin: origin, size: size)
        return frame.height <= 160 ? frame : CGRect(x: frame.minX, y: frame.maxY - 1, width: frame.width, height: 1)
    }

    private static func caretRect(_ e: AXUIElement) -> CGRect? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let value = v, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), let param = AXValueCreate(.cfRange, &range) else { return nil }
        var b: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString, param, &b) == .success,
              let bv = b, CFGetTypeID(bv) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect), rect.height > 0, rect.origin != .zero else { return nil }
        return rect
    }
}

/// Hosting view that reports hover even though the panel is never the key window
/// (SwiftUI's own hover tracking only works in the active app).
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: (Bool) -> Void = { _ in }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHoverChange(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHoverChange(false) }
    // Clicks work without first activating Fluent.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
