import Charts
import SwiftUI

/// Numbers at the top of History: how much you've dictated and what it's saved you.
struct DashboardStats {
    let words: Int
    let dictations: Int
    let spokenMinutes: Double
    let savedMinutes: Double
    let pace: Int
    let streak: Int
    let perDay: [(day: Date, words: Int)]
    let topApps: [(app: String, share: Double)]

    /// Typing speed used for "time saved". A typical typist; stated in the tile's help text.
    static let typingWPM = 40.0

    init(_ entries: [HistoryStore.Entry]) {
        let typed = entries.filter { !$0.text.isEmpty && $0.method != "Discarded" }
        func count(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
        words = typed.reduce(0) { $0 + count($1.text) }
        dictations = typed.count
        spokenMinutes = typed.reduce(0) { $0 + $1.audioSeconds } / 60
        savedMinutes = max(0, Double(words) / Self.typingWPM - spokenMinutes)
        pace = spokenMinutes > 0.1 ? Int(Double(words) / spokenMinutes) : 0

        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var byDay: [Date: Int] = [:]
        for e in typed { byDay[cal.startOfDay(for: e.date), default: 0] += count(e.text) }
        perDay = (0..<14).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }.map { ($0, byDay[$0] ?? 0) }
        var s = 0
        var day = today
        if byDay[day] == nil, let y = cal.date(byAdding: .day, value: -1, to: day) { day = y }   // today not started yet
        while byDay[day] != nil { s += 1; day = cal.date(byAdding: .day, value: -1, to: day)! }
        streak = s

        var byApp: [String: Int] = [:]
        for e in typed { byApp[e.app, default: 0] += count(e.text) }
        let total = max(1, byApp.values.reduce(0, +))
        topApps = byApp.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, Double($0.value) / Double(total)) }
    }
}

struct DashboardView: View {
    let stats: DashboardStats
    @State private var hovered: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Tile(value: stats.words.formatted(), label: "words dictated")
                Tile(value: duration(stats.savedMinutes), label: "saved vs typing",
                     help: "Typing the same words at \(Int(DashboardStats.typingWPM)) words a minute, minus the time you spent talking.")
                Tile(value: "\(stats.pace)", label: "words a minute", help: "Your speaking pace across all dictations.")
                Tile(value: stats.dictations.formatted(), label: "dictations")
                Tile(value: "\(stats.streak)", label: stats.streak == 1 ? "day streak" : "day streak")
            }
            HStack(alignment: .bottom, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Words per day, last 14 days").font(.caption).foregroundStyle(.secondary)
                    Chart(stats.perDay, id: \.day) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("Words", d.words), width: .ratio(0.72))
                            .cornerRadius(4)
                            .foregroundStyle(Color.primary.opacity(hovered == nil || hovered == d.day ? 0.85 : 0.35))
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()) } }
                    .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                    .chartOverlay { proxy in
                        GeometryReader { geo in
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let p):
                                        let x = p.x - geo[proxy.plotFrame!].origin.x
                                        hovered = (proxy.value(atX: x) as Date?).map { Calendar.current.startOfDay(for: $0) }
                                    case .ended: hovered = nil
                                    }
                                }
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if let h = hovered, let d = stats.perDay.first(where: { $0.day == h }) {
                            Text("\(d.day.formatted(.dateTime.weekday(.abbreviated).month().day())): \(d.words) words")
                                .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(radius: 2))
                        }
                    }
                    .frame(height: 110)
                    .accessibilityLabel("Words per day over the last 14 days")
                }
                if !stats.topApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Where your words went").font(.caption).foregroundStyle(.secondary)
                        ForEach(stats.topApps, id: \.app) { a in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(a.app).font(.callout).lineLimit(1)
                                    Spacer()
                                    Text("\(Int((a.share * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                                GeometryReader { g in
                                    Capsule().fill(.quaternary).overlay(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.75)).frame(width: max(4, g.size.width * a.share))
                                    }
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                    .frame(width: 200)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
        .padding(.horizontal, 24).padding(.bottom, 10)
    }

    private func duration(_ minutes: Double) -> String {
        minutes < 60 ? "\(Int(minutes.rounded())) min" : String(format: "%.1f h", minutes / 60)
    }
}

private struct Tile: View {
    let value: String
    let label: String
    var help: String? = nil
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(hovering ? 1 : 0.7)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help ?? "")
    }
}
