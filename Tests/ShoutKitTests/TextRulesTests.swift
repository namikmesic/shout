import XCTest
@testable import ShoutKit

final class TextRulesTests: XCTestCase {
    func entry(_ id: Int64, _ phrase: String, _ replacement: String? = nil, snippet: Bool = false) -> DictionaryEntry {
        DictionaryEntry(id: id, phrase: phrase, replacement: replacement, isSnippet: snippet, isStarred: false,
                        source: .manual, observedAs: nil, useCount: 0, createdAt: Date())
    }

    // MARK: Fit to cursor

    func testContinuingSentenceLowercasesCommonWordAndAddsSpace() {
        let out = TextRules.fitToCursor("And the second reason is cost.", before: "The first is speed,", after: "")
        XCTAssertEqual(out, " and the second reason is cost.")
    }

    func testProperNounStaysCapitalizedMidSentence() {
        XCTAssertEqual(TextRules.fitToCursor("Priya agreed.", before: "Yesterday", after: nil), " Priya agreed.")
    }

    func testNewSentenceKeepsCapital() {
        XCTAssertEqual(TextRules.fitToCursor("We shipped it.", before: "Done. ", after: nil), "We shipped it.")
    }

    func testTextAfterCursorDropsFinalPeriodAndAddsTrailingSpace() {
        XCTAssertEqual(TextRules.fitToCursor("really fast.", before: "It was ", after: "and cheap"), "really fast ")
    }

    func testNoContextLeavesTextAlone() {
        XCTAssertEqual(TextRules.fitToCursor("Hello there.", before: nil, after: nil), "Hello there.")
    }

    func testNoLeadingSpaceAfterOpeningParenOrBeforePunctuation() {
        XCTAssertEqual(TextRules.fitToCursor("for example", before: "(", after: ")"), "for example")
        XCTAssertEqual(TextRules.fitToCursor(", right?", before: "Okay", after: nil), ", right?")
    }

    // MARK: Snippets & replacements

    func testExactSnippetMatchesIgnoringCaseAndPunctuation() {
        let s = entry(1, "my calendly link", "https://cal.example/me", snippet: true)
        XCTAssertEqual(TextRules.exactSnippet("My Calendly link.", snippets: [s])?.id, 1)
        XCTAssertNil(TextRules.exactSnippet("Here's my Calendly link.", snippets: [s]))
    }

    func testInlineReplacementPrefersLongerPhrase() {
        let entries = [entry(1, "email", "E-MAIL"), entry(2, "my work email", "me@work.example")]
        let (out, used) = TextRules.applyReplacements("Send it to my work email please", entries: entries)
        XCTAssertEqual(out, "Send it to me@work.example please")
        XCTAssertEqual(used, [2])
    }

    func testReplacementRespectsWordBoundaries() {
        let (out, _) = TextRules.applyReplacements("The btwn value and btw that", entries: [entry(1, "btw", "by the way")])
        XCTAssertEqual(out, "The btwn value and by the way that")
    }

    func testVocabularyFixesCasingOfMultiWordTerm() {
        let (out, used) = TextRules.applyVocabulary("ask chat gpt and kubernetes", words: [entry(1, "Kubernetes"), entry(2, "ChatGPT")])
        XCTAssertEqual(out, "ask chat gpt and Kubernetes") // "chat gpt" is two words, ChatGPT is one: no match
        XCTAssertEqual(used, [1])
        let (out2, _) = TextRules.applyVocabulary("use new relic today", words: [entry(3, "New Relic")])
        XCTAssertEqual(out2, "use New Relic today")
    }

    // MARK: Voice commands, tone, artefacts

    func testPressEnterCommandIsExtracted() {
        let (t, enter) = TextRules.extractPressEnter("Sounds good, see you then. Press enter.")
        XCTAssertTrue(enter)
        XCTAssertEqual(t, "Sounds good, see you then.")
        XCTAssertFalse(TextRules.extractPressEnter("Please press the enter key gently").1)
    }

    func testCasualToneDropsFinalPeriodOnly() {
        XCTAssertEqual(TextRules.applyTone("See you at 5 p.m.", tone: .casual, category: .personalMessaging), "See you at 5 p.m.")
        XCTAssertEqual(TextRules.applyTone("See you soon.", tone: .casual, category: .personalMessaging), "See you soon")
        XCTAssertEqual(TextRules.applyTone("Wait... what?", tone: .casual, category: .personalMessaging), "Wait... what?")
    }

