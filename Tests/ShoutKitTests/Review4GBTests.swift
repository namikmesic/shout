import XCTest
import AVFoundation
@testable import ShoutKit
import ShoutASR

private func temporaryFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shout-4gb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func pcmData(_ samples: [Float]) -> Data {
    let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
    return pcm.withUnsafeBytes { Data($0) }
}

/// A 30 ms windowed chirp: a sharp correlation peak, so a shifted channel can't pass.
private func chirp() -> [Float] {
    let n = 480
    return (0..<n).map { i in
        let t = Double(i) / 16_000, duration = Double(n) / 16_000
        let phase = 2 * .pi * (300 * t + (3_000 - 300) / (2 * duration) * t * t)
        let window = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
        return Float(0.5 * window * sin(phase))
    }
}

private func timeline(_ count: Int, pulses positions: [Int], pulse: [Float]) -> [Float] {
    var x = [Float](repeating: 0, count: count)
    for p in positions { for (i, v) in pulse.enumerated() where p + i < count { x[p + i] = v } }
    return x
}

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

private func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }

// MARK: - Archive

final class Review4GBArchiveTests: XCTestCase {
    var dir: URL!
    let pulse = chirp()

    override func setUpWithError() throws { dir = try temporaryFolder() }
    override func tearDownWithError() throws {
        for name in ["mic.pcm", "system.pcm"] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url(name).path)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    private func archive(_ archiver: MeetingArchiver) -> Result<Int?, Error> {
        let done = expectation(description: "archived")
        nonisolated(unsafe) var result: Result<Int?, Error>?
        archiver.archive(folder: dir) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 60)
        return result ?? .success(nil)
    }

    /// Holds the archiver's queue (another meeting's work running) until `gate` is signalled.
    private func holdQueue(_ archiver: MeetingArchiver, until gate: DispatchSemaphore) throws {
        let other = try temporaryFolder()
        addTeardownBlock { try? FileManager.default.removeItem(at: other) }
        archiver.archive(folder: other) { _ in gate.wait() }
    }

    private func assertPulse(_ source: MeetingSource, at p: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let start = max(0, p - 2_048)
        let x = try MeetingArchive.read(source, in: dir, offset: start, count: 4_096 + pulse.count)
        XCTAssertEqual(start + locate(pulse, in: x), p, accuracy: 48, "\(source.rawValue) pulse at \(p)", file: file, line: line)
        XCTAssertGreaterThan(rms(x), 0.02, "\(source.rawValue) pulse at \(p) is there", file: file, line: line)
    }

    func testARawTrackThatCannotBeOpenedFailsTheArchiveAndBothTracksStay() throws {
        try pcmData(timeline(32_000, pulses: [4_000], pulse: pulse)).write(to: url("mic.pcm"))
        try pcmData(timeline(32_000, pulses: [12_000], pulse: pulse)).write(to: url("system.pcm"))
        // There, but unreadable: not a missing track to fill with silence.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url("system.pcm").path)
        let archiver = MeetingArchiver()
        guard case .failure(let error) = archive(archiver) else { return XCTFail("archived with Others silent") }
        XCTAssertTrue(error is MeetingArchive.ArchiveError)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url("system.pcm").path)
        let files = MeetingArchive.files(in: dir)
        XCTAssertNil(files.archive)
        XCTAssertNotNil(files.mic)
        XCTAssertNotNil(files.system)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url("audio.partial.m4a").path))
        // Readable again: both channels are archived.
        XCTAssertEqual(try archive(archiver).get(), 32_000)
        try assertPulse(.mic, at: 4_000)
        try assertPulse(.system, at: 12_000)
    }

    func testAMissingRawTrackWithNoArchiveIsStillSilence() throws {
        try pcmData(timeline(32_000, pulses: [4_000], pulse: pulse)).write(to: url("mic.pcm"))
        XCTAssertEqual(try archive(MeetingArchiver()).get(), 32_000)
        try assertPulse(.mic, at: 4_000)
        XCTAssertLessThan(rms(try MeetingArchive.read(.system, in: dir, offset: 0, count: 32_000)), 0.005)
    }

    func testAResumeWhileADiscardIsQueuedStartsWhereTheDiscardedLegBegan() throws {
        // Two legs in the raw tracks: [0, kept) stays, [kept, 32 000) was discarded.
        let kept = 16_000
        try pcmData(timeline(32_000, pulses: [4_000, 20_000], pulse: pulse)).write(to: url("mic.pcm"))
        try pcmData(timeline(32_000, pulses: [8_000, 24_000], pulse: pulse)).write(to: url("system.pcm"))
        let archiver = MeetingArchiver()
        let gate = DispatchSemaphore(value: 0)
        try holdQueue(archiver, until: gate)
        let trimmed = expectation(description: "trim ended")
        nonisolated(unsafe) var failure: Error?
        archiver.trim(folder: dir, toFrames: kept) { failure = $0; trimmed.fulfill() }

        // Resume before the queued cut ran: the cut is made first, so recording starts at `kept`.
        XCTAssertTrue(archiver.prepareForRecording(folder: dir))
        XCTAssertEqual(MeetingTrack.sampleCount(url("mic.pcm")), kept)
        XCTAssertEqual(MeetingTrack.sampleCount(url("system.pcm")), kept)
        gate.signal()
        wait(for: [trimmed], timeout: 60)
        XCTAssertTrue(failure is CancellationError, "the trim's re-encode gave way to the recording")
        XCTAssertNil(MeetingArchive.files(in: dir).archive)

        // The new leg follows the kept one; the discarded audio is in neither the tracks nor the archive.
        for (name, source) in [("mic.pcm", MeetingSource.mic), ("system.pcm", .system)] {
            let track = try MeetingTrack(source: source, url: url(name))
            XCTAssertEqual(track.sampleCount, kept)
            track.beginLeg(at: 0)
            track.append(timeline(16_000, pulses: [10_000], pulse: pulse), at: 0)
            track.endLeg(at: 1)
            track.close()
        }
        XCTAssertEqual(try archive(archiver).get(), kept + 16_000)
        try assertPulse(.mic, at: 4_000)
        try assertPulse(.system, at: 8_000)
        try assertPulse(.mic, at: kept + 10_000)
        for (source, p) in [(MeetingSource.mic, 20_000), (.system, 24_000)] {
            XCTAssertLessThan(rms(try MeetingArchive.read(source, in: dir, offset: p - 400, count: 1_280)), 0.005, "discarded pulse at \(p)")
        }
    }

    func testAResumeWaitsForADiscardThatMustBeCutFromTheArchive() throws {
        let kept = 16_000
        try pcmData(timeline(32_000, pulses: [4_000, 20_000], pulse: pulse)).write(to: url("mic.pcm"))
        try pcmData(timeline(32_000, pulses: [8_000, 24_000], pulse: pulse)).write(to: url("system.pcm"))
        let archiver = MeetingArchiver()
        // The discarded leg was compressed already: only the archive holds it.
        XCTAssertEqual(try archive(archiver).get(), 32_000)
        let gate = DispatchSemaphore(value: 0)
        try holdQueue(archiver, until: gate)
        let trimmed = expectation(description: "trim ended")
        nonisolated(unsafe) var failure: Error?
        archiver.trim(folder: dir, toFrames: kept) { failure = $0; trimmed.fulfill() }

        // Recording now would start after the discarded leg, and cancel its cut: refused, folder unchanged.
        XCTAssertFalse(archiver.prepareForRecording(folder: dir))
        XCTAssertNil(MeetingArchive.files(in: dir).mic)
        XCTAssertFalse(MeetingArchive.files(in: dir).restorePending)
        gate.signal()
        wait(for: [trimmed], timeout: 60)
        XCTAssertNil(failure, "the trim went on")
        XCTAssertLessThan(MeetingArchive.length(in: dir), kept + 2_048)

        // Once cut, Resume works and starts at the cut.
        XCTAssertTrue(archiver.prepareForRecording(folder: dir))
        XCTAssertLessThan(MeetingTrack.sampleCount(url("mic.pcm")), kept + 2_048)
        archiver.waitUntilIdle()
        try assertPulse(.mic, at: 4_000)
        try assertPulse(.system, at: 8_000)
    }
}

