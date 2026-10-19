import XCTest
import Combine
@testable import ShoutKit
import ShoutLLM

/// Answers from a script; records every prompt.
final class ScriptedGenerator: TextGenerator, @unchecked Sendable {
    let displayName = "Scripted"
    let contextTokens: Int
    private let lock = NSLock()
    private var replies: [Result<String, Error>]
    private var _prompts: [[ChatMessage]] = []
    private var _options: [GenerationOptions] = []
    var prompts: [[ChatMessage]] { lock.withLock { _prompts } }
    var options: [GenerationOptions] { lock.withLock { _options } }

    init(contextTokens: Int = 8192, replies: [Result<String, Error>] = []) {
        self.contextTokens = contextTokens
        self.replies = replies
    }

    func warmUp() async {}

    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        let reply = lock.withLock { () -> Result<String, Error> in
            _prompts.append(messages); _options.append(options)
            return replies.isEmpty ? .success("") : replies.removeFirst()
        }
        return try reply.get()
    }
}

/// Answers only once told to, and doesn't notice cancellation (like a model in the middle of a generation).
final class StuckGenerator: TextGenerator, @unchecked Sendable {
    let displayName = "Stuck"
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var finished = false

    func warmUp() async {}

    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if !finished { waiting = c }
                return finished
            }
            if go { c.resume() }
        }
        return "Too Late Title"
    }

    func finish() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            finished = true
            defer { waiting = nil }
            return waiting
        }
        c?.resume()
    }
}

