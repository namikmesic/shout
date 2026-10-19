import XCTest
@testable import ShoutKit

@MainActor
final class SpeakerStoreTests: XCTestCase {
    private var store: Store!
    private var path = ""
    private let meeting = Meeting(id: "m1", title: "Sync", status: .complete)

    override func setUp() async throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("shout-speakers-\(UUID().uuidString).sqlite").path
        store = try Store(path: path)
        store.createMeeting(meeting)
    }

    @discardableResult
    private func add(_ source: MeetingSource, _ start: Int, _ end: Int, speaker: String? = nil, origin: SpeakerOrigin? = nil) -> MeetingSegment {
        store.addSegment(MeetingSegment(meetingID: meeting.id, source: source, speaker: speaker, startMs: start, endMs: end,
                                        text: "Something said.", speakerOrigin: origin))
    }

    func testSpansRoundTripAndAreDeletedByLeg() {
        let spans = [
            SpeakerSpan.matched("Ada", 0, 1_000, platform: .meet),
            SpeakerSpan(leg: 3, startMs: 1_000, endMs: 2_000, platform: .teams, state: .ambiguous, speakingNames: ["Ada", "Bob"],
                        mutedNames: ["Cy"], selfName: "Sam", source: .teamsMain, reason: nil),
            SpeakerSpan(leg: 3, startMs: 2_000, endMs: 2_500, platform: .teams, state: .unknown, source: .teamsCompact, reason: .readFailed),
        ]
        store.appendSpeakerSpans(meetingID: meeting.id, spans)
        XCTAssertEqual(store.speakerSpans(meetingID: meeting.id), spans)
        store.deleteSpeakerSpans(meetingID: meeting.id, leg: 3)
        XCTAssertEqual(store.speakerSpans(meetingID: meeting.id), [spans[0]])
        XCTAssertEqual(store.speakerTalkTime(meetingID: meeting.id), ["Ada": 1_000])
        store.deleteMeeting(id: meeting.id)
        XCTAssertEqual(try store.db.scalar("SELECT COUNT(*) FROM meeting_speaker_spans").int, 0, "they go with the meeting")
    }

    func testNamesAreAppliedOnlyToOthersLinesTheAppNamed() {
        let a = add(.system, 0, 1_000)
        let b = add(.system, 1_000, 2_000, speaker: "Old", origin: .ax)
        let mine = add(.system, 2_000, 3_000, speaker: "Grace", origin: .user)
        let mic = add(.mic, 3_000, 4_000)
        let changed = store.applySpeakerNames(meetingID: meeting.id, [a.id: "Ada", b.id: nil, mine.id: "Ada", mic.id: "Ada"])
        XCTAssertEqual(changed, 2)
        let byID = Dictionary(uniqueKeysWithValues: store.segments(meetingID: meeting.id).map { ($0.id, $0) })
        XCTAssertEqual(byID[a.id]?.speaker, "Ada")
        XCTAssertEqual(byID[a.id]?.speakerOrigin, .ax)
        XCTAssertNil(byID[b.id]?.speaker)
        XCTAssertNil(byID[b.id]?.speakerOrigin)
        XCTAssertEqual(byID[mine.id]?.speaker, "Grace", "the user's label stays")
        XCTAssertNil(byID[mic.id]?.speaker, "You is never renamed")
        let revision = store.meetingsRevision
        XCTAssertEqual(store.applySpeakerNames(meetingID: meeting.id, [a.id: "Ada", b.id: nil]), 0, "idempotent")
        XCTAssertEqual(store.meetingsRevision, revision)
    }

    func testRenamingASpeakerRenamesEveryLineAndReading() {
        let a = add(.system, 0, 1_000, speaker: "Ada", origin: .ax)
        let b = add(.system, 1_000, 2_000, speaker: "ada (Guest)", origin: .ax)
        let c = add(.system, 2_000, 3_000, speaker: "Bob", origin: .ax)
        store.appendSpeakerSpans(meetingID: meeting.id, [
            .matched("Ada", 0, 1_000),
            SpeakerSpan(startMs: 1_000, endMs: 2_000, platform: .zoom, state: .ambiguous, speakingNames: ["Ada", "Bob"]),
        ])
        store.renameSpeaker(meetingID: meeting.id, from: "Ada", to: " Ada  Lovelace ")
        let byID = Dictionary(uniqueKeysWithValues: store.segments(meetingID: meeting.id).map { ($0.id, $0) })
        XCTAssertEqual(byID[a.id]?.speaker, "Ada Lovelace")
        XCTAssertEqual(byID[b.id]?.speaker, "Ada Lovelace", "same person by key")
        XCTAssertEqual(byID[a.id]?.speakerOrigin, .user)
        XCTAssertEqual(byID[c.id]?.speaker, "Bob")
        XCTAssertEqual(byID[c.id]?.speakerOrigin, .ax)
        let spans = store.speakerSpans(meetingID: meeting.id)
        XCTAssertEqual(spans.map(\.speakerName), ["Ada Lovelace", nil])
        XCTAssertEqual(spans.last?.speakingNames, ["Ada Lovelace", "Bob"])
        // A line named later from the same readings gets the new name.
        let d = add(.system, 100, 500)
        store.applySpeakerNames(meetingID: meeting.id, SpeakerAttribution.attribute(segments: store.segments(meetingID: meeting.id),
                                                                                    spans: spans))
        XCTAssertEqual(store.segments(meetingID: meeting.id).first { $0.id == d.id }?.speaker, "Ada Lovelace")
    }

    /// R6-1: rename "Bob" to "Robert", resume, Bob speaks again: still "Robert", everywhere.
    func testARenameLastsIntoLaterLegs() throws {
        let stop = 6_000
        let first = add(.system, 500, 4_000)
        store.appendSpeakerSpans(meetingID: meeting.id, [.matched("Bob", 0, 5_000)])
        store.applySpeakerNames(meetingID: meeting.id, SpeakerAttribution.attribute(segments: store.segments(meetingID: meeting.id),
                                                                                    spans: store.speakerSpans(meetingID: meeting.id)))
        XCTAssertEqual(store.segments(meetingID: meeting.id).first?.speaker, "Bob")
        store.renameSpeaker(meetingID: meeting.id, from: "Bob", to: "Robert")
        XCTAssertEqual(store.speakerAliases(meetingID: meeting.id), ["bob": "Robert"])

        // Stop, Resume: the app still calls him "Bob", and his readings in the new leg are stored as read.
        store.addSegment(MeetingSegment(meetingID: meeting.id, source: .marker, startMs: stop, endMs: stop, marker: .stopped))
        store.addSegment(MeetingSegment(meetingID: meeting.id, source: .marker, startMs: stop, endMs: stop, marker: .resumed))
        store.appendSpeakerSpans(meetingID: meeting.id, [.matched("Bob", stop + 500, 12_000, leg: 2)])
        let second = add(.system, stop + 1_000, 10_000)
        // The end-of-leg pass, as `ScribeController.relabelSpeakers` runs it (also after a relaunch).
        let reopened = try Store(path: path)
        let aliases = reopened.speakerAliases(meetingID: meeting.id)
        reopened.applySpeakerNames(meetingID: meeting.id, SpeakerAttribution.attribute(
            segments: reopened.segments(meetingID: meeting.id), spans: reopened.speakerSpans(meetingID: meeting.id), aliases: aliases))
        let byID = Dictionary(uniqueKeysWithValues: reopened.segments(meetingID: meeting.id).map { ($0.id, $0) })
        XCTAssertEqual(byID[first.id]?.speaker, "Robert")
        XCTAssertEqual(byID[first.id]?.speakerOrigin, .user)
        XCTAssertEqual(byID[second.id]?.speaker, "Robert", "the same speaker again keeps the new name")
        XCTAssertEqual(byID[second.id]?.speakerOrigin, .ax)
        // One person in the chips, with all of his talk time.
        let speakers = SpeakerAttribution.speakers(segments: reopened.segments(meetingID: meeting.id),
                                                   talkMs: reopened.speakerTalkTime(meetingID: meeting.id))
        XCTAssertEqual(speakers.map(\.name), ["Robert"])
        XCTAssertEqual(speakers.first?.talkMs, 5_000 + 5_500)

        // Renaming again follows the chain.
        reopened.renameSpeaker(meetingID: meeting.id, from: "Robert", to: "Rob")
        XCTAssertEqual(reopened.speakerAliases(meetingID: meeting.id), ["bob": "Rob", "robert": "Rob"])
        reopened.deleteMeeting(id: meeting.id)
        XCTAssertEqual(try reopened.db.scalar("SELECT COUNT(*) FROM meeting_speaker_aliases").int, 0, "they go with the meeting")
    }

    func testNamesThatFailToSaveChangeNothing() throws {
        let a = add(.system, 0, 1_000)
        let b = add(.system, 1_000, 2_000)
        // The second write fails (a full disk, say), so the first is rolled back with it.
        try store.db.exec("""
            CREATE TRIGGER fail_second BEFORE UPDATE OF speaker ON meeting_segments
            WHEN (SELECT COUNT(*) FROM meeting_segments WHERE speaker_origin = 'ax') > 0
            BEGIN SELECT RAISE(ABORT, 'disk full'); END
            """)
        let revision = store.meetingsRevision
        XCTAssertEqual(store.applySpeakerNames(meetingID: meeting.id, [a.id: "Ada", b.id: "Bob"]), 0)
        XCTAssertEqual(store.meetingsRevision, revision, "nobody is told about a change that wasn't kept")
        XCTAssertEqual(store.segments(meetingID: meeting.id).map(\.speaker), [nil, nil])
    }

    func testTheUserCanNameOrUnnameLines() {
        let a = add(.system, 0, 1_000, speaker: "Ada", origin: .ax)
        let b = add(.system, 1_000, 2_000)
        store.setSpeaker(segmentIDs: [a.id], name: nil)
        store.setSpeaker(segmentIDs: [b.id], name: "Grace Hopper")
        let byID = Dictionary(uniqueKeysWithValues: store.segments(meetingID: meeting.id).map { ($0.id, $0) })
        XCTAssertNil(byID[a.id]?.speaker)
        XCTAssertEqual(byID[a.id]?.speakerOrigin, .user, "\"Not Ada\" stays Others")
        XCTAssertEqual(byID[b.id]?.speaker, "Grace Hopper")
        store.applySpeakerNames(meetingID: meeting.id, [a.id: "Ada", b.id: "Bob"])
        XCTAssertEqual(store.segments(meetingID: meeting.id).map(\.speaker), [nil, "Grace Hopper"])
    }

    func testTheDemoMeetingIsNamedFromItsReadings() {
        store.seedDemoMeetings()
        let others = store.segments(meetingID: "demo-sync").filter { $0.source == .system }
        XCTAssertEqual(others.map(\.speaker), ["Mei Chen", "Mei Chen", "Joaquin Ortiz", "Mei Chen", "Priya Raman", nil],
                       "the resumed leg had no readings")
        XCTAssertTrue(others.dropLast().allSatisfy { $0.speakerOrigin == .ax })
        XCTAssertTrue(store.segments(meetingID: "demo-sync").filter { $0.source == .mic }.allSatisfy { $0.speaker == nil })
    }

    func testNamesReachSummariesAndAsk() {
        add(.system, 0, 1_000, speaker: "Ada Lovelace", origin: .ax)
        add(.system, 1_000, 2_000)
        add(.mic, 2_000, 3_000)
        let segments = store.segments(meetingID: meeting.id)
        XCTAssertEqual(MeetingSummarizer.turns(from: segments, userLabel: "Sam").map(\.speaker), ["Ada Lovelace", "Others", "Sam"])
        XCTAssertEqual(MeetingAsk.transcriptLines(segments).map { $0.components(separatedBy: ":")[0] }, ["Ada Lovelace", "Others", "You"])
        let system = MeetingAsk.messages(question: "Who spoke?", history: [], sources: [], userName: nil).first?.content ?? ""
        XCTAssertTrue(system.contains("any other transcript label is the name of the person speaking"))
    }

    func testANamedLineIsStoredWithItsOrigin() {
        let s = add(.system, 0, 1_000, speaker: "Ada", origin: .ax)
        XCTAssertEqual(store.segments(meetingID: meeting.id).first?.speakerOrigin, .ax)
        XCTAssertEqual(s.speakerOrigin, .ax)
        let plain = add(.system, 1_000, 2_000, origin: .ax)
        XCTAssertNil(store.segments(meetingID: meeting.id).first { $0.id == plain.id }?.speakerOrigin, "no name, no origin")
    }
}
