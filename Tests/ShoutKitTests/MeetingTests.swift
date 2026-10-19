import XCTest
@testable import ShoutKit
import ShoutASR
import ShoutLLM

/// Deterministic noise so tests are reproducible.
private struct Noise {
    var state: UInt32 = 12345
    mutating func next() -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: state)) / Float(Int32.max)
    }
    /// `seconds` of noise at a given RMS level.
    mutating func samples(_ seconds: Double, rms: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { _ in next() * rms * 1.732 }
    }
}

final class SpeechSegmenterTests: XCTestCase {
    func testTwoUtterancesSeparatedByPauses() {
        var n = Noise()
        let audio = n.samples(1.0, rms: 0.001) + n.samples(1.5, rms: 0.1) + n.samples(1.0, rms: 0.001)
            + n.samples(2.0, rms: 0.1) + n.samples(2.0, rms: 0.001)
        let seg = SpeechSegmenter()
        var out: [SpeechSegment] = []
        for i in stride(from: 0, to: audio.count, by: 640) { out += seg.process(Array(audio[i..<min(i + 640, audio.count)])) }
        out += seg.flush()
        XCTAssertEqual(out.count, 2)
        guard out.count == 2 else { return }
        // Starts include up to ~0.45 s of pre-roll; ends include a 0.25 s tail.
        XCTAssertEqual(Double(out[0].start) / 16_000, 0.65, accuracy: 0.25)
        XCTAssertEqual(Double(out[0].end) / 16_000, 2.75, accuracy: 0.15)
        XCTAssertEqual(Double(out[1].start) / 16_000, 3.15, accuracy: 0.25)
        XCTAssertEqual(Double(out[1].end) / 16_000, 5.75, accuracy: 0.15)
        // Segment samples are exactly the track samples at those positions.
        XCTAssertEqual(out[1].samples, Array(audio[out[1].start..<out[1].end]))
    }

    func testLongSpeechIsSplitIntoContiguousPieces() {
        var n = Noise()
        let audio = n.samples(0.5, rms: 0.001) + n.samples(40, rms: 0.1) + n.samples(1.5, rms: 0.001)
        let seg = SpeechSegmenter()
        var out = seg.process(audio)
        out += seg.flush()
        XCTAssertGreaterThanOrEqual(out.count, 2)
        for s in out { XCTAssertLessThanOrEqual(Double(s.samples.count) / 16_000, 28.05) }
        for (a, b) in zip(out, out.dropFirst()) { XCTAssertEqual(a.end, b.start) }
    }

    func testShortBlipIsIgnored() {
        var n = Noise()
        let audio = n.samples(1, rms: 0.001) + n.samples(0.1, rms: 0.2) + n.samples(1.5, rms: 0.001)
        let seg = SpeechSegmenter()
        XCTAssertTrue((seg.process(audio) + seg.flush()).isEmpty)
    }

    func testFlushEndsUtteranceInProgress() {
        var n = Noise()
        let seg = SpeechSegmenter()
        XCTAssertTrue(seg.process(n.samples(0.5, rms: 0.001) + n.samples(1.2, rms: 0.1)).isEmpty)
        XCTAssertTrue(seg.isSpeaking)
        let out = seg.flush()
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(seg.isSpeaking)
    }

    func testDigitalSilenceDoesNotLowerTheNoiseFloor() {
        var n = Noise()
        let seg = SpeechSegmenter()
        _ = seg.process(n.samples(3, rms: 0.003))
        let floor = seg.noiseFloorDB
        _ = seg.process([Float](repeating: 0, count: 16_000 * 5))
        XCTAssertEqual(seg.noiseFloorDB, floor, accuracy: 0.01)
    }
}

