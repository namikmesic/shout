import Foundation
import whisper

/// NVIDIA Parakeet TDT (0.6B v3) running through whisper.cpp's Parakeet runtime.
/// Very fast, punctuated and cased output, 25 European languages with automatic detection.
/// Parakeet has no prompt input, so custom vocabulary is applied later by the text pipeline.
public final class ParakeetEngine: SpeechRecognizer, @unchecked Sendable {
    public let displayName: String
    private let queue = NativeQueue(label: "shout.parakeet")
    private var ctx: OpaquePointer?

    public init(modelPath: String, displayName: String = "Parakeet") throws {
        self.displayName = displayName
        _ = NativeLog.installed
        var cparams = parakeet_context_default_params()
        cparams.use_gpu = true
        guard let c = parakeet_init_from_file_with_params(modelPath, cparams) else {
            throw SpeechRecognizerError.modelLoadFailed((modelPath as NSString).lastPathComponent)
        }
        ctx = c
    }

    deinit {
        if let ctx { parakeet_free(ctx) }
    }

    public func warmUp() async {
        do { _ = try await transcribe([Float](repeating: 0, count: Int(ASRAudio.sampleRate)), options: .init()) }
        catch is CancellationError {}
        catch { NSLog("Shout: %@ warm-up failed: %@", displayName, error.localizedDescription) }
    }

    public func transcribe(_ input: [Float], options: TranscriptionOptions) async throws -> TranscriptionResult {
        try await queue.run { [self] in
            guard let ctx else { throw SpeechRecognizerError.unavailable("Parakeet model is not loaded") }
            let start = Date()
            var samples = input
            let minSamples = Int(ASRAudio.sampleRate * 0.5)
            if samples.count < minSamples { samples += [Float](repeating: 0, count: minSamples - samples.count) }

            var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
            params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            params.no_context = true
            let rc = samples.withUnsafeBufferPointer { parakeet_full(ctx, params, $0.baseAddress, Int32($0.count)) }
            guard rc == 0 else { throw SpeechRecognizerError.inferenceFailed("parakeet_full returned \(rc)") }

            var text = ""
            let n = parakeet_full_n_segments(ctx)
            for i in 0..<n {
                if let cstr = parakeet_full_get_segment_text(ctx, i) {
                    let seg = String(cString: cstr).trimmingCharacters(in: .whitespaces)
                    if !seg.isEmpty { text += (text.isEmpty ? "" : " ") + seg }
                }
            }
            return TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                       language: nil,
                                       noSpeechProbability: nil,
                                       inferenceSeconds: Date().timeIntervalSince(start))
        }
    }
}
