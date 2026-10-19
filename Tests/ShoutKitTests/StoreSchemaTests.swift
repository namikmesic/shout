import XCTest
@testable import ShoutKit

/// The database schema: created once, in one transaction with its version.
@MainActor
final class StoreSchemaTests: XCTestCase {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("shout-schema-\(UUID().uuidString).sqlite").path
    }

    private func names(_ store: Store, _ type: String) throws -> Set<String> {
        Set(try store.db.query("SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE 'sqlite_%'", type)
            .compactMap { $0["name"]?.string })
    }

    func testNewDatabaseHasEveryTableAtVersion1() throws {
        let store = try Store(path: tempPath())
        XCTAssertEqual(try store.db.userVersion, 1)
        XCTAssertEqual(try names(store, "table"), [
            "history", "dictionary", "notes", "meetings", "meeting_segments", "todos", "folders", "meeting_folders",
            "ask_chats", "ask_messages", "meeting_speaker_spans", "meeting_speaker_aliases",
        ])
        XCTAssertEqual(try names(store, "index"), [
            "history_created", "dictionary_phrase", "meetings_created", "meetings_created_id", "meeting_segments_meeting",
            "todos_meeting", "ask_chats_meeting", "ask_messages_order", "meeting_speaker_spans_meeting",
        ])
    }

    func testOpeningTwiceKeepsTheData() throws {
        let path = tempPath()
        try Store(path: path).createMeeting(Meeting(title: "One"))
        let second = try Store(path: path)
        XCTAssertEqual(try second.db.userVersion, 1)
        XCTAssertEqual(second.meetings().map(\.title), ["One"])
    }

    func testAFailedStepLeavesNoTrace() throws {
        // DDL and user_version are transactional in SQLite: a step that fails is rolled back whole.
        let db = try SQLiteDB(path: tempPath())
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.exec("CREATE TABLE t (a INTEGER)")
            try db.setUserVersion(2)
            throw Boom()
        })
        XCTAssertTrue(try db.query("SELECT name FROM sqlite_master WHERE name = 't'").isEmpty)
        XCTAssertEqual(try db.userVersion, 0)
    }

    func testSummariesLeftGeneratingAreResetWhenTheDatabaseOpens() throws {
        let path = tempPath()
        do {
            let store = try Store(path: path)
            let empty = Meeting(title: "Never finished"), update = Meeting(title: "Update interrupted")
            store.createMeeting(empty); store.createMeeting(update)
            store.setSummary(id: update.id, markdown: "Old summary.", overview: "Old summary.", status: .ready)
            store.setSummaryStatus(id: empty.id, .generating)
            store.setSummaryStatus(id: update.id, .generating)
        }
        let store = try Store(path: path)
        let byTitle = Dictionary(uniqueKeysWithValues: store.meetings().map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Never finished"]?.summaryStatus, Meeting.SummaryStatus.none)
        XCTAssertEqual(byTitle["Update interrupted"]?.summaryStatus, .ready)
        XCTAssertEqual(store.resetInterruptedSummaries(), [byTitle["Never finished"]!.id])
        // A summary started after launch is not touched by the (late) launch recovery call.
        let fresh = Meeting(title: "Started at launch")
        store.createMeeting(fresh)
        store.setSummaryStatus(id: fresh.id, .generating)
        store.resetInterruptedSummaries()
        XCTAssertEqual(store.meeting(id: fresh.id)?.summaryStatus, .generating)
    }
}
