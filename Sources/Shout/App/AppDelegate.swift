import AppKit
import SwiftUI
import Combine
import ShoutKit

/// Navigation state shared by the main window.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    enum Page: String, CaseIterable, Identifiable {
        case home, scribe, tasks, history, dictionary, snippets, prompts, style, notes, models, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home: "Home"; case .scribe: "Scribe"; case .tasks: "My Tasks"; case .history: "History"
            case .dictionary: "Dictionary"; case .snippets: "Snippets"; case .prompts: "Prompts"
            case .style: "Style"; case .notes: "Notes"; case .models: "Models"; case .settings: "Settings"
            }
        }
        var symbol: String {
            switch self {
            case .home: "house"; case .scribe: "record.circle"; case .tasks: "checklist"; case .history: "clock.arrow.circlepath"
            case .dictionary: "character.book.closed"
            case .snippets: "text.badge.plus"; case .prompts: "wand.and.rays"; case .style: "paintbrush"; case .notes: "note.text"
            case .models: "cpu"; case .settings: "gearshape"
            }
        }
    }
    @Published var page: Page = .home
    @Published var showOnboarding = false
    /// The meeting open on the Scribe page (nil shows the list).
    @Published var meetingID: String?
    /// The tab the next meeting opened on the Scribe page should show (e.g. Tasks from My Tasks); the meeting
    /// view takes it and sets it back to nil.
    @Published var meetingTab: MeetingDetailView.Tab?
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General", scribe = "Scribe"
        var id: String { rawValue }
    }
    @Published var settingsTab: SettingsTab = .general

    /// Shows a meeting on the Scribe page, optionally on a given tab.
    func openMeeting(_ id: String, tab: MeetingDetailView.Tab? = nil) {
        page = .scribe
        meetingTab = tab
        meetingID = id
    }
}

