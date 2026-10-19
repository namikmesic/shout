import Foundation

/// Deterministic text transforms applied around the language model.
public enum TextRules {

    // MARK: Normalisation helpers

    static func normalized(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func wordCount(_ s: String) -> Int {
        var n = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    /// Builds a case-insensitive regex for a phrase that tolerates punctuation/extra spaces between words.
    /// Symbols at the phrase's edges belong to the term (".NET", "C++", "C#"): without them the pattern would match
    /// any "net" or "c". Trailing sentence punctuation ("Inc.", "Yahoo!") stays optional.
    static func phraseRegex(_ phrase: String) -> NSRegularExpression? {
        let words = normalized(phrase).split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        var body = words.joined(separator: "[\\s,.\\-]+")
        let isWordChar = { (c: Character) in c.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) }
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = String(trimmed.prefix { !isWordChar($0) })
        let trail = String(trimmed.reversed().prefix { !isWordChar($0) }.reversed())
        if !lead.isEmpty, !lead.contains(where: \.isWhitespace) {
            body = NSRegularExpression.escapedPattern(for: lead) + body
        }
        if !trail.isEmpty, !trail.contains(where: \.isWhitespace) {
            let t = NSRegularExpression.escapedPattern(for: trail)
            body += trail.allSatisfy({ ".,!?;:".contains($0) }) ? "(?:\(t))?" : t
        }
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + body + "(?![\\p{L}\\p{N}])", options: [.caseInsensitive])
    }

    // MARK: Hallucinations & artefacts

