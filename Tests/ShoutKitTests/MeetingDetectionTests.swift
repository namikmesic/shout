import XCTest
@testable import ShoutKit

final class MeetingDetectionTests: XCTestCase {

    // MARK: Allowlist

    func testNativeMeetingAppsAreCaseInsensitiveAndCoverHelpers() {
        XCTAssertEqual(MeetingDetection.kind(bundleID: "us.zoom.xos"), .meetingApp(.zoom))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "US.ZOOM.XOS"), .meetingApp(.zoom))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.microsoft.teams"), .meetingApp(.teams))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.microsoft.teams2"), .meetingApp(.teams))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.microsoft.teams2.modulehost"), .meetingApp(.teams))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.cisco.webexmeetingsapp"), .meetingApp(.webex))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "Cisco-Systems.Spark"), .meetingApp(.webex))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.apple.FaceTime"), .meetingApp(.facetime))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.apple.avconferenced"), .meetingApp(.facetime))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.larksuite.larkapp.helper"), .meetingApp(.lark))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.gather.gather"), .meetingApp(.gather))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.tencent.tencentmeeting"), .meetingApp(.voov))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.electron.uberconference.helper"), .meetingApp(.dialpadMeetings))
    }

    func testChatAppsAreCallsThatNeverAutoStart() {
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.hnc.Discord.helper.Renderer"), .meetingApp(.discord))
        XCTAssertEqual(MeetingDetection.kind(bundleID: "net.whatsapp.WhatsApp"), .meetingApp(.whatsapp))
        for p in [MeetingPlatform.discord, .whatsapp, .aircall, .dialpad, .tuple, .clickup, .other] {
            XCTAssertFalse(p.autoStartEligible, "\(p)")
        }
        for p in [MeetingPlatform.zoom, .meet, .teams, .webex, .facetime, .slack] { XCTAssertTrue(p.autoStartEligible, "\(p)") }
    }

    func testBrowsersSlackAndUnknownApps() {
        for id in ["com.google.Chrome", "com.google.Chrome.helper", "com.google.chrome.canary", "org.chromium.Chromium",
                   "com.microsoft.edgemac", "com.microsoft.edgemac.helper", "com.brave.Browser", "company.thebrowser.Browser",
                   "company.thebrowser.dia", "ai.perplexity.comet", "com.openai.atlas.web.helper", "com.operasoftware.Opera",
                   "com.vivaldi.Vivaldi", "app.zen-browser.zen", "org.mozilla.firefox", "com.apple.Safari", "com.apple.WebKit.GPU"] {
            XCTAssertEqual(MeetingDetection.kind(bundleID: id), .browser, id)
        }
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.tinyspeck.slackmacgap"), .slack)
        XCTAssertEqual(MeetingDetection.kind(bundleID: "com.tinyspeck.slackmacgap.helper"), .slack)
        for id in ["", "com.namikmesic.shout", "com.electron.wispr-flow", "com.apple.VoiceMemos", "com.apple.corespeechd_system",
                   "com.google.chromecast", "us.zoom.xosx", "com.microsoft.teamsx"] {
            XCTAssertEqual(MeetingDetection.kind(bundleID: id), .ignored, id)
        }
    }

    func testHelperWithUnlistedIDUsesItsApp() {
        let h = MicHolder(pid: 50, bundleID: "", appPID: 10, appBundleID: "com.google.Chrome", appName: "Google Chrome")
        XCTAssertEqual(MeetingDetection.kind(of: h), .browser)
    }

    // MARK: URLs

    func testMeetURLs() {
        XCTAssertEqual(MeetingDetection.platform(forURL: "https://meet.google.com/abc-defg-hij"), .meet)
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://meet.google.com/ABC-defg-hij?authuser=1&pli=1"), "abc-defg-hij")
        XCTAssertEqual(MeetingDetection.platform(forURL: "https://meet.google.com/lookup/abcdefgh"), .meet)
        XCTAssertNil(MeetingDetection.platform(forURL: "https://meet.google.com/"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://meet.google.com/landing?authuser=0"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://meet.google.com/new"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://workspace.google.com/products/meet/"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://evil.com/meet.google.com/abc-defg-hij"))
        XCTAssertNil(MeetingDetection.platform(forURL: "ftp://meet.google.com/abc-defg-hij"))
    }

    func testZoomURLs() {
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://us02web.zoom.us/j/81234567890?pwd=abc"), "81234567890")
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://zoom.us/s/1234567890"), "1234567890")
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://app.zoom.us/wc/81234567890/join?fromPWA=1"), "81234567890")
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://zoom.us/wc/81234567890/start"), "81234567890")
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://zoom.us/wc/join/81234567890"), "81234567890")
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://agency.zoomgov.com/j/1601234567"), "1601234567")
        XCTAssertEqual(MeetingDetection.platform(forURL: "https://company.zoom.us/my/jane.doe"), .zoom)
        XCTAssertNil(MeetingDetection.meetingCode(forURL: "https://company.zoom.us/my/jane.doe"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://zoom.us/"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://zoom.us/pricing"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://app.zoom.us/wc/home"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://zoom.us/j/"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://www.zoom.com/en/products/virtual-meetings/"))
    }

    func testTeamsURLs() {
        let join = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjM0ZTk2@thread.v2/0?context=%7b%22Tid%22%3a%22x%22%7d"
        XCTAssertEqual(MeetingDetection.platform(forURL: join), .teams)
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: join), "19:meeting_NjM0ZTk2@thread.v2")
        let web = "https://teams.microsoft.com/v2/?meetingjoin=true#/l/meetup-join/19:meeting_NjM0ZTk2@thread.v2/0?context=x"
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: web), "19:meeting_NjM0ZTk2@thread.v2")
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://teams.live.com/meet/9381234567890?p=abc"), "9381234567890")
        XCTAssertEqual(MeetingDetection.platform(forURL: "https://teams.microsoft.com/light-meetings/launch?agent=web"), .teams)
        XCTAssertNil(MeetingDetection.platform(forURL: "https://teams.microsoft.com/v2/"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://teams.live.com/"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software"))
    }

    func testWebexSlackDiscordAndOthers() {
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://acme.webex.com/meet/Jane.Doe"), "jane.doe")
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://acme.webex.com/acme/j.php?MTID=m1234abcd"), "m1234abcd")
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://acme.webex.com/wbxmjs/joinservice/sites/acme/meeting/download/abc?siteurl=acme&MTID=x&meetingNumber=2641234567"),
                       nil, "the number is only in the query")
        XCTAssertEqual(MeetingDetection.platform(forURL: "https://acme.webex.com/webappng/sites/acme/meeting/info/2641234567"), .webex)
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://acme.webex.com/webappng/sites/acme/meeting/info/2641234567"), "2641234567")
        XCTAssertNil(MeetingDetection.platform(forURL: "https://www.webex.com/"))
        XCTAssertNil(MeetingDetection.platform(forURL: "https://www.webex.com/pricing/index.html"))

        XCTAssertEqual(MeetingDetection.platform(forURL: "https://app.slack.com/huddle/T0123/C0456"), .slack)
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://app.slack.com/huddle/T0123/C0456"), "T0123/C0456")
        XCTAssertNil(MeetingDetection.platform(forURL: "https://app.slack.com/client/T0123/C0456"))
        XCTAssertEqual(MeetingDetection.platform(forURL: "https://discord.com/channels/123/456"), .discord)
        XCTAssertNil(MeetingDetection.platform(forURL: "https://discord.com/app"))

        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://app.goto.com/meeting/123456789"), "123456789")
        XCTAssertEqual(MeetingDetection.platform(forURL: "https://whereby.com/team-standup"), .whereby)
        XCTAssertNil(MeetingDetection.platform(forURL: "https://whereby.com/information/pricing"))
        XCTAssertEqual(MeetingDetection.meetingCode(forURL: "https://meet.jit.si/MyRoom"), "myroom")
        XCTAssertNil(MeetingDetection.platform(forURL: "https://www.google.com/search?q=meet.google.com/abc-defg-hij"))
        XCTAssertNil(MeetingDetection.platform(forURL: "not a url"))
    }

    // MARK: Titles

    func testSlackHuddleTitles() {
        XCTAssertTrue(MeetingDetection.isSlackHuddle(windowTitle: "Huddle: #design"))
        XCTAssertTrue(MeetingDetection.isSlackHuddle(windowTitle: "  huddle : Jane Doe"))
        XCTAssertTrue(MeetingDetection.isSlackHuddle(windowTitle: "Huddle: #general - Acme - Slack"))
        XCTAssertTrue(MeetingDetection.isSlackHuddle(windowTitle: "Slack 🎤 - general"))
        XCTAssertFalse(MeetingDetection.isSlackHuddle(windowTitle: "general (Channel) - Acme - Slack"))
        XCTAssertFalse(MeetingDetection.isSlackHuddle(windowTitle: "Notes about the huddle: planning"))
        XCTAssertFalse(MeetingDetection.isSlackHuddle(windowTitle: ""))
    }

    // MARK: Decision

    private let chromeHelper = MicHolder(pid: 501, bundleID: "com.google.Chrome.helper", appPID: 500,
                                         appBundleID: "com.google.Chrome", appName: "Google Chrome")

    func testNativeAppNeedsNoContext() {
        let zoom = MicHolder(pid: 42, bundleID: "us.zoom.xos", appName: "zoom.us")
        let call = MeetingDetection.detect(holder: zoom, context: nil)
        XCTAssertEqual(call?.platform, .zoom)
        XCTAssertEqual(call?.qualifiesForAutoStart, true)
        XCTAssertEqual(call?.displayName, "Zoom")
        let discord = MeetingDetection.detect(holder: MicHolder(pid: 7, bundleID: "com.hnc.Discord", appName: "Discord"), context: nil)
        XCTAssertEqual(discord?.platform, .discord)
        XCTAssertEqual(discord?.qualifiesForAutoStart, false)
        XCTAssertNil(MeetingDetection.detect(holder: MicHolder(pid: 8, bundleID: "com.apple.VoiceMemos", appName: "Voice Memos"),
                                             context: nil))
    }

    func testBrowserNeedsMeetingEvidence() {
        let none = MeetingContext(urls: ["https://docs.google.com/document/d/1"], windowTitles: ["Doc - Google Chrome"])
        XCTAssertNil(MeetingDetection.detect(holder: chromeHelper, context: none))
        XCTAssertNil(MeetingDetection.detect(holder: chromeHelper, context: nil))
        let unconfirmed = MeetingDetection.detect(holder: chromeHelper, context: none, includeUnconfirmed: true)
        XCTAssertEqual(unconfirmed?.platform, .other)
        XCTAssertEqual(unconfirmed?.qualifiesForAutoStart, false)
        XCTAssertEqual(unconfirmed?.displayName, "Google Chrome")

        let meet = MeetingDetection.detect(holder: chromeHelper, context: MeetingContext(
            urls: ["https://mail.google.com/", "https://meet.google.com/abc-defg-hij"]))
        XCTAssertEqual(meet?.platform, .meet)
        XCTAssertEqual(meet?.meetingCode, "abc-defg-hij")
        XCTAssertEqual(meet?.pid, 500, "the app's pid, not the helper's")
        XCTAssertEqual(meet?.bundleID, "com.google.Chrome")
        XCTAssertEqual(meet?.qualifiesForAutoStart, true)
    }

    func testBrowserTabTitles() {
        // A background Meet tab using the mic, while the front tab is something else.
        let ctx = MeetingContext(urls: ["https://github.com/"],
                                 windowTitles: ["GitHub - Google Chrome"],
                                 tabTitles: ["GitHub", "Weekly sync | Microsoft Teams", "Meet - abc-defg-hij - Microphone recording"])
        let call = MeetingDetection.detect(holder: chromeHelper, context: ctx)
        XCTAssertEqual(call?.platform, .meet, "marked tabs win over unmarked ones")
        XCTAssertEqual(call?.meetingCode, "abc-defg-hij")
        XCTAssertEqual(call?.url, "https://meet.google.com/abc-defg-hij", "rebuilt from the code, for the calendar link")
        XCTAssertEqual(call?.qualifiesForAutoStart, true, "the tab using the mic is proof of the meeting")

        // A recently seen meeting URL counts, but a live one wins.
        let recent = MeetingContext(urls: ["https://github.com/"], recentURLs: ["https://zoom.us/wc/81234567890/join"])
        XCTAssertEqual(MeetingDetection.detect(holder: chromeHelper, context: recent)?.meetingCode, "81234567890")
        var live = recent; live.urls.append("https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(MeetingDetection.detect(holder: chromeHelper, context: live)?.platform, .meet)
        var marked = recent; marked.tabTitles = ["Meet - xyz-wxyz-xyz - Camera and microphone recording"]
        XCTAssertEqual(MeetingDetection.detect(holder: chromeHelper, context: marked)?.meetingCode, "xyz-wxyz-xyz")

        let teams = MeetingDetection.detect(holder: chromeHelper, context: MeetingContext(tabTitles: ["Meeting with Ana | Microsoft Teams"]))
        XCTAssertEqual(teams?.platform, .teams)
        let huddle = MeetingDetection.detect(holder: chromeHelper, context: MeetingContext(windowTitles: ["Huddle: #eng - Acme - Slack - Google Chrome"]))
        XCTAssertEqual(huddle?.platform, .slack)
        XCTAssertNil(MeetingDetection.detect(holder: chromeHelper, context: MeetingContext(tabTitles: ["Meeting notes - Google Docs"])))
    }

    func testSlackOnlyDuringHuddle() {
        let slack = MicHolder(pid: 9, bundleID: "com.tinyspeck.slackmacgap.helper", appPID: 8,
                              appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack")
        XCTAssertNil(MeetingDetection.detect(holder: slack, context: MeetingContext(windowTitles: ["general - Acme - Slack"])))
        let call = MeetingDetection.detect(holder: slack, context: MeetingContext(windowTitles: ["general - Acme - Slack", "Huddle: #general"]))
        XCTAssertEqual(call?.platform, .slack)
        XCTAssertEqual(call?.qualifiesForAutoStart, true)
    }

    func testCallStillVisible() {
        let meet = DetectedCall(pid: 500, bundleID: "com.google.Chrome", appName: "Google Chrome", platform: .meet,
                                meetingCode: "abc-defg-hij", qualifiesForAutoStart: true)
        XCTAssertNil(MeetingDetection.isCallStillVisible(meet, context: nil))
        XCTAssertEqual(MeetingDetection.isCallStillVisible(meet, context: MeetingContext(tabTitles: ["Meet - abc-defg-hij"])), true)
        XCTAssertEqual(MeetingDetection.isCallStillVisible(meet, context: MeetingContext(urls: ["https://news.ycombinator.com/"])), false)
        let zoom = DetectedCall(pid: 42, bundleID: "us.zoom.xos", appName: "zoom.us", platform: .zoom, qualifiesForAutoStart: true)
        XCTAssertEqual(MeetingDetection.isCallStillVisible(zoom, context: MeetingContext(windowTitles: ["Zoom Meeting"])), true)
        XCTAssertEqual(MeetingDetection.isCallStillVisible(zoom, context: MeetingContext(windowTitles: ["Zoom Workplace"])), false)
        let ft = DetectedCall(pid: 3, bundleID: "com.apple.FaceTime", appName: "FaceTime", platform: .facetime, qualifiesForAutoStart: true)
        XCTAssertNil(MeetingDetection.isCallStillVisible(ft, context: MeetingContext()))
    }

    func testSameCall() {
        let a = DetectedCall(pid: 1, bundleID: "com.google.Chrome", appName: "Chrome", platform: .meet, meetingCode: "abc-defg-hij",
                             qualifiesForAutoStart: true)
        var b = a; b.bundleID = "company.thebrowser.Browser"
        XCTAssertTrue(a.isSameCall(as: b), "same code in another browser")
        var c = a; c.meetingCode = "xyz-wxyz-xyz"
        XCTAssertFalse(a.isSameCall(as: c))
        var d = a; d.meetingCode = nil
        XCTAssertTrue(a.isSameCall(as: d), "code unknown: same app")
        var e = a; e.platform = .teams
        XCTAssertFalse(a.isSameCall(as: e))
    }
}

// MARK: - CallSessionTracker

final class CallSessionTrackerTests: XCTestCase {
    typealias T = CallSessionTracker
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private let zoom = DetectedCall(pid: 42, bundleID: "us.zoom.xos", appName: "zoom.us", platform: .zoom, qualifiesForAutoStart: true)
    private let meet = DetectedCall(pid: 500, bundleID: "com.google.Chrome", appName: "Google Chrome", platform: .meet,
                                    url: "https://meet.google.com/abc-defg-hij", meetingCode: "abc-defg-hij", qualifiesForAutoStart: true)
    private let teams = DetectedCall(pid: 77, bundleID: "com.microsoft.teams2", appName: "Microsoft Teams", platform: .teams,
                                     qualifiesForAutoStart: true)

    /// Drives the tracker like the app: an observation every `poll` seconds plus ticks every 0.25 s.
    /// `calls(t)` gives the mic holders at time t. Returns actions with their times.
    private func run(_ tr: inout T, from start: TimeInterval, to end: TimeInterval, poll: TimeInterval = 3,
                     calls: (TimeInterval) -> [DetectedCall]) -> [(TimeInterval, T.Action)] {
        var out: [(TimeInterval, T.Action)] = []
        var t = start
        var nextPoll = start
        while t <= end + 1e-9 {
            if t + 1e-9 >= nextPoll {
                out += tr.observe(calls(t), at: at(t)).map { (t, $0) }
                nextPoll += poll
            } else {
                out += tr.tick(at: at(t)).map { (t, $0) }
            }
            t += 0.25
        }
        return out
    }

    private func prompts(_ list: [(TimeInterval, T.Action)]) -> [TimeInterval] {
        list.compactMap { if case .prompt = $0.1 { return $0.0 }; return nil }
    }

    private func time(of match: (T.Action) -> Bool, in list: [(TimeInterval, T.Action)]) -> TimeInterval? {
        list.first { match($0.1) }?.0
    }

    // MARK: Prompts

    func testPromptsOnceAndDismissesAfter20s() {
        var tr = T()
        let out = run(&tr, from: 0, to: 60) { _ in [self.zoom] }
        XCTAssertEqual(prompts(out), [0])
        XCTAssertEqual(time(of: { $0 == .dismissPrompt }, in: out), 20)
        XCTAssertEqual(out.count, 2, "ignored prompt latches; no re-prompt while the call continues")
    }

    func testDeclineLatchClearsOnlyAfter15sFree() {
        var tr = T()
        XCTAssertEqual(tr.observe([zoom], at: at(0)), [.prompt(zoom)])
        tr.promptDeclined(at: at(2))
        // Mic free for 10 s, then back: still latched.
        var out = run(&tr, from: 3, to: 40) { t in (t >= 10 && t < 20) ? [] : [self.zoom] }
        XCTAssertEqual(prompts(out), [])
        // Free for 15 s or more: the next call prompts.
        out = run(&tr, from: 41, to: 80) { t in t < 60 ? [] : [self.zoom] }
        XCTAssertEqual(prompts(out), [62])
    }

    func testDeclineLatchExpiresAfter4Hours() {
        var tr = T()
        _ = tr.observe([zoom], at: at(0))
        tr.promptDeclined(at: at(1))
        XCTAssertEqual(tr.observe([zoom], at: at(3600)), [])
        XCTAssertEqual(tr.observe([zoom], at: at(4 * 3600 - 5)), [])
        XCTAssertEqual(tr.observe([zoom], at: at(4 * 3600 + 1)), [.prompt(zoom)])
    }

    func testDeclinedCallDoesNotBlockADifferentCall() {
        var tr = T()
        _ = tr.observe([zoom], at: at(0))
        tr.promptDeclined(at: at(1))
        XCTAssertEqual(tr.observe([zoom, meet], at: at(3)), [.prompt(meet)])
    }

    func testSnoozeReturnsAfterTwoMinutesIfStillThere() {
        var tr = T()
        _ = tr.observe([zoom], at: at(0))
        tr.promptSnoozed(at: at(5))
        let out = run(&tr, from: 6, to: 140, poll: 5) { _ in [self.zoom] }
        XCTAssertEqual(prompts(out), [125])
    }

    func testSnoozedCallGoneIsNotPromptedAgain() {
        var tr = T()
        _ = tr.observe([zoom], at: at(0))
        tr.promptSnoozed(at: at(5))
        let out = run(&tr, from: 6, to: 140, poll: 5) { t in t < 60 ? [self.zoom] : [] }
        XCTAssertEqual(prompts(out), [])
    }

    func testPromptWithdrawnWhenCallEnds() {
        var tr = T()
        _ = tr.observe([zoom], at: at(0))
        let out = run(&tr, from: 3, to: 10) { _ in [] }
        XCTAssertEqual(time(of: { $0 == .dismissPrompt }, in: out), 4.5)
    }

    func testNoPromptWhileRecordingOrDisabled() {
        var tr = T()
        _ = tr.recordingStarted(at: at(0))
        XCTAssertEqual(tr.observe([zoom], at: at(1)), [])
        var off = T()
        off.promptsEnabled = false
        XCTAssertEqual(off.observe([zoom], at: at(1)), [])
    }

    func testRecordingStartDismissesPromptAndBindsItsCall() {
        var tr = T()
        _ = tr.observe([meet, zoom], at: at(0))
        XCTAssertEqual(tr.promptedCall, meet)
        XCTAssertEqual(tr.recordingStarted(at: at(2)), [.dismissPrompt])
        XCTAssertEqual(tr.boundCall, meet)
    }

    func testUserStopWhileCallContinuesDoesNotPrompt() {
        var tr = T()
        _ = tr.observe([zoom], at: at(0))
        _ = tr.recordingStarted(at: at(1))
        _ = tr.observe([zoom], at: at(10))
        XCTAssertEqual(tr.recordingStopped(at: at(100)), [])
        var out = run(&tr, from: 101, to: 200) { _ in [self.zoom] }
        XCTAssertEqual(prompts(out), [])
        out = run(&tr, from: 201, to: 260) { t in t < 230 ? [] : [self.zoom] }
        XCTAssertEqual(prompts(out), [231])
    }

    // MARK: Auto-stop windows

    /// Records `call` from t=0, the call ends at t=60. Returns the actions after 60.
    private func endCall(_ call: DetectedCall, poll: TimeInterval = 3, setup: (inout T) -> Void = { _ in },
                         evidence: T.Corroboration? = nil) -> (T, [(TimeInterval, T.Action)]) {
        var tr = T()
        setup(&tr)
        _ = tr.observe([call], at: at(0))
        _ = tr.recordingStarted(call: call, at: at(0))
        _ = run(&tr, from: 0, to: 59.75, poll: poll) { _ in [call] }
        var out = tr.observe([], at: at(60)).map { (60.0, $0) }
        if let e = evidence { out += tr.corroborate(e, at: at(60)).map { (60.0, $0) } }
        out += run(&tr, from: 60.25, to: 90, poll: poll) { _ in [] }
        return (tr, out)
    }

    private func stoppingTimes(_ out: [(TimeInterval, T.Action)]) -> (shown: TimeInterval, deadline: Date, stop: TimeInterval)? {
        guard let shown = out.first(where: { if case .showStopping = $0.1 { return true }; return false }),
              case .showStopping(let deadline) = shown.1,
              let stop = time(of: { $0 == .stop }, in: out) else { return nil }
        return (shown.0, deadline, stop)
    }

    func testCorroboratedStopWindow() {
        let (_, out) = endCall(zoom, evidence: .appQuit)
        let s = stoppingTimes(out)
        // Loss confirmed at 61.5 (1.5 s), quiet window 1 s, then a 6 s banner.
        XCTAssertEqual(s?.shown, 62.5)
        XCTAssertEqual(s?.deadline, at(68.5))
        XCTAssertEqual(s?.stop, 68.5)
    }

    func testNativeReleaseStopWindow() {
        let (tr, out) = endCall(zoom)
        let s = stoppingTimes(out)
        XCTAssertEqual(s?.shown, 65.0)
        XCTAssertEqual(s?.stop, 71.0)
        XCTAssertFalse(tr.isRecording)
    }

    func testAmbiguousStopWindowForBrowsers() {
        let (_, out) = endCall(meet)
        XCTAssertEqual(stoppingTimes(out)?.shown, 67.0)
        XCTAssertEqual(stoppingTimes(out)?.stop, 73.0)
    }

    func testWindowGoneCorroboratesABrowserCall() {
        let (_, out) = endCall(meet, evidence: .windowGone)
        XCTAssertEqual(stoppingTimes(out)?.shown, 62.5)
    }

    func testDeviceChangeMakesANativeReleaseAmbiguous() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 57.75) { _ in [self.zoom] }
        tr.inputDeviceChanged(at: at(58))
        var out = tr.observe([], at: at(60)).map { (60.0, $0) }
        out += run(&tr, from: 60.25, to: 90) { _ in [] }
        XCTAssertEqual(stoppingTimes(out)?.shown, 67.0)
    }

    func testBannerIsVisibleAtLeast6s() {
        for e in [T.Corroboration.appQuit, .windowGone] {
            let (_, out) = endCall(teams, evidence: e)
            guard let s = stoppingTimes(out) else { return XCTFail("no stop") }
            XCTAssertGreaterThanOrEqual(s.deadline.timeIntervalSince(at(s.shown)), T.minStoppingBanner)
            XCTAssertGreaterThanOrEqual(s.stop - s.shown, T.minStoppingBanner)
        }
    }

    func testAutoStopDisabled() {
        let (tr, out) = endCall(zoom, setup: { $0.autoStopEnabled = false })
        XCTAssertTrue(out.isEmpty)
        XCTAssertTrue(tr.isRecording)
    }

    // MARK: Cancelling

    func testKeepGoingCancelsAndHoldsUntilTheCallIsLostAgain() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.zoom] }
        var out = tr.observe([], at: at(60)).map { (60.0, $0) }
        out += run(&tr, from: 60.25, to: 66) { _ in [] }
        XCTAssertNotNil(time(of: { if case .showStopping = $0 { return true }; return false }, in: out))
        XCTAssertEqual(tr.keepGoing(at: at(66)), [.cancelStopping])
        out = run(&tr, from: 66.25, to: 120) { _ in [] }
        XCTAssertTrue(out.isEmpty, "no new stop while the call stays gone")
        XCTAssertTrue(tr.isRecording)
        // The call comes back and ends again: the ladder runs again.
        out = run(&tr, from: 120.25, to: 160) { t in t < 130 ? [self.zoom] : [] }
        XCTAssertNotNil(time(of: { $0 == .stop }, in: out))
    }

    func testCallReturningCancelsTheBanner() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.zoom] }
        let out = run(&tr, from: 60, to: 90) { t in t < 66 ? [] : [self.zoom] }
        XCTAssertEqual(out.map(\.1).filter { $0 == .cancelStopping }.count, 1)
        XCTAssertNil(time(of: { $0 == .stop }, in: out))
        XCTAssertTrue(tr.isRecording)
    }

    func testBriefFlapDuringTheQuietWindowShowsNothing() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.zoom] }
        var out = tr.observe([], at: at(60)).map { (60.0, $0) }
        out += tr.observe([zoom], at: at(61)).map { (61.0, $0) }
        out += run(&tr, from: 61.25, to: 90) { _ in [self.zoom] }
        XCTAssertTrue(out.isEmpty)
    }

    func testBoundCallFollowsAnAppRestart() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        var restarted = zoom; restarted.pid = 4242
        _ = tr.observe([restarted], at: at(20))
        XCTAssertEqual(tr.boundCall?.pid, 4242)
    }

    func testUserStopDuringBannerHidesIt() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.zoom] }
        _ = run(&tr, from: 60, to: 66) { _ in [] }
        XCTAssertEqual(tr.recordingStopped(at: at(66)), [.cancelStopping])
        XCTAssertFalse(tr.isRecording)
    }

    // MARK: Guards

    func testNoAutoStopInTheFirst15s() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = tr.observe([zoom], at: at(0))
        let out = run(&tr, from: 5, to: 40) { _ in [] }
        // Lost at 5, confirmable at 6.5, but armed only at 15; +3.5 s quiet window.
        XCTAssertEqual(stoppingTimes(out)?.shown, 18.5)
    }

    func testNoAutoStopWithin10sOfWake() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 99.75) { _ in [self.zoom] }
        tr.systemDidWake(at: at(100))
        let out = run(&tr, from: 100, to: 130) { _ in [] }
        XCTAssertEqual(stoppingTimes(out)?.shown, 113.5)
    }

    func testNoAutoStopWithin10sOfAudioRestart() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 99.75) { _ in [self.zoom] }
        tr.audioServiceRestarted(at: at(100))
        let out = run(&tr, from: 100, to: 130) { _ in [] }
        XCTAssertEqual(stoppingTimes(out)?.shown, 113.5)
    }

    func testSpeechNeedsTwoEmptyPollsAndVetoesTheBanner() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.zoom] }
        // Someone is still talking until t=70.
        var out: [(TimeInterval, T.Action)] = []
        var t = 60.0
        while t <= 100 {
            if t <= 70 { tr.lastSpeechAt = at(t) }
            let polled = (t - 60).truncatingRemainder(dividingBy: 3) == 0
            out += (polled ? tr.observe([], at: at(t)) : tr.tick(at: at(t))).map { (t, $0) }
            t += 0.25
        }
        // Second empty poll at 63 confirms; quiet window ends at 66.5, but speech holds the banner until 75.
        XCTAssertEqual(stoppingTimes(out)?.shown, 75)
    }

    func testSpeechVetoIsCapped() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.zoom] }
        var out: [(TimeInterval, T.Action)] = []
        var t = 60.0
        while t <= 120 {
            tr.lastSpeechAt = at(t)
            let polled = (t - 60).truncatingRemainder(dividingBy: 3) == 0
            out += (polled ? tr.observe([], at: at(t)) : tr.tick(at: at(t))).map { (t, $0) }
            t += 0.25
        }
        // Armed at 63, so speech holds the banner until 63 + 30.
        XCTAssertEqual(stoppingTimes(out)?.shown, 93)
    }

    func testUnboundRecordingBindsOnlyACallOfItsEvent() {
        var tr = T()
        _ = tr.recordingStarted(target: T.Target(eventKey: "ev@1"), at: at(0))
        XCTAssertNil(tr.boundCall)
        _ = tr.observe([zoom], at: at(30))
        XCTAssertNil(tr.boundCall, "a Zoom call of no (or another) event is not this recording")
        var mine = zoom; mine.eventKey = "ev@1"
        _ = tr.observe([mine], at: at(300))
        XCTAssertEqual(tr.boundCall, mine, "late correlation: no time limit")

        var plain = T()
        _ = plain.recordingStarted(at: at(0))
        _ = plain.observe([zoom], at: at(30))
        XCTAssertNil(plain.boundCall, "a manual recording without an event never takes a call that starts later")
        let out = run(&plain, from: 31, to: 90) { _ in [] }
        XCTAssertTrue(out.isEmpty, "an unbound recording never auto-stops")
    }

    // MARK: Auto-resume

    func testSameCallWithin120sOffersResume() {
        var (tr, out) = endCall(meet, evidence: .windowGone)
        guard let stop = time(of: { $0 == .stop }, in: out) else { return XCTFail("no stop") }
        var back = meet; back.pid = 600
        let again = tr.observe([back], at: at(stop + 100))
        XCTAssertEqual(again, [.offerResume(back)])
        _ = tr.recordingStarted(at: at(stop + 101))
        XCTAssertEqual(tr.boundCall, back)
    }

    func testSameCallAfter120sIsANewPrompt() {
        var (tr, out) = endCall(meet, evidence: .windowGone)
        guard let stop = time(of: { $0 == .stop }, in: out) else { return XCTFail("no stop") }
        XCTAssertEqual(tr.observe([meet], at: at(stop + 121)), [.prompt(meet)])
    }

    func testDifferentCallAfterAutoStopIsAPrompt() {
        var (tr, out) = endCall(meet, evidence: .windowGone)
        guard let stop = time(of: { $0 == .stop }, in: out) else { return XCTFail("no stop") }
        var other = meet; other.meetingCode = "xyz-wxyz-xyz"
        XCTAssertEqual(tr.observe([other], at: at(stop + 20)), [.prompt(other)])
    }

    func testAutoResumeIsCappedPerMeeting() {
        var tr = T()
        var clock = 0.0
        _ = tr.recordingStarted(call: meet, at: at(clock))
        var resumes = 0
        for _ in 0..<4 {
            _ = run(&tr, from: clock, to: clock + 30) { _ in [self.meet] }
            var out = run(&tr, from: clock + 30.25, to: clock + 32) { _ in [] }
            out += tr.corroborate(.windowGone, at: at(clock + 32)).map { (clock + 32, $0) }
            out += run(&tr, from: clock + 32.25, to: clock + 50) { _ in [] }
            guard let stop = time(of: { $0 == .stop }, in: out) else { return XCTFail("no stop") }
            clock = stop + 10
            let back = tr.observe([meet], at: at(clock))
            if back == [.offerResume(meet)] {
                resumes += 1
                _ = tr.recordingStarted(at: at(clock))
            } else {
                XCTAssertEqual(back, [.prompt(meet)])
                break
            }
        }
        XCTAssertEqual(resumes, T.maxAutoResumes)
    }

    func testUserStopIsNotResumed() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = tr.observe([zoom], at: at(10))
        _ = tr.observe([], at: at(20))
        _ = tr.recordingStopped(at: at(20.5))
        let out = run(&tr, from: 21, to: 60) { t in t < 40 ? [] : [self.zoom] }
        XCTAssertEqual(prompts(out), [42], "a normal prompt, not a resume")
    }
}

