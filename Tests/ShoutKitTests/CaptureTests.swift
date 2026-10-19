import XCTest
import AVFoundation
@testable import ShoutKit

/// Deterministic signals so tests are reproducible.
private struct Signal {
    var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: state)) / Float(Int32.max)
    }
    /// Speech-like audio: noise shaped by a syllable envelope (~4 Hz) with pauses, at about `rms`.
    mutating func speech(_ seconds: Double, rms: Float, phase: Double = 0) -> [Float] {
        let n = Int(seconds * 16_000)
        var lp: Float = 0
        return (0..<n).map { i in
            let t = Double(i) / 16_000
            let syllable = max(0, sin(2 * .pi * 4 * t + phase))
            let phrase: Float = sin(2 * .pi * 0.35 * t + phase) > -0.3 ? 1 : 0
            lp = 0.7 * lp + 0.3 * next() // a little low-pass, like voice
            return lp * Float(syllable) * phrase * rms * 3
        }
    }
    mutating func noise(_ count: Int, rms: Float) -> [Float] { (0..<count).map { _ in next() * rms * 1.732 } }
}

/// Echo as a microphone hears it: delayed, through a short room response, attenuated.
private func echo(of x: [Float], delayMs: Int, gain: Float, seed: UInt32 = 7) -> [Float] {
    var s = Signal(seed: seed)
    let delay = delayMs * 16
    let room: [Float] = (0..<160).map { k in k == 0 ? 1 : s.next() * 0.3 * Float(exp(-Double(k) / 40)) }
    var y = [Float](repeating: 0, count: x.count)
    for i in 0..<x.count {
        var acc: Float = 0
        for k in 0..<room.count {
            let j = i - delay - k
            if j >= 0 { acc += room[k] * x[j] }
        }
        y[i] = acc * gain
    }
    return y
}

private func mix(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

private func writePCM(_ samples: [Float], to url: URL) throws {
    let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
    try pcm.withUnsafeBytes { Data($0) }.write(to: url)
}

private func sine(_ hz: Double, seconds: Double, amplitude: Float = 0.3) -> [Float] {
    (0..<Int(seconds * 16_000)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / 16_000)) }
}

/// Zero crossings per second: a frequency estimate for a sine.
private func crossingsPerSecond(_ x: [Float]) -> Double {
    guard x.count > 1 else { return 0 }
    var n = 0
    for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) { n += 1 }
    return Double(n) / (Double(x.count) / 16_000)
}

private func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }

private func temporaryFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shout-capture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Track writing

final class MeetingTrackWriteTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testFailedWritesKeepTheTimelineAndLaterAudioLandsInPlace() throws {
        let url = dir.appendingPathComponent("mic.pcm")
        let t = try MeetingTrack(source: .mic, url: url)
        t.beginLeg(at: 0)
        t.append([Float](repeating: 0.25, count: 16_000), at: 0)
        XCTAssertEqual(t.sampleCount, 16_000)

        // A full disk: the process may not grow files past 40 000 bytes (20 000 samples).
        signal(SIGXFSZ, SIG_IGN)
        var original = rlimit()
        getrlimit(RLIMIT_FSIZE, &original)
        var limited = original
        limited.rlim_cur = 40_000
        setrlimit(RLIMIT_FSIZE, &limited)
        t.append([Float](repeating: 0.25, count: 16_000), at: 1)
        let during = t.sampleCount
        let failed = t.stats.writeFailed
        setrlimit(RLIMIT_FSIZE, &original)
        signal(SIGXFSZ, SIG_DFL)

        XCTAssertTrue(failed)
        XCTAssertNotNil(t.stats.writeError)
        XCTAssertEqual(during, 32_000, "the timeline moves on although the audio was not kept")
        XCTAssertLessThan(MeetingTrack.sampleCount(url), 32_000)

        // Space is back: the next chunk goes to its own position, the lost stretch reads as silence.
        t.append([Float](repeating: -0.5, count: 16_000), at: 2)
        XCTAssertEqual(t.sampleCount, 48_000)
        XCTAssertFalse(t.stats.writeFailed)
        XCTAssertEqual(MeetingTrack.sampleCount(url), 48_000)
        let s = try MeetingTrack.read(url, offset: 0)
        XCTAssertEqual(s[15_999], 0.25, accuracy: 0.001)
        XCTAssertEqual(s[30_000], 0)
        XCTAssertEqual(s[32_000], -0.5, accuracy: 0.001)
        XCTAssertEqual(s[47_999], -0.5, accuracy: 0.001)
    }

    func testAudioAfterCloseIsDroppedWithoutAnError() throws {
        let url = dir.appendingPathComponent("system.pcm")
        let t = try MeetingTrack(source: .system, url: url)
        t.beginLeg(at: 0)
        t.append([Float](repeating: 0.1, count: 640), at: 0)
        t.endLeg(at: 1)
        t.close()
        t.append([Float](repeating: 0.1, count: 640), at: 1.5)
        XCTAssertEqual(t.sampleCount, 16_000)
        XCTAssertEqual(MeetingTrack.sampleCount(url), 16_000)
        XCTAssertFalse(t.stats.writeFailed)
    }

    func testLongGapsAreWrittenSparsely() throws {
        let url = dir.appendingPathComponent("system.pcm")
        let t = try MeetingTrack(source: .system, url: url)
        t.beginLeg(at: 0)
        t.append([Float](repeating: 0.1, count: 1_600), at: 0)
        t.append([Float](repeating: 0.1, count: 1_600), at: 600) // ten minutes later
        XCTAssertEqual(t.endLeg(at: 601), 601 * 16_000)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        XCTAssertEqual(values.fileSize, 601 * 16_000 * 2)
        XCTAssertLessThan(values.totalFileAllocatedSize ?? .max, 2_000_000, "the gap takes no disk space")
        let s = try MeetingTrack.read(url, offset: 600 * 16_000 - 10, count: 20)
        XCTAssertEqual(s[9], 0)
        XCTAssertEqual(s[10], 0.1, accuracy: 0.001)
    }
}

final class SpeechSegmenterSilenceTests: XCTestCase {
    func testSilenceShortcutMatchesProcessingZeros() {
        for gap in [100, 7_000, 16_000, 200_000] {
            var n = Signal(seed: 3)
            // Ends mid-utterance and mid-frame, so the shortcut has to finish the utterance first.
            let before = n.noise(8_000, rms: 0.001) + n.noise(19_333, rms: 0.1)
            let after = n.noise(4_000, rms: 0.001) + n.noise(24_000, rms: 0.1) + n.noise(16_000, rms: 0.001)
            let a = SpeechSegmenter(), b = SpeechSegmenter()
            let full = a.process(before) + a.process([Float](repeating: 0, count: gap)) + a.process(after) + a.flush()
            let fast = b.process(before) + b.processSilence(gap) + b.process(after) + b.flush()
            XCTAssertEqual(full, fast, "gap \(gap)")
            XCTAssertEqual(a.trackPosition, b.trackPosition)
            if gap >= 16_000 { XCTAssertEqual(full.count, 2, "gap \(gap)") }
        }
    }
}