@MainActor
final class ScribeStoreTests: XCTestCase {
    func makeStore() throws -> Store {
        try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("shout-test-\(UUID().uuidString).sqlite").path)
    }

    // MARK: Paging and search (E-B9, G6)

    func testPastNotesPageWithoutGapsOrRepeats() throws {
        let store = try makeStore()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        // Two meetings share a creation time, so the page boundary needs the id to break the tie.
        for i in 0..<7 { store.createMeeting(Meeting(id: "m\(i)", title: "M\(i)", createdAt: base.addingTimeInterval(Double(i / 2) * 60))) }
        var seen: [String] = []
        var page = store.meetings(limit: 3)
        while !page.isEmpty {
            seen += page.map(\.id)
            page = store.meetings(before: page.last, limit: 3)
        }
        XCTAssertEqual(seen, ["m6", "m5", "m4", "m3", "m2", "m1", "m0"])
        XCTAssertEqual(store.meetings(search: "M", before: store.meeting(id: "m4"), limit: 2).map(\.id), ["m3", "m2"])
    }

    func testSearchCoversSummaryAttendeesAndTasksAndTakesWildcardsLiterally() throws {
        let store = try makeStore()
        let a = Meeting(title: "Planning"), b = Meeting(title: "Retro"), c = Meeting(title: "Budget"), d = Meeting(title: "100% sure")
        [a, b, c, d].forEach(store.createMeeting)
        store.setSummary(id: a.id, markdown: "We agreed on the Kubernetes upgrade.", overview: nil, status: .ready)
        store.setMeetingCalendarEvent(id: b.id, eventID: "e", occurrenceStart: nil, participants: ["Joaquin Ruiz"])
        store.addTask(meetingID: c.id, title: "Send the invoice")
        XCTAssertEqual(store.meetings(search: "kubernetes").map(\.id), [a.id])
        XCTAssertEqual(store.meetings(search: "joaquin").map(\.id), [b.id])
        XCTAssertEqual(store.meetings(search: " invoice ").map(\.id), [c.id])
        XCTAssertEqual(store.meetings(search: "%").map(\.id), [d.id])
        XCTAssertTrue(store.meetings(search: "_").isEmpty)
    }

    // MARK: Delete (P17, D21)

    func testDeleteAnnouncesTheMeetingAndKeepsItsTasksWithTheirSource() throws {
        let store = try makeStore()
        let m = Meeting(title: "Design review", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        store.createMeeting(m)
        store.addTask(meetingID: m.id, title: "Update the mockups")
        _ = store.createAskChat(meetingID: m.id, title: "What changed?")
        var deleted: [String] = []
        let sub = store.meetingDeleted.sink { deleted.append($0) }
        defer { sub.cancel() }
        store.deleteMeeting(id: m.id)
        XCTAssertEqual(deleted, [m.id])
        XCTAssertTrue(store.askChats(meetingID: m.id).isEmpty)
        let archived = store.taskList(archived: true)
        XCTAssertEqual(archived.map(\.task.title), ["Update the mockups"])
        XCTAssertEqual(archived.first?.meetingTitle, "Design review")
        XCTAssertEqual(archived.first?.meetingCreatedAt, m.createdAt)
        XCTAssertEqual(archived.first?.canOpenMeeting, false)
        XCTAssertNotNil(archived.first?.archivedAt)
        store.deleteMeeting(id: m.id) // already gone: nothing happens
        XCTAssertEqual(deleted, [m.id])
    }

    // MARK: Generated tasks (D-B4)

    func testEditedDeletedAndRewordedTasksDoNotComeBack() throws {
        let store = try makeStore()
        let m = Meeting(title: "Launch")
        store.createMeeting(m)
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the deck to Priya by Friday"),
                                                          ("Priya", "Draft the pricing proposal"),
                                                          ("Sam", "Book the venue")])
        var tasks = store.tasks(meetingID: m.id)
        XCTAssertEqual(tasks.count, 3)
        // The user edits one, deletes one.
        tasks[0].title = "Send deck and notes to Priya on Monday"
        store.updateTask(tasks[0])
        store.deleteTask(id: tasks[2].id)

        // "Update summary": the same items again, one reworded, one new.
        let previous = ["Send the deck to Priya by Friday", "Draft the pricing proposal", "Book the venue"]
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the deck to Priya by Friday"),
                                                          ("Priya", "Draft a pricing proposal"),
                                                          ("Sam", "Book the venue"),
                                                          ("You", "Share the deck with Priya by Friday"),
                                                          ("Joaquin", "Run the load tests")],
                                previous: previous)
        XCTAssertEqual(store.tasks(meetingID: m.id).map(\.title),
                       ["Send deck and notes to Priya on Monday", "Draft the pricing proposal", "Run the load tests"])
    }

    func testDifferentTasksAreNotMerged() {
        func reworded(_ a: String, _ b: String) -> Bool { TaskMatch.reworded(TaskMatch.key(a), TaskMatch.key(b)) }
        // Rewordings of one task.
        XCTAssertTrue(reworded("Send the decks to Priya", "send deck to priya"))
        XCTAssertTrue(reworded("Send the updated deck to Priya by Friday", "Send Priya the updated deck by Friday"))
        XCTAssertTrue(reworded("Share the deck with Priya by Friday", "Send the deck to Priya by Friday"))
        XCTAssertTrue(reworded("Send the deck to Priya by Friday", "Send the final deck to Priya by Friday"))
        // Different tasks (R4-2): one word swapped is a different action or object, however long the rest.
        XCTAssertFalse(reworded("Send the deck to Priya", "Review the deck with Priya"))
        XCTAssertFalse(reworded("Send the pricing proposal to Priya", "Review the pricing proposal with Priya"))
        XCTAssertFalse(reworded("Email Priya the Q3 numbers", "Email Priya the Q4 numbers"))
        XCTAssertFalse(reworded("Update the release notes for Android before the store submission on Friday",
                                "Update the release notes for iOS before the store submission on Friday"))
        XCTAssertFalse(reworded("Send the invoice", "Send the contract"))
        XCTAssertFalse(reworded("Deploy", "Deploy staging"))
        // Owners: no owner, "You" and the user's name are the user.
        XCTAssertEqual(TaskMatch.owner(nil, userName: nil), TaskMatch.owner("You", userName: nil))
        XCTAssertEqual(TaskMatch.owner("Namik", userName: "Namik Mesic"), TaskMatch.owner("you", userName: "Namik Mesic"))
        XCTAssertNotEqual(TaskMatch.owner("Priya", userName: "Namik"), TaskMatch.owner("You", userName: "Namik"))
    }

    func testOneSummaryCanHaveSimilarButDifferentItems() throws {
        let store = try makeStore()
        let m = Meeting()
        store.createMeeting(m)
        store.addGeneratedTasks(meetingID: m.id, items: [(nil, "Review the pricing draft by Friday"),
                                                          (nil, "Review the pricing doc by Friday"),
                                                          (nil, "Review the pricing doc by Friday"),
                                                          ("Priya", "Review the PR"),
                                                          ("You", "Review the PR")])
        XCTAssertEqual(store.tasks(meetingID: m.id).map { "\($0.owner ?? "-"): \($0.title)" },
                       ["-: Review the pricing draft by Friday", "-: Review the pricing doc by Friday",
                        "Priya: Review the PR", "You: Review the PR"])
    }

    /// R4-2: Regenerate keeps every new task that differs in its action, its details or its owner.
    func testRegeneratedTasksThatDifferAreAdded() throws {
        let store = try makeStore()
        let m = Meeting(title: "Pricing")
        store.createMeeting(m)
        let first: [(owner: String?, text: String)] = [("You", "Send the pricing proposal to Priya"),
                                                       ("You", "Email Priya the Q3 numbers"),
                                                       ("Priya", "Review the PR")]
        store.addGeneratedTasks(meetingID: m.id, items: first)
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Review the pricing proposal with Priya"),
                                                          ("You", "Email Priya the Q4 numbers"),
                                                          ("You", "Review the PR"),
                                                          ("You", "Share the pricing proposal with Priya"), // reworded
                                                          ("Priya", "Review the PR")],                      // already there
                                previous: first.map(\.text))
        XCTAssertEqual(store.tasks(meetingID: m.id).map { "\($0.owner ?? "-"): \($0.title)" },
                       ["You: Send the pricing proposal to Priya", "You: Email Priya the Q3 numbers", "Priya: Review the PR",
                        "You: Review the pricing proposal with Priya", "You: Email Priya the Q4 numbers", "You: Review the PR"])
    }

    /// Stored tasks match only by their exact text; rewordings only against the summary being replaced.
    func testStoredTasksMatchExactlyAndTheUsersNameIsYou() throws {
        let store = try makeStore()
        let m = Meeting()
        store.createMeeting(m)
        store.addGeneratedTasks(meetingID: m.id, items: [("Namik", "Draft the pricing proposal"), (nil, "Book the venue")],
                                userName: "Namik")
        // A later summary (not the one these came from) has the same items, one reworded, owners written differently.
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Draft the pricing proposal"), ("Namik", "Book the venue"),
                                                          ("You", "Draft a pricing proposal")],
                                previous: ["Something else"], userName: "Namik")
        XCTAssertEqual(store.tasks(meetingID: m.id).map(\.title),
                       ["Draft the pricing proposal", "Book the venue", "Draft a pricing proposal"])
    }

    /// R4-4: a next step the user typed into the summary never became a task, so after Regenerate the model's
    /// matching item does.
    func testATaskTypedIntoTheSummaryDoesNotHideTheModelsOne() throws {
        let store = try makeStore()
        let m = Meeting(title: "Mortgage")
        store.createMeeting(m)
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the signed contract")])
        let edited = "We went through the offer.\n\n## Next steps\n- **You** — Send the signed contract\n- **You** — Call the bank"
        store.addGeneratedTasks(meetingID: m.id, items: [("You", "Send the signed contract"), ("You", "Call the bank")],
                                previous: MeetingSummarizer.actionItems(in: edited).map(\.text))
        XCTAssertEqual(store.tasks(meetingID: m.id).map(\.title), ["Send the signed contract", "Call the bank"])
    }

    // MARK: Summaries (R4-1)

    func testTooShortOrNoSpeechNeverErasesASummary() throws {
        let store = try makeStore()
        let m = Meeting(title: "Quick sync", latestStopSeq: 2)
        store.createMeeting(m)
        store.setSummary(id: m.id, markdown: "Short summary.", overview: "Short summary.", status: .ready, stopSeq: 1)
        XCTAssertTrue(store.claimSummaryReadyNotification(id: m.id))
        store.setSummary(id: m.id, markdown: "My edits.", overview: "My edits.", status: .ready, edited: true)
        for status in [Meeting.SummaryStatus.tooShort, .noSpeech] {
            store.setSummary(id: m.id, markdown: nil, overview: nil, status: status, stopSeq: 2)
            let kept = try XCTUnwrap(store.meeting(id: m.id))
            XCTAssertEqual(kept.summary, "My edits.")
            XCTAssertEqual(kept.summaryOverview, "My edits.")
            XCTAssertEqual(kept.summaryStatus, .ready)
            XCTAssertTrue(kept.summaryEdited)
            XCTAssertEqual(kept.summaryStopSeq, 1, "it still covers the recording it covered")
            XCTAssertTrue(kept.summaryIsStale)
        }
        XCTAssertFalse(store.claimSummaryReadyNotification(id: m.id), "nothing new to announce")
        // A meeting without a summary gets the note.
        let short = Meeting(title: "Hi")
        store.createMeeting(short)
        store.setSummary(id: short.id, markdown: nil, overview: nil, status: .tooShort, stopSeq: 1)
        XCTAssertEqual(store.meeting(id: short.id)?.summaryStatus, .tooShort)
        XCTAssertNil(store.meeting(id: short.id)?.summary)
    }

    // MARK: My Tasks and Archived (G1, D-B3)

    func testTaskListAcrossMeetingsWithFilters() throws {
        let store = try makeStore()
        let older = Meeting(title: "", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = Meeting(title: "Sync", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        store.createMeeting(older); store.createMeeting(newer)
        let a = store.addTask(meetingID: older.id, title: "Old task")
        let b = store.addTask(meetingID: newer.id, title: "New task")
        let c = store.addTask(meetingID: newer.id, title: "Second new task")
        let manual = store.addTask(meetingID: nil, title: "Untitled task", atTop: true)
        XCTAssertLessThan(manual.sortOrder, a.sortOrder)
        var done = c; done.status = .done; store.updateTask(done)

        let all = store.taskList()
        XCTAssertEqual(Set(all.map(\.id)), [a.id, b.id, c.id, manual.id])
        XCTAssertEqual(all.first { $0.id == a.id }?.meetingTitle, "Untitled meeting")
        XCTAssertEqual(all.first { $0.id == b.id }?.meetingTitle, "Sync")
        XCTAssertNil(all.first { $0.id == manual.id }?.meetingTitle)
        XCTAssertEqual(store.taskList(done: true).map(\.id), [c.id])
        XCTAssertEqual(Set(store.taskList(done: false).map(\.id)), [a.id, b.id, manual.id])
        XCTAssertEqual(store.taskList(search: "second").map(\.id), [c.id])

        store.setTasksArchived(ids: [a.id, b.id], true)
        XCTAssertEqual(Set(store.taskList(archived: true).map(\.id)), [a.id, b.id])
        XCTAssertEqual(store.tasks(meetingID: newer.id).map(\.id), [c.id])
        XCTAssertEqual(store.tasks(meetingID: newer.id, includeArchived: true).count, 2)
        store.setTasksArchived(ids: [b.id], false) // Unarchive / Undo
        XCTAssertEqual(store.taskList(archived: true).map(\.id), [a.id])
        XCTAssertNil(store.taskList().first { $0.id == b.id }?.archivedAt)

        store.deleteTasks(ids: [b.id, c.id])
        XCTAssertEqual(store.tasks(meetingID: newer.id), [])
        store.restoreDeletedTasks(ids: [b.id]) // Undo
        XCTAssertEqual(store.tasks(meetingID: newer.id).map(\.id), [b.id])
    }

    func testTaskSectionsByDateWithDoneTasksLast() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000) // Friday 2027-01-15, 08:00 UTC
        func item(_ id: String, daysAgo: Double, order: Double) -> TaskListItem {
            TaskListItem(task: MeetingTask(id: id, meetingID: "m", title: id, sortOrder: order),
                         meetingTitle: "M", meetingCreatedAt: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let items = [item("t1", daysAgo: 0, order: 3000), item("t2", daysAgo: 0, order: 1000), item("t3", daysAgo: 0, order: 2000),
                     item("y", daysAgo: 1, order: 1), item("w", daysAgo: 6, order: 1), item("o", daysAgo: 7, order: 1)]
        let sections = TaskGroup.sections(items, doneAtLoad: ["t2"], now: now, calendar: cal)
        XCTAssertEqual(sections.map(\.group), [.today, .yesterday, .lastWeek, .older])
        XCTAssertEqual(sections[0].items.map(\.id), ["t3", "t1", "t2"])
        XCTAssertEqual(sections.map(\.group.title), ["Today", "Yesterday", "Last week", "Older"])
    }

    // MARK: Titles (G2)

    func testTitleIsWrittenOnlyWhileBlank() throws {
        let store = try makeStore()
        let m = Meeting(title: "  ")
        store.createMeeting(m)
        XCTAssertTrue(store.setTitleIfBlank(id: m.id, title: "Pricing Review"))
        XCTAssertFalse(store.setTitleIfBlank(id: m.id, title: "Something Else"))
        XCTAssertEqual(store.meeting(id: m.id)?.title, "Pricing Review")
    }

    func testTitleAtStopRetriesThenWritesFromTheTranscript() async throws {
        let store = try makeStore()
        let m = Meeting(title: "", status: .complete, notes: "pricing tiers?")
        store.createMeeting(m)
        store.addSegment(MeetingSegment(meetingID: m.id, source: .system, startMs: 0, endMs: 2_000,
                                        text: "Let's go through the enterprise pricing tiers."))
        let gen = ScriptedGenerator(replies: [.failure(TextGeneratorError.generationFailed("busy")), .success("Title: enterprise pricing tiers.")])
        let title = await store.generateTitleIfBlank(meetingID: m.id, userName: nil, generator: { gen }, retryDelays: [0.01, 0.01])
        XCTAssertEqual(title, "Enterprise Pricing Tiers")
        XCTAssertEqual(store.meeting(id: m.id)?.title, "Enterprise Pricing Tiers")
        XCTAssertEqual(gen.prompts.count, 2)
        let user = try XCTUnwrap(gen.prompts.last?.last?.content)
        XCTAssertTrue(user.contains("<user_notes>\npricing tiers?\n</user_notes>"))
        XCTAssertTrue(user.contains("Others: Let's go through the enterprise pricing tiers."))
        XCTAssertTrue(gen.options.allSatisfy(\.background))
    }

    func testTitleIsSkippedForTitledEmptyOrUnfinishedMeetings() async throws {
        let store = try makeStore()
        let titled = Meeting(title: "From the calendar", status: .complete)
        let empty = Meeting(title: "", status: .complete)
        let live = Meeting(title: "", status: .recording, notes: "agenda")
        [titled, empty, live].forEach(store.createMeeting)
        store.addSegment(MeetingSegment(meetingID: titled.id, source: .mic, startMs: 0, endMs: 1_000, text: "Hello there"))
        let gen = ScriptedGenerator(replies: [.success("Should Not Be Used")])
        XCTAssertEqual(store.meetingsNeedingTitle().map(\.id), [])
        for m in [titled, empty, live] {
            let t = await store.generateTitleIfBlank(meetingID: m.id, userName: nil, generator: { gen }, retryDelays: [])
            XCTAssertNil(t)
        }
        XCTAssertTrue(gen.prompts.isEmpty)
    }

    func testLaunchScanNamesBlankFinishedMeetings() async throws {
        let store = try makeStore()
        let a = Meeting(title: "", createdAt: Date(timeIntervalSince1970: 1), status: .complete, notes: "Hiring plan for Q3")
        let b = Meeting(title: "", createdAt: Date(timeIntervalSince1970: 2), status: .complete)
        [a, b].forEach(store.createMeeting)
        store.addSegment(MeetingSegment(meetingID: b.id, source: .mic, startMs: 0, endMs: 1_000, text: "Quick budget check", latched: true))
        XCTAssertEqual(store.meetingsNeedingTitle().map(\.id), [a.id]) // b's only line was echo
        let gen = ScriptedGenerator(replies: [.success("Q3 Hiring Plan")])
        let named = await store.generateMissingTitles(userName: nil, generator: { gen })
        XCTAssertEqual(named, 1)
        XCTAssertEqual(store.meeting(id: a.id)?.title, "Q3 Hiring Plan")
    }

    private func untitled(_ store: Store, at seconds: Double, saying text: String) -> Meeting {
        let m = Meeting(title: "", createdAt: Date(timeIntervalSince1970: seconds), status: .complete, latestStopSeq: 1)
        store.createMeeting(m)
        store.addSegment(MeetingSegment(meetingID: m.id, source: .mic, startMs: 0, endMs: 2_000, text: text))
        return m
    }

    /// R4-5: meetings with nothing to name them by are set aside without using up the scan.
    func testLaunchScanSkipsMeetingsItCannotNameAndReachesOlderOnes() async throws {
        let store = try makeStore()
        let real = untitled(store, at: 1, saying: "Let's plan the hiring for Q3.")
        for i in 0..<12 { _ = untitled(store, at: Double(10 + i), saying: "Um.") }
        let gen = ScriptedGenerator(replies: [.success("Q3 Hiring Plan")])
        let named = await store.generateMissingTitles(limit: 10, userName: nil, generator: { gen })
        XCTAssertEqual(named, 1)
        XCTAssertEqual(store.meeting(id: real.id)?.title, "Q3 Hiring Plan")
        XCTAssertEqual(gen.prompts.count, 1, "the model is asked only about the meeting it can name")
        XCTAssertTrue(store.meetingsNeedingTitle(limit: 50).isEmpty, "the next launch has nothing to do")
    }

    /// R4-5: a meeting the model can't name is tried once per recording, not at every launch.
    func testLaunchScanTriesAMeetingOncePerRecording() async throws {
        let store = try makeStore()
        var m = untitled(store, at: 1, saying: "Budget review for the marketing team.")
        // No model, or one that can't be loaded: nothing is marked, the next launch tries again.
        struct LoadFailed: Error {}
        var named = await store.generateMissingTitles(userName: nil, generator: { nil })
        named += await store.generateMissingTitles(userName: nil, generator: { throw LoadFailed() })
        XCTAssertEqual(named, 0)
        XCTAssertEqual(store.meetingsNeedingTitle().map(\.id), [m.id])
        // The model fails: not tried again at the next launch...
        let failing = ScriptedGenerator(replies: [.failure(TextGeneratorError.generationFailed("busy"))])
        named = await store.generateMissingTitles(userName: nil, generator: { failing })
        XCTAssertEqual(named, 0)
        XCTAssertEqual(failing.prompts.count, 1)
        XCTAssertTrue(store.meetingsNeedingTitle().isEmpty)
        // ...until it is recorded again.
        m.latestStopSeq = 2
        store.updateMeetingState(m)
        XCTAssertEqual(store.meetingsNeedingTitle().map(\.id), [m.id])
    }

    /// R4-5: the budget holds within an attempt, also when the model doesn't react to cancellation.
    func testLaunchScanStopsAtItsBudgetMidAttempt() async throws {
        let store = try makeStore()
        let m = untitled(store, at: 1, saying: "Budget review for the marketing team.")
        // Waiting for dictation to end (cancellable).
        let waiting = YieldingGenerator(ScriptedGenerator(replies: [.success("Never Used")]), isBusy: { true })
        var start = Date()
        var named = await store.generateMissingTitles(budget: 0.3, userName: nil, generator: { waiting })
        XCTAssertEqual(named, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        // A model that doesn't notice: the scan doesn't wait for it, and its late answer is dropped.
        let stuck = StuckGenerator()
        start = Date()
        named = await store.generateMissingTitles(budget: 0.3, userName: nil, generator: { stuck })
        XCTAssertEqual(named, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        stuck.finish()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.meeting(id: m.id)?.title, "")
        // Running out of time is not a failed attempt: the next launch tries again.
        XCTAssertEqual(store.meetingsNeedingTitle().map(\.id), [m.id])
    }

    // MARK: "Your summary is ready!" (G4)

    func testSummaryReadyNotificationIsClaimedOncePerSummary() throws {
        let store = try makeStore()
        let m = Meeting(title: "Sync")
        store.createMeeting(m)
        XCTAssertFalse(store.claimSummaryReadyNotification(id: m.id))
        store.setSummary(id: m.id, markdown: "Done.", overview: "Done.", status: .ready, stopSeq: 1)
        XCTAssertTrue(store.claimSummaryReadyNotification(id: m.id))
        XCTAssertFalse(store.claimSummaryReadyNotification(id: m.id))
        // The user's own edit is not a new summary; an Update is.
        store.setSummary(id: m.id, markdown: "Done, edited.", overview: "Done, edited.", status: .ready, edited: true)
        XCTAssertFalse(store.claimSummaryReadyNotification(id: m.id))
        store.setSummary(id: m.id, markdown: "Updated.", overview: "Updated.", status: .ready, stopSeq: 2)
        XCTAssertTrue(store.claimSummaryReadyNotification(id: m.id))
        // A too-short result is nothing to announce.
        store.setSummary(id: m.id, markdown: nil, overview: nil, status: .tooShort, stopSeq: 3)
        XCTAssertFalse(store.claimSummaryReadyNotification(id: m.id))
        let text = MeetingSummarizer.readyNotification(meetingTitle: "Sync")
        XCTAssertEqual(text.title, "Your summary is ready!")
        XCTAssertEqual(text.body, "From Sync")
        XCTAssertEqual(MeetingSummarizer.readyNotification(meetingTitle: " ").body, "Synthesized your notes")
        XCTAssertEqual(text.action, "View summary")
    }

    // MARK: Ask history (G3)

    func testAskChatsArePersistedPerMeeting() throws {
        let store = try makeStore()
        let m = Meeting(title: "Sync")
        store.createMeeting(m)
        let chat = store.createAskChat(meetingID: m.id, title: "  What did we decide?  ")
        XCTAssertEqual(chat.title, "What did we decide?")
        let source = AskSource(id: m.id, title: "Sync", date: Date())
        let first = store.addAskQuestion(chatID: chat.id, question: "What did we decide?", sources: [source])
        store.finishAskAnswer(id: first.id, content: "Ship on the 28th. [Sync]", status: .succeeded, model: "Fake", latencyMs: 1200)
        let second = store.addAskQuestion(chatID: chat.id, question: "Who owns pricing?", sources: [source])
        XCTAssertEqual(second.status, .pending)
        store.interruptPendingAskAnswers(chatID: chat.id) // the sheet closed mid-answer

        let messages = store.askMessages(chatID: chat.id)
        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(messages.map(\.status), [.succeeded, .succeeded, .succeeded, .interrupted])
        XCTAssertEqual(messages[1].sources, [AskMessage.Source(id: m.id, title: "Sync")])
        XCTAssertEqual(messages[1].model, "Fake")
        XCTAssertEqual(messages[1].latencyMs, 1200)
        XCTAssertEqual(MeetingAsk.history(messages), [MeetingAsk.Turn(question: "What did we decide?", answer: "Ship on the 28th. [Sync]")])

        XCTAssertEqual(store.askChats(meetingID: m.id).map(\.id), [chat.id])
        XCTAssertTrue(store.askChats(meetingID: nil).isEmpty)
        let hub = store.createAskChat(meetingID: nil, title: "Across meetings")
        XCTAssertEqual(store.askChats(meetingID: nil).map(\.id), [hub.id])
        store.deleteAskChat(id: hub.id)
        XCTAssertTrue(store.askChats(meetingID: nil).isEmpty)
    }

    func testPendingAnswersAreInterruptedAtLaunch() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("shout-test-\(UUID().uuidString).sqlite").path
        let chatID: String
        do {
            let store = try Store(path: path)
            let chat = store.createAskChat(meetingID: nil, title: "Q")
            chatID = chat.id
            store.addAskQuestion(chatID: chat.id, question: "Q", sources: [])
        }
        let store = try Store(path: path)
        XCTAssertEqual(store.askMessages(chatID: chatID).last?.status, .interrupted)
    }

    func testOldestChatsArePrunedBeyondTheCap() throws {
        let store = try makeStore()
        var ids: [String] = []
        for i in 0..<(Store.maxAskChats + 3) {
            let chat = store.createAskChat(meetingID: nil, title: "Q\(i)")
            ids.append(chat.id)
            _ = try store.db.run("UPDATE ask_chats SET last_accessed_at = ? WHERE id = ?", Double(i), chat.id)
        }
        let kept = Set(store.askChats(meetingID: nil).map(\.id))
        XCTAssertEqual(kept.count, Store.maxAskChats)
        XCTAssertFalse(kept.contains(ids[0]))
        XCTAssertTrue(kept.contains(ids.last!))
    }
}
