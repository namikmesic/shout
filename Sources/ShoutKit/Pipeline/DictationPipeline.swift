import Foundation
import ShoutASR
import ShoutLLM

/// Everything the pipeline needs, captured at the moment recording stops.
public struct PipelineInput: Sendable {
    public var samples: [Float]
    public var context: DictationContext
    public var settings: AppSettings
    public var dictionary: [DictionaryEntry]
    /// Words to recognize on top of the dictionary's (a pinned Prompt mode pack's terms).
    public var extraVocabulary: [String]

    public init(samples: [Float], context: DictationContext, settings: AppSettings, dictionary: [DictionaryEntry],
                extraVocabulary: [String] = []) {
        self.samples = samples; self.context = context; self.settings = settings; self.dictionary = dictionary
        self.extraVocabulary = extraVocabulary
    }

    var vocabularyEntries: [DictionaryEntry] { dictionary.filter { !$0.isSnippet && $0.replacement == nil } }
    var replacementEntries: [DictionaryEntry] { dictionary.filter { $0.replacement != nil } }
    var snippetEntries: [DictionaryEntry] { dictionary.filter(\.isSnippet) }
    var vocabularyWords: [String] {
        let v = vocabularyEntries.sorted { ($0.isStarred ? 1 : 0, $0.useCount) > ($1.isStarred ? 1 : 0, $1.useCount) }.map(\.phrase)
        let targets = dictionary.filter { !$0.isSnippet }.compactMap(\.replacement).filter { $0.count <= 40 }
        return Array((v + extraVocabulary + targets).prefix(200))
    }
}

public struct PipelineOutput: Sendable {
    public var rawText = ""
    public var finalText = ""
    public var pressEnter = false
    public var audioSeconds: Double = 0
    public var asrSeconds: Double = 0
    public var llmSeconds: Double = 0
    public var language: String?
    public var usedEntryIDs: [Int64] = []
    public var llmNote: String?
    public var isEmpty: Bool { finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public init() {}
}

public enum DictationPipeline {

    // MARK: Audio → text

    public static func prepareAudio(_ samples: [Float]) -> [Float] {
        AudioDSP.normalize(AudioDSP.trimSilence(AudioDSP.highPass(samples)))
    }

    public static func transcribe(_ input: PipelineInput, recognizer: SpeechRecognizer) async throws -> PipelineOutput {
        var out = PipelineOutput()
        out.audioSeconds = Double(input.samples.count) / Double(AudioDSP.sampleRate)
        guard !AudioDSP.isSilent(input.samples) else { return out }
        let audio = prepareAudio(input.samples)
        let speech = AudioDSP.speechSeconds(audio)
        let opts = TranscriptionOptions(language: input.settings.forcedLanguage,
                                        prompt: input.settings.useContext ? input.context.textBefore.map { String($0.suffix(200)) } : nil,
                                        vocabulary: input.vocabularyWords)
        let r = try await recognizer.transcribe(audio, options: opts)
        out.asrSeconds = r.inferenceSeconds
        out.language = r.language
        if let nsp = r.noSpeechProbability, nsp > 0.85, speech < 1.0 { return out }
        out.rawText = TextRules.cleanASRArtifacts(r.text, speechSeconds: speech)
        return out
    }

    /// Transcribes the recording in parts split at each screenshot (seconds into the recording), so "[screenshot N]"
    /// lands between the words said before and after it. Without screenshots, as `transcribe`.
    public static func transcribeMarked(_ input: PipelineInput, times: [Double],
                                        recognizer: SpeechRecognizer) async throws -> (PipelineOutput, MarkedTranscript) {
        guard !times.isEmpty else {
            let out = try await transcribe(input, recognizer: recognizer)
            return (out, MarkedTranscript(text: out.rawText, anchors: []))
        }
        let points = PromptScreenshots.splitPoints(samples: input.samples, times: times)
        let bounds = [0] + points + [input.samples.count]
        var total = PipelineOutput()
        total.audioSeconds = Double(input.samples.count) / Double(AudioDSP.sampleRate)
        var parts: [String] = []
        for i in 0..<(bounds.count - 1) {
            guard bounds[i + 1] - bounds[i] >= AudioDSP.sampleRate / 4 else { parts.append(""); continue }
            var part = input
            part.samples = Array(input.samples[bounds[i]..<bounds[i + 1]])
            // What was said so far, for engines that take a prompt (Whisper), as text before the cursor would be.
            if i > 0 { part.context.textBefore = parts.joined(separator: " ") }
            let out = try await transcribe(part, recognizer: recognizer)
            parts.append(out.rawText)
            total.asrSeconds += out.asrSeconds
            total.language = total.language ?? out.language
        }
        let marked = PromptScreenshots.assemble(parts)
        total.rawText = marked.text
        return (total, marked)
    }

