import XCTest
@testable import ShoutKit

final class SpeakerAttributionTests: XCTestCase {
    private func line(_ id: String, _ start: Int, _ end: Int, _ source: MeetingSource = .system,
                      origin: SpeakerOrigin? = nil, speaker: String? = nil, latched: Bool = false) -> MeetingSegment {
        MeetingSegment(id: id, meetingID: "m", source: source, speaker: speaker, startMs: start, endMs: end, text: "words",
                       latched: latched, speakerOrigin: origin)
    }

    private func silence(_ start: Int, _ end: Int) -> SpeakerSpan {
        SpeakerSpan(startMs: start, endMs: end, platform: .zoom, state: .unknown, speakingNames: [])
    }

    private func overlap(_ start: Int, _ end: Int) -> SpeakerSpan {
        SpeakerSpan(startMs: start, endMs: end, platform: .zoom, state: .ambiguous, speakingNames: ["Ada", "Bob"])
    }

    /// The name given to line `id` ("Others" when none).
    private func name(_ id: String, _ segments: [MeetingSegment], _ spans: [SpeakerSpan], selfNames: [String] = [],
                      rules: SpeakerAttribution.Rules = .default) -> String {
        let result = SpeakerAttribution.attribute(segments: segments, spans: spans, selfNames: selfNames, rules: rules)
        XCTAssertTrue(result.keys.contains(id), "line \(id) was considered")
        return (result[id] ?? nil) ?? "Others"
    }

    // MARK: Basics

    func testOneSpeakerNamesTheLine() {
        XCTAssertEqual(name("a", [line("a", 1_000, 5_000)], [.matched("Ada", 0, 10_000)]), "Ada")
    }

    func testOnlyOthersLinesAreConsidered() {
        let segments = [
            line("mic", 1_000, 5_000, .mic),
            line("user", 1_000, 5_000, origin: .user, speaker: "Grace"),
            line("hidden", 1_000, 5_000, latched: true),
            MeetingSegment(id: "marker", meetingID: "m", source: .marker, startMs: 1_000, endMs: 1_000, marker: .dictated),
            line("ax", 1_000, 5_000, origin: .ax, speaker: "Old name"),
        ]
        let result = SpeakerAttribution.attribute(segments: segments, spans: [.matched("Ada", 0, 10_000)])
        XCTAssertEqual(Set(result.keys), ["ax"], "the microphone is You; the user's labels, hidden lines and markers stay")
        XCTAssertEqual(result["ax"], .some("Ada"), "a name read earlier is worked out again")
    }

    func testNoReadingsMeansOthers() {
        XCTAssertEqual(name("a", [line("a", 1_000, 5_000)], []), "Others")
        let unreadable = SpeakerSpan(startMs: 0, endMs: 10_000, platform: .meet, state: .unknown, reason: .readFailed)
        XCTAssertEqual(name("a", [line("a", 1_000, 5_000)], [unreadable]), "Others")
        XCTAssertEqual(name("a", [line("a", 1_000, 5_000)], [silence(0, 10_000)]), "Others")
    }

    // MARK: Votes

    func testANameSticksAfterThreeConsecutiveVotes() {
        // A short line gets three samples (0, 300, 600 ms), all looked up 300 ms later.
        let short = [line("a", 0, 600)]
        XCTAssertEqual(name("a", short, [.matched("Ada", 0, 2_000)]), "Ada")
        XCTAssertEqual(name("a", short, [.matched("Ada", 0, 700), .matched("Bob", 700, 2_000)]), "Others",
                       "two votes for Ada, one for Bob: nothing sticks")
    }

    func testAShortLineFullyShownIsNamed() {
        XCTAssertEqual(name("yeah", [line("yeah", 1_000, 1_400)], [.matched("Ada", 0, 5_000)]), "Ada")
    }

    func testAHandOffMidLineSwitchesAfterFiveVotes() {
        // Ada for the first three samples (named), then Bob for the rest: the first change of name is never held back.
        let spans: [SpeakerSpan] = [.matched("Ada", 0, 1_000), .matched("Bob", 1_000, 10_000)]
        XCTAssertEqual(name("a", [line("a", 0, 6_000)], spans), "Bob")
    }

