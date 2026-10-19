import XCTest
@testable import ShoutKit

final class SpeakerNamesTests: XCTestCase {
    func testNameFilterRejectsStatusTimersOverflowAndInitials() {
        for bad in ["+3 more", "12 others", "4 participants", "+1 other", "12:04", "1:02:33", "AL", "JD", "A", " ",
                    "Muted", "Computer audio unmuted", "Video off", "Presenting", "Camera", "Microphone", "Talking", "42"] {
            XCTAssertFalse(SpeakerNames.isPlausible(bad), bad)
        }
        for good in ["Ada Lovelace", "Bo", "Al", "Zoë Ångström", "Ada (Guest)", "李雷", "O'Brien", "Agent 47"] {
            XCTAssertTrue(SpeakerNames.isPlausible(good), good)
        }
    }

    func testKeyIgnoresCaseSpacingNormalisationAndATrailingParenthetical() {
        XCTAssertEqual(SpeakerNames.key("Ada Lovelace (Guest)"), "ada lovelace")
        XCTAssertEqual(SpeakerNames.key("  ada\tLOVELACE "), "ada lovelace")
        XCTAssertEqual(SpeakerNames.key("Zoe\u{0308}"), SpeakerNames.key("Zoë"))
        XCTAssertEqual(SpeakerNames.key("(Guest)"), "(guest)", "a name that is only a parenthetical keeps it")
        XCTAssertNotEqual(SpeakerNames.key("Ada (Lovelace) King"), SpeakerNames.key("Ada King"), "only a trailing one")
    }

    func testCleanCollapsesWhitespaceAndCapsLength() {
        XCTAssertEqual(SpeakerNames.clean(" Ada\n  Lovelace\t"), "Ada Lovelace")
        XCTAssertNil(SpeakerNames.clean(" \n "))
        XCTAssertEqual(SpeakerNames.clean(String(repeating: "a", count: 300))?.count, SpeakerNames.maxLength)
    }

    func testSelfLabels() {
        XCTAssertEqual(SpeakerNames.selfName(fromLabel: "You"), "You")
        XCTAssertEqual(SpeakerNames.selfName(fromLabel: "me"), "me")
        XCTAssertEqual(SpeakerNames.selfName(fromLabel: "Ada Lovelace (You)"), "Ada Lovelace")
        XCTAssertEqual(SpeakerNames.selfName(fromLabel: "Ada Lovelace (me)"), "Ada Lovelace")
        XCTAssertNil(SpeakerNames.selfName(fromLabel: "Ada Lovelace"))
        XCTAssertNil(SpeakerNames.selfName(fromLabel: "Young"))
    }
}

final class SpeakerTargetTests: XCTestCase {
    private func call(_ platform: MeetingPlatform, _ bundleID: String, code: String? = nil) -> DetectedCall {
        DetectedCall(pid: 42, bundleID: bundleID, appName: "App", platform: platform, meetingCode: code, qualifiesForAutoStart: true)
    }

    func testPlatformsAndWhetherTheTreeIsWoken() {
        let zoom = SpeakerTarget(call: call(.zoom, "us.zoom.xos"))
        XCTAssertEqual(zoom?.platform, .zoom)
        XCTAssertEqual(zoom?.wakesTree, false)
        let meet = SpeakerTarget(call: call(.meet, "com.google.Chrome", code: "abc-defg-hij"))
        XCTAssertEqual(meet?.platform, .meet)
        XCTAssertEqual(meet?.wakesTree, true)
        XCTAssertEqual(meet?.meetingCode, "abc-defg-hij")
        XCTAssertEqual(SpeakerTarget(call: call(.meet, "com.google.Chrome.canary"))?.wakesTree, true)
        XCTAssertEqual(SpeakerTarget(call: call(.meet, "company.thebrowser.Browser"))?.wakesTree, true, "Arc")
        XCTAssertEqual(SpeakerTarget(call: call(.meet, "com.microsoft.edgemac"))?.platform, .meet)
        let safari = SpeakerTarget(call: call(.meet, "com.apple.Safari"))
        XCTAssertEqual(safari?.platform, .meet)
        XCTAssertEqual(safari?.wakesTree, false, "WebKit isn't woken")
        XCTAssertEqual(SpeakerTarget(call: call(.teams, "com.microsoft.teams2"))?.wakesTree, true)
        XCTAssertEqual(SpeakerTarget(call: call(.teams, "com.brave.Browser"))?.platform, .teams, "Teams on the web")
        XCTAssertEqual(SpeakerTarget(call: call(.slack, "com.tinyspeck.slackmacgap"))?.platform, .slack)
        XCTAssertEqual(SpeakerTarget(call: call(.teams, "com.microsoft.edgemac"))?.inBrowser, true)
        XCTAssertEqual(SpeakerTarget(call: call(.teams, "com.microsoft.teams2"))?.inBrowser, false)
    }