    // MARK: Text → final dictation

    public static func format(_ partial: PipelineOutput, input: PipelineInput, generator: TextGenerator?) async -> PipelineOutput {
        var out = partial
        let s = input.settings
        let ctx = input.context
        var raw = out.rawText
        guard !raw.isEmpty else { return out }

        // Whole-utterance snippet: insert the expansion verbatim.
        if let snip = TextRules.exactSnippet(raw, snippets: input.snippetEntries), let expansion = snip.replacement {
            out.finalText = TextRules.fitToCursor(expansion, before: s.useContext ? ctx.textBefore : nil,
                                                  after: s.useContext ? ctx.textAfter : nil)
            out.usedEntryIDs = [snip.id]
            return out
        }

        if s.pressEnterCommand {
            let (t, enter) = TextRules.extractPressEnter(raw)
            raw = t; out.pressEnter = enter
        }

        // Nothing but filler words ("um.") → nothing to insert.
        if TextRules.removeFillers(raw).trimmingCharacters(in: CharacterSet.alphanumerics.inverted).isEmpty {
            out.rawText = raw
            return out
        }

        let mode = s.override(for: ctx.bundleID)
        let category = ctx.category
        let tone: Tone = mode == .casual ? .casual : s.tone(for: category.styleCategory)
        var text = raw

        if mode != .noAI && s.cleanupLevel != .off, let generator {
            let msgs = PromptBuilder.cleanupMessages(transcript: raw, context: ctx, level: s.cleanupLevel, tone: tone,
                                                     vocabulary: input.vocabularyWords, useContext: s.useContext)
            let t0 = Date()
            do {
                var result = try await generator.generate(msgs, options: .init(maxTokens: cleanupTokenBudget(raw), temperature: 0))
                out.llmSeconds = Date().timeIntervalSince(t0)
                if ProcessInfo.processInfo.environment["SHOUT_DEBUG"] != nil {
                    FileHandle.standardError.write("[llm raw] \(result.debugDescription)\n".data(using: .utf8)!)
                }
                if PromptBuilder.isSuspiciousCleanup(input: raw, output: result, level: s.cleanupLevel),
                   let salvaged = PromptBuilder.salvage(output: result, input: raw, level: s.cleanupLevel) {
                    result = salvaged
                }
                if PromptBuilder.isSuspiciousCleanup(input: raw, output: result, level: s.cleanupLevel) {
                    text = TextRules.removeFillers(raw)
                    out.llmNote = "Language model output was discarded (looked like a reply, not a cleanup)."
                } else {
                    text = result
                }
            } catch {
                out.llmSeconds = Date().timeIntervalSince(t0)
                text = TextRules.removeFillers(raw)
                out.llmNote = error.localizedDescription
            }
        }

        if s.pressEnterCommand && !out.pressEnter {
            let (t, enter) = TextRules.extractPressEnter(text)
            text = t; out.pressEnter = enter
        }

        let (replaced, usedR) = TextRules.applyReplacements(text, entries: input.replacementEntries)
        let (vocabFixed, usedV) = TextRules.applyVocabulary(replaced, words: input.vocabularyEntries)
        text = vocabFixed
        out.usedEntryIDs = usedR + usedV

        if mode == .automatic || mode == .noAI {
            text = TextRules.applyTone(text, tone: tone, category: category)
        } else {
            text = TextRules.applyFormatMode(text, mode: mode)
        }

        if category == .email && s.emailSignatureEnabled && !s.emailSignature.isEmpty && text.contains("\n\n")
            && !text.contains(s.emailSignature) && (ctx.textAfter ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\n" + s.emailSignature
        }

        text = TextRules.tidy(text)
        if s.useContext {
            text = TextRules.fitToCursor(text, before: ctx.textBefore, after: ctx.textAfter)
        }
        out.finalText = text
        return out
    }

    /// Room for the cleaned text: a cut-off reply would lose the end of the dictation. Two tokens a word covers
    /// English, but Greek or Cyrillic words can take three or more; their letters are two UTF-8 bytes each, so a
    /// third of the byte count covers them.
    static func cleanupTokenBudget(_ transcript: String) -> Int {
        min(2048, max(TextRules.wordCount(transcript) * 2, transcript.utf8.count / 3) + 32)
    }

    // MARK: Command Mode

