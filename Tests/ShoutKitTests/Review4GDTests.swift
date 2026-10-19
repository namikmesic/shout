import XCTest
@testable import ShoutKit

/// Greptile on PR #2: generated-task matching across Updates and for tasks added by hand.
@MainActor
final class Review4GDTests: XCTestCase {
    private func makeStore() throws -> Store {
        try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("shout-r4gd-\(UUID().uuidString).sqlite").path)
    }

    private func titles(_ store: Store, _ meetingID: String) -> [String] {
        store.tasks(meetingID: meetingID, includeArchived: true).map(\.title)
    }

    /// A rewording skipped on one Update is remembered as the task's, so the next Update's rewording of it (the
    /// summary now has that wording) still matches, also once the task is deleted or archived.
    func testRewordingsStayMatchedAcrossConsecutiveUpdates() throws {
        let store = try makeStore()
        let m = Meeting(title: "Launch")
        store.createMeeting(m)
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the deck to Priya"), ("Sam", "Book the venue")])
        // Update 1 rewords it: skipped, and the summary now says "Share the deck with Priya".
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Share the deck with Priya"), ("Sam", "Book the venue")],
                                previous: ["Send the deck to Priya", "Book the venue"])
        XCTAssertEqual(titles(store, m.id), ["Send the deck to Priya", "Book the venue"])
        let tasks = store.tasks(meetingID: m.id)
        store.deleteTask(id: tasks[0].id)
        store.setTasksArchived(ids: [tasks[1].id], true)

        // Update 2 rewords the summary's wording; a different task is still added.
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the updated deck to Priya"), ("Sam", "Book the venue"),
                                                          ("You", "Review the deck with Priya")],
                                previous: ["Share the deck with Priya", "Book the venue"])
        XCTAssertEqual(titles(store, m.id), ["Book the venue", "Review the deck with Priya"])

        // A summary that doesn't have it: every wording the task was matched under matches exactly; another
        // owner's is a different task.
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Share the deck with Priya"), ("You", "Send the updated deck to Priya"),
                                                          ("Sam", "Share the deck with Priya")],
                                previous: ["Something else"])
        XCTAssertEqual(titles(store, m.id), ["Book the venue", "Review the deck with Priya", "Share the deck with Priya"])
    }

    /// A task added by hand (no `source_key`) that a rewording is matched to keeps its title as a key too, so
    /// editing it afterwards doesn't bring its first wording back.
    func testATaskAddedByHandKeepsItsTitleAsKeyWhenARewordingIsRemembered() throws {
        let store = try makeStore()
        let m = Meeting(title: "Launch")
        store.createMeeting(m)
        store.addTask(meetingID: m.id, title: "Send the deck to Priya", owner: "You")
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Share the deck with Priya")], previous: ["Send the deck to Priya"])
        var task = try XCTUnwrap(store.tasks(meetingID: m.id).first)
        task.title = "Send deck and notes to Priya on Monday"
        store.updateTask(task)
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the deck to Priya"), ("You", "Share the deck with Priya")],
                                previous: ["Something else"])
        XCTAssertEqual(titles(store, m.id), ["Send deck and notes to Priya on Monday"])
    }
}
