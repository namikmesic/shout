import Foundation
import ShoutLLM

// MARK: - Public types

/// Everything the summarizer needs about one meeting, captured as a value.
public struct MeetingSummaryInput: Sendable {
    /// May be empty.
    public var title: String
    public var date: Date
    /// Calendar attendee names, if known.
    public var participants: [String]
    /// The user's name, if set. "You" in the transcript is this person.
    public var userName: String?
    /// The user's own notes taken during the meeting (may be empty).
    public var notes: String
    /// Timeline order. Markers, latched (echo) lines and empty lines are ignored; `displayText` is used.
    public var segments: [MeetingSegment]

    public init(title: String = "", date: Date = Date(), participants: [String] = [], userName: String? = nil,
                notes: String = "", segments: [MeetingSegment]) {
        self.title = title; self.date = date; self.participants = participants; self.userName = userName
        self.notes = notes; self.segments = segments
    }
}

public struct MeetingActionItem: Sendable, Equatable {
    /// A person's name, "You"/the user's name, "Others" or "Team"; nil when the bullet names nobody.
    public var owner: String?
    public var text: String
    public init(owner: String? = nil, text: String) { self.owner = owner; self.text = text }
}

public struct MeetingSummary: Sendable, Equatable {
    public enum Outcome: String, Sendable { case summary, tooShort, noSpeech }
    public var outcome: Outcome
    /// The full Markdown summary (empty for `tooShort` / `noSpeech`).
    public var markdown: String
    /// The first paragraph, for list previews.
    public var overview: String
    /// Suggested 3–6 word title (nil when not requested or not usable).
    public var title: String?
    /// Parsed from the Next steps section.
    public var actionItems: [MeetingActionItem]

    public init(outcome: Outcome, markdown: String = "", overview: String = "", title: String? = nil,
                actionItems: [MeetingActionItem] = []) {
        self.outcome = outcome; self.markdown = markdown; self.overview = overview; self.title = title
        self.actionItems = actionItems
    }
}

public enum MeetingSummaryStage: Sendable, Equatable {
    /// Taking notes on part `part` of a long transcript (map step).
    case reading(part: Int, of: Int)
    /// Writing the final summary.
    case writing
    /// Writing the title.
    case titling
}

public enum MeetingSummaryError: LocalizedError, Equatable {
    case emptyOutput
    case echoedTranscript
    case contextTooSmall(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyOutput: return "The language model returned an empty summary."
        case .echoedTranscript: return "The language model repeated the transcript instead of summarizing it."
        case .contextTooSmall(let n): return "The language model's context (\(n) tokens) is too small to summarize this meeting."
        }
    }
}

// MARK: - Summarizer

/// Writes a meeting summary with the local language model.
///
/// Short transcripts are summarized in one call. Transcripts that do not fit the context are split on turn
/// boundaries into parts; each part is condensed into compact notes (map), and the summary is written from the
/// notes (reduce). Every prompt is kept inside `contextTokens` with room for the reply.
///
/// All calls run as background generations, so dictation preempts them: `TextGeneratorError.preempted` is
/// passed through to the caller (retry later), and so are cancellation and other generator errors.
public enum MeetingSummarizer {

    // MARK: Tunables

    /// Fewer substantive words than this: "no meaningful audio".
    static let noSpeechWords = 5
    /// Fewer than this: "too short to summarize".
    static let tooShortWords = 60
    static let finalMaxTokens = 1000
    static let partMaxTokens = 640
    static let titleMaxTokens = 24
    /// Chat-template tokens and estimation error.
    static let reserveTokens = 320
    /// Preferred size of one map part (about 10–12 minutes of conversation).
    static let preferredPartTokens = 3000
    static let maxUserNotesTokens = 1200
    /// Conservative: Qwen-style tokenizers average about 4.2 characters per English token.
    static let charsPerToken = 3.5

    // MARK: Entry point

    /// `allowShort` ("Summarize Anyway" only) skips the too-short check; a meeting without speech is still not
    /// summarized. Generate, Update and Try Again keep the check, so a short meeting gets the too-short note
    /// rather than a padded summary.
    public static func summarize(_ input: MeetingSummaryInput, generator: TextGenerator, wantTitle: Bool,
                                 contextTokens: Int = 8192, allowShort: Bool = false,
                                 progress: (@Sendable (MeetingSummaryStage) -> Void)? = nil) async throws -> MeetingSummary {
        let speakers = Speakers(userName: input.userName)
        let allTurns = turns(from: input.segments, userLabel: speakers.user)
        let words = substantiveWordCount(allTurns)
        if words < noSpeechWords { return MeetingSummary(outcome: .noSpeech) }
        if words < tooShortWords && !allowShort { return MeetingSummary(outcome: .tooShort) }

        let transcript = render(allTurns)
        let echo = EchoGuard(transcript: transcript, labels: Set(allTurns.map(\.speaker)).union(["You", "Others", speakers.user]))
        let system = systemPrompt(speakers)
        let header = meetingBlock(input, speakers: speakers)
            + userNotesBlock(input.notes, maxTokens: min(maxUserNotesTokens, contextTokens / 6))

        // One pass when the whole transcript fits; otherwise notes on each part first (map), then the summary (reduce).
        let longestTask = MeetingKind.allCases.map { estimateTokens(summaryTask($0, speakers, fromPartNotes: true)) }.max() ?? 0
        let fixed = estimateTokens(system) + estimateTokens(header) + longestTask + finalMaxTokens + reserveTokens
        let material: String
        if estimateTokens(transcript) + 10 <= contextTokens - fixed {
            material = "<transcript>\n\(transcript)\n</transcript>"
        } else {
            let notes = try await readInParts(allTurns, system: system, header: header, room: contextTokens - fixed - 10,
                                              speakers: speakers, generator: generator, echo: echo,
                                              contextTokens: contextTokens, progress: progress)
            material = "<part_notes>\n\(notes)\n</part_notes>"
        }
        let fromNotes = material.hasPrefix("<part_notes>")
        let prefix = header + material + "\n\n"

        try Task.checkCancellation()
        progress?(.writing)
        // Both calls share the long prefix, so the second one reuses the first one's KV cache.
        let kind = try await classify(title: input.title, participants: input.participants.count, system: system,
                                      prefix: prefix, generator: generator)
        let headings = kind.sections.map(\.0) + ["Next steps"]
        var markdown = try await generateChecked(
            [.init(.system, system), .init(.user, prefix + summaryTask(kind, speakers, fromPartNotes: fromNotes))],
            generator: generator, maxTokens: finalMaxTokens,
            clean: { normalizeSummary(restoringHeadings(stripWrapping($0), headings: headings)) },
            check: { checkSummary($0, echo: echo) })
        if let other = soleOtherParticipant(input.participants.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                            speakers: speakers) {
            markdown = renamingOwner("Others", to: other, in: markdown)
        }

        var title: String?
        if wantTitle {
            try Task.checkCancellation()
            progress?(.titling)
            do { title = try await makeTitle(summary: markdown, generator: generator) }
            catch is CancellationError { throw CancellationError() }
            catch { title = nil } // a missing title is not worth failing the summary for
        }
        return MeetingSummary(outcome: .summary, markdown: markdown, overview: overview(of: markdown), title: title,
                              actionItems: actionItems(in: markdown))
    }