// MARK: - Detection fixes (audit area A)

final class MeetingDetectionFixTests: XCTestCase {
    private let chromeHelper = MicHolder(pid: 501, bundleID: "com.google.Chrome.helper", appPID: 500,
                                         appBundleID: "com.google.Chrome", appName: "Google Chrome")
    private let slack = MicHolder(pid: 9, bundleID: "com.tinyspeck.slackmacgap.helper", appPID: 8,
                                  appBundleID: "com.tinyspeck.slackmacgap", appName: "Slack")

    func testMarkedTabKeepsItsLiveURLAndQualifies() {
        let ctx = MeetingContext(urls: ["https://meet.google.com/abc-defg-hij?authuser=0"],
                                 tabTitles: ["Inbox", "Meet - abc-defg-hij - Microphone recording"])
        let call = MeetingDetection.detect(holder: chromeHelper, context: ctx)
        XCTAssertEqual(call?.platform, .meet)
        XCTAssertEqual(call?.url, "https://meet.google.com/abc-defg-hij?authuser=0")
        XCTAssertEqual(call?.qualifiesForAutoStart, true)

        // A marked Teams tab (its title has no code) keeps the one live Teams URL for the calendar link, but
        // never takes its meeting key: the URL may be another meeting's (R2-3).
        let liveURL = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0"
        let teams = MeetingDetection.detect(holder: chromeHelper, context: MeetingContext(
            urls: [liveURL], tabTitles: ["Weekly | Microsoft Teams - Camera and microphone recording"]))
        XCTAssertEqual(teams?.platform, .teams)
        XCTAssertEqual(teams?.url, liveURL)
        XCTAssertNil(teams?.meetingCode)
        XCTAssertEqual(teams?.qualifiesForAutoStart, true)
    }

