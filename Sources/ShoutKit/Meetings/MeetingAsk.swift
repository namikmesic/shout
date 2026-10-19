import Foundation
import ShoutLLM

/// One meeting's material offered to the model when answering a question.
public struct AskSource: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var date: Date
    public var summary: String?
    public var notes: String?
    /// Transcript text: the whole transcript for a single-meeting question, else matching excerpts.
    public var transcript: String

    public init(id: String, title: String, date: Date, summary: String? = nil, notes: String? = nil, transcript: String = "") {
        self.id = id; self.title = title; self.date = date; self.summary = summary; self.notes = notes; self.transcript = transcript
    }
}

/// Answers questions about meetings with the local language model ("Ask"), from summaries, the user's
/// notes and transcript excerpts that fit the model's context.
public enum MeetingAsk {
    public struct Turn: Sendable, Equatable {
        public var question: String
        public var answer: String
        public init(question: String, answer: String) { self.question = question; self.answer = answer }
    }

    /// Chat-template tokens and estimation error.
    static let reserveTokens = 320
    /// A meeting that doesn't fit whole and would get less room than this is left out rather than cut to nothing.
    static let minSourceTokens = 120
    /// Transcript lines longer than this (one speaker talking for minutes) are split so excerpts stay small.
    static let maxLineTokens = 250
    /// A meeting's title is cut to this in the prompt, since titles have no length limit. With the date, the
    /// header stays well under `minSourceTokens`, so a meeting that is cut to its share always fits it.
    static let maxTitleTokens = 40

    /// Tokens kept for the answer: at most 700, and a sixth of a small context.
    public static func replyTokens(contextTokens: Int) -> Int { min(700, contextTokens / 6) }

    /// Words worth searching for: no stop words, no short words.
    public static func keywords(_ question: String) -> [String] {
        let stop: Set<String> = ["what", "when", "where", "which", "who", "whom", "why", "how", "the", "and", "for", "are", "was",
                                 "were", "did", "does", "about", "with", "from", "that", "this", "there", "their", "have", "has",
                                 "had", "into", "any", "all", "our", "your", "you", "can", "could", "would", "should", "will",
                                 "meeting", "meetings", "call", "calls", "said", "say", "tell", "give", "list", "show", "last",
                                 "yesterday", "today", "week", "they", "them", "been", "being", "items", "item", "action"]
        var seen = Set<String>()
        return question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
    }

    /// "You: …" / "Others: …" lines, consecutive lines of one speaker merged.
    public static func transcriptLines(_ segments: [MeetingSegment]) -> [String] {
        var out: [(String, String)] = []
        for s in segments where s.marker == nil && !s.latched && !s.displayText.isEmpty {
            if let last = out.last, last.0 == s.speakerLabel { out[out.count - 1].1 += " " + s.displayText }
            else { out.append((s.speakerLabel, s.displayText)) }
        }
        return out.map { "\($0.0): \($0.1)" }
    }

    /// Lines of a transcript that contain a keyword, with one line of context on each side.
    public static func excerpts(_ lines: [String], keywords: [String], maxLines: Int = 24) -> String {
        guard !keywords.isEmpty else { return "" }
        var keep = IndexSet()
        for (i, line) in lines.enumerated() {
            let lower = line.lowercased()
            guard keywords.contains(where: { lower.contains($0) }) else { continue }
            keep.insert(integersIn: max(0, i - 1)...min(lines.count - 1, i + 1))
            if keep.count >= maxLines { break }
        }
        var out: [String] = []
        var last = -2
        for i in keep {
            if i != last + 1 && !out.isEmpty { out.append("…") }
            out.append(lines[i]); last = i
        }
        return out.joined(separator: "\n")
    }

    /// Earlier exchanges of a saved chat that got an answer, oldest first (the `history` for a follow-up).
    public static func history(_ messages: [AskMessage]) -> [Turn] {
        var questions: [String: String] = [:]
        var turns: [Turn] = []
        for m in messages.sorted(by: { $0.order < $1.order }) {
            switch m.role {
            case .user: questions[m.turnID] = m.content
            case .assistant:
                if m.status == .succeeded, let q = questions[m.turnID] { turns.append(Turn(question: q, answer: m.content)) }
            }
        }
        return turns
    }

    // MARK: Prompt