    func testCallsWithoutAReader() {
        XCTAssertNil(SpeakerTarget(call: call(.zoom, "com.google.Chrome")), "Zoom on the web")
        XCTAssertNil(SpeakerTarget(call: call(.slack, "com.google.Chrome")), "Slack in a browser")
        XCTAssertNil(SpeakerTarget(call: call(.teams, "company.thebrowser.Browser")), "Teams in Arc")
        XCTAssertNil(SpeakerTarget(call: call(.teams, "com.apple.Safari")))
        XCTAssertNil(SpeakerTarget(call: call(.meet, "org.mozilla.firefox")))
        XCTAssertNil(SpeakerTarget(call: call(.webex, "com.cisco.webexmeetingsapp")))
        XCTAssertNil(SpeakerTarget(call: call(.facetime, "com.apple.FaceTime")))
        XCTAssertNil(SpeakerTarget(call: call(.other, "com.google.Chrome")))
    }

    func testMeetingWindowTitles() {
        XCTAssertTrue(SpeakerWindows.isMeetingWindow(title: "Zoom Meeting", platform: .zoom))
        XCTAssertFalse(SpeakerWindows.isMeetingWindow(title: "Zoom Workplace", platform: .zoom))
        XCTAssertTrue(SpeakerWindows.isMeetingWindow(title: "Meet – abc-defg-hij - Google Chrome", platform: .meet))
        XCTAssertTrue(SpeakerWindows.isMeetingWindow(title: "Meet - abc-defg-hij", platform: .meet))
        XCTAssertTrue(SpeakerWindows.isMeetingWindow(title: "meet.google.com/abc-defg-hij", platform: .meet))
        XCTAssertFalse(SpeakerWindows.isMeetingWindow(title: "Meeting notes - Google Docs", platform: .meet))
        XCTAssertTrue(SpeakerWindows.isMeetingWindow(title: "Weekly sync | Microsoft Teams", platform: .teams))
        XCTAssertTrue(SpeakerWindows.isMeetingWindow(title: "Huddle: #eng - Acme - Slack", platform: .slack))
        XCTAssertFalse(SpeakerWindows.isMeetingWindow(title: "#eng - Acme - Slack", platform: .slack))
        XCTAssertEqual(SpeakerWindows.meetCode(inTitle: "Meet – ABC-defg-hij - Google Chrome"), "abc-defg-hij")
        XCTAssertNil(SpeakerWindows.meetCode(inTitle: "Meet - Google Chrome"))
    }
}

final class SpeakerAppTextTests: XCTestCase {
    func testZoomPersonBoxes() {
        let box = ZoomSpeakerText.box(description: "Ada Lovelace, Active speaker, Computer audio unmuted, Video on")
        XCTAssertEqual(box, .init(name: "Ada Lovelace", isSpeaking: true, isMuted: false))
        XCTAssertEqual(ZoomSpeakerText.box(description: "Bob,Computer audio muted"), .init(name: "Bob", isSpeaking: false, isMuted: true))
        XCTAssertNil(ZoomSpeakerText.box(description: "Ada Lovelace, Video on"), "not a participant box")
        XCTAssertNil(ZoomSpeakerText.box(description: "+3 more, Computer audio muted"), "overflow")
        XCTAssertTrue(ZoomSpeakerText.isBox(description: "X, COMPUTER AUDIO UNMUTED"))
        XCTAssertNil(ZoomSpeakerText.box(description: ", Active speaker, Computer audio unmuted"),
                     "an empty first field is no name, not the next field")
    }

    func testZoomTalkingLabelAndLocalMic() {
        XCTAssertEqual(ZoomSpeakerText.talkingLabel("Talking: Ada Lovelace "), "Ada Lovelace")
        XCTAssertEqual(ZoomSpeakerText.talkingLabel("Talking:Ada, Bob"), "Ada, Bob", "one label, not split")
        XCTAssertNil(ZoomSpeakerText.talkingLabel("talking: Ada"), "the prefix is case-sensitive")
        XCTAssertNil(ZoomSpeakerText.talkingLabel("Talking:  "))
        XCTAssertEqual(ZoomSpeakerText.localMicMuted(buttonLabel: "Unmute my audio"), true)
        XCTAssertEqual(ZoomSpeakerText.localMicMuted(buttonLabel: "audio, turn off, currently unmuted"), false)
        XCTAssertNil(ZoomSpeakerText.localMicMuted(buttonLabel: "Share screen"))
    }