    /// R2-3: meeting B in the Teams web app (its URL is the `/v2/` shell) after meeting A, whose link is still in
    /// the recent-URL cache: B gets neither A's URL nor its code, so it is never merged into A's note.
    func testCodeLessMarkedTabTakesNoStaleURL() {
        let a = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_A%40thread.v2/0"
        let b = MeetingDetection.detect(holder: chromeHelper, context: MeetingContext(
            urls: ["https://teams.microsoft.com/v2/"], tabTitles: ["Planning | Microsoft Teams - Microphone recording"],
            recentURLs: [a]))
        XCTAssertEqual(b?.platform, .teams)
        XCTAssertNil(b?.url)
        XCTAssertNil(b?.meetingCode)
        XCTAssertEqual(b?.qualifiesForAutoStart, true)
        let ended = DetectedCall(pid: 500, bundleID: "com.google.Chrome", appName: "Google Chrome", platform: .teams, url: a,
                                 meetingCode: MeetingDetection.meetingCode(forURL: a), qualifiesForAutoStart: true)
        XCTAssertFalse(b.map { $0.isSameMeeting(as: ended) } ?? true)

        // A Meet tab named after its event, with two Meet meetings on screen: neither URL is taken.
        let named = MeetingDetection.detect(holder: chromeHelper, context: MeetingContext(
            urls: ["https://meet.google.com/aaa-bbbb-ccc", "https://meet.google.com/ddd-eeee-fff"],
            tabTitles: ["Meet - Weekly sync - Microphone recording"]))
        XCTAssertEqual(named?.platform, .meet)
        XCTAssertNil(named?.url)
        XCTAssertNil(named?.meetingCode)
    }

