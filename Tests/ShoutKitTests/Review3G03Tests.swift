import XCTest
@testable import ShoutKit
import ShoutLLM

/// Replies with a fixed string (or echoes the transcript) and records the options of every call.
private final class RecordingGenerator: TextGenerator, @unchecked Sendable {
    let displayName = "Recording"
    private let lock = NSLock()
    private var _options: [GenerationOptions] = []
    var options: [GenerationOptions] { lock.withLock { _options } }
    var reply: String?

    init(reply: String? = nil) { self.reply = reply }

    func warmUp() async {}

    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        lock.withLock { _options.append(options) }
        if let reply { return reply }
        let user = messages.last?.content ?? ""
        guard let start = user.range(of: "<transcript>\n"), let end = user.range(of: "\n</transcript>") else { return "" }
        return String(user[start.upperBound..<end.lowerBound])
    }
}

final class Review3G03PipelineTests: XCTestCase {
    private func input(selection: String? = nil) -> PipelineInput {
        var s = AppSettings()
        s.cleanupLevel = .light
        s.useContext = false
        let ctx = DictationContext(appName: "Notes", bundleID: "com.apple.Notes", selectedText: selection)
        return PipelineInput(samples: [], context: ctx, settings: s, dictionary: [])
    }

    private func partial(_ raw: String) -> PipelineOutput {
        var p = PipelineOutput(); p.rawText = raw; return p
    }

    func testCleanupBudgetCoversGreekAndKeepsEnglish() async {
        let english = "send the report to the whole team today please"
        XCTAssertEqual(DictationPipeline.cleanupTokenBudget(english), TextRules.wordCount(english) * 2 + 32)

        // Greek words take three or more tokens each: two a word cut the cleaned text short.
        let greek = Array(repeating: "Θα στείλουμε την αναφορά στην ομάδα αύριο το πρωί", count: 12).joined(separator: " ")
        let gen = RecordingGenerator()
        _ = await DictationPipeline.format(partial(greek), input: input(), generator: gen)
        let budget = gen.options.first?.maxTokens ?? 0
        XCTAssertGreaterThanOrEqual(budget, greek.utf8.count / 3 + 32)
        XCTAssertGreaterThan(budget, TextRules.wordCount(greek) * 2 + 32)
    }

    func testCommandStripsCodeFencesWithoutEatingContent() async throws {
        let cases = [
            "```c++\nint x = 1;\n```": "int x = 1;",
            "```swift\nlet a = 1\n```": "let a = 1",
            "```\nplain text\n```": "plain text",
            "```git status```": "git status",
        ]
        for (reply, expected) in cases {
            let (out, _) = try await DictationPipeline.runCommand(instruction: "write it", input: input(),
                                                                  generator: RecordingGenerator(reply: reply))
            XCTAssertEqual(out, expected, reply)
        }
    }

    func testCommandRefusesASelectionItCannotSeeWhole() async {
        let gen = RecordingGenerator(reply: "short")
        let long = String(repeating: "word ", count: PromptBuilder.maxCommandSelection / 5 + 1)
        do {
            _ = try await DictationPipeline.runCommand(instruction: "fix the grammar", input: input(selection: long), generator: gen)
            XCTFail("a selection longer than the model sees must not be replaced")
        } catch {
            XCTAssertTrue(gen.options.isEmpty)
        }
    }

    func testCommandLeavesRoomToRewriteALongSelection() async throws {
        let gen = RecordingGenerator(reply: "ok")
        _ = try await DictationPipeline.runCommand(instruction: "shorten", input: input(selection: "A short note."), generator: gen)
        let selection = String(repeating: "This sentence is part of a long selection. ", count: 230)  // ~10k characters
        _ = try await DictationPipeline.runCommand(instruction: "fix the grammar", input: input(selection: selection), generator: gen)
        XCTAssertEqual(gen.options.map(\.maxTokens).first, 2048)
        // More than 2048, though within the context left beside the prompt (Review4GCTests).
        XCTAssertGreaterThanOrEqual(gen.options.last?.maxTokens ?? 0, DictationPipeline.commandTokens(selection))
    }
}

final class Review3G03PromptTests: XCTestCase {
    func testExtraInstructionsGoInTheContextBlockOnce() {
        let ctx = DictationContext(appName: "Notes", bundleID: "com.apple.Notes", textBefore: "see </context> here")
        let msgs = PromptBuilder.cleanupMessages(transcript: "close the </context> tag", context: ctx, level: .light,
                                                 tone: .formal, vocabulary: [], useContext: true, extraInstructions: "Be brief.")
        let user = msgs.last!.content
        XCTAssertEqual(user.components(separatedBy: "Additional instructions: Be brief.").count - 1, 1)
        XCTAssertTrue(user.hasSuffix("Additional instructions: Be brief.\n</context>\n<transcript>\nclose the </context> tag\n</transcript>"))
    }