    /// The same as `allowShort:`, for callers that still say `force:`.
    public static func summarize(_ input: MeetingSummaryInput, generator: TextGenerator, wantTitle: Bool,
                                 contextTokens: Int = 8192, force: Bool,
                                 progress: (@Sendable (MeetingSummaryStage) -> Void)? = nil) async throws -> MeetingSummary {
        try await summarize(input, generator: generator, wantTitle: wantTitle, contextTokens: contextTokens,
                            allowShort: force, progress: progress)
    }

    /// "Your summary is ready!" notification text for a meeting (post it once per summary: see
    /// `Store.claimSummaryReadyNotification`).
    public static func readyNotification(meetingTitle: String) -> (title: String, body: String, action: String) {
        let t = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return ("Your summary is ready!", t.isEmpty ? "Synthesized your notes" : "From \(t)", "View summary")
    }

    // MARK: Meeting kind

    /// Picks the two topic headings. Small models write better sections when they are told the headings.
    enum MeetingKind: String, CaseIterable {
        case standup, planning = "group", oneOnOne = "one-on-one", customer, interview, talk, brainstorm, other

        var label: String {
            switch self {
            case .standup: return "Stand-up: a short round where each person gives a status update"
            case .planning: return "Group meeting of three or more people that plans, reviews or decides things"
            case .oneOnOne: return "One-on-one: only two people talking, such as a manager and their report, or a mentor"
            case .customer: return "Sales, customer or partner call with someone from another company"
            case .interview: return "Job interview of a candidate"
            case .talk: return "Talk, lecture, class or presentation by mostly one speaker"
            case .brainstorm: return "Brainstorm or workshop generating ideas"
            case .other: return "Something else"
            }
        }

        /// A kind named in the meeting title ("Weekly stand-up", "Dana / Chris 1:1", "Interview: …").
        static func fromTitle(_ title: String) -> MeetingKind? {
            let t = " " + title.lowercased() + " "
            let table: [(MeetingKind, [String])] = [
                (.oneOnOne, [" 1:1", "1-1 ", " 1on1", "one-on-one", "one on one", " 1:1 "]),
                (.standup, ["standup", "stand-up", "stand up", "daily sync", "daily scrum"]),
                (.interview, ["interview"]),
                (.brainstorm, ["brainstorm", "workshop", "ideation"]),
                (.talk, ["lecture", "webinar", " class ", "talk:", "keynote", "seminar"]),
            ]
            return table.first { _, keys in keys.contains { t.contains($0) } }?.0
        }

        /// The two topic sections: heading and what goes under it.
        var sections: [(String, String)] {
            switch self {
            case .standup: return [("Updates", "what each person finished, is working on or reported"),
                                   ("Blockers", "what is stuck, at risk or waiting on someone, and why (if nothing, one bullet saying so)")]
            case .planning: return [("Decisions", "what was agreed, with the key numbers, dates and reasons"),
                                    ("Open questions", "issues, risks and questions that are still unresolved")]
            case .oneOnOne: return [("Updates", "work, progress and news that was discussed"),
                                    ("Feedback", "feedback, concerns, growth and career topics raised by either side")]
            case .customer: return [("Customer needs", "what the customer wants, their situation, numbers and timeline"),
                                    ("Concerns", "objections, risks and open questions")]
            case .interview: return [("Background", "the candidate's experience and current situation"),
                                     ("Candidate answers", "how the candidate answered the main questions")]
            case .talk: return [("Key points", "the main ideas presented"),
                                ("Questions", "questions raised and the answers given")]
            case .brainstorm: return [("Ideas", "the main ideas and options discussed"),
                                      ("Open questions", "what is still undecided or needs research")]
            case .other: return [("Key points", "the main things discussed and agreed"),
                                 ("Open questions", "what is still unresolved")]
            }
        }
    }

    static func classify(title: String, participants: Int, system: String, prefix: String,
                         generator: TextGenerator) async throws -> MeetingKind {
        if let kind = MeetingKind.fromTitle(title) { return kind }
        let options = MeetingKind.allCases.map { "- \($0.rawValue): \($0.label)" }.joined(separator: "\n")
        let invited = participants > 0 ? " \(participants) people were invited." : ""
        let task = """
        <task>
        What kind of meeting is this?\(invited) Reply with exactly one word from this list and nothing else:
        \(options)
        </task>
        """
        let raw = try await generator.generate([.init(.system, system), .init(.user, prefix + task)],
                                               options: .init(maxTokens: 6, temperature: 0, background: true))
        let answer = raw.strippingThinking().lowercased().trimmingCharacters(in: CharacterSet.letters.inverted)
        return MeetingKind.allCases.first { answer.hasPrefix($0.rawValue) }
            ?? (answer.hasPrefix("one") ? .oneOnOne : answer.hasPrefix("stand") ? .standup : .other)
    }

    // MARK: Map step

    /// Notes on one part (or, after merging, a run of parts) of a long meeting.
    struct PartNotes: Equatable {
        var first: Int, last: Int, count: Int
        var start: String, end: String
        var text: String
        var rendered: String {
            let n = first == last ? "\(first)" : "\(first)-\(last)"
            return "<part n=\"\(n)\" of=\"\(count)\" time=\"\(start)–\(end)\">\n\(text)\n</part>"
        }
    }

