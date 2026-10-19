import Foundation
import ShoutLLM

/// Runs background language-model work (meeting summaries) without delaying dictation. Every request
/// is marked as background; when the engine stops it for an interactive request, or the app reports
/// it is busy (the user is dictating), it waits until things are quiet and retries.
public final class YieldingGenerator: TextGenerator, Sendable {
    private let base: TextGenerator
    private let isBusy: @Sendable () async -> Bool
    private let retryDelay: UInt64

    public init(_ base: TextGenerator, retryDelay: TimeInterval = 1.5, isBusy: @escaping @Sendable () async -> Bool) {
        self.base = base
        self.isBusy = isBusy
        self.retryDelay = UInt64(retryDelay * 1e9)
    }

    public var displayName: String { base.displayName }
    public var contextTokens: Int { base.contextTokens }
    public func warmUp() async { await base.warmUp() }

    public func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        var o = options
        o.background = true
        while true {
            try Task.checkCancellation()
            while await isBusy() {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            do {
                return try await base.generate(messages, options: o)
            } catch TextGeneratorError.preempted {
                try await Task.sleep(nanoseconds: retryDelay)
            }
        }
    }
}