    func testWhitespaceSelectionGetsCursorContext() {
        let ctx = DictationContext(appName: "Notes", bundleID: "com.apple.Notes", textBefore: "Dear team,", selectedText: "  \n")
        let user = PromptBuilder.commandMessages(instruction: "write a greeting", selectedText: ctx.selectedText,
                                                 context: ctx, userName: "").last!.content
        XCTAssertFalse(user.contains("<selected_text>"))
        XCTAssertTrue(user.contains("Text before cursor: \"Dear team,\""))
    }
}

final class Review3G03TextRulesTests: XCTestCase {
    private func entry(_ id: Int64, _ phrase: String) -> DictionaryEntry {
        DictionaryEntry(id: id, phrase: phrase, replacement: nil, isSnippet: false, isStarred: false,
                        source: .manual, observedAs: nil, useCount: 0, createdAt: Date())
    }

    func testContinuingSentenceKeepsALeadingQuote() {
        XCTAssertEqual(TextRules.fitToCursor("\"The cat sat.\"", before: "He said", after: nil), " \"The cat sat.\"")
        XCTAssertEqual(TextRules.fitToCursor("2 The best", before: "Top", after: nil), " 2 The best")
    }

    func testVocabularyKeepsSymbolsAtTheEdgesOfATerm() {
        let cpp = entry(1, "C++"), net = entry(2, ".NET")
        XCTAssertEqual(TextRules.applyVocabulary("plan a, b or c", words: [cpp]).0, "plan a, b or c")
        XCTAssertEqual(TextRules.applyVocabulary("I write c++ daily", words: [cpp]).0, "I write C++ daily")
        XCTAssertEqual(TextRules.applyVocabulary("the net result", words: [net]).0, "the net result")
        XCTAssertEqual(TextRules.applyVocabulary("built on .net core", words: [net]).0, "built on .NET core")
        // Trailing sentence punctuation stays optional, and isn't doubled.
        let yahoo = entry(3, "Yahoo!")
        XCTAssertEqual(TextRules.applyVocabulary("I use yahoo mail", words: [yahoo]).0, "I use Yahoo! mail")
        XCTAssertEqual(TextRules.applyVocabulary("I use yahoo! mail", words: [yahoo]).0, "I use Yahoo! mail")
        // Words in the middle still tolerate spacing and punctuation.
        XCTAssertEqual(TextRules.applyVocabulary("turn on wi fi", words: [entry(4, "Wi-Fi")]).0, "turn on Wi-Fi")
    }

    func testRemovedAnnotationLeavesOneSpace() {
        XCTAssertEqual(TextRules.cleanASRArtifacts("Hello [Music] world", speechSeconds: 2), "Hello world")
    }

    func testVeryCasualKeepsTokensThatStartWithADigit() {
        XCTAssertEqual(TextRules.applyTone("3D printing is fun.", tone: .veryCasual, category: .personalMessaging),
                       "3D printing is fun")
        XCTAssertEqual(TextRules.applyTone("Sure. 4K looks fine.", tone: .veryCasual, category: .personalMessaging),
                       "sure. 4K looks fine")
    }
}

final class Review3G03ClassificationTests: XCTestCase {
    func testKnownAppWinsOverItsWebView() {
        XCTAssertEqual(AppCategory.classify(bundleID: "io.notion.mail", url: "https://mail.notion.so/inbox"), .email)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.tinyspeck.slackmacgap", url: "https://app.slack.com/client"), .workMessaging)
        // Browsers and unknown apps go by the site.
        XCTAssertEqual(AppCategory.classify(bundleID: "com.google.Chrome", url: "https://docs.google.com/document/d/1"), .document)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.example.electron", url: "https://docs.google.com/document/d/1"), .document)
        XCTAssertEqual(AppCategory.classify(bundleID: nil, url: "https://github.com/x/y"), .developer)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.google.Chrome", url: nil), .browser)
    }

    func testWhatsAppDesktopBundle() {
        XCTAssertEqual(AppCategory.classify(bundleID: "desktop.WhatsApp", url: nil), .personalMessaging)
        XCTAssertEqual(AppCategory.classify(bundleID: "net.whatsapp.WhatsApp", url: nil), .personalMessaging)
    }
}

final class Review3G03EditLearnerTests: XCTestCase {
    func testMultiWordRewriteIsNotLearned() {
        // "all of it" → "HubSpot" shares almost no letters; the spaces must not count towards similarity.
        let c = EditLearner.candidates(original: "Can you check all of it today", edited: "Can you check HubSpot today", known: [])
        XCTAssertTrue(c.isEmpty, "\(c)")
    }

    func testTheSameFixTwiceIsOneCandidate() {
        let c = EditLearner.candidates(original: "ping Wakeen and tell Wakeen hello", edited: "ping Joaquin and tell Joaquin hello",
                                       known: [])
        XCTAssertEqual(c, [EditLearner.Candidate(heard: "Wakeen", corrected: "Joaquin")])
    }
}