    func testBackAndForthWithinTheCooldownStaysOthers() {
        // Ada (named) → Bob (switched) → Ada again within 30 s: the switch back is blocked, so the line ends as
        // Bob, who has a minority of its votes.
        let spans: [SpeakerSpan] = [.matched("Ada", 0, 1_500), .matched("Bob", 1_500, 3_500), .matched("Ada", 3_500, 6_000)]
        XCTAssertEqual(name("a", [line("a", 0, 6_000)], spans), "Others")
    }

    func testASecondSwitchIsAllowedAfterTheCooldown() {
        let spans: [SpeakerSpan] = [.matched("Ada", 0, 2_000), .matched("Bob", 2_000, 35_000), .matched("Ada", 35_000, 70_000)]
        XCTAssertEqual(name("a", [line("a", 0, 70_000)], spans), "Ada")
        var quick = SpeakerAttribution.Rules()
        quick.switchCooldownMs = 120_000
        XCTAssertEqual(name("a", [line("a", 0, 70_000)], spans, rules: quick), "Others", "held as Bob, who has fewer votes")
    }

    func testOverlappingSpeakersStayOthers() {
        XCTAssertEqual(name("a", [line("a", 0, 4_000)], [overlap(0, 10_000)]), "Others")
        // Ada alone for the first second, then both: more overlap than Ada.
        XCTAssertEqual(name("a", [line("a", 0, 4_000)], [.matched("Ada", 0, 1_500), overlap(1_500, 6_000)]), "Others")
        // A little overlap inside a line that is clearly Ada's.
        XCTAssertEqual(name("a", [line("a", 0, 4_000)], [.matched("Ada", 0, 3_000), overlap(3_000, 3_600), .matched("Ada", 3_600, 6_000)]),
                       "Ada")
    }

    func testTwoSpeakersInTurnEachGetTheirLine() {
        let spans: [SpeakerSpan] = [.matched("Ada", 0, 4_800), silence(4_800, 5_200), .matched("Bob", 5_200, 9_000)]
        let lines = [line("a", 200, 4_500), line("b", 5_000, 8_500)]
        XCTAssertEqual(name("a", lines, spans), "Ada")
        XCTAssertEqual(name("b", lines, spans), "Bob")
    }

    func testALineMostlyWithoutReadingsStaysOthers() {
        // Three votes for Ada at the start of a ten-second line, then nothing readable.
        let spans: [SpeakerSpan] = [.matched("Ada", 0, 900), silence(900, 12_000)]
        XCTAssertEqual(name("a", [line("a", 0, 10_000)], spans), "Others")
        // The indicator flickering with the voice (lit about half the time) is enough.
        let flicker = stride(from: 0, to: 10_000, by: 1_000).flatMap { s in [SpeakerSpan.matched("Ada", s, s + 500), silence(s + 500, s + 1_000)] }
        XCTAssertEqual(name("a", [line("a", 0, 10_000)], flicker), "Ada")
    }

    // MARK: Time

    func testReadingsExpireUnlessConfirmed() {
        // The poller last confirmed Ada at 2 s, then went quiet (a hung app): its reading counts for 1.5 s more.
        let spans: [SpeakerSpan] = [.matched("Ada", 0, 2_000)]
        let lines = [line("near", 2_000, 2_900), line("far", 5_000, 6_000)]
        XCTAssertEqual(name("near", lines, spans), "Ada")
        XCTAssertEqual(name("far", lines, spans), "Others")
        var strict = SpeakerAttribution.Rules()
        strict.freshnessMs = 0
        XCTAssertEqual(name("near", lines, spans, rules: strict), "Others")
    }

    func testTheIndicatorLagShiftsTheLookup() {
        // Ada speaks 1.0–2.0 s; the app lights her tile 0.8 s late and Bob's until then.
        let spans: [SpeakerSpan] = [.matched("Bob", 0, 1_800), .matched("Ada", 1_800, 2_800), silence(2_800, 9_000)]
        var noLag = SpeakerAttribution.Rules()
        noLag.indicatorLagMs = 0
        XCTAssertEqual(name("a", [line("a", 1_000, 2_000)], spans, rules: noLag), "Bob")
        var lag = SpeakerAttribution.Rules()
        lag.indicatorLagMs = 800
        XCTAssertEqual(name("a", [line("a", 1_000, 2_000)], spans, rules: lag), "Ada")
    }

