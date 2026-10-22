import Foundation

/// Layout added after cleanup, by rule rather than by the AI model, so it is instant and can never
/// drop or change a word: formatting only ever touches layout.
/// - Anywhere: your own name in a sign-off is spelled right ("Thanks. Jon." to "John").
/// Only in a long-form box (never a search box or one-line field):
/// - "new line" / "new paragraph" said at a pause: line breaks.
/// - Spoken sequences ("one, ... two, ..." or "first, ... second, ..."): a numbered list.
/// - Email: the greeting and your sign-off on their own lines.
enum TextShape {
    static func apply(_ text: String, longForm: Bool, lists: Bool, email: Bool, atStart: Bool) -> String {
        guard longForm else { return signOffName(text) }
        var t = spokenBreaks(text)
        // The sign-off comes off first, so it never ends up inside the last list item.
        if email { t = signOff(t) } else { t = signOffName(t) }
        if lists { t = numberedList(t) }
        if email, atStart { t = greeting(t) }
        return t
    }

    /// Where a sentence ends: "?" "!" a line break, or a "." followed by the end or a new sentence.
    /// "p.m. short day" and "e.g. this" carry on.
    private static func sentenceEnd(in text: String, from start: String.Index) -> String.Index? {
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if "?!\n".contains(c) { return i }
            if c == "." {
                let next = text.index(after: i)
                if next == text.endIndex { return i }
                let after = text[next...]
                if after.first!.isLetter || after.first!.isNumber { i = next; continue }        // "p.m", "3.5"
                if let word = after.drop(while: { $0 == " " }).first, word.isLowercase { i = next; continue }
                return i
            }
            i = text.index(after: i)
        }
        return nil
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

