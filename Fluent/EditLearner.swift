import AppKit
import ApplicationServices

/// After Fluent types something, watches that stretch of text for a minute. When you replace a
/// word or two with something that sounds or spells similar and looks like a name ("fluid audio"
/// to "FluidAudio"), that's a correction worth remembering. Changes of mind ("Thursday" to
/// "Friday"), grammar fixes ("their" to "there") and number changes are not learned.
@MainActor
final class EditLearner {
    var onLearned: (_ heard: String, _ correct: String, _ app: String) -> Void = { _, _, _ in }

    private var timer: Timer?
    private var generation = 0

    /// Call right after text went in. `text` is exactly what was inserted.
    func watch(_ text: String, app: String) {
        stop()
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        let inserted = text.trimmingCharacters(in: .whitespaces)
        generation += 1
        let gen = generation
        Task.detached {
            guard let target = Self.locate(pid: pid, insertedLength: inserted.utf16.count) else { return }
            await MainActor.run { self.poll(target, inserted: inserted, app: app, gen: gen) }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private var lastSeen: [Swap] = []
    private var learned = Set<String>()
    private var ticks = 0

    private func poll(_ target: Target, inserted: String, app: String, gen: Int) {
        guard gen == generation else { return }
        ticks = 0
        lastSeen = []
        learned = []
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(target, inserted: inserted, app: app, gen: gen) }
        }
    }

    private func tick(_ target: Target, inserted: String, app: String, gen: Int) {
        guard gen == generation else { return }
        ticks += 1
        if ticks > 60 { stop(); return }
        Task {
            let swaps = await Task.detached { () -> [Swap] in
                guard let now = Self.read(target, length: inserted.utf16.count + 40) else { return [] }
                return Self.corrections(from: inserted, to: now)
            }.value
            guard gen == generation else { return }
            // Only act on edits that stayed the same for two checks in a row (finished typing).
            for s in swaps where lastSeen.contains(s) && !learned.contains(s.key) {
                learned.insert(s.key)
                onLearned(s.heard, s.correct, app)
            }
            lastSeen = swaps
        }
    }

    // MARK: Accessibility (any thread)

    struct Target: @unchecked Sendable {
        let element: AXUIElement
        let start: Int
    }

    nonisolated static func locate(pid: pid_t, insertedLength: Int) -> Target? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        let element = ref as! AXUIElement
        var r: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &r) == .success,
              let rv = r, CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range), range.location >= insertedLength else { return nil }
        return Target(element: element, start: range.location - insertedLength)
    }

    nonisolated static func read(_ target: Target, length: Int) -> String? {
        var countRef: CFTypeRef?
        var total = Int.max
        if AXUIElementCopyAttributeValue(target.element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let n = countRef as? Int { total = n }
        guard target.start < total else { return nil }
        var want = CFRange(location: target.start, length: max(0, min(length, total - target.start)))
        guard let param = AXValueCreate(.cfRange, &want) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(target.element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         param, &out) == .success else { return nil }
        return out as? String
    }

    // MARK: Finding corrections

    struct Swap: Equatable, Sendable {
        let heard: String
        let correct: String
        var key: String { heard.lowercased() + "→" + correct }
    }

    /// Word-level comparison of what was typed with what's there now. Returns replaced stretches
    /// of 1 to 3 words that look like spelling corrections of a name or term.
    nonisolated static func corrections(from inserted: String, to now: String) -> [Swap] {
        // Split on line breaks too, or "\nOn" is taken for a word and learned.
        let a = inserted.split(whereSeparator: \.isWhitespace).map(String.init)
        var b = now.split(whereSeparator: \.isWhitespace).map(String.init)
        if b.count > a.count + 6 { b = Array(b.prefix(a.count + 6)) }   // ignore what you typed after it
        func norm(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let na = a.map(norm), nb = b.map(norm)

        // Longest common subsequence over words.
        var lcs = Array(repeating: Array(repeating: 0, count: nb.count + 1), count: na.count + 1)
        for i in stride(from: na.count - 1, through: 0, by: -1) {
            for j in stride(from: nb.count - 1, through: 0, by: -1) {
                lcs[i][j] = na[i] == nb[j] && a[i].trimmingCharacters(in: .punctuationCharacters) == b[j].trimmingCharacters(in: .punctuationCharacters)
                    ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var swaps: [Swap] = []
        var i = 0, j = 0
        var oldRun: [String] = [], newRun: [String] = []
        func flush() {
            defer { oldRun.removeAll(); newRun.removeAll() }
            guard (1...3).contains(oldRun.count), (1...3).contains(newRun.count) else { return }
            let heard = oldRun.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            let correct = newRun.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            if looksLikeNameCorrection(heard: heard, correct: correct) { swaps.append(Swap(heard: heard, correct: correct)) }
        }
        let same = { (x: Int, y: Int) in na[x] == nb[y] && a[x].trimmingCharacters(in: .punctuationCharacters) == b[y].trimmingCharacters(in: .punctuationCharacters) }
        while i < na.count && j < nb.count {
            if same(i, j) { flush(); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { oldRun.append(a[i]); i += 1 }
            else { newRun.append(b[j]); j += 1 }
        }
        // Words added after the end are new typing, not corrections.
        if i < na.count { oldRun.append(contentsOf: a[i...]) }
        if !oldRun.isEmpty, !newRun.isEmpty { flush() }
        return swaps
    }

    /// True for a plain swap of ordinary words, where the spell checker's view decides; false when
    /// words were joined or split, or a capital appears mid-word ("FluidAudio"): those are names.
    nonisolated static func isPlainWordSwap(heard: String, correct: String) -> Bool {
        let midCapital = correct.split(separator: " ").contains { $0.dropFirst().contains(where: \.isUppercase) }
        return !midCapital && heard.split(separator: " ").count == correct.split(separator: " ").count
    }

    nonisolated static func looksLikeNameCorrection(heard: String, correct: String) -> Bool {
        guard heard != correct, !correct.isEmpty, !correct.contains(where: \.isNewline) else { return false }
        if correct.contains(where: \.isNumber) && !correct.contains(where: \.isLetter) { return false }   // a number changed: a fact
        if heard.contains(where: \.isNumber) != correct.contains(where: \.isNumber),
           !correct.contains(where: \.isLetter) { return false }
        // Must look like a name or term: a capital letter, or letters mixed with digits ("n8n").
        let namey = correct.contains(where: \.isUppercase) || (correct.contains(where: \.isNumber) && correct.contains(where: \.isLetter))
        guard namey else { return false }
        let x = WordDictionary.squash(heard), y = WordDictionary.squash(correct)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }   // only spacing or capitals changed ("fluid audio" to "FluidAudio")
        let d = Double(WordDictionary.editDistance(x, y)) / Double(max(x.count, y.count))
        return d <= 0.45
    }
}
