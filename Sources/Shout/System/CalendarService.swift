import AppKit
import EventKit
import Security
import ShoutKit

/// Upcoming meetings from macOS Calendar (EventKit: every account added to Calendar.app, read locally).
///
/// Never prompts on its own: an `EKEventStore` is only created once access is granted, or inside `requestAccess()`.
/// Without access, `events` stays empty and reminders never fire.
@MainActor
final class CalendarService: ObservableObject {
    enum Access: Equatable {
        case notDetermined, granted, denied, restricted
        /// The user allowed adding events only; the app cannot read them.
        case writeOnly
    }

    static let shared = CalendarService()

    @Published private(set) var access: Access
    /// Occurrences from 2 h ago to the end of tomorrow, sorted by start. All-day and declined events are left out
    /// unless `includeAllDay` / `includeDeclined` are set.
    @Published private(set) var events: [UpcomingEvent] = []

    var includeAllDay = false { didSet { if includeAllDay != oldValue { refresh() } } }
    var includeDeclined = false { didSet { if includeDeclined != oldValue { refresh() } } }

    /// Called once per occurrence, `lead` seconds before it starts (see `scheduleReminders`).
    var onReminder: ((UpcomingEvent) -> Void)?
    private(set) var reminderLead: TimeInterval?

    /// The event in progress or the next one to start (an event starting within 5 min wins over one in progress).
    var nextEvent: UpcomingEvent? { CalendarSchedule.next(in: events, now: Date()) }

    /// Menu-bar text ("Title • in 5 min", "Title • 23m left", "Free until 3:00 PM"), or nil.
    var menuBarTitle: String? { CalendarText.menuBarTitle(events: events, now: Date()) }

    private var store: EKEventStore?
    private var reminderTimer: Timer?
    /// Occurrence IDs already reminded about, with their start (for pruning).
    private var notified: [String: Date] = [:]
    private let lifetime = Lifetime()
    /// Snapshot mode: `events` are fixed (see `preview`), so `refresh` leaves them alone.
    private var previewing = false
    /// A notification-driven refresh is scheduled (see `refreshSoon`).
    private var refreshPending = false