    func testVeryCasualLowercasesSentenceStartsButKeepsI() {
        let out = TextRules.applyTone("Sure. I can do 12. NASA called.", tone: .veryCasual, category: .personalMessaging)
        XCTAssertEqual(out, "sure. I can do 12. NASA called")
    }

    func testToneIsNotAppliedInTerminals() {
        XCTAssertEqual(TextRules.applyTone("Run make.", tone: .veryCasual, category: .terminal), "Run make.")
    }

    func testSilenceHallucinationsAreDropped() {
        XCTAssertEqual(TextRules.cleanASRArtifacts("Thank you.", speechSeconds: 0.2), "")
        XCTAssertEqual(TextRules.cleanASRArtifacts("Thank you.", speechSeconds: 3.0), "Thank you.")
        XCTAssertEqual(TextRules.cleanASRArtifacts("[Music] Hello there (laughs)", speechSeconds: 2), "Hello there")
    }

    func testRemoveFillers() {
        XCTAssertEqual(TextRules.removeFillers("Um, so, uh, we should ship it."), "So, we should ship it.")
        XCTAssertEqual(TextRules.removeFillers("Umbrella sales are up."), "Umbrella sales are up.")
    }

    func testWordCount() {
        XCTAssertEqual(TextRules.wordCount("Hi John,\n\nThanks for the update."), 6)
    }
}

final class EditLearnerTests: XCTestCase {
    func testLearnsMisheardName() {
        let c = EditLearner.candidates(original: "Thanks Wakeen, see you tomorrow.", edited: "Thanks Joaquin, see you tomorrow.", known: [])
        XCTAssertEqual(c, [EditLearner.Candidate(heard: "Wakeen", corrected: "Joaquin")])
    }

    func testLearnsCasingOfBrand() {
        let c = EditLearner.candidates(original: "deploy to kubernetes now", edited: "deploy to Kubernetes now", known: [])
        XCTAssertEqual(c.map(\.corrected), ["Kubernetes"])
    }

    func testSentenceStartCapitalisationIsNotLearned() {
        XCTAssertTrue(EditLearner.candidates(original: "great work today", edited: "Great work today", known: []).isEmpty)
    }

    func testIgnoresStopwordsContractionsAndKnownWords() {
        XCTAssertTrue(EditLearner.candidates(original: "I do not know", edited: "I don't know", known: []).isEmpty)
        XCTAssertTrue(EditLearner.candidates(original: "send it to the team", edited: "send it to a team", known: []).isEmpty)
        XCTAssertTrue(EditLearner.candidates(original: "ping Wakeen", edited: "ping Joaquin", known: ["joaquin"]).isEmpty)
    }

    func testIgnoresUnrelatedRewrites() {
        let c = EditLearner.candidates(original: "the meeting is on Tuesday", edited: "the meeting is on Friday", known: [])
        XCTAssertTrue(c.isEmpty, "Tuesday→Friday is a content change, not a misrecognition")
    }
}

final class ClassificationAndPromptTests: XCTestCase {
    func testClassifiesByBundleAndURL() {
        XCTAssertEqual(AppCategory.classify(bundleID: "com.tinyspeck.slackmacgap", url: nil), .workMessaging)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.google.Chrome", url: "https://mail.google.com/mail/u/0"), .email)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.apple.Safari", url: "https://claude.ai/new"), .chatbot)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.jetbrains.intellij", url: nil), .developer)
        XCTAssertEqual(AppCategory.classify(bundleID: "com.unknown.app", url: nil), .other)
    }

    func testSuspiciousCleanupDetectsAnswersAndPreambles() {
        XCTAssertTrue(PromptBuilder.isSuspiciousCleanup(input: "what is the capital of france",
                                                        output: "The capital of France is Paris, a city known for the Eiffel Tower and its museums.",
                                                        level: .light))
        XCTAssertTrue(PromptBuilder.isSuspiciousCleanup(input: "send the report today please",
                                                        output: "Sure, here is the cleaned text: Send the report today, please.", level: .light))
        XCTAssertFalse(PromptBuilder.isSuspiciousCleanup(input: "um send the report uh today please",
                                                         output: "Send the report today, please.", level: .light))
    }

    func testSalvageKeepsLeadingParagraph() {
        let out = PromptBuilder.salvage(output: "And the second reason is cost.\n\nBy the way, Priya and Joaquin recommended Kubernetes for the whole team next quarter.",
                                        input: "And the second reason is cost.", level: .light)
        XCTAssertEqual(out, "And the second reason is cost.")
    }