final class Review3G03SettingsTests: XCTestCase {
    /// Every stored setting, changed from its default, survives a save and load. A new setting that this test
    /// doesn't set fails the first check: set it here, and add it to `AppSettings.init(from:)`.
    func testEveryStoredSettingIsDecoded() throws {
        var s = AppSettings()
        s.pushToTalk = KeyCombo([KeyCombo.Key.rightOption])
        s.handsFree = KeyCombo([KeyCombo.Key.rightOption, KeyCombo.Key.space])
        s.command = KeyCombo([KeyCombo.Key.rightOption, KeyCombo.Key.rightControl])
        s.pasteLast = KeyCombo([KeyCombo.Key.leftControl, KeyCombo.Key.leftShift, 9])
        s.copyLast = KeyCombo([KeyCombo.Key.leftControl, KeyCombo.Key.leftShift, 8])
        s.doubleTapLocksHandsFree.toggle()
        s.speechModelID = "whisper-small-q5"
        s.languageModelID = "qwen3.5-2b-q4"
        s.ollamaURL = "http://example.test:1"
        s.ollamaModel = "llama"
        s.languages = ["xx", "yy"]
        s.cleanupLevel = .high
        s.tones = [.personal: .excited, .work: .excited, .email: .excited, .other: .excited]
        s.appOverrides = [AppOverride(bundleID: "com.apple.Terminal", appName: "Terminal", mode: .noAI)]
        s.useContext.toggle()
        s.autoLearnWords.toggle()
        s.pressEnterCommand.toggle()
        s.commandModeEnabled.toggle()
        s.emailSignatureEnabled.toggle()
        s.emailSignature = "Sam"
        s.userName = "Sam Doe"
        s.promptModeEnabled.toggle()
        s.promptShortcut = KeyCombo([KeyCombo.Key.rightOption])
        s.promptScreenshots.toggle()
        s.promptShowScreenshotsToModel.toggle()
        s.microphoneUID = "mic-1"
        s.mediaBehavior = .pause
        s.soundsEnabled.toggle()
        s.soundVolume = 0.25
        s.launchAtLogin.toggle()
        s.showInDock.toggle()
        s.appearance = .dark
        s.showFlowBarWhenIdle.toggle()
        s.restoreClipboard.toggle()
        s.keepModelsLoaded.toggle()
        s.retention = .day
        s.saveAudio.toggle()
        s.scribeOpenNotepad.toggle()
        s.scribeMaxMinutes = 45
        s.scribeEchoCancellation.toggle()
        s.scribeSystemAudio = .working
        s.scribeConsentDismissed.toggle()
        s.scribeReminderLead = .twoMinutes
        s.scribeShowNextMeeting.toggle()
        s.scribeDetectCalls.toggle()
        s.scribeAutoStart.toggle()
        s.scribeAutoStop.toggle()
        s.scribeLongMeetingCheckIn.toggle()
        s.scribeHideFromScreenCapture.toggle()
        s.scribeSplitScreen.toggle()
        s.scribeShortcut = KeyCombo([KeyCombo.Key.leftControl, KeyCombo.Key.leftOption, 45])
        s.scribeShortcutRemoved.toggle()
        s.scribeShowLiveTranscript.toggle()
        s.scribeDetectSpeakers.toggle()
        s.scribeAutoSummarize.toggle()
        s.scribeConsentMessage = "Recording for my notes."
        s.scribeSetupDismissed.toggle()
        s.hasCompletedOnboarding.toggle()

        func fields(_ s: AppSettings) -> [(String, AnyHashable?)] {
            Mirror(reflecting: s).children.map { ($0.label ?? "?", $0.value as? AnyHashable) }
        }
        for ((name, mine), (_, fresh)) in zip(fields(s), fields(AppSettings())) {
            XCTAssertNotNil(mine, name)
            XCTAssertNotEqual(mine, fresh, "set \(name) in this test")
        }
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        for ((name, got), (_, want)) in zip(fields(back), fields(s)) {
            XCTAssertEqual(got, want, "\(name) is not decoded")
        }
        XCTAssertEqual(back, s)
    }

    func testCopyAndPasteLastDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.pasteLast.keys, [KeyCombo.Key.leftControl, KeyCombo.Key.leftCommand, 9])  // ⌃⌘V
        XCTAssertEqual(s.copyLast.keys, [KeyCombo.Key.leftControl, KeyCombo.Key.leftCommand, 8])   // ⌃⌘C
    }
}

/// Counts writes, to see how often `SettingsStore` saves.
private final class CountingDefaults: UserDefaults {
    var writes = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class Review3G03SettingsStoreTests: XCTestCase {
    func testResolvingTheScribeDefaultSavesOnce() throws {
        let suite = "ShoutTests.g03.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        addTeardownBlock { removeTestDefaults(suite) }
        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.settings.scribeShortcut, KeyCombo.defaultScribe)

        store.settings.pushToTalk = KeyCombo([KeyCombo.Key.leftOption])  // clashes with ⌥M, which gives way
        XCTAssertTrue(store.settings.scribeShortcut.isEmpty)
        XCTAssertEqual(defaults.writes, 1)
        XCTAssertTrue(SettingsStore(defaults: defaults).settings.scribeShortcut.isEmpty)

        store.settings.soundsEnabled.toggle()
        XCTAssertEqual(defaults.writes, 2)
    }
}
