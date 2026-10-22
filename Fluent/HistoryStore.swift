import Foundation
import Observation

/// Every dictation, kept on this Mac in Application Support/Fluent/history.json (newest first,
/// last 1,000). Answers "where did my words go?".
@MainActor
@Observable
final class HistoryStore {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let text: String
        let raw: String
        let app: String
        let method: String
        let seconds: Double
        let audioSeconds: Double
    }

    private(set) var entries: [Entry] = []
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fluent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder.iso.decode([Entry].self, from: data) { entries = saved }
    }

    func add(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > 1000 { entries.removeLast(entries.count - 1000) }
        save()
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        let snapshot = entries
        let url = self.url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder.iso.encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