    /// Builds the prompt so that it fits `contextTokens` with room for the reply: the newest earlier exchanges
    /// that fit a third of the room, then as much of each meeting as fits the rest, shared fairly between
    /// meetings. A transcript that doesn't fit is cut to its beginning and end plus the lines around the
    /// question's keywords.
    public static func messages(question: String, history: [Turn], sources: [AskSource], userName: String?,
                                now: Date = Date(), contextTokens: Int = 8192) -> [ChatMessage] {
        let day = DateFormatter()
        // English, like the rest of the prompt, whatever the Mac's language.
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEEE, MMMM d, yyyy"
        let me = userName.map { "The user is \($0); \"You\" in transcripts is the user. " } ?? "\"You\" in transcripts is the user. "
        let system = """
        You answer questions about the user's meetings. Use only the meeting material provided. \(me)"Others" are the \
        other people on the call; any other transcript label is the name of the person speaking. Today is \(day.string(from: now)).
        Be direct and concise. Use short paragraphs or bullet points in Markdown. After a fact, name the meeting it \
        comes from in square brackets, e.g. [Weekly sync]. If the material does not contain the answer, say so in one \
        sentence; never invent names, dates or numbers.
        """
        let lead = "Meeting material:\n\n"
        let primer = "I've read the meeting material. What would you like to know?"
        let est = MeetingSummarizer.estimateTokens
        var room = contextTokens - replyTokens(contextTokens: contextTokens) - reserveTokens
            - est(system) - est(lead) - est(primer) - est(question)

        // Earlier exchanges, newest first, within a third of the room; a long answer is cut.
        var kept: [Turn] = []
        var historyRoom = max(0, room / 3)
        for t in history.reversed() {
            let answer = MeetingSummarizer.truncate(t.answer, toTokens: max(60, room / 4))
            let cost = est(t.question) + est(answer) + 10
            guard cost <= historyRoom else { break }
            kept.insert(Turn(question: t.question, answer: answer), at: 0)
            historyRoom -= cost; room -= cost
        }

        let material = fitMaterial(sources, keywords: keywords(question), budget: room, day: day)
        let none = sources.isEmpty ? "(no meetings found)" : "(meetings were found, but they don't fit in the model's context)"
        var msgs = [ChatMessage(.system, system), ChatMessage(.user, lead + (material.isEmpty ? none : material))]
        msgs.append(ChatMessage(.assistant, primer))
        for t in kept {
            msgs.append(ChatMessage(.user, t.question))
            msgs.append(ChatMessage(.assistant, t.answer))
        }
        msgs.append(ChatMessage(.user, question))
        return msgs
    }

