import XCTest
@testable import ShoutKit
import ShoutLLM

/// Replies with a fixed text and records every call.
private final class ReplyingGenerator: TextGenerator, @unchecked Sendable {
    let displayName = "Replying"
    let contextTokens: Int
    let reply: String
    private let lock = NSLock()
    private var _calls: [([ChatMessage], GenerationOptions)] = []
    var calls: [([ChatMessage], GenerationOptions)] { lock.withLock { _calls } }

    init(reply: String, contextTokens: Int = 8192) { self.reply = reply; self.contextTokens = contextTokens }
    func warmUp() async {}
    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        lock.withLock { _calls.append((messages, options)) }
        return reply
    }
}

final class PromptModePipelineTests: XCTestCase {
    private func input(selection: String? = nil, settings: AppSettings = AppSettings(), vocabulary: [String] = []) -> PipelineInput {
        let ctx = DictationContext(appName: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", windowTitle: "Shout — DictionaryView.swift",
                                   selectedText: selection)
        let dictionary = vocabulary.enumerated().map {
            DictionaryEntry(id: Int64($0.offset + 1), phrase: $0.element, replacement: nil, isSnippet: false, isStarred: false,
                            source: .manual, observedAs: nil, useCount: 0, createdAt: Date())
        }
        return PipelineInput(samples: [], context: ctx, settings: settings, dictionary: dictionary)
    }

    func testMessagesCarryTheWordsAndSpellingsButNotTheApp() {
        let msgs = PromptBuilder.promptMessages(spoken: "make the add button open a modal", material: nil, vocabulary: ["Shout"])
        XCTAssertEqual(msgs.count, 2)
        XCTAssertFalse(msgs[0].content.contains("Domain:"), "no domain packs")
        XCTAssertTrue(msgs[0].content.contains("keep error messages, code and names exactly as said"))
        XCTAssertTrue(msgs[0].content.contains("Keep the user's words, order, meaning and voice"))
        XCTAssertFalse(msgs[0].content.contains("## "), "no section template")
        XCTAssertTrue(msgs[1].content.contains("<spoken>\nmake the add button open a modal\n</spoken>"))
        XCTAssertTrue(msgs[1].content.contains("Shout"))
        // Small models took the app for the subject of the request.
        XCTAssertFalse(msgs[1].content.contains("Cursor"))
        XCTAssertFalse(msgs[1].content.contains("DictionaryView"))

        let withSelection = PromptBuilder.promptMessages(spoken: "", material: "group history by day", vocabulary: [])
        XCTAssertTrue(withSelection[1].content.contains("<material>\ngroup history by day\n</material>"))
        XCTAssertFalse(withSelection[1].content.contains("<spoken>"))
        XCTAssertTrue(withSelection[1].content.hasSuffix("Clean up <material> the same way."))
    }

    func testCleanPromptTidiesSmallModelHabits() {
        let reply = """
        ```markdown
        Here is the prompt:
        ## Problem: one sentence.
        - The app crashes when recording starts.

        ## Context
        - Version: Not specified
        - Device: unknown

        ## Steps to reproduce
        1. Press record.


        2. It crashes.

        ## Open questions
        - None

        ## Rules
        7. Output only the cleaned message: no preamble, no notes, no code fence.
        ```
        """
        let instructions = PromptBuilder.promptSystem
        XCTAssertEqual(PromptBuilder.cleanPrompt(reply, instructions: instructions), """
        ## Problem
        - The app crashes when recording starts.

        ## Steps to reproduce
        1. Press record.

        2. It crashes.
        """)
    }

    func testRunPromptTidiesTheReply() async throws {
        let gen = ReplyingGenerator(reply: "Sure, here's the prompt:\n## Goal:\n- Open a modal from the Add button.\n\n## Open questions\nN/A")
        let r = try await DictationPipeline.runPrompt(
            spoken: "um so the add button should uh open a modal instead of the inline text box on the page",
            input: input(vocabulary: ["Shout"]), generator: gen)
        XCTAssertEqual(r.text, "## Goal\n- Open a modal from the Add button.")
        let (msgs, options) = try XCTUnwrap(gen.calls.first)
        XCTAssertTrue(options.failIfTruncated, "a cut-off prompt is never pasted")
        XCTAssertEqual(options.temperature, 0)
        XCTAssertFalse(msgs[1].content.contains(" um "), "fillers are removed before the model sees the words")
        XCTAssertTrue(msgs[1].content.contains("<spelling>") && msgs[1].content.contains("Shout"),
                      "the user's Dictionary is the spelling reference")
    }

    func testRunPromptOnSelectedText() async throws {
        let gen = ReplyingGenerator(reply: "## Task\n- Write the announcement that the launch moves to Thursday.")
        let r = try await DictationPipeline.runPrompt(spoken: "", input: input(selection: "launch moves to thursday"), generator: gen)
        XCTAssertTrue(r.text.contains("Thursday"))
        XCTAssertTrue(gen.calls[0].0[1].content.contains("<material>\nlaunch moves to thursday\n</material>"))
    }

