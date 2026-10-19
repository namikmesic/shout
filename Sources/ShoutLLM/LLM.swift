import Foundation

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public var role: Role
    public var content: String
    /// Pictures (PNG or JPEG files' bytes), one for each `ChatMessage.imageMarker` in `content`, in order. Only a
    /// generator whose `readsImages` is true takes them.
    public var images: [Data]
    public init(_ role: Role, _ content: String, images: [Data] = []) {
        self.role = role; self.content = content; self.images = images
    }

    /// Where a picture goes in `content`.
    public static let imageMarker = "<__media__>"
}

public struct GenerationOptions: Sendable {
    public var maxTokens: Int
    public var temperature: Float
    /// Generation stops as soon as any of these strings appears; the stop string is not returned.
    public var stop: [String]
    /// Text the assistant turn is pre-filled with (it is part of the prompt, not returned).
    public var assistantPrefix: String?
    /// Background work (meeting summaries) gives way to interactive requests: engines that support it
    /// abort with `TextGeneratorError.preempted` as soon as a foreground request is waiting.
    public var background: Bool
    /// Throw `TextGeneratorError.truncated` rather than return a reply cut off at `maxTokens` or the end of the
    /// context (Command Mode: a partial rewrite must never replace the user's selection).
    public var failIfTruncated: Bool

    public init(maxTokens: Int = 1024, temperature: Float = 0, stop: [String] = [], assistantPrefix: String? = nil,
                background: Bool = false, failIfTruncated: Bool = false) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.stop = stop
        self.assistantPrefix = assistantPrefix
        self.background = background
        self.failIfTruncated = failIfTruncated
    }
}

public enum TextGeneratorError: LocalizedError {
    case modelLoadFailed(String)
    case generationFailed(String)
    case unavailable(String)
    /// A background generation stopped so an interactive request could run; retry later.
    case preempted
    /// The reply hit its length limit and `failIfTruncated` was set.
    case truncated

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let s): return "Could not load language model: \(s)"
        case .generationFailed(let s): return "Language model failed: \(s)"
        case .unavailable(let s): return s
        case .preempted: return "Paused for dictation."
        case .truncated: return "The reply was too long for the language model, so nothing was changed."
        }
    }
}

/// A local text generation backend used for cleanup, styling and command mode.
public protocol TextGenerator: AnyObject, Sendable {
    var displayName: String { get }
    /// How many tokens of prompt plus reply fit (long jobs such as meeting summaries size their parts by it).
    var contextTokens: Int { get }
    func warmUp() async
    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String
    /// Whether `generate` can look at `ChatMessage.images` now (the model sees pictures and its image reader is on
    /// this Mac).
    var readsImages: Bool { get }
    /// Gets ready to read images, so the first request with pictures doesn't wait for it.
    func prepareImages() async
    /// Reads a picture now (while the user is still talking), so a request with exactly these bytes later only
    /// feeds it in.
    func readAhead(_ image: Data) async
}

public extension TextGenerator {
    var contextTokens: Int { 8192 }
    var readsImages: Bool { false }
    func prepareImages() async {}
    func readAhead(_ image: Data) async {}
}

public extension String {
    /// Removes `<think>…</think>` blocks that reasoning models sometimes emit. Pass `openedInPrompt` when the
    /// prompt itself ended inside an open `<think>` (some chat templates add it): the reply then starts with the
    /// reasoning and holds only the closing tag. Otherwise a lone `</think>` is ordinary text (for example in a
    /// Command Mode selection) and is kept.
    func strippingThinking(openedInPrompt: Bool = false) -> String {
        var s = self
        if openedInPrompt, let close = s.range(of: "</think>"),
           s.range(of: "<think>", range: s.startIndex..<close.lowerBound) == nil {
            s.removeSubrange(s.startIndex..<close.upperBound)
        }
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether this prompt ends inside a `<think>` block that it opened and didn't close.
    var leavesThinkingOpen: Bool {
        guard let open = range(of: "<think>", options: .backwards) else { return false }
        return range(of: "</think>", range: open.upperBound..<endIndex) == nil
    }
}