extension Notification.Name {
    /// Posted on the main thread before quitting: views with debounced edits save them now.
    static let shoutFlushEdits = Notification.Name("ShoutFlushEdits")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var flowBar: FlowBarController!
    private(set) var controller: DictationController!
    private(set) var scribe: ScribeController!
    private var notepad: NotepadWindowController!
    let notepadOpener = NotepadOpener()
    let calendar = CalendarService.shared
    let callDetector = CallDetector()
    private var statusItem: NSStatusItem!
    /// Built each time it opens (`menuNeedsUpdate`), so calendar rows and past notes are never stale.
    private var statusMenu: NSMenu?
    private var scribeMenu: NSMenu?
    /// The Scribe menu's New Note, whose ⌘N follows `newNoteKeyActive`.
    private weak var newNoteItem: NSMenuItem?
    private var menuBarTimer: Timer?
    private var mainWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var permissionTimer: Timer?
    private var hotkeysRunning = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore.shared
        applyActivationPolicy(settings.settings.showInDock)
        flowBar = FlowBarController()
        controller = DictationController(settingsStore: settings, store: Store.shared, hub: EngineHub.shared, flowBar: flowBar)
        controller.onOpenMainWindow = { [weak self] page in
            Task { @MainActor in self?.openMainWindow(page: page) }
        }
        scribe = ScribeController(settingsStore: settings, store: Store.shared, hub: EngineHub.shared, flowBar: flowBar)
        notepad = NotepadWindowController(scribe: scribe, opener: notepadOpener, calendar: calendar)
        notepadOpener.handler = { [weak self] id in self?.notepad.show(meetingID: id) }
        scribe.calendar = calendar
        if ScribeSelfTest.runIfRequested(scribe: scribe) { return }
        if !SnapshotMode.active { scribe.attach(detector: callDetector) }
        scribe.onOpenNotepad = { [weak self] id, activate in self?.notepad.show(meetingID: id, activate: activate) }
        controller.onMicrophoneWillStart = { [weak self] in self?.scribe.dictationWillStart() }
        controller.onMicrophoneDidStop = { [weak self] in self?.scribe.dictationDidEnd() }
        controller.isMeetingRecording = { [weak self] in self?.scribe.isRecording ?? false }
        scribe.isDictating = { [weak self] in self?.controller.session != nil }
        controller.onScribeToggle = { [weak self] in
            guard let self else { return }
            if self.scribe.isRecording { self.scribe.stop() } else { self.scribe.start() }
        }
        if Snapshots.runIfRequested(controller: controller, scribe: scribe, flowBar: flowBar,
                                    calendar: calendar, notepad: notepadOpener) { return }
        if SelfTest.runIfRequested() { return }
        if FocusReturnSelfTest.runIfRequested() { return }
        if ScreenshotSelfTest.runIfRequested() { return }
        if SelectionSelfTest.runIfRequested() { return }
        setUpStatusItem()
        setUpMainMenu()
        // New Note's ⌘N is on only while the Scribe page is the key window.
        Publishers.MergeMany(
            AppRouter.shared.$page.map { _ in () }.eraseToAnyPublisher(),
            AppRouter.shared.$showOnboarding.map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification).map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification).map { _ in () }.eraseToAnyPublisher())
            .receive(on: RunLoop.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refreshNewNoteKey() } }
            .store(in: &cancellables)

        settings.$settings
            .map(\.appearance).removeDuplicates()
            .sink { appearance in MainActor.assumeIsolated { Self.apply(appearance) } }
            .store(in: &cancellables)
        settings.$settings
            .map(\.showInDock).removeDuplicates().dropFirst()
            .sink { [weak self] show in Task { @MainActor in self?.applyActivationPolicy(show) } }
            .store(in: &cancellables)
        settings.$settings
            .map(\.launchAtLogin).removeDuplicates()
            .sink { LoginItem.set($0) }
            .store(in: &cancellables)
        Publishers.CombineLatest(flowBar.model.$phase.removeDuplicates(), scribe.$activeMeetingID.removeDuplicates())
            .sink { [weak self] phase, meeting in Task { @MainActor in self?.updateStatusIcon(phase, recordingMeeting: meeting != nil) } }
            .store(in: &cancellables)
        // "Your summary is ready" is only posted when the note isn't already in front of the user.
        scribe.isMeetingFrontmost = { [weak self] id in
            guard let self, NSApp.isActive else { return false }
            let router = AppRouter.shared
            return (router.page == .scribe && router.meetingID == id && self.mainWindow?.isKeyWindow == true)
                || (self.notepad.nsWindow?.isKeyWindow == true && self.notepad.meetingID == id)
        }
        settings.$settings.removeDuplicates()
            .sink { [weak self] s in Task { @MainActor in self?.scribe.applyDetectionSettings(s) } }
            .store(in: &cancellables)
        // "Hide Notepad and Flow Bar from screen sharing": the Notepad (and its sheets) whenever the setting is on,
        // since it shows the transcript and notes after the meeting too; the Flow Bar while a meeting is recorded.
        Publishers.CombineLatest(scribe.$activeMeetingID.map { $0 != nil }.removeDuplicates(),
                                 settings.$settings.map(\.scribeHideFromScreenCapture).removeDuplicates())
            .sink { [weak self] recording, hide in
                Task { @MainActor in
                    self?.flowBar.setHiddenFromCapture(recording && hide)
                    self?.notepad.hiddenFromCapture = hide
                }
            }
            .store(in: &cancellables)
        scribe.onSplitScreen = { [weak self] pid in
            guard let self, let window = self.notepad.nsWindow else { return }
            WindowArranger.split(meetingPID: pid, notepad: window)
        }
        // Calendar: reminders before meetings and the next meeting next to the menu bar icon.
        calendar.onReminder = { [weak self] event in self?.scribe.showReminder(event) }
        settings.$settings.map(\.scribeReminderLead).removeDuplicates()
            .sink { [weak self] lead in Task { @MainActor in self?.calendar.scheduleReminders(lead: lead.seconds) } }
            .store(in: &cancellables)
        Publishers.CombineLatest(calendar.$events, settings.$settings.map(\.scribeShowNextMeeting).removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in Task { @MainActor in self?.updateMenuBarMeeting() } }
            .store(in: &cancellables)
        scheduleMenuBarTick()
        // Finish meetings interrupted by a quit or crash once the speech model has had time to load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scribe.recoverInterrupted() }

        tryStartHotkeys()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tryStartHotkeys() }
        }
        pruneHistory()
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneHistory() }
        }

        if !settings.settings.hasCompletedOnboarding || !Permissions.shared.allGranted {
            AppRouter.shared.showOnboarding = !settings.settings.hasCompletedOnboarding
            openMainWindow(page: nil)
        }
    }

    @MainActor
    private func tryStartHotkeys() {
        // Polled until the tap starts, which can be the whole run: refresh (a tccd round trip, and a redraw of every
        // view watching Permissions) only when Accessibility changed.
        let trusted = AXIsProcessTrusted()
        if trusted != Permissions.shared.accessibility { Permissions.shared.refresh() }
        guard !hotkeysRunning, trusted else { return }
        hotkeysRunning = controller.startHotkeys()
        if hotkeysRunning { permissionTimer?.invalidate() }
    }

    @MainActor
    private func pruneHistory() {
        switch SettingsStore.shared.settings.retention {
        case .day: Store.shared.pruneHistory(olderThan: Date().addingTimeInterval(-86_400))
        case .never: Store.shared.deleteAllHistory()
        case .forever: break
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { openMainWindow(page: nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        nonisolated(unsafe) var menu: NSMenu?
        MainActor.assumeIsolated {
            let m = NSMenu()
            if scribe?.isRecording == true {
                m.addItem(item("Stop Scribe", #selector(stopScribe)))
                m.addItem(item("Show Notepad", #selector(showNotepad)))
            } else {
                m.addItem(item("Start Scribe", #selector(startScribe)))
            }
            m.addItem(item("Open Scribe", #selector(openScribe)))
            menu = m
        }
        return menu
    }

    /// Notes and titles typed in the last moments are saved (`applicationWillTerminate` exits without running
    /// pending tasks), and a meeting in progress is stopped cleanly (both tracks flushed) before quitting; anything
    /// not yet transcribed is finished at the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            NotificationCenter.default.post(name: .shoutFlushEdits, object: nil)
            scribe?.stopForQuit()
        }
        return .terminateNow
    }

    /// ggml's Metal backend asserts in its C++ static destructors if a model context is still alive
    /// (e.g. a model is mid-load). Settings and SQLite writes are already durable, so skip those
    /// destructors and exit directly.
    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
        _exit(0)
    }

    @MainActor
    /// Every Shout window follows it (nil: as macOS is set).
    static func apply(_ appearance: Appearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyActivationPolicy(_ showInDock: Bool) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // MARK: Main window

    @MainActor
    func openMainWindow(page: String?) {
        if let page {
            if page == "onboarding" { AppRouter.shared.showOnboarding = true }
            else if let p = AppRouter.Page(rawValue: page) { AppRouter.shared.page = p }
        }
        if mainWindow == nil {
            let root = MainView(controller: controller)
                .environmentObject(SettingsStore.shared)
                .environmentObject(Store.shared)
                .environmentObject(EngineHub.shared)
                .environmentObject(ModelManager.shared)
                .environmentObject(Permissions.shared)
                .environmentObject(AppRouter.shared)
                .environmentObject(scribe)
                .environmentObject(notepadOpener)
                .environmentObject(calendar)
            let host = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: host)
            window.title = "Shout"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            // A unified (empty) toolbar gives the native sidebar-under-traffic-lights layout.
            let toolbar = NSToolbar(identifier: "ShoutMainToolbar")
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 1000, height: 700))
            window.minSize = NSSize(width: 820, height: 560)
            window.isReleasedWhenClosed = false
            // Reopens where it was left, as the Notepad does; centred the first time.
            if !window.setFrameUsingName("ShoutMainWindow") { window.center() }
            window.setFrameAutosaveName("ShoutMainWindow")
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }


    // MARK: Status item

    @MainActor
    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Shout")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusMenu = menu
    }

    /// "Standup • in 5 min" next to the icon (setting "Show your next meeting in the menu bar").
    @MainActor
    private func updateMenuBarMeeting() {
        guard let button = statusItem?.button else { return }
        let title = SettingsStore.shared.settings.scribeShowNextMeeting ? (calendar.menuBarTitle ?? "") : ""
        if title.isEmpty {
            statusItem.length = NSStatusItem.squareLength
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            statusItem.length = NSStatusItem.variableLength
            button.title = " " + title
            button.font = .menuBarFont(ofSize: 0)
            button.imagePosition = .imageLeading
        }
    }

    /// Updates the menu-bar meeting just after every minute boundary, so its countdown moves with the clock.
    @MainActor
    private func scheduleMenuBarTick() {
        menuBarTimer?.invalidate()
        let next = ((Date().timeIntervalSince1970 / 60).rounded(.down) + 1) * 60 + 0.05
        let timer = Timer(fire: Date(timeIntervalSince1970: next), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenuBarMeeting()
                self?.scheduleMenuBarTick()
            }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        menuBarTimer = timer
    }

    /// Menu bar icon mirrors the dictation state, like macOS's own recording indicators.
    @MainActor
    private func updateStatusIcon(_ phase: FlowBarModel.Phase, recordingMeeting: Bool = false) {
        guard let button = statusItem?.button else { return }
        let image: NSImage?
        switch phase {
        case .idle where recordingMeeting, .success where recordingMeeting, .message where recordingMeeting:
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Shout is recording a meeting")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
        case .listening(_, let command):
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, command ? .systemPurple : .systemRed])
            image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "Shout is listening")?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
        case .processing:
            image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Shout is working")
            image?.isTemplate = true
        default:
            image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Shout")
            image?.isTemplate = true
        }
        button.image = image
    }

    /// Status line, dictation, the calendar (Join Meeting, Now / Today / Tomorrow), past notes, the Scribe
    /// and the app's pages.
    @MainActor
    private func fillStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let hub = EngineHub.shared
        let status: String
        if !Permissions.shared.accessibility { status = "Needs Accessibility permission" }
        else if case .loading = hub.speechState { status = hub.speechState.label }
        else if case .loading = hub.languageState { status = hub.languageState.label }
        else if case .ready = hub.speechState { status = "Ready · \(SettingsStore.shared.settings.pushToTalk.displayString) to dictate" }
        else { status = hub.speechState.label }
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item("Start Hands-Free Dictation", #selector(startHandsFree)))
        menu.addItem(item("Paste Last Transcript", #selector(pasteLast)))
        menu.addItem(.separator())

        let now = Date()
        if calendar.access == .granted {
            if let e = CalendarSchedule.joinableNow(calendar.events, now: now) {
                let join = item("Join Meeting", #selector(joinEvent(_:)))
                join.representedObject = e.id
                join.toolTip = e.displayTitle
                join.image = NSImage(systemSymbolName: "video", accessibilityDescription: nil)
                menu.addItem(join)
            }
            for section in CalendarSchedule.menuSections(calendar.events, now: now) {
                menu.addItem(.sectionHeader(title: section.title))
                for e in section.events { menu.addItem(eventItem(e)) }
            }
            menu.addItem(item("See All Upcoming Meetings", #selector(openScribeList)))
        }
        let past = NSMenuItem(title: "Past Notes", action: nil, keyEquivalent: "")
        let pastMenu = NSMenu()
        let notes = recentNotes(now: now)
        if notes.isEmpty {
            let none = NSMenuItem(title: "No Notes Yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            pastMenu.addItem(none)
        }
        notes.forEach(pastMenu.addItem)
        pastMenu.addItem(.separator())
        pastMenu.addItem(item("See All Past Notes", #selector(openScribeList)))
        past.submenu = pastMenu
        menu.addItem(past)
        menu.addItem(.separator())

        if scribe?.isRecording == true {
            menu.addItem(item("Stop Scribe", #selector(stopScribe)))
            menu.addItem(item("Show Notepad", #selector(showNotepad)))
        } else {
            menu.addItem(item("Start Scribe", #selector(startScribe)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Shout", #selector(openHome)))
        menu.addItem(item("History", #selector(openHistory)))
        menu.addItem(item("Dictionary", #selector(openDictionary)))
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        if calendar.access == .granted {
            let show = SettingsStore.shared.settings.scribeShowNextMeeting
            let toggle = item(show ? "Hide Next Meeting from Menu Bar" : "Show Next Meeting in Menu Bar", #selector(toggleNextMeeting))
            toggle.image = NSImage(systemSymbolName: show ? "eye.slash" : "eye", accessibilityDescription: nil)
            menu.addItem(toggle)
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Shout", #selector(quit), key: "q"))
    }

    /// A calendar row: the title (shortened if long) with its time range below; click joins and starts the Scribe.
    @MainActor
    private func eventItem(_ e: UpcomingEvent) -> NSMenuItem {
        let title = e.displayTitle.count > 40 ? String(e.displayTitle.prefix(39)) + "…" : e.displayTitle
        let row = item(title, #selector(joinEvent(_:)))
        row.representedObject = e.id
        let action = e.conferenceURL == nil ? "Start Scribe" : "Join and start Scribe"
        row.toolTip = title == e.displayTitle ? action : "\(e.displayTitle)\n\(action)"
        if #available(macOS 14.4, *) { row.subtitle = CalendarText.timeRange(e) }
        else { row.title += " · " + CalendarText.timeRange(e) }
        return row
    }

    /// The five most recent notes (not the one being recorded), each opening in the main window.
    @MainActor
    private func recentNotes(now: Date) -> [NSMenuItem] {
        Store.shared.meetings(limit: 6).filter { $0.id != scribe?.activeMeetingID }.prefix(5).map { m in
            let row = item(m.displayTitle.count > 40 ? String(m.displayTitle.prefix(39)) + "…" : m.displayTitle,
                           #selector(openMeetingNote(_:)))
            row.representedObject = m.id
            if #available(macOS 14.4, *) { row.subtitle = CalendarText.noteTime(m.createdAt, now: now) }
            return row
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func startHandsFree() { MainActor.assumeIsolated { controller.startSession(mode: .dictation, locked: true) } }
    @objc private func pasteLast() { MainActor.assumeIsolated { controller.pasteLast() } }
    @objc private func openHome() { MainActor.assumeIsolated { openMainWindow(page: "home") } }
    @objc private func startScribe() { MainActor.assumeIsolated { scribe.start() } }
    @objc private func stopScribe() { MainActor.assumeIsolated { scribe.stop() } }
    @objc private func showNotepad() {
        MainActor.assumeIsolated { if let id = scribe.activeMeetingID { notepad.show(meetingID: id) } }
    }
    /// Opens the event's call link and starts the Scribe for it (just joins while another meeting is recorded).
    @objc private func joinEvent(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let id = sender.representedObject as? String, let e = calendar.events.first(where: { $0.id == id }) else { return }
            scribe.noteJoinIntent(e)
            if let url = e.conferenceURL { NSWorkspace.shared.open(url) }
            if !scribe.isRecording { scribe.start(event: e) }
        }
    }
    @objc private func openMeetingNote(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            guard let id = sender.representedObject as? String else { return }
            AppRouter.shared.openMeeting(id)
            openMainWindow(page: nil)
        }
    }
    @objc private func toggleNextMeeting() {
        MainActor.assumeIsolated { SettingsStore.shared.settings.scribeShowNextMeeting.toggle() }
    }
    @objc private func openScribe() { MainActor.assumeIsolated { openMainWindow(page: "scribe") } }
    /// The Scribe page's list (upcoming meetings and past notes), not whichever note was open.
    @objc private func openScribeList() {
        MainActor.assumeIsolated {
            AppRouter.shared.meetingID = nil
            openMainWindow(page: "scribe")
        }
    }
    @objc private func newNote() {
        MainActor.assumeIsolated {
            // ⌘N only counts on the Scribe page (see `validateMenuItem`); choosing the item works anywhere.
            if let e = NSApp.currentEvent, e.type == .keyDown, e.modifierFlags.contains(.command),
               e.charactersIgnoringModifiers?.lowercased() == "n", !newNoteKeyActive { return }
            if !scribe.isRecording { scribe.start() }
        }
    }
    @objc private func openHistory() { MainActor.assumeIsolated { openMainWindow(page: "history") } }
    @objc private func openDictionary() { MainActor.assumeIsolated { openMainWindow(page: "dictionary") } }
    @objc private func openSettings() { MainActor.assumeIsolated { openMainWindow(page: "settings") } }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Main menu (so ⌘C/⌘V/⌘Q work in our windows)

    @MainActor
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Shout", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Shout", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Shout", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let scribeItem = NSMenuItem(); main.addItem(scribeItem)
        let notes = NSMenu(title: "Scribe")
        notes.delegate = self
        fillScribeMenu(notes)
        scribeItem.submenu = notes
        scribeMenu = notes

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        NSApp.mainMenu = main
    }

    /// ⌘N starts a note only while the Scribe page is the key window, as in Wispr Flow. Anywhere else (Settings,
    /// another page, a sheet, the Notepad) New Note has no key, so ⌘N never starts a recording by surprise.
    @MainActor
    private var newNoteKeyActive: Bool {
        let router = AppRouter.shared
        return mainWindow?.isKeyWindow == true && router.page == .scribe && !router.showOnboarding
    }

    @MainActor
    private func refreshNewNoteKey() {
        newNoteItem?.keyEquivalent = newNoteKeyActive ? "n" : ""
    }

    /// New Note (⌘N on the Scribe page), Stop / Show Notepad while recording, upcoming meetings, recent notes and
    /// the Scribe page.
    @MainActor
    private func fillScribeMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = item("New Note", #selector(newNote), key: newNoteKeyActive ? "n" : "")
        menu.addItem(row)
        newNoteItem = row
        if scribe?.isRecording == true {
            menu.addItem(item("Stop Scribe", #selector(stopScribe)))
            menu.addItem(item("Show Notepad", #selector(showNotepad)))
        }
        menu.addItem(.separator())
        if calendar.access == .granted { menu.addItem(item("See All Upcoming Meetings", #selector(openScribeList))) }
        let notes = recentNotes(now: Date())
        if !notes.isEmpty {
            menu.addItem(.sectionHeader(title: "Past Notes"))
            notes.forEach(menu.addItem)
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Scribe", #selector(openScribeList)))
    }
}

extension AppDelegate: NSMenuDelegate, NSMenuItemValidation {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu { fillStatusMenu(menu) }
        else if menu === scribeMenu { fillScribeMenu(menu) }
    }

    /// New Note starts a recording, so it is off while one is running (Stop is next to it). Its ⌘N works only on the
    /// Scribe page: the item may still carry the key from when the menu was last built there.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(newNote) else { return true }
        if scribe?.isRecording == true { return false }
        if let e = NSApp.currentEvent, e.type == .keyDown, e.modifierFlags.contains(.command),
           e.charactersIgnoringModifiers?.lowercased() == "n" {
            return newNoteKeyActive
        }
        return true
    }
}