    func testRunPromptRefusesWhatItCantDo() async {
        func message(_ run: () async throws -> Void) async -> String? {
            do { try await run(); return nil } catch { return error.localizedDescription }
        }
        let noModel = await message { _ = try await DictationPipeline.runPrompt(spoken: "make a modal", input: self.input(), generator: nil) }
        XCTAssertEqual(noModel, "Prompt mode needs a language model. Choose one in Models.")

        let long = String(repeating: "a", count: PromptBuilder.maxCommandSelection + 1)
        let tooLong = await message {
            _ = try await DictationPipeline.runPrompt(spoken: "", input: self.input(selection: long), generator: ReplyingGenerator(reply: "x"))
        }
        XCTAssertEqual(tooLong, "The selection is too long to turn into a prompt. Select less text and try again.")

        let tinyContext = await message {
            _ = try await DictationPipeline.runPrompt(spoken: "make a modal", input: self.input(),
                                                      generator: ReplyingGenerator(reply: "x", contextTokens: 900))
        }
        XCTAssertEqual(tinyContext, "That's too long for the language model to turn into a prompt. Try a shorter description.")

        let empty = await message {
            _ = try await DictationPipeline.runPrompt(spoken: "make a modal", input: self.input(), generator: ReplyingGenerator(reply: "```\n```"))
        }
        XCTAssertNotNil(empty, "an empty prompt is an error, so the caller can paste the words instead")
    }

    /// History entry 51: "so this" (while a permission prompt was in the way) became a prompt about the spelling list.
    func testWordsWithoutARequestAreRefusedBeforeTheModel() async {
        let gen = ReplyingGenerator(reply: "## Goal\nUse these spellings for words that were actually used.")
        for words in ["so this", "okay um so yeah", "this one"] {
            do {
                _ = try await DictationPipeline.runPrompt(spoken: words, input: input(), generator: gen)
                XCTFail("\(words) made a prompt")
            } catch {
                XCTAssertEqual(error as? DictationPipeline.PromptModeError, .tooShort, words)
            }
        }
        XCTAssertTrue(gen.calls.isEmpty, "the model isn't asked")
        // A screenshot carries the rest: one word of request is enough.
        let shot = [PromptCapture(time: 1, path: "/tmp/s.png", source: .screenshot)]
        let ok = ReplyingGenerator(reply: "## Goal\n- Fix the layout (screenshot 1).")
        let r = try? await DictationPipeline.runPrompt(spoken: "fix this [screenshot 1]", input: input(), generator: ok,
                                                       captures: shot, anchors: ["fix this"])
        XCTAssertNotNil(r)
    }

    func testTheModelCanSayThereIsNoRequest() async {
        do {
            _ = try await DictationPipeline.runPrompt(spoken: "and then the other thing we said", input: input(),
                                                      generator: ReplyingGenerator(reply: "NO_REQUEST"))
            XCTFail("pasted")
        } catch {
            XCTAssertEqual(error as? DictationPipeline.PromptModeError, .tooShort)
        }
    }

    func testAPromptAboutSomethingElseIsRejected() async {
        let gen = ReplyingGenerator(reply: "## Goal\n- Use these spellings for words that were actually used.\n\n## Requirements\n- Keep exact spellings.")
        do {
            _ = try await DictationPipeline.runPrompt(spoken: "make the add button open a modal dialog", input: input(), generator: gen)
            XCTFail("a prompt sharing no words with what was said was pasted")
        } catch {
            XCTAssertNotEqual(error as? DictationPipeline.PromptModeError, .tooShort, "a model failure: the words are pasted instead")
        }
    }

    func testCopiedBoilerplateIsDropped() {
        let msgs = PromptBuilder.promptMessages(spoken: "make the add button open a modal", material: nil, vocabulary: ["modal"])
        let reply = "## Goal\n- Open a modal from the add button.\n\n## Notes\nUse these spellings for words that were actually used: modal"
        let cleaned = PromptBuilder.cleanPrompt(reply, instructions: PromptBuilder.boilerplate(msgs))
        XCTAssertEqual(cleaned, "## Goal\n- Open a modal from the add button.")
    }

}

final class PromptModeSettingsTests: XCTestCase {
    func testOldSettingsGetPromptModeDefaults() throws {
        let old = try JSONEncoder().encode(["pushToTalk": KeyCombo.defaultPushToTalk])
        let s = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertTrue(s.promptModeEnabled)
        XCTAssertEqual(s.promptShortcut, KeyCombo.defaultPrompt)
    }

    func testPromptSettingsRoundTrip() throws {
        var s = AppSettings()
        s.promptShortcut = KeyCombo([KeyCombo.Key.rightOption])
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.promptShortcut, s.promptShortcut)
    }

    /// Screenshots need a model that names what they point at and keeps the user's words; others gray the switch out.
    func testScreenshotsNeedACapableModel() {
        var s = AppSettings()
        XCTAssertTrue(s.promptScreenshotsAvailable, "the default Qwen3 4B Instruct handles them")
        XCTAssertTrue(s.promptScreenshotsOn)
        for id in ["qwen3.5-2b-q4", "apple-intelligence", "ollama"] {
            s.languageModelID = id
            XCTAssertFalse(s.promptScreenshotsAvailable, id)
            XCTAssertFalse(s.promptScreenshotsOn, "\(id): off while the switch stays on")
            XCTAssertTrue(s.promptScreenshots, "the user's choice is kept")
        }
        for id in ["qwen3.5-4b-q4", "qwen3.5-9b-q4"] {
            s.languageModelID = id
            XCTAssertTrue(s.promptScreenshotsOn, id)
        }
        s.promptScreenshots = false
        XCTAssertFalse(s.promptScreenshotsOn)
    }

    func testPromptShortcutBuildsOnPushToTalkLikeCommandMode() {
        let s = AppSettings()
        XCTAssertNil(s.shortcutConflict(KeyCombo.defaultPrompt, for: .prompt), "fn+⇧ extends fn, like fn+⌃")
        XCTAssertEqual(s.shortcutConflict(KeyCombo.defaultCommand, for: .prompt), .command)
        XCTAssertEqual(s.shortcutConflict(KeyCombo.defaultPrompt, for: .command), .prompt)
        XCTAssertEqual(s[shortcut: .prompt], KeyCombo.defaultPrompt)
        XCTAssertEqual(ShortcutSlot.prompt.title, "Prompt mode")
    }
}