// MARK: - Real-time hand-off

final class RealtimeAudioQueueTests: XCTestCase {
    /// Host time of frame `frame` of a stream at `rate` that started at host time 1 s.
    private func host(_ frame: Int, rate: Double = 48_000) -> UInt64 {
        MeetingClock.hostTime(seconds: 1 + Double(frame) / rate)
    }

    /// Pushes contiguous callbacks of `size` frames until the pool is full; returns the frames it took.
    private func fill(_ q: RealtimeAudioQueue, callback size: Int, rate: Double) -> Int {
        let x = [Float](repeating: 0.5, count: size)
        var frame = 0
        while x.withUnsafeBufferPointer({ q.push($0.baseAddress!, count: size, hostTime: host(frame, rate: rate), sampleRate: rate, generation: 1) }) {
            frame += size
            if frame > Int(rate) * 60 { break }
        }
        return frame
    }

    func testThePoolHoldsTwoSecondsWhateverTheCallbackSize() {
        for rate in [44_100.0, 48_000, 96_000] {
            for size in [64, 128, 256, 441, 480, 512, 1_024, 4_096, 4_800] {
                let q = RealtimeAudioQueue()
                let seconds = Double(fill(q, callback: size, rate: rate)) / rate
                XCTAssertGreaterThanOrEqual(seconds, 2, "\(size)-frame callbacks at \(Int(rate)) Hz")
                XCTAssertGreaterThanOrEqual(seconds, q.guaranteedSeconds(sampleRate: rate) - Double(size) / rate)
            }
        }
        XCTAssertGreaterThanOrEqual(RealtimeAudioQueue().guaranteedSeconds(sampleRate: 192_000), 2)
    }

    func testContiguousCallbacksArePackedAndABreakStartsANewChunk() {
        let q = RealtimeAudioQueue(blocks: 16, framesPerBlock: 2_048, publishSeconds: 0.01) // 480 frames at 48 kHz
        let x = (0..<128).map(Float.init)
        x.withUnsafeBufferPointer { p in
            // Four contiguous 128-frame callbacks: one chunk, handed on once it holds 10 ms.
            for i in 0..<4 { q.push(p.baseAddress!, count: 128, hostTime: host(i * 128), sampleRate: 48_000, generation: 1) }
            XCTAssertEqual(q.drain { _ in }, 1)
            for i in 4..<7 { q.push(p.baseAddress!, count: 128, hostTime: host(i * 128), sampleRate: 48_000, generation: 1) }
            XCTAssertEqual(q.drain { _ in }, 0, "less than 10 ms waits for more")
            // 10 ms missing: not the continuation of the waiting block.
            q.push(p.baseAddress!, count: 128, hostTime: host(896 + 480), sampleRate: 48_000, generation: 1)
            // A restart: a new stream, although it follows in time.
            q.push(p.baseAddress!, count: 128, hostTime: host(896 + 480 + 128), sampleRate: 48_000, generation: 2)
        }
        q.push(nil, count: 0, hostTime: host(3_000), sampleRate: 48_000, generation: 2) // a heartbeat hands on what waits
        var got: [(count: Int, time: Double, gen: Int, first: Float, last: Float)] = []
        q.drain { got.append(($0.samples.count, $0.time, $0.generation, $0.samples.first ?? -1, $0.samples.last ?? -1)) }
        XCTAssertEqual(got.map(\.count), [384, 128, 128, 0])
        XCTAssertEqual(got.map(\.gen), [1, 1, 2, 2])
        XCTAssertEqual(got[0].time, 1 + 512.0 / 48_000, accuracy: 1e-6)
        XCTAssertEqual(got[1].time, 1 + Double(896 + 480) / 48_000, accuracy: 1e-6, "audio after a gap keeps its own time")
        XCTAssertEqual(got[2].time, 1 + Double(896 + 608) / 48_000, accuracy: 1e-6)
        XCTAssertEqual(got[0].first, 0)
        XCTAssertEqual(got[0].last, 127)
    }

    func testChunksArriveInOrderWithTheirTiming() {
        let q = RealtimeAudioQueue(blocks: 8, framesPerBlock: 4, publishSeconds: 0) // every callback handed on at once
        var values: [Float] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        values.withUnsafeBufferPointer { p in
            XCTAssertTrue(q.push(p.baseAddress!, count: 3, hostTime: 100, sampleRate: 48_000, generation: 1))
            XCTAssertTrue(q.push(p.baseAddress! + 3, count: 7, hostTime: 200, sampleRate: 48_000, generation: 1)) // split in two
        }
        XCTAssertTrue(q.push(nil, count: 0, hostTime: 300, sampleRate: 48_000, generation: 2)) // heartbeat
        var got: [(samples: [Float], host: UInt64, offset: Int, gen: Int)] = []
        XCTAssertEqual(q.drain { got.append((Array($0.samples), $0.hostTime, $0.frameOffset, $0.generation)) }, 4)
        XCTAssertEqual(got.map(\.samples), [[1, 2, 3], [4, 5, 6, 7], [8, 9, 10], []])
        XCTAssertEqual(got.map(\.host), [100, 200, 200, 300])
        XCTAssertEqual(got.map(\.offset), [0, 0, 4, 0])
        XCTAssertEqual(got.map(\.gen), [1, 1, 1, 2])
        values[0] = 0
        XCTAssertEqual(q.drain { _ in }, 0)
    }

    func testAFullPoolDropsAndCountsInsteadOfWaiting() {
        let q = RealtimeAudioQueue(blocks: 2, framesPerBlock: 4, publishSeconds: 0)
        let x: [Float] = [1, 2, 3, 4]
        x.withUnsafeBufferPointer { p in
            XCTAssertTrue(q.push(p.baseAddress!, count: 4, hostTime: 1, sampleRate: 16_000, generation: 0))
            XCTAssertTrue(q.push(p.baseAddress!, count: 4, hostTime: 2, sampleRate: 16_000, generation: 0))
            XCTAssertFalse(q.push(p.baseAddress!, count: 4, hostTime: 3, sampleRate: 16_000, generation: 0))
        }
        XCTAssertEqual(q.drain { _ in }, 2)
        var dropped: [Int] = []
        x.withUnsafeBufferPointer { p in _ = q.push(p.baseAddress!, count: 4, hostTime: 4, sampleRate: 16_000, generation: 0) }
        q.drain { dropped.append($0.dropped) }
        XCTAssertEqual(dropped, [4])
    }

