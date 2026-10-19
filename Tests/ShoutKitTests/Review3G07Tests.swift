import XCTest
@testable import ShoutKit
import ShoutLLM

/// A read that gains one field but misses another (a URL without the code) still names the same meeting.
final class Review3G07DetectionTests: XCTestCase {
    typealias T = CallSessionTracker
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private let coded = DetectedCall(pid: 500, bundleID: "com.google.Chrome", appName: "Google Chrome", platform: .teams,
                                     meetingCode: "19:meeting_x@thread.v2", qualifiesForAutoStart: true)
    private var urlOnly: DetectedCall {
        var c = coded
        c.meetingCode = nil
        c.url = "https://teams.microsoft.com/light-meetings/launch"
        return c
    }

    func testTheRecordedMeetingKeepsItsCodeWhenAReadOnlyAddsTheURL() {
        var tr = T()
        _ = tr.recordingStarted(call: coded, at: at(0))
        XCTAssertEqual(tr.observe([urlOnly], at: at(3)), [])
        XCTAssertEqual(tr.boundCall?.meetingCode, coded.meetingCode)
        XCTAssertEqual(tr.boundCall?.url, urlOnly.url)
        // Another meeting in the same app is still not the recorded one.
        var other = coded
        other.meetingCode = "19:meeting_y@thread.v2"
        _ = tr.observe([other], at: at(6))
        XCTAssertEqual(tr.boundCall?.meetingCode, coded.meetingCode)
    }

    func testAPromptUpdateKeepsWhatTheCardAlreadyKnew() {
        var tr = T()
        var first = coded
        first.qualifiesForAutoStart = false
        XCTAssertEqual(tr.observe([first], at: at(0)), [.prompt(first)])
        var expected = first
        expected.url = urlOnly.url
        expected.qualifiesForAutoStart = true
        XCTAssertEqual(tr.observe([urlOnly], at: at(3)), [.prompt(expected)])
        XCTAssertEqual(tr.promptedCall, expected)
    }
}

/// Ask keeps meetings that fit and never leaves every meeting out of a room that could hold one.
final class Review3G07AskTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_760_788_800) // 2025-10-18 12:00 UTC

    func testDatesInThePromptAreEnglish() {
        let msgs = MeetingAsk.messages(question: "Anything new?", history: [], sources: [], userName: nil, now: day)
        // English names in any time zone (Friday to Sunday) and whatever the Mac's language.
        XCTAssertNotNil(msgs[0].content.firstMatch(of: #/Today is (Friday|Saturday|Sunday), October 1[789], 2025\./#), msgs[0].content)
        XCTAssertEqual(msgs[1].content, "Meeting material:\n\n(no meetings found)")
    }

    func testSmallMeetingsThatFitWholeAreKept() {
        let sources = (0..<3).map { AskSource(id: "m\($0)", title: "Sync \($0)", date: day, summary: "All good.") }
        let material = MeetingAsk.fitMaterial(sources, keywords: [], budget: 300, day: DateFormatter())
        for i in 0..<3 { XCTAssertTrue(material.contains("### Sync \(i) ("), material) }
    }

    func testTooManyMeetingsForTheRoomStillGivesTheFirstOne() {
        let long = String(repeating: "We went through the dashboard numbers again. ", count: 40)
        let sources = (0..<6).map { AskSource(id: "m\($0)", title: "Review \($0)", date: day, summary: long, transcript: long) }
        let material = MeetingAsk.fitMaterial(sources, keywords: ["dashboard"], budget: 400, day: DateFormatter())
        XCTAssertTrue(material.contains("### Review 0 ("))
        XCTAssertFalse(material.contains("### Review 1 ("))
        XCTAssertLessThanOrEqual(MeetingSummarizer.estimateTokens(material), 410)
    }

    func testALongTitleLeavesNoBareEllipsisSections() {
        let title = String(repeating: "Quarterly planning ", count: 25)
        let source = AskSource(id: "m", title: title, date: day, summary: String(repeating: "Summary sentence. ", count: 50),
                               notes: String(repeating: "note ", count: 100))
        let material = MeetingAsk.fitMaterial([source], keywords: [], budget: 140, day: DateFormatter())
        XCTAssertFalse(material.contains("Summary:\n…"), material)
        XCTAssertFalse(material.contains("User's notes:\n…"), material)
    }

    func testNoRoomForAnyMeetingSaysSo() {
        let source = AskSource(id: "m", title: "Infra sync", date: day, summary: "Summary.", transcript: "You: hello")
        let question = String(repeating: "Please tell me everything about the upgrade plan. ", count: 700)
        let msgs = MeetingAsk.messages(question: question, history: [], sources: [source], userName: nil, contextTokens: 8192)
        XCTAssertTrue(msgs[1].content.contains("don't fit"), msgs[1].content)
    }
}
