import Foundation
import llama

/// In-process GGUF model through llama.cpp (Metal). Keeps the KV cache of the previous
/// prompt so that a shared system prompt is only evaluated once across dictations. With an image reader
/// (`visionPath`, the model's mmproj file) it also looks at pictures in the messages.
public final class LlamaEngine: TextGenerator, @unchecked Sendable {
    public let displayName: String
    private let queue = DispatchQueue(label: "shout.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var cachedTokens: [llama_token] = []
    private let nBatch: Int32
    private let templateKind: TemplateKind
    private let nativeTemplate: String?
    private let threads: Int32
    /// The image reader's file. It may arrive after the model loaded (it's downloaded separately), so it's loaded
    /// on first use.
    private let visionPath: String?
    private var vision: OpaquePointer?
    /// Pictures read ahead (`readAhead`): the image reader's output by picture id (the SHA-256 of its bytes), and the
    /// order they came in. Dropped once a request has used them.
    private var readPictures: [String: [Float]] = [:]
    private var readOrder: [String] = []
    private static let maxReadPictures = 6

    enum TemplateKind { case chatml(disableThinking: Bool), native }

    /// SHOUT_LLAMA_LOG=1 keeps llama.cpp's own log on stderr, with timings (for measuring).
    private static let verbose = ProcessInfo.processInfo.environment["SHOUT_LLAMA_LOG"] == "1"

    private static let backendInit: Void = {
        if !verbose {
            llama_log_set({ _, _, _ in }, nil)
            mtmd_helper_log_set({ _, _, _ in }, nil)
        }
        llama_backend_init()
    }()

    public init(modelPath: String, displayName: String = "Local LLM", contextSize: Int = 8192, visionPath: String? = nil) throws {
        _ = Self.backendInit
        self.displayName = displayName
        self.visionPath = visionPath
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = -1 // offload every layer to Metal
        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            throw TextGeneratorError.modelLoadFailed((modelPath as NSString).lastPathComponent)
        }
        model = m
        vocab = llama_model_get_vocab(m)

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextSize)
        cparams.n_batch = 2048
        cparams.n_ubatch = 512
        cparams.n_seq_max = 1
        let threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        self.threads = threads
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        cparams.no_perf = true
        nBatch = Int32(cparams.n_batch)
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw TextGeneratorError.modelLoadFailed("context creation failed")
        }
        ctx = c

        let tmpl = llama_model_chat_template(m, nil).map { String(cString: $0) }
        nativeTemplate = tmpl
        if let tmpl, tmpl.contains("<|im_start|>") {
            templateKind = .chatml(disableThinking: tmpl.contains("enable_thinking"))
        } else {
            templateKind = .native
        }
    }

    deinit {
        if let vision { mtmd_free(vision) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    public var contextTokens: Int { ctx.map { Int(llama_n_ctx($0)) } ?? 8192 }

    public var readsImages: Bool { visionPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }

    public func prepareImages() async {
        guard readsImages else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in _ = try? loadVision(); cont.resume() }
        }
    }

    public func readAhead(_ image: Data) async {
        guard readsImages else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { [self] in try? encodeAhead(image); cont.resume() }
        }
    }

    private func bitmap(_ data: Data, _ vision: OpaquePointer) -> OpaquePointer? {
        data.withUnsafeBytes { raw in
            mtmd_helper_bitmap_init_from_buf(vision, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, false,
                                             mtmd_helper_init_opt_default()).bitmap
        }
    }

    /// Splits `text` (with a marker per picture) into text and picture chunks.
    private func tokenize(_ text: String, bitmaps: [OpaquePointer?], vision: OpaquePointer, into chunks: OpaquePointer,
                          addSpecial: Bool) -> Int32 {
        text.withCString { cstr -> Int32 in
            var input = mtmd_input_text(text: cstr, text_len: strlen(cstr), add_special: addSpecial, parse_special: true)
            return bitmaps.withUnsafeBufferPointer { mtmd_tokenize(vision, chunks, &input, $0.baseAddress, $0.count) }
        }
    }

    private func encodeAhead(_ image: Data) throws {
        let vision = try loadVision()
        guard let bitmap = bitmap(image, vision) else { return }
        defer { mtmd_bitmap_free(bitmap) }
        guard let chunks = mtmd_input_chunks_init() else { return }
        defer { mtmd_input_chunks_free(chunks) }
        guard tokenize(ChatMessage.imageMarker, bitmaps: [bitmap], vision: vision, into: chunks, addSpecial: false) == 0 else { return }
        for i in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, i)
            guard mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_IMAGE,
                  let idC = mtmd_input_chunk_get_id(chunk) else { continue }
            let id = String(cString: idC)
            guard readPictures[id] == nil, mtmd_encode_chunk(vision, chunk) == 0, let out = mtmd_get_output_embd(vision) else { return }
            let count = Int(llama_model_n_embd_inp(model)) * mtmd_input_chunk_get_n_tokens(chunk)
            readPictures[id] = Array(UnsafeBufferPointer(start: out, count: count))
            readOrder.append(id)
            while readOrder.count > Self.maxReadPictures { readPictures[readOrder.removeFirst()] = nil }
        }
    }

    /// The image reader, loaded on the model's queue the first time it's needed (about 1 GB of memory).
    private func loadVision() throws -> OpaquePointer {
        if let vision { return vision }
        guard let visionPath, FileManager.default.fileExists(atPath: visionPath) else {
            throw TextGeneratorError.unavailable("\(displayName) can't read images on this Mac.")
        }
        var params = mtmd_context_params_default()
        params.use_gpu = true
        params.print_timings = Self.verbose
        params.n_threads = threads
        guard let v = mtmd_init_from_file(visionPath, model, params) else {
            throw TextGeneratorError.modelLoadFailed((visionPath as NSString).lastPathComponent)
        }
        vision = v
        return v
    }

    public func warmUp() async {
        _ = try? await generate([.init(.system, "You are terse."), .init(.user, "Say OK.")],
                                options: .init(maxTokens: 2))
    }

    /// Interactive requests waiting for the queue; background generations yield to them.
    private let pendingLock = NSLock()
    private var foregroundPending = 0
    private var foregroundWaiting: Bool { pendingLock.withLock { foregroundPending > 0 } }

    /// A cancelled caller is dropped while it waits for the queue, and stops a running generation at the
    /// next batch or token (like a preempted background one).
    public func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        try Task.checkCancellation()
        if !options.background { pendingLock.withLock { foregroundPending += 1 } }
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async { [self] in
                    if !options.background { pendingLock.withLock { foregroundPending -= 1 } }
                    do { cont.resume(returning: try generateSync(messages, options: options, cancelled: cancelled)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } onCancel: { cancelled.set() }
    }

    // MARK: - Prompt formatting

    func formatPrompt(_ messages: [ChatMessage], assistantPrefix: String?) throws -> String {
        var prompt: String
        switch templateKind {
        case .chatml(let disableThinking):
            prompt = ""
            for m in messages {
                prompt += "<|im_start|>\(m.role.rawValue)\n\(m.content)<|im_end|>\n"
            }
            prompt += "<|im_start|>assistant\n"
            if disableThinking { prompt += "<think>\n\n</think>\n\n" }
        case .native:
            prompt = try applyNativeTemplate(messages)
        }
        if let assistantPrefix { prompt += assistantPrefix }
        return prompt
    }

    private func applyNativeTemplate(_ messages: [ChatMessage]) throws -> String {
        // Keep C strings alive for the duration of the call.
        let roles = messages.map { strdup($0.role.rawValue) }
        let contents = messages.map { strdup($0.content) }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var chat = (0..<messages.count).map { llama_chat_message(role: roles[$0], content: contents[$0]) }
        let totalChars = messages.reduce(0) { $0 + $1.content.utf8.count } * 2 + 512
        var buf = [CChar](repeating: 0, count: totalChars)
        var n = nativeTemplate.withOptionalCString { tmpl in
            llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
        }
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = nativeTemplate.withOptionalCString { tmpl in
                llama_chat_apply_template(tmpl, &chat, chat.count, true, &buf, Int32(buf.count))
            }
        }
        guard n > 0 else { throw TextGeneratorError.generationFailed("unsupported chat template") }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Generation

    private func tokenize(_ text: String, addSpecial: Bool) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        var n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), addSpecial, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), addSpecial, true)
        }
        return Array(tokens.prefix(Int(max(0, n))))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    private func decode(_ tokens: [llama_token], yieldsToForeground: Bool, cancelled: CancelFlag) throws {
        var offset = 0
        while offset < tokens.count {
            if cancelled.isSet { throw CancellationError() }
            if yieldsToForeground && foregroundWaiting { throw TextGeneratorError.preempted }
            let end = min(tokens.count, offset + Int(nBatch))
            var chunk = Array(tokens[offset..<end])
            let rc = chunk.withUnsafeMutableBufferPointer { buf in
                llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
            }
            if rc != 0 { throw TextGeneratorError.generationFailed("llama_decode returned \(rc)") }
            offset = end
        }
    }

    private func generateSync(_ messages: [ChatMessage], options: GenerationOptions, cancelled: CancelFlag) throws -> String {
        guard let ctx else { throw TextGeneratorError.unavailable("Language model is not loaded") }
        if cancelled.isSet { throw CancellationError() }
        let prompt = try formatPrompt(messages, assistantPrefix: options.assistantPrefix)
        let thinkingOpen = prompt.leavesThinkingOpen
        let nCtx = Int(llama_n_ctx(ctx))
        let images = messages.flatMap(\.images)
        // With pictures, positions are counted here (`nextPosition`): an image takes fewer positions than tokens.
        var nextPosition: llama_pos? = nil
        if !images.isEmpty {
            nextPosition = try evaluateWithImages(prompt, images: images, nCtx: nCtx, cancelled: cancelled)
        } else {
            try evaluateText(prompt, nCtx: nCtx, options: options, cancelled: cancelled)
        }
        return try sample(options: options, nCtx: nCtx, thinkingOpen: thinkingOpen, position: nextPosition, cancelled: cancelled)
    }

    /// Evaluates a text-only prompt, reusing the cache for what it shares with the previous one.
    private func evaluateText(_ prompt: String, nCtx: Int, options: GenerationOptions, cancelled: CancelFlag) throws {
        let promptTokens = tokenize(prompt, addSpecial: true)
        guard promptTokens.count + 8 < nCtx else {
            throw TextGeneratorError.generationFailed("prompt too long (\(promptTokens.count) tokens)")
        }

        // Reuse the KV cache for the longest common prefix with the previous call.
        let mem = llama_get_memory(ctx)
        var common = 0
        while common < min(cachedTokens.count, promptTokens.count) && cachedTokens[common] == promptTokens[common] {
            common += 1
        }
        if common == promptTokens.count { common -= 1 } // must evaluate at least one token for logits
        if common > 0 && !llama_memory_seq_rm(mem, 0, llama_pos(common), -1) {
            llama_memory_clear(mem, true)
            common = 0
        } else if common == 0 {
            llama_memory_clear(mem, true)
        }
        cachedTokens = Array(promptTokens.prefix(common))
        let fresh = Array(promptTokens[common...])
        do { try decode(fresh, yieldsToForeground: options.background, cancelled: cancelled) } catch {
            llama_memory_clear(mem, true); cachedTokens = []; throw error
        }
        cachedTokens += fresh
    }

    /// Evaluates a prompt with pictures at its `ChatMessage.imageMarker`s, from an empty cache, and returns the
    /// next position. The cache isn't reused afterwards: it holds pictures that `cachedTokens` can't describe.
    private func evaluateWithImages(_ prompt: String, images: [Data], nCtx: Int, cancelled: CancelFlag) throws -> llama_pos {
        let vision = try loadVision()
        // Whatever happens, pictures read ahead were for this request.
        defer { readPictures = [:]; readOrder = [] }
        var bitmaps: [OpaquePointer?] = []
        defer { bitmaps.forEach { mtmd_bitmap_free($0) } }
        for data in images {
            guard let bitmap = bitmap(data, vision) else { throw TextGeneratorError.generationFailed("a picture couldn't be read") }
            bitmaps.append(bitmap)
        }
        guard let chunks = mtmd_input_chunks_init() else { throw TextGeneratorError.generationFailed("mtmd init failed") }
        defer { mtmd_input_chunks_free(chunks) }
        let rc = tokenize(prompt, bitmaps: bitmaps, vision: vision, into: chunks, addSpecial: true)
        // 1: the markers and pictures don't match up; 2: a picture couldn't be prepared.
        guard rc == 0 else { throw TextGeneratorError.generationFailed("the pictures couldn't be read (\(rc))") }
        let total = mtmd_helper_get_n_tokens(chunks)
        guard total + 8 < nCtx else { throw TextGeneratorError.generationFailed("prompt too long (\(total) tokens)") }
        if cancelled.isSet { throw CancellationError() }

        let mem = llama_get_memory(ctx)
        llama_memory_clear(mem, true)
        cachedTokens = []
        var next: llama_pos = 0
        let count = mtmd_input_chunks_size(chunks)
        for i in 0..<count {
            if cancelled.isSet { llama_memory_clear(mem, true); throw CancellationError() }
            let chunk = mtmd_input_chunks_get(chunks, i)
            // Text chunks add their length to it, pictures set it.
            var after: llama_pos = next
            let result: Int32
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_IMAGE,
               let idC = mtmd_input_chunk_get_id(chunk), var read = readPictures[String(cString: idC)] {
                // Read while the user was talking: only fed in now.
                result = read.withUnsafeMutableBufferPointer {
                    mtmd_helper_decode_image_chunk(vision, ctx, chunk, $0.baseAddress, next, 0, nBatch, &after, nil, nil)
                }
            } else {
                result = mtmd_helper_eval_chunk_single(vision, ctx, chunk, next, 0, nBatch, i == count - 1, &after)
            }
            if result != 0 {
                llama_memory_clear(mem, true)
                throw TextGeneratorError.generationFailed("evaluating the pictures returned \(result)")
            }
            next = after
        }
        return next
    }

    /// Samples the reply. `position`: the next position when the prompt had pictures (tokens then go in at counted
    /// positions and aren't added to the reusable cache); nil for a text prompt.
    private func sample(options: GenerationOptions, nCtx: Int, thinkingOpen: Bool, position: llama_pos?,
                        cancelled: CancelFlag) throws -> String {
        // Sampler chain.
        let sparams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(sparams) else {
            throw TextGeneratorError.generationFailed("sampler init failed")
        }
        defer { llama_sampler_free(sampler) }
        if options.temperature <= 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(options.temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        }

        var output: [UInt8] = []
        var position = position
        let used = position.map(Int.init) ?? cachedTokens.count
        let budget = min(options.maxTokens, nCtx - used - 1)
        var produced = 0
        var batch = llama_batch_init(1, 0, 1)
        defer { llama_batch_free(batch) }
        while produced < budget {
            if cancelled.isSet { throw CancellationError() }
            if options.background && foregroundWaiting { throw TextGeneratorError.preempted }
            let token = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += piece(token)
            produced += 1
            if !options.stop.isEmpty {
                let text = String(decoding: output, as: UTF8.self)
                if let hit = options.stop.compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                    return String(text[..<hit.lowerBound]).strippingThinking(openedInPrompt: thinkingOpen)
                }
            }
            let rc: Int32
            if let pos = position {
                batch.n_tokens = 1
                batch.token[0] = token
                batch.pos[0] = pos
                batch.n_seq_id[0] = 1
                batch.seq_id[0]![0] = 0
                batch.logits[0] = 1
                rc = llama_decode(ctx, batch)
                position = pos + 1
            } else {
                var t = token
                rc = withUnsafeMutablePointer(to: &t) { llama_decode(ctx, llama_batch_get_one($0, 1)) }
            }
            if rc != 0 { throw TextGeneratorError.generationFailed("llama_decode returned \(rc)") }
            if position == nil { cachedTokens.append(token) }
        }
        // The loop ran out of budget instead of reaching the end of the reply.
        if options.failIfTruncated && produced >= budget { throw TextGeneratorError.truncated }
        return String(decoding: output, as: UTF8.self).strippingThinking(openedInPrompt: thinkingOpen)
    }
}

/// Set by a task's cancellation handler, read on the model's queue.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private extension Optional where Wrapped == String {
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) -> R) -> R {
        switch self {
        case .some(let s): return s.withCString { body($0) }
        case .none: return body(nil)
        }
    }
}