    /// One instance (`shared`): each one adds its own timers, observers and reminders.
    private init() {
        access = Self.currentAccess()
        let nc = NotificationCenter.default, ws = NSWorkspace.shared.notificationCenter
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            lifetime.observe(nc, name) { [weak self] in self?.refreshSoon() }
        }
        lifetime.observe(ws, NSWorkspace.didWakeNotification) { [weak self] in self?.refreshSoon() }
        let tick = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        tick.tolerance = 5
        RunLoop.main.add(tick, forMode: .common)
        lifetime.timers.append(tick)
        refresh()
    }

    // MARK: Access

    static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Why asking for access would fail or crash in this build, or nil. The prompt needs the Info.plist usage string,
    /// and under the hardened runtime tccd also requires the calendars entitlement.
    static var setupProblem: String? {
        if Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") == nil {
            return "Info.plist has no NSCalendarsFullAccessUsageDescription"
        }
        if hasHardenedRuntime && !hasEntitlement("com.apple.security.personal-information.calendars") {
            return "Signed with the hardened runtime but without com.apple.security.personal-information.calendars"
        }
        return nil
    }

    /// Shows the system prompt (first time only; afterwards it just reports the stored answer). Only call this from a
    /// user action such as "Connect calendar".
    func requestAccess() async -> Bool {
        if let problem = Self.setupProblem {
            NSLog("Shout calendar: not requesting access: \(problem)")
            return false
        }
        var granted = false
        do { granted = try await EKEventStore().requestFullAccessToEvents() } catch {
            NSLog("Shout calendar: access request failed: \(error.localizedDescription)")
        }
        // A store created before the grant can keep seeing no calendars; start from a fresh one.
        closeStore()
        refresh()
        return granted && access == .granted
    }

    /// Privacy & Security → Calendars, for when access was denied or is write-only.
    func openSettings() { Permissions.openPrivacyPane("Privacy_Calendars") }

    // MARK: Events

    /// Shows fixed events and access instead of the real calendar (snapshot mode only); nil goes back to it.
    func preview(events: [UpcomingEvent]?, access: Access = .granted) {
        guard SnapshotMode.active else { return }
        previewing = events != nil
        if let events {
            self.access = access
            self.events = access == .granted ? events : []
        } else {
            refresh()
        }
    }

    /// Re-reads authorization and events. Cheap; runs every minute, on store changes, day change and wake.
    func refresh() {
        guard !previewing else { return }
        let a = Self.currentAccess()
        if a != access { access = a }
        guard a == .granted else {
            closeStore()
            if !events.isEmpty { events = [] }
            rescheduleReminders()
            return
        }
        let store = openStore()
        let now = Date(), cal = Calendar.current
        let from = now.addingTimeInterval(-2 * 3600)
        let to = cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(48 * 3600)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let mapped = store.events(matching: predicate).compactMap(Self.upcomingEvent)
        let fresh = CalendarSchedule.visible(mapped, includeAllDay: includeAllDay, includeDeclined: includeDeclined)
        if fresh != events { events = fresh }
        rescheduleReminders()
    }

    /// `refresh` half a second from now, once for a burst of notifications (`EKEventStoreChanged` arrives in
    /// bursts while accounts sync, and each refresh queries every calendar on the main thread).
    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshPending = false
                self?.refresh()
            }
        }
    }

    private func openStore() -> EKEventStore {
        if let store { return store }
        let s = EKEventStore()
        store = s
        return s
    }

    private func closeStore() { store = nil }

    /// EKEvent → UpcomingEvent. Cancelled events are dropped.
    static func upcomingEvent(_ e: EKEvent) -> UpcomingEvent? {
        guard e.status != .canceled, let start = e.startDate as Date?, let end = e.endDate as Date? else { return nil }
        let identifier = (e.eventIdentifier as String?) ?? e.calendarItemIdentifier
        let occurrence = (e.occurrenceDate as Date?) ?? start
        let external = (e.calendarItemExternalIdentifier as String?).flatMap { $0.isEmpty ? nil : $0 } ?? identifier
        let location = e.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpcomingEvent(
            id: UpcomingEvent.makeID(eventIdentifier: identifier, occurrenceStart: occurrence),
            externalID: external,
            occurrenceStart: occurrence,
            title: e.title ?? "",
            start: start, end: end, isAllDay: e.isAllDay,
            location: location?.isEmpty == false ? location : nil,
            conferenceURL: CalendarText.conferenceURL(location: e.location, url: e.url, notes: e.notes),
            attendees: attendeeNames(e),
            colorHex: hex(e.calendar?.color),
            myStatus: myStatus(e),
            calendarTitle: e.calendar?.title)
    }

    /// Organizer first, then attendees; people only (no rooms/resources), without the current user, deduplicated.
    private static func attendeeNames(_ e: EKEvent) -> [String] {
        var people: [EKParticipant] = []
        if let o = e.organizer { people.append(o) }
        people += e.attendees ?? []
        var seen = Set<String>(), names: [String] = []
        for p in people where !p.isCurrentUser && p.participantType != .room && p.participantType != .resource {
            guard seen.insert(p.url.absoluteString.lowercased()).inserted,
                  let name = CalendarText.participantName(name: p.name, url: p.url) else { continue }
            names.append(name)
        }
        return names
    }

    private static func myStatus(_ e: EKEvent) -> UpcomingEvent.Response {
        if e.organizer?.isCurrentUser == true { return .accepted }
        guard let me = e.attendees?.first(where: { $0.isCurrentUser }) else { return .none }
        switch me.participantStatus {
        case .accepted: return .accepted
        case .tentative: return .tentative
        case .declined: return .declined
        default: return .none
        }
    }

    private static func hex(_ color: NSColor?) -> String? {
        guard let c = color?.usingColorSpace(.sRGB) else { return nil }
        return CalendarText.hexColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
    }

    // MARK: Reminders

    /// Fires `onReminder` `lead` seconds before each event starts, once per occurrence; declined events are skipped.
    /// A reminder missed while asleep is still delivered up to 5 min after the start. nil = never.
    func scheduleReminders(lead: TimeInterval?) {
        reminderLead = lead
        rescheduleReminders()
    }

    private func rescheduleReminders() {
        reminderTimer?.invalidate()
        reminderTimer = nil
        let now = Date()
        notified = notified.filter { $0.value > now.addingTimeInterval(-86_400) }
        guard let lead = reminderLead, access == .granted else { return }
        let seen = Set(notified.keys)
        for e in CalendarSchedule.dueReminders(in: events, now: now, lead: lead, notified: seen) {
            notified[e.id] = e.start
            onReminder?(e)
        }
        guard let due = CalendarSchedule.nextReminderDate(in: events, now: now, lead: lead, notified: Set(notified.keys)) else { return }
        let t = Timer(fire: max(due, now.addingTimeInterval(0.25)), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rescheduleReminders() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        reminderTimer = t
        lifetime.reminder = t
    }

    // MARK: Code signing checks

    private static var hasHardenedRuntime: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let flags = dict[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return flags.uint32Value & SecCodeSignatureFlags.runtime.rawValue != 0
    }

    private static func hasEntitlement(_ name: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return (SecTaskCopyValueForEntitlement(task, name as CFString, nil) as? Bool) == true
    }
}

/// Owns timers and observers so they are torn down with the service (deinit of a @MainActor class can't touch them).
private final class Lifetime {
    var timers: [Timer] = []
    var reminder: Timer?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        tokens.append((center, token))
    }

    deinit {
        timers.forEach { $0.invalidate() }
        reminder?.invalidate()
        tokens.forEach { $0.0.removeObserver($0.1) }
    }
}
