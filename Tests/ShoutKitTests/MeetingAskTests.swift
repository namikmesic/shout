import XCTest
@testable import ShoutKit
import ShoutLLM

/// Ask must fit the model's context (D-B2): a long meeting is cut to its beginning, end and the lines about
/// the question, not just its beginning.
final class MeetingAskTests: XCTestCase {
    private func tokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + MeetingSummarizer.estimateTokens($1.content) + 6 }
    }

    /// About `minutes` of conversation at ~900 characters a minute, one numbered line every 10 seconds.
    private func transcript(minutes: Int, special: [Int: String] = [:]) -> String {
        (0..<(minutes * 6)).map { i in
            special[i] ?? "\(i % 2 == 0 ? "You" : "Others"): Point \(i): we went through the dashboard numbers, the weekly totals and the open questions again."
        }.joined(separator: "\n")
    }

    func testLongMeetingFitsASmallContextWithBeginningEndAndKeywordLines() {
        let lines = transcript(minutes: 60, special: [180: "Others: The Kubernetes upgrade moves to March because of the freeze."])
        let source = AskSource(id: "m", title: "Infra sync", date: Date(), summary: String(repeating: "Summary sentence. ", count: 200),
                               notes: "- kubernetes?", transcript: lines)
        let msgs = MeetingAsk.messages(question: "When is the Kubernetes upgrade?", history: [], sources: [source], userName: nil,
                                       contextTokens: 4096)
        XCTAssertLessThanOrEqual(tokens(msgs) + MeetingAsk.replyTokens(contextTokens: 4096), 4096 - 100)
        XCTAssertGreaterThan(tokens(msgs), 2400, "the room left after the matches is used too")
        let material = msgs[1].content
        XCTAssertTrue(material.contains("Point 0:"), "beginning")
        XCTAssertTrue(material.contains("Point 359:"), "end")
        XCTAssertTrue(material.contains("The Kubernetes upgrade moves to March"), "keyword line")
        XCTAssertTrue(material.contains("Point 179:") && material.contains("Point 181:"), "context around it")
        XCTAssertTrue(material.contains("\n…\n"))
        XCTAssertTrue(material.contains("User's notes:\n- kubernetes?"))
        XCTAssertEqual(msgs.last?.content, "When is the Kubernetes upgrade?")
    }

    func testShortMeetingIsSentWhole() {
        let lines = transcript(minutes: 2)
        let source = AskSource(id: "m", title: "Standup", date: Date(), summary: "All good.", transcript: lines)
        let msgs = MeetingAsk.messages(question: "Anything blocked?", history: [], sources: [source], userName: "Dana", contextTokens: 8192)
        XCTAssertTrue(msgs[1].content.contains(lines))
        XCTAssertFalse(msgs[1].content.contains("…"))
        XCTAssertTrue(msgs[0].content.contains("The user is Dana"))
    }

    func testHistoryKeepsTheNewestTurnsThatFit() {
        let history = (0..<8).map { MeetingAsk.Turn(question: "Question \($0)?", answer: "Answer \($0). " + String(repeating: "More detail. ", count: 300)) }
        let msgs = MeetingAsk.messages(question: "And now?", history: history, sources: [], userName: nil, contextTokens: 4096)
        XCTAssertLessThanOrEqual(tokens(msgs) + MeetingAsk.replyTokens(contextTokens: 4096), 4096 - 100)
        let questions = msgs.filter { $0.role == .user }.map(\.content).dropFirst() // the first user turn is the material
        XCTAssertFalse(questions.isEmpty)
        XCTAssertEqual(questions.last, "And now?")
        XCTAssertEqual(questions.dropLast().last, "Question 7?")
        XCTAssertFalse(questions.contains("Question 0?"))
        // Chronological order is kept.
        let asked = questions.dropLast().compactMap { Int($0.dropFirst("Question ".count).dropLast()) }
        XCTAssertEqual(asked, asked.sorted())
    }

    func testSeveralMeetingsShareTheRoom() {
        let sources = (0..<6).map { i in
            AskSource(id: "m\(i)", title: "Meeting \(i)", date: Date(), summary: "Summary \(i).", transcript: transcript(minutes: 10))
        }
        let msgs = MeetingAsk.messages(question: "What about the dashboard?", history: [], sources: sources, userName: nil,
                                       contextTokens: 4096)
        XCTAssertLessThanOrEqual(tokens(msgs) + MeetingAsk.replyTokens(contextTokens: 4096), 4096 - 100)
        for i in 0..<6 { XCTAssertTrue(msgs[1].content.contains("### Meeting \(i) ("), "meeting \(i)") }
    }

    /// Titles have no length limit: a pasted one must not push the prompt past the context (Greptile PR #2).
    func testALongTitleIsCutSoThePromptStaysWithinTheBudget() {
        let title = String(repeating: "Quarterly planning ", count: 2000) // about 11,000 tokens
        let budget = { (msgs: [ChatMessage]) in self.tokens(msgs) + MeetingAsk.replyTokens(contextTokens: 4096) }
        // A meeting that has to be cut: its header used to be appended whole after its share was used up.
        let long = AskSource(id: "m", title: title, date: Date(), summary: "Budget approved.", transcript: transcript(minutes: 60))
        let msgs = MeetingAsk.messages(question: "What about the dashboard?", history: [], sources: [long], userName: nil,
                                       contextTokens: 4096)
        XCTAssertLessThanOrEqual(budget(msgs), 4096 - 100)
        let material = msgs[1].content
        XCTAssertTrue(material.hasPrefix("Meeting material:\n\n### Quarterly planning Quarterly planning"))
        XCTAssertTrue(material.contains("planning… ("), "the title is cut")
        XCTAssertTrue(material.contains("Point 0:") && material.contains("Point 359:"), "the transcript keeps the room")
        // A small meeting, and several meetings sharing the room (non-ASCII too).
        let small = AskSource(id: "s", title: title, date: Date(), summary: "All good.")
        let many = (0..<6).map { i in
            AskSource(id: "m\(i)", title: i % 2 == 0 ? title : String(repeating: Self.japanese, count: 500), date: Date(),
                      summary: "Summary \(i).", transcript: transcript(minutes: 10))
        }
        for sources in [[small], many] {
            let msgs = MeetingAsk.messages(question: "What about the dashboard?", history: [], sources: sources, userName: nil,
                                           contextTokens: 4096)
            XCTAssertLessThanOrEqual(budget(msgs), 4096 - 100)
            XCTAssertEqual(msgs[1].content.components(separatedBy: "\n### ").count - 1, sources.count, "every meeting is kept")
        }
    }

    func testFairShares() {
        XCTAssertEqual(MeetingAsk.fairShares([100, 1000, 1000], budget: 1100), [100, 500, 500])
        XCTAssertEqual(MeetingAsk.fairShares([10, 20], budget: 100), [10, 20])
        XCTAssertEqual(MeetingAsk.fairShares([300, 300, 300], budget: 600), [200, 200, 200])
        XCTAssertEqual(MeetingAsk.fairShares([], budget: 600), [])
    }

    func testOverlongTurnIsSplitWithItsLabel() {
        let line = "You: " + String(repeating: "word ", count: 2000)
        let pieces = MeetingAsk.splitLine(line, maxTokens: 100)
        XCTAssertGreaterThan(pieces.count, 10)
        XCTAssertTrue(pieces.allSatisfy { $0.hasPrefix("You: ") && MeetingSummarizer.estimateTokens($0) <= 100 })
    }

    // MARK: Languages without spaces (R4-6)

    static let japanese = "来週のリリースについて、価格の変更を確認しました。"

    func testJapaneseTurnIsSplitAfterClausesOrCharacters() {
        let text = String(repeating: Self.japanese, count: 100)
        let pieces = MeetingAsk.splitLine("Others: " + text, maxTokens: 100)
        XCTAssertGreaterThan(pieces.count, 20)
        XCTAssertTrue(pieces.allSatisfy { $0.hasPrefix("Others: ") && MeetingSummarizer.estimateTokens($0) <= 100 })
        XCTAssertEqual(pieces.map { $0.dropFirst("Others: ".count) }.joined(), text, "nothing is lost")
        XCTAssertTrue(pieces.allSatisfy { $0.hasSuffix("。") || $0.hasSuffix("、") }, "cut after a clause")
        // No punctuation at all: between characters.
        let run = String(repeating: "あいうえおかきくけこ", count: 200)
        let cut = MeetingAsk.splitLine("You: " + run, maxTokens: 100)
        XCTAssertTrue(cut.allSatisfy { $0.hasPrefix("You: ") && MeetingSummarizer.estimateTokens($0) <= 100 })
        XCTAssertEqual(cut.map { $0.dropFirst("You: ".count) }.joined(), run)
    }

    func testLongJapaneseMeetingStillGetsItsTranscriptInAsk() {
        // A long run per speaker, as `transcriptLines` makes of a meeting in Japanese.
        let lines = (0..<6).map { i in "\(i % 2 == 0 ? "You" : "Others"): 【\(i)】" + String(repeating: Self.japanese, count: 120) }
        let source = AskSource(id: "m", title: "リリース会議", date: Date(), transcript: lines.joined(separator: "\n"))
        let msgs = MeetingAsk.messages(question: "価格はいつ変わりますか？", history: [], sources: [source], userName: nil,
                                       contextTokens: 4096)
        XCTAssertLessThanOrEqual(tokens(msgs) + MeetingAsk.replyTokens(contextTokens: 4096), 4096 - 100)
        let material = msgs[1].content
        XCTAssertGreaterThan(MeetingSummarizer.estimateTokens(material), 2000, "most of the room goes to the transcript")
        XCTAssertTrue(material.contains("You: 【0】来週のリリース"), "the beginning")
        XCTAssertTrue(material.contains("\n…\n"))
        // A long earlier answer is cut, not emptied.
        let history = [MeetingAsk.Turn(question: "要点は？", answer: String(repeating: Self.japanese, count: 100))]
        let followUp = MeetingAsk.messages(question: "次は？", history: history, sources: [], userName: nil, contextTokens: 4096)
        XCTAssertTrue(followUp.contains { $0.role == .assistant && $0.content.hasPrefix("来週のリリース") && $0.content.hasSuffix("…") })
    }

    func testAnswerUsesTheGeneratorsContext() async throws {
        let gen = ScriptedGenerator(contextTokens: 4096, replies: [.success("<think>x</think> March. [Infra sync]")])
        let source = AskSource(id: "m", title: "Infra sync", date: Date(), transcript: transcript(minutes: 90))
        let answer = try await MeetingAsk.answer(question: "When?", history: [], sources: [source], userName: nil, generator: gen)
        XCTAssertEqual(answer, "March. [Infra sync]")
        XCTAssertEqual(gen.options.first?.maxTokens, 682)
        XCTAssertFalse(gen.options.first?.background ?? true)
        XCTAssertLessThanOrEqual(tokens(gen.prompts[0]) + 682, 4096 - 100)
    }
}

