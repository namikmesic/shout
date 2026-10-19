import XCTest
@testable import ShoutKit
import ShoutLLM

/// Records every call and answers by call type (classification, part notes, merge, summary, title).
private final class FakeGenerator: TextGenerator, @unchecked Sendable {
    struct Call { let messages: [ChatMessage]; let options: GenerationOptions; let kind: Kind }
    enum Kind { case classify, part, merge, summary, title }

    let displayName = "Fake"
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    func calls(_ kind: Kind) -> [Call] { calls.filter { $0.kind == kind } }

    var classifyReply = "group"
    var partReply: (Int) -> String = { i in "Decisions:\n- Decision from part \(i).\nAction items:\n- Others — follow up on part \(i)." }
    var mergeReply = "Decisions:\n- Merged decision.\nAction items:\n- Team — merged follow-up."
    var summaryReplies: [String] = [FakeGenerator.goodSummary]
    var titleReply = "Title: \"quarterly roadmap review.\""

    static let goodSummary = """
    Sam and the team agreed to ship the beta on the 28th and to revisit pricing next week.

    ## Decisions
    - Ship the beta on the 28th.

    ## Open questions
    - Whether pricing changes before launch.

    ## Next steps
    - **Sam** — Send the launch checklist by Friday.
    - **Others** — Review the pricing draft.
    """

    func warmUp() async {}

    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        let user = messages.last?.content ?? ""
        let kind: Kind
        if messages.first?.content == MeetingSummarizer.titleSystem { kind = .title }
        else if user.contains("What kind of meeting is this?") { kind = .classify }
        else if user.contains("one part of a long meeting") { kind = .part }
        else if user.contains("Merge the notes above") { kind = .merge }
        else { kind = .summary }
        let n = lock.withLock {
            _calls.append(Call(messages: messages, options: options, kind: kind))
            return _calls.filter { $0.kind == kind }.count
        }
        switch kind {
        case .classify: return classifyReply
        case .part: return partReply(n)
        case .merge: return mergeReply
        case .title: return titleReply
        case .summary: return summaryReplies[min(n, summaryReplies.count) - 1]
        }
    }
}

private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _stages: [MeetingSummaryStage] = []
    var stages: [MeetingSummaryStage] { lock.withLock { _stages } }
    func add(_ s: MeetingSummaryStage) { lock.withLock { _stages.append(s) } }
}

private func seg(_ source: MeetingSource, _ text: String, at ms: Int, speaker: String? = nil, edited: String? = nil,
                 latched: Bool = false, marker: MeetingMarker? = nil) -> MeetingSegment {
    MeetingSegment(meetingID: "m", source: source, speaker: speaker, startMs: ms, endMs: ms + 1_000, text: text,
                   editedText: edited, latched: latched, marker: marker)
}

/// A realistic-looking conversation of about `words` words, alternating You / Others.
private func conversation(words: Int) -> [MeetingSegment] {
    let sentences = [
        "We still need to decide whether the migration runs before or after the holiday freeze.",
        "I think the dashboard numbers look right, but the weekly totals are off by about three percent.",
        "Can you check with finance whether the new budget covers the extra infrastructure?",
        "The customer asked again about single sign-on, so we should put it on the roadmap.",
        "Let's keep the scope small and ship the read-only version first, then iterate.",
        "I'll write up the proposal and share it with everyone before the next review.",
    ]
    var out: [MeetingSegment] = []
    var count = 0, i = 0, ms = 0
    while count < words {
        let text = sentences[i % sentences.count] + " " + sentences[(i * 7 + 3) % sentences.count]
        out.append(seg(i % 2 == 0 ? .mic : .system, text, at: ms))
        count += TextRules.wordCount(text); i += 1; ms += 8_000
    }
    return out
}

final class MeetingSummarizerTests: XCTestCase {

    // MARK: Transcript formatting

    func testTurnsMergeTheUserSkipMarkersAndLatchedLinesAndUseEdits() {
        let segments = [
            seg(.mic, "Good morning", at: 0),
            seg(.mic, "everyone.", at: 1_500),
            seg(.marker, "", at: 2_000, marker: .stopped),
            seg(.mic, "This only repeated the call audio.", at: 2_500, latched: true),
            seg(.system, "Morning!", at: 3_000),
            seg(.system, "Hi, I am Priya.", at: 4_000),
            seg(.system, "wrong words", at: 5_000, edited: "Corrected words."),
            seg(.system, "   ", at: 6_000),
            seg(.system, "Ada here.", at: 7_000, speaker: "Ada"),
            seg(.system, "Still Ada.", at: 8_000, speaker: "Ada"),
            seg(.mic, "Out of order but early.", at: 500),
        ]
        let turns = MeetingSummarizer.turns(from: segments, userLabel: "Dana")
        XCTAssertEqual(MeetingSummarizer.render(turns), """
        Dana: Good morning Out of order but early. everyone.
        Others: Morning!
        Others: Hi, I am Priya.
        Others: Corrected words.
        Ada: Ada here. Still Ada.
        """)
        XCTAssertEqual(turns.first?.startMs, 0)
        XCTAssertEqual(turns.first?.endMs, 2_500)
    }

