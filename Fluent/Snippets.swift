import AppKit
import Observation

/// Say a short phrase, get stored text ("my email" → your address), or press its own shortcut to
/// type it anywhere. Stored in Application Support/Fluent/snippets.json.
@MainActor
@Observable
final class Snippets {
    struct Snippet: Codable, Identifiable, Equatable {
        var id = UUID()
        var trigger: String
        var text: String
        /// Optional shortcut: key code plus modifier flags (raw CGEventFlags), and how it reads.
        var keyCode: Int64?
        var flags: UInt64?
        var shortcutLabel: String?
    }

    private(set) var items: [Snippet] = []
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snippets.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Snippet].self, from: data) { items = saved }
    }

    func add(trigger: String, text: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines), body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !body.isEmpty else { return }
        items.insert(Snippet(trigger: t, text: body), at: 0)
        save()
    }

    func delete(_ s: Snippet) { items.removeAll { $0.id == s.id }; save() }

    func setShortcut(_ id: UUID, keyCode: Int64, flags: UInt64, label: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].keyCode = keyCode; items[i].flags = flags; items[i].shortcutLabel = label
        save()
    }

    func clearShortcut(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].keyCode = nil; items[i].flags = nil; items[i].shortcutLabel = nil
        save()
    }

    func snippet(forKey keyCode: Int64, flags: UInt64) -> Snippet? {
        items.first { $0.keyCode == keyCode && $0.flags == flags }
    }

    /// Replaces each spoken trigger with its text. Matching ignores case and punctuation and
    /// needs the whole phrase, so "my email" doesn't fire inside "my emails".
    func expand(_ text: String) -> String { expandWith(items, text) }

    func expandWith(_ list: [Snippet], _ text: String) -> String {
        var out = text
        for s in list.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let words = s.trigger.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?i)(?<![\p{L}\p{N}])"# + words.joined(separator: #"[\s,]+"#) + #"(?![\p{L}\p{N}])[.!?]?"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: s.text))
        }
        return out
    }

    private func save() {
        let snapshot = items, url = self.url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}

/// How text should be shaped for the app you're in. Email and documents get real lists; chat
/// stays one plain paragraph.
enum AppStyle: String {
    case document, chat, plain

    static let documentApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.apple.Notes", "com.apple.iWork.Pages",
        "com.microsoft.Word", "com.apple.TextEdit", "md.obsidian", "notion.id", "com.superhuman.electron",
    ]
    static let chatApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap", "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp", "com.hnc.Discord", "ru.keepcoder.Telegram", "com.openai.chat",
    ]
    static let documentSites = ["Gmail", "Google Docs", "Outlook", "Notion", "Google Keep", "Superhuman"]
    static let chatSites = ["Slack", "ChatGPT", "Claude", "WhatsApp", "Messenger", "Discord", "Gemini"]

    static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron", "com.readdle.SparkDesktop",
        "com.readdle.smartemail-Mac", "com.mimestream.Mimestream",
    ]

    /// Email gets its own layout (greeting and sign-off on their own lines).
    static func isEmail(bundleID: String?, appName: String? = nil, windowTitle: String?) -> Bool {
        if let id = bundleID, emailApps.contains(id) { return true }
        // Web apps installed from Chrome are named after the site ("Gmail"), and their window title
        // can't always be read.
        let title = (windowTitle ?? "") + " " + (appName ?? "")
        return ["Gmail", "Outlook", "Superhuman"].contains { title.localizedCaseInsensitiveContains($0) }
    }

    /// Uses the app, and for browsers and web apps the window title (which names the site).
    static func detect(bundleID: String?, appName: String?, windowTitle: String?) -> AppStyle {
        if let id = bundleID {
            if documentApps.contains(id) { return .document }
            if chatApps.contains(id) { return .chat }
        }
        let title = (windowTitle ?? "") + " " + (appName ?? "")
        if documentSites.contains(where: { title.localizedCaseInsensitiveContains($0) }) { return .document }
        if chatSites.contains(where: { title.localizedCaseInsensitiveContains($0) }) { return .chat }
        return .plain
    }

    /// Title of the app's focused window, off the main thread.
    nonisolated static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let w = win, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(w as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    var formattingInstruction: String {
        switch self {
        case .document, .plain:
            // Lists and line breaks are added afterwards by rule (TextShape), never by the model.
            return "Do not add lists or line breaks unless the speaker says \"new line\" or \"bullet point\"."
        case .chat:
            return "The text goes into a chat message. Keep it as plain sentences in one paragraph. Never make lists or line breaks."
        }
    }
}