    func testCleanupPromptPrefixIsStableAcrossDictations() {
        let ctxA = DictationContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap")
        let ctxB = DictationContext(appName: "Mail", bundleID: "com.apple.mail", textBefore: "Hi")
        let a = PromptBuilder.cleanupMessages(transcript: "one", context: ctxA, level: .light, tone: .casual, vocabulary: [], useContext: true)
        let b = PromptBuilder.cleanupMessages(transcript: "two", context: ctxB, level: .high, tone: .formal, vocabulary: ["X"], useContext: true)
        // Everything except the final user turn must be identical so the KV cache can be reused.
        XCTAssertEqual(Array(a.dropLast()), Array(b.dropLast()))
        XCTAssertTrue(b.last!.content.contains("<transcript>\ntwo\n</transcript>"))
    }
}

final class SettingsAndKeysTests: XCTestCase {
    func testSettingsDecodeToleratesMissingAndUnknownKeys() throws {
        let json = #"{"cleanupLevel":"high","soundsEnabled":false,"someFutureKey":123}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.cleanupLevel, .high)
        XCTAssertFalse(s.soundsEnabled)
        XCTAssertEqual(s.pushToTalk, KeyCombo.defaultPushToTalk)
        XCTAssertEqual(s.speechModelID, ModelCatalog.defaultSpeechModelID)
    }