    func testTeamsTileNamesAndBadges() {
        XCTAssertEqual(TeamsSpeakerText.tileName(description: "Ada Lovelace, Muted, Video off", kind: .video), "Ada Lovelace")
        XCTAssertEqual(TeamsSpeakerText.tileName(description: "Profile picture, Ada Lovelace, Muted", kind: .primitive), "Ada Lovelace")
        XCTAssertNil(TeamsSpeakerText.tileName(description: "Ada Lovelace", kind: .primitive), "no second field")
        XCTAssertEqual(TeamsSpeakerText.tileName(description: "Ada Lovelace Organizer, Video on", kind: .video), "Ada Lovelace")
        XCTAssertEqual(TeamsSpeakerText.stripBadges("Ada Lovelace (Guest) Presenter"), "Ada Lovelace (Guest)")
        XCTAssertNil(TeamsSpeakerText.tileName(description: "Muted, Microphone", kind: .video))
        XCTAssertEqual(TeamsSpeakerText.tileKind(classes: ["x", "vdi-dynamic-occlusion"], video: ["vdi-dynamic-occlusion"],
                                                 primitive: ["fui-Primitive"]), .video)
        XCTAssertTrue(TeamsSpeakerText.isMuted("Ada, Muted"))
        XCTAssertFalse(TeamsSpeakerText.isMuted("Ada, Unmuted"))
        XCTAssertEqual(TeamsSpeakerText.localMicMuted(buttonLabel: "Unmute mic (⌘⇧M)"), true)
        XCTAssertEqual(TeamsSpeakerText.localMicMuted(buttonLabel: "Mute mic"), false)
    }

    func testTeamsCallMonitorLabel() {
        let known = ["Ada Lovelace (Guest)", "Charles Babbage"]
        XCTAssertEqual(TeamsSpeakerText.resolveCompactLabel("You are speaking", knownNames: known), .selfSpeaking)
        XCTAssertEqual(TeamsSpeakerText.resolveCompactLabel("ada lovelace", knownNames: known), .name("Ada Lovelace (Guest)"))
        XCTAssertEqual(TeamsSpeakerText.resolveCompactLabel("Charles Babbage, Muted", knownNames: known), .name("Charles Babbage"))
        XCTAssertEqual(TeamsSpeakerText.resolveCompactLabel("Charles", knownNames: known), .unrecognized)
        XCTAssertEqual(TeamsSpeakerText.resolveCompactLabel("Weekly sync", knownNames: known), .unrecognized, "the meeting title")
        XCTAssertEqual(TeamsSpeakerText.resolveCompactLabel("Ada Lovelace", knownNames: []), .unrecognized, "only known names")
        XCTAssertEqual(TeamsSpeakerText.resolveCompactLabel("Ada Lovelace guest", knownNames: ["Ada Lovelace", "Ada Lovelace Guest"]),
                       .ambiguous)
    }

    func testSlackProfileNames() {
        XCTAssertEqual(SlackSpeakerText.profileName("View Ada Lovelace’s profile"), "Ada Lovelace")
        XCTAssertEqual(SlackSpeakerText.profileName("view ada'S PROFILE"), "ada")
        XCTAssertEqual(SlackSpeakerText.profileName(" View Zoë ʼs profile "), "Zoë")
        XCTAssertNil(SlackSpeakerText.profileName("View profile"))
        XCTAssertNil(SlackSpeakerText.profileName("Ada's profile"))
        XCTAssertNil(SlackSpeakerText.profileName("View 's profile"))
    }

    func testClassListsCanBeOverridden() {
        let defaults = SpeakerClassNames.default
        XCTAssertEqual(defaults.meetMarkers, ["kssMZb"])
        XCTAssertEqual(defaults.markers(.slack), ["p-huddle_peer_tile__overlay--active_speaker"])
        let overrides: [String: Any] = [
            "ShoutSpeakerMeetMarkerClasses": ["newMark", " "],
            "ShoutSpeakerMeetTileRootClasses": "rootA, rootB",
            "ShoutSpeakerTeamsMarkerClasses": [String](),
            "ShoutSpeakerSlackMarkerClasses": 7,
        ]
        let custom = SpeakerClassNames { overrides[$0] }
        XCTAssertEqual(custom.meetMarkers, ["newMark"])
        XCTAssertEqual(custom.meetTileRoots, ["rootA", "rootB"])
        XCTAssertEqual(custom.teamsMarkers, defaults.teamsMarkers, "an empty override keeps the default")
        XCTAssertEqual(custom.slackMarkers, defaults.slackMarkers, "so does an unreadable one")
    }
}

