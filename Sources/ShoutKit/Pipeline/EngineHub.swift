import Foundation
import Combine
import ShoutASR
import ShoutLLM

/// Owns the loaded speech and language engines and swaps them when settings change.
@MainActor
public final class EngineHub: ObservableObject {
    public static let shared = EngineHub()

    public enum State: Equatable {
        case idle, loading(String), ready(String), missingModel(String), disabled, failed(String)
        public var isReady: Bool { if case .ready = self { return true }; return false }
        public var label: String {
            switch self {
            case .idle: "Not loaded"
            case .loading(let n): "Loading \(n)…"
            case .ready(let n): n
            case .missingModel(let n): "\(n) is not downloaded"
            case .disabled: "Off"
            case .failed(let e): e
            }
        }
    }

    @Published public private(set) var speechState: State = .idle
    @Published public private(set) var languageState: State = .idle

    private var recognizer: SpeechRecognizer?
    private var recognizerKey: String?
    private var recognizerTask: Task<SpeechRecognizer, Error>?

    private var generator: TextGenerator?
    private var generatorKey: String?
    private var generatorTask: Task<TextGenerator?, Error>?
    /// The generator was loaded on first use (Ask, summaries, titles) while no setting needs it.
    private var generatorOnDemand = false
    /// Every language model this hub loaded, by model key, held weakly. One that `configure` let go of can
    /// still be in use (a summary, an Ask answer or a title holds it until it finishes): loading that model
    /// again adopts it rather than loading a second copy, and Models shows it as loaded until it is released.
    private var loadedGenerators: [String: WeakGenerator] = [:]
    /// Loads in flight, by model key: asking for the same model again waits for the same load.
    private var generatorLoads: [String: Task<TextGenerator?, Error>] = [:]
    private var releaseWatch: Task<Void, Never>?

    typealias RecognizerFactory = @Sendable (ModelInfo, String?) async throws -> SpeechRecognizer
    typealias GeneratorFactory = @Sendable (ModelInfo, _ ollamaURL: String, _ ollamaModel: String) async throws -> TextGenerator?
    private let makeRecognizerEngine: RecognizerFactory
    private let makeGeneratorEngine: GeneratorFactory
    /// How often a released model is checked for, while one is still held after `configure` let it go.
    private let releaseCheckInterval: TimeInterval

    public convenience init() {
        self.init(makeRecognizer: { try await EngineHub.makeRecognizer($0, language: $1) },
                  makeGenerator: { try await EngineHub.makeGenerator($0, ollamaURL: $1, ollamaModel: $2) })
    }

    /// Tests pass engines of their own.
    init(makeRecognizer: @escaping RecognizerFactory, makeGenerator: @escaping GeneratorFactory,
         releaseCheckInterval: TimeInterval = 2) {
        makeRecognizerEngine = makeRecognizer
        makeGeneratorEngine = makeGenerator
        self.releaseCheckInterval = releaseCheckInterval
    }

    // MARK: Configuration

    private var lastSettings: AppSettings?

    public func configure(_ s: AppSettings) {
        lastSettings = s
        let sKey = s.speechModelID + "|" + (s.forcedLanguage ?? "auto")
        if sKey != recognizerKey || Self.needsRetry(speechState) { loadRecognizer(s, key: sKey) }
        let needsLLM = s.cleanupLevel != .off || s.commandModeEnabled || s.scribeAutoSummarize
        if let key = Self.generatorKeyToLoad(needsLLM: needsLLM, modelKey: Self.modelKey(s), currentKey: generatorKey,
                                             onDemand: generatorOnDemand, state: languageState) {
            loadGenerator(s, key: key)
        }
        if needsLLM { generatorOnDemand = false }
    }

    /// Identifies the chosen language model; "off" means none is loaded.
    static func modelKey(_ s: AppSettings) -> String { "\(s.languageModelID)|\(s.ollamaURL)|\(s.ollamaModel)" }

    /// The generator `configure` should load ("off" unloads it), or nil to keep the current one. A model
    /// loaded on demand stays while the model choice is the same: an unrelated settings change must not
    /// unload it (Models would say "Off" while a summary still holds it, and the next Ask would load a
    /// second copy).
    static func generatorKeyToLoad(needsLLM: Bool, modelKey: String, currentKey: String?, onDemand: Bool,
                                   state: State) -> String? {
        let retry = needsRetry(state)
        if !needsLLM && onDemand && currentKey == modelKey && !retry { return nil }
        let wanted = needsLLM ? modelKey : "off"
        return wanted != currentKey || retry ? wanted : nil
    }

