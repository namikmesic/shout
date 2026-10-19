import Foundation
import ShoutASR

/// What transcription needs from settings and the dictionary, captured as a value.
public struct MeetingTranscriptionSettings: Sendable {
    public var language: String?
    /// Words passed to engines that accept a prompt (Whisper).
    public var vocabulary: [String]
    /// Dictionary entries used to correct spellings afterwards (all engines).
    public var vocabularyEntries: [DictionaryEntry]

    public init(language: String? = nil, vocabulary: [String] = [], vocabularyEntries: [DictionaryEntry] = []) {
        self.language = language; self.vocabulary = vocabulary; self.vocabularyEntries = vocabularyEntries
    }
}

public enum MeetingTranscription {
    /// Transcribes one utterance. Returns "" when it holds no usable speech.
    public static func transcribe(_ segment: SpeechSegment, recognizer: SpeechRecognizer,
                                  settings: MeetingTranscriptionSettings) async throws -> String {
        guard !AudioDSP.isSilent(segment.samples) else { return "" }
        let audio = AudioDSP.normalize(AudioDSP.highPass(segment.samples))
        let speech = AudioDSP.speechSeconds(audio)
        let r = try await recognizer.transcribe(audio, options: TranscriptionOptions(language: settings.language,
                                                                                      vocabulary: settings.vocabulary))
        if let nsp = r.noSpeechProbability, nsp > 0.8, speech < 1.5 { return "" }
        let text = TextRules.cleanASRArtifacts(r.text, speechSeconds: speech)
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        return TextRules.applyVocabulary(text, words: settings.vocabularyEntries).0
    }
}

/// Transcribes meeting utterances one at a time, in arrival order, with the shared recognizer.
/// Submitting one job at a time keeps at most one meeting segment ahead of a dictation that needs
/// the same engine.
public actor MeetingTranscriber {
    public struct Job: Sendable {
        public let meetingID: String
        public let source: MeetingSource
        public let segment: SpeechSegment
        public init(meetingID: String, source: MeetingSource, segment: SpeechSegment) {
            self.meetingID = meetingID; self.source = source; self.segment = segment
        }
    }

    public typealias RecognizerProvider = @Sendable () async throws -> SpeechRecognizer
    public typealias SettingsProvider = @Sendable () async -> MeetingTranscriptionSettings
    public typealias ResultHandler = @Sendable (Job, Result<String, Error>) async -> Void

    /// Synchronous hand-off from audio queues: a job (or scan) submitted before `waitUntilDone` is always
    /// seen by it.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var jobs: [Job] = []
        /// Scans still looking for utterances, by meeting.
        private var scans: [String: Int] = [:]
        func add(_ j: Job) { lock.lock(); jobs.append(j); lock.unlock() }
        func beginScan(_ id: String) { lock.lock(); scans[id, default: 0] += 1; lock.unlock() }
        /// The scan's jobs arrive as the scan ends, so the meeting never looks done in between.
        func endScan(_ id: String, found: [Job]) {
            lock.lock(); defer { lock.unlock() }
            jobs += found
            if let n = scans[id], n > 1 { scans[id] = n - 1 } else { scans[id] = nil }
        }
        func drain() -> [Job] { lock.lock(); defer { jobs = []; lock.unlock() }; return jobs }
        func count(_ id: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return jobs.filter { $0.meetingID == id }.count + scans[id, default: 0]
        }
    }

    private nonisolated let inbox = Inbox()
    private var queue: [Job] = []
    private var running = false
    private var inFlight: Job?
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let recognizer: RecognizerProvider
    private let settings: SettingsProvider
    private let onResult: ResultHandler

    public init(recognizer: @escaping RecognizerProvider, settings: @escaping SettingsProvider,
                onResult: @escaping ResultHandler) {
        self.recognizer = recognizer; self.settings = settings; self.onResult = onResult
    }

    /// Queues an utterance. Safe to call from any thread.
    public nonisolated func submit(_ job: Job) {
        inbox.add(job)
        Task { await self.pump() }
    }

    /// Queues the utterances `scan` finds in recorded audio (crash recovery), running it in the background.
    /// Until it returns, the meeting counts as pending, so `waitUntilDone` also waits for the scan and for
    /// what it finds. Safe to call from any thread.
    public nonisolated func submit(meetingID: String, scanning scan: @escaping @Sendable () -> [Job]) {
        inbox.beginScan(meetingID)
        Task.detached(priority: .utility) {
            self.inbox.endScan(meetingID, found: scan())
            await self.scanEnded(meetingID)
        }
    }

    public func pending(for meetingID: String) -> Int {
        queue.filter { $0.meetingID == meetingID }.count + inbox.count(meetingID) + (inFlight?.meetingID == meetingID ? 1 : 0)
    }

    /// Returns once every utterance of the meeting submitted so far has been transcribed, including those
    /// a scan submitted so far finds.
    public func waitUntilDone(_ meetingID: String) async {
        pump()
        guard pending(for: meetingID) > 0 else { return }
        await withCheckedContinuation { waiters[meetingID, default: []].append($0) }
    }

    private func pump() {
        queue.append(contentsOf: inbox.drain())
        guard !running, !queue.isEmpty else { return }
        running = true
        Task { await run() }
    }

    /// A scan that found nothing leaves no job to release the meeting's waiters, so they are released here.
    private func scanEnded(_ meetingID: String) {
        pump()
        if pending(for: meetingID) == 0, let w = waiters.removeValue(forKey: meetingID) { w.forEach { $0.resume() } }
    }

    private func run() async {
        while true {
            queue.append(contentsOf: inbox.drain())
            guard !queue.isEmpty else { break }
            let job = queue.removeFirst()
            inFlight = job
            do {
                let rec = try await recognizer()
                let text = try await MeetingTranscription.transcribe(job.segment, recognizer: rec, settings: await settings())
                await onResult(job, .success(text))
            } catch {
                await onResult(job, .failure(error))
            }
            inFlight = nil
            if pending(for: job.meetingID) == 0, let w = waiters.removeValue(forKey: job.meetingID) {
                w.forEach { $0.resume() }
            }
        }
        running = false
    }
}