    func testDropsAfterAFullPoolAreCountedOnTheNextChunk() {
        let q = RealtimeAudioQueue(blocks: 8, framesPerBlock: 2_048)
        let filled = fill(q, callback: 512, rate: 48_000) // the last push of `fill` was dropped already
        let x = [Float](repeating: 0.5, count: 512)
        x.withUnsafeBufferPointer { p in
            for k in 1...3 { XCTAssertFalse(q.push(p.baseAddress!, count: 512, hostTime: host(filled + k * 512), sampleRate: 48_000, generation: 1)) }
        }
        var chunks = 0
        q.drain { XCTAssertEqual($0.dropped, 0); chunks += 1 }
        XCTAssertGreaterThan(chunks, 0)
        x.withUnsafeBufferPointer { p in
            XCTAssertTrue(q.push(p.baseAddress!, count: 512, hostTime: host(filled + 4 * 512), sampleRate: 48_000, generation: 1))
        }
        var dropped: [Int] = []
        var times: [Double] = []
        q.drain { dropped.append($0.dropped); times.append($0.time) }
        XCTAssertEqual(dropped, [4 * 512], "the push that found the pool full, and the three after it")
        XCTAssertEqual(times.first ?? 0, 1 + Double(filled + 4 * 512) / 48_000, accuracy: 1e-6, "the next audio keeps its own time")

        var counter = AudioDropCounter()
        XCTAssertTrue(counter.record(frames: 4_800, sampleRate: 48_000, at: 100), "an episode begins: log it")
        XCTAssertFalse(counter.record(frames: 2_400, sampleRate: 48_000, at: 105))
        XCTAssertFalse(counter.record(frames: 0, sampleRate: 48_000, at: 200))
        XCTAssertTrue(counter.record(frames: 480, sampleRate: 48_000, at: 120), "after 10 s without drops, a new episode")
        XCTAssertEqual(counter.totalSeconds, 0.16, accuracy: 1e-9)
        XCTAssertEqual(counter.episodes, 2)
        XCTAssertEqual(counter.episodeSeconds, 0.01, accuracy: 1e-9)
    }

    func testConcurrentProducerAndConsumerLoseNothing() {
        // Packed blocks (two callbacks each) and a pool that runs full, with the consumer on another thread:
        // every frame arrives once, in order, at its own time. (Blocks are handed on only when full, so a
        // push that finds the pool empty copied nothing and can be retried.)
        let q = RealtimeAudioQueue(blocks: 32, framesPerBlock: 320, publishSeconds: 1)
        let total = 400_000, size = 160
        let done = DispatchSemaphore(value: 0)
        let producer = Thread {
            var buffer = [Float](repeating: 0, count: size)
            var frame = 0
            while frame < total {
                for k in 0..<size { buffer[k] = Float(frame + k) }
                let ok = buffer.withUnsafeBufferPointer {
                    q.push($0.baseAddress!, count: size, hostTime: self.host(frame), sampleRate: 48_000, generation: 0)
                }
                if ok { frame += size } else { usleep(50) } // the test retries; a real producer drops
            }
            q.push(nil, count: 0, hostTime: self.host(total), sampleRate: 48_000, generation: 0) // hands on the last block
            done.signal()
        }
        producer.start()
        var next = 0
        var corrupt = false
        let deadline = Date().addingTimeInterval(30)
        while next < total, !corrupt, Date() < deadline {
            q.drain { c in
                guard !c.samples.isEmpty else { return }
                if abs(c.time - (1 + Double(next) / 48_000)) > 1e-6 || c.samples.enumerated().contains(where: { $0.element != Float(next + $0.offset) }) {
                    corrupt = true
                }
                next += c.samples.count
            }
        }
        done.wait()
        XCTAssertFalse(corrupt)
        XCTAssertEqual(next, total)
    }
}

final class MicrophoneReleaseTests: XCTestCase {
    func testNothingPendingDoesNotWait() {
        let fence = MicrophoneRelease()
        let start = Date()
        XCTAssertTrue(fence.wait(timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.02)
    }

    func testAStartWaitsForThePendingReleaseOnly() {
        let fence = MicrophoneRelease()
        fence.begin()
        XCTAssertTrue(fence.isPending)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { fence.end() }
        let start = Date()
        XCTAssertTrue(fence.wait(timeout: 0.3))
        let waited = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(waited, 0.04)
        XCTAssertLessThan(waited, 0.25, "returns as soon as the device is released")
        XCTAssertFalse(fence.isPending)
    }

    func testAReleaseThatNeverEndsIsWaitedForAtMostTheBound() {
        let fence = MicrophoneRelease()
        fence.begin()
        let start = Date()
        XCTAssertFalse(fence.wait(timeout: 0.3))
        let waited = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(waited, 0.29)
        XCTAssertLessThan(waited, 0.45, "bounded: the main thread is never held longer")
        fence.end()
        fence.end() // unbalanced ends don't go negative
        XCTAssertTrue(fence.wait(timeout: 0))
    }
}

// MARK: - Echo correlation

final class EchoCorrelationTests: XCTestCase {
    let otherSide: [Float] = { var s = Signal(seed: 1); return s.speech(4, rms: 0.08) }()
    var roomNoise: [Float] { var s = Signal(seed: 99); return s.noise(otherSide.count, rms: 0.001) }

    func testSpeakerEchoLocksAtItsDelay() {
        let e = EchoCorrelation.measure(mic: mix(echo(of: otherSide, delayMs: 40, gain: 0.25), roomNoise), system: otherSide)
        XCTAssertTrue(e.supportsHiding)
        XCTAssertEqual(e.lagMs ?? 0, 40, accuracy: 2)
    }

    func testEchoUnderDoubleTalkIsStillFound() {
        var user = Signal(seed: 2)
        let mic = mix(mix(echo(of: otherSide, delayMs: 60, gain: 0.2), user.speech(4, rms: 0.08, phase: 1)), roomNoise)
        let e = EchoCorrelation.measure(mic: mic, system: otherSide)
        XCTAssertTrue(e.supportsCut)
        XCTAssertEqual(e.lagMs ?? 0, 60, accuracy: 2)
    }

    func testTheUserSpeakingOverTheCallIsNotEcho() {
        for seed in UInt32(10)..<UInt32(40) {
            var a = Signal(seed: seed), b = Signal(seed: seed + 1_000)
            let seconds = 1.5 + Double(seed % 5)
            let system = a.speech(seconds, rms: 0.08, phase: Double(seed))
            let mic = b.speech(seconds, rms: 0.08, phase: Double(seed) * 1.7)
            XCTAssertFalse(EchoCorrelation.measure(mic: mic, system: system).supportsCut, "seed \(seed)")
        }
    }

    func testTheFarEndEchoingTheUserBackIsNotEcho() {
        // The call audio carries the user's voice 300 ms later: the microphone leads, so the line is the user's.
        let system = echo(of: otherSide, delayMs: 300, gain: 0.5)
        XCTAssertFalse(EchoCorrelation.measure(mic: otherSide, system: system).supportsCut)
    }

    func testQuietMicrophoneGivesNoEvidence() {
        let e = EchoCorrelation.measure(mic: roomNoise, system: otherSide)
        XCTAssertEqual(e.windows, 0)
        XCTAssertFalse(e.supportsCut)
    }

    // The B23 case: the user repeats the other side's words with headphones on.
    let ask = MeetingSegment(meetingID: "m", source: .system, startMs: 0, endMs: 3_000,
                             text: "Can you send the pricing proposal by Friday?")
    let reply = MeetingSegment(meetingID: "m", source: .mic, startMs: 3_400, endMs: 6_000,
                               text: "Sure, the pricing proposal by Friday.")