    /// R2-8: a re-read while meeting A is recorded and meeting B's green room (also marked, earlier in the tab
    /// strip) is open keeps A; once A's tab no longer uses the mic, it is B.
    func testRereadPrefersTheMeetingAlreadyFollowed() {
        let both = MeetingContext(urls: ["https://meet.google.com/bbb-cccc-ddd"],
                                  tabTitles: ["Meet - bbb-cccc-ddd - Camera and microphone recording",
                                              "Meet - aaa-bbbb-ccc - Microphone recording"])
        XCTAssertEqual(MeetingDetection.detect(holder: chromeHelper, context: both)?.meetingCode, "bbb-cccc-ddd")
        let kept = MeetingDetection.detect(holder: chromeHelper, context: both, preferCode: "aaa-bbbb-ccc")
        XCTAssertEqual(kept?.meetingCode, "aaa-bbbb-ccc")
        XCTAssertEqual(kept?.url, "https://meet.google.com/aaa-bbbb-ccc")
        let left = MeetingContext(urls: ["https://meet.google.com/bbb-cccc-ddd"],
                                  tabTitles: ["Meet - bbb-cccc-ddd - Camera and microphone recording", "Meet - aaa-bbbb-ccc"])
        XCTAssertEqual(MeetingDetection.detect(holder: chromeHelper, context: left, preferCode: "aaa-bbbb-ccc")?.meetingCode,
                       "bbb-cccc-ddd")
        // Without markers (Safari, Firefox), the followed meeting's front tab wins over another window's.
        let windows = MeetingContext(urls: ["https://meet.google.com/bbb-cccc-ddd", "https://meet.google.com/aaa-bbbb-ccc"])
        XCTAssertEqual(MeetingDetection.detect(holder: chromeHelper, context: windows, preferCode: "aaa-bbbb-ccc")?.meetingCode,
                       "aaa-bbbb-ccc")
    }