    private static func needsRetry(_ state: State) -> Bool {
        switch state { case .missingModel, .failed: return true; default: return false }
    }

    public func unloadAll() {
        recognizer = nil; recognizerKey = nil; recognizerTask = nil; speechState = .idle
        generator = nil; generatorKey = nil; generatorTask = nil; languageState = .idle; generatorOnDemand = false
    }

    private func loadRecognizer(_ s: AppSettings, key: String) {
        recognizerKey = key
        recognizer = nil
        recognizerTask?.cancel() // superseded: its warm-up is skipped (whoever awaits it still gets the engine)
        let model = s.speechModel
        let lang = s.forcedLanguage
        speechState = .loading(model.name)
        let make = makeRecognizerEngine
        let task = Task<SpeechRecognizer, Error> {
            let engine = try await make(model, lang)
            await engine.warmUp()
            return engine
        }
        recognizerTask = task
        Task {
            do {
                let engine = try await task.value
                guard recognizerKey == key else { return }
                recognizer = engine
                speechState = .ready(model.name)
            } catch {
                guard recognizerKey == key else { return }
                speechState = Self.state(for: error, model: model)
            }
        }
    }

    /// Makes `key` the current language model ("off": none). A copy of that model that is still alive or
    /// still loading is used rather than loading another.
    private func loadGenerator(_ s: AppSettings, key: String) {
        generatorKey = key
        generator = nil
        generatorTask = nil // a finished load holds its engine
        generatorOnDemand = false
        guard key != "off" else { showReleasedGenerators(); return }
        let model = s.languageModel
        if let g = loadedGenerators[key]?.engine {
            generator = g
            languageState = .ready(g.displayName)
            return
        }
        languageState = .loading(model.name)
        if let loading = generatorLoads[key] { generatorTask = loading; return } // its completion below sets it
        let url = s.ollamaURL, ollamaModel = s.ollamaModel
        let make = makeGeneratorEngine
        let task = Task<TextGenerator?, Error> {
            let g = try await make(model, url, ollamaModel)
            await g?.warmUp()
            return g
        }
        generatorTask = task
        generatorLoads[key] = task
        Task {
            defer { generatorLoads[key] = nil }
            do {
                let g = try await task.value
                if let g { loadedGenerators[key] = WeakGenerator(g) }
                // No longer wanted: whoever waited for it may still use it (until then Models shows it).
                guard generatorKey == key else {
                    if generatorKey == "off" { watchReleasedGenerators() }
                    return
                }
                generator = g
                languageState = .ready(g?.displayName ?? model.name)
                primeCleanupCache(s)
            } catch {
                guard generatorKey == key else { return }
                languageState = Self.state(for: error, model: model)
            }
        }
    }

    /// With no model wanted, Models says "Off" only once nothing holds one any more: a model a summary or an
    /// answer still uses shows as loaded until it is released.
    private func showReleasedGenerators() {
        guard generatorKey == "off" else { return }
        loadedGenerators = loadedGenerators.filter { $0.value.engine != nil }
        if let g = loadedGenerators.sorted(by: { $0.key < $1.key }).lazy.compactMap({ $0.value.engine }).first {
            languageState = .ready(g.displayName)
            watchReleasedGenerators()
        } else {
            languageState = .disabled
        }
    }

    /// Checks every `releaseCheckInterval` until the models still held are released (or one is wanted again).
    private func watchReleasedGenerators() {
        guard releaseWatch == nil else { return }
        let interval = UInt64(releaseCheckInterval * 1e9)
        releaseWatch = Task { [weak self] in
            while true {
                do { try await Task.sleep(nanoseconds: interval) } catch { return }
                guard let self else { return }
                self.showReleasedGenerators()
                if self.generatorKey != "off" || self.loadedGenerators.isEmpty { self.releaseWatch = nil; return }
            }
        }
    }

    private static func state(for error: Error, model: ModelInfo) -> State {
        if case EngineError.missingModel = error { return .missingModel(model.name) }
        return .failed(error.localizedDescription)
    }