    func testSharedChannelIsMergedOnlyWhenEnabled() {
        // "Others" is every remote voice; consecutive lines are kept apart so the model sees the turn changes.
        XCTAssertFalse(MeetingSummarizer.mergeSharedChannel)
        let turns = MeetingSummarizer.turns(from: [seg(.system, "One.", at: 0), seg(.system, "Two.", at: 1_000)], userLabel: "You")
        XCTAssertEqual(turns.count, 2)
    }

    func testPromptNamesTheUserAndIncludesNotesAndMeetingDetails() async throws {
        let gen = FakeGenerator()
        let input = MeetingSummaryInput(title: "Launch sync", date: Date(timeIntervalSince1970: 1_792_108_800),
                                        participants: ["Dana Whitfield", "Sam Ortiz", "Priya Raman"], userName: "Dana",
                                        notes: "- confirm beta date", segments: conversation(words: 300))
        _ = try await MeetingSummarizer.summarize(input, generator: gen, wantTitle: false)
        let call = try XCTUnwrap(gen.calls(.summary).first)
        XCTAssertTrue(call.messages[0].content.contains("Lines starting with \"Dana:\" are the user, Dana"))
        let user = call.messages[1].content
        XCTAssertTrue(user.contains("Title: Launch sync"))
        XCTAssertTrue(user.contains("Invited: Dana Whitfield, Sam Ortiz, Priya Raman"))
        XCTAssertTrue(user.contains("<user_notes>\n- confirm beta date\n</user_notes>"))
        XCTAssertTrue(user.contains("<transcript>\nDana: "))
        XCTAssertTrue(user.contains("\nOthers: "))
        XCTAssertFalse(user.contains("\nYou: "))
        XCTAssertTrue(user.contains("Refer to the user as \"Dana\""))
        // Instructions come last, after the shared prefix.
        XCTAssertTrue(user.hasSuffix("</task>"))
    }

    // MARK: Sentinels

