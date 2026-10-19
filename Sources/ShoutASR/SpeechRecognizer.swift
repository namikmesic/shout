import Foundation

/// Options passed to a speech recognizer for a single utterance.
public struct TranscriptionOptions: Sendable {
    /// ISO-639-1 language code (e.g. "en"), or nil for automatic detection.
    public var language: String?
    /// Free text used to bias recognition towards custom vocabulary and context
    /// (names, jargon, preceding text). Engines that cannot use it ignore it.
    public var prompt: String?
    /// Words that should be recognised verbatim (custom dictionary).
    public var vocabulary: [String]

    public init(language: String? = nil, prompt: String? = nil, vocabulary: [String] = []) {
        self.language = language
        self.prompt = prompt
        self.vocabulary = vocabulary
    }
}

public struct TranscriptionResult: Sendable {
    public var text: String
    /// Detected or forced language code, when the engine reports it.
    public var language: String?
    /// Probability that the audio contained no speech (0...1), if known.
    public var noSpeechProbability: Float?
    /// Wall-clock inference time in seconds.
    public var inferenceSeconds: Double

    public init(text: String, language: String? = nil, noSpeechProbability: Float? = nil, inferenceSeconds: Double = 0) {
        self.text = text
        self.language = language
        self.noSpeechProbability = noSpeechProbability
        self.inferenceSeconds = inferenceSeconds
    }
}

public enum SpeechRecognizerError: LocalizedError {
    case modelLoadFailed(String)
    case inferenceFailed(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let s): return "Could not load speech model: \(s)"
        case .inferenceFailed(let s): return "Transcription failed: \(s)"
        case .unavailable(let s): return s
        }
    }
}

/// A local speech-to-text engine. Implementations must be safe to call from any task;
/// they serialise access to their native context internally.
public protocol SpeechRecognizer: AnyObject, Sendable {
    var displayName: String { get }
    /// Runs a tiny inference so the first real dictation does not pay shader/graph warm-up.
    func warmUp() async
    /// Transcribes 16 kHz mono Float32 PCM in the range -1...1.
    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptionResult
}

public enum ASRAudio {
    public static let sampleRate: Double = 16_000
}

/// Serial executor for native contexts that are not thread-safe.
final class NativeQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    /// Runs `body` on the queue. A caller cancelled before its turn comes is dropped without running it
    /// (an inference that has started runs to the end).
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async {
                    if cancelled.isSet { cont.resume(throwing: CancellationError()); return }
                    do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { cancelled.set() }
    }
}

/// Set by a task's cancellation handler, read on the native queue.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