    func testSharedWordsWithoutCorrelatedAudioChangeNothing() {
        XCTAssertNotNil(EchoMatcher.resolve([ask, reply])[reply.id], "the words alone look like echo")
        XCTAssertTrue(EchoMatcher.resolve([ask, reply]) { _ in EchoCorrelation.Evidence(windows: 6, bothActive: 4) }.isEmpty)
    }

    func testCorrelatedAudioLetsTheTextGateCut() {
        let full = EchoCorrelation.Evidence(windows: 6, bothActive: 6, locked: 6, lagMs: 40)
        XCTAssertEqual(EchoMatcher.resolve([ask, reply]) { _ in full }[reply.id]?.text, "")
        // Echo in only part of the line: words may be cut, but the line is never hidden.
        let partial = EchoCorrelation.Evidence(windows: 6, bothActive: 3, locked: 2, lagMs: 40)
        XCTAssertNil(EchoMatcher.resolve([ask, reply]) { _ in partial }[reply.id])
        let mixed = MeetingSegment(meetingID: "m", source: .mic, startMs: 0, endMs: 6_000,
                                   text: "Can you send the pricing proposal by Friday? Yes, I will do that today.")
        XCTAssertEqual(EchoMatcher.resolve([ask, mixed]) { _ in partial }[mixed.id]?.text, "Yes, I will do that today.")
    }

    func testResolveFromTrackFiles() throws {
        let dir = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pad = [Float](repeating: 0, count: 16_000)
        try writePCM(pad + otherSide + pad, to: dir.appendingPathComponent("system.pcm"))
        let sys = MeetingSegment(meetingID: "m", source: .system, startMs: 1_000, endMs: 5_000,
                                 text: "Let's ship the onboarding flow on Monday morning")
        let mic = MeetingSegment(meetingID: "m", source: .mic, startMs: 1_050, endMs: 5_050,
                                 text: "let's ship the onboarding flow on Monday morning")
        // Speakers: the microphone hears the call.
        try writePCM(pad + mix(echo(of: otherSide, delayMs: 50, gain: 0.3), roomNoise) + pad, to: dir.appendingPathComponent("mic.pcm"))
        XCTAssertEqual(EchoMatcher.resolve([sys, mic], folder: dir)[mic.id]?.text, "")
        // Headphones: the user says the same words, the microphone hears only the user.
        var user = Signal(seed: 5)
        try writePCM(pad + user.speech(4, rms: 0.08, phase: 2) + pad, to: dir.appendingPathComponent("mic.pcm"))
        XCTAssertTrue(EchoMatcher.resolve([sys, mic], folder: dir).isEmpty)
    }
}

// MARK: - Archive

final class MeetingArchiveTests: XCTestCase {
    var dir: URL!
    let micAudio = sine(440, seconds: 10)
    let systemAudio = sine(1_000, seconds: 7) // shorter: padded with silence in the archive

