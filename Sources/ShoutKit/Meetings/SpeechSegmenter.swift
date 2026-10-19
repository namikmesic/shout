import Foundation
import Accelerate

/// A stretch of speech cut from a continuous 16 kHz track.
public struct SpeechSegment: Sendable, Equatable {
    /// Track position (in samples) of the first sample.
    public let start: Int
    public let samples: [Float]
    public var end: Int { start + samples.count }
    public var startMs: Int { start / 16 }
    public var endMs: Int { end / 16 }

    public init(start: Int, samples: [Float]) { self.start = start; self.samples = samples }
}

/// Energy-based voice activity endpointing for live meeting transcription.
///
/// Audio is consumed in 30 ms frames. A frame is voiced when it rises clearly above an adaptive noise
/// floor and above an absolute level. Speech starts after 3 of 5 voiced frames (with pre-roll so word
/// onsets survive) and ends at a pause, so each segment is roughly one utterance:
/// - a pause of `endSilence` ends the segment;
/// - past `softMax` it ends at the next short pause;
/// - past `hardMax` it is cut at the quietest frame of the last 3 seconds.
/// Segments with too little voiced audio are dropped as noise.
public final class SpeechSegmenter {
    public struct Config: Sendable {
        public var endSilence: Double = 0.7
        public var softMax: Double = 15
        public var softPause: Double = 0.3
        public var hardMax: Double = 28
        public var preRoll: Double = 0.3
        public var tail: Double = 0.25
        public var minSpeech: Double = 0.3
        /// Voiced frames must exceed the noise floor by this much…
        public var marginDB: Float = 10
        /// …and this absolute level.
        public var absoluteFloorDB: Float = -50
        public init() {}
    }

    public static let frame = 480 // 30 ms at 16 kHz

    private struct Frame { var samples: [Float]; var db: Float }

    private let config: Config
    private var position: Int           // track position of the next unconsumed sample
    private var partial: [Float] = []   // samples not yet forming a whole frame
    private var preRoll: [Frame] = []   // recent frames kept so an onset can start a little earlier
    private var votes: [Bool] = []

    private var active = false
    private var segStart = 0
    private var segSamples: [Float] = []
    private var segFrameDB: [Float] = []
    private var lastVoicedEnd = 0
    private var voicedFrames = 0
    private var silenceFrames = 0

    public private(set) var noiseFloorDB: Float = -60
    /// True while an utterance is in progress (for "speaking…" indicators).
    public var isSpeaking: Bool { active }
    /// Track position of the next sample this segmenter expects.
    public var trackPosition: Int { position + partial.count }

    public init(config: Config = Config(), startPosition: Int = 0) {
        self.config = config
        self.position = startPosition
    }