final class SpeakerTileTests: XCTestCase {
    private let classes = SpeakerClassNames.default
    private typealias N = AXNodeSnapshot

    private func meetTile(_ name: String, lit: Bool, mutedBadge: Bool = false) -> N {
        N(role: "AXGroup", domClasses: ["oZRSLe"], children: [
            N(role: "AXGroup", children: [N(role: "AXGroup", children: [N(role: "AXGroup", domClasses: lit ? ["kssMZb", "x"] : ["x"])])]),
            N(role: "AXStaticText", value: "12:04"),
            N(role: "AXHeading", children: [N(role: "AXStaticText", value: name)]),
        ] + (mutedBadge ? [N(role: "AXImage", description: "Microphone muted")] : []))
    }

    func testMeetTiles() {
        XCTAssertTrue(SpeakerTileRules.isTileRoot(meetTile("Ada", lit: false), platform: .meet, classes: classes))
        XCTAssertFalse(SpeakerTileRules.isTileRoot(N(role: "AXGroup", domClasses: ["other"]), platform: .meet, classes: classes))
        XCTAssertEqual(SpeakerTileRules.tile(from: meetTile("Ada Lovelace", lit: true), platform: .meet, classes: classes),
                       SpeakerTile(name: "Ada Lovelace", isLit: true))
        XCTAssertEqual(SpeakerTileRules.tile(from: meetTile("Ada Lovelace", lit: false, mutedBadge: true), platform: .meet,
                                             classes: classes),
                       SpeakerTile(name: "Ada Lovelace", isMuted: true, isLit: false))
        XCTAssertEqual(SpeakerTileRules.tile(from: meetTile("You", lit: true), platform: .meet, classes: classes),
                       SpeakerTile(name: "You", isSelf: true, isLit: true))
        XCTAssertEqual(SpeakerTileRules.tile(from: meetTile("Mutedson  (You)", lit: false), platform: .meet, classes: classes),
                       SpeakerTile(name: "Mutedson", isSelf: true), "the name's own text is no mute badge")
    }

    func testTheMarkerIsOnlyLookedForNearTheTop() {
        var deep = N(role: "AXGroup", domClasses: ["kssMZb"])
        for _ in 0..<SpeakerTileRules.markerDepth { deep = N(role: "AXGroup", children: [deep]) }
        XCTAssertFalse(SpeakerTileRules.isLit(N(role: "AXGroup", domClasses: ["oZRSLe"], children: [deep]), markers: ["kssMZb"]))
        let wide = N(role: "AXGroup", children: Array(repeating: N(role: "AXGroup"), count: SpeakerTileRules.markerNodes)
                     + [N(role: "AXGroup", domClasses: ["kssMZb"])])
        XCTAssertFalse(SpeakerTileRules.isLit(wide, markers: ["kssMZb"]), "past the node budget")
    }

    func testSlackAndTeamsTiles() {
        let slack = N(role: "AXGroup", domClasses: ["p-huddle_peer_tile"], children: [
            N(role: "AXButton", description: "View Ada Lovelace’s profile"),
            N(role: "AXGroup", domClasses: ["p-huddle_peer_tile__overlay--active_speaker"]),
        ])
        XCTAssertTrue(SpeakerTileRules.isTileRoot(slack, platform: .slack, classes: classes))
        XCTAssertEqual(SpeakerTileRules.tile(from: slack, platform: .slack, classes: classes), SpeakerTile(name: "Ada Lovelace", isLit: true))

        let teams = N(role: "AXGroup", description: "Charles Babbage, Muted, Video off", domClasses: ["vdi-dynamic-occlusion"],
                      children: [N(role: "AXGroup", domClasses: ["vdi-frame-occlusion"])])
        XCTAssertTrue(SpeakerTileRules.isTileRoot(teams, platform: .teams, classes: classes))
        XCTAssertEqual(SpeakerTileRules.tile(from: teams, platform: .teams, classes: classes),
                       SpeakerTile(name: "Charles Babbage", isMuted: true, isLit: true))
        let button = N(role: "AXButton", description: "Chat", domClasses: ["fui-Primitive"])
        XCTAssertFalse(SpeakerTileRules.isTileRoot(button, platform: .teams, classes: classes), "no name field")
    }

