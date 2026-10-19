import Foundation
import AVFoundation
import Speech
import ShoutASR

/// macOS 26 on-device dictation model (SpeechAnalyzer + DictationTranscriber).
@available(macOS 26.0, *)
public final class AppleSpeechEngine: SpeechRecognizer, @unchecked Sendable {
    public let displayName = "Apple Speech"
    private let defaultLocale: Locale

    public init(locale: Locale = .current) {
        defaultLocale = locale
    }

    public static var isSupported: Bool { SpeechTranscriber.isAvailable }

    public func warmUp() async {
        // Makes sure the language assets are installed before the first dictation.
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: defaultLocale) {
            let t = DictationTranscriber(locale: locale, preset: .longDictation)
            if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
                try? await req.downloadAndInstall()
            }
        }
    }

    public func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptionResult {
        let start = Date()
        let wanted = options.language.map { Locale(identifier: $0) } ?? defaultLocale
        var resolved = await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        if resolved == nil { resolved = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale = resolved else {
            throw SpeechRecognizerError.unavailable("Apple Speech does not support \(wanted.identifier)")
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !options.vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(options.vocabulary.prefix(100))
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechRecognizerError.unavailable("No compatible audio format for Apple Speech")
        }
        let buffer = try Self.makeBuffer(samples, format: format)

        let collector = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }
        let input = AsyncStream<AnalyzerInput> { cont in
            cont.yield(AnalyzerInput(buffer: buffer))
            cont.finish()
        }
        do {
            try await analyzer.start(inputSequence: input)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            // Otherwise the collector would wait for results that never come.
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        let text = try await collector.value
        return TranscriptionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                   language: locale.language.languageCode?.identifier,
                                   noSpeechProbability: nil,
                                   inferenceSeconds: Date().timeIntervalSince(start))
    }

    static func makeBuffer(_ samples: [Float], format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            throw SpeechRecognizerError.inferenceFailed("cannot allocate audio for Apple Speech")
        }
        srcBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { srcBuf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if format == src { return srcBuf }
        guard let conv = AVAudioConverter(from: src, to: format) else {
            throw SpeechRecognizerError.inferenceFailed("cannot convert audio for Apple Speech")
        }
        let ratio = format.sampleRate / src.sampleRate
        let cap = AVAudioFrameCount(Double(samples.count) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else {
            throw SpeechRecognizerError.inferenceFailed("cannot allocate audio for Apple Speech")
        }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return srcBuf
        }
        if let err { throw err }
        if status == .error { throw SpeechRecognizerError.inferenceFailed("cannot convert audio for Apple Speech") }
        return out
    }
}
