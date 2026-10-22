import CoreGraphics
import Foundation
import Observation

/// The dictation key. A modifier is told apart by side through its key code (left Option 58,
/// right Option 61); fn is matched by its flag alone, because some keyboards (Logitech among
/// them) set the fn flag without Apple's fn key code. Any other key is matched by key code.
struct DictationKey: Codable, Equatable, Sendable {
    enum Kind: String, Codable { case fnFlag, modifier, key }
    let kind: Kind
    let keyCode: Int64
    let flagRaw: UInt64
    let label: String

    var flag: CGEventFlags { CGEventFlags(rawValue: flagRaw) }

    static let fn = DictationKey(kind: .fnFlag, keyCode: 63, flagRaw: CGEventFlags.maskSecondaryFn.rawValue, label: "fn")
    static let rightOption = DictationKey(kind: .modifier, keyCode: 61, flagRaw: CGEventFlags.maskAlternate.rawValue, label: "right ⌥")

    private static let defaultsKey = "dictationKey"
    static var saved: DictationKey {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let key = try? JSONDecoder().decode(DictationKey.self, from: data) else { return .rightOption }
        return key
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey) }

    /// Names for the keys people are likely to pick.
    static func name(keyCode: Int64, flags: CGEventFlags) -> String {
        let names: [Int64: String] = [
            63: "fn", 54: "right ⌘", 55: "left ⌘", 58: "left ⌥", 61: "right ⌥", 59: "left ⌃", 62: "right ⌃",
            56: "left ⇧", 60: "right ⇧", 57: "Caps Lock", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 118: "F4",
            120: "F2", 122: "F1", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 176: "Dictation",
            179: "Globe",
        ]
        if let n = names[keyCode] { return n }
        if flags.contains(.maskSecondaryFn) { return "fn (key \(keyCode))" }
        return "key \(keyCode)"
    }
}

/// One raw keyboard event, shown in the key tester so the owner can see what a keyboard sends.
struct KeyEventInfo: Identifiable, Equatable {
    let id = UUID()
    let kind: String
    let keyCode: Int64
    let flags: CGEventFlags
    var name: String { DictationKey.name(keyCode: keyCode, flags: flags) }
    var flagText: String {
        var parts: [String] = []
        if flags.contains(.maskSecondaryFn) { parts.append("fn") }
        if flags.contains(.maskCommand) { parts.append("⌘") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        return parts.joined(separator: " ")
    }
}

/// Watches the dictation key in every app through an event tap (needs Input Monitoring and
/// Accessibility). Only a bound ordinary key is swallowed, so it doesn't also type or trigger
/// its usual action; every other keystroke passes through untouched.
@MainActor
@Observable
final class HotkeyMonitor {
    @ObservationIgnored var onPress: () -> Void = {}
    @ObservationIgnored var onRelease: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    /// While a hands-free recording runs or text is being held, Esc cancels (and is not passed on).
    @ObservationIgnored var cancelActive = false
    /// While held text is ready to drop into a text box, Return drops it (and is not passed on).
    @ObservationIgnored var returnActive = false
    @ObservationIgnored var onReturn: () -> Void = {}
    /// A key pressed with ⌘, ⌃ or ⌥: returns true when it was a snippet shortcut (then swallowed).
    @ObservationIgnored var onCombo: (Int64, UInt64) -> Bool = { _, _ in false }
    /// While set, the next key combination becomes this snippet's shortcut.
    var capturingSnippet: UUID?
    @ObservationIgnored var onCapturedCombo: (UUID, Int64, UInt64, String) -> Void = { _, _, _, _ in }
    private(set) var key: DictationKey = .saved
    private(set) var recent: [KeyEventInfo] = []
    /// While true, the next key pressed becomes the dictation key.
    var isCapturing = false

    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var isDown = false
    @ObservationIgnored private var fnWasDown = false

    func setKey(_ newKey: DictationKey) {
        key = newKey
        newKey.save()
        isDown = false
    }

    /// Returns false when the permissions are missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) } | (1 << 14) // 14: system-defined (special keys)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: hotkeyCallback, userInfo: refcon) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, autorepeat: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let kindName = switch type.rawValue {
        case CGEventType.flagsChanged.rawValue: "modifier"
        case CGEventType.keyDown.rawValue: "key down"
        case CGEventType.keyUp.rawValue: "key up"
        default: "special"
        }
        if !autorepeat {
            recent.insert(KeyEventInfo(kind: kindName, keyCode: keyCode, flags: flags), at: 0)
            if recent.count > 12 { recent.removeLast(recent.count - 12) }
        }

        let comboMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let mods = flags.intersection(comboMask)
        if type == .keyDown, !autorepeat, !mods.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            if let id = capturingSnippet {
                capturingSnippet = nil
                onCapturedCombo(id, keyCode, mods.rawValue, Self.comboLabel(keyCode: keyCode, flags: mods))
                return true
            }
            if onCombo(keyCode, mods.rawValue) { return true }
        }
        if returnActive, keyCode == 36 || keyCode == 76, type == .keyDown || type == .keyUp {
            if type == .keyDown, !autorepeat { onReturn() }
            return true
        }
        if cancelActive, keyCode == 53, type == .keyDown || type == .keyUp {
            if type == .keyDown, !autorepeat { onCancel() }
            return true
        }

        if isCapturing, !autorepeat, type == .flagsChanged || type == .keyDown {
            isCapturing = false
            let fnDown = flags.contains(.maskSecondaryFn)
            if type == .flagsChanged {
                if fnDown || keyCode == 63 {
                    setKey(.fn)
                } else {
                    let flag = [CGEventFlags.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskAlphaShift]
                        .first { flags.contains($0) } ?? []
                    setKey(DictationKey(kind: .modifier, keyCode: keyCode, flagRaw: flag.rawValue,
                                        label: DictationKey.name(keyCode: keyCode, flags: flags)))
                }
            } else {
                setKey(DictationKey(kind: .key, keyCode: keyCode, flagRaw: 0,
                                    label: DictationKey.name(keyCode: keyCode, flags: flags)))
            }
            return type == .keyDown
        }

        switch key.kind {
        case .fnFlag:
            guard type == .flagsChanged else { return false }
            let fnDown = flags.contains(.maskSecondaryFn)
            defer { fnWasDown = fnDown }
            if fnDown, !fnWasDown { press() } else if !fnDown, fnWasDown { release() }
            return false
        case .modifier:
            guard type == .flagsChanged, keyCode == key.keyCode else { return false }
            if flags.contains(key.flag) { press() } else { release() }
            return false
        case .key:
            guard keyCode == key.keyCode, type == .keyDown || type == .keyUp else { return false }
            if type == .keyDown, !autorepeat { press() } else if type == .keyUp { release() }
            return true
        }
    }

    /// "⌃⌥E" style label for a key combination.
    static func comboLabel(keyCode: Int64, flags: CGEventFlags) -> String {
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        let letters: [Int64: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
            40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
            13: "W", 7: "X", 16: "Y", 6: "Z", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]
        return s + (letters[keyCode] ?? "key \(keyCode)")
    }

    private func press() { if !isDown { isDown = true; onPress() } }
    private func release() { if isDown { isDown = false; onRelease() } }
}

private func hotkeyCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    // The tap runs on the main run loop, so this is already the main thread.
    let swallow = MainActor.assumeIsolated {
        monitor.handle(type: type, keyCode: keyCode, flags: flags, autorepeat: autorepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