    func testNoSpeechMakesNoModelCall() async throws {
        let gen = FakeGenerator()
        for segments in [[], [seg(.mic, "Um, uh.", at: 0), seg(.system, "Hmm?", at: 1_000)],
                         [seg(.marker, "", at: 0, marker: .stopped), seg(.mic, "Testing one two three four five six", at: 0, latched: true)]] {
            let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: segments), generator: gen, wantTitle: true)
            XCTAssertEqual(s.outcome, .noSpeech)
            XCTAssertEqual(s.markdown, "")
            XCTAssertNil(s.title)
        }
        XCTAssertTrue(gen.calls.isEmpty)
    }

    func testTooShortMakesNoModelCall() async throws {
        let gen = FakeGenerator()
        let segments = [seg(.mic, "Hey, can you hear me? I think my microphone was muted for a second there.", at: 0),
                        seg(.system, "Yes, we can hear you now. Let's wait two minutes for the others to join, okay?", at: 5_000)]
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: segments), generator: gen, wantTitle: true)
        XCTAssertEqual(s.outcome, .tooShort)
        XCTAssertTrue(gen.calls.isEmpty)
    }

    // MARK: Single pass

    func testShortMeetingIsOnePassWithParsedResult() async throws {
        let gen = FakeGenerator()
        let log = StageLog()
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(userName: "Sam", segments: conversation(words: 400)),
                                                      generator: gen, wantTitle: true, progress: { log.add($0) })
        XCTAssertEqual(s.outcome, .summary)
        XCTAssertEqual(gen.calls(.part).count, 0)
        XCTAssertEqual(gen.calls(.classify).count, 1)
        XCTAssertEqual(gen.calls(.summary).count, 1)
        XCTAssertEqual(log.stages, [.writing, .titling])
        XCTAssertEqual(s.overview, "Sam and the team agreed to ship the beta on the 28th and to revisit pricing next week.")
        XCTAssertEqual(s.actionItems, [MeetingActionItem(owner: "Sam", text: "Send the launch checklist by Friday."),
                                       MeetingActionItem(owner: "Others", text: "Review the pricing draft.")])
        XCTAssertEqual(s.title, "Quarterly Roadmap Review")
        // Summaries are background work that dictation can preempt.
        XCTAssertTrue(gen.calls.allSatisfy(\.options.background))
        // The classification answer picks the headings the summary is asked for.
        let task = try XCTUnwrap(gen.calls(.summary).first?.messages.last?.content)
        XCTAssertTrue(task.contains("\"## Decisions\"") && task.contains("\"## Open questions\""))
        // The classification and the summary share everything up to the task, so the KV cache is reused.
        let a = try XCTUnwrap(gen.calls(.classify).first?.messages.last?.content)
        XCTAssertEqual(a.components(separatedBy: "<task>").first, task.components(separatedBy: "<task>").first)
    }

    func testMeetingKindFromTitleSkipsClassification() async throws {
        let gen = FakeGenerator()
        _ = try await MeetingSummarizer.summarize(MeetingSummaryInput(title: "Dana / Chris 1:1", segments: conversation(words: 200)),
                                                  generator: gen, wantTitle: false)
        XCTAssertEqual(gen.calls(.classify).count, 0)
        let task = try XCTUnwrap(gen.calls(.summary).first?.messages.last?.content)
        XCTAssertTrue(task.contains("\"## Updates\"") && task.contains("\"## Feedback\""))
        XCTAssertEqual(MeetingSummarizer.MeetingKind.fromTitle("Weekly Stand-up"), .standup)
        XCTAssertEqual(MeetingSummarizer.MeetingKind.fromTitle("Interview: backend candidate"), .interview)
        XCTAssertNil(MeetingSummarizer.MeetingKind.fromTitle("Q4 planning"))
    }

    func testClassificationAnswerIsParsedLoosely() async throws {
        for (reply, heading) in [("One-on-one.", "Feedback"), ("**standup**", "Blockers"), ("customer", "Customer needs"),
                                 ("I am not sure", "Key points")] {
            let gen = FakeGenerator()
            gen.classifyReply = reply
            _ = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 200)), generator: gen, wantTitle: false)
            let task = try XCTUnwrap(gen.calls(.summary).first?.messages.last?.content)
            XCTAssertTrue(task.contains("\"## \(heading)\""), reply)
        }
    }

    func testSoleOtherInviteeReplacesOthersAsOwner() async throws {
        let gen = FakeGenerator()
        let input = MeetingSummaryInput(participants: ["Dana Whitfield", "Chris Romero"], userName: "Dana",
                                        segments: conversation(words: 200))
        let s = try await MeetingSummarizer.summarize(input, generator: gen, wantTitle: false)
        XCTAssertTrue(gen.calls(.summary)[0].messages[1].content.contains("\"Others\" in this meeting is Chris Romero"))
        XCTAssertEqual(s.actionItems.last, MeetingActionItem(owner: "Chris Romero", text: "Review the pricing draft."))
        XCTAssertNil(MeetingSummarizer.soleOtherParticipant(["Dana", "Chris", "Sam"], speakers: .init(userName: "Dana")))
        XCTAssertNil(MeetingSummarizer.soleOtherParticipant(["Dana", "Chris"], speakers: .init(userName: nil)))
    }

    // MARK: Map-reduce

    func testLongMeetingIsReadInPartsThatFitTheContext() async throws {
        let gen = FakeGenerator()
        let log = StageLog()
        let context = 8192
        let segments = conversation(words: 11_000) // about 75 minutes
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(notes: "my notes", segments: segments),
                                                      generator: gen, wantTitle: true, contextTokens: context,
                                                      progress: { log.add($0) })
        XCTAssertEqual(s.outcome, .summary)
        let parts = gen.calls(.part)
        XCTAssertGreaterThanOrEqual(parts.count, 3)
        XCTAssertEqual(log.stages, (1...parts.count).map { .reading(part: $0, of: parts.count) } + [.writing, .titling])
        for call in gen.calls {
            let prompt = call.messages.map(\.content).joined(separator: "\n")
            XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(prompt) + call.options.maxTokens, context - 200,
                                     "\(call.kind) prompt over budget")
        }
        // Parts split on turn boundaries: every transcript line is a whole "Speaker: …" turn, and nothing is lost.
        var seen = 0
        for call in parts {
            let user = call.messages[1].content
            let body = try XCTUnwrap(user.components(separatedBy: "\">\n").dropFirst().first?.components(separatedBy: "\n</transcript>").first)
            for line in body.components(separatedBy: "\n") {
                XCTAssertTrue(line.hasPrefix("You: ") || line.hasPrefix("Others: "), line)
                seen += 1
            }
        }
        XCTAssertEqual(seen, MeetingSummarizer.turns(from: segments, userLabel: "You").count)
        // The summary is written from the part notes, in order.
        let final = try XCTUnwrap(gen.calls(.summary).first?.messages[1].content)
        XCTAssertTrue(final.contains("<part_notes>"))
        XCTAssertFalse(final.contains("<transcript>"))
        let first = try XCTUnwrap(final.range(of: "Decision from part 1."))
        let last = try XCTUnwrap(final.range(of: "Decision from part \(parts.count)."))
        XCTAssertLessThan(first.lowerBound, last.lowerBound)
    }

    func testVeryLongMeetingMergesPartNotesToFit() async throws {
        let gen = FakeGenerator()
        // Verbose notes for every part force the merge step in a small context.
        gen.partReply = { i in "Key points:\n" + String(repeating: "- Part \(i) detail about the rollout plan and owners.\n", count: 40) }
        let context = 4096
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 9_000)),
                                                      generator: gen, wantTitle: false, contextTokens: context)
        XCTAssertEqual(s.outcome, .summary)
        XCTAssertGreaterThan(gen.calls(.merge).count, 0)
        for call in gen.calls {
            let prompt = call.messages.map(\.content).joined(separator: "\n")
            XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(prompt) + call.options.maxTokens, context, "\(call.kind)")
        }
    }

    func testOneUnreadablePartIsSkipped() async throws {
        let gen = FakeGenerator()
        gen.partReply = { n in n == 2 || n == 3 ? "" : "Decisions:\n- Decision \(n)." } // part 2 fails both tries
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 11_000)),
                                                      generator: gen, wantTitle: false, contextTokens: 8192)
        XCTAssertEqual(s.outcome, .summary)
        XCTAssertGreaterThanOrEqual(gen.calls(.part).count, 4)
    }

    func testMostPartsUnreadableFailsRatherThanSummarizingAFew() async throws {
        let gen = FakeGenerator()
        // The model writes the transcript back out, speaker by speaker, for every part but the first.
        let echo = "Others: We still need to decide on the migration.\nYou: I think the numbers look right.\n"
            + "Others: Can you check with finance?\nYou: I'll write up the proposal."
        gen.partReply = { n in n == 1 ? "Decisions:\n- From part 1." : echo }
        do {
            _ = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 11_000)),
                                                      generator: gen, wantTitle: false, contextTokens: 8192)
            XCTFail("expected an error")
        } catch let e as MeetingSummaryError {
            XCTAssertEqual(e, .echoedTranscript)
        }
        XCTAssertTrue(gen.calls(.summary).isEmpty)
    }

    func testMostlyQuietMeetingIsStillSummarized() async throws {
        let gen = FakeGenerator()
        // Nothing worth noting in most parts: the model leaves their notes empty, as the part task allows.
        gen.partReply = { n in n == 1 ? "Decisions:\n- From part 1." : "" }
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 11_000)),
                                                      generator: gen, wantTitle: false, contextTokens: 8192)
        XCTAssertEqual(s.outcome, .summary)
    }

    func testPartNotesThatCannotFitThrowRatherThanOverflow() async throws {
        let gen = FakeGenerator()
        let text = String(repeating: "- A long note line about the rollout and its owners.\n", count: 30)
        let notes = (1...20).map { MeetingSummarizer.PartNotes(first: $0, last: $0, count: 20, start: "0:00", end: "9:00", text: text) }
        do {
            _ = try await MeetingSummarizer.fitNotes(notes, room: 400, system: "", speakers: .init(userName: nil), wordLimit: 80,
                                                     generator: gen, contextTokens: 1200)
            XCTFail("expected an error")
        } catch let e as MeetingSummaryError {
            XCTAssertEqual(e, .contextTooSmall(1200))
        }
        // Few enough parts are cut to fit.
        let three = try await MeetingSummarizer.fitNotes(Array(notes.prefix(3)), room: 400, system: "", speakers: .init(userName: nil),
                                                         wordLimit: 80, generator: gen, contextTokens: 1200)
        XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(three), 400)
        XCTAssertTrue(gen.calls(.merge).isEmpty)
    }

    func testOverlongSingleTurnIsSplitBetweenSentences() {
        let sentence = "This is one long monologue sentence about the quarterly plan and its many details."
        let turn = MeetingSummarizer.Turn(speaker: "Others", text: Array(repeating: sentence, count: 400).joined(separator: " "),
                                          startMs: 0, endMs: 600_000)
        let chunks = MeetingSummarizer.chunk([turn], budget: 1_000)
        XCTAssertGreaterThan(chunks.count, 5)
        for c in chunks {
            XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(MeetingSummarizer.render(c)), 1_000)
            for t in c { XCTAssertTrue(t.text.hasSuffix(".")) }
        }
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.text).joined(separator: " "), turn.text)
        XCTAssertEqual(chunks.last?.last?.endMs, 600_000)
    }

    func testChunksAreBalanced() {
        let turns = (0..<100).map { MeetingSummarizer.Turn(speaker: $0 % 2 == 0 ? "You" : "Others",
                                                            text: String(repeating: "word ", count: 50), startMs: $0, endMs: $0) }
        let total = MeetingSummarizer.estimateTokens(MeetingSummarizer.render(turns))
        for (budget, parts) in [(total / 3 + 300, 3), (total / 3 + 20, 4), (total / 5 + 300, 5)] {
            let chunks = MeetingSummarizer.chunk(turns, budget: budget)
            XCTAssertEqual(chunks.count, parts, "budget \(budget)")
            let sizes = chunks.map(\.count)
            XCTAssertGreaterThanOrEqual(sizes.min()! * 2, sizes.max()!, "\(sizes)") // no tiny last part
            XCTAssertEqual(chunks.flatMap { $0 }, turns)
            for c in chunks { XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(MeetingSummarizer.render(c)), budget) }
        }
    }

    func testEstimateIsConservativeForEnglish() {
        let text = String(repeating: "We agreed to ship the read-only version first and revisit editing in Q1. ", count: 20)
        XCTAssertGreaterThanOrEqual(MeetingSummarizer.estimateTokens(text), text.count / 4)
        XCTAssertEqual(MeetingSummarizer.estimateTokens("日本語"), 3)
    }

    // MARK: Retries and guards

    func testEmptyOutputIsRetriedAtHigherTemperature() async throws {
        let gen = FakeGenerator()
        gen.summaryReplies = ["   ", FakeGenerator.goodSummary]
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 300)), generator: gen, wantTitle: false)
        XCTAssertEqual(s.outcome, .summary)
        XCTAssertEqual(gen.calls(.summary).map(\.options.temperature), [0, 0.2])
    }

    func testEchoedTranscriptThrowsAfterRetry() async throws {
        let gen = FakeGenerator()
        let segments = conversation(words: 300)
        let echoed = MeetingSummarizer.render(MeetingSummarizer.turns(from: segments, userLabel: "You"))
        gen.summaryReplies = [echoed, "Here is the summary:\n" + echoed]
        do {
            _ = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: segments), generator: gen, wantTitle: false)
            XCTFail("expected an error")
        } catch let e as MeetingSummaryError {
            XCTAssertEqual(e, .echoedTranscript)
            XCTAssertNotNil(e.errorDescription)
        }
        XCTAssertEqual(gen.calls(.summary).count, 2)
    }

    func testPreemptionIsPassedThrough() async throws {
        final class Preempting: TextGenerator, @unchecked Sendable {
            let displayName = "Preempting"
            func warmUp() async {}
            func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
                throw TextGeneratorError.preempted
            }
        }
        do {
            _ = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 300)),
                                                      generator: Preempting(), wantTitle: true)
            XCTFail("expected preemption")
        } catch TextGeneratorError.preempted {}
    }

    func testEmptyTwiceThrows() async throws {
        let gen = FakeGenerator()
        gen.summaryReplies = ["", "<think>hmm</think>"]
        do {
            _ = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 300)), generator: gen, wantTitle: false)
            XCTFail("expected an error")
        } catch let e as MeetingSummaryError {
            XCTAssertEqual(e, .emptyOutput)
        }
    }

    func testBadlyFormattedSummaryIsRetriedButKept() async throws {
        let gen = FakeGenerator()
        let plain = "Everyone agreed to ship the beta on the 28th and to revisit the pricing page copy next week with design."
        gen.summaryReplies = [plain, plain]
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 300)), generator: gen, wantTitle: false)
        XCTAssertEqual(s.markdown, plain)
        XCTAssertEqual(gen.calls(.summary).count, 2)
    }

    func testTitleIsOptionalAndFailuresAreIgnored() async throws {
        let gen = FakeGenerator()
        gen.titleReply = "  \"\" "
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 300)), generator: gen, wantTitle: true)
        XCTAssertNil(s.title)
        XCTAssertEqual(gen.calls(.title).count, 2)
        let none = FakeGenerator()
        _ = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: conversation(words: 300)), generator: none, wantTitle: false)
        XCTAssertEqual(none.calls(.title).count, 0)
    }

    // MARK: Output cleanup

    func testCleanupStripsThinkingFencesPreamblesAndNormalizesMarkdown() {
        let raw = """
        <think>Let me think.</think>
        Here is the summary of the meeting:
        ```markdown
        # Weekly Sync

        ## Overview
        The team agreed to ship on Friday.
        Pricing stays the same.

        **Decisions**
        * Ship on Friday.
        * Ship on Friday.
        • Keep pricing.

        ### Risks:

        + QA is short-staffed.

        Action Items:
        1. **Sam** - Book the launch room.
        2) [ ] Others: Send the deck.
        ```
        Let me know if you need anything else!
        """
        let md = MeetingSummarizer.normalizeSummary(MeetingSummarizer.stripWrapping(raw))
        XCTAssertEqual(md, """
        The team agreed to ship on Friday.
        Pricing stays the same.

        ## Decisions
        - Ship on Friday.
        - Keep pricing.

        ## Risks
        - QA is short-staffed.

        ## Next steps
        - **Sam** - Book the launch room.
        - Others: Send the deck.
        """)
        XCTAssertEqual(MeetingSummarizer.overview(of: md), "The team agreed to ship on Friday. Pricing stays the same.")
        XCTAssertEqual(MeetingSummarizer.actionItems(in: md), [MeetingActionItem(owner: "Sam", text: "Book the launch room."),
                                                               MeetingActionItem(owner: "Others", text: "Send the deck.")])
    }

    func testMissingHeadingsAreRestored() {
        let raw = """
        The team agreed to ship on Friday.

        - Ship on Friday.
        - Keep pricing.

        - QA is short-staffed.

        - **Sam** — Book the launch room.
        """
        let md = MeetingSummarizer.normalizeSummary(MeetingSummarizer.restoringHeadings(raw, headings: ["Decisions", "Open questions", "Next steps"]))
        XCTAssertEqual(md, """
        The team agreed to ship on Friday.

        ## Decisions
        - Ship on Friday.
        - Keep pricing.

        ## Open questions
        - QA is short-staffed.

        ## Next steps
        - **Sam** — Book the launch room.
        """)
        // Groups that do not line up: owner bullets go to Next steps, the rest to the first section.
        let merged = MeetingSummarizer.restoringHeadings("Overview.\n\n- Ship it.\n- **Sam** — Book the room.",
                                                        headings: ["Decisions", "Open questions", "Next steps"])
        XCTAssertEqual(merged, "Overview.\n\n## Decisions\n- Ship it.\n\n## Next steps\n- **Sam** — Book the room.")
        // Text that already has headings is left alone.
        XCTAssertEqual(MeetingSummarizer.restoringHeadings("A.\n\n## X\n- b", headings: ["D", "O", "Next steps"]), "A.\n\n## X\n- b")
    }

    // MARK: Parsing

    func testActionItemVariants() {
        let md = """
        Overview paragraph.

        ## Decisions
        - **Priya** — Not an action item, wrong section.

        ## Next Steps
        - **Priya** — Send the deck by Friday.
        - **Marco:** Fix the dark mode toggle.
        - **Lena**: Rerun the flaky tests.
        - Wei: Publish the postmortem.
        - Jordan — Monitor refunds for 30 days.
        - (Hannah) Update the pricing copy.
        - [Sam] Talk to Rachel.
        - **You** — Post the on-call rotation.
        - **Team** will review the plan together.
        - Deadline: Friday for everything.
        - Follow up with legal about the DPA.
        - **Unassigned** — Pick a venue.
        - Namik (You): Chase the copy.
        1. **Ana and Ben** — Pair on the migration.
        - [ ] Check the alerts.
        - None
        """
        XCTAssertEqual(MeetingSummarizer.actionItems(in: md), [
            .init(owner: "Priya", text: "Send the deck by Friday."),
            .init(owner: "Marco", text: "Fix the dark mode toggle."),
            .init(owner: "Lena", text: "Rerun the flaky tests."),
            .init(owner: "Wei", text: "Publish the postmortem."),
            .init(owner: "Jordan", text: "Monitor refunds for 30 days."),
            .init(owner: "Hannah", text: "Update the pricing copy."),
            .init(owner: "Sam", text: "Talk to Rachel."),
            .init(owner: "You", text: "Post the on-call rotation."),
            .init(owner: "Team", text: "Review the plan together."),
            .init(owner: nil, text: "Deadline: Friday for everything."),
            .init(owner: nil, text: "Follow up with legal about the DPA."),
            .init(owner: nil, text: "Pick a venue."),
            .init(owner: "Namik", text: "Chase the copy."),
            .init(owner: "Ana and Ben", text: "Pair on the migration."),
            .init(owner: nil, text: "Check the alerts."),
        ])
    }

    func testActionItemsGroupedByOwner() {
        let md = """
        ## Action items
        - **Priya**
          - Send the deck.
          - Book the room.
        - **Sam** — Approve the budget.

        ### Marco
        - Ship the hotfix.

        ## Notes
        - Not a task.
        """
        XCTAssertEqual(MeetingSummarizer.actionItems(in: md), [
            .init(owner: "Priya", text: "Send the deck."),
            .init(owner: "Priya", text: "Book the room."),
            .init(owner: "Sam", text: "Approve the budget."),
            .init(owner: "Marco", text: "Ship the hotfix."),
        ])
    }

    func testNoneAndEmptyNextSteps() {
        XCTAssertEqual(MeetingSummarizer.actionItems(in: "Text.\n\n## Next steps\n- None"), [])
        XCTAssertEqual(MeetingSummarizer.actionItems(in: "Text.\n\n## Next steps\n- No next steps were agreed."), [])
        XCTAssertEqual(MeetingSummarizer.actionItems(in: "Text without sections."), [])
    }

    func testOverviewExtraction() {
        XCTAssertEqual(MeetingSummarizer.overview(of: "First line\nsecond line.\n\nSecond paragraph.\n\n## A\n- b"),
                       "First line second line.")
        XCTAssertEqual(MeetingSummarizer.overview(of: "**Bold** start.\n## A\n- b"), "Bold start.")
        // No paragraph before the first heading: the first paragraph anywhere.
        XCTAssertEqual(MeetingSummarizer.overview(of: "## A\n- b\n\nLate paragraph."), "Late paragraph.")
        XCTAssertEqual(MeetingSummarizer.overview(of: "## A\n- b"), "")
    }

    // MARK: Title

    func testTitleCleanup() {
        XCTAssertEqual(MeetingSummarizer.cleanTitle("Title: \"q3 roadmap review.\""), "Q3 Roadmap Review")
        XCTAssertEqual(MeetingSummarizer.cleanTitle("**Weekly sync with the API team**"), "Weekly Sync with the API Team")
        XCTAssertEqual(MeetingSummarizer.cleanTitle("<think>ok</think>\n\n# “Hiring plan for iOS”\nextra line"), "Hiring Plan for iOS")
        XCTAssertEqual(MeetingSummarizer.cleanTitle("planning OF the follow-up launch!"), "Planning of the Follow-Up Launch")
        XCTAssertEqual(MeetingSummarizer.cleanTitle("Review of the offline mode plan and the pricing experiment results"),
                       "Review of the Offline Mode Plan")
        XCTAssertEqual(MeetingSummarizer.cleanTitle("Meeting title — Dana / Chris 1:1"), "Dana / Chris 1:1")
        XCTAssertNil(MeetingSummarizer.cleanTitle("  \"\"  "))
        XCTAssertNil(MeetingSummarizer.cleanTitle(""))
        XCTAssertLessThanOrEqual(MeetingSummarizer.cleanTitle(String(repeating: "Supercalifragilistic", count: 10))?.count ?? 0, 120)
    }

    // MARK: Generate vs Summarize Anyway (D-B6)

    func testOnlySummarizeAnywaySkipsTheTooShortCheck() async throws {
        let short = [seg(.mic, "Can you hear me? I think the microphone works now, so we can start with the agenda.", at: 0),
                     seg(.system, "Yes, loud and clear. Let's wait for the others before we begin.", at: 5_000)]
        let generate = FakeGenerator()
        let s = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: short), generator: generate, wantTitle: true)
        XCTAssertEqual(s.outcome, .tooShort) // Generate Summary / Try Again / Update
        XCTAssertTrue(generate.calls.isEmpty)

        let anyway = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: short), generator: FakeGenerator(),
                                                           wantTitle: false, allowShort: true)
        XCTAssertEqual(anyway.outcome, .summary)
        // The old spelling still means "Summarize Anyway".
        let forced = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: short), generator: FakeGenerator(),
                                                           wantTitle: false, force: true)
        XCTAssertEqual(forced.outcome, .summary)
        // No speech is never summarized.
        let silent = try await MeetingSummarizer.summarize(MeetingSummaryInput(segments: [seg(.mic, "Um.", at: 0)]),
                                                           generator: FakeGenerator(), wantTitle: false, allowShort: true)
        XCTAssertEqual(silent.outcome, .noSpeech)
    }

    // MARK: Title from the transcript (G2)

    func testTitleFromTranscriptAndNotes() async throws {
        let gen = ScriptedGenerator(replies: [.success("**Beta launch date.**")])
        let input = MeetingSummaryInput(userName: "Dana", notes: "beta date", segments: [seg(.mic, "Short one: the beta ships on the 28th.", at: 0)])
        let title = try await MeetingSummarizer.title(for: input, generator: gen)
        XCTAssertEqual(title, "Beta Launch Date")
        let prompt = try XCTUnwrap(gen.prompts.first)
        XCTAssertEqual(prompt.first?.content, MeetingSummarizer.transcriptTitleSystem)
        XCTAssertEqual(prompt.last?.content, "<user_notes>\nbeta date\n</user_notes>\n<transcript>\nDana: Short one: the beta ships on the 28th.\n</transcript>\n")
        XCTAssertEqual(gen.options.first?.maxTokens, MeetingSummarizer.titleMaxTokens)
    }

    func testTitleOfALongMeetingSamplesItsBeginningMiddleAndEnd() async throws {
        let gen = ScriptedGenerator(contextTokens: 4096, replies: [.success("Roadmap Review")])
        var segments = conversation(words: 20_000)
        segments.append(seg(.system, "Final words: thanks everyone, see you at the offsite.", at: 10_000_000))
        _ = try await MeetingSummarizer.title(for: MeetingSummaryInput(segments: segments), generator: gen, contextTokens: 4096)
        let user = try XCTUnwrap(gen.prompts.first?.last?.content)
        XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(user), MeetingSummarizer.maxTitleTranscriptTokens + 40)
        let total = gen.prompts[0].reduce(0) { $0 + MeetingSummarizer.estimateTokens($1.content) }
        XCTAssertLessThan(total + MeetingSummarizer.titleMaxTokens, 4096)
        XCTAssertTrue(user.contains("\n…\n"))
        XCTAssertTrue(user.contains("You: " + segments[0].text))
        XCTAssertTrue(user.contains("see you at the offsite"))
    }

    func testNothingToTitle() async throws {
        let gen = ScriptedGenerator(replies: [.success("Anything")])
        let silent = MeetingSummaryInput(segments: [seg(.mic, "Um, uh.", at: 0), seg(.mic, "Echo only", at: 1_000, latched: true)])
        XCTAssertFalse(MeetingSummarizer.canTitle(silent))
        let none = try await MeetingSummarizer.title(for: silent, generator: gen)
        XCTAssertNil(none)
        XCTAssertTrue(gen.prompts.isEmpty)
        XCTAssertTrue(MeetingSummarizer.canTitle(MeetingSummaryInput(notes: "Agenda: hiring", segments: [])))
    }

    // MARK: Languages without spaces (R4-6)

    static let japanese = "来週のリリースについて、価格の変更を確認しました。"

    func testJapaneseIsTruncatedAfterAClauseNotEmptied() {
        let text = String(repeating: Self.japanese, count: 40)
        let cut = MeetingSummarizer.truncate(text, toTokens: 60)
        XCTAssertTrue(cut.hasSuffix("。…") || cut.hasSuffix("、…"), cut)
        XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(cut), 60)
        XCTAssertGreaterThan(MeetingSummarizer.estimateTokens(cut), 40)
        XCTAssertTrue(text.hasPrefix(String(cut.dropLast())))
        // No punctuation: between characters. Spaced text: between words, as before.
        let run = MeetingSummarizer.truncate(String(repeating: "あいうえお", count: 40), toTokens: 30)
        XCTAssertEqual(run, String(repeating: "あいうえお", count: 5) + "あいうえ…")
        XCTAssertEqual(MeetingSummarizer.truncate("Send the deck to Priya by Friday", toTokens: 6), "Send the deck to…")
    }

    func testTitleOfAJapaneseMeetingSamplesItsText() async throws {
        let gen = ScriptedGenerator(replies: [.success("Pricing Change Review")])
        let segments = (0..<6).map { i in
            seg(i % 2 == 0 ? .mic : .system, "【\(i)】" + String(repeating: Self.japanese, count: 150), at: i * 60_000)
        }
        let input = MeetingSummaryInput(notes: String(repeating: Self.japanese, count: 50), segments: segments)
        _ = try await MeetingSummarizer.title(for: input, generator: gen)
        let user = try XCTUnwrap(gen.prompts.first?.last?.content)
        XCTAssertTrue(user.contains("<user_notes>\n来週のリリース"), "the notes are cut, not emptied")
        XCTAssertTrue(user.contains("You: 【0】来週のリリース"), "the beginning")
        XCTAssertTrue(user.contains("Others: 【5】来週のリリース"), "the end")
        XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(user),
                                 MeetingSummarizer.maxTitleTranscriptTokens + MeetingSummarizer.maxTitleNotesTokens + 40)
    }

    func testUnpunctuatedJapaneseTurnIsSplitToFitAPart() {
        let turn = MeetingSummarizer.Turn(speaker: "Others", text: String(repeating: "あいうえおかきくけこ", count: 300),
                                          startMs: 0, endMs: 600_000)
        let parts = MeetingSummarizer.split(turn, budget: 500)
        XCTAssertGreaterThan(parts.count, 5)
        XCTAssertTrue(parts.allSatisfy { MeetingSummarizer.estimateTokens($0.line) + 1 <= 500 })
        XCTAssertEqual(parts.map(\.text).joined(), turn.text)
        // Sentences are kept whole and joined as written.
        let spoken = MeetingSummarizer.Turn(speaker: "Others", text: String(repeating: Self.japanese, count: 100),
                                            startMs: 0, endMs: 600_000)
        let pieces = MeetingSummarizer.split(spoken, budget: 500)
        XCTAssertTrue(pieces.allSatisfy { $0.text.hasSuffix("。") && MeetingSummarizer.estimateTokens($0.line) + 1 <= 500 })
        XCTAssertEqual(pieces.map(\.text).joined(), spoken.text)
    }
}