    func testZoomBoxes() {
        let box = N(role: "AXGroup", description: "Ada Lovelace, Active speaker, Computer audio unmuted")
        XCTAssertTrue(SpeakerTileRules.isTileRoot(box, platform: .zoom, classes: classes))
        XCTAssertEqual(SpeakerTileRules.tile(from: box, platform: .zoom, classes: classes), SpeakerTile(name: "Ada Lovelace", isLit: true))
        let own = N(role: "AXGroup", description: "Sam Park (Me), Computer audio muted")
        XCTAssertEqual(SpeakerTileRules.tile(from: own, platform: .zoom, classes: classes),
                       SpeakerTile(name: "Sam Park", isSelf: true, isMuted: true), "as the poller reads Zoom's own box")
    }
}

final class SpeakerChangeTests: XCTestCase {
    private func change(_ tiles: [SpeakerTile]?, signal: SpeakerReading.Signal = .tiles, selfNames: [String] = []) -> SpeakerChange {
        SpeakerChange(reading: SpeakerReading(source: .meetTab, tiles: tiles, signal: signal, reason: tiles == nil ? .readFailed : nil),
                      platform: .meet, selfNames: selfNames, timestamp: 1)
    }

    func testOneLitTileIsMatchedAndSeveralAreAmbiguous() {
        let one = change([SpeakerTile(name: "Ada", isLit: true), SpeakerTile(name: "Bob", isMuted: true)])
        XCTAssertEqual(one.attributionState, .matched)
        XCTAssertEqual(one.speakerName, "Ada")
        XCTAssertEqual(one.speakingNames, ["Ada"])
        XCTAssertEqual(one.mutedNames, ["Bob"])
        let two = change([SpeakerTile(name: "Ada", isLit: true), SpeakerTile(name: "Bob", isLit: true)])
        XCTAssertEqual(two.attributionState, .ambiguous)
        XCTAssertNil(two.speakerName)
        XCTAssertEqual(two.speakingNames, ["Ada", "Bob"])
        let same = change([SpeakerTile(name: "Ada (Guest)", isLit: true), SpeakerTile(name: "ada", isLit: true)])
        XCTAssertEqual(same.attributionState, .matched, "one person by key")
        XCTAssertEqual(same.speakerName, "Ada (Guest)")
    }

    func testTheUserIsNeverASpeaker() {
        let withSelfTile = change([SpeakerTile(name: "You", isSelf: true, isLit: true), SpeakerTile(name: "Ada", isLit: true)])
        XCTAssertEqual(withSelfTile.attributionState, .matched)
        XCTAssertEqual(withSelfTile.speakerName, "Ada")
        XCTAssertEqual(withSelfTile.selfName, "You")
        let onlySelf = change([SpeakerTile(name: "Sam Park", isSelf: true, isLit: true)])
        XCTAssertEqual(onlySelf.attributionState, .unknown)
        XCTAssertEqual(onlySelf.speakingNames, [], "silence for the Others track, not unreadable")
        let byName = change([SpeakerTile(name: "Sam Park", isLit: true), SpeakerTile(name: "Ada", isLit: true)], selfNames: ["sam  park"])
        XCTAssertEqual(byName.attributionState, .matched, "the user's own name is taken out")
        XCTAssertEqual(byName.speakerName, "Ada")
        XCTAssertEqual(change([], signal: .remote("Sam Park"), selfNames: ["Sam Park"]).attributionState, .unknown)
        XCTAssertEqual(change([SpeakerTile(name: "Ada", isLit: true)], signal: .selfOnly).speakingNames, [])
    }

    func testLabelsAndUnreadableWindows() {
        let label = change([SpeakerTile(name: "Ada"), SpeakerTile(name: "Bob", isLit: true)], signal: .remote("Ada"))
        XCTAssertEqual(label.speakerName, "Ada", "the label wins over the tiles")
        let unreadable = change(nil)
        XCTAssertNil(unreadable.speakingNames)
        XCTAssertEqual(unreadable.attributionState, .unknown)
        XCTAssertEqual(unreadable.reason, .readFailed)
    }

    func testSameReadingAndRenaming() {
        var later = change([SpeakerTile(name: "Ada", isLit: true)])
        later.timestamp = 9
        XCTAssertTrue(later.sameReading(as: change([SpeakerTile(name: "Ada", isLit: true)])))
        XCTAssertFalse(later.sameReading(as: change([SpeakerTile(name: "Bob", isLit: true)])))
        let renamed = later.renaming([SpeakerNames.key("ada"): "Ada Lovelace"])
        XCTAssertEqual(renamed.speakerName, "Ada Lovelace")
        XCTAssertEqual(renamed.speakingNames, ["Ada Lovelace"])
    }
}
