import Foundation

/// Where the text is going, in the four groups Wispr Flow uses: personal messages, work messages,
/// email, and everything else. AI chat apps count as "other" but get no formatting.
enum AppCategory: String, CaseIterable, Identifiable {
    case personal, work, email, other
    var id: String { rawValue }

    var title: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work messages"
        case .email: "Email"
        case .other: "Everything else"
        }
    }
    var examples: String {
        switch self {
        case .personal: "iMessage, WhatsApp, Telegram, Signal"
        case .work: "Slack, Teams, LinkedIn"
        case .email: "Gmail, Outlook, Mail, Superhuman"
        case .other: "Documents, notes, browsers, AI chats"
        }
    }

    private static let personalApps: Set<String> = [
        "com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop",
        "org.whispersystems.signal-desktop", "com.facebook.archon", "com.hnc.Discord",
    ]
    private static let workApps: Set<String> = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams"]
    static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron", "com.readdle.SparkDesktop",
        "com.readdle.smartemail-Mac", "com.mimestream.Mimestream",
    ]
    private static let aiApps: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.chat"]

    // Web apps are recognised by the site's name in the window title or the installed web app's name.
    private static let personalSites = ["WhatsApp", "Messenger", "Telegram", "Instagram", "Signal"]
    private static let workSites = ["Slack", "Microsoft Teams", "Teams", "LinkedIn"]
    private static let emailSites = ["Gmail", "Outlook", "Superhuman", "Yahoo Mail", "Proton Mail"]
    private static let aiSites = ["ChatGPT", "Claude", "Gemini", "Perplexity"]

    /// The category, and whether it's an AI chat (which skips formatting, as Wispr Flow does).
    static func detect(bundleID: String?, appName: String?, windowTitle: String?) -> (AppCategory, ai: Bool) {
        if let id = bundleID {
            if emailApps.contains(id) { return (.email, false) }
            if workApps.contains(id) { return (.work, false) }
            if personalApps.contains(id) { return (.personal, false) }
            if aiApps.contains(id) { return (.other, true) }
        }
        let title = (windowTitle ?? "") + " " + (appName ?? "")
        func has(_ names: [String]) -> Bool { names.contains { title.localizedCaseInsensitiveContains($0) } }
        if has(emailSites) { return (.email, false) }
        if has(workSites) { return (.work, false) }
        if has(personalSites) { return (.personal, false) }
        if has(aiSites) { return (.other, true) }
        return (.other, false)
    }

    var styles: [WritingStyle] {
        self == .personal ? [.formal, .casual, .veryCasual] : [.formal, .casual, .excited]
    }
    var defaultStyle: WritingStyle { self == .personal || self == .work ? .casual : .formal }

    var style: WritingStyle {
        get { UserDefaults.standard.string(forKey: "style.\(rawValue)").flatMap(WritingStyle.init) ?? defaultStyle }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: "style.\(rawValue)") }
    }
}

/// Punctuation and capitals only; never the words (Wispr Flow's Styles do the same).
enum WritingStyle: String, CaseIterable, Identifiable {
    case formal, casual, veryCasual, excited
    var id: String { rawValue }

    var label: String {
        switch self {
        case .formal: "Formal."
        case .casual: "Casual"
        case .veryCasual: "very casual"
        case .excited: "Excited!"
        }
    }
    var help: String {
        switch self {
        case .formal: "Capitals and full punctuation."
        case .casual: "Capitals, lighter punctuation: no full stop at the end."
        case .veryCasual: "No capitals at the start of sentences, lighter punctuation."
        case .excited: "Capitals, and an exclamation mark to finish."
        }
    }

    func apply(_ text: String) -> String {
        switch self {
        case .formal: return text
        case .casual: return Self.dropFinalPeriod(text)
        case .excited: return Self.exclaim(text)
        case .veryCasual: return Self.lowercaseStarts(Self.dropFinalPeriod(text))
        }
    }

    /// "See you then." becomes "See you then". Leaves "?", "!", "..." and abbreviations ("p.m.") alone.
    private static func dropFinalPeriod(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("."), !t.hasSuffix(".."), !t.hasSuffix("\n") else { return text }
        let word = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init) ?? ""
        if word.dropLast().contains(".") { return text }   // "p.m.", "e.g."
        return String(t.dropLast())
    }

    private static func exclaim(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("."), !t.hasSuffix("..") else { return text }
        let word = t.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init) ?? ""
        if word.dropLast().contains(".") { return text }
        return String(t.dropLast()) + "!"
    }

    /// Lowercases the first word of each sentence unless it is "I" (or "I'm"...) or has capitals
    /// inside it (a name like "iPhone" or "FluidAudio" keeps its form).
    private static func lowercaseStarts(_ text: String) -> String {
        var out = "", atStart = true, word = ""
        func flush() {
            if atStart, let first = word.first, first.isUppercase, !word.dropFirst().contains(where: \.isUppercase),
               !(word == "I" || word.hasPrefix("I'") || word.hasPrefix("I’")) {
                out += first.lowercased() + word.dropFirst()
            } else { out += word }
            if !word.isEmpty { atStart = false }
            word = ""
        }
        for c in text {
            if c.isLetter || c == "'" || c == "’" { word.append(c); continue }
            flush()
            out.append(c)
            if ".?!\n".contains(c) { atStart = true }
        }
        flush()
        return out
    }
}