final class MeetingTrackTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("shout-track-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLateSourceIsPaddedSoTracksStayAligned() throws {
        let mic = try MeetingTrack(source: .mic, url: dir.appendingPathComponent("mic.pcm"))
        let sys = try MeetingTrack(source: .system, url: dir.appendingPathComponent("system.pcm"))
        let t0 = 1000.0
        mic.beginLeg(at: t0); sys.beginLeg(at: t0)
        let chunk = [Float](repeating: 0.25, count: 640)
        sys.append(chunk, at: t0)
        mic.append(chunk, at: t0 + 0.5) // the microphone started half a second late
        XCTAssertEqual(mic.sampleCount, 8_000 + 640)
        XCTAssertEqual(sys.sampleCount, 640)
        let a = mic.endLeg(at: t0 + 1), b = sys.endLeg(at: t0 + 1)
        XCTAssertEqual(a, 16_000); XCTAssertEqual(b, 16_000)
        let micSamples = try MeetingTrack.read(dir.appendingPathComponent("mic.pcm"), offset: 0)
        XCTAssertEqual(micSamples.count, 16_000)
        XCTAssertEqual(micSamples[7_999], 0)
        XCTAssertEqual(micSamples[8_000], 0.25, accuracy: 0.001)
    }

    func testSmallJitterIsNotPadded() throws {
        let t = try MeetingTrack(source: .mic, url: dir.appendingPathComponent("mic.pcm"))
        t.beginLeg(at: 5)
        let chunk = [Float](repeating: 0.1, count: 640)
        t.append(chunk, at: 5.0)
        t.append(chunk, at: 5.09) // 50 ms late: within tolerance
        XCTAssertEqual(t.sampleCount, 1_280)
    }

    func testFirstChunkIsPlacedExactlyAndAClockRunningAheadIsTrimmed() throws {
        let t = try MeetingTrack(source: .system, url: dir.appendingPathComponent("system.pcm"))
        t.beginLeg(at: 10)
        let chunk = [Float](repeating: 0.1, count: 1_600)
        t.append(chunk, at: 10.05) // 50 ms startup latency: below the gap tolerance, but the first chunk aligns exactly
        XCTAssertEqual(t.sampleCount, 800 + 1_600)
        // A source whose clock runs fast delivers more audio than time has passed.
        for _ in 0..<5 { t.append(chunk, at: 10.05) }
        XCTAssertLessThanOrEqual(t.sampleCount - t.position(at: 10.05), MeetingTrack.gapTolerance + 1_600)
    }

    func testResumeAppendsANewLegAfterTheExistingAudio() throws {
        let url = dir.appendingPathComponent("system.pcm")
        let first = try MeetingTrack(source: .system, url: url)
        first.beginLeg(at: 0)
        first.append([Float](repeating: 0.1, count: 640), at: 0)
        first.endLeg(at: 2)
        first.close()
        let second = try MeetingTrack(source: .system, url: url)
        XCTAssertEqual(second.sampleCount, 32_000)
        second.beginLeg(at: 500) // much later wall-clock: the stopped time is not recorded
        second.append([Float](repeating: 0.1, count: 640), at: 500)
        XCTAssertEqual(second.endLeg(at: 501), 48_000)
    }

    func testLiveSegmentsMatchRecoveryFromTheFile() throws {
        var n = Noise()
        let url = dir.appendingPathComponent("mic.pcm")
        let t = try MeetingTrack(source: .mic, url: url)
        let lock = NSLock()
        var live: [SpeechSegment] = []
        t.onSegment = { s in lock.lock(); live.append(s); lock.unlock() }
        t.beginLeg(at: 0)
        let audio = n.samples(1, rms: 0.001) + n.samples(2, rms: 0.1) + n.samples(1.5, rms: 0.001)
            + n.samples(1.5, rms: 0.1) + n.samples(1, rms: 0.001)
        var time = 0.0
        for i in stride(from: 0, to: audio.count, by: 640) {
            t.append(Array(audio[i..<min(i + 640, audio.count)]), at: time)
            time += 0.04
        }
        t.endLeg(at: time)
        let recovered = try MeetingTrack.segments(in: url, from: 0)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(live.count, 2)
        XCTAssertEqual(live.map(\.start), recovered.map(\.start))
        XCTAssertEqual(live.map(\.end), recovered.map(\.end))
    }
}

final class EchoMatcherTests: XCTestCase {
    func testWholeLineOfCallAudioIsHidden() {
        let c = EchoMatcher.removeEcho(from: "we should move the launch by one week",
                                       heard: "I think we should move the launch by one week. The tests aren't done.")
        XCTAssertEqual(c?.text, "")
    }

    func testEchoMergedIntoOwnSpeechIsCutOut() {
        let c = EchoMatcher.removeEcho(
            from: "Morning everyone. Let's start with the launch timeline. Then pricing. I think we should move the launch by one week.",
            heard: "Morning everyone. Let's start with the launch timeline, then pricing.")
        XCTAssertEqual(c?.text, "I think we should move the launch by one week.")
        XCTAssertEqual(c?.removedPrefix, true)
        XCTAssertEqual(c?.prefixEndSystemWord, 9)
    }

    func testSmallRecognizerDifferencesInsideEchoAreBridged() {
        let c = EchoMatcher.removeEcho(from: "Kriya, can you own the pricing proposal by Friday? Sure, I'll take it from here.",
                                       heard: "Priya, can you own the pricing proposal by Friday?")
        XCTAssertEqual(c?.text, "Sure, I'll take it from here.")
    }

    func testDifferentSpeechIsKept() {
        XCTAssertNil(EchoMatcher.removeEcho(from: "That works for me, I'll send the notes after the call.",
                                            heard: "Can we move the launch by one week?"))
    }

