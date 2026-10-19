import XCTest
@testable import ShoutKit

/// Greptile round, group E: which Meet window may name the recorded call, and what a Zoom box reads as.
final class Review4GEMeetWindowTests: XCTestCase {
    private struct W: Equatable { let title: String; var minimized = false }

    private func eligible(_ windows: [W], code: String?) -> [String] {
        SpeakerWindows.meetWindows(windows, code: code, title: \.title).map(\.title)
    }

    func testAnotherMeetingsWindowNeverStandsInForTheRecordedOne() {
        // The recorded call's window is minimised; another meeting is on screen. Its tiles must not name the call.
        let windows = [W(title: "Meet – abc-defg-hij - Google Chrome", minimized: true),
                       W(title: "Meet - xyz-wxyz-uvw - Google Chrome")]
        XCTAssertEqual(eligible(windows, code: "abc-defg-hij"), ["Meet – abc-defg-hij - Google Chrome"])
        XCTAssertEqual(eligible(windows, code: "ABC-DEFG-HIJ"), ["Meet – abc-defg-hij - Google Chrome"], "codes compare lowercased")
        XCTAssertEqual(eligible([W(title: "Meet - xyz-wxyz-uvw - Google Chrome")], code: "abc-defg-hij"), [],
                       "only another meeting is open: nothing is read")
    }

    func testAMeetingTitledAfterItsEventIsReadOnlyWhenNoWindowHasTheCode() {
        let named = W(title: "Meet - Weekly sync - Google Chrome")
        let other = W(title: "Meet - xyz-wxyz-uvw - Google Chrome")
        let own = W(title: "Meet - abc-defg-hij - Google Chrome")
        XCTAssertEqual(eligible([other, named], code: "abc-defg-hij"), [named.title], "a code-less title may be the call")
        XCTAssertEqual(eligible([named, own, other], code: "abc-defg-hij"), [own.title], "the window with the code wins alone")
    }

    func testEveryMeetWindowWhenTheCodeIsUnknown() {
        let windows = [W(title: "Meet - Weekly sync"), W(title: "Meet - xyz-wxyz-uvw")]
        XCTAssertEqual(eligible(windows, code: nil), windows.map(\.title))
    }
}

final class Review4GEZoomBoxTests: XCTestCase {
    private let classes = SpeakerClassNames.default

    func testABoxReadsAsAWholeTile() {
        XCTAssertEqual(ZoomSpeakerText.tile(description: "Grace Hopper, Active speaker, Computer audio unmuted"),
                       SpeakerTile(name: "Grace Hopper", isLit: true))
        XCTAssertEqual(ZoomSpeakerText.tile(description: "Sam Park (Me), Computer audio muted"),
                       SpeakerTile(name: "Sam Park", isSelf: true, isMuted: true))
        XCTAssertNil(ZoomSpeakerText.tile(description: "Ada Lovelace, Video on"), "not a participant box")
    }

    func testABoxHandedToSomeoneElseNamesTheNewPerson() {
        // Discovery saw Ada in this box; Zoom then gave the box to Grace, who is speaking.
        let before = ZoomSpeakerText.tile(description: "Ada Lovelace, Computer audio unmuted")
        let after = ZoomSpeakerText.tile(description: "Grace Hopper, Active speaker, Computer audio unmuted")
        XCTAssertEqual(before?.name, "Ada Lovelace")
        let reading = SpeakerReading(source: .zoomMain, tiles: [after].compactMap { $0 })
        let change = SpeakerChange(reading: reading, platform: .zoom, selfNames: [], timestamp: 1)
        XCTAssertEqual(change.speakerName, "Grace Hopper")
        XCTAssertEqual(change.attributionState, .matched)
    }

    func testABoxThatBecomesTheUsersOwnNamesNobody() {
        let own = ZoomSpeakerText.tile(description: "Ada Lovelace (You), Active speaker, Computer audio unmuted")
        XCTAssertEqual(own, SpeakerTile(name: "Ada Lovelace", isSelf: true, isLit: true))
        let change = SpeakerChange(reading: SpeakerReading(source: .zoomMain, tiles: [own].compactMap { $0 }),
                                   platform: .zoom, selfNames: [], timestamp: 1)
        XCTAssertEqual(change.speakingNames, [], "the user is never one of the speakers")
        XCTAssertEqual(change.selfName, "Ada Lovelace")
    }

    func testThePureTileRuleReadsZoomTheSameWay() {
        for d in ["Grace Hopper, Active speaker, Computer audio unmuted", "Sam Park (Me), Computer audio muted",
                  "Bob,Computer audio muted"] {
            XCTAssertEqual(SpeakerTileRules.tile(from: AXNodeSnapshot(role: "AXGroup", description: d), platform: .zoom, classes: classes),
                           ZoomSpeakerText.tile(description: d), d)
        }
    }
}