@MainActor
final class EngineHubTests: XCTestCase {
    func testAModelLoadedOnDemandStaysUntilTheModelChoiceChanges() {
        let key = "qwen3-4b|http://localhost:11434|", other = "llama-3b|http://localhost:11434|"
        func load(_ needsLLM: Bool, _ model: String, current: String?, onDemand: Bool, _ state: EngineHub.State = .ready("Q")) -> String? {
            EngineHub.generatorKeyToLoad(needsLLM: needsLLM, modelKey: model, currentKey: current, onDemand: onDemand, state: state)
        }
        // Loaded for Ask while nothing else needs it: an unrelated settings change keeps it.
        XCTAssertNil(load(false, key, current: key, onDemand: true))
        // Another model was chosen: unload; the next Ask loads the new one.
        XCTAssertEqual(load(false, other, current: key, onDemand: true), "off")
        // Loaded because formatting needed it, and formatting was turned off: unload.
        XCTAssertEqual(load(false, key, current: key, onDemand: false), "off")
        // Formatting turned on while the on-demand model is loaded: keep it.
        XCTAssertNil(load(true, key, current: key, onDemand: true))
        XCTAssertEqual(load(true, other, current: key, onDemand: true), other)
        XCTAssertNil(load(false, key, current: "off", onDemand: false, .disabled))
        // Failed loads are retried, or cleared when nothing needs the model.
        XCTAssertEqual(load(true, key, current: key, onDemand: false, .failed("x")), key)
        XCTAssertEqual(load(false, key, current: key, onDemand: true, .missingModel("Q")), "off")
    }