    func testReadingsDoNotCarryOverAStop() {
        let stop = MeetingSegment(meetingID: "m", source: .marker, startMs: 10_000, endMs: 10_000, marker: .stopped)
        let resume = MeetingSegment(meetingID: "m", source: .marker, startMs: 10_000, endMs: 10_000, marker: .resumed)
        let segments = [line("before", 8_500, 9_800), stop, resume, line("after", 10_100, 11_000)]
        let spans: [SpeakerSpan] = [.matched("Ada", 8_000, 10_000)]
        XCTAssertEqual(name("before", segments, spans), "Ada")
        XCTAssertEqual(name("after", segments, spans), "Others", "the next leg starts with nothing known")
        let nextLeg: [SpeakerSpan] = spans + [.matched("Bob", 10_000, 12_000, leg: 1)]
        XCTAssertEqual(name("after", segments, nextLeg), "Bob")
        // A short line just before the stop: its last lookup (300 ms later) lands on the stop, where the next leg's
        // first reading starts. It reads its own leg.
        let late = [line("late", 9_400, 9_800), stop, resume, line("after", 10_000, 10_600)]
        XCTAssertEqual(name("late", late, nextLeg), "Ada")
        XCTAssertEqual(name("after", late, nextLeg), "Bob", "a line starting at the stop is in the next leg")
    }

    // MARK: Names

    func testTheUsersOwnNameNeverNamesALine() {
        XCTAssertEqual(name("a", [line("a", 0, 3_000)], [.matched("Sam Park", 0, 5_000)], selfNames: ["sam park"]), "Others")
    }

    func testASelfTileLitBesideAnotherSpeakerNamesTheOther() {
        // From the poller's changes: the user's tile and Ada's both lit, then Ada alone.
        var timeline = SpeakerTimeline(leg: 0)
        let both = SpeakerReading(source: .meetTab, tiles: [SpeakerTile(name: "You", isSelf: true, isLit: true),
                                                            SpeakerTile(name: "Ada", isLit: true)])
        let ada = SpeakerReading(source: .meetTab, tiles: [SpeakerTile(name: "You", isSelf: true), SpeakerTile(name: "Ada", isLit: true)])
        timeline.record(SpeakerChange(reading: both, platform: .meet, selfNames: [], timestamp: 0), atMs: 0)
        timeline.record(SpeakerChange(reading: ada, platform: .meet, selfNames: [], timestamp: 0), atMs: 2_000)
        timeline.record(SpeakerChange(reading: ada, platform: .meet, selfNames: [], timestamp: 0), atMs: 5_000)
        XCTAssertEqual(timeline.spans.count, 1, "the user's tile doesn't change who is speaking for Others")
        XCTAssertEqual(name("a", [line("a", 0, 4_000)], timeline.spans), "Ada")
    }

    func testRenamesApplyToEveryReading() {
        // Readings made after the rename still say "Bob"; the meeting's alias names them "Robert".
        let spans: [SpeakerSpan] = [.matched("Bob", 0, 5_000), .matched("Ada", 5_000, 9_000)]
        let lines = [line("a", 500, 4_000), line("b", 5_500, 8_500)]
        let result = SpeakerAttribution.attribute(segments: lines, spans: spans, aliases: ["bob": "Robert"])
        XCTAssertEqual(result["a"], .some("Robert"))
        XCTAssertEqual(result["b"], .some("Ada"))
    }

    func testARenameThatMergesTwoPeopleMakesOneSpeaker() {
        // Bob and Ada lit together, then the user says Bob is Ada (the app showed one person twice).
        let both = SpeakerSpan(startMs: 0, endMs: 5_000, platform: .meet, state: .ambiguous, speakingNames: ["Bob", "Ada"])
        let merged = both.renaming(["bob": "Ada"])
        XCTAssertEqual(merged.state, .matched)
        XCTAssertEqual(merged.speakerName, "Ada")
        XCTAssertEqual(merged.speakingNames, ["Ada"])
        XCTAssertEqual(name("a", [line("a", 500, 4_000)], [both], rules: .default), "Others")
        XCTAssertEqual(SpeakerAttribution.attribute(segments: [line("a", 500, 4_000)], spans: [both], aliases: ["bob": "Ada"])["a"],
                       .some("Ada"))
        let change = SpeakerChange(timestamp: 0, platform: .meet, speakingNames: ["Bob", "Ada"], attributionState: .ambiguous,
                                   source: .meetTab).renaming(["bob": "Ada"])
        XCTAssertEqual(change.attributionState, .matched)
        XCTAssertEqual(change.speakerName, "Ada")
        let silence = SpeakerSpan(startMs: 0, endMs: 1, platform: .meet, state: .unknown, speakingNames: []).renaming(["bob": "Ada"])
        XCTAssertEqual(silence.state, .unknown)
        let unreadable = SpeakerSpan(startMs: 0, endMs: 1, platform: .meet, state: .unknown, reason: .readFailed).renaming(["bob": "Ada"])
        XCTAssertNil(unreadable.speakingNames)
        XCTAssertEqual(unreadable.state, .unknown)
    }

