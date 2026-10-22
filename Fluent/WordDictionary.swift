import Foundation
import Observation

/// Names and words Fluent should always write a certain way. Three sources:
/// yours (added by you), learned (from your edits), starter (seeded, editable). A built-in list
/// of common company and product names can be switched off. Stored in
/// Application Support/Fluent/dictionary.json.
@MainActor
@Observable
final class WordDictionary {
    enum Source: String, Codable { case yours, learned, starter }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var term: String
        /// Other ways the speech model writes it ("cooper netties" for "Kubernetes").
        var heard: [String] = []
        var source: Source
        /// Learned entries apply in the app they were learned in until seen twice.
        var apps: [String] = []
        var count = 1
        var added = Date()
    }

    private(set) var entries: [Entry] = []
    var useCommonNames: Bool {
        get { UserDefaults.standard.object(forKey: "useCommonNames") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useCommonNames") }
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("dictionary.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = Self.starter.map { Entry(term: $0.0, heard: $0.1, source: .starter) }
            save()
        }
    }

    // MARK: Editing

    func add(_ term: String, heard: [String] = []) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let i = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) {
            entries[i].heard = Array(Set(entries[i].heard + heard))
        } else {
            entries.insert(Entry(term: t, heard: heard, source: .yours), at: 0)
        }
        save()
    }

    /// Another way the speech model writes this word ("cooper netties" for "Kubernetes").
    func addHeard(_ heard: String, to id: UUID) {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !h.contains(where: \.isNewline), let i = entries.firstIndex(where: { $0.id == id }),
              !entries[i].heard.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }),
              h.caseInsensitiveCompare(entries[i].term) != .orderedSame else { return }
        entries[i].heard.append(h)
        save()
    }

    func removeHeard(_ heard: String, from id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].heard.removeAll { $0 == heard }
        save()
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Records a correction you made. Returns the entry when it is new or newly applies everywhere.
    @discardableResult
    func learn(heard: String?, correct: String, app: String) -> Entry? {
        let h = heard?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !correct.contains(where: \.isNewline), !correct.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if let i = entries.firstIndex(where: { $0.term == correct }) {
            if !h.isEmpty, !entries[i].heard.contains(where: { $0.caseInsensitiveCompare(h) == .orderedSame }) { entries[i].heard.append(h) }
            entries[i].count += 1
            if !entries[i].apps.contains(app) { entries[i].apps.append(app) }
            save()
            return entries[i].count == 2 ? entries[i] : nil
        }
        let e = Entry(term: correct, heard: h.isEmpty ? [] : [h], source: .learned, apps: [app])
        entries.insert(e, at: 0)
        save()
        return e
    }

    private func save() {
        let snapshot = entries, url = self.url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: Applying

    /// Terms to hint to the cleanup model.
    var hintTerms: [String] { Array(entries.map(\.term).prefix(60)) }

    /// Rewrites known names in `text`. Returns the text and the terms that were applied.
    func apply(to text: String, app: String?) -> (String, [String]) {
        var candidates: [Candidate] = []
        for e in entries {
            if e.source == .learned, e.count < 2, let app, !e.apps.contains(app) { continue }
            candidates.append(Candidate(term: e.term, form: e.term, fuzzy: true))
            for h in e.heard { candidates.append(Candidate(term: e.term, form: h)) }
        }
        if useCommonNames {
            for (term, heard) in Self.commonNames {
                candidates.append(Candidate(term: term, form: term))
                for h in heard { candidates.append(Candidate(term: term, form: h)) }
            }
            for name in worldNames { candidates.append(Candidate(term: name, form: name, guarded: true)) }
        }
        return Self.replace(in: text, candidates: candidates)
    }

    /// Names synced from Wikidata (WorldNames); reloaded when a refresh lands.
    private(set) var worldNames: [String] = WorldNames.load()?.names ?? []
    private(set) var worldNamesUpdated: Date? = WorldNames.lastUpdated
    var syncing = false
    var syncError: String?

    /// Refreshes the Wikidata list when it's more than a week old (or `force`), in the background.
    func refreshWorldNames(force: Bool = false) {
        guard !syncing, force || WorldNames.needsRefresh() else { return }
        syncing = true
        syncError = nil
        Task {
            do {
                let store = try await WorldNames.refresh()
                worldNames = store.names
                worldNamesUpdated = store.updated
            } catch {
                syncError = "Couldn't reach Wikidata. Fluent keeps the list it has and tries again later."
            }
            syncing = false
        }
    }

    struct Candidate: Sendable {
        let term: String
        let form: String
        var fuzzy = false
        /// From the synced list: never replaces a phrase that starts with an everyday word ("my space").
        var guarded = false
    }

    nonisolated static func squash(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Scans windows of 1 to 3 words, longest first, and swaps in the term when the window
    /// matches one of its forms ignoring case, spaces and punctuation. Close misspellings of
    /// your own long terms match too ("Fluid Odio" for "FluidAudio"); built-in names must match exactly.
    nonisolated static func replace(in text: String, candidates: [Candidate]) -> (String, [String]) {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard !words.isEmpty, !candidates.isEmpty else { return (text, []) }
        let forms = candidates.map { (term: $0.term, key: squash($0.form), fuzzy: $0.fuzzy, guarded: $0.guarded, n: $0.form.split(separator: " ").count) }
            .filter { !$0.key.isEmpty }
        // Exact matches by key (first one listed wins: yours, then built-in, then synced).
        var exact: [String: (term: String, guarded: Bool)] = [:]
        for f in forms where exact[f.key] == nil { exact[f.key] = (f.term, f.guarded) }
        let fuzzyForms = forms.filter { $0.fuzzy && $0.key.count >= 7 }
        var out: [String] = [], applied: [String] = []
        var i = 0
        while i < words.count {
            var matched = false
            for n in stride(from: min(3, words.count - i), through: 1, by: -1) {
                let window = words[i..<(i + n)]
                var core = window.joined(separator: " ")
                // A possessive ("FluidAudio's") matches its name and keeps the 's.
                var possessive = ""
                if let r = core.range(of: #"['’]s(?=\p{P}*$)"#, options: .regularExpression) {
                    possessive = String(core[r])
                    core.removeSubrange(r)
                }
                let key = squash(core)
                guard key.count >= 2 else { continue }
                let firstWord = window.first!.lowercased().trimmingCharacters(in: .punctuationCharacters)
                var hit: (term: String, guarded: Bool)? = exact[key]
                if let h = hit, h.guarded, n > 1, WorldNames.commonWords.contains(firstWord) { hit = nil }
                if hit == nil {
                    hit = fuzzyForms.first { f in
                        abs(f.n - n) <= 1 && f.key.first == key.first && editDistance(f.key, key) <= (f.key.count >= 10 ? 2 : 1)
                    }.map { ($0.term, false) }
                }
                guard let hit, core.trimmingCharacters(in: .punctuationCharacters) != hit.term else { continue }
                // Keep punctuation that was around the words ("FluidAudio," "(n8n)").
                let lead = String(window.first!.prefix { $0.isPunctuation })
                let trail = String(window.last!.reversed().prefix { $0.isPunctuation }.reversed())
                out.append(lead + hit.term + possessive + trail)
                applied.append(hit.term)
                i += n
                matched = true
                break
            }
            if !matched { out.append(words[i]); i += 1 }
        }
        return (out.joined(separator: " "), applied)
    }

    nonisolated static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]; row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[b.count]
    }

    // MARK: Lists

    /// Seeded into a new dictionary; add your own names in the app.
    static let starter: [(String, [String])] = [
        ("n8n", ["n 8 n", "n eight n", "nate n"]), ("FluidAudio", ["fluid audio"]),
        ("Kubernetes", ["cooper netties"]),
    ]

    /// Company and product names that speech models often split or misspell. Only names that
    /// can't be mistaken for ordinary words, so "zoom in" or "outlook" are never touched.
    static let commonNames: [(String, [String])] = [
        ("OpenAI", ["open ai"]), ("ChatGPT", ["chat gpt", "chat g p t"]), ("Anthropic", []), ("Claude Code", []),
        ("GitHub", ["git hub"]), ("GitLab", ["git lab"]), ("LinkedIn", ["linked in"]), ("YouTube", ["you tube"]),
        ("WhatsApp", ["whats app", "what's app"]), ("iMessage", ["i message"]), ("FaceTime", ["face time"]),
        ("iPhone", ["i phone"]), ("iPad", ["i pad"]), ("MacBook", ["mac book"]), ("macOS", ["mac os", "mac o s"]),
        ("iOS", ["i o s"]), ("AirPods", ["air pods"]), ("PowerPoint", ["power point"]), ("OneDrive", ["one drive"]),
        ("SharePoint", ["share point"]), ("HubSpot", ["hub spot"]), ("PayPal", ["pay pal"]),
        ("Airbnb", ["air bnb", "air b n b"]), ("TikTok", ["tik tok", "tick tock"]),
        ("JavaScript", ["java script"]), ("TypeScript", ["type script"]), ("SwiftUI", ["swift ui", "swift u i"]),
        ("Xcode", ["x code"]), ("VS Code", ["vs code", "v s code"]), ("Hugging Face", []), ("NVIDIA", []),
        ("PyTorch", ["pie torch", "py torch"]), ("TensorFlow", ["tensor flow"]), ("PostgreSQL", ["postgres sql", "post gres sql"]),
        ("MongoDB", ["mongo db", "mongo d b"]), ("Supabase", ["supa base", "super base"]), ("Cloudflare", ["cloud flare"]),
        ("Home Assistant", []), ("ElevenLabs", ["eleven labs"]), ("Midjourney", ["mid journey"]),
        ("1Password", ["one password"]), ("Dropbox", ["drop box"]), ("Grammarly", []), ("McKinsey", ["mckinsey", "mc kinsey"]),
        ("JPMorgan", ["jp morgan", "j p morgan"]), ("BlackRock", ["black rock"]), ("PwC", ["p w c"]), ("Deloitte", []),
        ("Google Docs", []), ("Google Sheets", []), ("Google Meet", []), ("Microsoft Teams", []), ("Raycast", ["ray cast"]),
        ("Salesforce", ["sales force"]), ("Shopify", []), ("Calendly", []),
    ]
}