    override func setUpWithError() throws {
        dir = try temporaryFolder()
        try writePCM(micAudio, to: dir.appendingPathComponent("mic.pcm"))
        try writePCM(systemAudio, to: dir.appendingPathComponent("system.pcm"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func archive(_ archiver: MeetingArchiver) throws -> Int? {
        let done = expectation(description: "archived")
        nonisolated(unsafe) var result: Result<Int?, Error>?
        archiver.archive(folder: dir) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 60)
        return try XCTUnwrap(result).get()
    }

    func testEncodeVerifyCommitAndReadBack() throws {
        let frames = try archive(MeetingArchiver())
        XCTAssertEqual(frames, 160_000)
        let files = MeetingArchive.files(in: dir)
        XCTAssertNotNil(files.archive)
        XCTAssertNil(files.mic, "raw tracks are removed once the archive verified")
        XCTAssertNil(files.system)
        XCTAssertEqual(files.preferred, .archive(dir.appendingPathComponent("audio.m4a")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.partial.m4a").path))
        XCTAssertEqual(try MeetingArchive.verify(dir.appendingPathComponent("audio.m4a"), expectedFrames: 160_000), 160_000, accuracy: 2048)
        let size = try XCTUnwrap(try dir.appendingPathComponent("audio.m4a").resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let stereo = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false))
        let bitRate = MeetingArchive.bitRate(from: stereo)
        print("archive: \(size) bytes for 10 s at \(bitRate) bit/s")
        XCTAssertGreaterThanOrEqual(bitRate, 32_000)
        XCTAssertLessThan(size, 10 * bitRate / 8 * 5 / 4, "about the requested bit rate")

        // Left is You, right is Others, on the same timeline.
        let you = try MeetingArchive.read(.mic, in: dir, offset: 32_000, count: 16_000)
        let others = try MeetingArchive.read(.system, in: dir, offset: 32_000, count: 16_000)
        XCTAssertEqual(crossingsPerSecond(you), 880, accuracy: 20)
        XCTAssertEqual(crossingsPerSecond(others), 2_000, accuracy: 40)
        XCTAssertEqual(rms(you), 0.21, accuracy: 0.03)
        let tail = try MeetingArchive.read(.system, in: dir, offset: 8 * 16_000, count: 16_000)
        XCTAssertLessThan(rms(tail), 0.01, "the shorter track is padded with silence")
    }

    func testResumeRecreatesTheTracksAtOnceAndRestoresThemInTheBackground() throws {
        let archiver = MeetingArchiver()
        _ = try archive(archiver)
        archiver.prepareForRecording(folder: dir)
        // Right away: full-length tracks to append to, and a marker for the restore.
        let files = MeetingArchive.files(in: dir)
        XCTAssertNotNil(files.mic)
        XCTAssertEqual(MeetingTrack.sampleCount(dir.appendingPathComponent("mic.pcm")), 160_000, accuracy: 2048)
        archiver.waitUntilIdle()
        XCTAssertFalse(MeetingArchive.files(in: dir).restorePending)
        let restored = try MeetingTrack.read(dir.appendingPathComponent("mic.pcm"), offset: 32_000, count: 16_000)
        XCTAssertEqual(crossingsPerSecond(restored), 880, accuracy: 20)
        XCTAssertEqual(rms(restored), 0.21, accuracy: 0.03)
        let system = try MeetingTrack.read(dir.appendingPathComponent("system.pcm"), offset: 32_000, count: 16_000)
        XCTAssertEqual(crossingsPerSecond(system), 2_000, accuracy: 40)

        // Recording appends a new leg; the next archive holds both.
        let track = try MeetingTrack(source: .mic, url: dir.appendingPathComponent("mic.pcm"))
        let start = track.sampleCount
        track.beginLeg(at: 0)
        track.append(sine(440, seconds: 2), at: 0)
        track.endLeg(at: 2)
        track.close()
        let frames = try XCTUnwrap(try archive(archiver))
        XCTAssertEqual(frames, start + 32_000)
        XCTAssertNil(MeetingArchive.files(in: dir).mic)
        let late = try MeetingArchive.read(.mic, in: dir, offset: start + 8_000, count: 16_000)
        XCTAssertEqual(crossingsPerSecond(late), 880, accuracy: 20)
    }

    func testReadingDuringAPendingRestoreUsesTheArchive() throws {
        _ = try archive(MeetingArchiver())
        try MeetingArchive.prepareTracks(folder: dir) // no restore run yet
        XCTAssertTrue(MeetingArchive.files(in: dir).restorePending)
        XCTAssertEqual(MeetingArchive.files(in: dir).preferred, .archive(dir.appendingPathComponent("audio.m4a")))
        let you = try MeetingArchive.read(.mic, in: dir, offset: 16_000, count: 16_000)
        XCTAssertEqual(crossingsPerSecond(you), 880, accuracy: 20)
    }

    func testCancelledEncodeLeavesTheTracksAlone() throws {
        XCTAssertThrowsError(try MeetingArchive.encode(folder: dir, isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
        let files = MeetingArchive.files(in: dir)
        XCTAssertNil(files.archive)
        XCTAssertNotNil(files.mic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.partial.m4a").path))
    }

    func testLaunchRecoveryArchivesIdleMeetingsOnly() throws {
        let root = try temporaryFolder(), original = dir!
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: original) }
        let fm = FileManager.default
        var folders: [String: URL] = [:]
        for name in ["idle", "recording", "transcribing"] {
            let folder = root.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: dir.appendingPathComponent("mic.pcm"), to: folder.appendingPathComponent("mic.pcm"))
            try fm.copyItem(at: dir.appendingPathComponent("system.pcm"), to: folder.appendingPathComponent("system.pcm"))
            folders[name] = folder
        }
        let archiver = MeetingArchiver()
        archiver.prepareForRecording(folder: folders["recording"]!)
        archiver.recoverAll(skipping: ["transcribing"], in: root)
        archiver.waitUntilIdle()
        archiver.waitUntilIdle() // the encodes recovery queued
        XCTAssertNotNil(MeetingArchive.files(in: folders["idle"]!).archive)
        XCTAssertNil(MeetingArchive.files(in: folders["idle"]!).mic)
        XCTAssertNil(MeetingArchive.files(in: folders["recording"]!).archive)
        XCTAssertNotNil(MeetingArchive.files(in: folders["recording"]!).mic)
        XCTAssertNil(MeetingArchive.files(in: folders["transcribing"]!).archive)
        // Archiving after the leg's transcription is what ends "recording" for a folder.
        dir = folders["recording"]!
        XCTAssertEqual(try archive(archiver), 160_000)
    }

    func testFailedEncodeKeepsTheRawTracks() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertThrowsError(try archive(MeetingArchiver()))
        let files = MeetingArchive.files(in: dir)
        XCTAssertNil(files.archive)
        XCTAssertNotNil(files.mic)
        XCTAssertNotNil(files.system)
    }

    func testCrashRecoveryToleratesEveryState() throws {
        // A partial file from an interrupted encode, and a broken archive next to the raw tracks.
        try Data("partial".utf8).write(to: dir.appendingPathComponent("audio.partial.m4a"))
        try Data("not audio".utf8).write(to: dir.appendingPathComponent("audio.m4a"))
        XCTAssertTrue(MeetingArchive.recover(folder: dir))
        var files = MeetingArchive.files(in: dir)
        XCTAssertNil(files.archive)
        XCTAssertNotNil(files.mic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.partial.m4a").path))

        // Archive only: kept as is.
        _ = try archive(MeetingArchiver())
        XCTAssertFalse(MeetingArchive.recover(folder: dir))
        XCTAssertNotNil(MeetingArchive.files(in: dir).archive)

        // A Resume interrupted before the restore finished: recovery finishes it.
        try MeetingArchive.prepareTracks(folder: dir)
        XCTAssertTrue(MeetingArchive.recover(folder: dir))
        files = MeetingArchive.files(in: dir)
        XCTAssertFalse(files.restorePending)
        let restored = try MeetingTrack.read(dir.appendingPathComponent("mic.pcm"), offset: 16_000, count: 16_000)
        XCTAssertEqual(crossingsPerSecond(restored), 880, accuracy: 20)
    }

    func testLegStartsComeFromResumeMarkers() {
        let segments = [
            MeetingSegment(meetingID: "m", source: .marker, startMs: 60_000, endMs: 60_000, marker: .stopped),
            MeetingSegment(meetingID: "m", source: .marker, startMs: 60_000, endMs: 60_000, marker: .resumed),
            MeetingSegment(meetingID: "m", source: .marker, startMs: 90_000, endMs: 90_000, marker: .dictated),
        ]
        XCTAssertEqual(MeetingArchive.legStarts(segments), [0, 60_000])
    }
}

/// A 30 ms rising chirp under a Hann window: its correlation peak is sharp, so lossy compression can't
/// hide a timeline offset the way a steady tone would.
private func chirp() -> [Float] {
    let n = 480
    return (0..<n).map { i in
        let t = Double(i) / 16_000, duration = Double(n) / 16_000
        let phase = 2 * .pi * (300 * t + (3_000 - 300) / (2 * duration) * t * t)
        let window = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
        return Float(0.5 * window * sin(phase))
    }
}

/// `count` samples of silence with `pulse` at each of `positions`.
private func timeline(_ count: Int, pulses positions: [Int], pulse: [Float]) -> [Float] {
    var x = [Float](repeating: 0, count: count)
    for p in positions { for (i, v) in pulse.enumerated() where p + i < count { x[p + i] = v } }
    return x
}

/// The offset in `x` where `pulse` correlates best.
private func locate(_ pulse: [Float], in x: [Float]) -> Int {
    guard x.count >= pulse.count else { return -1 }
    var best = (offset: -1, score: -Float.infinity)
    for start in 0...(x.count - pulse.count) {
        var s: Float = 0
        for i in 0..<pulse.count { s += x[start + i] * pulse[i] }
        if s > best.score { best = (start, s) }
    }
    return best.offset
}

/// The archive's partial states: a Resume whose preparation failed or was cut short, a commit cut short
/// between its deletions, an archive that would shrink, and exact sample positions through all of it.
final class MeetingArchiveEdgeCaseTests: XCTestCase {
    var dir: URL!
    let pulse = chirp()
    let length = 160_000
    let micPulses = [8_000, 80_000, 150_000]
    let systemPulses = [24_000, 120_000]
    /// Within 3 ms.
    let tolerance = 48

    override func setUpWithError() throws {
        dir = try temporaryFolder()
        try writePCM(timeline(length, pulses: micPulses, pulse: pulse), to: url("mic.pcm"))
        try writePCM(timeline(length, pulses: systemPulses, pulse: pulse), to: url("system.pcm"))
    }
    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func archive(_ archiver: MeetingArchiver, folder: URL? = nil) -> Result<Int?, Error> {
        let done = expectation(description: "archived")
        nonisolated(unsafe) var result: Result<Int?, Error>?
        archiver.archive(folder: folder ?? dir) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 60)
        return result ?? .success(nil)
    }

    /// The pulses of `source` as the meeting's audio reads (archive and/or raw track).
    private func assertPulses(_ source: MeetingSource, at positions: [Int], in folder: URL? = nil,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        for p in positions {
            let start = max(0, p - 2_048)
            let x = try MeetingArchive.read(source, in: folder ?? dir, offset: start, count: 4_096 + pulse.count)
            XCTAssertEqual(start + locate(pulse, in: x), p, accuracy: tolerance, "\(source.rawValue) pulse at \(p)", file: file, line: line)
            XCTAssertGreaterThan(rms(x), 0.02, "\(source.rawValue) pulse at \(p) is there", file: file, line: line)
        }
    }

    /// The pulses as the raw track holds them.
    private func assertTrackPulses(_ name: String, at positions: [Int], file: StaticString = #filePath, line: UInt = #line) throws {
        for p in positions {
            let start = max(0, p - 2_048)
            let x = try MeetingTrack.read(url(name), offset: start, count: 4_096 + pulse.count)
            XCTAssertEqual(start + locate(pulse, in: x), p, accuracy: tolerance, "\(name) pulse at \(p)", file: file, line: line)
        }
    }

    private func archivedFrames() -> Int { (try? AVAudioFile(forReading: url("audio.m4a")).length).map(Int.init) ?? 0 }

    // MARK: Alignment

    func testPulsesStayInPlaceThroughArchiveRestoreAndANewLeg() throws {
        let archiver = MeetingArchiver()
        XCTAssertEqual(try archive(archiver).get(), length)
        XCTAssertNil(MeetingArchive.files(in: dir).mic)
        try assertPulses(.mic, at: micPulses)
        try assertPulses(.system, at: systemPulses)
        // Nothing leaks across channels.
        XCTAssertLessThan(rms(try MeetingArchive.read(.mic, in: dir, offset: 24_000, count: 480)), 0.005)

        // Resume: restored raw tracks hold the pulses at the same positions.
        XCTAssertTrue(archiver.prepareForRecording(folder: dir))
        archiver.waitUntilIdle()
        XCTAssertFalse(MeetingArchive.files(in: dir).restorePending)
        try assertTrackPulses("mic.pcm", at: micPulses)
        try assertTrackPulses("system.pcm", at: systemPulses)

        // A new leg appended after the archived part, with a pulse 1 s in.
        let start = MeetingTrack.sampleCount(url("mic.pcm"))
        XCTAssertEqual(start, archivedFrames())
        let track = try MeetingTrack(source: .mic, url: url("mic.pcm"))
        track.beginLeg(at: 0)
        track.append(timeline(32_000, pulses: [16_000], pulse: pulse), at: 0)
        track.endLeg(at: 2)
        track.close()
        XCTAssertEqual(try archive(archiver).get(), start + 32_000)
        try assertPulses(.mic, at: micPulses + [start + 16_000])
        try assertPulses(.system, at: systemPulses)
    }

    // MARK: Resume

    func testPreparingAgainFinishesAResumeThatStoppedAfterItsMarker() throws {
        let archiver = MeetingArchiver()
        _ = try archive(archiver).get()
        let frames = archivedFrames()
        // A crash right after the marker: no raw tracks yet. (Older markers carry only the frame count.)
        try String(frames).write(to: url("restore.pending"), atomically: true, encoding: .utf8)
        XCTAssertEqual(MeetingArchive.files(in: dir).restoreSources, [.mic, .system])
        XCTAssertTrue(archiver.prepareForRecording(folder: dir))
        // Recording would append after the archived part, not at 0.
        XCTAssertEqual(MeetingTrack.sampleCount(url("mic.pcm")), frames)
        XCTAssertEqual(MeetingTrack.sampleCount(url("system.pcm")), frames)
        archiver.waitUntilIdle()
        XCTAssertFalse(MeetingArchive.files(in: dir).restorePending)
        try assertTrackPulses("mic.pcm", at: micPulses)
        try assertTrackPulses("system.pcm", at: systemPulses)
    }

    func testAPendingRestoreKeepsTheLegRecordedMeanwhile() throws {
        let archiver = MeetingArchiver()
        _ = try archive(archiver).get()
        let frames = archivedFrames()
        // Resume prepared the tracks, recorded a leg, and the app died before the restore ran.
        XCTAssertTrue(try MeetingArchive.prepareTracks(folder: dir))
        let track = try MeetingTrack(source: .mic, url: url("mic.pcm"))
        track.beginLeg(at: 0)
        track.append(timeline(16_000, pulses: [4_000], pulse: pulse), at: 0)
        track.endLeg(at: 1)
        track.close()
        // The next Resume prepares again: nothing shrinks, the archived part is decoded back, the leg stays.
        XCTAssertTrue(archiver.prepareForRecording(folder: dir))
        XCTAssertEqual(MeetingTrack.sampleCount(url("mic.pcm")), frames + 16_000)
        archiver.waitUntilIdle()
        try assertTrackPulses("mic.pcm", at: micPulses + [frames + 4_000])
        XCTAssertEqual(try archive(archiver).get(), frames + 16_000)
        try assertPulses(.mic, at: micPulses + [frames + 4_000])
        try assertPulses(.system, at: systemPulses)
    }

    func testAResumeThatCannotPrepareTheTracksIsRefused() throws {
        let archiver = MeetingArchiver()
        _ = try archive(archiver).get()
        // The marker can't be written (the folder is read-only): nothing is recorded, nothing is left behind.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertFalse(archiver.prepareForRecording(folder: dir))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        var files = MeetingArchive.files(in: dir)
        XCTAssertNil(files.mic)
        XCTAssertFalse(files.restorePending)
        // An archive that can't be read: refused as well.
        try Data("not audio".utf8).write(to: url("audio.m4a"))
        XCTAssertFalse(archiver.prepareForRecording(folder: dir))
        files = MeetingArchive.files(in: dir)
        XCTAssertNil(files.mic)
        XCTAssertFalse(files.restorePending)
        // The folder is not left marked as recording: archiving it works as before (nothing to do here).
        XCTAssertNil(try archive(archiver).get())
    }

    func testAnArchiveIsNeverReplacedByAShorterOne() throws {
        let archiver = MeetingArchiver()
        _ = try archive(archiver).get()
        let frames = archivedFrames()
        // Raw tracks that start over at 0 (a leg recorded without the archived part in front of it).
        try writePCM(sine(440, seconds: 2), to: url("mic.pcm"))
        try writePCM(sine(1_000, seconds: 2), to: url("system.pcm"))
        guard case .failure(let error) = archive(archiver) else { return XCTFail("a 2 s archive replaced \(frames) frames") }
        XCTAssertTrue(error is MeetingArchive.ArchiveError)
        XCTAssertEqual(archivedFrames(), frames, "the earlier legs are kept")
        let files = MeetingArchive.files(in: dir)
        XCTAssertNotNil(files.mic, "and so are the new raw tracks")
        XCTAssertNotNil(files.system)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("audio.partial.m4a").path))
        for p in micPulses {
            let x = try MeetingArchive.readArchive(url("audio.m4a"), channel: 0, offset: p - 2_048, count: 4_096 + pulse.count)
            XCTAssertEqual(p - 2_048 + locate(pulse, in: x), p, accuracy: tolerance, "archived pulse at \(p)")
        }
    }

