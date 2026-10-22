import Foundation

/// Layout added after cleanup, by rule rather than by the AI model, so it is instant and can never
/// drop or change a word: formatting only ever touches layout.
/// - "new line" / "new paragraph" said at a pause: line breaks, in every app.
/// - Spoken sequences ("one, ... two, ..." or "first, ... second, ..."): a numbered list.
/// - Email: the greeting and your sign-off on their own lines.
enum TextShape {
    static func apply(_ text: String, lists: Bool, email: Bool, atStart: Bool) -> String {
        var t = spokenBreaks(text)
        if lists { t = numberedList(t) }
        if email {
            if atStart { t = greeting(t) }
            t = signOff(t)
        }
        return t
    }

    // MARK: Spoken line breaks

    private static let breakRules: [(NSRegularExpression, String)] = [("new paragraph", "\n\n"), ("new line", "\n")].map { phrase, br in
        // Only at a pause (start of text or after punctuation), so "a new line of products" is left alone.
        (try! NSRegularExpression(pattern: #"(?i)(^|[.?!,;:])\s*\#(phrase)\b[.,;:!?]?\s*"#), br)
    }

    static func spokenBreaks(_ text: String) -> String {
        var t = text
        for (re, br) in breakRules {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1" + br)
        }
        return t == text ? t : capitaliseLineStarts(t.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Numbered lists

    private static let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let cueRe = try! NSRegularExpression(pattern:
        #"(?i)(^|[.?!,;:]\s+(?:and\s+|or\s+)?|\n)(one|two|three|four|five|six|seven|eight|nine|ten|10|[1-9]|first(?:ly)?|second(?:ly)?|third(?:ly)?|fourth|fifth|sixth|seventh|eighth|ninth|tenth|finally|lastly)\s*[,:.)]\s+"#)

    private struct Cue { let wordStart: String.Index; let itemStart: String.Index; let n: Int; let family: Int }

    /// Two or more items introduced in order ("One, ... Two, ..."), each with real words, become
    /// "1. ..." lines. The sentence before stays as the lead-in and anything after the last item
    /// stays after the list. Only the first such run is formatted.
    static func numberedList(_ text: String) -> String {
        let ns = NSRange(text.startIndex..., in: text)
        let cues: [Cue] = cueRe.matches(in: text, range: ns).compactMap { m in
            guard let wordR = Range(m.range(at: 2), in: text), let all = Range(m.range, in: text) else { return nil }
            var word = text[wordR].lowercased()
            if word.hasSuffix("ly"), word != "lastly" { word = String(word.dropLast(2)) }
            if let d = Int(word), (1...10).contains(d) { return Cue(wordStart: wordR.lowerBound, itemStart: all.upperBound, n: d, family: 0) }
            if let i = cardinals.firstIndex(of: word) { return Cue(wordStart: wordR.lowerBound, itemStart: all.upperBound, n: i + 1, family: 0) }
            if let i = ordinals.firstIndex(of: word) { return Cue(wordStart: wordR.lowerBound, itemStart: all.upperBound, n: i + 1, family: 1) }
            return Cue(wordStart: wordR.lowerBound, itemStart: all.upperBound, n: -1, family: 1)   // finally, lastly
        }
        // The first run that starts at 1 and counts up (ordinals may end with "finally").
        var run: [Cue] = []
        for c in cues {
            if run.isEmpty { if c.n == 1 { run = [c] }; continue }
            let last = run.last!
            if c.family == last.family, c.n == last.n + 1 || (c.n == -1 && c.family == 1) { run.append(c); if c.n == -1 { break } }
            else if run.count >= 2 { break }
            else { run = c.n == 1 ? [c] : [] }
        }
        guard run.count >= 2 else { return text }

        var items: [String] = []
        for (i, c) in run.enumerated() {
            let end: String.Index
            if i + 1 < run.count { end = run[i + 1].wordStart }
            else if let stop = text[c.itemStart...].firstIndex(where: { ".?!\n".contains($0) }) { end = text.index(after: stop) }
            else { end = text.endIndex }
            items.append(String(text[c.itemStart..<end]))
        }
        let cleaned = items.map(tidyItem)
        // Counting out loud ("one, two, three") is not a list: every item needs a real word.
        guard cleaned.allSatisfy({ item in
            item.split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 2 && !cardinals.contains($0.lowercased()) }
        }) else { return text }

        var intro = String(text[..<run[0].wordStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        if intro.hasSuffix(",") || intro.hasSuffix(";") { intro = String(intro.dropLast()) + ":" }
        let lastEnd: String.Index = {
            let c = run.last!
            if let stop = text[c.itemStart...].firstIndex(where: { ".?!\n".contains($0) }) { return text.index(after: stop) }
            return text.endIndex
        }()
        let outro = String(text[lastEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let list = cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return [intro, list, outro].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Trims the joins between items ("eggs, and" becomes "eggs") and capitalises the item.
    private static func tidyItem(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for tail in [", and", ", or", " and", " or", ",", ";"] where t.lowercased().hasSuffix(tail) {
            t = String(t.dropLast(tail.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return capitaliseFirst(t)
    }

    // MARK: Email

    private static let greetingRe = try! NSRegularExpression(pattern:
        #"(?i)^\s*((?:dear|hi|hello|hey|good morning|good afternoon|good evening)\b[^,.!?\n]{0,40}[,!])\s+(?=\S)"#)

    /// "Dear Swati, how are you?" becomes "Dear Swati," and a blank line before the rest.
    static func greeting(_ text: String) -> String {
        guard let m = greetingRe.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let g = Range(m.range(at: 1), in: text), let all = Range(m.range, in: text) else { return text }
        let rest = String(text[all.upperBound...])
        return String(text[g]) + "\n\n" + capitaliseFirst(rest)
    }

    private static let signOffs = ["best regards", "kind regards", "warm regards", "all the best", "thanks so much",
                                   "thank you", "talk soon", "regards", "best", "thanks", "cheers", "sincerely", "warmly"]

    /// A sign-off with your own name at the very end ("... Let me know. Best, Sam") goes on its own
    /// lines. Only your name counts, so "Thanks Paul" at the end of a message is left as a sentence.
    static func signOff(_ text: String, fullName: String = NSFullUserName()) -> String {
        let names = Set([fullName, fullName.split(separator: " ").first.map(String.init) ?? ""].filter { !$0.isEmpty }.map { $0.lowercased() })
        guard !names.isEmpty else { return text }
        let alts = signOffs.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let nameAlts = names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: #"(?i)(^|[.?!]\s+|\n)(\#(alts))[,.!]?\s+(\#(nameAlts))[.!]?\s*$"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let lead = Range(m.range(at: 1), in: text), let word = Range(m.range(at: 2), in: text),
              let name = Range(m.range(at: 3), in: text), let all = Range(m.range, in: text) else { return text }
        let body = String(text[..<all.lowerBound]) + String(text[lead]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sign = capitaliseFirst(String(text[word])) + ",\n" + capitaliseFirst(String(text[name]))
        return body.isEmpty ? sign : body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + sign
    }

    // MARK: Helpers

    private static func capitaliseFirst(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter) else { return s }
        return s.replacingCharacters(in: i...i, with: s[i].uppercased())
    }

    /// Capitalises a line only when the line before it ended a sentence (or was blank), so a break
    /// said mid-sentence ("Monday, new line, and finish") keeps its lowercase.
    private static func capitaliseLineStarts(_ s: String) -> String {
        var previous = ""
        return s.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ended = previous.isEmpty || ".?!:".contains(previous.last!)
            if !line.isEmpty { previous = line } else { previous = "" }
            return ended ? capitaliseFirst(line) : line
        }.joined(separator: "\n")
    }
}
