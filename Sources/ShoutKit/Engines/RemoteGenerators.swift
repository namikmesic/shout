import Foundation
import ShoutLLM
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Talks to a model served on this Mac by Ollama, LM Studio, llama-server or any
/// OpenAI-compatible endpoint. Refuses non-loopback hosts so text never leaves the machine.
public final class OpenAICompatibleGenerator: TextGenerator, @unchecked Sendable {
    public let displayName: String
    let baseURL: URL
    let model: String

    public init(baseURL: URL, model: String) throws {
        guard Self.isOnThisMac(baseURL) else {
            throw TextGeneratorError.unavailable("Only servers on this Mac (localhost) are allowed.")
        }
        self.baseURL = baseURL
        self.model = model
        self.displayName = "Ollama · \(model)"
    }

    /// Ollama's default context window; longer prompts are cut silently, so plan for this.
    public var contextTokens: Int { 4096 }

    public func warmUp() async {
        _ = try? await generate([.init(.user, "Reply with OK.")], options: .init(maxTokens: 2))
    }

    public func generate(_ messages: [ChatMessage], options: ShoutLLM.GenerationOptions) async throws -> String {
        var msgs = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        if let prefix = options.assistantPrefix { msgs.append(["role": "assistant", "content": prefix]) }
        var body: [String: Any] = [
            "model": model, "messages": msgs, "stream": false,
            "temperature": options.temperature, "max_tokens": options.maxTokens,
        ]
        if !options.stop.isEmpty { body["stop"] = options.stop }
        // Ollama-specific: disable "thinking" for hybrid reasoning models.
        body["think"] = false
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TextGeneratorError.generationFailed("server error: \(msg.prefix(200))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TextGeneratorError.generationFailed("unexpected response")
        }
        if options.failIfTruncated, choices.first?["finish_reason"] as? String == "length" { throw TextGeneratorError.truncated }
        return content.strippingThinking()
    }

    /// Lists models from an Ollama server (`/api/tags`).
    public static func listOllamaModels(baseURL: URL) async -> [String] {
        guard isOnThisMac(baseURL),
              let (data, _) = try? await session.data(from: baseURL.appendingPathComponent("api/tags")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    /// An http(s) URL of this Mac. Hosts compare without case, IPv6 brackets or a trailing dot.
    static func isOnThisMac(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased() else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    /// Follows a server's redirect only to this Mac, so a request never leaves it that way either.
    private static let session = URLSession(configuration: .default, delegate: LocalRedirectsOnly(), delegateQueue: nil)

    private final class LocalRedirectsOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(OpenAICompatibleGenerator.isOnThisMac(request.url) ? request : nil)
        }
    }
}

/// Apple's on-device foundation model (macOS 26, Apple Intelligence enabled).
@available(macOS 26.0, *)
public final class AppleIntelligenceGenerator: TextGenerator, @unchecked Sendable {
    /// The on-device foundation model's context window.
    public var contextTokens: Int { 4096 }

    public let displayName = "Apple Intelligence"

    public init() throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw TextGeneratorError.unavailable(Self.unavailableReason ?? "Apple Intelligence is unavailable")
        }
    }

    public static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use this model."
        case .unavailable(.deviceNotEligible): return "This Mac does not support Apple Intelligence."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model."
        case .unavailable: return "Apple Intelligence is unavailable."
        }
    }

    public func warmUp() async {
        LanguageModelSession().prewarm()
    }

    public func generate(_ messages: [ChatMessage], options: ShoutLLM.GenerationOptions) async throws -> String {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let convo = messages.filter { $0.role != .system }
        let session = LanguageModelSession(instructions: system)
        // Feed earlier turns (few-shot examples) as a transcript inside the prompt.
        var prompt = ""
        for m in convo.dropLast() {
            prompt += (m.role == .user ? "Input:\n" : "Output:\n") + m.content + "\n\n"
        }
        prompt += convo.last?.content ?? ""
        var gen = FoundationModels.GenerationOptions()
        gen.temperature = Double(options.temperature)
        // Uncapped when a cut-off reply must fail: it then ends on its own or throws for the context window.
        gen.maximumResponseTokens = options.failIfTruncated ? nil : options.maxTokens
        let response = try await session.respond(to: prompt, options: gen)
        return response.content.strippingThinking()
    }
}
