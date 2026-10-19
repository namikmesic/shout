import Foundation
import whisper

/// OpenAI Whisper running through whisper.cpp with Metal acceleration.
/// Supports ~99 languages and vocabulary biasing through the initial prompt.
public final class WhisperEngine: SpeechRecognizer, @unchecked Sendable {
    public let displayName: String
    private let queue = NativeQueue(label: "shout.whisper")
    private var ctx: OpaquePointer?

    public init(modelPath: String, displayName: String = "Whisper") throws {
        self.displayName = displayName
        _ = NativeLog.installed
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true
        guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw SpeechRecognizerError.modelLoadFailed((modelPath as NSString).lastPathComponent)
        }
        ctx = c
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    public func warmUp() async {
        do { _ = try await transcribe([Float](repeating: 0, count: Int(ASRAudio.sampleRate)), options: .init(language: "en")) }
        catch is CancellationError {}
        catch { NSLog("Shout: %@ warm-up failed: %@", displayName, error.localizedDescription) }
    }

    public func transcribe(_ input: [Float], options: TranscriptionOptions) async throws -> TranscriptionResult {
        try await queue.run { [self] in
            guard let ctx else { throw SpeechRecognizerError.unavailable("Whisper model is not loaded") }
            let start = Date()
            // whisper.cpp needs at least ~1 s of audio; pad short clips with silence.
            var samples = input
            let minSamples = Int(ASRAudio.sampleRate * 1.1)
            if samples.count < minSamples { samples += [Float](repeating: 0, count: minSamples - samples.count) }

            var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
            params.no_context = true
            params.no_timestamps = true
            params.single_segment = false
            params.print_special = false
            params.print_progress = false
            params.print_realtime = false
            params.print_timestamps = false
            params.suppress_blank = true
            params.suppress_nst = true
            params.temperature = 0
            params.translate = false

            let lang = (options.language?.isEmpty == false) ? options.language! : "auto"
            let prompt = Self.buildPrompt(options, maxTokens: Int(whisper_n_text_ctx(ctx)) / 2) { Self.tokenCount(ctx, $0) }

            let rc: Int32 = lang.withCString { langPtr in
                params.language = langPtr
                params.detect_language = false
                if let prompt {
                    return prompt.withCString { promptPtr in
                        params.initial_prompt = promptPtr
                        return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
                    }
                }
                return samples.withUnsafeBufferPointer { whisper_full(ctx, params, $0.baseAddress, Int32($0.count)) }
            }
            guard rc == 0 else { throw SpeechRecognizerError.inferenceFailed("whisper_full returned \(rc)") }

            var text = ""
            var noSpeech: Float = 0
            let n = whisper_full_n_segments(ctx)
            for i in 0..<n {
                if let cstr = whisper_full_get_segment_text(ctx, i) { text += String(cString: cstr) }
                noSpeech = max(noSpeech, whisper_full_get_segment_no_speech_prob(ctx, i))
            }
            var detected: String?
            let langId = whisper_full_lang_id(ctx)
            if langId >= 0, let l = whisper_lang_str(langId) { detected = String(cString: l) }
            return TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                       language: detected,
                                       noSpeechProbability: n > 0 ? noSpeech : 1,
                                       inferenceSeconds: Date().timeIntervalSince(start))
        }
    }

    /// Whisper conditions on the prompt as if it were preceding transcript, so a short,
    /// well-punctuated sentence containing the vocabulary works best.
    ///
    /// whisper.cpp keeps only the last `maxTokens` tokens of the prompt, so a long one would lose its start:
    /// the vocabulary, whose first (starred, most used) words matter most. When the whole prompt does not
    /// fit, the preceding text is cut to its last 100 characters and the vocabulary to as many words as fit.
    static func buildPrompt(_ o: TranscriptionOptions, maxTokens: Int, tokenCount: (String) -> Int) -> String? {
        let context = o.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func prompt(terms: Int, contextChars: Int) -> String? {
            var parts: [String] = []
            if terms > 0 { parts.append("Vocabulary: " + o.vocabulary.prefix(terms).joined(separator: ", ") + ".") }
            if !context.isEmpty { parts.append(String(context.suffix(contextChars))) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        let allTerms = min(60, o.vocabulary.count)
        guard let full = prompt(terms: allTerms, contextChars: 400) else { return nil }
        if tokenCount(full) <= maxTokens { return full }
        // The most vocabulary words that fit beside the shortened context (binary search).
        var lo = 0, hi = allTerms
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if let p = prompt(terms: mid, contextChars: 100), tokenCount(p) <= maxTokens { lo = mid } else { hi = mid - 1 }
        }
        return prompt(terms: lo, contextChars: 100)
    }

    private static func tokenCount(_ ctx: OpaquePointer, _ text: String) -> Int {
        // A token covers at least one byte, so this always fits (a short buffer makes whisper.cpp log an error).
        var tokens = [whisper_token](repeating: 0, count: text.utf8.count + 1)
        return Int(abs(whisper_tokenize(ctx, text, &tokens, Int32(tokens.count))))
    }
}

/// whisper.cpp and Parakeet print dozens of lines to stderr while loading a model. Only errors are passed on
/// (NSLog), so a failed load or inference can be diagnosed. The sink is process-wide: it is set once.
enum NativeLog {
    static let installed: Void = {
        let sink: ggml_log_callback = { level, text, _ in
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            NSLog("Shout: whisper.cpp: %@", String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        whisper_log_set(sink, nil)
        parakeet_log_set(sink, nil)
    }()
}