    /// "... meet me and third are you going ..." (no comma after the ordinal): only "and" plus an
    /// ordinal from second on, and it only counts when it continues a run, so "the third time" is safe.
    private static let andCueRe = try! NSRegularExpression(pattern:
        #"(?i)(\s+and\s+)(second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|finally|lastly)\s+(?=\p{L})"#)

    private struct Cue { let wordStart: String.Index; let itemStart: String.Index; let n: Int; let family: Int }

    /// Two or more items introduced in order ("One, ... Two, ..."), each with real words, become
    /// "1. ..." lines. The sentence before stays as the lead-in and anything after the last item
    /// stays after the list. Only the first such run is formatted.
    static func numberedList(_ text: String) -> String {
        let ns = NSRange(text.startIndex..., in: text)
        let matches = (cueRe.matches(in: text, range: ns) + andCueRe.matches(in: text, range: ns)).sorted { $0.range.location < $1.range.location }
        let cues: [Cue] = matches.compactMap { m in
            guard let wordR = Range(m.range(at: 2), in: text), let all = Range(m.range, in: text) else { return nil }
            var word = text[wordR].lowercased()
            if word.hasSuffix("ly"), word != "lastly" { word = String(word.dropLast(2)) }
            if let d = Int(word), (1...10).contains(d) { return Cue(wordStart: wordR.lowerBound, itemStart: all.upperBound, n: d, family: 0) }
            if let i = cardinals.firstIndex(of: word) { return Cue(wordStart: wordR.lowerBound, itemStart: all.upperBound, n: i + 1, family: 0) }
            if let i = ordinals.firstIndex(of: word) { return Cue(wordStart: wordR.lowerBound, itemStart: all.upperBound, n: i + 1, family: 1) }
            return Cue(wordStart: wordR.lowerBound, itemStart: all.upperBound, n: -1, family: 1)   // finally, lastly
        }
        // The first run that counts up from 1 (ordinals may end with "finally"). A run from 2 counts
        // too when it has two or more cues: the first marker was lost ("First" heard as "um"), so
        // the sentence just before "second" is item 1.
        func findRun(from start: Int) -> [Cue] {
            var run: [Cue] = []
            for c in cues {
                if run.isEmpty { if c.n == start { run = [c] }; continue }
                let last = run.last!
                // People mix the two ("one... second... and third..."), so the kind of word doesn't matter.
                if c.n == last.n + 1 || (c.n == -1 && last.n >= 1) { run.append(c); if c.n == -1 { break } }
                else if run.count >= 2 { break }
                else { run = c.n == start ? [c] : [] }
            }
            return run
        }
        var run = findRun(from: 1)
        var lostFirst: Range<String.Index>?
        if run.count < 2 {
            run = findRun(from: 2)
            guard run.count >= 2 else { return text }
            // Item 1: the last sentence before "second".
            let before = text[..<run[0].wordStart]
            guard let end = before.lastIndex(where: { ".?!".contains($0) }) else { return text }
            let start = before[..<end].lastIndex(where: { ".?!:\n".contains($0) }).map { text.index(after: $0) } ?? text.startIndex
            lostFirst = start..<text.index(after: end)
        }
        guard run.count >= 2 else { return text }

        var items: [String] = lostFirst.map { [String(text[$0])] } ?? []
        for (i, c) in run.enumerated() {
            let end: String.Index
            if i + 1 < run.count { end = run[i + 1].wordStart }
            else if let stop = sentenceEnd(in: text, from: c.itemStart) { end = text.index(after: stop) }
            else { end = text.endIndex }
            items.append(String(text[c.itemStart..<end]))
        }
        var cleaned = items.map(tidyItem)
        // Counting out loud ("one, two, three") is not a list: every item needs a real word.
        guard cleaned.allSatisfy({ item in
            item.split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 2 && !cardinals.contains($0.lowercased()) }
        }) else { return text }

        var intro = String(text[..<(lostFirst?.lowerBound ?? run[0].wordStart)]).trimmingCharacters(in: .whitespacesAndNewlines)
        if intro.hasSuffix(",") || intro.hasSuffix(";") { intro = String(intro.dropLast()) + ":" }
        let lastEnd: String.Index = {
            let c = run.last!
            if let stop = sentenceEnd(in: text, from: c.itemStart) { return text.index(after: stop) }
            return text.endIndex
        }()
        var outro = String(text[lastEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A run-on last item ("Are you free Friday, let me know.") gives its closing phrase back.
        if let (item, closer) = splitCloser(cleaned[cleaned.count - 1]) {
            cleaned[cleaned.count - 1] = item
            outro = outro.isEmpty ? closer : closer + "\n\n" + outro
        }
        let list = cleaned.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return [intro, list, outro].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static let closers = ["let me know what you think", "let me know", "looking forward to it", "talk soon"]
    private static let questionStarts: Set<String> = ["are", "is", "am", "can", "could", "did", "do", "does", "will", "would",
                                                      "should", "have", "has", "when", "what", "where", "why", "who", "how", "which"]

    /// "Are you free Friday, let me know." becomes ("Are you free Friday?", "Let me know.").
    private static func splitCloser(_ item: String) -> (String, String)? {
        let lower = item.lowercased()
        for c in closers {
            guard let r = lower.range(of: ", " + c, options: .backwards),
                  lower[r.upperBound...].allSatisfy({ ".!?".contains($0) }) else { continue }
            let head = String(item[..<item.index(item.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))])
            let first = head.split(separator: " ").first.map { $0.lowercased() } ?? ""
            let ending = questionStarts.contains(first) ? "?" : "."
            return (head + ending, capitaliseFirst(c) + ".")
        }
        return nil
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
    /// lines. Only your name counts, so "Thanks Paul" at the end of a message is left as a sentence. A
    /// near miss from the speech model ("Jon" for "John") counts and is written correctly.
    static func signOff(_ text: String, fullName: String = NSFullUserName()) -> String {
        guard let s = findSignOff(text, fullName: fullName) else { return text }
        var body = String(text[..<s.all.lowerBound]) + String(text[s.lead]).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(",") { body = String(body.dropLast()) + "." }   // "..., let me know, thanks, Sam."
        let sign = capitaliseFirst(String(text[s.word])) + ",\n" + s.name
        return body.isEmpty ? sign : body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + sign
    }

    /// Same sign-off, layout untouched: only the name is spelled right. For any text box.
    static func signOffName(_ text: String, fullName: String = NSFullUserName()) -> String {
        guard let s = findSignOff(text, fullName: fullName), String(text[s.nameRange]) != s.name else { return text }
        return text.replacingCharacters(in: s.nameRange, with: s.name)
    }

    private struct SignOff { let lead: Range<String.Index>; let word: Range<String.Index>; let nameRange: Range<String.Index>; let all: Range<String.Index>; let name: String }

    private static func findSignOff(_ text: String, fullName: String) -> SignOff? {
        let first = fullName.split(separator: " ").first.map(String.init) ?? ""
        guard !first.isEmpty else { return nil }
        let alts = signOffs.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: #"(?i)(^|[.?!,]\s+|\n)(\#(alts))[,.!]?\s+(\p{L}[\p{L}'-]*(?:\s\p{L}[\p{L}'-]*)?)[.!]?\s*$"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let lead = Range(m.range(at: 1), in: text), let word = Range(m.range(at: 2), in: text),
              let nameR = Range(m.range(at: 3), in: text), let all = Range(m.range, in: text) else { return nil }
        let said = String(text[nameR])
        func close(_ a: String, _ b: String) -> Bool {
            let x = a.lowercased(), y = b.lowercased()
            if x == y || (y.count >= 4 && WordDictionary.editDistance(x, y) <= 1) { return true }
            // Sounds like it: the speech model splits an unusual name into words ("Mary Ann" for
            // "Marianne"). Same first letter and at most half different counts.
            let sx = WordDictionary.squash(a), sy = WordDictionary.squash(b)
            guard sy.count >= 4, sx.first == sy.first else { return false }
            return Double(WordDictionary.editDistance(sx, sy)) <= Double(max(sx.count, sy.count)) * 0.5
        }
        let name: String
        if close(said, fullName) { name = fullName }
        else if close(said, first) { name = first }
        else { return nil }
        return SignOff(lead: lead, word: word, nameRange: nameR, all: all, name: name)
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
