import Foundation
import AppKit

/// Learns custom vocabulary from the user's corrections of dictated text: aligns the pasted text
/// with what the user edited it into and extracts short substituted spans (e.g. "Wakeen" → "Joaquin").
public enum EditLearner {
    public struct Candidate: Equatable, Sendable {
        public let heard: String
        public let corrected: String
    }

    static let stopwords: Set<String> = Set("""
    a an the and or but if then so of to in on at by for with from as is are was were be been am do does did have has had i you he she it we they me him her us them my your his its our their this that these those not no yes ok okay just very really
    """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { w in
            String(w).trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'’-@.")))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        }.filter { !$0.isEmpty }
    }

    /// Word-level LCS alignment returning substituted spans.
    static func substitutions(_ a: [String], _ b: [String]) -> [([String], [String])] {
        let n = a.count, m = b.count
        guard n > 0, m > 0, n * m < 250_000 else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var i = 0, j = 0
        var out: [([String], [String])] = []
        var da: [String] = [], db: [String] = []
        func flush() {
            if !da.isEmpty && !db.isEmpty { out.append((da, db)) }
            da = []; db = []
        }
        while i < n && j < m {
            if a[i] == b[j] { flush(); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { da.append(a[i]); i += 1 }
            else { db.append(b[j]); j += 1 }
        }
        da += a[i...]; db += b[j...]
        flush()
        return out
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a.lowercased()), b = Array(b.lowercased())
        if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// True when `word` appears somewhere in `text` that is not the start of a sentence.
    static func occursMidSentence(_ word: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])") else { return false }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
            if let last = before.last, !".!?\n:\"“".contains(last) { return true }
        }
        return false
    }

    /// True when every word is in the system spelling dictionary.
    static func isDictionaryPhrase(_ phrase: String) -> Bool {
        let checker = NSSpellChecker.shared
        return phrase.split(separator: " ").allSatisfy { word in
            let w = String(word)
            let r = checker.checkSpelling(of: w, startingAt: 0, language: nil, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            return r.location == NSNotFound
        }
    }

    /// Returns up to `limit` words/phrases worth adding to the dictionary.
    public static func candidates(original: String, edited: String, known: Set<String>, limit: Int = 4) -> [Candidate] {
        let a = tokens(original), b = tokens(edited)
        // Large rewrites are not corrections of recognition errors.
        guard !a.isEmpty, !b.isEmpty, abs(a.count - b.count) <= max(6, a.count / 2) else { return [] }
        var out: [Candidate] = []
        for (heard, corrected) in substitutions(a, b) {
            guard heard.count <= 4, corrected.count <= 4 else { continue }
            let h = heard.joined(separator: " "), c = corrected.joined(separator: " ")
            let cl = c.lowercased()
            if stopwords.contains(cl) || known.contains(cl) { continue }
            // The same fix made twice is one word to learn (the dictionary is case-insensitive).
            if out.contains(where: { $0.corrected.lowercased() == cl }) { continue }
            let pureCasing = h.lowercased() == cl
            if pureCasing { // only learn casing fixes that introduce capitals (names, brands)
                guard c != c.lowercased() else { continue }
            } else {
                // Contractions and inflections ("do not" → "don't", "run" → "runs") are not vocabulary.
                let apostrophes = CharacterSet(charactersIn: "'’")
                let isLowerContraction = { (w: String) in w.rangeOfCharacter(from: apostrophes) != nil && w.first?.isLowercase == true }
                if isLowerContraction(c) || isLowerContraction(h) { continue }
                if cl.hasPrefix(h.lowercased()) && cl.count - h.count <= 2 { continue }
                if h.lowercased().hasPrefix(cl) && h.count - cl.count <= 2 { continue }
            }
            if c.count < 3 || c.count > 40 { continue }
            if c.allSatisfy({ $0.isNumber || $0.isPunctuation }) { continue }
            // Must plausibly sound alike: similar spelling, or the correction looks like a proper noun/term.
            let hFlat = h.replacingOccurrences(of: " ", with: ""), cFlat = c.replacingOccurrences(of: " ", with: "")
            let similarity = 1 - Double(levenshtein(hFlat, cFlat)) / Double(max(hFlat.count, cFlat.count))
            let looksLikeTerm = c.first?.isUppercase == true || c.contains(where: { $0.isNumber }) ||
                c.dropFirst().contains(where: { $0.isUppercase })
            guard pureCasing || similarity >= 0.45 || (looksLikeTerm && similarity >= 0.25) else { continue }
            // Swapping one ordinary word for another ("Tuesday" → "Friday") is an edit of meaning, not a
            // recognition error. Learn only when one side is not a dictionary word, or it is term-like.
            let termLike = c.dropFirst().contains(where: { $0.isUppercase }) || c.contains(where: { $0.isNumber })
            if !termLike && !pureCasing && isDictionaryPhrase(c) && isDictionaryPhrase(h) { continue }
            // Capitalising the first word of a sentence is grammar, not vocabulary.
            if pureCasing && !occursMidSentence(c, in: edited) { continue }
            out.append(Candidate(heard: h, corrected: c))
            if out.count >= limit { break }
        }
        return out
    }
}
