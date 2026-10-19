import XCTest
import AVFoundation
@testable import ShoutKit

private func temporaryFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shout-g05-\(UUID().uuidString)")
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

// MARK: - Archive

final class Review3G05ArchiveTests: XCTestCase {
    var dir: URL!
    let pulse = chirp()

    override func setUpWithError() throws { dir = try temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func testShortAndOddSizedReadsNeverShiftTheTrack() {
        let samples: [Float] = (0..<1_000).map { Float(sin(Double($0) * 0.37)) * 0.8 }
        let bytes = pcmData(samples)
        var cursor = 0
        // Never more than 3 bytes at a time: every other read ends in the middle of a sample.
        let trickle: (Int) -> Data? = { want in
            let n = min(want, 3, bytes.count - cursor)
            guard n > 0 else { return nil }
            defer { cursor += n }
            return bytes.subdata(in: cursor..<cursor + n)
        }
        var out: [Float] = []
        var block = [Float](repeating: 0, count: 256)
        for _ in 0..<4 {
            block.withUnsafeMutableBufferPointer { MeetingArchive.PCMReader.read(into: $0.baseAddress!, count: 256, next: trickle) }
            out += block
        }
        let expected = samples.map { Float(Int16(max(-1, min(1, $0)) * 32767)) / 32767 }
        XCTAssertEqual(Array(out.prefix(1_000)), expected)
        XCTAssertEqual(Array(out.suffix(24)), [Float](repeating: 0, count: 24), "silence after the end")
    }

    func testAnOddByteAtTheEndOfATrackShiftsNoChannel() throws {
        let length = 64_000, micPulses = [4_000, 40_000], systemPulses = [12_000, 56_000]
        // A writer cut off mid-sample: one stray byte at the end of the microphone track.
        try (pcmData(timeline(length, pulses: micPulses, pulse: pulse)) + Data([0x7f])).write(to: url("mic.pcm"))
        try pcmData(timeline(length, pulses: systemPulses, pulse: pulse)).write(to: url("system.pcm"))
        let done = expectation(description: "archived")
        nonisolated(unsafe) var result: Result<Int?, Error>?
        MeetingArchiver().archive(folder: dir) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(try XCTUnwrap(result).get(), length)
        XCTAssertNil(MeetingArchive.files(in: dir).mic, "the raw tracks went only after the archive verified")
        for (source, positions) in [(MeetingSource.mic, micPulses), (.system, systemPulses)] {
            for p in positions {
                let start = p - 2_048
                let x = try MeetingArchive.read(source, in: dir, offset: start, count: 4_096 + pulse.count)
                XCTAssertEqual(start + locate(pulse, in: x), p, accuracy: 48, "\(source.rawValue) pulse at \(p)")
            }
        }
    }

    func testOneWaitCoversTheEncodesLaunchRecoveryStarts() throws {
        let root = dir!, folder = root.appendingPathComponent("idle")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try pcmData(timeline(32_000, pulses: [8_000], pulse: pulse)).write(to: folder.appendingPathComponent("mic.pcm"))
        try pcmData(timeline(32_000, pulses: [20_000], pulse: pulse)).write(to: folder.appendingPathComponent("system.pcm"))
        let archiver = MeetingArchiver()
        archiver.recoverAll(in: root)
        archiver.waitUntilIdle()
        let files = MeetingArchive.files(in: folder)
        XCTAssertNotNil(files.archive)
        XCTAssertNil(files.mic)
        XCTAssertNil(files.system)
    }
}

// MARK: - Track

final class Review3G05TrackTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws { dir = try temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testPaddingOrEndingALegAfterCloseChangesNothing() throws {
        let url = dir.appendingPathComponent("mic.pcm")
        let t = try MeetingTrack(source: .mic, url: url)
        t.beginLeg(at: 0)
        t.append([Float](repeating: 0.1, count: 640), at: 0)
        let length = t.endLeg(at: 1)
        t.close()
        t.pad(toLength: length + 16_000)
        XCTAssertEqual(t.endLeg(at: 5), length)
        XCTAssertEqual(t.sampleCount, length, "the timeline stays with the file")
        XCTAssertEqual(MeetingTrack.sampleCount(url), length)
        XCTAssertFalse(t.stats.writeFailed)
    }

    func testReadingAtANegativePositionThrows() throws {
        let url = dir.appendingPathComponent("system.pcm")
        try pcmData([0.5, 0.25]).write(to: url)
        XCTAssertThrowsError(try MeetingTrack.read(url, offset: -1, count: 1))
        XCTAssertThrowsError(try MeetingTrack.read(url, offset: 0, count: -1))
        XCTAssertEqual(try MeetingTrack.read(url, offset: 1, count: 1).first ?? 0, 0.25, accuracy: 0.001)
    }
}

// MARK: - SQLite

final class Review3G05SQLiteTests: XCTestCase {
    var path: String!
    override func setUp() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("shout-g05-\(UUID().uuidString).sqlite").path
    }
    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    func testScalarIsTheFirstColumn() throws {
        let db = try SQLiteDB(path: path)
        for _ in 0..<5 {
            XCTAssertEqual(try db.scalar("SELECT 1 AS h, 2 AS g, 3 AS f, 4 AS e, 5 AS d, 6 AS c, 7 AS b, 8 AS a").int, 1)
        }
        try db.exec("CREATE TABLE t (a INTEGER)")
        XCTAssertEqual(try db.scalar("SELECT a FROM t"), .null, "no row")
    }