    func testLeadingEchoMovesTheStartToTheEndOfTheMatchingCallLine() {
        let a = MeetingSegment(meetingID: "m", source: .system, startMs: 0, endMs: 4_000, text: "Morning everyone, let's start with pricing.")
        let b = MeetingSegment(meetingID: "m", source: .system, startMs: 9_000, endMs: 12_000, text: "Can you own the proposal?")
        let mic = MeetingSegment(meetingID: "m", source: .mic, startMs: 500, endMs: 10_000,
                                 text: "Morning everyone, let's start with pricing. I think we should wait a week.")
        XCTAssertEqual(EchoMatcher.resolve([a, b, mic])[mic.id]?.startMs, 4_000)
    }

    func testVeryShortLinesAreNeverTouched() {
        XCTAssertNil(EchoMatcher.removeEcho(from: "Yes.", heard: "Yes."))
    }

    func testOnlyOverlappingSystemLinesCount() {
        let sys = MeetingSegment(meetingID: "m", source: .system, startMs: 10_000, endMs: 14_000,
                                 text: "Let's ship the onboarding flow on Monday morning")
        let echo = MeetingSegment(meetingID: "m", source: .mic, startMs: 10_300, endMs: 14_200,
                                  text: "let's ship the onboarding flow on Monday")
        let later = MeetingSegment(meetingID: "m", source: .mic, startMs: 60_000, endMs: 63_000,
                                   text: "let's ship the onboarding flow on Monday")
        let r = EchoMatcher.resolve([sys, echo, later])
        XCTAssertEqual(Array(r.keys), [echo.id])
        XCTAssertEqual(r[echo.id]?.text, "")
    }
}

final class MeetingTranscriberTests: XCTestCase {
    final class FakeRecognizer: SpeechRecognizer, @unchecked Sendable {
        let displayName = "Fake"
        let lock = NSLock()
        var calls = 0
        func warmUp() async {}
        func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptionResult {
            try await Task.sleep(nanoseconds: 20_000_000)
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            return TranscriptionResult(text: "Line number \(n) here.")
        }
    }

    final class Results: @unchecked Sendable {
        let lock = NSLock()
        var items: [(String, String)] = []
        func add(_ id: String, _ t: String) { lock.lock(); items.append((id, t)); lock.unlock() }
    }

    func testWaitUntilDoneSeesJobsSubmittedJustBefore() async {
        var n = Noise()
        // Syllable-like bursts: stationary noise would (rightly) be rejected as no speech.
        var audio: [Float] = []
        for _ in 0..<4 { audio += n.samples(0.2, rms: 0.1) + n.samples(0.1, rms: 0.003) }
        let speech = SpeechSegment(start: 0, samples: audio)
        let rec = FakeRecognizer()
        let results = Results()
        let tr = MeetingTranscriber(recognizer: { rec }, settings: { MeetingTranscriptionSettings() },
                                    onResult: { job, r in if case .success(let t) = r { results.add(job.meetingID, t) } })
        for _ in 0..<3 { tr.submit(.init(meetingID: "a", source: .mic, segment: speech)) }
        tr.submit(.init(meetingID: "b", source: .system, segment: speech))
        await tr.waitUntilDone("a")
        let a = results.items.filter { $0.0 == "a" }.map(\.1)
        XCTAssertEqual(a, ["Line number 1 here.", "Line number 2 here.", "Line number 3 here."])
        await tr.waitUntilDone("b")
        XCTAssertEqual(results.items.count, 4)
    }

    func testSilenceIsNotSentToTheRecognizer() async throws {
        let rec = FakeRecognizer()
        let text = try await MeetingTranscription.transcribe(SpeechSegment(start: 0, samples: [Float](repeating: 0, count: 16_000)),
                                                             recognizer: rec, settings: MeetingTranscriptionSettings())
        XCTAssertEqual(text, "")
        XCTAssertEqual(rec.calls, 0)
    }
}

