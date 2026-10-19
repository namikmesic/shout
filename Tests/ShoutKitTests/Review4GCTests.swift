import XCTest
@testable import ShoutKit
import ShoutLLM

/// Reports a given context size and records the messages and options of every call.
private final class SizedGenerator: TextGenerator, @unchecked Sendable {
    let displayName = "Sized"
    let contextTokens: Int
    private let lock = NSLock()
    private var _calls: [([ChatMessage], GenerationOptions)] = []
    var calls: [([ChatMessage], GenerationOptions)] { lock.withLock { _calls } }

    init(contextTokens: Int) { self.contextTokens = contextTokens }

    func warmUp() async {}

    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        lock.withLock { _calls.append((messages, options)) }
        return "rewritten"
    }
}

final class Review4GCCommandBudgetTests: XCTestCase {
    private let sentence = "This sentence is part of a long selection. "

    private func input(selection: String?, textBefore: String? = nil) -> PipelineInput {
        let ctx = DictationContext(appName: "Notes", bundleID: "com.apple.Notes", textBefore: textBefore, selectedText: selection)
        return PipelineInput(samples: [], context: ctx, settings: AppSettings(), dictionary: [])
    }

    private func promptTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + DictationPipeline.commandTokens($1.content) }
    }

    /// Under the character cap, a selection can still leave a 4096-token model (Ollama, Apple Intelligence) or
    /// token-heavy text no room for its rewrite: it is refused before generating, not replaced by a cut-off reply.
    func testSelectionWhoseRewriteCannotFitIsRefused() async {
        let english = String(repeating: sentence, count: 140)  // ~6,000 characters
        let cyrillic = String(repeating: "Это предложение — часть длинного выделения. ", count: 250)  // ~11,000
        for (selection, context) in [(english, 4096), (cyrillic, 8192)] {
            XCTAssertLessThanOrEqual(selection.count, PromptBuilder.maxCommandSelection)
            let gen = SizedGenerator(contextTokens: context)
            do {
                _ = try await DictationPipeline.runCommand(instruction: "fix the grammar", input: input(selection: selection),
                                                           generator: gen)
                XCTFail("a rewrite that can't fit the context must not replace the selection")
            } catch {
                XCTAssertTrue(gen.calls.isEmpty)
                XCTAssertTrue(error.localizedDescription.contains("too long"), error.localizedDescription)
            }
        }
    }

    /// The reply budget fits the context beside the prompt (an engine would shrink it silently) and holds a
    /// rewrite as long as the selection.
    func testReplyBudgetFitsTheContextBesideThePrompt() async throws {
        let cases: [(selection: String?, before: String?, context: Int)] = [
            (String(repeating: sentence, count: 20), nil, 4096),
            (String(repeating: sentence, count: 90), nil, 4096),
            (String(repeating: sentence, count: 230), nil, 8192),  // ~10,000 characters
            (String(repeating: sentence, count: 260), nil, 8192),  // ~11,200, about the most that fits
            (String(repeating: "Это предложение — часть длинного выделения. ", count: 90), nil, 8192),  // ~4,000
            // No selection: the text around the cursor goes in the prompt instead.
            (nil, String(repeating: "会议纪要已经发给大家了。", count: 130), 4096),
        ]
        for c in cases {
            let gen = SizedGenerator(contextTokens: c.context)
            _ = try await DictationPipeline.runCommand(instruction: "fix the grammar",
                                                       input: input(selection: c.selection, textBefore: c.before), generator: gen)
            let (msgs, opts) = try XCTUnwrap(gen.calls.first)
            XCTAssertLessThanOrEqual(promptTokens(msgs) + opts.maxTokens + DictationPipeline.commandReserveTokens, c.context)
            XCTAssertGreaterThanOrEqual(opts.maxTokens, DictationPipeline.commandTokens(c.selection ?? ""))
            XCTAssertLessThanOrEqual(opts.maxTokens, max(2048, (c.selection ?? "").utf8.count / 2 + 256))
        }
    }
}

/// Cuts every reply off at its limit, like a model that would have written more.
private final class TruncatingGenerator: TextGenerator, @unchecked Sendable {
    let displayName = "Truncating"
    let contextTokens = 8192
    private let lock = NSLock()
    private var _options: [GenerationOptions] = []
    var options: [GenerationOptions] { lock.withLock { _options } }

    func warmUp() async {}

    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        lock.withLock { _options.append(options) }
        if options.failIfTruncated { throw TextGeneratorError.truncated }
        return "a rewrite cut off half way"
    }
}

final class Review4GCTruncationTests: XCTestCase {
    /// A reply that hits its limit (an expansion or translation much longer than the selection) is an error, so
    /// nothing replaces the selection.
    func testCommandModeFailsInsteadOfPastingACutOffReply() async {
        let gen = TruncatingGenerator()
        let ctx = DictationContext(appName: "Notes", bundleID: "com.apple.Notes", selectedText: "Short note.")
        let input = PipelineInput(samples: [], context: ctx, settings: AppSettings(), dictionary: [])
        do {
            _ = try await DictationPipeline.runCommand(instruction: "expand this into an essay", input: input, generator: gen)
            XCTFail("a cut-off reply must not be returned for pasting")
        } catch {
            XCTAssertEqual(error.localizedDescription, TextGeneratorError.truncated.localizedDescription)
        }
        XCTAssertEqual(gen.options.map(\.failIfTruncated), [true])
    }
}