    // MARK: Commit

    func testTheCommitDeletesBothRawTracksOrNeither() throws {
        let encoded = try XCTUnwrap(try MeetingArchive.encode(folder: dir))
        // One track changes after the encode began.
        let h = try FileHandle(forWritingTo: url("system.pcm"))
        try h.seekToEnd()
        try h.write(contentsOf: Data(count: 3_200))
        try h.close()
        try MeetingArchive.commit(encoded)
        let files = MeetingArchive.files(in: dir)
        XCTAssertNotNil(files.archive)
        XCTAssertNotNil(files.mic, "kept with its partner")
        XCTAssertNotNil(files.system)
    }

    func testACommitCutShortBetweenItsDeletionsLosesNoChannel() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("meeting")
        try FileManager.default.moveItem(at: dir, to: folder)
        dir = folder
        let systemTrack = try Data(contentsOf: url("system.pcm"))
        let archiver = MeetingArchiver()
        _ = try archive(archiver).get()
        // The app died after deleting mic.pcm: the archive and system.pcm are left.
        try systemTrack.write(to: url("system.pcm"))
        XCTAssertThrowsError(try MeetingArchive.encode(folder: dir), "never encoded with You silent")
        XCTAssertTrue(MeetingArchive.recover(folder: dir))
        XCTAssertNotNil(MeetingArchive.files(in: dir).archive, "kept: it holds You's only copy")