    /// Splits the transcript into parts, takes notes on each and returns them joined, fitted to `room` tokens.
    static func readInParts(_ turns: [Turn], system: String, header: String, room: Int, speakers: Speakers,
                            generator: TextGenerator, echo: EchoGuard, contextTokens: Int,
                            progress: (@Sendable (MeetingSummaryStage) -> Void)?) async throws -> String {
        let partBudget = min(preferredPartTokens, contextTokens - partMaxTokens - reserveTokens - estimateTokens(system)
                             - estimateTokens(header) - estimateTokens(partTask(speakers, wordLimit: 999)) - 40)
        guard partBudget >= 300, room >= 400 else { throw MeetingSummaryError.contextTooSmall(contextTokens) }

        let parts = chunk(turns, budget: partBudget)
        // Share the room in the final prompt between the parts (about 6.5 characters per word).
        let wordLimit = max(80, min(250, Int(Double(room) * charsPerToken / 6.5) / max(1, parts.count)))
        let task = partTask(speakers, wordLimit: wordLimit)
        let maxTokens = min(partMaxTokens, wordLimit * 5 / 2)

        var notes: [PartNotes] = []
        var failure: Error = MeetingSummaryError.emptyOutput
        var failed = 0
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            progress?(.reading(part: i + 1, of: parts.count))
            let user = header + "<transcript part=\"\(i + 1) of \(parts.count)\">\n\(render(part))\n</transcript>\n\n" + task
            do {
                let text = try await generateChecked([.init(.system, system), .init(.user, user)], generator: generator,
                                                     maxTokens: maxTokens, clean: { stripWrapping($0) },
                                                     check: { checkPartNotes($0, echo: echo) })
                notes.append(PartNotes(first: i + 1, last: i + 1, count: parts.count,
                                       start: formatTimestamp(ms: part.first?.startMs ?? 0),
                                       end: formatTimestamp(ms: part.last?.endMs ?? 0), text: text))
            } catch let e as MeetingSummaryError {
                failure = e // one unreadable part should not sink the whole summary…
                // An empty reply is a quiet part (the task says to leave out empty headings), not an unreadable one.
                if e != .emptyOutput { failed += 1 }
            }
        }
        // …but a summary of a minority of the readable parts would pass for the whole meeting.
        guard !notes.isEmpty, failed * 2 <= parts.count else { throw failure }
        return try await fitNotes(notes, room: room, system: system, speakers: speakers, wordLimit: wordLimit,
                                  generator: generator, contextTokens: contextTokens)
    }

    /// Merges neighbouring part notes until they fit `room` (only needed for very long meetings).
    static func fitNotes(_ notes: [PartNotes], room: Int, system: String, speakers: Speakers, wordLimit: Int,
                         generator: TextGenerator, contextTokens: Int) async throws -> String {
        var notes = notes
        func joined() -> String { notes.map(\.rendered).joined(separator: "\n") }
        let task = mergeTask(speakers, wordLimit: wordLimit * 2)
        let groupRoom = contextTokens - partMaxTokens - reserveTokens - estimateTokens(system) - estimateTokens(task) - 40
        while estimateTokens(joined()) > room {
            var groups: [[PartNotes]] = [], current: [PartNotes] = [], size = 0
            for n in notes {
                let c = estimateTokens(n.rendered) + 1
                if !current.isEmpty && size + c > groupRoom { groups.append(current); current = []; size = 0 }
                current.append(n); size += c
            }
            if !current.isEmpty { groups.append(current) }
            if groups.count == notes.count {
                // Nothing can be merged any more: keep as much of each part as fits.
                let each = max(50, room / max(1, notes.count) - 30)
                for i in notes.indices { notes[i].text = truncate(notes[i].text, toTokens: each) }
                // At the 50-token floor there are too many parts for this context.
                guard estimateTokens(joined()) <= room else { throw MeetingSummaryError.contextTooSmall(contextTokens) }
                break
            }
            var merged: [PartNotes] = []
            for g in groups {
                try Task.checkCancellation()
                guard g.count > 1, let a = g.first, let b = g.last else { merged += g; continue }
                let user = "<part_notes>\n" + g.map(\.rendered).joined(separator: "\n") + "\n</part_notes>\n\n" + task
                let text = try await generateChecked([.init(.system, system), .init(.user, user)],
                                                     generator: generator, maxTokens: partMaxTokens,
                                                     clean: { stripWrapping($0) },
                                                     check: { words($0).isEmpty ? .bad(.emptyOutput) : .good })
                merged.append(PartNotes(first: a.first, last: b.last, count: a.count, start: a.start, end: b.end, text: text))
            }
            notes = merged
        }
        return joined()
    }

    // MARK: Title

    static let titleSystem = """
    You name meetings for a note-taking app. You receive the summary of a meeting. Reply with a title of 3 to 6 words, in Title Case, that says what the meeting was about. Prefer the specific subject (a project, product, customer or decision) over generic words like "Meeting", "Discussion" or "Summary". No quotes, no date, no trailing punctuation. Output only the title.
    """

    static func makeTitle(summary: String, generator: TextGenerator) async throws -> String? {
        try await askTitle([.init(.system, titleSystem), .init(.user, "<summary>\n\(summary)\n</summary>")], generator: generator)
    }

    static func askTitle(_ messages: [ChatMessage], generator: TextGenerator) async throws -> String? {
        for temperature: Float in [0, 0.2] {
            try Task.checkCancellation()
            let raw = try await generator.generate(messages, options: .init(maxTokens: titleMaxTokens, temperature: temperature,
                                                                                       background: true))
            if let t = cleanTitle(raw) { return t }
        }
        return nil
    }

    static let transcriptTitleSystem = """
    You name meetings for a note-taking app. You receive what was said in a meeting (from speech recognition, so some words may be misheard) and sometimes the user's own notes. Reply with a title of 3 to 6 words, in Title Case, that says what the meeting was about. Prefer the specific subject (a project, product, customer or decision) over generic words like "Meeting", "Call", "Sync" or "Discussion". Ignore greetings and small talk. No quotes, no date, no trailing punctuation. Output only the title.
    """
    static let maxTitleNotesTokens = 400
    /// Enough of a transcript to name it; keeps a title quick even with a large context.
    static let maxTitleTranscriptTokens = 2500

    /// Whether there is anything to name the meeting by: some speech, or the user's notes.
    public static func canTitle(_ input: MeetingSummaryInput) -> Bool {
        !input.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || substantiveWordCount(turns(from: input.segments, userLabel: "You")) > 0
    }

    /// A 3–6 word title from what was said (first) and the user's notes, independently of the summary, so a
    /// meeting gets one at every stop whatever its length. A long transcript is sampled from its beginning,
    /// middle and end. Nil when there is nothing to name it by or the answer is unusable.
    public static func title(for input: MeetingSummaryInput, generator: TextGenerator,
                             contextTokens: Int = 8192) async throws -> String? {
        guard canTitle(input) else { return nil }
        let speakers = Speakers(userName: input.userName)
        let notes = userNotesBlock(input.notes, maxTokens: min(maxTitleNotesTokens, contextTokens / 10))
        let room = min(maxTitleTranscriptTokens, contextTokens - titleMaxTokens - reserveTokens
                       - estimateTokens(transcriptTitleSystem) - estimateTokens(notes) - 20)
        let all = turns(from: input.segments, userLabel: speakers.user)
        let transcript = all.isEmpty || room < 100 ? "" : "<transcript>\n\(spread(all, budget: room))\n</transcript>\n"
        return try await askTitle([.init(.system, transcriptTitleSystem), .init(.user, notes + transcript)], generator: generator)
    }

    /// The transcript cut to about `budget` tokens: all of it when it fits, else `runs` runs of turns spread
    /// evenly from the beginning to the end, separated by "…".
    static func spread(_ turns: [Turn], budget: Int, runs: Int = 4) -> String {
        let all = render(turns)
        guard estimateTokens(all) > budget, !turns.isEmpty, runs > 1 else { return all }
        let each = max(20, budget / runs)
        // The turns of one run: forward from `start`, or (the last run) back from the end, staying after `floor`.
        func run(from start: Int, floor: Int, backwards: Bool) -> [Int] {
            var picked: [Int] = [], used = 0
            var i = backwards ? turns.count - 1 : start
            while backwards ? i >= floor : i < turns.count {
                let cost = estimateTokens(truncate(turns[i].line, toTokens: each)) + 1
                if !picked.isEmpty && used + cost > each { break }
                picked.append(i); used += cost
                i += backwards ? -1 : 1
            }
            return backwards ? picked.reversed() : picked
        }
        var out: [String] = []
        var next = 0
        for r in 0..<runs {
            let picked = run(from: max(next, (turns.count - 1) * r / (runs - 1)), floor: next, backwards: r == runs - 1)
            guard let first = picked.first, let end = picked.last else { continue }
            if first > next { out.append("…") } // a gap
            out += picked.map { truncate(turns[$0].line, toTokens: each) }
            next = end + 1
        }
        if next < turns.count { out.append("…") }
        return out.joined(separator: "\n")
    }

    // MARK: Prompts
    //
    // Every call is [system, user] where the user turn is <meeting>, <user_notes>, the material (<transcript> or
    // <part_notes>) and finally a <task>. The system prompt and the material are shared between calls, so
    // llama.cpp reuses their KV cache, and the instructions sit right before the answer, where small models
    // follow them best.

    struct Speakers {
        /// Transcript label for the user: their name, or "You".
        let user: String
        let named: Bool
        init(userName: String?) {
            let n = (userName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ":", with: "")
            named = !n.isEmpty && n.lowercased() != "you" && n.lowercased() != "others"
            user = named ? n : "You"
        }
    }

    static func systemPrompt(_ s: Speakers) -> String {
        let userLine = s.named
            ? "Lines starting with \"\(s.user):\" are the user, \(s.user), recorded from their own microphone."
            : "Lines starting with \"You:\" are the user, recorded from their own microphone."
        return """
        You are the note-taker of a meeting notes app that runs on the user's Mac. You read what was said in a meeting and then do the task at the end of the message, exactly as it asks.

        Transcripts come from speech recognition, so expect some misheard words. There is one line per turn:
        - \(userLine)
        - Lines starting with "Others:" are everyone else on the call, recorded together from the computer's audio. "Others" can be several different people. Name one of them only when the transcript makes clear who is speaking, for example when they are addressed by name just before, or introduce themselves.
        - Any other label is the name of one specific person.
        Someone who is only mentioned did not necessarily attend.

        Never invent names, numbers, dates, decisions or commitments. If something is unclear, leave it out. Write dates as they were said: do not add a month, weekday or year that nobody mentioned.
        """
    }

    static func ownerRule(_ s: Speakers) -> String {
        "The owner is the person who will do the task, not whoever asked for it or was mentioned in it: a name, \"\(s.user)\" for the user, \"Others\" when someone else on the call took it but their name is unclear, or \"Team\" for shared work."
    }

    static func summaryTask(_ kind: MeetingKind, _ s: Speakers, fromPartNotes: Bool) -> String {
        let source = fromPartNotes ? "Using the notes on each part of the meeting above" : "Using the transcript above"
        let sections = kind.sections.map { "- a \"## \($0.0)\" line, then 1 to 5 bullets: \($0.1)." }.joined(separator: "\n")
        return """
        <task>
        \(source), write a summary of the meeting in Markdown, in English, for someone who missed it.

        Start with an overview paragraph of 2 to 4 sentences (under 80 words) and no heading: what the meeting was about, the main outcomes and what happens next. Begin with the substance (who agreed, decided or reported what), not with "The meeting" or "In this meeting".

        Then write exactly three sections, in this order, each starting with its heading line written exactly as shown:
        \(sections)
        - a "## Next steps" line, then one bullet per task, written as "- **Owner** — the task, with its deadline if one was given".

        For Next steps: Go through the meeting from start to end and include every task someone took on ("I'll…", "I can…") or agreed to when asked ("can you…?"), including each of \(s.user)'s own commitments. \(ownerRule(s)) If nothing was agreed, write "- None".

        Rules:
        - Only include what was actually said. A section with little to say gets a single bullet; never pad it with guesses.
        - Be brief and specific. Keep names, numbers, dates and decisions; drop greetings, small talk and repetition. Every bullet is one short sentence of at most 15 words.
        - Write dates exactly as they were said (for example "the 20th"); never add a month or year nobody mentioned.
        - Write in your own words; do not copy the transcript line by line.
        - If there are user notes, make sure their points are covered, but check them against the meeting.
        - Refer to the user as "\(s.user)".
        - Output only the summary: no title, no preamble, no closing remarks.
        </task>
        """
    }

    static func partTask(_ s: Speakers, wordLimit: Int) -> String {
        """
        <task>
        The transcript above is one part of a long meeting. Take notes on this part only; a later step combines the notes on every part into the summary. Write plain text under these headings, in this order, leaving out any heading that would have nothing under it:

        Decisions:
        - what was agreed, with the key numbers and dates
        Action items:
        - Owner — the task, with its deadline if one was given
        Key points:
        - other important facts, numbers, names and updates
        Open questions:
        - unresolved issues, risks and things still to be decided

        Rules:
        - \(ownerRule(s)) Use a name only when the transcript shows that this person said they would do it, or agreed when asked by name; otherwise use "Others".
        - One short line per bullet, and no more than about \(wordLimit) words in total. Do not repeat a point under two headings.
        - Output only the notes: no preamble, no closing remarks.
        </task>
        """
    }

    static func mergeTask(_ s: Speakers, wordLimit: Int) -> String {
        """
        <task>
        Merge the notes above, taken on consecutive parts of one meeting, into a single set of notes with the same headings (Decisions, Action items, Key points, Open questions). Keep every decision, every action item with its owner, and the key names, numbers and dates; merge duplicates and drop minor details. "\(s.user)" is the user. No more than about \(wordLimit) words. Output only the notes.
        </task>
        """
    }

    static func meetingBlock(_ input: MeetingSummaryInput, speakers: Speakers) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMMM d, yyyy"
        var lines: [String] = []
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { lines.append("Title: \(title)") }
        lines.append("Date: \(df.string(from: input.date))")
        let people = input.participants.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !people.isEmpty { lines.append("Invited: \(people.prefix(30).joined(separator: ", ")) (use these spellings for their names)") }
        lines.append(speakers.named ? "The user: \(speakers.user) (their lines are labelled \"\(speakers.user):\")"
                                    : "The user: labelled \"You:\" (name unknown)")
        if let other = soleOtherParticipant(people, speakers: speakers) {
            lines.append("\"Others\" in this meeting is \(other), the only other person invited: call them \(other), not \"Others\".")
        }
        return "<meeting>\n\(lines.joined(separator: "\n"))\n</meeting>\n"
    }

    /// The one invitee who is not the user, when the invite has exactly one such person (a 1:1).
    static func soleOtherParticipant(_ people: [String], speakers: Speakers) -> String? {
        guard speakers.named else { return people.count == 1 ? people[0] : nil }
        let user = speakers.user.lowercased()
        let userFirst = user.split(separator: " ").first.map(String.init) ?? user
        let others = people.filter { p in
            let l = p.lowercased()
            return l != user && l.split(separator: " ").first.map(String.init) != userFirst
        }
        return others.count == 1 ? others[0] : nil
    }

    /// Replaces an owner label in Next steps bullets ("- **Others** — …").
    static func renamingOwner(_ owner: String, to name: String, in markdown: String) -> String {
        var inSection = false
        return markdown.components(separatedBy: "\n").map { line in
            if line.hasPrefix("## ") { inSection = isNextStepsHeading(String(line.dropFirst(3))) }
            guard inSection, line.hasPrefix("- **\(owner)**") else { return line }
            return "- **\(name)**" + line.dropFirst("- **\(owner)**".count)
        }.joined(separator: "\n")
    }

    static func userNotesBlock(_ notes: String, maxTokens: Int) -> String {
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return "" }
        return "<user_notes>\n\(truncate(n, toTokens: maxTokens))\n</user_notes>\n"
    }

    // MARK: Transcript

    struct Turn: Equatable {
        var speaker: String
        var text: String
        var startMs: Int
        var endMs: Int
        var line: String { "\(speaker): \(text)" }
    }

    /// Whether consecutive "Others" segments are merged too. "Others" is the whole call audio, so consecutive
    /// segments are often different people; keeping them as separate lines lets the model see the turn changes
    /// (in the evaluation it attributed tasks to the wrong person noticeably more often when they were merged).
    static let mergeSharedChannel = false

    /// Speech lines in timeline order. Consecutive lines of the same speaker (the user, or a named speaker) are
    /// merged into one turn; "Others" lines are merged only when `mergeSharedChannel` is set.
    static func turns(from segments: [MeetingSegment], userLabel: String) -> [Turn] {
        let speech = segments.enumerated()
            .filter { _, s in s.source != .marker && s.marker == nil && !s.latched }
            .sorted { a, b in a.element.startMs != b.element.startMs ? a.element.startMs < b.element.startMs : a.offset < b.offset }
            .map(\.element)
        var out: [Turn] = []
        for s in speech {
            let text = s.displayText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            let label: String
            if let name = s.speaker?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                label = name.lowercased() == "you" ? userLabel : name
            } else {
                label = s.source == .mic ? userLabel : MeetingSource.system.speakerLabel
            }
            let shared = label == MeetingSource.system.speakerLabel
            if let last = out.last, last.speaker == label, !shared || mergeSharedChannel {
                out[out.count - 1].text += " " + text
                out[out.count - 1].endMs = max(last.endMs, s.endMs)
            } else {
                out.append(Turn(speaker: label, text: text, startMs: s.startMs, endMs: s.endMs))
            }
        }
        return out
    }

    static func render(_ turns: [Turn]) -> String { turns.map(\.line).joined(separator: "\n") }

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "erm", "er", "ah", "eh", "hmm", "hm", "mm", "mhm", "mm-hmm", "uh-huh"]

    static func substantiveWordCount(_ turns: [Turn]) -> Int {
        turns.reduce(0) { n, t in n + words(t.text).filter { !fillers.contains($0) }.count }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }.filter { !$0.isEmpty }
    }

    static func timeRange(_ part: [Turn]) -> String {
        guard let a = part.first, let b = part.last else { return "" }
        return "\(formatTimestamp(ms: a.startMs))–\(formatTimestamp(ms: b.endMs))"
    }

    // MARK: Token budget and chunking

    /// Conservative token estimate: ASCII at `charsPerToken`, every other character as a whole token.
    static func estimateTokens(_ s: String) -> Int {
        var ascii = 0, other = 0
        for u in s.unicodeScalars { if u.isASCII { ascii += 1 } else { other += 1 } }
        return Int((Double(ascii) / charsPerToken).rounded(.up)) + other
    }

    /// `s` cut to at most `n` tokens, "…" included, where `cutIndex` says (between words when it has spaces).
    static func truncate(_ s: String, toTokens n: Int) -> String {
        guard estimateTokens(s) > n else { return s }
        return s[..<cutIndex(Substring(s), maxTokens: n - 1)].trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Clause and sentence ends of scripts written without spaces (Chinese, Japanese): where such text is cut.
    static let unspacedBreaks: Set<Character> = ["。", "．", "！", "？", "、", "，", "；", "：", "｡", "､"]

    /// Where to cut `s` so the part before it fits `maxTokens`: its end when all of it fits; else after the
    /// last word or clause that fits (before a space, or after 。、！？ and the like); else, in text with
    /// neither (a long run of Chinese, Japanese or Thai, or one very long word), after the last character
    /// that fits. `s.startIndex` when not even one character fits.
    static func cutIndex(_ s: Substring, maxTokens: Int) -> String.Index {
        var ascii = 0, other = 0
        var fits = s.startIndex, boundary: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            for u in c.unicodeScalars { if u.isASCII { ascii += 1 } else { other += 1 } }
            guard Int((Double(ascii) / charsPerToken).rounded(.up)) + other <= maxTokens else { break }
            let next = s.index(after: i)
            if c.isWhitespace { boundary = i } else if unspacedBreaks.contains(c) { boundary = next }
            fits = next
            i = next
        }
        if fits == s.endIndex || s[fits].isWhitespace { return fits }
        if let boundary, boundary > s.startIndex { return boundary }
        return fits
    }

    /// `s` in pieces of at most `maxTokens`, cut where `cutIndex` says, without the spaces at the cuts.
    static func pieces(_ s: String, maxTokens: Int) -> [String] {
        var out: [String] = []
        var rest = Substring(s)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { return out }
            var cut = cutIndex(rest, maxTokens: maxTokens)
            if cut == rest.startIndex { cut = rest.index(after: cut) } // not even one character fits: never stall
            let piece = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { out.append(piece) }
            rest = rest[cut...]
        }
    }

    /// Splits turns into parts of at most `budget` estimated tokens, on turn boundaries where possible
    /// (a single turn longer than the budget is split between sentences). Parts come out roughly equal in size.
    static func chunk(_ turns: [Turn], budget: Int) -> [[Turn]] {
        let pieces = turns.flatMap { split($0, budget: budget) }
        let costs = pieces.map { estimateTokens($0.line) + 1 }
        let total = costs.reduce(0, +)
        guard total > budget else { return pieces.isEmpty ? [] : [pieces] }
        let largest = costs.max() ?? 0
        // Pack greedily towards an even share; if that needs more than `n` parts (the budget caps the share),
        // try again with one more part rather than leaving a tiny last part.
        var n = Int((Double(total) / Double(budget)).rounded(.up))
        while true {
            let target = min(budget, (total + n - 1) / n + largest)
            var chunks: [[Turn]] = [], current: [Turn] = [], size = 0
            for (p, c) in zip(pieces, costs) {
                if !current.isEmpty && size + c > target { chunks.append(current); current = []; size = 0 }
                current.append(p); size += c
            }
            if !current.isEmpty { chunks.append(current) }
            if chunks.count <= n || n >= pieces.count { return chunks }
            n += 1
        }
    }

    /// Splits one over-long turn between sentences (or words or characters, for run-on text) so each piece
    /// fits `budget`.
    static func split(_ turn: Turn, budget: Int) -> [Turn] {
        guard estimateTokens(turn.line) + 1 > budget else { return [turn] }
        let room = budget - estimateTokens(turn.speaker + ": ") - 2
        var sentences: [String] = []
        turn.text.enumerateSubstrings(in: turn.text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
        }
        var units: [String] = []
        for s in sentences {
            if estimateTokens(s) <= room { units.append(s) } else { units += pieces(s, maxTokens: room) }
        }
        var texts: [String] = [], cur = ""
        for u in units {
            // Sentences of unspaced scripts are joined as they were written.
            let next = cur.isEmpty ? u : cur + (cur.last.map(unspacedBreaks.contains) == true ? "" : " ") + u
            if estimateTokens(next) > room && !cur.isEmpty { texts.append(cur); cur = u } else { cur = next }
        }
        if !cur.isEmpty { texts.append(cur) }
        // Spread the turn's time span over the pieces by length.
        let totalChars = max(1, texts.reduce(0) { $0 + $1.count })
        var pos = 0
        return texts.map { t in
            let span = turn.endMs - turn.startMs
            let start = turn.startMs + span * pos / totalChars
            pos += t.count
            return Turn(speaker: turn.speaker, text: t, startMs: start, endMs: turn.startMs + span * pos / totalChars)
        }
    }

    // MARK: Generation with checks

    enum Check: Equatable { case good, weak, bad(MeetingSummaryError) }

    /// Generates, cleans and checks; retries once at temperature 0.2. A weak (badly formatted) result is used
    /// when nothing better comes back; a bad one (empty, echoed transcript) throws.
    static func generateChecked(_ messages: [ChatMessage], generator: TextGenerator, maxTokens: Int,
                                clean: (String) -> String, check: (String) -> Check) async throws -> String {
        var fallback: String?
        var failure = MeetingSummaryError.emptyOutput
        for temperature: Float in [0, 0.2] {
            try Task.checkCancellation()
            let raw = try await generator.generate(messages, options: .init(maxTokens: maxTokens, temperature: temperature,
                                                                                       background: true))
            let text = clean(raw)
            switch check(text) {
            case .good: return text
            case .weak: if fallback == nil { fallback = text }
            case .bad(let e): failure = e
            }
        }
        if let fallback { return fallback }
        throw failure
    }

    static func checkSummary(_ md: String, echo: EchoGuard) -> Check {
        if words(md).count < 15 { return .bad(.emptyOutput) }
        if echo.isEcho(md, overlap: 0.5) { return .bad(.echoedTranscript) }
        let lines = md.components(separatedBy: "\n")
        let sections = lines.filter { $0.hasPrefix("## ") }.map { String($0.dropFirst(3)) }
        let topics = sections.filter { !isNextStepsHeading($0) }
        if overview(of: md).isEmpty || topics.count < 2 || topics.count == sections.count { return .weak }
        return .good
    }

    static func checkPartNotes(_ text: String, echo: EchoGuard) -> Check {
        if words(text).isEmpty { return .bad(.emptyOutput) }
        // Notes may legitimately reuse phrases from the transcript, so only near-copies count.
        if echo.isEcho(text, overlap: 0.8) { return .bad(.echoedTranscript) }
        return .good
    }

    /// Detects a model that wrote the transcript back out instead of summarizing it.
    struct EchoGuard {
        let grams: Set<String>
        let labels: Set<String>
        static let n = 6

        init(transcript: String, labels: Set<String>) {
            grams = Self.ngrams(MeetingSummarizer.words(transcript))
            self.labels = Set(labels.map { $0.lowercased() })
        }

        static func ngrams(_ w: [String]) -> Set<String> {
            guard w.count >= n else { return [] }
            return Set((0...(w.count - n)).map { w[$0..<($0 + n)].joined(separator: " ") })
        }

        /// True when most lines are transcript turns ("Others: …") or more than `overlap` of the text's
        /// 6-word sequences appear verbatim in the transcript.
        func isEcho(_ text: String, overlap: Double) -> Bool {
            let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let labelled = lines.filter { line in
                guard let colon = line.firstIndex(of: ":") else { return false }
                return labels.contains(line[..<colon].lowercased())
            }
            if labelled.count >= 4 && labelled.count * 2 >= lines.count { return true }
            let w = MeetingSummarizer.words(text)
            guard w.count >= 40 else { return false }
            var hits = 0, total = 0
            for i in 0...(w.count - Self.n) {
                total += 1
                if grams.contains(w[i..<(i + Self.n)].joined(separator: " ")) { hits += 1 }
            }
            return Double(hits) / Double(total) > overlap
        }
    }

    // MARK: Output cleanup

    /// Removes reasoning blocks, code fences, preambles ("Here is the summary:") and sign-offs.
    static func stripWrapping(_ raw: String) -> String {
        var lines = raw.strippingThinking().replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        func trimBlankEnds() {
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        }
        trimBlankEnds()
        while let first = lines.first, isPreamble(first) { lines.removeFirst(); trimBlankEnds() }
        while let last = lines.last, isSignOff(last) { lines.removeLast(); trimBlankEnds() }
        return lines.joined(separator: "\n")
    }

    static func isPreamble(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        let l = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*_#: "))
        let starts = ["here is", "here's", "here are", "sure", "certainly", "of course", "okay,", "ok,", "below is",
                      "below are", "the following is", "i've summarized", "i have summarized"]
        if starts.contains(where: { l.hasPrefix($0) }) && (t.hasSuffix(":") || words(l).count <= 25) { return true }
        return ["summary", "meeting summary", "summary of the meeting", "meeting notes", "notes"].contains(l)
    }

    static func isSignOff(_ line: String) -> Bool {
        let l = line.trimmingCharacters(in: .whitespaces).lowercased()
        return ["let me know", "i hope", "hope this", "feel free", "if you need", "if you'd like", "would you like"]
            .contains { l.hasPrefix($0) }
    }

    /// Normalizes the summary Markdown: `##` section headings (from `#`, `**Bold**` or `Label:` lines),
    /// "- " bullets, a canonical "## Next steps", no leading title or "Overview" heading, no repeated bullets.
    static func normalizeSummary(_ text: String) -> String {
        var out: [String] = []
        var seenBullets = Set<String>()
        var inNextSteps = false
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { out.append(""); continue }
            // Inside Next steps, "### Priya" / "**Priya**" lines group items by owner and stay as they are.
            if let (level, h) = heading(t), !(inNextSteps && (level >= 3 || !t.hasPrefix("#"))) {
                inNextSteps = isNextStepsHeading(h)
                if level == 1 && out.allSatisfy({ $0.isEmpty }) { out.append("# \(h)"); continue } // dropped below
                out.append("## \(inNextSteps ? "Next steps" : h)")
                continue
            }
            if let (indent, body) = bullet(raw) {
                let key = body.lowercased()
                if indent == 0 && seenBullets.contains(key) { continue }
                if indent == 0 { seenBullets.insert(key) }
                out.append((indent > 0 ? "  " : "") + "- " + body)
                continue
            }
            out.append(t)
        }
        // Drop a leading title ("# …") or an "Overview"/"Summary" heading above the first paragraph.
        while let i = out.firstIndex(where: { !$0.isEmpty }) {
            let line = out[i]
            let isTitle = line.hasPrefix("# ")
            let isOverviewHeading = line.hasPrefix("## ") && overviewHeadings.contains(
                line.dropFirst(3).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": ")))
            guard isTitle || isOverviewHeading else { break }
            out.removeSubrange(0...i)
        }
        // Blank line before each heading, none right after one or between bullets, never two in a row.
        var tidy: [String] = []
        for (i, line) in out.enumerated() {
            if line.isEmpty {
                guard let prev = tidy.last, !prev.isEmpty, !prev.hasPrefix("#") else { continue }
                let next = out[(i + 1)...].first { !$0.isEmpty }
                if let next, isBulletLine(prev), isBulletLine(next) { continue }
                if next == nil { continue }
                tidy.append("")
            } else {
                if line.hasPrefix("#"), let prev = tidy.last, !prev.isEmpty { tidy.append("") }
                tidy.append(line)
            }
        }
        return tidy.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Small models sometimes write the right sections but leave out the heading lines. When the text has no
    /// headings at all, puts the expected ones back: one per blank-line-separated bullet group when the counts
    /// match, otherwise owner bullets ("- **Name** — …") under the last heading and the rest under the first.
    static func restoringHeadings(_ text: String, headings: [String]) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let last = headings.last, !headings.isEmpty,
              !lines.contains(where: { heading($0.trimmingCharacters(in: .whitespaces)) != nil }) else { return text }
        // Blocks separated by blank lines; a block is a bullet group when it starts with a bullet.
        var blocks: [[String]] = [], current: [String] = []
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces).isEmpty { if !current.isEmpty { blocks.append(current); current = [] } }
            else { current.append(l) }
        }
        if !current.isEmpty { blocks.append(current) }
        let groups = blocks.indices.filter { isBulletLine(blocks[$0][0]) }
        guard !groups.isEmpty else { return text }
        var out: [String] = []
        if groups.count == headings.count {
            for (i, block) in blocks.enumerated() {
                if let n = groups.firstIndex(of: i) { out.append("## \(headings[n])") }
                out += block; out.append("")
            }
            return out.joined(separator: "\n")
        }
        let isOwnerBullet: (String) -> Bool = { line in
            guard let (indent, body) = bullet(line), indent == 0 else { return false }
            return body.hasPrefix("**") && parseActionItem(body)?.owner != nil
        }
        var topics: [String] = [], tasks: [String] = []
        for (i, block) in blocks.enumerated() {
            if groups.contains(i) {
                for l in block { if isOwnerBullet(l) { tasks.append(l) } else { topics.append(l) } }
            } else {
                out += block; out.append("")
            }
        }
        if !topics.isEmpty { out += ["## \(headings[0])"] + topics + [""] }
        if !tasks.isEmpty { out += ["## \(last)"] + tasks }
        return out.joined(separator: "\n")
    }

    static let overviewHeadings: Set<String> = ["overview", "summary", "meeting summary", "meeting overview", "tl;dr", "tldr"]

    /// A heading line: `#…` (level = number of #), a whole-line `**Bold**`, or a short `Label:` line (level 2).
    static func heading(_ t: String) -> (Int, String)? {
        if t.hasPrefix("#") {
            let level = t.prefix { $0 == "#" }.count
            let rest = t.dropFirst(level)
            guard level <= 6, rest.first == " " else { return nil }
            let h = cleanHeading(String(rest))
            return h.isEmpty ? nil : (level, h)
        }
        if t.hasPrefix("**") && (t.hasSuffix("**") || t.hasSuffix("**:")) {
            let inner = cleanHeading(t)
            if !inner.isEmpty && !inner.contains("*") && words(inner).count <= 6 { return (2, inner) }
        }
        if t.hasSuffix(":") && !t.hasPrefix("-") && !t.hasPrefix("*") {
            let inner = String(t.dropLast()).trimmingCharacters(in: .whitespaces)
            if (1...4).contains(words(inner).count) && inner.first?.isUppercase == true && !inner.contains(".") && !inner.contains(":") {
                return (2, inner)
            }
        }
        return nil
    }

    static func cleanHeading(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "#: ").union(.whitespaces))
    }

    static func isNextStepsHeading(_ h: String) -> Bool {
        let l = h.lowercased()
        return ["next step", "action item", "action point", "follow-up", "follow up", "followup", "to-do", "todo", "to do"]
            .contains { l.contains($0) }
    }

    /// A list item: returns its indent (0 = top level) and its text.
    static func bullet(_ line: String) -> (Int, String)? {
        guard let m = line.firstMatch(#"^(\s*)(?:[-*•+–]|\d{1,2}[.)])\s+(.*\S)\s*$"#) else { return nil }
        var body = m[2]
        for box in ["[ ] ", "[x] ", "[X] "] where body.hasPrefix(box) { body = String(body.dropFirst(box.count)) }
        return (m[1].count, body)
    }

    static func isBulletLine(_ line: String) -> Bool { bullet(line) != nil }

    // MARK: Parsing (also useful on user-edited summaries)

    /// The overview: the first paragraph before the first heading (else the first paragraph anywhere).
    public static func overview(of markdown: String) -> String {
        var paragraphs: [(beforeHeading: Bool, text: String)] = []
        var current: [String] = [], seenHeading = false
        func flush() {
            if !current.isEmpty { paragraphs.append((!seenHeading, current.joined(separator: " "))); current = [] }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); continue }
            if t.hasPrefix("#") || isBulletLine(t) || heading(t) != nil {
                flush()
                if t.hasPrefix("#") || heading(t) != nil { seenHeading = true }
                continue
            }
            current.append(t)
        }
        flush()
        let pick = paragraphs.first { $0.beforeHeading } ?? paragraphs.first
        return (pick?.text ?? "").replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Action items from the Next steps (or Action items / Follow-ups) section.
    public static func actionItems(in markdown: String) -> [MeetingActionItem] {
        let lines = markdown.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var items: [MeetingActionItem] = []
        var inSection = false
        var headingOwner: String? // "### Priya", "**Priya**" or "Priya:" alone on a line
        var bulletOwner: String?  // "- **Priya**" followed by nested bullets
        for (i, raw) in lines.enumerated() {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#"), let (level, h) = heading(t) {
                if inSection && level >= 3 { headingOwner = isOwnerLike(h) ? h : nil; bulletOwner = nil; continue }
                inSection = isNextStepsHeading(h); headingOwner = nil; bulletOwner = nil
                continue
            }
            guard inSection else { continue }
            guard let (indent, body) = bullet(raw) else {
                if let (_, h) = heading(t), isOwnerLike(h) { headingOwner = h; bulletOwner = nil }
                continue
            }
            if indent == 0 {
                bulletOwner = nil
                let plain = body.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                let nextIsNested = i + 1 < lines.count && (bullet(lines[i + 1])?.0 ?? 0) > 0
                if nextIsNested && isOwnerLike(plain) && parseActionItem(body)?.owner == nil { bulletOwner = plain; continue }
            }
            guard var item = parseActionItem(body) else { continue }
            if item.owner == nil { item.owner = (indent > 0 ? bulletOwner : nil) ?? headingOwner }
            items.append(item)
        }
        return items
    }

    static let ownerStopWords: Set<String> = ["deadline", "note", "notes", "action", "todo", "task", "next", "due", "status",
                                              "priority", "goal", "owner", "done", "update", "decision", "question", "follow",
                                              "timeline", "when", "by", "then", "also", "and"]

    /// Something that reads like a person, a few people, or a group label ("You", "Team", "Others").
    static func isOwnerLike(_ raw: String) -> Bool {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let paren = s.range(of: " (") { s = String(s[..<paren.lowerBound]) } // "Namik (You)"
        guard (1...40).contains(s.count), !s.contains(where: \.isNumber) else { return false }
        let parts = s.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        guard (1...5).contains(parts.count) else { return false }
        if ownerStopWords.contains(parts[0].lowercased()) { return false }
        return parts.allSatisfy { p in
            ["and", "&", "/", "+"].contains(p) || (p.first?.isUppercase == true && p.allSatisfy { $0.isLetter || "'-.".contains($0) })
        }
    }

    static let noneItems = ["none", "n/a", "nothing", "no next steps", "no action items", "no follow-ups", "no follow ups",
                            "no followups", "no follow-up", "nothing was agreed", "no specific", "no clear next steps"]
    static let unassignedOwners: Set<String> = ["unassigned", "tbd", "unknown", "n/a", "none", "owner", "anyone", "someone"]

    /// Parses one Next steps bullet: `**Owner** — x`, `**Owner:** x`, `Owner: x`, `Owner — x`, `(Owner) x`, `[Owner] x` or `x`.
    static func parseActionItem(_ body: String) -> MeetingActionItem? {
        let s = body.trimmingCharacters(in: .whitespaces)
        let plain = s.replacingOccurrences(of: "**", with: "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ._:"))
        if plain.isEmpty || noneItems.contains(where: { plain == $0 || plain.hasPrefix($0 + " ") || plain.hasPrefix($0 + ".") || plain.hasPrefix($0 + ",") }) {
            return nil
        }
        var owner: String?
        var text = s
        if let m = s.firstMatch(#"^\*\*(.+?)\*\*\s*(.*)$"#) {
            let candidate = m[1].trimmingCharacters(in: CharacterSet(charactersIn: ":—–- "))
            let rest = stripSeparators(m[2])
            if rest.isEmpty { text = candidate }
            else if isOwnerLike(candidate) { owner = candidate; text = rest }
        } else if let m = s.firstMatch(#"^[(\[]([^)\]]{1,40})[)\]]\s*[:—–-]?\s*(.+)$"#), isOwnerLike(m[1]) {
            owner = m[1]; text = m[2]
        } else if let m = s.firstMatch(#"^([^:—–]{1,40}?)\s*(?::|\s[—–-]\s|[—–])\s*(.+)$"#), isOwnerLike(m[1]) {
            owner = m[1]; text = m[2]
        }
        if let o = owner {
            var name = o.trimmingCharacters(in: .whitespaces)
            if let paren = name.range(of: " (") { name = String(name[..<paren.lowerBound]) }
            owner = unassignedOwners.contains(name.lowercased()) ? nil : name
            // "Priya will send…" / "Priya to send…" → "Send…"
            for lead in ["will ", "to ", "should "] where text.lowercased().hasPrefix(lead) && owner != nil {
                text = String(text.dropFirst(lead.count))
            }
        }
        text = stripSeparators(text).replacingOccurrences(of: "**", with: "")
        guard let first = text.first else { return nil }
        text = first.uppercased() + text.dropFirst()
        return MeetingActionItem(owner: owner, text: text)
    }

    static func stripSeparators(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: ":—–- ").union(.whitespaces))
    }

    // MARK: Title cleanup

    static let titleSmallWords: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "as", "at", "by", "in",
                                               "of", "on", "per", "to", "via", "vs", "vs.", "with"]

    /// First line, without labels, quotes, Markdown or trailing punctuation; at most 6 words; Title Case.
    static func cleanTitle(_ raw: String) -> String? {
        guard var t = raw.strippingThinking().components(separatedBy: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^(meeting\s+)?title\s*[:\-—–]\s*"#, options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        let edge = CharacterSet(charactersIn: "\"'“”‘’`«»*_ .!?:;,…").union(.whitespaces)
        t = t.trimmingCharacters(in: edge)
        var ws = t.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !ws.isEmpty else { return nil }
        if ws.count > 6 {
            ws = Array(ws.prefix(6))
            while ws.count > 1, let last = ws.last, titleSmallWords.contains(last.lowercased()) { ws.removeLast() }
        }
        let last = ws.count - 1
        let cased = ws.enumerated().map { i, w -> String in
            let lower = w.lowercased()
            if i != 0 && i != last && titleSmallWords.contains(lower) { return lower }
            // Keep acronyms and mixed case (API, iOS, McKinsey); "q3" → "Q3".
            if w.dropFirst().contains(where: \.isUppercase) { return w }
            if w.contains(where: \.isNumber) { return w.prefix(1).uppercased() + w.dropFirst() }
            return lower.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "-")
        }
        let title = String(cased.joined(separator: " ").prefix(120)).trimmingCharacters(in: edge)
        return title.isEmpty ? nil : title
    }
}

// MARK: - Regex helper

extension String {
    /// Capture groups of the first match (index 0 = whole match; unmatched groups are "").
    fileprivate func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