    public static func runCommand(instruction: String, input: PipelineInput, generator: TextGenerator?) async throws -> (String, Double) {
        guard let generator else {
            throw TextGeneratorError.unavailable("Command Mode needs a language model. Choose one in Settings → Models.")
        }
        // The reply replaces the whole selection, so the model must see all of it and have room to rewrite it.
        let selection = input.context.selectedText ?? ""
        guard selection.count <= PromptBuilder.maxCommandSelection else {
            throw TextGeneratorError.unavailable("The selection is too long for Command Mode. Select less text and try again.")
        }
        let cleanInstruction = TextRules.removeFillers(instruction)
        let msgs = PromptBuilder.commandMessages(instruction: cleanInstruction, selectedText: input.context.selectedText,
                                                 context: input.context, userName: input.settings.userName)
        guard let maxTokens = commandTokenBudget(msgs, selection: selection, contextTokens: generator.contextTokens) else {
            throw TextGeneratorError.unavailable("The selection is too long for the language model to rewrite. Select less text and try again.")
        }
        let t0 = Date()
        var result = try await generator.generate(msgs, options: .init(maxTokens: maxTokens, temperature: 0.3, failIfTruncated: true))
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip accidental code fences / wrapping quotes.
        if result.hasPrefix("```") && result.hasSuffix("```") {
            var body = result.dropFirst(3).dropLast(3)
            // A language tag ("```swift", "```c++") runs to the end of the fence's first line.
            if let nl = body.firstIndex(of: "\n"), !body[..<nl].contains(" ") { body = body[body.index(after: nl)...] }
            result = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.count > 2, result.first == "\"", result.last == "\"", !(input.context.selectedText ?? "").hasPrefix("\"") {
            result = String(result.dropFirst().dropLast())
        }
        return (result, Date().timeIntervalSince(t0))
    }

    // MARK: Prompt mode

    public enum PromptModeError: LocalizedError, Equatable {
        /// What was said doesn't say what the user wants ("so this").
        case tooShort
        public var errorDescription: String? {
            switch self {
            case .tooShort: "Too short for a prompt. Say what you want in a sentence or two, then finish."
            }
        }
    }

    public struct PromptResult: Sendable {
        public var text: String
        public var seconds: Double
        /// How many screenshots the model looked at (0 when it only had what they pointed at).
        public var picturesSeen = 0
    }

    /// Writes a prompt from what the user said, or from the selected text (with what they said as direction), spelled
    /// as in the Dictionary. Throws when there is no language model, the text is too long for it, or the reply was
    /// cut off or empty.
    public static func runPrompt(spoken: String, input: PipelineInput, generator: TextGenerator?,
                                 captures: [PromptCapture] = [], anchors: [String] = []) async throws -> PromptResult {
        guard let generator else {
            throw TextGeneratorError.unavailable("Prompt mode needs a language model. Choose one in Models.")
        }
        let s = input.settings
        let material = input.context.hasSelection ? input.context.selectedText : nil
        if let material, material.count > PromptBuilder.maxCommandSelection {
            throw TextGeneratorError.unavailable("The selection is too long to turn into a prompt. Select less text and try again.")
        }
        var words = TextRules.removeFillers(spoken).trimmingCharacters(in: .whitespacesAndNewlines)
        // Plain words survive a small model's rewriting better than bracketed markers.
        if !captures.isEmpty {
            words = words.replacingOccurrences(of: #"\[screenshot (\d+)\]"#, with: "(see screenshot $1)", options: .regularExpression)
        }
        // A few words with nothing to act on ("so this") would leave the model writing about its own instructions.
        if material == nil && PromptBuilder.substantiveWordCount(words) < (captures.isEmpty ? 2 : 1) {
            throw PromptModeError.tooShort
        }
        let vocabulary = input.vocabularyWords
        let msgs = PromptBuilder.promptMessages(spoken: words, material: material, vocabulary: vocabulary, captures: captures)
        guard let maxTokens = promptTokenBudget(msgs, source: words + (material ?? ""), contextTokens: generator.contextTokens) else {
            throw TextGeneratorError.unavailable("That's too long for the language model to turn into a prompt. Try a shorter description.")
        }
        let t0 = Date()
        let options = GenerationOptions(maxTokens: maxTokens, temperature: 0, failIfTruncated: true)
        // A model that sees pictures gets the screenshots too, to name what "this" is from what it looks like.
        var seenReply: String?
        var picturesSeen = 0
        if !captures.isEmpty && s.promptModelSeesScreenshots && generator.readsImages {
            let each = PromptImages.modelTokenBudget(count: captures.count, contextTokens: generator.contextTokens)
            let pictures = captures.map { PromptImages.forModel($0.path, maxTokens: each) }
            let seen = PromptBuilder.promptMessages(spoken: words, material: material, vocabulary: vocabulary,
                                                    captures: captures, images: pictures.map { $0?.data })
            let pictureTokens = pictures.reduce(0) { $0 + ($1?.tokens ?? 0) }
            if pictureTokens > 0,
               let budget = promptTokenBudget(seen, source: words + (material ?? ""), contextTokens: generator.contextTokens - pictureTokens) {
                do {
                    seenReply = try await generator.generate(seen, options: GenerationOptions(maxTokens: budget, temperature: 0, failIfTruncated: true))
                    picturesSeen = pictures.filter { $0 != nil }.count
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Pictures that couldn't be read, or no room: the words and what was pointed at still make a prompt.
                    seenReply = nil
                }
            }
        }
        let reply: String
        if let seenReply { reply = seenReply } else { reply = try await generator.generate(msgs, options: options) }
        if reply.contains("NO_REQUEST") { throw PromptModeError.tooShort }
        var text = PromptBuilder.cleanPrompt(reply, instructions: PromptBuilder.boilerplate(msgs))
        guard !text.isEmpty else { throw TextGeneratorError.generationFailed("the prompt came back empty") }
        // It must be about what was said: not one of the user's words in it means the model wrote about something else.
        let said = Set(PromptBuilder.normalize(words + " " + (material ?? "")).split(separator: " ").map(String.init)
            .filter { $0.count >= 3 && !PromptBuilder.fillerWords.contains($0) })
        let written = Set(PromptBuilder.normalize(text).split(separator: " ").map(String.init))
        if said.count >= 3 && said.isDisjoint(with: written) {
            throw TextGeneratorError.generationFailed("the prompt didn't match what you said")
        }
        // A clean-up is about as long as what was said (plus names of what was pointed at): much longer means the
        // model added things the user didn't say.
        let saidWords = TextRules.wordCount(words + " " + (material ?? "")), writtenWords = TextRules.wordCount(text)
        // Quoting a selection is fine.
        let selectedWords = min(400, captures.compactMap(\.selection).reduce(0) { $0 + TextRules.wordCount($1) })
        if saidWords >= 8 && writtenWords > saidWords * 2 + 12 * max(1, captures.count) + selectedWords {
            throw TextGeneratorError.generationFailed("the prompt added more than you said")
        }
        if !captures.isEmpty {
            text = PromptScreenshots.normalizeReferences(text)
            text = PromptScreenshots.placeMissingReferences(text, contexts: PromptScreenshots.contexts(in: words, count: captures.count))
            text += "\n\n" + PromptScreenshots.section(captures, anchors: anchors)
        }
        return PromptResult(text: text, seconds: Date().timeIntervalSince(t0), picturesSeen: picturesSeen)
    }

    /// Reads a screenshot ahead, while the user is still talking (`TextGenerator.readAhead`), at the size `runPrompt`
    /// sends it when a prompt has up to four: then only feeding it in is left for the end.
    public static func readAhead(_ capture: PromptCapture, settings: AppSettings, generator: TextGenerator) async {
        guard settings.promptModelSeesScreenshots, generator.readsImages,
              let picture = PromptImages.forModel(capture.path, maxTokens: PromptImages.modelTokenBudget(count: 1, contextTokens: generator.contextTokens))
        else { return }
        await generator.readAhead(picture.data)
    }

    /// Tokens for the prompt: room for structure on top of the source (at least 1024), within what the context
    /// has left. Nil when less than 256 would be left.
    static func promptTokenBudget(_ messages: [ChatMessage], source: String, contextTokens: Int) -> Int? {
        let room = contextTokens - messages.reduce(0) { $0 + commandTokens($1.content) } - commandReserveTokens
        guard room >= 256 else { return nil }
        return min(max(1024, commandTokens(source) * 2 + 384), room)
    }

    /// Context kept free for chat-template tokens and estimation error, on top of the Command Mode prompt and reply.
    static let commandReserveTokens = 320

    /// Tokens for the Command Mode reply. Prompt and reply must fit the model's context together: an engine cuts
    /// the reply to the space left, and a cut-off rewrite would replace the whole selection. Nil when that space
    /// can't hold a rewrite as long as the selection.
    static func commandTokenBudget(_ messages: [ChatMessage], selection: String, contextTokens: Int) -> Int? {
        let room = contextTokens - messages.reduce(0) { $0 + commandTokens($1.content) } - commandReserveTokens
        guard room >= commandTokens(selection) + 64 else { return nil }
        return min(max(2048, selection.utf8.count / 2 + 256), room)
    }

    /// A high token count for Command Mode text: ASCII at 3 characters a token (code and markup run denser than
    /// prose), other characters at a third of their UTF-8 bytes, as in `cleanupTokenBudget`.
    static func commandTokens(_ s: String) -> Int {
        var ascii = 0, bytes = 0
        for u in s.unicodeScalars { if u.isASCII { ascii += 1 } else { bytes += UTF8.width(u) } }
        return (ascii + 2) / 3 + (bytes + 2) / 3
    }
}