// MARK: - Transcriber

final class Review4GBTranscriberTests: XCTestCase {
    final class FakeRecognizer: SpeechRecognizer, @unchecked Sendable {
        let displayName = "Fake"
        func warmUp() async {}
        func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptionResult {
            try await Task.sleep(nanoseconds: 10_000_000)
            return TranscriptionResult(text: "A line of speech here.")
        }
    }

    final class Lines: @unchecked Sendable {
        let lock = NSLock()
        var sources: [MeetingSource] = []
        func add(_ s: MeetingSource) { lock.lock(); sources.append(s); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return sources.count }
    }

    final class Flag: @unchecked Sendable {
        let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Syllable-like bursts (stationary noise is rightly rejected as no speech).
    private var speech: SpeechSegment {
        var state: UInt32 = 12345
        func noise(_ seconds: Double, rms: Float) -> [Float] {
            (0..<Int(seconds * 16_000)).map { _ in
                state = state &* 1_664_525 &+ 1_013_904_223
                return Float(Int32(bitPattern: state)) / Float(Int32.max) * rms * 1.732
            }
        }
        var audio: [Float] = []
        for _ in 0..<4 { audio += noise(0.2, rms: 0.1) + noise(0.1, rms: 0.003) }
        return SpeechSegment(start: 0, samples: audio)
    }