    public enum EngineError: LocalizedError {
        case missingModel(String), unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .missingModel(let n): "\(n) is not downloaded yet. Open Models to download it."
            case .unsupported(let s): s
            }
        }
    }

    /// Evaluates the constant cleanup prompt prefix so the first dictation does not pay for it.
    public func primeCleanupCache(_ s: AppSettings) {
        Task {
            guard let g = try? await currentGenerator() else { return }
            let msgs = PromptBuilder.cleanupMessages(transcript: "hello there", context: DictationContext(appName: "Notes", bundleID: "com.apple.Notes"),
                                                     level: s.cleanupLevel == .off ? .light : s.cleanupLevel, tone: .formal,
                                                     vocabulary: [], useContext: false)
            _ = try? await g.generate(msgs, options: .init(maxTokens: 1))
        }
    }

    // MARK: Access

    public func currentRecognizer() async throws -> SpeechRecognizer {
        if let recognizer { return recognizer }
        guard let task = recognizerTask else { throw EngineError.missingModel("Speech model") }
        return try await task.value
    }

    /// The language model for features that need one even when AI formatting is off (Ask, meeting
    /// summaries): loads the chosen model on first use, or again after a failed load (e.g. it has been
    /// downloaded since). It then stays loaded until the model choice changes.
    public func generatorLoadingIfNeeded() async throws -> TextGenerator? {
        if let s = lastSettings, generatorKey == "off" || Self.needsRetry(languageState) {
            let onDemand = generatorKey == "off" || generatorOnDemand
            loadGenerator(s, key: Self.modelKey(s))
            generatorOnDemand = onDemand
        }
        return try await currentGenerator()
    }

    /// Returns nil when the language model is disabled.
    public func currentGenerator() async throws -> TextGenerator? {
        if let generator { return generator }
        guard generatorKey != "off", let task = generatorTask else { return nil }
        return try await task.value
    }

    // MARK: Factories

    private final class WeakGenerator {
        weak var engine: TextGenerator?
        init(_ engine: TextGenerator) { self.engine = engine }
    }

    nonisolated static func makeRecognizer(_ model: ModelInfo, language: String?) async throws -> SpeechRecognizer {
        switch model.engine {
        case .whisper, .parakeet:
            guard let url = AppPaths.modelFile(model), FileManager.default.fileExists(atPath: url.path) else {
                throw EngineError.missingModel(model.name)
            }
            return try await Task.detached(priority: .userInitiated) { () throws -> SpeechRecognizer in
                model.engine == .whisper
                    ? try WhisperEngine(modelPath: url.path, displayName: model.name)
                    : try ParakeetEngine(modelPath: url.path, displayName: model.name)
            }.value
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                guard AppleSpeechEngine.isSupported else { throw EngineError.unsupported("Apple Speech is not available on this Mac.") }
                return AppleSpeechEngine(locale: language.map { Locale(identifier: $0) } ?? .current)
            }
            throw EngineError.unsupported("Apple Speech requires macOS 26.")
        default:
            throw EngineError.unsupported("\(model.name) is not a speech model.")
        }
    }

    nonisolated static func makeGenerator(_ model: ModelInfo, ollamaURL: String, ollamaModel: String) async throws -> TextGenerator? {
        switch model.engine {
        case .llama:
            guard let url = AppPaths.modelFile(model), FileManager.default.fileExists(atPath: url.path) else {
                throw EngineError.missingModel(model.name)
            }
            return try await Task.detached(priority: .userInitiated) { () throws -> TextGenerator in
                try LlamaEngine(modelPath: url.path, displayName: model.name,
                                visionPath: model.imageReader.flatMap(AppPaths.modelFile)?.path)
            }.value
        case .ollama:
            guard let base = URL(string: ollamaURL), !ollamaModel.isEmpty else {
                throw EngineError.unsupported("Choose an Ollama model in Settings → Models.")
            }
            return try OpenAICompatibleGenerator(baseURL: base, model: ollamaModel)
        case .appleIntelligence:
            if #available(macOS 26.0, *) { return try AppleIntelligenceGenerator() }
            throw EngineError.unsupported("Apple Intelligence requires macOS 26.")
        default:
            throw EngineError.unsupported("\(model.name) is not a language model.")
        }
    }
}