    func testAValueThatCannotBeBoundFailsTheStatement() throws {
        let db = try SQLiteDB(path: path)
        try db.exec("CREATE TABLE t (a INTEGER, b TEXT)")
        XCTAssertThrowsError(try db.run("INSERT INTO t (a) VALUES (?)", 1, "one too many"))
        XCTAssertThrowsError(try db.query("SELECT * FROM t WHERE a = ?", 1, 2))
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM t").int, 0)
        try db.run("INSERT INTO t (a, b) VALUES (?, ?)", 1, nil)
        XCTAssertEqual(try db.query("SELECT * FROM t"), [["a": .int(1), "b": .null]])
    }

    func testUserVersionReadsTheStoredVersion() throws {
        let db = try SQLiteDB(path: path)
        XCTAssertEqual(try db.userVersion, 0)
        try db.setUserVersion(8)
        XCTAssertEqual(try db.userVersion, 8)
    }

    func testAFailedOpenSaysWhy() {
        XCTAssertThrowsError(try SQLiteDB(path: "/nonexistent-\(UUID().uuidString)/x.sqlite")) { error in
            XCTAssertTrue((error as? SQLiteDB.DBError)?.message.contains(": ") == true, "\(error)")
        }
    }
}

// MARK: - Store

@MainActor
final class Review3G05StoreTests: XCTestCase {
    private var paths: [String] = []

    private func tempPath() -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("shout-g05-\(UUID().uuidString).sqlite").path
        paths.append(p)
        return p
    }

    override func tearDown() async throws {
        for p in paths { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + suffix) } }
    }

    func testUsageStatsCompareEveryShownValue() {
        var a = UsageStats(), b = UsageStats()
        a.topApps = [("Mail", 10)]; b.topApps = [("Mail", 10)]
        XCTAssertEqual(a, b)
        b.minutesSaved = 3
        XCTAssertNotEqual(a, b)
        b.minutesSaved = 0; b.topApps = [("Mail", 12)]
        XCTAssertNotEqual(a, b)
    }

    func testInterruptedSummariesAreHandedOutOnce() throws {
        let path = tempPath()
        let m = Meeting(title: "Interrupted")
        do {
            let store = try Store(path: path)
            store.createMeeting(m)
            store.setSummaryStatus(id: m.id, .generating)
        }
        let store = try Store(path: path)
        XCTAssertEqual(store.resetInterruptedSummaries(), [m.id])
        XCTAssertEqual(store.resetInterruptedSummaries(), [], "a second recovery pass doesn't summarize it again")
    }

    func testTranscriptLinesAreNumberedInOrder() throws {
        let store = try Store(path: tempPath())
        let m = Meeting(title: "Numbered")
        store.createMeeting(m)
        let seqs = (0..<3).map { i in
            store.addSegment(MeetingSegment(meetingID: m.id, source: .mic, startMs: i * 1000, endMs: i * 1000 + 500, text: "line \(i)")).seq
        }
        XCTAssertEqual(seqs, [1, 2, 3])
        XCTAssertEqual(store.segments(meetingID: m.id).map(\.seq), [1, 2, 3])
        store.setSegmentLatched(ids: Set(store.segments(meetingID: m.id).prefix(2).map(\.id)), latched: true)
        XCTAssertEqual(store.segments(meetingID: m.id).map(\.latched), [true, true, false])
    }

    func testGeneratedTasksAreAddedAllOrNothing() throws {
        let store = try Store(path: tempPath())
        let m = Meeting(title: "Tasks")
        store.createMeeting(m)
        // The second insert of this meeting fails.
        try store.db.exec("""
            CREATE TEMP TRIGGER second_task_fails BEFORE INSERT ON todos
            WHEN (SELECT COUNT(*) FROM todos WHERE meeting_id = NEW.meeting_id) >= 1
            BEGIN SELECT RAISE(ABORT, 'disk full'); END;
            """)
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the deck"), ("You", "Book the venue")])
        XCTAssertEqual(store.tasks(meetingID: m.id).map(\.title), [], "rolled back, so the next summary adds both")
        try store.db.exec("DROP TRIGGER second_task_fails")
        let before = store.meetingsRevision
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the deck"), ("You", "Book the venue")])
        XCTAssertEqual(store.tasks(meetingID: m.id).map(\.title), ["Send the deck", "Book the venue"])
        XCTAssertEqual(store.meetingsRevision, before + 1, "one refresh for the batch")
    }

    func testAskTurnsAreOrderedAndAnAnswerKeepsItsSources() throws {
        let store = try Store(path: tempPath())
        let chat = store.createAskChat(meetingID: nil, title: "Q")
        let source = AskSource(id: "m1", title: "Sync", date: Date())
        let first = store.addAskQuestion(chatID: chat.id, question: "One?", sources: [source])
        let second = store.addAskQuestion(chatID: chat.id, question: "Two?", sources: [])
        XCTAssertEqual([first.order, second.order], [2, 4])
        store.finishAskAnswer(id: first.id, content: "Yes.", status: .succeeded, model: "Scripted", latencyMs: 12)
        let messages = store.askMessages(chatID: chat.id)
        XCTAssertEqual(messages.map(\.order), [1, 2, 3, 4])
        let answer = try XCTUnwrap(messages.first { $0.id == first.id })
        XCTAssertEqual(answer.content, "Yes.")
        XCTAssertEqual(answer.status, .succeeded)
        XCTAssertEqual(answer.sources, [AskMessage.Source(id: "m1", title: "Sync")])
        XCTAssertEqual(answer.model, "Scripted")
    }

    func testUsageIsCountedForEveryEntry() throws {
        let store = try Store(path: tempPath())
        store.addDictionaryEntry(phrase: "Kubernetes")
        store.addDictionaryEntry(phrase: "Priya")
        store.bumpUsage(ids: store.dictionary.map(\.id))
        store.bumpUsage(ids: store.dictionary.map(\.id))
        XCTAssertEqual(store.dictionary.map(\.useCount), [2, 2])
    }
}