/// Removes call audio that the microphone picked up (speakers instead of headphones) from "You" lines.
/// Both lines come from the same recognizer, so echo shows up as runs of identical words in a
/// microphone line and in the call audio around the same time. Runs of 3+ words are cut; small gaps
/// between cut runs go too. A line with almost nothing left is hidden entirely.
///
/// This is a text-level backstop; echo cancellation on the meeting microphone does the main work.
public enum EchoMatcher {
    public struct Cleaned: Equatable, Sendable {
        /// What is left of the microphone line ("" when it was all echo).
        public var text: String
        /// The echo was at the start of the line, so the line really starts later.
        public var removedPrefix: Bool
        /// Index (in the call-audio words) of the last word of that leading echo.
        public var prefixEndSystemWord: Int? = nil
    }

    struct Token { let norm: String; let range: Range<String.Index> }

    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i].isLetter || s[i].isNumber else { i = s.index(after: i); continue }
            var j = i
            while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "'" || s[j] == "’" { j = s.index(after: j) }
            let norm = s[i..<j].lowercased().replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            out.append(Token(norm: norm, range: i..<j))
            i = j
        }
        return out
    }

    /// Returns the microphone line without the words it shares with the call audio, or nil if none.
    public static func removeEcho(from mic: String, heard system: String) -> Cleaned? {
        let m = tokens(mic), sys = tokens(system).map(\.norm)
        guard m.count >= 3, sys.count >= 3 else { return nil }
        var removed = [Bool](repeating: false, count: m.count)
        var runs: [(mic: Int, length: Int, sys: Int)] = []
        var i = 0
        while i < m.count {
            var best = 0, bestJ = 0
            for j in 0..<sys.count where sys[j] == m[i].norm {
                var k = 0
                while i + k < m.count, j + k < sys.count, m[i + k].norm == sys[j + k] { k += 1 }
                if k > best { best = k; bestJ = j }
            }
            if best >= 3 {
                for k in i..<(i + best) { removed[k] = true }
                runs.append((i, best, bestJ)); i += best
            } else { i += 1 }
        }
        guard let first = runs.first, let last = runs.last else { return nil }
        // A word or two at either edge that differs only because the recognizer heard it differently
        // ("Kriya" for "Priya") belongs to the echo when the call audio has words there too.
        if first.mic > 0, first.mic <= 2, first.sys >= first.mic { for k in 0..<first.mic { removed[k] = true } }
        let tail = m.count - (last.mic + last.length)
        if tail > 0, tail <= 2, sys.count - (last.sys + last.length) >= tail { for k in (m.count - tail)..<m.count { removed[k] = true } }
        // Bridge short gaps (≤ 2 words) between removed runs for the same reason.
        for k in 0..<m.count where !removed[k] {
            if let prevEnd = (0..<k).last(where: { removed[$0] }), let next = ((k + 1)..<m.count).first(where: { removed[$0] }),
               next - prevEnd - 1 <= 2 { removed[k] = true }
        }
        let kept = m.indices.filter { !removed[$0] }
        var prefixEnd: Int?
        if removed[0] {
            let lastRemoved = (m.indices.first { !removed[$0] } ?? m.count) - 1
            if let run = runs.last(where: { $0.mic <= lastRemoved }) {
                prefixEnd = run.sys + min(run.length - 1, lastRemoved - run.mic)
            }
        }
        if kept.count < 2 { return Cleaned(text: "", removedPrefix: removed[0], prefixEndSystemWord: prefixEnd) }
        // Rebuild from the original text, keeping each kept run with its punctuation.
        var pieces: [String] = []
        var k = 0
        while k < m.count {
            guard !removed[k] else { k += 1; continue }
            var e = k
            while e + 1 < m.count, !removed[e + 1] { e += 1 }
            let end = e + 1 < m.count ? m[e + 1].range.lowerBound : mic.endIndex
            pieces.append(String(mic[m[k].range.lowerBound..<end]).trimmingCharacters(in: .whitespaces))
            k = e + 1
        }
        var text = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "^[,.;:!?\\s]+", with: "", options: .regularExpression)
        if let f = text.first, f.isLowercase { text = f.uppercased() + text.dropFirst() }
        return Cleaned(text: text, removedPrefix: removed[0], prefixEndSystemWord: prefixEnd)
    }

    /// Time overlap with some slack for capture latency.
    public static func overlaps(_ a: MeetingSegment, _ b: MeetingSegment, slackMs: Int = 1_500) -> Bool {
        a.startMs < b.endMs + slackMs && b.startMs < a.endMs + slackMs
    }

    public struct Resolution: Sendable {
        public var text: String
        /// Where the line really starts once leading echo is removed.
        public var startMs: Int
    }

    /// For each microphone line that contains call audio, what is left of it. Lines are compared
    /// with the system lines that overlap them in time.
    public static func resolve(_ segments: [MeetingSegment]) -> [String: Resolution] {
        let system = segments.filter { $0.source == .system && $0.marker == nil }.sorted { $0.startMs < $1.startMs }
        var out: [String: Resolution] = [:]
        for mic in segments where mic.source == .mic && mic.marker == nil && !mic.latched && mic.editedText == nil {
            let near = system.filter { overlaps(mic, $0) }
            guard !near.isEmpty, let c = removeEcho(from: mic.text, heard: near.map(\.text).joined(separator: " ")) else { continue }
            var start = mic.startMs
            if c.removedPrefix, let word = c.prefixEndSystemWord {
                // The line starts after the call-audio line its leading echo came from.
                var count = 0
                for seg in near {
                    count += tokens(seg.text).count
                    if word < count { start = max(start, min(seg.endMs, mic.endMs)); break }
                }
            }
            out[mic.id] = Resolution(text: c.text, startMs: start)
        }
        return out
    }
}
