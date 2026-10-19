import XCTest
@testable import ShoutKit

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
private let enUS = Locale(identifier: "en_US")

/// 2025-10-16 (a Thursday) at hh:mm:ss UTC, shifted by `day` days.
private func at(_ h: Int, _ m: Int, _ s: Int = 0, day: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2025, month: 10, day: 16 + day, hour: h, minute: m, second: s))!
}

private func event(_ id: String, _ start: Date, _ end: Date, title: String? = nil, url: String? = nil,
                   status: UpcomingEvent.Response = .accepted, allDay: Bool = false) -> UpcomingEvent {
    UpcomingEvent(id: id, externalID: "ext-" + id, title: title ?? id.uppercased(), start: start, end: end, isAllDay: allDay,
                  conferenceURL: url.flatMap(URL.init(string:)), myStatus: status)
}

final class ConferenceURLTests: XCTestCase {
    private func link(location: String? = nil, url: String? = nil, notes: String? = nil) -> String? {
        CalendarText.conferenceURL(location: location, url: url.flatMap(URL.init(string:)), notes: notes)?.absoluteString
    }

    func testPrefersURLThenLocationThenNotes() {
        let zoom = "https://us02web.zoom.us/j/85012345678?pwd=abc", meet = "https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(link(location: meet, url: zoom, notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0"), zoom)
        // A non-conference URL field is skipped.
        XCTAssertEqual(link(location: meet, url: "https://docs.google.com/document/d/1", notes: zoom), meet)
        XCTAssertEqual(link(location: "Microsoft Teams Meeting", url: nil, notes: "Join: " + zoom), zoom)
        XCTAssertEqual(link(location: "Room 4B", url: nil, notes: "Agenda: budget"), nil)
    }

    func testOutlookTeamsInviteSkipsOptionsAndDialIn() {
        let notes = """
        ________________________________________________________________________________
        Microsoft Teams meeting
        Meeting options<https://teams.microsoft.com/meetingOptions/?organizerId=abc&tenantId=def&threadId=19_meeting_ZmFh@thread.v2&messageId=0&language=en-US>
        Find a local number<https://dialin.teams.microsoft.com/8a1b2c?id=123456789> | Reset PIN<https://dialin.teams.microsoft.com/usp/pstnconferencing>
        Join on your computer, mobile app or room device
        Click here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmFhNTk4ZjAtMDk3MS00YmRj%40thread.v2/0?context=%7b%22Tid%22%3a%2272f988bf%22%2c%22Oid%22%3a%22abc%22%7d>
        Meeting ID: 123 456 789 012
        Passcode: abc123
        Download Teams<https://www.microsoft.com/microsoft-teams/download-app> | Join on the web<https://www.microsoft.com/microsoft-teams/join-a-meeting>
        Or call in (audio only)
        +1 425-555-0100,,123456789#<tel:+14255550100,,123456789#>   United States, Seattle
        Learn More<https://aka.ms/JoinTeamsMeeting> | Help<https://support.microsoft.com/teams>
        ________________________________________________________________________________
        """
        XCTAssertEqual(link(location: "Microsoft Teams Meeting", notes: notes),
                       "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmFhNTk4ZjAtMDk3MS00YmRj%40thread.v2/0?context=%7b%22Tid%22%3a%2272f988bf%22%2c%22Oid%22%3a%22abc%22%7d")
    }

    func testHTMLNotesWithEntitiesAndSafeLinks() {
        let html = """
        <div><p>Hi all,</p><a href="https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_QWE%2540thread.v2%2F0%3Fcontext%3D%257b%257d&amp;data=05%7C01%7C&amp;reserved=0" target="_blank" rel="noreferrer">
        <span style="color:#5B5FC7">Join the meeting now</span></a></div>
        """
        let u = CalendarText.conferenceURL(location: nil, url: nil, notes: html)
        XCTAssertEqual(u?.host, "teams.microsoft.com")
        XCTAssertEqual(u.flatMap(CalendarText.meetingCode), "teams:19:meeting_QWE@thread.v2")

        let zoomHTML = #"<a href="https://zoom.us/j/123456789?pwd=a1b2&amp;from=addon">Join Zoom Meeting</a>"#
        XCTAssertEqual(link(notes: zoomHTML), "https://zoom.us/j/123456789?pwd=a1b2&from=addon")
    }

    func testZoomInviteIgnoresLocalNumberLink() {
        let notes = """
        John Doe is inviting you to a scheduled Zoom meeting.
        Find your local number: https://us02web.zoom.us/u/kdZ5bQ3Xy
        Join Zoom Meeting
        https://us02web.zoom.us/j/85012345678?pwd=Q2VkT1BxR3c.1

        Meeting ID: 850 1234 5678
        Passcode: 123456
        One tap mobile
        +16465588656,,85012345678#,,,,*123456# US (New York)
        Join by SIP
        • 85012345678@zoomcrc.com
        """
        XCTAssertEqual(link(notes: notes), "https://us02web.zoom.us/j/85012345678?pwd=Q2VkT1BxR3c.1")
        // Dial-in only: no link.
        XCTAssertNil(link(notes: "Dial: +1 646 558 8656\nFind your local number: https://us02web.zoom.us/u/kdZ5bQ3Xy\nhttps://zoom.us/download"))
    }

    func testGoogleMeetDescriptionAndRedirect() {
        let notes = """
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        More phone numbers: https://tel.meet/abc-defg-hij?pin=1234567890123
        Join with Google Meet: https://meet.google.com/abc-defg-hij.
        Learn more about Meet at: https://support.google.com/a/users/answer/9282720
        Please do not edit this section.
        """
        XCTAssertEqual(link(notes: notes), "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(link(notes: "Link: https://www.google.com/url?q=https://meet.google.com/xyz-abcd-efg&sa=D&source=calendar"),
                       "https://meet.google.com/xyz-abcd-efg")
    }

    func testBareHostsAndPunctuation() {
        XCTAssertEqual(link(location: "us02web.zoom.us/j/85012345678"), "https://us02web.zoom.us/j/85012345678")
        XCTAssertEqual(link(location: "Call (meet.google.com/abc-defg-hij)"), "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(link(notes: "Join (https://zoom.us/j/123456789)!"), "https://zoom.us/j/123456789")
        XCTAssertEqual(link(notes: "[Join](https://meet.google.com/abc-defg-hij)"), "https://meet.google.com/abc-defg-hij")
    }

    func testWebexAndFaceTime() {
        XCTAssertEqual(link(notes: "Global call-in https://acme.webex.com/acme/globalcallin.php?MTID=m1\nJoin https://acme.webex.com/acme/j.php?MTID=m0123abcd"),
                       "https://acme.webex.com/acme/j.php?MTID=m0123abcd")
        XCTAssertEqual(link(location: "https://acme.webex.com/meet/jdoe"), "https://acme.webex.com/meet/jdoe")
        XCTAssertNil(link(notes: "https://help.webex.com/en-us/article/123 https://www.webex.com/downloads.html"))
        XCTAssertEqual(link(notes: "FaceTime: https://facetime.apple.com/join#v=1&p=AbCdEf123&k=xyz"),
                       "https://facetime.apple.com/join#v=1&p=AbCdEf123&k=xyz")
        XCTAssertNil(link(notes: "https://facetime.apple.com/"))
    }

    func testNonJoinLinksAreRejected() {
        for s in ["https://zoom.us", "https://zoom.us/download", "https://support.zoom.us/hc/en-us/articles/1",
                  "https://zoom.us/unsubscribe?id=1", "https://meet.google.com/", "https://meet.google.com/landing",
                  "https://teams.microsoft.com/meetingOptions/?organizerId=1", "https://aka.ms/JoinTeamsMeeting",
                  "https://teams.microsoft.com/l/chat/0/0?users=a@b.com", "https://example.com/zoom.us/j/123456789",
                  "mailto:someone@zoom.us"] {
            XCTAssertNil(link(notes: s), s)
        }
    }

    func testRoomsNamedLikeHelpPagesAreStillJoinLinks() {
        for s in ["https://acme.zoom.us/my/helpdesk", "https://zoom.us/my/supportteam", "https://acme.webex.com/meet/helpline",
                  "https://acme.zoom.us/my/downloads.team"] {
            XCTAssertEqual(link(notes: s), s)
        }
        for s in ["https://us02web.zoom.us/u/kdZ5bQ3Xy", "https://acme.webex.com/support/join/x", "https://acme.webex.com/help/meet/x"] {
            XCTAssertNil(link(notes: s), s)
        }
    }

    func testJoinLinksListsAllInOrderWithoutDuplicates() {
        let text = "A https://zoom.us/j/111111111 B https://meet.google.com/abc-defg-hij C https://zoom.us/j/111111111"
        XCTAssertEqual(CalendarText.joinLinks(in: text).map(\.absoluteString),
                       ["https://zoom.us/j/111111111", "https://meet.google.com/abc-defg-hij"])
    }

    func testPlatformIsDerivedFromLink() {
        XCTAssertEqual(event("a", at(10, 0), at(11, 0), url: "https://meet.google.com/abc-defg-hij").platform, "Google Meet")
        XCTAssertEqual(event("a", at(10, 0), at(11, 0), url: "https://teams.live.com/meet/9384756123?p=x").platform, "Microsoft Teams")
        XCTAssertNil(event("a", at(10, 0), at(11, 0)).platform)
    }
}

final class MeetingCodeTests: XCTestCase {
    private func code(_ s: String) -> String? { URL(string: s).flatMap(CalendarText.meetingCode) }

    func testMeet() {
        XCTAssertEqual(code("https://meet.google.com/abc-defg-hij"), "google_meet:abc-defg-hij")
        XCTAssertEqual(code("https://meet.google.com/abc-defg-hij?authuser=1&pli=1"), "google_meet:abc-defg-hij")
        XCTAssertEqual(code("https://meet.google.com/ABC-DEFG-HIJ"), "google_meet:abc-defg-hij")
        XCTAssertNil(code("https://meet.google.com/"))
        XCTAssertNil(code("https://tel.meet/abc-defg-hij?pin=1"))
    }

    func testZoomVariantsAgree() {
        let expected = "zoom:85012345678"
        for s in ["https://us02web.zoom.us/j/85012345678?pwd=abc", "https://app.zoom.us/wc/85012345678/join?fromPWA=1",
                  "https://zoom.us/wc/join/85012345678", "https://us02web.zoom.us/s/85012345678?zak=x",
                  "zoommtg://zoom.us/join?action=join&confno=85012345678&pwd=abc", "https://acme.zoomgov.com/j/85012345678"] {
            XCTAssertEqual(code(s), expected, s)
        }
        XCTAssertNotEqual(code("https://zoom.us/j/85012345679"), expected)
        XCTAssertEqual(code("https://acme.zoom.us/my/JaneDoe"), "zoom:my/janedoe")
    }

    func testTeamsCalendarLinkMatchesLiveURLs() {
        let expected = "teams:19:meeting_ZmFh@thread.v2"
        for s in ["https://teams.microsoft.com/l/meetup-join/19%3ameeting_ZmFh%40thread.v2/0?context=%7b%22Tid%22%3a%221%22%7d",
                  "https://teams.microsoft.com/l/meetup-join/19%3AMeeting_ZmFh%40thread.v2/0".replacingOccurrences(of: "Meeting", with: "meeting"),
                  "https://teams.microsoft.com/dl/launcher/launcher.html?url=%2F_%23%2Fl%2Fmeetup-join%2F19%3Ameeting_ZmFh%2540thread.v2%2F0%3Fcontext%3D%257b%257d&type=meetup-join",
                  "https://teams.microsoft.com/v2/?meetingjoin=true#/l/meetup-join/19:meeting_ZmFh@thread.v2/0?context=%7b%7d&anon=true",
                  "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_ZmFh%2540thread.v2%2F0&data=1"] {
            XCTAssertEqual(code(s), expected, s)
        }
        XCTAssertEqual(code("https://teams.microsoft.com/meet/2345678901234?p=abc"), "teams:meet/2345678901234")
        XCTAssertEqual(code("https://teams.live.com/meet/2345678901234?p=abc"), "teams:meet/2345678901234")
        XCTAssertNil(code("https://teams.microsoft.com/v2/"))
    }

    func testOtherServicesAndNonConference() {
        XCTAssertEqual(code("https://acme.webex.com/acme/j.php?MTID=m0123ABCD"), "webex:mtid/m0123abcd")
        XCTAssertEqual(code("https://acme.webex.com/meet/jdoe"), "webex:acme/jdoe")
        XCTAssertEqual(code("https://facetime.apple.com/join#v=1&p=AbCdEf123&k=xyz"), "facetime:AbCdEf123")
        XCTAssertNil(code("https://example.com/j/85012345678"))
        XCTAssertNil(code("https://docs.google.com/document/d/abc-defg-hij"))
    }
}

final class CalendarLabelTests: XCTestCase {
    let e = event("a", at(10, 0), at(10, 30))

    private func label(_ now: Date, _ ev: UpcomingEvent? = nil) -> String { CalendarText.relativeLabel(ev ?? e, now: now) }

    func testBeforeStart() {
        XCTAssertEqual(label(at(9, 55)), "in 5 min")
        XCTAssertEqual(label(at(9, 55, 30)), "in 5 min")          // rounds up
        XCTAssertEqual(label(at(9, 54, 59)), "in 6 min")
        XCTAssertEqual(label(at(9, 59)), "in 1 min")
        XCTAssertEqual(label(at(8, 40)), "in 1 h 20 min")
        XCTAssertEqual(label(at(9, 0)), "in 1 h")
        XCTAssertEqual(label(at(9, 0, 30)), "in 1 h")            // 59.5 min → 60 → "1 h", never "60 min"
        XCTAssertEqual(label(at(9, 1)), "in 59 min")
    }

    func testAroundStart() {
        XCTAssertEqual(label(at(9, 59, 1)), "Starting now")
        XCTAssertEqual(label(at(10, 0)), "Starting now")
        XCTAssertEqual(label(at(10, 0, 59)), "Starting now")
        XCTAssertEqual(label(at(10, 1)), "29 min left")
    }

    func testInProgressAndEnding() {
        XCTAssertEqual(label(at(10, 10)), "20 min left")
        XCTAssertEqual(label(at(10, 24, 59)), "6 min left")
        XCTAssertEqual(label(at(10, 25)), "Ending soon")
        XCTAssertEqual(label(at(10, 29, 59)), "Ending soon")
        XCTAssertEqual(label(at(10, 30), event("b", at(10, 0), at(12, 0))), "1 h 30 min left")
    }

    func testAfterEnd() {
        XCTAssertEqual(label(at(10, 30)), "1 min ago")
        XCTAssertEqual(label(at(10, 42)), "12 min ago")
        XCTAssertEqual(label(at(10, 42, 59)), "12 min ago")
        XCTAssertEqual(label(at(12, 30)), "2 h ago")
        XCTAssertEqual(label(at(9, 0), event("d", at(0, 0), at(0, 0, day: 1), allDay: true)), "All day")
    }

    func testTimeFormatting() {
        XCTAssertEqual(CalendarText.time(at(15, 0), calendar: utc, locale: enUS), "3:00 PM")
        XCTAssertEqual(CalendarText.timeRange(e, calendar: utc, locale: enUS), "10:00 – 10:30 AM")
    }
}

final class MenuBarTitleTests: XCTestCase {
    private func title(_ e: UpcomingEvent?, _ now: Date) -> String? {
        title(e.map { [$0] } ?? [], now)
    }

    private func title(_ events: [UpcomingEvent], _ now: Date) -> String? {
        CalendarText.menuBarTitle(events: events, now: now, calendar: utc, locale: enUS)
    }

    func testNoRoomAtAllGivesAnEllipsisRatherThanACrash() {
        let soon = event("a", at(10, 5), at(10, 30), title: "Standup"), later = event("b", at(15, 0), at(16, 0))
        for n in [0, -3, 1] {
            XCTAssertEqual(CalendarText.menuBarTitle(events: [soon], now: at(10, 0), maxLength: n, calendar: utc, locale: enUS), "…")
            XCTAssertEqual(CalendarText.menuBarTitle(events: [later], now: at(10, 0), maxLength: n, calendar: utc, locale: enUS), "…")
        }
    }

    func testStates() {
        let standup = event("s", at(15, 0), at(15, 30), title: "Standup")
        XCTAssertNil(title(nil, at(9, 0)))
        XCTAssertEqual(title(standup, at(14, 55)), "Standup • in 5 min")
        XCTAssertEqual(title(standup, at(14, 55, 30)), "Standup • in 4 min")          // whole minutes, rounded down
        XCTAssertEqual(title(standup, at(14, 59)), "Standup • in 1 min")
        XCTAssertEqual(title(standup, at(14, 59, 30)), "Standup • now")               // under a minute
        XCTAssertEqual(title(standup, at(15, 7)), "Standup • 23m left")
        XCTAssertEqual(title(standup, at(15, 7, 40)), "Standup • 23m left")           // counted from the minute
        XCTAssertEqual(title(event("l", at(15, 0), at(17, 0), title: "Offsite"), at(15, 55)), "Offsite • 1h 5m left")
        XCTAssertEqual(title(event("l", at(15, 0), at(18, 0), title: "Offsite"), at(16, 0)), "Offsite • 2 hr left")
        XCTAssertEqual(title(standup, at(14, 0)), "Standup • in 1 hr")                // exactly an hour: still counts down
        XCTAssertEqual(title(standup, at(13, 59)), "Free until 3:00 PM")
        XCTAssertNil(title(standup, at(15, 30)))                                          // over
        XCTAssertNil(title(event("d", at(0, 0), at(0, 0, day: 1), allDay: true), at(12, 0)))
        XCTAssertNil(title(event("x", at(15, 0), at(15, 30), status: .declined), at(14, 55)))
        XCTAssertNil(title(event("z", at(15, 0), at(15, 0)), at(14, 55)))                 // zero length
        XCTAssertEqual(title(event("n", at(15, 0), at(15, 30), title: "  "), at(14, 55)), "(No title) • in 5 min")
    }

    /// The menu bar refreshes 0.05–0.25 s after each minute boundary: minutes are rounded down from there
    /// (E-ui G2), so the last minute reads "now" and ten minutes before reads "in 9 min" (R5-5).
    func testCountdownOnTheMinuteTick() {
        let standup = event("s", at(15, 0), at(15, 30), title: "Standup")
        func tick(_ h: Int, _ m: Int, _ late: TimeInterval) -> Date { at(h, m).addingTimeInterval(late) }
        XCTAssertEqual(title(standup, tick(14, 59, 0.1)), "Standup • now")
        XCTAssertEqual(title(standup, tick(14, 59, 0.05)), "Standup • now")
        XCTAssertEqual(title(standup, tick(14, 58, 0.25)), "Standup • in 1 min")
        XCTAssertEqual(title(standup, tick(14, 50, 0.05)), "Standup • in 9 min")
        XCTAssertEqual(title(standup, tick(14, 0, 0.1)), "Standup • in 59 min")
        XCTAssertEqual(title(standup, tick(13, 59, 0.1)), "Free until 3:00 PM")
        XCTAssertEqual(title(standup, tick(15, 7, 0.2)), "Standup • 23m left")
        XCTAssertEqual(title(standup, tick(15, 14, 0.1)), "Standup • 16m left")
        // Upcoming within ten minutes takes over from a meeting in progress on the same rule.
        let running = event("r", at(14, 0), at(15, 0), title: "Planning")
        let next = event("n", at(14, 30), at(15, 0), title: "Sync")
        XCTAssertEqual(title([running, next], tick(14, 20, 0.1)), "Sync • in 9 min")
        XCTAssertEqual(title([running, next], tick(14, 19, 0.1)), "Planning • 41m left")   // 10 min 59.9 s away
        XCTAssertEqual(title([running, next], tick(14, 29, 0.1)), "Sync • now")
        let workshop = event("w", at(12, 0), at(15, 0), title: "Workshop")
        XCTAssertEqual(title([workshop, event("b", at(15, 0, 30), at(15, 30), title: "1:1")], tick(13, 40, 0.1)), "1:1 • in 1h 20m")
    }

    func testFreeUntilNextDayHasWeekdayOnlyBeyondADay() {
        let tomorrowMorning = event("t", at(9, 0, day: 1), at(9, 30, day: 1))
        XCTAssertEqual(title(tomorrowMorning, at(18, 0)), "Free until 9:00 AM")          // 15 h away
        XCTAssertEqual(title(tomorrowMorning, at(8, 0)), "Free until Fri 9:00 AM")      // 25 h away
    }

    func testUpcomingWithinTenMinutesBeatsRunning() {
        let running = event("r", at(14, 0), at(15, 0), title: "Planning")
        let next = event("n", at(14, 30), at(15, 0), title: "Standup")
        XCTAssertEqual(title([running, next], at(14, 19)), "Planning • 41m left")        // next is 11 min away
        XCTAssertEqual(title([running, next], at(14, 20)), "Standup • in 10 min")
        XCTAssertEqual(title([running, next], at(14, 29, 30)), "Standup • now")
    }

    func testRunningUntilMidpointThenFree() {
        let review = event("r", at(14, 0), at(15, 0), title: "Review")
        let later = event("l", at(16, 0), at(16, 30), title: "Sync")
        XCTAssertEqual(title([review, later], at(14, 29)), "Review • 31m left")
        XCTAssertEqual(title([review, later], at(14, 30)), "Free from 3:00 – 4:00 PM")    // half over
        XCTAssertEqual(title([review], at(14, 30)), "Free after 3:00 PM")
        XCTAssertEqual(title([review, event("t", at(9, 0, day: 1), at(10, 0, day: 1))], at(14, 30)), "Free after 3:00 PM")
        // Back to back: the next meeting starts within a minute of the end.
        XCTAssertEqual(title([review, event("b", at(15, 0), at(15, 30), title: "1:1")], at(14, 40)), "1:1 • in 20 min")
        let workshop = event("w", at(12, 0), at(15, 0), title: "Workshop")
        XCTAssertEqual(title([workshop, event("b", at(15, 0, 30), at(15, 30), title: "1:1")], at(13, 40)), "1:1 • in 1h 20m")
    }

    func testFreeFromUsesTheLatestEndOfEverythingRunning() {
        let a = event("a", at(14, 0), at(14, 40), title: "Short")
        let b = event("b", at(13, 0), at(15, 0), title: "Long")
        let c = event("c", at(16, 0), at(16, 30))
        // "Short" started last (the current one) and is past its midpoint; "Long" runs until 3.
        XCTAssertEqual(title([a, b, c], at(14, 25)), "Free from 3:00 – 4:00 PM")
        XCTAssertEqual(title([a, b, c], at(14, 10)), "Short • 30m left")
    }

    func testFreeAfterAMeetingRunningPastMidnightShowsTheWeekday() {
        let late = event("n", at(18, 0), at(1, 0, day: 1), title: "Launch")
        XCTAssertEqual(title(late, at(22, 0)), "Free after Fri 1:00 AM")
    }

    func testMeetingsStartingTogether() {
        let a = event("a", at(15, 0), at(15, 30)), b = event("b", at(15, 0), at(16, 0))
        XCTAssertEqual(title([a, b], at(14, 55)), "2 meetings • in 5 min")
        XCTAssertEqual(title([a, b], at(15, 5)), "2 meetings • 25m left")               // the one ending first
    }

    func testTruncatesTitleToThirtyCharacters() {
        let long = event("q", at(15, 0), at(16, 0), title: "Quarterly business review with the leadership team")
        let t = title(long, at(14, 55))
        XCTAssertEqual(t, "Quarterly business… • in 5 min")
        XCTAssertEqual(t?.count, 30)
        // Exactly fits: no ellipsis.
        let fits = event("f", at(15, 0), at(16, 0), title: String(repeating: "x", count: 19))
        XCTAssertEqual(title(fits, at(14, 55)), String(repeating: "x", count: 19) + " • in 5 min")
        for (name, now) in [("A very long meeting title that goes on", at(15, 10)), ("Short", at(14, 1)),
                            ("Emoji 🎉🎉🎉 planning session for Q4 launch", at(14, 30))] {
            let r = title(event("x", at(15, 0), at(16, 0), title: name), now)!
            XCTAssertLessThanOrEqual(r.count, 30, r)
            XCTAssertTrue(r.contains(" • "), r)
        }
        XCTAssertEqual(title(event("w", at(15, 0), at(16, 0), title: "Weekly sync with design and engineering"), at(15, 10)),
                       "Weekly sync with d… • 50m left")
        let free = title([event("r", at(14, 0), at(15, 0)), event("l", at(16, 0), at(16, 30))], at(14, 30))
        XCTAssertLessThanOrEqual(free?.count ?? 99, 30)
    }
}

final class MenuSectionTests: XCTestCase {
    func testNowTodayTomorrowUpToThree() {
        let now = at(10, 0)
        let running = event("r", at(9, 30), at(10, 30)), soon = event("s", at(11, 0), at(11, 30))
        let later = event("l", at(15, 0), at(16, 0)), tomorrow = event("t", at(9, 0, day: 1), at(9, 30, day: 1))
        let ended = event("e", at(8, 0), at(9, 0)), declined = event("x", at(12, 0), at(13, 0), status: .declined)
        let allDay = event("d", at(0, 0), at(0, 0, day: 1), allDay: true)
        let all = [tomorrow, later, soon, running, ended, declined, allDay]
        let sections = CalendarSchedule.menuSections(all, now: now, calendar: utc)
        XCTAssertEqual(sections.map(\.title), ["Now", "Today"])
        XCTAssertEqual(sections.flatMap { $0.events.map(\.id) }, ["r", "s", "l"])
        let evening = CalendarSchedule.menuSections(all, now: at(15, 30), calendar: utc)
        XCTAssertEqual(evening.map(\.title), ["Now", "Tomorrow"])
        XCTAssertEqual(evening.flatMap { $0.events.map(\.id) }, ["l", "t"])
        XCTAssertTrue(CalendarSchedule.menuSections([ended], now: now, calendar: utc).isEmpty)
    }

    func testJoinableNowNeedsALinkAndToBeInProgress() {
        let plain = event("p", at(9, 0), at(11, 0))
        let zoom = event("z", at(9, 30), at(10, 30), url: "https://zoom.us/j/123456789")
        let upcoming = event("u", at(10, 5), at(11, 0), url: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(CalendarSchedule.joinableNow([upcoming, plain, zoom], now: at(10, 0))?.id, "z")
        XCTAssertNil(CalendarSchedule.joinableNow([upcoming, plain], now: at(10, 0)))
    }

    func testNoteTime() {
        func t(_ d: Date) -> String { CalendarText.noteTime(d, now: at(16, 0), calendar: utc, locale: enUS) }
        XCTAssertEqual(t(at(15, 4)), "3:04 PM")
        XCTAssertEqual(t(at(9, 30, day: -1)), "Yesterday, 9:30 AM")
        XCTAssertEqual(t(at(9, 30, day: -3)), "Oct 13, 9:30 AM")
        XCTAssertEqual(t(at(9, 30, day: -300)), "Dec 20, 2024, 9:30 AM")
    }
}

final class CalendarMatcherTests: XCTestCase {
    let zoomA = event("a", at(10, 0), at(10, 30), url: "https://us02web.zoom.us/j/111111111?pwd=x")
    let meetB = event("b", at(10, 0), at(11, 0), url: "https://meet.google.com/abc-defg-hij")
    let meetC = event("c", at(10, 0, day: 1), at(11, 0, day: 1), url: "https://meet.google.com/abc-defg-hij")
    let zoomD = event("d", at(10, 15), at(10, 45), url: "https://zoom.us/j/222222222")
    let teamsE = event("e", at(13, 0), at(14, 0), url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_T%40thread.v2/0")
    var all: [UpcomingEvent] { [zoomA, meetB, meetC, zoomD, teamsE] }

    private func m(_ t: Date, url: String? = nil, bundle: String? = nil, intent: String? = nil, intentAt: Date? = nil,
                   events: [UpcomingEvent]? = nil) -> CalendarMatcher.Match? {
        CalendarMatcher.matchDetailed(recordingStart: t, callURL: url.flatMap(URL.init(string:)), bundleID: bundle,
                                      userIntentEventID: intent, userIntentAt: intentAt, events: events ?? all)
    }

    func testUserIntentWinsWithinTTL() {
        let r = m(at(10, 5), url: "https://meet.google.com/abc-defg-hij", intent: zoomA.id, intentAt: at(10, 4))
        XCTAssertEqual(r?.event.id, "a"); XCTAssertEqual(r?.type, .userIntent)
        // Stale intent (> 120 s) falls through to the meeting code.
        let stale = m(at(10, 5), url: "https://meet.google.com/abc-defg-hij", intent: zoomA.id, intentAt: at(10, 2, 59))
        XCTAssertEqual(stale?.event.id, "b"); XCTAssertEqual(stale?.type, .meetingCode)
        // Unknown intent falls through; external IDs work too.
        XCTAssertEqual(m(at(10, 5), url: "https://meet.google.com/abc-defg-hij", intent: "gone")?.event.id, "b")
        XCTAssertEqual(m(at(10, 5), intent: "ext-d")?.event.id, "d")
        XCTAssertEqual(CalendarMatcher.match(recordingStart: at(10, 5), callURL: nil, bundleID: nil,
                                             userIntentEventID: "e", events: all)?.id, "e")
    }

    func testSeriesIntentTakesTheOccurrenceNearestTheRecording() {
        var today = event("s1", at(10, 0), at(11, 0)), tomorrow = event("s2", at(10, 0, day: 1), at(11, 0, day: 1))
        today.externalID = "series"; tomorrow.externalID = "series"
        XCTAssertEqual(m(at(9, 58, day: 1), intent: "series", intentAt: at(9, 57, day: 1), events: [today, tomorrow])?.event.id, "s2")
        XCTAssertEqual(m(at(10, 5), intent: "series", intentAt: at(10, 4), events: [tomorrow, today])?.event.id, "s1")
    }

    func testMeetingCodePrefersInProgressThenClosest() {
        XCTAssertEqual(m(at(10, 5), url: "https://meet.google.com/abc-defg-hij?authuser=0")?.event.id, "b")
        XCTAssertEqual(m(at(9, 58, day: 1), url: "https://meet.google.com/abc-defg-hij")?.event.id, "c")
        // No time bound: hours before the event still matches.
        XCTAssertEqual(m(at(7, 0), url: "https://teams.microsoft.com/v2/?meetingjoin=true#/l/meetup-join/19:meeting_T@thread.v2/0")?.event.id, "e")
        XCTAssertNil(m(at(10, 5), url: "https://meet.google.com/zzz-zzzz-zzz"))
        // Code beats the Zoom time window.
        let r = m(at(10, 5), url: "https://app.zoom.us/wc/222222222/join", bundle: "us.zoom.xos")
        XCTAssertEqual(r?.event.id, "d"); XCTAssertEqual(r?.type, .meetingCode)
    }

    func testNativeZoomTimeWindow() {
        let r = m(at(10, 0, 30), bundle: "us.zoom.xos")
        XCTAssertEqual(r?.event.id, "a"); XCTAssertEqual(r?.type, .timeWindow)
        XCTAssertEqual(m(at(9, 59), bundle: "US.ZOOM.XOS")?.event.id, "a")      // start - 60 s
        XCTAssertNil(m(at(9, 58, 59), bundle: "us.zoom.xos"))
        XCTAssertNil(m(at(10, 20), bundle: "us.zoom.xos"))                      // A and D both running: ambiguous
        XCTAssertEqual(m(at(10, 31), bundle: "us.zoom.xos")?.event.id, "d")     // A within +60 s, only D running
        XCTAssertNil(m(at(10, 0, 30), bundle: "com.google.chrome"))             // browsers need a code
        XCTAssertNil(m(at(13, 5), bundle: "com.microsoft.teams2"))              // Teams is never matched by time
        // A declined Zoom event is not a candidate.
        let declined = event("x", at(10, 15), at(10, 45), url: "https://zoom.us/j/333333333", status: .declined)
        XCTAssertEqual(m(at(10, 20), bundle: "us.zoom.xos", events: [zoomA, declined])?.event.id, "a")
    }
}

final class CalendarScheduleTests: XCTestCase {
    func testConflictGroups() {
        let a = event("a", at(10, 0), at(10, 30)), b = event("b", at(10, 0), at(11, 0)), d = event("d", at(10, 15), at(10, 45))
        let f = event("f", at(11, 0), at(11, 30))                              // touches b: no conflict
        let g = event("g", at(12, 0), at(13, 0)), h = event("h", at(12, 30), at(12, 45))
        let i = event("i", at(14, 0), at(15, 0), status: .declined), j = event("j", at(14, 30), at(15, 0))
        let k = event("k", at(0, 0), at(0, 0, day: 1), allDay: true)
        let all = [h, f, a, j, k, i, g, d, b]
        XCTAssertEqual(CalendarSchedule.conflictGroups(all).map { $0.map(\.id) }, [["a", "b", "d"], ["g", "h"]])
        XCTAssertEqual(CalendarSchedule.conflictingIDs(all), ["a", "b", "d", "g", "h"])
        XCTAssertTrue(CalendarSchedule.conflictGroups([a, f]).isEmpty)
        XCTAssertTrue(CalendarText.conflicts(d, in: all))
        XCTAssertFalse(CalendarText.conflicts(f, in: all))
        XCTAssertFalse(CalendarText.conflicts(j, in: all))                    // only overlaps a declined event
        XCTAssertFalse(CalendarText.conflicts(i, in: all))                    // declined itself
        XCTAssertFalse(CalendarText.conflicts(a, in: [a]))
    }

    func testDaysGrouping() {
        let now = at(10, 0)
        let overnight = event("o", at(23, 30, day: -1), at(10, 30))
        let yesterday = event("y", at(9, 0, day: -1), at(9, 30, day: -1))
        let today = event("t", at(14, 0), at(15, 0)), tomorrow = event("m", at(9, 0, day: 1), at(9, 30, day: 1))
        let saturday = event("s", at(9, 0, day: 2), at(10, 0, day: 2))
        let days = CalendarSchedule.days([saturday, today, tomorrow, overnight, yesterday], now: now, calendar: utc, locale: enUS)
        XCTAssertEqual(days.map(\.title), ["Yesterday", "Today", "Tomorrow", "Saturday, Oct 18"])
        XCTAssertEqual(days[1].events.map(\.id), ["o", "t"])
    }

    func testVisibleFiltersAndSorts() {
        let a = event("a", at(11, 0), at(12, 0)), b = event("b", at(9, 0), at(10, 0))
        let declined = event("c", at(10, 0), at(11, 0), status: .declined)
        let allDay = event("d", at(0, 0), at(0, 0, day: 1), allDay: true)
        XCTAssertEqual(CalendarSchedule.visible([a, declined, allDay, b]).map(\.id), ["b", "a"])
        XCTAssertEqual(CalendarSchedule.visible([a, declined, allDay, b], includeAllDay: true, includeDeclined: true).map(\.id),
                       ["d", "b", "c", "a"])
    }

    func testNextEvent() {
        let running = event("r", at(10, 0), at(10, 30)), soon = event("s", at(10, 27), at(11, 0))
        let later = event("l", at(13, 0), at(14, 0)), declined = event("x", at(11, 30), at(12, 0), status: .declined)
        let all = [later, soon, running, declined]
        XCTAssertEqual(CalendarSchedule.next(in: all, now: at(10, 10))?.id, "r")
        XCTAssertEqual(CalendarSchedule.next(in: all, now: at(10, 23))?.id, "s")   // starts within 5 min
        XCTAssertEqual(CalendarSchedule.next(in: [later, declined], now: at(11, 0))?.id, "l")
        XCTAssertNil(CalendarSchedule.next(in: all, now: at(14, 0)))
    }

    func testReminders() {
        let e = event("e", at(10, 0), at(10, 30))
        let declined = event("x", at(10, 0), at(10, 30), status: .declined)
        let allDay = event("d", at(0, 0), at(0, 0, day: 1), allDay: true)
        let all = [e, declined, allDay]
        func due(_ now: Date, _ notified: Set<String> = []) -> [String] {
            CalendarSchedule.dueReminders(in: all, now: now, lead: 15, notified: notified).map(\.id)
        }
        XCTAssertEqual(due(at(9, 59, 44)), [])
        XCTAssertEqual(due(at(9, 59, 45)), ["e"])
        XCTAssertEqual(due(at(9, 59, 50), ["e"]), [])                               // once per occurrence
        XCTAssertEqual(due(at(10, 4, 59)), ["e"])                                   // late after sleep/launch
        XCTAssertEqual(due(at(10, 5)), [])
        XCTAssertEqual(CalendarSchedule.nextReminderDate(in: all, now: at(9, 0), lead: 15, notified: []), at(9, 59, 45))
        XCTAssertNil(CalendarSchedule.nextReminderDate(in: all, now: at(9, 0), lead: 15, notified: ["e"]))
        let two = [e, event("f", at(9, 30), at(9, 45))]
        XCTAssertEqual(CalendarSchedule.nextReminderDate(in: two, now: at(9, 0), lead: 120, notified: []), at(9, 28))
    }

    func testHelpers() {
        XCTAssertEqual(UpcomingEvent.makeID(eventIdentifier: "ABC:123", occurrenceStart: Date(timeIntervalSince1970: 1_760_608_800.4)),
                       "ABC:123@1760608800")
        XCTAssertEqual(CalendarText.participantName(name: " Jane Doe ", url: URL(string: "mailto:jane@example.com")), "Jane Doe")
        XCTAssertEqual(CalendarText.participantName(name: nil, url: URL(string: "mailto:jane@example.com")), "jane@example.com")
        XCTAssertEqual(CalendarText.participantName(name: "", url: URL(string: "mailto:a%2Bb@example.com?subject=x")), "a+b@example.com")
        XCTAssertNil(CalendarText.participantName(name: nil, url: URL(string: "urn:uuid:1234")))
        XCTAssertEqual(CalendarText.hexColor(red: 1, green: 0.5, blue: 0), "#FF8000")
        XCTAssertEqual(CalendarText.hexColor(red: -1, green: 2, blue: 0.2), "#00FF33")
    }
}