@MainActor
final class MeetingStoreTests: XCTestCase {
    func makeStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("shout-test-\(UUID().uuidString).sqlite").path
        return try Store(path: path)
    }

    func testTranscriptIsOrderedByTimeAndCountsVisibleWords() throws {
        let store = try makeStore()
        let m = Meeting(title: "Sync")
        store.createMeeting(m)
        store.addSegment(MeetingSegment(meetingID: m.id, source: .system, startMs: 5_000, endMs: 7_000, text: "Second line here"))
        let first = store.addSegment(MeetingSegment(meetingID: m.id, source: .mic, startMs: 1_000, endMs: 3_000, text: "First line"))
        let echo = store.addSegment(MeetingSegment(meetingID: m.id, source: .mic, startMs: 5_100, endMs: 7_000, text: "second line here"))
        XCTAssertEqual(store.segments(meetingID: m.id).map(\.startMs), [1_000, 5_000, 5_100])
        XCTAssertEqual(store.meeting(id: m.id)?.wordCount, 8)
        store.setSegmentLatched(ids: [echo.id], latched: true)
        XCTAssertEqual(store.meeting(id: m.id)?.wordCount, 5)
        store.editSegment(id: first.id, text: "The first line, corrected")
        XCTAssertEqual(store.segments(meetingID: m.id).first?.displayText, "The first line, corrected")
        XCTAssertEqual(store.meeting(id: m.id)?.wordCount, 7) // 4 corrected + 3, echo still hidden
        XCTAssertEqual(store.lastSegmentEndMs(meetingID: m.id, source: .mic), 7_000)
    }

    func testUnfinishedMeetingsAndDeletion() throws {
        let store = try makeStore()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shout-meeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var m = Meeting(status: .recording, audioPath: folder.path)
        store.createMeeting(m)
        store.createMeeting(Meeting(status: .complete))
        XCTAssertEqual(store.unfinishedMeetings().map(\.id), [m.id])
        m.status = .complete
        store.updateMeetingState(m)
        XCTAssertTrue(store.unfinishedMeetings().isEmpty)
        store.addSegment(MeetingSegment(meetingID: m.id, source: .mic, startMs: 0, endMs: 1_000, text: "Hello"))
        store.deleteMeeting(id: m.id)
        XCTAssertNil(store.meeting(id: m.id))
        XCTAssertTrue(store.segments(meetingID: m.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testSearchFindsTranscriptText() throws {
        let store = try makeStore()
        let m = Meeting(title: "Planning")
        store.createMeeting(m)
        store.createMeeting(Meeting(title: "Other"))
        store.addSegment(MeetingSegment(meetingID: m.id, source: .system, startMs: 0, endMs: 1_000, text: "Kubernetes upgrade"))
        XCTAssertEqual(store.meetings(search: "kubernetes").map(\.id), [m.id])
    }

    func testSummaryTasksAndFolders() throws {
        let store = try makeStore()
        var m = Meeting(title: "Planning", latestStopSeq: 1)
        store.createMeeting(m)
        store.setSummary(id: m.id, markdown: "Overview.\n\n## Next steps\n- **You** — Ship it", overview: "Overview.",
                         status: .ready, stopSeq: 1)
        XCTAssertEqual(store.meeting(id: m.id)?.summaryStatus, .ready)
        XCTAssertEqual(store.meeting(id: m.id)?.summaryIsStale, false)
        m.latestStopSeq = 2
        store.updateMeetingState(m)
        XCTAssertEqual(store.meeting(id: m.id)?.summaryIsStale, true)

        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Ship it"), (nil, "Write docs")])
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "ship it")]) // already there
        var tasks = store.tasks(meetingID: m.id)
        XCTAssertEqual(tasks.map(\.title), ["Ship it", "Write docs"])
        tasks[0].status = .done
        store.updateTask(tasks[0])
        XCTAssertEqual(store.meeting(id: m.id)?.taskDone, 1)
        XCTAssertEqual(store.meeting(id: m.id)?.taskTotal, 2)

        let f = store.createFolder(name: " Q3 ")
        store.setMeeting(m.id, inFolder: f.id, true)
        XCTAssertEqual(store.folders().first?.name, "Q3")
        XCTAssertEqual(store.folders().first?.meetingCount, 1)
        XCTAssertEqual(store.meetings(inFolder: f.id).map(\.id), [m.id])
        store.deleteMeeting(id: m.id)
        XCTAssertEqual(store.folders().first?.meetingCount, 0)
        XCTAssertEqual(store.tasks(meetingID: nil, includeArchived: true).filter(\.isArchived).count, 2)
    }
}

final class YieldingGeneratorTests: XCTestCase {
    final class Preempting: TextGenerator, @unchecked Sendable {
        let displayName = "Fake"
        var calls = 0
        var sawBackground = true
        func warmUp() async {}
        func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
            calls += 1
            sawBackground = sawBackground && options.background
            if calls == 1 { throw TextGeneratorError.preempted }
            return "done"
        }
    }

    func testRetriesAfterPreemptionAsBackgroundWork() async throws {
        let base = Preempting()
        let g = YieldingGenerator(base, retryDelay: 0.01) { false }
        let out = try await g.generate([ChatMessage(.user, "hi")], options: GenerationOptions())
        XCTAssertEqual(out, "done")
        XCTAssertEqual(base.calls, 2)
        XCTAssertTrue(base.sawBackground)
    }
}