        // Launch recovery archives the folder again with You decoded back from the archive.
        archiver.recoverAll(in: root)
        archiver.waitUntilIdle()
        archiver.waitUntilIdle()
        let files = MeetingArchive.files(in: dir)
        XCTAssertNil(files.mic)
        XCTAssertNil(files.system)
        XCTAssertFalse(files.restorePending)
        try assertPulses(.mic, at: micPulses)
        try assertPulses(.system, at: systemPulses)
    }

    func testArchivingNextToOneRawTrackRestoresTheOtherFirst() throws {
        let micTrack = try Data(contentsOf: url("mic.pcm"))
        let archiver = MeetingArchiver()
        _ = try archive(archiver).get()
        try micTrack.write(to: url("mic.pcm")) // system.pcm was deleted, mic.pcm wasn't
        XCTAssertEqual(try archive(archiver).get(), length)
        try assertPulses(.mic, at: micPulses)
        try assertPulses(.system, at: systemPulses)
        XCTAssertNil(MeetingArchive.files(in: dir).mic)
    }

    // MARK: Discard

    func testTrimCutsALegThatWasArchivedAlready() throws {
        let archiver = MeetingArchiver()
        _ = try archive(archiver).get()
        // A resumed leg, archived with the rest before "Discard" was chosen.
        XCTAssertTrue(archiver.prepareForRecording(folder: dir))
        archiver.waitUntilIdle()
        let start = MeetingTrack.sampleCount(url("mic.pcm"))
        for name in ["mic.pcm", "system.pcm"] {
            let track = try MeetingTrack(source: name == "mic.pcm" ? .mic : .system, url: url(name))
            track.beginLeg(at: 0)
            track.append(timeline(32_000, pulses: [16_000], pulse: pulse), at: 0)
            track.endLeg(at: 2)
            track.close()
        }
        XCTAssertEqual(try archive(archiver).get(), start + 32_000)

        let done = expectation(description: "trimmed")
        nonisolated(unsafe) var failure: Error?
        archiver.trim(folder: dir, toFrames: start) { failure = $0; done.fulfill() }
        wait(for: [done], timeout: 60)
        XCTAssertNil(failure)
        XCTAssertEqual(archivedFrames(), start, accuracy: 2_048)
        XCTAssertNil(MeetingArchive.files(in: dir).mic)
        XCTAssertLessThan(MeetingArchive.length(in: dir), start + 2_048, "the discarded leg is gone")
        XCTAssertLessThan(rms(try MeetingArchive.read(.mic, in: dir, offset: start, count: 32_000)), 0.005)
        try assertPulses(.mic, at: micPulses)
        try assertPulses(.system, at: systemPulses)
    }
}

// MARK: - Capture health

final class CaptureHealthTests: XCTestCase {
    func testWatchdogRestartsAStalledCaptureAndReportsAfterTwoFailedRestarts() {
        var w = CaptureWatchdog(now: 0)
        w.started(at: 0)
        XCTAssertEqual(w.check(buffers: 10, at: 1), [])
        XCTAssertEqual(w.check(buffers: 10, at: 4), [])
        XCTAssertEqual(w.check(buffers: 10, at: 5), [.restart]) // 4 s without a buffer
        w.started(at: 5)
        XCTAssertEqual(w.check(buffers: 0, at: 9), [.restart])
        w.started(at: 9)
        XCTAssertEqual(w.check(buffers: 0, at: 13), [])          // backing off: 8 s now
        XCTAssertEqual(w.check(buffers: 0, at: 17), [.reportStall, .restart])
        w.started(at: 17)
        XCTAssertEqual(w.check(buffers: 3, at: 18), [.reportRecovered])
        XCTAssertFalse(w.stallReported)
    }

    func testWatchdogLeavesAFlowingCaptureAlone() {
        var w = CaptureWatchdog(now: 0)
        for t in 1...60 { XCTAssertEqual(w.check(buffers: t * 25, at: Double(t)), []) }
    }

    func testAStallIsReportedAgainAfterAStopAndStart() {
        var w = CaptureWatchdog(now: 0)
        w.started(at: 0)
        XCTAssertEqual(w.check(buffers: 40, at: 1), [])
        XCTAssertEqual(w.check(buffers: 40, at: 5), [.restart])
        w.started(at: 5)
        XCTAssertEqual(w.check(buffers: 0, at: 9), [.restart])
        w.started(at: 9)
        XCTAssertEqual(w.check(buffers: 0, at: 17), [.reportStall, .restart])
        XCTAssertTrue(w.stallReported)
        // Dictation (or a new leg) stops and starts the capture: the capture clears its stalled flag, and the
        // watchdog must not stay "reported" for a unit that is still dead.
        w.reset(at: 30)
        XCTAssertFalse(w.stallReported)
        w.started(at: 30)
        XCTAssertEqual(w.check(buffers: 0, at: 34), [.restart])
        w.started(at: 34)
        XCTAssertEqual(w.check(buffers: 0, at: 38), [.restart])
        w.started(at: 38)
        XCTAssertEqual(w.check(buffers: 0, at: 46), [.reportStall, .restart], "the still-dead microphone is reported again")
        // A counter that happens to equal the old one after the reset does not count as progress either.
        var v = CaptureWatchdog(now: 0)
        v.started(buffers: 7, at: 0)
        v.reset(at: 1)
        v.started(at: 1)
        XCTAssertEqual(v.check(buffers: 0, at: 5), [.restart])
    }