    // MARK: A model still in use (R4-3)

    final class FakeModel: TextGenerator, @unchecked Sendable {
        let displayName = "Fake model"
        func warmUp() async {}
        func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String { "" }
    }

    /// Counts the models loaded; a load can be held until `release()`.
    final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0, held = false, waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { lock.withLock { made } }
        init(held: Bool = false) { self.held = held }

        func load() async -> TextGenerator {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let go = lock.withLock { () -> Bool in
                    made += 1
                    if held { waiting.append(c) }
                    return !held
                }
                if go { c.resume() }
            }
            return FakeModel()
        }

        func release() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                held = false
                defer { waiting = [] }
                return waiting
            }
            all.forEach { $0.resume() }
        }
    }

    private func hub(_ loads: Loads) -> EngineHub {
        EngineHub(makeRecognizer: { _, _ in throw EngineHub.EngineError.missingModel("Speech") },
                  makeGenerator: { _, _, _ in await loads.load() }, releaseCheckInterval: 0.01)
    }

    private func settings(formatting: Bool) -> AppSettings {
        var s = AppSettings()
        s.cleanupLevel = formatting ? .light : .off
        s.commandModeEnabled = false
        s.scribeAutoSummarize = false
        return s
    }

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(2)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testAModelStillInUseIsUsedAgainRatherThanLoadedTwice() async throws {
        let loads = Loads()
        let hub = hub(loads)
        hub.configure(settings(formatting: true))
        let summary = try await hub.generatorLoadingIfNeeded() // a long summary holds the model
        await until { hub.languageState.isReady }
        hub.configure(settings(formatting: false))             // formatting is turned off meanwhile
        XCTAssertEqual(hub.languageState, .ready("Fake model"), "it is still loaded: Models doesn't say Off")
        let ask = try await hub.generatorLoadingIfNeeded()     // the next Ask
        XCTAssertTrue(ask === summary)
        hub.configure(settings(formatting: true))
        let dictation = try await hub.currentGenerator()
        XCTAssertTrue(dictation === summary)
        XCTAssertEqual(loads.count, 1)
    }

    func testModelsSaysOffOnceTheModelIsReleased() async throws {
        let loads = Loads()
        let hub = hub(loads)
        hub.configure(settings(formatting: true))
        var summary = try await hub.generatorLoadingIfNeeded()
        await until { hub.languageState.isReady }
        hub.configure(settings(formatting: false))
        XCTAssertEqual(hub.languageState, .ready("Fake model"))
        // Turned on again while the summary still holds it: the same copy.
        hub.configure(settings(formatting: true))
        let same = try await hub.currentGenerator() === summary
        XCTAssertTrue(same)
        hub.configure(settings(formatting: false))
        summary = nil // the summary finished
        await until { hub.languageState == .disabled }
        XCTAssertEqual(hub.languageState, .disabled)
        XCTAssertEqual(loads.count, 1)
        _ = try await hub.generatorLoadingIfNeeded() // released: the next Ask loads it again
        XCTAssertEqual(loads.count, 2)
    }

    func testALoadInFlightIsAwaitedRatherThanStartedAgain() async throws {
        let loads = Loads(held: true)
        let hub = hub(loads)
        hub.configure(settings(formatting: true)) // starts loading
        hub.configure(settings(formatting: false)) // turned off before it finished
        XCTAssertEqual(hub.languageState, .disabled)
        let ask = Task { try await hub.generatorLoadingIfNeeded() }
        await until { if case .loading = hub.languageState { return true }; return false }
        loads.release()
        let model = try await ask.value
        XCTAssertNotNil(model)
        await until { hub.languageState.isReady }
        XCTAssertEqual(hub.languageState, .ready("Fake model"))
        XCTAssertEqual(loads.count, 1)
    }
}