    func testSlackHuddleRules() {
        XCTAssertTrue(MeetingDetection.isSlackHuddle(windowTitle: "[Main] Acme - Slack"))
        XCTAssertTrue(MeetingDetection.isSlackHuddleTitle("Huddle: #eng | Slack"))
        XCTAssertFalse(MeetingDetection.isSlackHuddleTitle("Huddle: #eng"), "browsers need Slack named too")
        XCTAssertFalse(MeetingDetection.isSlackHuddleTitle("slackers huddle: notes"), "whole words only")
        XCTAssertTrue(MeetingDetection.isSlackHuddleTitle("Slack 🎤 general"))
    }

    func testSlackHuddleMarkerLastsFiveMinutes() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var marker = SlackHuddleMarker()
        marker.note(windowTitle: "Huddle: #eng", at: t0)
        XCTAssertTrue(marker.isFresh(at: t0.addingTimeInterval(299)))
        XCTAssertFalse(marker.isFresh(at: t0.addingTimeInterval(301)))
        marker.note(windowTitle: "general - Acme - Slack", at: t0.addingTimeInterval(10))
        XCTAssertFalse(marker.isFresh(at: t0.addingTimeInterval(11)), "another focused title clears it")

        // A huddle whose window is not titled yet qualifies while the marker is fresh.
        let ctx = MeetingContext(windowTitles: ["general - Acme - Slack"])
        XCTAssertNil(MeetingDetection.detect(holder: slack, context: ctx))
        XCTAssertEqual(MeetingDetection.detect(holder: slack, context: ctx, slackHuddleSeen: true)?.qualifiesForAutoStart, true)
    }

    func testZoomMeetingWindowByIdentifier() {
        let zoom = DetectedCall(pid: 42, bundleID: "us.zoom.xos", appName: "zoom.us", platform: .zoom, qualifiesForAutoStart: true)
        let german = MeetingContext(windowTitles: ["Zoom-Meeting"], windowIdentifiers: ["zm.meeting.window.main"])
        XCTAssertEqual(MeetingDetection.isCallStillVisible(zoom, context: german), true)
        XCTAssertEqual(MeetingDetection.isCallStillVisible(zoom, context: MeetingContext(windowTitles: ["Zoom Workplace"],
                                                                                      windowIdentifiers: ["zm.home"])), false)
        // R2-10: a Zoom that names its windows decides by the identifier alone, whatever the titles say.
        XCTAssertEqual(MeetingDetection.isCallStillVisible(zoom, context: MeetingContext(
            windowTitles: ["Zoom Meeting chat"], windowIdentifiers: ["zm.chat.window"])), false)
        // A Zoom build without identifiers still has the English title fallback.
        XCTAssertEqual(MeetingDetection.isCallStillVisible(zoom, context: MeetingContext(windowTitles: ["Zoom Meeting"])), true)
    }

    func testSameMeetingNeedsTheSameCode() {
        let zoom = DetectedCall(pid: 42, bundleID: "us.zoom.xos", appName: "zoom.us", platform: .zoom, qualifiesForAutoStart: true)
        XCTAssertTrue(zoom.isSameCall(as: zoom))
        XCTAssertFalse(zoom.isSameMeeting(as: zoom), "two code-less Zoom calls are the same app, not the same meeting")
        let a = DetectedCall(pid: 1, bundleID: "com.google.Chrome", appName: "Chrome", platform: .meet, meetingCode: "abc-defg-hij",
                             qualifiesForAutoStart: true)
        XCTAssertTrue(a.isSameMeeting(as: a))
        let other = DetectedCall(pid: 1, bundleID: "com.google.Chrome", appName: "Chrome", platform: .other, qualifiesForAutoStart: false)
        XCTAssertTrue(other.isSameCall(as: a), "a browser without evidence is the meeting later found in it")
        XCTAssertTrue(a.improves(on: other))
        XCTAssertFalse(other.improves(on: a))
    }

    func testEventKeysAndPlatforms() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let e = UpcomingEvent(id: "x@1", externalID: "ext", occurrenceStart: start, title: "Sync", start: start,
                              end: start.addingTimeInterval(1800))
        XCTAssertEqual(MeetingDetection.eventKey(e), MeetingDetection.eventKey(externalID: "ext", occurrenceStart: start))
        XCTAssertEqual(MeetingDetection.eventKey(e), "ext@1800000000")
        XCTAssertEqual(MeetingPlatform(service: .googleMeet), .meet)
        XCTAssertEqual(MeetingPlatform(service: .zoom), .zoom)
    }
}

// MARK: - Tracker fixes (audit areas A and C)

final class CallSessionTrackerFixTests: XCTestCase {
    typealias T = CallSessionTracker
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private let zoom = DetectedCall(pid: 42, bundleID: "us.zoom.xos", appName: "zoom.us", platform: .zoom, qualifiesForAutoStart: true)
    private let meet = DetectedCall(pid: 500, bundleID: "com.google.Chrome", appName: "Google Chrome", platform: .meet,
                                    url: "https://meet.google.com/abc-defg-hij", meetingCode: "abc-defg-hij", qualifiesForAutoStart: true)
    private let whatsapp = DetectedCall(pid: 61, bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", platform: .whatsapp,
                                        qualifiesForAutoStart: false)
    private let chrome = DetectedCall(pid: 500, bundleID: "com.google.Chrome", appName: "Google Chrome", platform: .other,
                                      qualifiesForAutoStart: false)
    private let facetime = DetectedCall(pid: 3, bundleID: "com.apple.FaceTime", appName: "FaceTime", platform: .facetime,
                                        qualifiesForAutoStart: true)
    private let slack = DetectedCall(pid: 8, bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", platform: .slack,
                                     qualifiesForAutoStart: true)

    private func run(_ tr: inout T, from start: TimeInterval, to end: TimeInterval, poll: TimeInterval = 3,
                     calls: (TimeInterval) -> [DetectedCall]) -> [(TimeInterval, T.Action)] {
        var out: [(TimeInterval, T.Action)] = []
        var t = start
        var nextPoll = start
        while t <= end + 1e-9 {
            if t + 1e-9 >= nextPoll {
                out += tr.observe(calls(t), at: at(t)).map { (t, $0) }
                nextPoll += poll
            } else {
                out += tr.tick(at: at(t)).map { (t, $0) }
            }
            t += 0.25
        }
        return out
    }

    private func time(of match: (T.Action) -> Bool, in list: [(TimeInterval, T.Action)]) -> TimeInterval? {
        list.first { match($0.1) }?.0
    }
    private func isShowStopping(_ a: T.Action) -> Bool { if case .showStopping = a { return true }; return false }