    /// Consumes samples and returns any segments that ended inside them.
    public func process(_ x: [Float]) -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        var buffer = partial
        buffer.append(contentsOf: x)
        let frame = Self.frame
        var i = 0
        while i + frame <= buffer.count {
            out.append(contentsOf: consume(Array(buffer[i..<(i + frame)])))
            i += frame
        }
        partial = Array(buffer[i...])
        return out
    }

    /// Ends any utterance in progress (end of a recording leg or of the file).
    public func flush() -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        if !partial.isEmpty {
            // Evaluate the last partial frame too, then drop the padding so positions stay exact.
            let pad = Self.frame - partial.count
            let f = partial + [Float](repeating: 0, count: pad)
            partial = []
            out.append(contentsOf: consume(f))
            position -= pad
            if active { segSamples.removeLast(min(pad, segSamples.count)) }
        }
        if active, let s = endSegment(cutAt: min(lastVoicedEnd + samples(config.tail), segStart + segSamples.count)) {
            out.append(s)
        }
        active = false; votes = []; preRoll = []
        segSamples = []; segFrameDB = []; voicedFrames = 0; silenceFrames = 0
        return out
    }

    /// Consumes `count` samples of digital silence (gap padding) without building them: an utterance in
    /// progress ends exactly as `process` would end it, and the rest is skipped. Same segments and
    /// positions as `process([Float](repeating: 0, count: count))`, at a fraction of the cost for long gaps.
    public func processSilence(_ count: Int) -> [SpeechSegment] {
        var out: [SpeechSegment] = []
        var left = count
        while left > 0 && (active || partial.contains { $0 != 0 }) {
            let n = min(left, Self.frame * 8)
            out.append(contentsOf: process([Float](repeating: 0, count: n)))
            left -= n
        }
        guard left > 0 else { return out }
        // Idle in digital silence: every frame is unvoiced and ignored by the noise floor, so only the
        // position, the votes and the pre-roll move.
        let total = partial.count + left
        let frames = total / Self.frame
        position += frames * Self.frame
        partial = [Float](repeating: 0, count: total % Self.frame)
        votes.append(contentsOf: repeatElement(false, count: min(frames, 5)))
        if votes.count > 5 { votes.removeFirst(votes.count - 5) }
        let keep = self.frames(config.preRoll) + 5
        let silent = Frame(samples: [Float](repeating: 0, count: Self.frame), db: Self.level([Float](repeating: 0, count: Self.frame)))
        preRoll.append(contentsOf: repeatElement(silent, count: min(frames, keep)))
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        return out
    }

    // MARK: Internals

    private func samples(_ seconds: Double) -> Int { Int(seconds * 16_000) }
    private func frames(_ seconds: Double) -> Int { max(1, Int((seconds / 0.03).rounded())) }

    private static func level(_ f: [Float]) -> Float {
        var rms: Float = 0
        f.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length($0.count)) }
        return 20 * log10(max(rms, 1e-7))
    }

    private func isVoiced(_ db: Float) -> Bool { db > max(noiseFloorDB + config.marginDB, config.absoluteFloorDB) }

    private func consume(_ f: [Float]) -> [SpeechSegment] {
        let frameStart = position
        position += f.count
        let db = Self.level(f)

        // Noise floor: follows quieter frames quickly and louder ones slowly (~1.5 dB/s), so speech
        // does not drag it up, but a noisier room is learnt within seconds. Digital silence (gap
        // padding, an idle system track) says nothing about the room and is ignored.
        if db > -139 {
            if db < noiseFloorDB { noiseFloorDB += (db - noiseFloorDB) * 0.25 }
            else { noiseFloorDB += min(db - noiseFloorDB, 0.045) }
            noiseFloorDB = max(-75, min(-30, noiseFloorDB))
        }

        let voiced = isVoiced(db)
        votes.append(voiced)
        if votes.count > 5 { votes.removeFirst() }

        if !active {
            preRoll.append(Frame(samples: f, db: db))
            let keep = frames(config.preRoll) + 5
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            guard votes.filter({ $0 }).count >= 3 else { return [] }
            // Onset: begin with the pre-roll before the voting window.
            active = true
            segSamples = preRoll.flatMap(\.samples)
            segFrameDB = preRoll.map(\.db)
            segStart = position - segSamples.count
            preRoll = []
            voicedFrames = votes.filter { $0 }.count
            silenceFrames = 0
            lastVoicedEnd = position
            return []
        }

        segSamples.append(contentsOf: f)
        segFrameDB.append(db)
        if voiced { voicedFrames += 1; silenceFrames = 0; lastVoicedEnd = frameStart + f.count }
        else { silenceFrames += 1 }

        let length = Double(segSamples.count) / 16_000
        if silenceFrames >= frames(config.endSilence) {
            return finish(cutAt: lastVoicedEnd + samples(config.tail))
        }
        if length >= config.softMax && silenceFrames >= frames(config.softPause) {
            return finish(cutAt: lastVoicedEnd + samples(min(config.tail, config.softPause / 2)))
        }
        if length >= config.hardMax {
            return hardCut()
        }
        return []
    }

    /// Ends the current segment at `cutAt`; audio after the cut becomes pre-roll for the next one.
    private func finish(cutAt: Int) -> [SpeechSegment] {
        let seg = endSegment(cutAt: cutAt)
        active = false
        votes = []
        return seg.map { [$0] } ?? []
    }

    private func endSegment(cutAt rawCut: Int) -> SpeechSegment? {
        let cut = max(segStart, min(rawCut, segStart + segSamples.count))
        let count = cut - segStart
        let leftover = Array(segSamples[count...])
        let enoughSpeech = Double(voicedFrames) * 0.03 >= config.minSpeech
        let seg = enoughSpeech && count > 0 ? SpeechSegment(start: segStart, samples: Array(segSamples[..<count])) : nil
        // Whole frames ending at the current position become pre-roll (frames stay aligned to the end).
        let skip = leftover.count % Self.frame
        preRoll = stride(from: skip, to: leftover.count, by: Self.frame).map {
            let chunk = Array(leftover[$0..<($0 + Self.frame)])
            return Frame(samples: chunk, db: Self.level(chunk))
        }
        let keep = frames(config.preRoll) + 5
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
        segSamples = []; segFrameDB = []; voicedFrames = 0; silenceFrames = 0
        return seg
    }

    /// Splits a long utterance at the quietest frame of its last 3 seconds and keeps going.
    private func hardCut() -> [SpeechSegment] {
        let window = min(segFrameDB.count - 1, 100)
        var best = segFrameDB.count - 1
        for k in (segFrameDB.count - window)..<segFrameDB.count where segFrameDB[k] < segFrameDB[best] { best = k }
        let cutFrame = max(1, best)
        let cutSample = cutFrame * Self.frame
        let first = SpeechSegment(start: segStart, samples: Array(segSamples[..<cutSample]))
        segStart += cutSample
        segSamples = Array(segSamples[cutSample...])
        segFrameDB = Array(segFrameDB[cutFrame...])
        voicedFrames = segFrameDB.filter(isVoiced).count
        return [first]
    }
}