    private func run(_ l: inout SystemAudioLiveness, from: Int, to: Int, zeroSince: Double = 0, lastHeard: Double? = nil,
                     heardAny: Bool = true, othersPlaying: Bool = true) -> [Int: SystemAudioLiveness.Action] {
        var out: [Int: SystemAudioLiveness.Action] = [:]
        for t in from...to {
            let a = l.tick(now: Double(t), zeroRunSeconds: Double(t) - zeroSince + 1, lastHeard: lastHeard, heardAny: heardAny,
                           othersPlaying: othersPlaying)
            if a != .none { out[t] = a }
        }
        return out
    }

    func testSilenceWithNothingPlayingIsJustAQuietCall() {
        var l = SystemAudioLiveness()
        XCTAssertTrue(run(&l, from: 0, to: 600, othersPlaying: false).isEmpty)
    }

    func testDeadTapIsRebuiltOnALadderThenReported() {
        var l = SystemAudioLiveness()
        let actions = run(&l, from: 0, to: 100)
        // Suspect after 10 s; rebuilds 0 / 10 / 30 s apart with 10 s verification; then the notice.
        XCTAssertEqual(actions[10], .rebuild)
        XCTAssertEqual(actions[20], .rebuild)
        XCTAssertEqual(actions[50], .rebuild)
        XCTAssertEqual(actions[60], .showSilentNotice)
        XCTAssertEqual(actions[90], .rebuild, "keep-alive retry")
        XCTAssertEqual(actions.count, 5)
        XCTAssertTrue(l.noticeShown)
        // Audio comes back: the notice goes.
        XCTAssertEqual(l.tick(now: 101, zeroRunSeconds: 0, lastHeard: 101, heardAny: true, othersPlaying: true), .clearSilentNotice)
    }

    func testATapThatNeverHeardAnythingGetsOneRebuild() {
        var l = SystemAudioLiveness()
        let actions = run(&l, from: 0, to: 40, heardAny: false)
        XCTAssertEqual(actions[10], .rebuild)
        XCTAssertEqual(actions[20], .showSilentNotice)
        XCTAssertEqual(actions.count, 2)
    }

    func testRecoveryAfterARebuildResetsTheBudget() {
        var l = SystemAudioLiveness()
        XCTAssertEqual(run(&l, from: 0, to: 10)[10], .rebuild)
        // Audio arrives 3 s after the rebuild (it worked), then the tap goes silent again: a working tap,
        // so most likely a quiet call. One rebuild after 60 s, keep-alive retries, no notice.
        XCTAssertEqual(l.tick(now: 13, zeroRunSeconds: 0, lastHeard: 13, heardAny: true, othersPlaying: true), .none)
        let again = run(&l, from: 14, to: 200, zeroSince: 13, lastHeard: 13)
        XCTAssertEqual(again, [74: .rebuild, 114: .rebuild, 174: .rebuild])
        XCTAssertFalse(l.noticeShown)
    }

    func testAQuietCallOnAWorkingTapIsNotADeadTap() {
        // The call app keeps its output running with exact zeros (the other side muted) after the tap was heard.
        var l = SystemAudioLiveness()
        XCTAssertEqual(l.tick(now: 5, zeroRunSeconds: 0, lastHeard: 5, heardAny: true, othersPlaying: true), .none)
        let actions = run(&l, from: 6, to: 400, zeroSince: 6, lastHeard: 5)
        XCTAssertNil(actions[16], "not rebuilt after the usual 10 s")
        XCTAssertEqual(actions[66], .rebuild, "suspected only after 60 s")
        XCTAssertFalse(actions.values.contains(.showSilentNotice), "never told the call isn't heard")
        XCTAssertFalse(l.noticeShown)
        // Someone speaks again: back to watching, nothing to clear.
        XCTAssertEqual(l.tick(now: 401, zeroRunSeconds: 0, lastHeard: 401, heardAny: true, othersPlaying: true), .none)
        // A tap never heard since its last rebuild is still treated as dead (the ladder and the notice).
        var dead = SystemAudioLiveness()
        let ladder = run(&dead, from: 0, to: 100)
        XCTAssertEqual(ladder[60], .showSilentNotice)
    }

    // MARK: Playback oracle

    private let zoom = DetectedCall(pid: 500, bundleID: "us.zoom.xos", appName: "Zoom", platform: .zoom, qualifiesForAutoStart: true)
    private let chrome = DetectedCall(pid: 600, bundleID: "com.google.Chrome", appName: "Chrome", platform: .meet,
                                      qualifiesForAutoStart: true)

    func testTheCallsOwnProcessesDecideWhetherSomethingPlays() {
        let me: Int32 = 42
        let idleTab = PlaybackOracle.Process(pid: 700, bundleID: "com.apple.Safari", runningOutput: true)
        let zoomSilent = PlaybackOracle.Process(pid: 500, bundleID: "us.zoom.xos", runningOutput: false)
        let zoomPlaying = PlaybackOracle.Process(pid: 500, bundleID: "us.zoom.xos", runningOutput: true)
        let shout = PlaybackOracle.Process(pid: me, bundleID: "com.namikmesic.shout", runningOutput: true)
        // Another app's idle output does not make the call's silence suspicious.
        XCTAssertFalse(PlaybackOracle.othersPlaying([idleTab, zoomSilent, shout], excluding: me, call: zoom))
        XCTAssertTrue(PlaybackOracle.othersPlaying([idleTab, zoomPlaying], excluding: me, call: zoom))
        // Without a call, or when none of its processes uses audio, any other process counts (never Shout).
        XCTAssertTrue(PlaybackOracle.othersPlaying([idleTab, zoomSilent], excluding: me, call: nil))
        XCTAssertTrue(PlaybackOracle.othersPlaying([idleTab], excluding: me, call: zoom))
        XCTAssertFalse(PlaybackOracle.othersPlaying([shout], excluding: me, call: nil))
    }

    func testABrowserCallPlaysFromItsHelperProcesses() {
        let me: Int32 = 42
        let browser = PlaybackOracle.Process(pid: 600, bundleID: "com.google.Chrome", runningOutput: false)
        let helper = PlaybackOracle.Process(pid: 601, parentPID: 600, bundleID: "com.google.Chrome.helper", runningOutput: true)
        let byParent = PlaybackOracle.Process(pid: 602, parentPID: 600, bundleID: nil, runningOutput: true)
        let other = PlaybackOracle.Process(pid: 900, bundleID: "com.spotify.client", runningOutput: true)
        XCTAssertTrue(PlaybackOracle.othersPlaying([browser, helper], excluding: me, call: chrome))
        XCTAssertTrue(PlaybackOracle.othersPlaying([browser, byParent], excluding: me, call: chrome))
        XCTAssertFalse(PlaybackOracle.othersPlaying([browser, other], excluding: me, call: chrome))
        let safari = DetectedCall(pid: 800, bundleID: "com.apple.Safari", appName: "Safari", platform: .meet, qualifiesForAutoStart: true)
        let webKit = PlaybackOracle.Process(pid: 801, bundleID: "com.apple.WebKit.GPU", runningOutput: true)
        XCTAssertTrue(PlaybackOracle.othersPlaying([PlaybackOracle.Process(pid: 800, bundleID: "com.apple.Safari", runningOutput: false), webKit],
                                                   excluding: me, call: safari))
    }
}