    func testSettingsRoundTrip() throws {
        var s = AppSettings()
        s.tones[.email] = .excited
        s.appOverrides = [AppOverride(bundleID: "com.apple.Terminal", appName: "Terminal", mode: .noAI)]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.override(for: "com.apple.Terminal"), .noAI)
    }

    func testForcedLanguage() {
        var s = AppSettings()
        s.languages = ["de"]; XCTAssertEqual(s.forcedLanguage, "de")
        s.languages = ["de", "en"]; XCTAssertNil(s.forcedLanguage)
        s.languages = []; XCTAssertNil(s.forcedLanguage)
    }

    func testKeyComboDisplay() {
        XCTAssertEqual(KeyCombo.defaultHandsFree.displayString, "fn + Space")
        XCTAssertEqual(KeyCombo.defaultCommand.displayString, "fn + ⌃")
        XCTAssertEqual(KeyCombo([KeyCombo.Key.rightOption]).displayString, "Right ⌥")
        XCTAssertTrue(KeyCombo.defaultPushToTalk.isModifierOnly)
    }

    func testCatalogIntegrity() {
        let ids = ModelCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        for m in ModelCatalog.all where m.isDownloadable {
            XCTAssertEqual(m.sha256?.count, 64, m.id)
            XCTAssertNotNil(m.fileName, m.id)
            XCTAssertGreaterThan(m.sizeBytes, 0, m.id)
        }
        XCTAssertNotNil(ModelCatalog.model(id: ModelCatalog.defaultSpeechModelID))
        XCTAssertNotNil(ModelCatalog.model(id: ModelCatalog.defaultLanguageModelID))
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func makeStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("shout-test-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    func testHistoryStatsAndSearch() throws {
        let store = try makeStore()
        for (i, text) in ["Hello world from Shout", "Second dictation here"].enumerated() {
            store.addHistory(HistoryEntry(id: 0, createdAt: Date(), mode: .dictation, status: .inserted, rawText: text,
                                          finalText: text, appName: i == 0 ? "Slack" : "Notes", audioSeconds: 6,
                                          asrSeconds: 0.1, llmSeconds: 0.5, totalSeconds: 0.7,
                                          wordCount: TextRules.wordCount(text)))
        }
        store.addHistory(HistoryEntry(id: 0, createdAt: Date(), mode: .dictation, status: .cancelled, rawText: "", finalText: "",
                                      audioSeconds: 1, asrSeconds: 0, llmSeconds: 0, totalSeconds: 0, wordCount: 0))
        let stats = store.stats()
        XCTAssertEqual(stats.totalWords, 7)
        XCTAssertEqual(stats.totalDictations, 2)
        XCTAssertEqual(stats.dayStreak, 1)
        XCTAssertEqual(stats.averageWPM, 35, accuracy: 0.01) // 7 words over 12 s of audio
        XCTAssertEqual(store.history(search: "shout").count, 1)
        XCTAssertEqual(store.lastInsertableEntry()?.finalText, "Second dictation here")
    }

    func testDictionaryUniquenessAndKinds() throws {
        let store = try makeStore()
        XCTAssertTrue(store.addDictionaryEntry(phrase: "Joaquin"))
        XCTAssertFalse(store.addDictionaryEntry(phrase: "joaquin"), "case-insensitive duplicate")
        XCTAssertTrue(store.addDictionaryEntry(phrase: "btw", replacement: "by the way"))
        XCTAssertTrue(store.addDictionaryEntry(phrase: "my link", replacement: "https://x.example", isSnippet: true))
        XCTAssertEqual(store.vocabulary.map(\.phrase), ["Joaquin"])
        XCTAssertEqual(store.replacements.map(\.phrase), ["btw"])
        XCTAssertEqual(store.snippets.map(\.phrase), ["my link"])
        XCTAssertTrue(store.vocabularyWords().contains("by the way"))
    }

    /// The edit form keeps itself open on a failed save, so the store must say when one didn't happen.
    func testDictionaryEditReportsDuplicatesAndTrims() throws {
        let store = try makeStore()
        XCTAssertTrue(store.addDictionaryEntry(phrase: "Joaquin"))
        XCTAssertTrue(store.addDictionaryEntry(phrase: "Priya"))
        XCTAssertTrue(store.addDictionaryEntry(phrase: "priya", isSnippet: true), "a snippet is another kind")
        var priya = try XCTUnwrap(store.vocabulary.first { $0.phrase == "Priya" })

        priya.phrase = "JOAQUIN"
        XCTAssertFalse(store.updateDictionaryEntry(priya), "case-insensitive duplicate of another word")
        priya.phrase = "   "
        XCTAssertFalse(store.updateDictionaryEntry(priya), "empty phrase")
        XCTAssertEqual(store.vocabulary.map(\.phrase).sorted(), ["Joaquin", "Priya"], "nothing changed")

        priya.phrase = "  Cooper Netties \n"
        priya.replacement = " Kubernetes "
        XCTAssertTrue(store.updateDictionaryEntry(priya))
        XCTAssertEqual(store.replacements.map(\.phrase), ["Cooper Netties"])
        XCTAssertEqual(store.replacements.first?.replacement, "Kubernetes")
        priya = try XCTUnwrap(store.replacements.first)
        priya.replacement = "  "
        XCTAssertTrue(store.updateDictionaryEntry(priya))
        XCTAssertEqual(store.vocabulary.map(\.phrase).sorted(), ["Cooper Netties", "Joaquin"], "a blank replacement makes it a plain word")
    }

    func testNotesCRUD() throws {
        let store = try makeStore()
        let id = store.addNote(title: "Ideas", body: "One")
        store.updateNote(id: id, title: "Ideas", body: "Two")
        XCTAssertEqual(store.notes.first?.body, "Two")
        store.deleteNote(id: id)
        XCTAssertTrue(store.notes.isEmpty)
    }
}

final class AudioDSPTests: XCTestCase {
    func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    func testSilenceDetection() {
        XCTAssertTrue(AudioDSP.isSilent([Float](repeating: 0, count: 16_000)))
        XCTAssertTrue(AudioDSP.isSilent(tone(seconds: 1, amplitude: 0.002)))
        let speechLike = [Float](repeating: 0, count: 8_000) + tone(seconds: 1, amplitude: 0.3) + [Float](repeating: 0, count: 8_000)
        XCTAssertFalse(AudioDSP.isSilent(speechLike))
    }

    func testTrimSilenceKeepsMargin() {
        let x = [Float](repeating: 0.0005, count: 32_000) + tone(seconds: 1, amplitude: 0.3) + [Float](repeating: 0.0005, count: 32_000)
        let trimmed = AudioDSP.trimSilence(x, margin: 0.25)
        XCTAssertLessThan(trimmed.count, x.count)
        XCTAssertGreaterThanOrEqual(trimmed.count, 16_000 + 4_000)
    }

    func testNormalizeBoostsQuietAudioOnly() {
        let quiet = tone(seconds: 0.5, amplitude: 0.1)
        XCTAssertEqual(AudioDSP.peak(AudioDSP.normalize(quiet)), 0.7, accuracy: 0.01)
        let loud = tone(seconds: 0.5, amplitude: 0.9)
        XCTAssertEqual(AudioDSP.normalize(loud), loud)
    }
}