    /// Records `call` until it leaves at `leave`; returns the time of the auto-stop.
    private func recordUntilAutoStop(_ tr: inout T, _ call: DetectedCall, leave: TimeInterval = 60,
                                     evidence: T.Corroboration? = nil) -> TimeInterval? {
        _ = run(&tr, from: 0, to: leave - 0.25) { _ in [call] }
        var out = tr.observe([], at: at(leave)).map { (leave, $0) }
        if let e = evidence { out += tr.corroborate(e, at: at(leave)).map { (leave, $0) } }
        out += run(&tr, from: leave + 0.25, to: leave + 30) { _ in [] }
        return time(of: { $0 == .stop }, in: out)
    }

    // A-B3: identity for auto-resume

    func testCodeLessCallBackAfterAutoStopIsANewPrompt() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        guard let stop = recordUntilAutoStop(&tr, zoom) else { return XCTFail("no stop") }
        XCTAssertEqual(tr.observe([zoom], at: at(stop + 50)), [.prompt(zoom)], "another Zoom meeting, not the same note")
    }

    /// R2-1: native Zoom gets its event from the time window, so the next meeting (back-to-back, or ad hoc
    /// during the event) has the same event key. Only a code says it is the same meeting (Wispr Flow).
    func testCodeLessCallOfTheSameEventIsANewPrompt() {
        var tr = T()
        var mine = zoom; mine.eventKey = "ev@1"
        _ = tr.recordingStarted(call: mine, target: T.Target(eventKey: "ev@1"), at: at(0))
        guard let stop = recordUntilAutoStop(&tr, mine) else { return XCTFail("no stop") }
        XCTAssertEqual(tr.observe([mine], at: at(stop + 20)), [.prompt(mine)], "Y joined early is not X")
    }

    func testCodedCallOfTheSameEventResumesWithin10Minutes() {
        var mine = meet; mine.eventKey = "ev@1"
        var tr = T()
        _ = tr.recordingStarted(call: mine, target: T.Target(eventKey: "ev@1"), at: at(0))
        guard let stop = recordUntilAutoStop(&tr, mine, evidence: .windowGone) else { return XCTFail("no stop") }
        XCTAssertEqual(tr.observe([mine], at: at(stop + 500)), [.offerResume(mine)])

        var late = T()
        _ = late.recordingStarted(call: mine, target: T.Target(eventKey: "ev@1"), at: at(0))
        guard let stop2 = recordUntilAutoStop(&late, mine, evidence: .windowGone) else { return XCTFail("no stop") }
        XCTAssertEqual(late.observe([mine], at: at(stop2 + 601)), [.prompt(mine)])

        // The same code, but the stopped note has no event: the 2-minute window only.
        var other = T()
        _ = other.recordingStarted(call: meet, at: at(0))
        guard let stop3 = recordUntilAutoStop(&other, meet, evidence: .windowGone) else { return XCTFail("no stop") }
        XCTAssertEqual(other.observe([mine], at: at(stop3 + 300)), [.prompt(mine)])
    }

    // A-B2 / C-B1 / A-G5: sleep

    func testSleepStopResumesTheSameMeetingAfterWake() {
        var tr = T()
        _ = tr.observe([meet], at: at(0))
        _ = tr.recordingStarted(at: at(1))
        _ = run(&tr, from: 1, to: 100) { _ in [self.meet] }
        XCTAssertEqual(tr.recordingSuspended(at: at(100)), [])
        XCTAssertEqual(tr.endedCall, meet)
        // Asleep for an hour; the resume window counts from wake.
        tr.systemDidWake(at: at(3700))
        XCTAssertEqual(tr.observe([meet], at: at(3702)), [.offerResume(meet)])
        _ = tr.recordingStarted(at: at(3703))
        XCTAssertEqual(tr.boundCall, meet)
    }

    /// R2-6: a check that runs after a long sleep but before the wake notification (the overdue poll, Core
    /// Audio listeners) keeps the sleep stop; the call seen then, or after wake, resumes the note.
    func testCheckBeforeWakeKeepsTheSleepStop() {
        var tr = T()
        _ = tr.recordingStarted(call: meet, at: at(0))
        _ = run(&tr, from: 0, to: 100) { _ in [self.meet] }
        _ = tr.recordingSuspended(at: at(100))
        XCTAssertEqual(tr.observe([], at: at(1900)), [], "asleep 30 minutes; the call isn't back yet")
        XCTAssertEqual(tr.endedCall, meet)
        tr.systemDidWake(at: at(1901))
        XCTAssertEqual(tr.observe([meet], at: at(1903)), [.offerResume(meet)])

        var early = T()
        _ = early.recordingStarted(call: meet, at: at(0))
        _ = run(&early, from: 0, to: 100) { _ in [self.meet] }
        _ = early.recordingSuspended(at: at(100))
        XCTAssertEqual(early.observe([meet], at: at(1900)), [.offerResume(meet)])

        // A wake that never comes (the sleep was cancelled) doesn't keep the stop forever.
        var cancelled = T()
        _ = cancelled.recordingStarted(call: meet, at: at(0))
        _ = cancelled.recordingSuspended(at: at(100))
        _ = cancelled.observe([], at: at(100 + T.sleepWakeWait + 1))
        XCTAssertNil(cancelled.endedCall)
    }

    func testCodeLessCallAfterSleepPromptsAndIsNotLatched() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 100) { _ in [self.zoom] }
        _ = tr.recordingSuspended(at: at(100))
        tr.systemDidWake(at: at(200))
        XCTAssertEqual(tr.observe([zoom], at: at(201)), [.prompt(zoom)], "the app keeps its Resume card in front of it")
        // Resume from the card follows the slept call.
        XCTAssertEqual(tr.callToBind(T.Target(previousCall: tr.endedCall, isResume: true)), zoom)
    }

    func testUserSwitchStopNeitherLatchesNorResumes() {
        var tr = T()
        _ = tr.recordingStarted(call: meet, at: at(0))
        _ = run(&tr, from: 0, to: 30) { _ in [self.meet] }
        _ = tr.recordingStopped(at: at(30), latch: false)
        XCTAssertNil(tr.endedCall)
        XCTAssertEqual(tr.observe([meet], at: at(31)), [.prompt(meet)])
    }

    // A-B4: Join + Start

    func testJoinAndStartIgnoresACallAlreadyHoldingTheMic() {
        var tr = T()
        _ = tr.observe([zoom], at: at(0))
        tr.promptDeclined(at: at(1))
        let target = T.Target(eventKey: "meet@1", platform: .meet)
        XCTAssertNil(tr.callToBind(target), "Zoom is another call")
        _ = tr.recordingStarted(target: target, at: at(2))
        XCTAssertNil(tr.boundCall)
        _ = tr.observe([zoom], at: at(5))
        XCTAssertNil(tr.boundCall)
        _ = tr.observe([zoom, meet], at: at(8))
        XCTAssertEqual(tr.boundCall, meet, "the event's service, starting after the recording")
        // Leaving Zoom later does not stop the recording.
        XCTAssertTrue(run(&tr, from: 120, to: 160) { _ in [self.meet] }.isEmpty)
    }

    func testJoinAndStartTakesTheEventsCallAlreadyThere() {
        var tr = T()
        var mine = zoom; mine.eventKey = "z@1"
        _ = tr.observe([mine], at: at(0))
        XCTAssertEqual(tr.callToBind(T.Target(eventKey: "z@1", platform: .zoom)), mine)
        var other = zoom; other.eventKey = "other@1"
        var tr2 = T()
        _ = tr2.observe([other], at: at(0))
        XCTAssertNil(tr2.callToBind(T.Target(eventKey: "z@1", platform: .zoom)), "a Zoom call of another event")
    }

    // A-B5: manual recordings

    func testManualRecordingNeverTakesChatOrUnconfirmedBrowserCalls() {
        var tr = T()
        _ = tr.recordingStarted(target: T.Target(eventKey: "ev@1"), at: at(0))
        _ = tr.observe([whatsapp, chrome], at: at(30))
        XCTAssertNil(tr.boundCall)
        var chatOfEvent = whatsapp; chatOfEvent.eventKey = "ev@1"
        _ = tr.observe([chatOfEvent], at: at(33))
        XCTAssertEqual(tr.boundCall, chatOfEvent, "a calendar-matched call is the meeting, whatever the app")
        var plain = T()
        _ = plain.observe([whatsapp], at: at(0))
        plain.promptDeclined(at: at(1))
        XCTAssertNil(plain.callToBind(), "chat apps only from their own card")
        _ = plain.observe([whatsapp, zoom], at: at(3))
        XCTAssertEqual(plain.callToBind(), zoom, "a manual start takes a meeting already in progress")

        // R2-9: not even while the chat call's or the browser's prompt is on screen (a start from the menu bar).
        var prompted = T()
        XCTAssertEqual(prompted.observe([whatsapp], at: at(0)), [.prompt(whatsapp)])
        XCTAssertNil(prompted.callToBind())
        _ = prompted.observe([whatsapp, zoom], at: at(3))
        XCTAssertEqual(prompted.promptedCall, whatsapp)
        XCTAssertEqual(prompted.callToBind(), zoom, "the first call that may auto-start")
        var browser = T()
        XCTAssertEqual(browser.observe([chrome], at: at(0)), [.prompt(chrome)])
        XCTAssertNil(browser.callToBind())
        _ = browser.recordingStarted(at: at(1))
        XCTAssertNil(browser.boundCall, "an in-person note is never stopped by the browser's tab")
    }

    // R2-7: a browser holding the mic without evidence (`.other`) vs a meeting in that browser

    func testOtherLatchDoesNotSilenceAMeetingInTheSameBrowser() {
        var tr = T()
        XCTAssertEqual(tr.observe([chrome], at: at(0)), [.prompt(chrome)])
        tr.promptDeclined(at: at(2))
        XCTAssertEqual(tr.observe([chrome], at: at(5)), [])
        XCTAssertEqual(tr.observe([meet], at: at(8)), [.prompt(meet)], "Not now on the tab was not about this meeting")

        var declinedMeet = T()
        XCTAssertEqual(declinedMeet.observe([meet], at: at(0)), [.prompt(meet)])
        declinedMeet.promptDeclined(at: at(2))
        XCTAssertEqual(declinedMeet.observe([chrome], at: at(5)), [], "the declined Meet, read without its evidence")
        XCTAssertEqual(declinedMeet.observe([meet], at: at(8)), [])
    }

    func testRecordedMeetingIsNotKeptAliveByAnotherTab() {
        var tr = T()
        _ = tr.recordingStarted(call: meet, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.meet] }
        let out = run(&tr, from: 60, to: 90) { _ in [self.chrome] }
        XCTAssertNotNil(time(of: { $0 == .stop }, in: out), "left the Meet; another tab still uses the mic")

        // A recording started from the browser's own prompt follows the meeting later found in it.
        var other = T()
        _ = other.recordingStarted(call: chrome, at: at(0))
        XCTAssertTrue(run(&other, from: 0, to: 120) { t in [t < 30 ? self.chrome : self.meet] }.isEmpty)
        XCTAssertEqual(other.boundCall, meet)
    }

    func testLateBindingStopsAfter24Tries() {
        var tr = T()
        _ = tr.recordingStarted(target: T.Target(eventKey: "ev@1"), at: at(0))
        for i in 0..<T.lateBindAttempts {
            var c = zoom; c.pid = pid_t(1000 + i)
            _ = tr.observe([c], at: at(Double(i)))
        }
        var mine = zoom; mine.eventKey = "ev@1"; mine.pid = 7
        _ = tr.observe([mine], at: at(100))
        XCTAssertNil(tr.boundCall)
    }

    // A-B7

    func testNoTickerWhileAutoStopIsOff() {
        var tr = T()
        tr.autoStopEnabled = false
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = tr.observe([], at: at(30))
        XCTAssertFalse(tr.needsTick)
        tr.autoStopEnabled = true
        XCTAssertTrue(tr.needsTick)
    }

    // A-B6: prompt hold

    func testHeldPromptDoesNotTimeOutAndGetsAFreshTimeout() {
        var tr = T()
        _ = tr.observe([zoom], at: at(0))
        tr.holdPrompt(true, at: at(5))
        XCTAssertTrue(run(&tr, from: 5, to: 60) { _ in [self.zoom] }.isEmpty, "locked: nothing times out")
        tr.holdPrompt(false, at: at(60))
        let out = run(&tr, from: 60, to: 90) { _ in [self.zoom] }
        XCTAssertEqual(time(of: { $0 == .dismissPrompt }, in: out), 80)
    }

    // C-B2: hand-back

    func testStopHandedBackKeepsRecording() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.zoom] }
        _ = tr.observe([], at: at(60))
        // The app finds its banner gone when the `.stop` arrives and hands it straight back.
        var stop = 60.0
        while !tr.tick(at: at(stop)).contains(.stop) { stop += 0.25; if stop > 120 { return XCTFail("no stop") } }
        _ = tr.stopHandedBack(at: at(stop))
        XCTAssertTrue(tr.isRecording)
        XCTAssertNil(tr.endedCall)
        XCTAssertTrue(run(&tr, from: stop + 0.25, to: stop + 60) { _ in [] }.isEmpty, "kept going until the call is seen again")
    }

    func testBannerRefusedBeforeItsDeadlineHandsBack() {
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.zoom] }
        let out = run(&tr, from: 60, to: 66) { _ in [] }
        XCTAssertNotNil(time(of: isShowStopping, in: out))
        XCTAssertEqual(tr.stopHandedBack(at: at(66)), [.cancelStopping])
        XCTAssertTrue(run(&tr, from: 66.25, to: 100) { _ in [] }.isEmpty)
    }

    // A-G6: [Stop] on the banner expedites the auto-stop

    func testExpeditedStopCanResume() {
        var tr = T()
        _ = tr.recordingStarted(call: meet, at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.meet] }
        _ = run(&tr, from: 60, to: 68) { _ in [] }
        XCTAssertEqual(tr.expediteStop(at: at(68)), [.stop])
        XCTAssertFalse(tr.isRecording)
        XCTAssertEqual(tr.observe([meet], at: at(100)), [.offerResume(meet)])
    }

    // C-B5

    func testFailedResumePromptsTheCall() {
        var tr = T()
        _ = tr.recordingStarted(call: meet, at: at(0))
        guard let stop = recordUntilAutoStop(&tr, meet, evidence: .windowGone) else { return XCTFail("no stop") }
        XCTAssertEqual(tr.observe([meet], at: at(stop + 10)), [.offerResume(meet)])
        XCTAssertEqual(tr.resumeFailed(at: at(stop + 10)), [.prompt(meet)])
        XCTAssertEqual(tr.promptedCall, meet)
    }

    // A-G1: the prompt is correlated again as its call is identified

    func testPromptIsUpdatedWhenItsCallIsIdentified() {
        var tr = T()
        XCTAssertEqual(tr.observe([chrome], at: at(0)), [.prompt(chrome)])
        XCTAssertEqual(tr.observe([meet], at: at(3)), [.prompt(meet)], "same browser, now a Meet call: the card is updated")
        XCTAssertEqual(tr.observe([meet], at: at(6)), [])
        var withEvent = meet; withEvent.eventKey = "ev@1"
        XCTAssertEqual(tr.observe([withEvent], at: at(9)), [.prompt(withEvent)])
        XCTAssertEqual(tr.promptedCall, withEvent)
    }

    /// R2-4: a prompt that qualifies only on a later read (a Slack huddle's title lags the mic) starts its
    /// 10 s countdown then, and gets a full timeout from that update rather than from the first prompt.
    func testPromptQualifyingLateGetsAFullTimeout() {
        var tr = T()
        var lagging = slack; lagging.qualifiesForAutoStart = false
        XCTAssertEqual(tr.observe([lagging], at: at(0)), [.prompt(lagging)])
        let out = run(&tr, from: 1, to: 60) { t in [t < 11 ? lagging : self.slack] }
        guard let updated = time(of: { $0 == .prompt(self.slack) }, in: out),
              let dismissed = time(of: { $0 == .dismissPrompt }, in: out) else { return XCTFail("no update or dismissal") }
        XCTAssertEqual(updated, 13)
        XCTAssertEqual(dismissed, updated + T.promptTimeout)
    }

    func testPromptUpdatesAreCapped() {
        var tr = T()
        XCTAssertEqual(tr.observe([chrome], at: at(0)), [.prompt(chrome)])
        var a = chrome; a.platform = .meet
        var b = a; b.url = "https://meet.google.com/abc-defg-hij"
        var c = b; c.meetingCode = "abc-defg-hij"
        var d = c; d.qualifiesForAutoStart = true
        XCTAssertEqual(tr.observe([a], at: at(3)), [.prompt(a)])
        XCTAssertEqual(tr.observe([b], at: at(6)), [.prompt(b)])
        XCTAssertEqual(tr.observe([c], at: at(9)), [.prompt(c)])
        XCTAssertEqual(tr.observe([d], at: at(12)), [], "at most \(T.maxPromptUpdates) updates")
        XCTAssertEqual(tr.promptedCall, c)
    }

    // A-G13: calendar proximity

    func testLossNearTheEventEndStopsSooner() {
        var tr = T()
        _ = tr.recordingStarted(call: meet, target: T.Target(eventKey: "ev@1", eventEnd: at(62)), at: at(0))
        _ = run(&tr, from: 0, to: 59.75) { _ in [self.meet] }
        let out = run(&tr, from: 60, to: 90) { _ in [] }
        // A browser loss waits 5.5 s (banner at 67); near the event's end 3.5 s.
        XCTAssertEqual(time(of: isShowStopping, in: out), 65)

        var early = T()
        _ = early.recordingStarted(call: zoom, target: T.Target(eventEnd: at(10)), at: at(0))
        _ = early.observe([zoom], at: at(0))
        let out2 = run(&early, from: 5, to: 40) { _ in [] }
        XCTAssertEqual(time(of: isShowStopping, in: out2), 10, "no 15 s guard at the end of the event")
    }

    // MARK: Scenario simulations (A-detection.md §6)

    /// §6.1 Zoom call from start to end, then another Zoom meeting a minute later.
    func testScenarioZoomCallStartToEnd() {
        var tr = T()
        XCTAssertEqual(tr.observe([zoom], at: at(0)), [.prompt(zoom)])
        _ = tr.recordingStarted(call: zoom, at: at(10.25))
        XCTAssertEqual(tr.boundCall, zoom)
        _ = run(&tr, from: 10.25, to: 599.75) { _ in [self.zoom] }
        var out = tr.observe([], at: at(600)).map { (600.0, $0) }
        out += tr.corroborate(.windowGone, at: at(600)).map { (600.0, $0) }
        out += run(&tr, from: 600.25, to: 620) { _ in [] }
        XCTAssertEqual(time(of: isShowStopping, in: out), 602.5)
        guard let stop = time(of: { $0 == .stop }, in: out) else { return XCTFail("no stop") }
        XCTAssertEqual(stop, 608.5)
        XCTAssertEqual(tr.observe([zoom], at: at(stop + 60)), [.prompt(zoom)], "a new meeting, not merged")
    }

    /// §6.2 Meet in Chrome with background tabs: the meeting tab's call qualifies with its URL, survives a
    /// tab switch, stops when left, and a different Meet afterwards is a new prompt.
    func testScenarioMeetInChromeWithBackgroundTabs() {
        let helper = MicHolder(pid: 501, bundleID: "com.google.Chrome.helper", appPID: 500,
                               appBundleID: "com.google.Chrome", appName: "Google Chrome")
        let ctx = MeetingContext(urls: ["https://meet.google.com/abc-defg-hij", "https://calendar.google.com/"],
                                 tabTitles: ["Inbox", "Doc", "Meet - abc-defg-hij - Microphone recording"])
        guard let call = MeetingDetection.detect(holder: helper, context: ctx) else { return XCTFail("no call") }
        XCTAssertTrue(call.qualifiesForAutoStart)
        XCTAssertEqual(call.url, "https://meet.google.com/abc-defg-hij")
        var tr = T()
        XCTAssertEqual(tr.observe([call], at: at(0)), [.prompt(call)])
        _ = tr.recordingStarted(at: at(2))
        XCTAssertEqual(tr.boundCall, call)
        // The Gmail tab in front now: the same call (same code) is still seen.
        var background = call; background.qualifiesForAutoStart = false
        XCTAssertTrue(run(&tr, from: 2, to: 300) { _ in [background] }.isEmpty)
        var out = tr.observe([], at: at(300)).map { (300.0, $0) }
        out += run(&tr, from: 300.25, to: 330) { _ in [] }
        XCTAssertEqual(time(of: isShowStopping, in: out), 307)
        guard let stop = time(of: { $0 == .stop }, in: out) else { return XCTFail("no stop") }
        var next = call; next.meetingCode = "xyz-wxyz-xyz"; next.url = "https://meet.google.com/xyz-wxyz-xyz"
        XCTAssertEqual(tr.observe([next], at: at(stop + 30)), [.prompt(next)])
    }

    /// §6.3 A Slack huddle that drops and rejoins within 5 minutes: no meeting identity, so a new prompt.
    func testScenarioSlackHuddleRejoin() {
        var tr = T()
        _ = tr.recordingStarted(call: slack, at: at(0))
        guard let stop = recordUntilAutoStop(&tr, slack, leave: 120, evidence: .windowGone) else { return XCTFail("no stop") }
        XCTAssertEqual(tr.observe([slack], at: at(stop + 60)), [.prompt(slack)])
    }

    /// §6.4 FaceTime: hang up, then call someone else within 2 minutes.
    func testScenarioFaceTimeTwoCalls() {
        var tr = T()
        _ = tr.recordingStarted(call: facetime, at: at(0))
        _ = run(&tr, from: 0, to: 299.75) { _ in [self.facetime] }
        let out = tr.observe([], at: at(300)).map { (300.0, $0) } + run(&tr, from: 300.25, to: 330) { _ in [] }
        XCTAssertEqual(time(of: isShowStopping, in: out), 305, "native release: 1.5 s + 3.5 s")
        guard let stop = time(of: { $0 == .stop }, in: out) else { return XCTFail("no stop") }
        XCTAssertEqual(tr.observe([facetime], at: at(stop + 90)), [.prompt(facetime)], "not merged into the same note")
    }

    /// §6.5 A manual recording while WhatsApp takes and releases the mic, then a Zoom call of the meeting's event.
    func testScenarioManualRecordingWhileOtherAppsTakeTheMic() {
        var tr = T()
        _ = tr.recordingStarted(target: T.Target(eventKey: "ev@1"), at: at(0))
        var out = run(&tr, from: 30, to: 45) { _ in [self.whatsapp] }
        out += run(&tr, from: 45.25, to: 70) { _ in [] }
        XCTAssertNil(tr.boundCall)
        XCTAssertTrue(out.isEmpty, "never bound, so never stopped")
        var mine = zoom; mine.eventKey = "ev@1"
        _ = tr.observe([mine], at: at(90))
        XCTAssertEqual(tr.boundCall, mine)
    }

    /// §6.6 Sleep in the middle of a Zoom call, with the call still holding the mic at wake.
    func testScenarioSleepMidZoomCall() {
        // Code-less Zoom without a calendar event: a prompt (the app keeps the Resume card in front of it).
        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        _ = run(&tr, from: 0, to: 600) { _ in [self.zoom] }
        _ = tr.recordingSuspended(at: at(600))
        tr.systemDidWake(at: at(900))
        let out = run(&tr, from: 902, to: 905) { _ in [self.zoom] }
        XCTAssertEqual(out.first?.1, .prompt(zoom))
        // Linked to a calendar event by its time window, it is still code-less: a prompt too (R2-1).
        var mine = zoom; mine.eventKey = "ev@1"
        var cal = T()
        _ = cal.recordingStarted(call: mine, target: T.Target(eventKey: "ev@1"), at: at(0))
        _ = run(&cal, from: 0, to: 600) { _ in [mine] }
        _ = cal.recordingSuspended(at: at(600))
        cal.systemDidWake(at: at(900))
        XCTAssertEqual(cal.observe([mine], at: at(902)), [.prompt(mine)])
        // The same meeting by its code (Zoom on the web) resumes the note after a long sleep.
        let web = DetectedCall(pid: 500, bundleID: "com.google.Chrome", appName: "Google Chrome", platform: .zoom,
                               url: "https://zoom.us/j/123456789", meetingCode: "123456789", qualifiesForAutoStart: true,
                               eventKey: "ev@1")
        var coded = T()
        _ = coded.recordingStarted(call: web, target: T.Target(eventKey: "ev@1"), at: at(0))
        _ = run(&coded, from: 0, to: 600) { _ in [web] }
        _ = coded.recordingSuspended(at: at(600))
        coded.systemDidWake(at: at(4200))
        XCTAssertEqual(coded.observe([web], at: at(4202)), [.offerResume(web)])
    }

    /// §6.7 Dictation in the middle of a call, simulated from the mic holders up. Holding fn pauses the meeting
    /// microphone and starts Shout's dictation recorder; both switch the input, and the call app can drop out
    /// of a check while it re-opens the device. Shout's own input is never a call (the monitor skips Shout's
    /// processes, and Shout isn't a calling app either), Zoom stays bound with no banner through the hand-off,
    /// and the ladder runs normally when the call ends.
    func testScenarioDictationMidCall() {
        let zoomHolder = MicHolder(pid: 42, bundleID: "us.zoom.xos", appName: "zoom.us")
        let dictation = MicHolder(pid: 900, bundleID: "com.namikmesic.shout", appName: "Shout")
        let meetingMic = MicHolder(pid: 901, bundleID: "com.apple.audio.AUVoiceIOService", appPID: 900,
                                   appBundleID: "com.namikmesic.shout", appName: "Shout")
        func calls(_ holders: [MicHolder]) -> [DetectedCall] {
            holders.compactMap { MeetingDetection.detect(holder: $0, context: nil, includeUnconfirmed: true) }
        }
        XCTAssertEqual(calls([dictation, meetingMic]), [])

        var tr = T()
        _ = tr.recordingStarted(call: zoom, at: at(0))
        XCTAssertTrue(run(&tr, from: 0, to: 59.75) { _ in calls([zoomHolder, meetingMic]) }.isEmpty)
        // fn down at 60 s, up at 68 s. The others keep talking (system audio), so the conversation is warm.
        tr.lastSpeechAt = at(59.5)
        tr.inputDeviceChanged(at: at(60))
        var around = run(&tr, from: 60, to: 67.75) { t in calls(t < 62 ? [dictation] : [zoomHolder, dictation]) }
        tr.lastSpeechAt = at(67.5)
        tr.inputDeviceChanged(at: at(68))
        around += run(&tr, from: 68, to: 120) { t in calls(t < 69 ? [zoomHolder] : [zoomHolder, meetingMic]) }
        XCTAssertTrue(around.isEmpty, "no banner and no stop around the dictation")
        XCTAssertEqual(tr.boundCall, zoom)

        let out = tr.observe(calls([meetingMic]), at: at(150)).map { (150.0, $0) }
            + run(&tr, from: 150.25, to: 170) { _ in calls([meetingMic]) }
        XCTAssertNotNil(time(of: isShowStopping, in: out))
        XCTAssertNotNil(time(of: { $0 == .stop }, in: out), "the call ended: stopped as usual")
    }
}
