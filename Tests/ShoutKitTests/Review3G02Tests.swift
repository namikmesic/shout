import XCTest
import AVFoundation
@testable import ShoutKit
import ShoutASR
import ShoutLLM

/// Speech and language engines: reasoning tags, yielding background work, local-only servers,
/// Apple Speech audio and superseded speech-model loads.
final class Review3G02Tests: XCTestCase {

    // MARK: Thinking tags

    func testThinkingIsStrippedAlsoWhenTheTemplateOpenedIt() {
        XCTAssertEqual("<think>plan</think>\n\nHello.".strippingThinking(), "Hello.")
        // The opening tag was part of the prompt: only the end is in the reply.
        XCTAssertEqual("The user wants a greeting.\n</think>\n\nHello.".strippingThinking(openedInPrompt: true), "Hello.")
        XCTAssertEqual("plan</think>Hello <think>more</think>there.".strippingThinking(openedInPrompt: true), "Hello there.")
        // Otherwise a lone closing tag is text (a Command Mode selection of this very code, say).
        XCTAssertEqual("if s.hasSuffix(\"</think>\") { trim() }".strippingThinking(), "if s.hasSuffix(\"</think>\") { trim() }")
        XCTAssertTrue("<|im_start|>assistant\n<think>\n".leavesThinkingOpen)
        XCTAssertFalse("<|im_start|>assistant\n<think>\n\n</think>\n\n".leavesThinkingOpen)
        XCTAssertFalse("<|im_start|>assistant\n".leavesThinkingOpen)
        XCTAssertEqual("Hello.".strippingThinking(), "Hello.")
        // Cut off while thinking: there is no answer.
        XCTAssertEqual("<think>still thinking".strippingThinking(), "")
    }

    // MARK: YieldingGenerator

    final class Counting: TextGenerator, @unchecked Sendable {
        let displayName = "Fake"
        private let lock = NSLock()
        private var n = 0
        var calls: Int { lock.withLock { n } }
        func warmUp() async {}
        func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
            lock.withLock { n += 1 }
            return "done"
        }
    }

    func testACancelledRequestDoesNotStartTheModel() async {
        let base = Counting()
        let g = YieldingGenerator(base, retryDelay: 0.01) { false }
        let task = Task { () async throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await g.generate([ChatMessage(.user, "hi")], options: GenerationOptions())
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled request returned")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(base.calls, 0)
    }

    // MARK: Local servers only

    func testOnlyHttpURLsOfThisMacAreAccepted() {
        for s in ["http://localhost:11434", "http://LOCALHOST:11434/", "http://localhost.:11434", "https://127.0.0.1:1234",
                  "http://[::1]:11434"] {
            XCTAssertTrue(OpenAICompatibleGenerator.isOnThisMac(URL(string: s)), s)
        }
        for s in ["http://example.com:11434", "http://localhost.example.com", "http://127.0.0.1.example.com",
                  "file://localhost/etc/hosts", "ftp://localhost/", "localhost:11434", "http://10.0.0.2:11434"] {
            XCTAssertFalse(OpenAICompatibleGenerator.isOnThisMac(URL(string: s)), s)
        }
        XCTAssertThrowsError(try OpenAICompatibleGenerator(baseURL: URL(string: "https://example.com")!, model: "m"))
        XCTAssertNoThrow(try OpenAICompatibleGenerator(baseURL: URL(string: "http://LocalHost:11434")!, model: "m"))
    }

    func testModelsAreNotListedFromAnotherMachine() async {
        // 192.0.2.1 is a documentation address that never answers: a request would wait for its timeout, so an
        // immediate empty answer shows that none was made.
        let start = Date()
        let models = await OpenAICompatibleGenerator.listOllamaModels(baseURL: URL(string: "http://192.0.2.1:11434")!)
        XCTAssertEqual(models, [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "no request leaves this Mac")
    }

    // MARK: Apple Speech audio

    func testAppleSpeechAudioIsResampledAndEmptyAudioIsFine() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Apple Speech needs macOS 26") }
        let at48k = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1,
                                                interleaved: false))
        let tone = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        let out = try AppleSpeechEngine.makeBuffer(tone, format: at48k)
        XCTAssertEqual(Double(out.frameLength), 48_000, accuracy: 1_100)
        XCTAssertEqual(try AppleSpeechEngine.makeBuffer([], format: at48k).frameLength, 0)
    }
}

// MARK: Superseded speech-model loads

@MainActor
final class Review3G02EngineHubTests: XCTestCase {
    final class Recognizer: SpeechRecognizer, @unchecked Sendable {
        let displayName: String
        private let lock = NSLock()
        private var cancelled: Bool?
        /// Whether the load that made this engine was cancelled when it warmed up (nil: not warmed up yet).
        var warmedUpCancelled: Bool? { lock.withLock { cancelled } }
        init(_ name: String) { displayName = name }
        func warmUp() async { let c = Task.isCancelled; lock.withLock { cancelled = c } }
        func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptionResult {
            TranscriptionResult(text: "")
        }
    }

    /// Engines by model id; the first model's load is held until `release()`.
    final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var held = true, waiting: [CheckedContinuation<Void, Never>] = [], made: [String: Recognizer] = [:]
        let heldID: String
        init(holding id: String) { heldID = id }
        func engine(_ id: String) -> Recognizer? { lock.withLock { made[id] } }

        func load(_ model: ModelInfo) async -> SpeechRecognizer {
            if model.id == heldID {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let go = lock.withLock { () -> Bool in
                        if held { waiting.append(c) }
                        return !held
                    }
                    if go { c.resume() }
                }
            }
            let r = Recognizer(model.name)
            lock.withLock { made[model.id] = r }
            return r
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

    private func until(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(2)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testASupersededSpeechModelLoadSkipsItsWarmUp() async throws {
        var first = AppSettings(), second = AppSettings()
        first.speechModelID = "whisper-small-q5"
        second.speechModelID = "parakeet-v3-q8"
        let loads = Loads(holding: first.speechModelID)
        let hub = EngineHub(makeRecognizer: { model, _ in await loads.load(model) },
                            makeGenerator: { _, _, _ in nil }, releaseCheckInterval: 0.01)
        hub.configure(first)  // still loading...
        hub.configure(second) // ...when another model is chosen
        await until { hub.speechState == .ready(second.speechModel.name) }
        XCTAssertEqual(hub.speechState, .ready(second.speechModel.name))
        loads.release()
        await until { loads.engine(first.speechModelID)?.warmedUpCancelled != nil }
        XCTAssertEqual(loads.engine(first.speechModelID)?.warmedUpCancelled, true)
        XCTAssertEqual(loads.engine(second.speechModelID)?.warmedUpCancelled, false)
        XCTAssertEqual(hub.speechState, .ready(second.speechModel.name), "the superseded load doesn't take over")
    }
}