    /// The meetings' material within `budget` tokens. Each meeting gets a fair share (one that needs less
    /// leaves the rest to the others); inside its share the summary and notes are kept short so most of it
    /// goes to the transcript.
    static func fitMaterial(_ sources: [AskSource], keywords: [String], budget: Int, day: DateFormatter) -> String {
        let est = MeetingSummarizer.estimateTokens
        let blocks = sources.map { s -> (header: String, summary: String, notes: String, lines: [String]) in
            let notes = (s.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = s.title.isEmpty ? "Untitled meeting" : MeetingSummarizer.truncate(s.title, toTokens: maxTitleTokens)
            return ("### \(title) (\(day.string(from: s.date)))\n",
                    s.summary ?? "", notes, s.transcript.isEmpty ? [] : s.transcript.components(separatedBy: "\n"))
        }
        func render(_ b: (header: String, summary: String, notes: String, lines: [String]), transcript: String) -> String {
            var out = b.header
            if !b.summary.isEmpty { out += "Summary:\n\(b.summary)\n" }
            if !b.notes.isEmpty { out += "User's notes:\n\(b.notes)\n" }
            if !transcript.isEmpty { out += "Transcript:\n\(transcript)\n" }
            return out
        }
        let full = blocks.map { render($0, transcript: $0.lines.joined(separator: "\n")) }
        let costs = full.map { est($0) + 1 }
        var shares = fairShares(costs, budget: budget)
        // Too many meetings for a usable share each: the first (the best match) gets the room rather than none of them.
        if !shares.isEmpty, budget >= minSourceTokens,
           !shares.indices.contains(where: { costs[$0] <= shares[$0] || shares[$0] >= minSourceTokens }) {
            shares = [budget] + Array(repeating: 0, count: shares.count - 1)
        }
        // Text cut to fit `room`; left out when the room is too small for more than a bare "…".
        func fit(_ text: String, _ room: Int) -> String {
            if est(text) <= room { return text }
            return room < 10 ? "" : MeetingSummarizer.truncate(text, toTokens: room)
        }
        var out = ""
        for (i, b) in blocks.enumerated() {
            // A small meeting that fits whole is kept; only one that would be cut to almost nothing is left out.
            if costs[i] <= shares[i] { out += full[i] + "\n"; continue }
            guard shares[i] >= minSourceTokens else { continue }
            var left = max(0, shares[i] - est(b.header) - 12) // labels
            let summary = fit(b.summary, left * 35 / 100)
            left -= est(summary)
            let notes = fit(b.notes, left * 20 / 100)
            left -= est(notes)
            let transcript = fitTranscript(b.lines, keywords: keywords, budget: left)
            out += render((b.header, summary, notes, b.lines), transcript: transcript) + "\n"
        }
        return out
    }

    /// Splits `budget` between items that need `costs`: an item needing less than an even share gets what it
    /// needs, and the rest is shared again among the others.
    static func fairShares(_ costs: [Int], budget: Int) -> [Int] {
        var shares = Array(repeating: 0, count: costs.count)
        var open = Array(costs.indices), left = max(0, budget)
        while !open.isEmpty {
            let each = left / open.count
            let fits = open.filter { costs[$0] <= each }
            if fits.isEmpty {
                for i in open { shares[i] = each }
                break
            }
            for i in fits { shares[i] = costs[i]; left -= costs[i] }
            open.removeAll { fits.contains($0) }
        }
        return shares
    }

    /// A transcript within `budget` tokens: all of it when it fits; otherwise how it began and ended plus the
    /// lines around the keywords (most matches first), in timeline order with "…" for the gaps.
    static func fitTranscript(_ lines: [String], keywords: [String], budget: Int) -> String {
        let est = MeetingSummarizer.estimateTokens
        let all = lines.joined(separator: "\n")
        if est(all) <= budget { return all }
        guard budget >= 40 else { return "" }
        let pieces = lines.flatMap { splitLine($0, maxTokens: min(maxLineTokens, max(20, budget / 6))) }
        let costs = pieces.map { est($0) + 1 }
        let lower = pieces.map { $0.lowercased() }
        let hitCounts = lower.map { l in keywords.reduce(0) { $0 + (l.contains($1) ? 1 : 0) } }
        let hasHits = hitCounts.contains { $0 > 0 }

        var keep = IndexSet(), used = 0
        func take(_ i: Int, limit: Int) -> Bool {
            guard pieces.indices.contains(i), !keep.contains(i) else { return true }
            guard used + costs[i] <= limit else { return false }
            keep.insert(i); used += costs[i]
            return true
        }
        // The beginning and the end: what the meeting was about and where it ended up.
        let edge = hasHits ? budget / 5 : budget / 2
        var i = 0
        while i < pieces.count, take(i, limit: edge) { i += 1 }
        var j = pieces.count - 1, tailStart = used
        while j > i, used - tailStart + costs[j] <= edge, take(j, limit: budget) { j -= 1 }
        // Then the lines that mention the question's keywords, with a line of context on each side.
        let hits = pieces.indices.filter { hitCounts[$0] > 0 }.sorted { (hitCounts[$0], -$0) > (hitCounts[$1], -$1) }
        for h in hits {
            guard take(h, limit: budget) else { continue }
            _ = take(h - 1, limit: budget)
            _ = take(h + 1, limit: budget)
        }
        // Room left: more context around the matches, then more of the beginning and the end.
        for radius in 2...3 {
            for h in hits where keep.contains(h) {
                _ = take(h - radius, limit: budget)
                _ = take(h + radius, limit: budget)
            }
        }
        var head = i, tail = j
        while head <= tail {
            let grewHead = take(head, limit: budget)
            let grewTail = head < tail && take(tail, limit: budget)
            guard grewHead || grewTail else { break }
            if grewHead { head += 1 }
            if grewTail { tail -= 1 }
        }
        var out: [String] = []
        var last = -1
        for k in keep {
            if k != last + 1 { out.append("…") }
            out.append(pieces[k]); last = k
        }
        if last < pieces.count - 1 { out.append("…") }
        return out.joined(separator: "\n")
    }

    /// Splits a long "Speaker: …" line into pieces of at most `maxTokens`, each with the label: between words,
    /// or between clauses or characters in text without spaces (`MeetingSummarizer.cutIndex`).
    static func splitLine(_ line: String, maxTokens: Int) -> [String] {
        let est = MeetingSummarizer.estimateTokens
        guard est(line) > maxTokens else { return [line] }
        var label = "", text = line
        if let colon = line.firstIndex(of: ":"), line.distance(from: line.startIndex, to: colon) <= 40 {
            label = String(line[...colon]) + " "
            text = String(line[line.index(after: colon)...])
        }
        return MeetingSummarizer.pieces(text, maxTokens: max(1, maxTokens - est(label))).map { label + $0 }
    }

    /// Answers a question within the generator's context window.
    public static func answer(question: String, history: [Turn], sources: [AskSource], userName: String?,
                              generator: TextGenerator) async throws -> String {
        let context = generator.contextTokens
        let msgs = messages(question: question, history: history, sources: sources, userName: userName, contextTokens: context)
        let out = try await generator.generate(msgs, options: GenerationOptions(maxTokens: replyTokens(contextTokens: context),
                                                                                temperature: 0.2))
        return out.strippingThinking().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