    static let hallucinations: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching", "thank you very much", "you", "bye",
        "thanks", "subtitles by the amara org community", "please subscribe", "so", "okay", "oh",
        "blank audio", "silence", "music", "applause", "the end",
    ]

    /// Removes bracketed sound annotations ("[Music]", "(laughs)") and known silence hallucinations.
    public static func cleanASRArtifacts(_ text: String, speechSeconds: Double) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\\[(?:[^\\]]{0,40})\\]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\((?:music|applause|laughs?|laughter|silence|inaudible|upbeat music|sighs?|coughs?)\\)",
                                   with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "[♪♫]+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression) // gaps left by removals
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if speechSeconds < 1.5 && hallucinations.contains(normalized(t)) { return "" }
        return t
    }

    // MARK: Fillers (used when no language model is available or as a fallback)

    public static func removeFillers(_ text: String) -> String {
        var t = text
        let pattern = "(?<![\\p{L}])(?:um+|uh+|uhm+|erm+|er|ah+|hmm+|mm+)(?![\\p{L}])[,.]?\\s*"
        t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s+([,.!?])", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: ",\\s*,", with: ",", options: .regularExpression)
        t = t.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "^[,.]\\s*", with: "", options: .regularExpression)
        return capitalizeFirst(t)
    }

    static func capitalizeFirst(_ s: String) -> String {
        guard let first = s.first, first.isLowercase else { return s }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: Snippets, replacements and vocabulary

    /// If the whole utterance is a snippet trigger, returns the expansion.
    public static func exactSnippet(_ text: String, snippets: [DictionaryEntry]) -> DictionaryEntry? {
        let n = normalized(text)
        guard !n.isEmpty else { return nil }
        return snippets.first { normalized($0.phrase) == n && $0.replacement != nil }
    }

    /// Replaces snippet triggers and "say X, write Y" phrases inside the text.
    /// Returns the new text and the ids of entries that were applied.
    public static func applyReplacements(_ text: String, entries: [DictionaryEntry]) -> (String, [Int64]) {
        var t = text
        var used: [Int64] = []
        // Longer phrases first so "my work email" wins over "email".
        for e in entries.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            guard let replacement = e.replacement, let re = phraseRegex(e.phrase) else { continue }
            let range = NSRange(t.startIndex..., in: t)
            if re.firstMatch(in: t, range: range) != nil {
                t = re.stringByReplacingMatches(in: t, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
                used.append(e.id)
            }
        }
        return (t, used)
    }

    /// Fixes the casing/spelling of vocabulary words that were recognised case-insensitively
    /// (e.g. "kubernetes" → "Kubernetes", "chat gpt" → "ChatGPT").
    public static func applyVocabulary(_ text: String, words: [DictionaryEntry]) -> (String, [Int64]) {
        var t = text
        var used: [Int64] = []
        for e in words.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            let phrase = e.phrase
            guard phrase.count >= 2, let re = phraseRegex(phrase) else { continue }
            let range = NSRange(t.startIndex..., in: t)
            let matches = re.matches(in: t, range: range)
            guard !matches.isEmpty else { continue }
            var changed = false
            for m in matches.reversed() {
                guard let r = Range(m.range, in: t) else { continue }
                if String(t[r]) != phrase {
                    t.replaceSubrange(r, with: phrase)
                    changed = true
                }
            }
            if changed || !matches.isEmpty { used.append(e.id) }
        }
        return (t, used)
    }

    // MARK: Voice commands

    /// Detects a trailing "press enter" / "press return" command.
    public static func extractPressEnter(_ text: String) -> (String, Bool) {
        let pattern = ",?\\s*(?:and\\s+)?(?:press|hit|send)\\s+(?:enter|return)[.!]?\\s*$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return (text, false) }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return (text, false) }
        var t = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix(",") { t.removeLast() }
        return (t, true)
    }

    // MARK: Tone & per-app modes

    public static func applyTone(_ text: String, tone: Tone, category: AppCategory) -> String {
        guard category != .developer && category != .terminal else { return text }
        var t = text
        switch tone {
        case .formal, .excited:
            break
        case .casual:
            t = dropFinalPeriod(t)
        case .veryCasual:
            t = dropFinalPeriod(lowercaseSentenceStarts(t))
        }
        return t
    }

    public static func applyFormatMode(_ text: String, mode: FormatMode) -> String {
        switch mode {
        case .lowercase: return text.lowercased()
        case .casual: return dropFinalPeriod(text)
        default: return text
        }
    }

    static func dropFinalPeriod(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep "etc." / "a.m." style abbreviations and ellipses.
        if t.hasSuffix(".") && !t.hasSuffix("..") && !t.hasSuffix(".m.") && !t.lowercased().hasSuffix("etc.") {
            // Only for short message-like text; multi-paragraph text keeps its punctuation.
            if !t.contains("\n\n") { t.removeLast() }
        }
        return t
    }

    static let keepCapitalized: Set<String> = ["I", "I'm", "I'll", "I've", "I'd", "I’m", "I’ll", "I’ve", "I’d"]

    static func lowercaseSentenceStarts(_ s: String) -> String {
        var out = ""
        var atStart = true
        var word = ""
        func flush() {
            if atStart && !word.isEmpty {
                let isAcronym = word.count > 1 && word == word.uppercased() && word.rangeOfCharacter(from: .lowercaseLetters) == nil
                if !keepCapitalized.contains(word) && !isAcronym, let f = word.first {
                    word = f.lowercased() + word.dropFirst()
                }
                atStart = false
            }
            out += word; word = ""
        }
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" { // digits too: "3D" is one word
                word.append(ch)
            } else {
                flush()
                out.append(ch)
                if ".!?\n".contains(ch) { atStart = true }
            }
        }
        flush()
        return out
    }

    // MARK: Fit to cursor

    static let commonWords: Set<String> = Set("""
    a about above after again against all also am an and any are as at be because been before being below between both but by can could did do does doing down during each else even ever every few for from further get gets got had has have having he her here hers him his how however i if in into is it its just let lets like made make many may me might more most much must my need never no nor not now of off often on once one only or other our out over own perhaps please quite rather really same she should since so some still such than that the their them then there these they this those though through thus to too under until up upon us very was we were what when where whether which while who whom whose why will with within without would yes yet you your yours yeah okay ok oh well maybe actually basically anyway also plus because especially including
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Adjusts casing, spacing and final punctuation so the text fits naturally at the cursor.
    public static func fitToCursor(_ text: String, before: String?, after: String?) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, before != nil || after != nil else { return t }
        let before = before ?? ""
        let after = after ?? ""
        let beforeTrim = before.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression)

        // Continuing a sentence: lowercase a common first word.
        if let last = beforeTrim.last, !".!?:\n\"“".contains(last) {
            if let firstWord = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first {
                let w = String(firstWord)
                if !keepCapitalized.contains(w), commonWords.contains(w.lowercased()), w.first?.isUppercase == true,
                   w.dropFirst().allSatisfy({ $0.isLowercase || $0 == "'" }) {
                    // Only when the text starts with the word: after a quote or a digit, splicing would drop characters.
                    if t.hasPrefix(w) { t = w.lowercased() + t.dropFirst(w.count) }
                }
            }
        }

        // Text follows the cursor mid-sentence: drop a final period.
        let afterTrim = after.replacingOccurrences(of: "^[ \\t]+", with: "", options: .regularExpression)
        if let next = afterTrim.first, next.isLowercase || next.isNumber || next == "," {
            if t.hasSuffix(".") && !t.hasSuffix("..") { t.removeLast() }
        }

        // Leading space.
        if let prev = before.last, !prev.isWhitespace, !"([{\"'“‘/-@#".contains(prev),
           let first = t.first, !".,;:!?)]}%".contains(first) {
            t = " " + t
        }
        // Trailing space.
        if let next = after.first, next.isLetter || next.isNumber {
            t += " "
        }
        return t
    }

    /// Final tidy-up: trims, collapses runs of blank lines and stray spaces before punctuation.
    public static func tidy(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
