import XCTest
@testable import ShoutKit

/// Store queries added for callers in the app target: each must agree with the query it replaces there.
@MainActor
final class Review3CrossFileTests: XCTestCase {
    func makeStore() throws -> Store {
        try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("shout-test-\(UUID().uuidString).sqlite").path)
    }

    func testSetupProgressMatchesTheMeetingsItSummarizes() throws {
        let store = try makeStore()
        XCTAssertEqual(store.meetingSetupProgress().hasNote, false)
        XCTAssertEqual(store.meetingSetupProgress().hasSummary, false)
        let m = Meeting(title: "Standup")
        store.createMeeting(m)
        XCTAssertEqual(store.meetingSetupProgress().hasNote, true)
        XCTAssertEqual(store.meetingSetupProgress().hasSummary, false)
        store.setSummaryStatus(id: m.id, .failed)
        XCTAssertEqual(store.meetingSetupProgress().hasSummary, false)
        store.setSummary(id: m.id, markdown: "Shipped.", overview: nil, status: .ready)
        XCTAssertEqual(store.meetingSetupProgress().hasSummary, true)
    }

    func testSetupProgressCountsASummaryFromBeforeSummaryStatus() throws {
        let store = try makeStore()
        let m = Meeting(title: "Old")
        store.createMeeting(m)
        try store.db.run("UPDATE meetings SET summary = 'Notes', summary_status = NULL WHERE id = ?", m.id)
        XCTAssertEqual(store.meeting(id: m.id)?.summaryStatus, .ready, "the row mapper's rule")
        XCTAssertEqual(store.meetingSetupProgress().hasSummary, true)
    }

    func testArchivedTaskCountMatchesTheArchivedList() throws {
        let store = try makeStore()
        let m = Meeting(title: "Planning")
        store.createMeeting(m)
        let a = store.addTask(meetingID: m.id, title: "One")
        let b = store.addTask(meetingID: m.id, title: "Two")
        let c = store.addTask(meetingID: nil, title: "Three")
        _ = store.addTask(meetingID: m.id, title: "Open")
        store.setTasksArchived(ids: [a.id, b.id, c.id], true)
        store.deleteTask(id: b.id)
        XCTAssertEqual(store.archivedTaskCount(), store.taskList(archived: true).count)
        XCTAssertEqual(store.archivedTaskCount(), 2)
    }

    func testOverlappingSegmentsMatchFilteringTheWholeTranscript() throws {
        let store = try makeStore()
        let m = Meeting(title: "Call")
        store.createMeeting(m)
        for (i, start) in [0, 50_000, 61_000, 120_000, 180_000, 240_000].enumerated() {
            _ = store.addSegment(MeetingSegment(meetingID: m.id, source: i.isMultiple(of: 2) ? .mic : .system,
                                                startMs: start, endMs: start + 9_000, text: "line \(i)"))
        }
        let lo = 120_000 - 60_000, hi = 129_000 + 60_000
        let expected = store.segments(meetingID: m.id).filter { $0.endMs > lo && $0.startMs < hi }
        let got = store.segments(meetingID: m.id, overlappingMs: lo, hi)
        XCTAssertEqual(got.map(\.id), expected.map(\.id))
        XCTAssertEqual(got.map(\.text), ["line 2", "line 3", "line 4"])
    }

    func testAskSourcesCanBeGatheredOffTheMainActor() async throws {
        let store = try makeStore()
        let m = Meeting(title: "Budget review")
        store.createMeeting(m)
        _ = store.addSegment(MeetingSegment(meetingID: m.id, source: .system, startMs: 0, endMs: 4_000,
                                            text: "The budget for Q3 is approved."))
        let sources = await Task.detached { store.askSources(question: "What about the budget?", meetingID: nil) }.value
        XCTAssertEqual(sources.map(\.id), [m.id])
        XCTAssertTrue(sources.first?.transcript.contains("approved") ?? false)
    }
}
