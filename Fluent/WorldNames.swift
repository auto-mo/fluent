import AppKit

/// Well-known company, product, software and site names from Wikidata (CC0), so names a speech model
/// splits or lowercases come out right ("pay pal" to "PayPal", "duolingo" to "Duolingo").
/// Ships with a copy in the app; refreshed from Wikidata about once a week, in the background.
/// Only the query goes out; nothing about you or what you dictate is sent.
enum WorldNames {
    struct Store: Codable {
        var updated: Date
        var names: [String]
    }

    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("world-names.json")
    }()

    /// The synced list if there is one, else the copy bundled with the app.
    static func load() -> Store? {
        for file in [url, Bundle.main.url(forResource: "world-names", withExtension: "json")].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: file), let store = try? decoder.decode(Store.self, from: data) { return store }
        }
        return nil
    }

    static var lastUpdated: Date? { load()?.updated }

    static func needsRefresh(now: Date = .now) -> Bool {
        guard let updated = lastUpdated else { return true }
        return now.timeIntervalSince(updated) > 7 * 86_400
    }

    /// Items with at least this many Wikipedia language editions: famous enough to be worth it.
    private static let minSitelinks = 25
    /// Companies, businesses, software, websites, brands, video games, products, apps.
    private static let classes = ["Q891723", "Q4830453", "Q7397", "Q35127", "Q431289", "Q7889", "Q2424752", "Q166142", "Q1668024"]

    /// Fetches the current list, filters it and saves it. One small query per kind of thing, since
    /// Wikidata stops any query at 60 s and one big query sits right at that limit.
    static func refresh() async throws -> Store {
        var labels = Set<String>()
        var answered = 0
        for cls in classes {
            if let batch = try? await fetch(cls) { labels.formUnion(batch); answered += 1 }
        }
        guard answered * 2 >= classes.count else { throw URLError(.badServerResponse) }
        let names = await MainActor.run { filter(Array(labels)) }
        guard names.count > 100 else { throw URLError(.cannotParseResponse) }   // a broken answer never replaces a good list
        let store = Store(updated: .now, names: names)
        try encoder.encode(store).write(to: url, options: .atomic)
        return store
    }

    private static func fetch(_ cls: String) async throws -> [String] {
        let query = """
        SELECT ?label WHERE {
          ?item wdt:P31 wd:\(cls) ; wikibase:sitelinks ?links ; rdfs:label ?label .
          FILTER(?links >= \(minSitelinks) && LANG(?label) = "en")
        }
        """
        var parts = URLComponents(string: "https://query.wikidata.org/sparql")!
        parts.queryItems = [URLQueryItem(name: "query", value: query)]
        var request = URLRequest(url: parts.url!, timeoutInterval: 70)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        request.setValue("Fluent/1.0 (Mac dictation app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let csv = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return csv.split(whereSeparator: \.isNewline).dropFirst()
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
    }

    /// Keeps names a speech model is likely to get wrong and that can't be mistaken for ordinary
    /// words: one word with a capital or digit inside ("PayPal", "eBay", "SpaceX", "1Password"), or
    /// one word that isn't English ("Duolingo"). Multi-word names ("Google Maps") come out right
    /// already, and "my space" style splits that start with a common word are skipped.
    @MainActor
    static func filter(_ labels: [String]) -> [String] {
        let checker = NSSpellChecker.shared
        var out = Set<String>()
        for label in labels {
            guard !label.contains(" "), (3...24).contains(label.count),
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }),
                  label.first?.isLetter == true || label.first?.isNumber == true else { continue }
            let inner = label.dropFirst()
            let camel = inner.contains(where: \.isUppercase) && label.contains(where: \.isLowercase)
            let mixedDigits = label.contains(where: \.isNumber) && label.contains(where: \.isLetter)
            if camel || mixedDigits {
                let firstPiece = (String(label.prefix(1)) + String(inner.prefix { !$0.isUppercase && !$0.isNumber })).lowercased()
                if commonWords.contains(firstPiece) { continue }
                out.insert(label)
            } else if label.first?.isUppercase == true, inner.allSatisfy({ $0.isLowercase || $0 == "-" }) {
                // A plain capitalised word: only if the spell checker doesn't know it as English.
                let lower = label.lowercased()
                if checker.checkSpelling(of: lower, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound {
                    out.insert(label)
                }
            }
        }
        return out.sorted()
    }

    /// Everyday words a name must not start with when split ("my space"): such phrases are left alone.
    static let commonWords: Set<String> = ["my", "your", "our", "his", "her", "their", "the", "a", "an", "all", "no", "any",
                                           "one", "go", "get", "let", "in", "on", "at", "to", "of", "it", "is", "we", "you",
                                           "me", "be", "do", "up", "so", "and", "or", "for", "with", "this", "that"]

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