    private func transcriber(_ lines: Lines) -> MeetingTranscriber {
        let rec = FakeRecognizer()
        return MeetingTranscriber(recognizer: { rec }, settings: { MeetingTranscriptionSettings() },
                                  onResult: { job, r in if case .success = r { lines.add(job.source) } })
    }

    func testWaitingForAMeetingWaitsForItsRecoveryScanAndWhatItFinds() async throws {
        let lines = Lines()
        let tr = transcriber(lines)
        let gate = DispatchSemaphore(value: 0)
        let segment = speech
        // A crash-recovery scan still reading the tracks, and a line of the leg resumed meanwhile.
        tr.submit(meetingID: "a") {
            gate.wait()
            return [.init(meetingID: "a", source: .system, segment: segment)]
        }
        tr.submit(.init(meetingID: "a", source: .mic, segment: segment))
        let done = expectation(description: "waited"), returned = Flag()
        let waiter = Task { await tr.waitUntilDone("a"); returned.set(); done.fulfill() }
        // The resumed leg's line is in; the scan's isn't yet, so the meeting isn't done.
        for _ in 0..<200 where lines.count < 1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(lines.sources, [.mic])
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(returned.isSet, "the wait returned while the scan was still running")
        let pending = await tr.pending(for: "a")
        XCTAssertEqual(pending, 1, "the scan counts as pending")
        gate.signal()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(lines.sources, [.mic, .system], "the scan's line was in before the wait returned")
        waiter.cancel()
    }

    func testAScanThatFindsNothingEndsTheWait() async throws {
        let lines = Lines()
        let tr = transcriber(lines)
        let gate = DispatchSemaphore(value: 0)
        tr.submit(meetingID: "a") { gate.wait(); return [] }
        let done = expectation(description: "waited"), returned = Flag()
        let waiter = Task { await tr.waitUntilDone("a"); returned.set(); done.fulfill() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(returned.isSet, "the wait returned before the scan ended")
        gate.signal()
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(lines.count, 0)
        let pending = await tr.pending(for: "a")
        XCTAssertEqual(pending, 0)
        waiter.cancel()
    }
}