    func testTheLongestShownSpellingIsUsed() {
        let spans: [SpeakerSpan] = [.matched("Ada Lovelace (Guest)", 0, 1_000), .matched("Ada Lovelace", 1_000, 9_000)]
        XCTAssertEqual(name("a", [line("a", 0, 900)], spans), "Ada Lovelace")
    }

    // MARK: Timeline

    func testTheTimelineMergesConfirmationsAndSplitsOnChanges() {
        func change(_ names: [String]) -> SpeakerChange {
            SpeakerChange(reading: SpeakerReading(source: .zoomMain, tiles: names.map { SpeakerTile(name: $0, isLit: true) }),
                          platform: .zoom, selfNames: [], timestamp: 0)
        }
        var t = SpeakerTimeline(leg: 2)
        t.record(change(["Ada"]), atMs: 1_000)
        t.record(change(["Ada"]), atMs: 2_000)
        XCTAssertEqual(t.spans.map { [$0.startMs, $0.endMs] }, [[1_000, 2_000]])
        XCTAssertEqual(t.takeClosed(), [], "the open span isn't stored yet")
        t.record(change(["Ada", "Bob"]), atMs: 3_000)
        XCTAssertEqual(t.spans.map { [$0.startMs, $0.endMs] }, [[1_000, 3_000], [3_000, 3_000]])
        XCTAssertEqual(t.spans.map(\.state), [.matched, .ambiguous])
        XCTAssertEqual(t.takeClosed().map(\.speakerName), ["Ada"])
        XCTAssertEqual(t.takeClosed(), [])
        t.record(change(["Ada", "Bob"]), atMs: 2_500)
        XCTAssertEqual(t.spans.last?.endMs, 3_000, "time never runs backwards")
        t.close(atMs: 4_000)
        XCTAssertFalse(t.isOpen)
        XCTAssertEqual(t.unstored.map(\.endMs), [4_000])
        XCTAssertEqual(t.takeClosed().map { $0.leg }, [2])
        t.rename(key: "ada", to: "Ada Lovelace")
        XCTAssertEqual(t.spans.first?.speakerName, "Ada Lovelace")
        XCTAssertEqual(t.spans.last?.speakingNames, ["Ada Lovelace", "Bob"])
    }

    // MARK: Speakers

    func testSpeakersInOrderOfTheirFirstLine() {
        let segments = [
            line("1", 5_000, 6_000, speaker: "Bob"), line("2", 1_000, 3_000, speaker: "Ada"),
            line("3", 7_000, 9_000, speaker: "ada"), line("4", 9_000, 9_500), line("5", 9_000, 9_500, .mic),
        ]
        let speakers = SpeakerAttribution.speakers(segments: segments, talkMs: ["Bob": 4_000, "Grace": 2_000, "Mute": 0])
        XCTAssertEqual(speakers.map(\.name), ["Ada", "Bob", "Grace"])
        XCTAssertEqual(speakers.map(\.lines), [2, 1, 0])
        XCTAssertEqual(speakers.map(\.talkMs), [4_000, 4_000, 2_000], "the app's talk time when known, else the lines'")
    }

    func testAPersonReadSeveralWaysHasTheLongestShownSpelling() {
        // Without lines of their own, the chip's name comes from the readings: the same one on every run.
        let speakers = SpeakerAttribution.speakers(segments: [], talkMs: ["ada": 1_000, "Ada": 3_000, "ADA": 500])
        XCTAssertEqual(speakers.map(\.name), ["Ada"])
        XCTAssertEqual(speakers.map(\.talkMs), [4_500])
    }
}
