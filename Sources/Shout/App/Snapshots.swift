import AppKit
import SwiftUI
import ShoutKit

/// Development aid: `SHOUT_SNAPSHOT_DIR=/path Shout` renders every page to PNG and quits.
/// Rendering happens inside the app's own process, so no screen-recording permission is needed.
@MainActor
enum Snapshots {
    static func runIfRequested(controller: DictationController, scribe: ScribeController, flowBar: FlowBarController,
                               calendar: CalendarService, notepad: NotepadOpener) -> Bool {
        guard let dir = ProcessInfo.processInfo.environment["SHOUT_SNAPSHOT_DIR"] else { return false }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        func fail(_ message: String) { FileHandle.standardError.write(Data("Shout snapshots: \(message)\n".utf8)) }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { fail("can't create \(url.path): \(error.localizedDescription)") }
        let router = AppRouter.shared
        router.showOnboarding = false

        /// A throwaway settings suite goes with its file (macOS keeps an empty plist otherwise).
        func removeSuite(_ name: String) {
            UserDefaults().removePersistentDomain(forName: name)
            CFPreferencesAppSynchronize(name as CFString)
            let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Preferences/\(name).plist")
            try? FileManager.default.removeItem(at: file)
        }

        func render<V: View>(_ view: V, size: NSSize, name: String, dark: Bool = false) {
            let root = view
                .environmentObject(SettingsStore.shared).environmentObject(Store.shared)
                .environmentObject(EngineHub.shared).environmentObject(ModelManager.shared)
                .environmentObject(Permissions.shared).environmentObject(router).environmentObject(scribe)
                .environmentObject(calendar).environmentObject(notepad)
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            // Scroll views only lay out their content once the window is really on screen, so show it
            // far outside the visible displays for a moment.
            // On a real display (so it gets display-link updates) but below the desktop, so it stays invisible.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.ignoresMouseEvents = true
            if let vf = NSScreen.main?.visibleFrame { window.setFrameOrigin(vf.origin) }
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return fail("\(name): no bitmap") }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return fail("\(name): PNG encoding failed") }
            do { try png.write(to: url.appendingPathComponent("\(name).png")) }
            catch { fail("\(name): \(error.localizedDescription)") }
        }

        /// Scribe states beyond the demo notes: summary states, tabs, folders, search, Ask, calendar cards,
        /// the narrow Notepad, live notices and My Tasks. Adds its own notes to the throwaway database.
        func renderScribeStates() {
            let store = Store.shared
            let both = [false, true]
            func suffix(_ dark: Bool) -> String { dark ? "-dark" : "" }
            func page<V: View>(_ v: V) -> some View {
                v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor))
            }

            for dark in both {
                render(MeetingDetailView(meetingID: "demo-sync", inNotepad: false, initialTab: .notes),
                       size: NSSize(width: 820, height: 560), name: "meeting-notes\(suffix(dark))", dark: dark)
                render(page(ScribeView(initialTab: .folders)), size: NSSize(width: 820, height: 900),
                       name: "scribe-folders\(suffix(dark))", dark: dark)
            }
            if let product = store.folders().first(where: { $0.name == "Product" }) {
                render(page(ScribeView(initialTab: .folders, initialFolderID: product.id)), size: NSSize(width: 820, height: 900),
                       name: "scribe-folder-open")
            }
            render(page(ScribeView(initialSearch: "zebra")), size: NSSize(width: 820, height: 900), name: "scribe-search-empty")

            // The player under a finished meeting's title. Demo notes have no audio, so it gets a stand-in length;
            // the mark is where the demo meeting was resumed.
            let playback = MeetingPlayer.preview(duration: 31 * 60 + 12, position: 7 * 60 + 41, legStarts: [64])
            for dark in both {
                render(page(PlaybackBar(player: playback).padding(20)), size: NSSize(width: 820, height: 72),
                       name: "playback\(suffix(dark))", dark: dark)
                render(page(PlaybackBar(player: playback).padding(20)), size: NSSize(width: 500, height: 72),
                       name: "playback-notepad\(suffix(dark))", dark: dark)
            }

            // Summary tab states.
            for (id, state) in SnapshotFixtures.summaryStates(in: store) {
                for dark in both {
                    render(MeetingDetailView(meetingID: id, inNotepad: false, initialTab: .summary),
                           size: NSSize(width: 820, height: 620), name: "summary-\(state)\(suffix(dark))", dark: dark)
                }
            }
            render(MeetingDetailView(meetingID: "snap-summary-none", inNotepad: false, initialTab: .notes),
                   size: NSSize(width: 820, height: 480), name: "meeting-notes-empty")

            // The Notepad at its minimum width with attendees, an app and folders (the pills wrap).
            let attendees = SnapshotFixtures.notepadWithAttendees(in: store)
            for dark in both {
                render(MeetingDetailView(meetingID: attendees, inNotepad: true, initialTab: .transcript),
                       size: NSSize(width: 500, height: 760), name: "notepad-500-attendees\(suffix(dark))", dark: dark)
            }

            // Speaker names: chips with "+N" in the main window and wrapping in the narrow Notepad, and the live
            // Notepad with the speaker the meeting app shows right now.
            let speakers = SnapshotFixtures.manySpeakers(in: store)
            for dark in both {
                render(MeetingDetailView(meetingID: speakers, inNotepad: false, initialTab: .transcript),
                       size: NSSize(width: 820, height: 1100), name: "meeting-speakers\(suffix(dark))", dark: dark)
                render(MeetingDetailView(meetingID: speakers, inNotepad: true, initialTab: .transcript),
                       size: NSSize(width: 500, height: 1500), name: "notepad-speakers\(suffix(dark))", dark: dark)
            }
            scribe.previewLive(meetingID: "demo-sync", notices: [], speaker: "Mei Chen")
            for dark in both {
                render(MeetingDetailView(meetingID: "demo-sync", inNotepad: true, initialTab: .transcript),
                       size: NSSize(width: 520, height: 1500), name: "notepad-live-speaker\(suffix(dark))", dark: dark)
            }
            scribe.endPreview()

            // Every notice while live, and the dividers (stopped/resumed, dictated).
            scribe.previewLive(meetingID: attendees, notices: [
                .systemAudioSilent, .systemAudioDenied, .systemAudioUnavailable("The call's audio device was disconnected."),
                .micUnavailable("The selected microphone isn't connected."), .micSilent, .noEchoCancellation,
                .transcriptionFailed("The speech model couldn't be loaded."),
            ])
            render(MeetingDetailView(meetingID: attendees, inNotepad: true), size: NSSize(width: 520, height: 1700),
                   name: "notepad-live-notices")
            scribe.endPreview()

            // Ask: an answer with its source meetings, an error, and one still thinking.
            let ask = AskRequest(question: "What did we decide about the launch?", meetingID: nil)
            for dark in both {
                render(page(AskSheet(request: ask, preview: SnapshotFixtures.askExchanges(in: store))),
                       size: NSSize(width: 620, height: 640), name: "ask-sheet\(suffix(dark))", dark: dark)
            }
            // Ask history: no chats yet, the saved chats, and one reopened.
            let chatSize = NSSize(width: 620, height: 420)
            render(page(AskSheet(request: AskRequest(question: "", meetingID: "demo-sync"))), size: chatSize, name: "ask-history-empty")
            let newestChat = SnapshotFixtures.savedChats(in: store)
            for dark in both {
                render(page(AskSheet(request: AskRequest(question: "", meetingID: nil))), size: chatSize,
                       name: "ask-history\(suffix(dark))", dark: dark)
                render(page(AskSheet(request: AskRequest(question: "", meetingID: nil, chatID: newestChat))), size: chatSize,
                       name: "ask-chat-reopened\(suffix(dark))", dark: dark)
            }

            // Today card: not connected, nothing left, and a busy day (conflict, "Show 2 more").
            let todaySize = NSSize(width: 680, height: 360)
            calendar.preview(events: [], access: .notDetermined)
            render(page(TodayCard(preview: .constant(nil)).padding(20)), size: todaySize, name: "today-not-connected")
            calendar.preview(events: [])
            render(page(TodayCard(preview: .constant(nil)).padding(20)), size: todaySize, name: "today-empty")
            calendar.preview(events: SnapshotFixtures.busyDay(now: Date()))
            for dark in both {
                render(page(TodayCard(preview: .constant(nil)).padding(20)), size: todaySize, name: "today-busy\(suffix(dark))", dark: dark)
            }
            calendar.preview(events: SnapshotFixtures.events(now: Date()))

            for dark in both {
                render(page(VStack(spacing: 16) { SetupCard(); EmptyNotes() }.padding(20)), size: NSSize(width: 680, height: 420),
                       name: "scribe-setup-empty\(suffix(dark))", dark: dark)
            }

            // My Tasks: the list and the Archived view, and a meeting's Tasks tab with an archived item.
            if var archived = store.tasks(meetingID: "demo-1on1").first {
                archived.isArchived = true
                store.updateTask(archived)
            }
            store.addTask(meetingID: nil, title: "Book the venue for the offsite")
            for dark in both {
                router.page = .tasks
                render(page(MyTasksView()), size: NSSize(width: 820, height: 760), name: "tasks\(suffix(dark))", dark: dark)
                render(page(MyTasksView(showingArchived: true)), size: NSSize(width: 820, height: 480),
                       name: "tasks-archived\(suffix(dark))", dark: dark)
            }
            if var t = store.tasks(meetingID: "demo-sync").last {
                t.isArchived = true
                store.updateTask(t)
            }
            render(MeetingDetailView(meetingID: "demo-sync", inNotepad: false, initialTab: .tasks),
                   size: NSSize(width: 820, height: 640), name: "meeting-tasks-archived")

            for f in store.folders() { store.deleteFolder(id: f.id) }
            render(page(ScribeView(initialTab: .folders)), size: NSSize(width: 820, height: 900), name: "scribe-folders-empty")
        }

        // Fixed calendar events, so a snapshot never shows the real calendar.
        calendar.preview(events: SnapshotFixtures.events(now: Date()))

        // NavigationSplitView cannot be captured offscreen, so render each page's content directly.
        let pageSize = NSSize(width: 820, height: 1240)
        for page in AppRouter.Page.allCases {
            router.page = page
            render(MainView.detail(page, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
                   size: pageSize, name: "page-\(page.rawValue)")
        }
        for page in [AppRouter.Page.home, .history, .models] {
            render(MainView.detail(page, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
                   size: pageSize, name: "page-\(page.rawValue)-dark", dark: true)
        }
        // Style with a tone row picked for the preview, and dark.
        render(StyleView(channel: .tone(.work)).background(Color(nsColor: .windowBackgroundColor)),
               size: NSSize(width: 820, height: 1000), name: "style-tone-work")
        render(MainView.detail(.style, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
               size: NSSize(width: 820, height: 1000), name: "page-style-dark", dark: true)

        // The add and edit forms of Dictionary and Snippets, as their sheets show them.
        func sheet<V: View>(_ v: V) -> some View {
            v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Color(nsColor: .windowBackgroundColor))
        }
        for dark in [false, true] {
            let s = dark ? "-dark" : ""
            render(sheet(DictionaryEntrySheet(entry: nil)), size: NSSize(width: 460, height: 330), name: "dictionary-add\(s)", dark: dark)
            render(sheet(DictionaryEntrySheet(entry: nil, word: "Kubernetes", misspelling: "Cooper Netties")),
                   size: NSSize(width: 460, height: 400), name: "dictionary-add-correction\(s)", dark: dark)
            render(sheet(SnippetSheet(entry: nil)), size: NSSize(width: 520, height: 460), name: "snippet-add\(s)", dark: dark)
        }
        render(sheet(DictionaryEntrySheet(entry: nil, word: "priya")), size: NSSize(width: 460, height: 360), name: "dictionary-add-duplicate")
        if let btw = Store.shared.replacements.first {
            render(sheet(DictionaryEntrySheet(entry: btw)), size: NSSize(width: 460, height: 380), name: "dictionary-edit")
        }
        if let snippet = Store.shared.snippets.first {
            render(sheet(SnippetSheet(entry: snippet)), size: NSSize(width: 520, height: 440), name: "snippet-edit")
        }
        // A prompt's pictures in History (generated stand-ins, with what was said and what was under the mouse).
        let picturesDir = FileManager.default.temporaryDirectory.appendingPathComponent("shout-snapshot-pictures")
        try? FileManager.default.createDirectory(at: picturesDir, withIntermediateDirectories: true)
        func picture(_ name: String, _ color: NSColor) -> String {
            let image = NSImage(size: NSSize(width: 1280, height: 800), flipped: false) { r in
                NSColor.windowBackgroundColor.setFill(); r.fill()
                color.withAlphaComponent(0.25).setFill(); NSRect(x: 0, y: 0, width: 260, height: 800).fill()
                NSColor.systemRed.setStroke()
                let ring = NSBezierPath(ovalIn: NSRect(x: 600, y: 420, width: 80, height: 80)); ring.lineWidth = 8; ring.stroke()
                return true
            }
            let url = picturesDir.appendingPathComponent("\(name).png")
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
            return url.path
        }
        let pictures = PromptCaptureArchive.Saved(historyID: 1, createdAt: Date(), captures: [
            PromptCaptureRecord(path: picture("one", .systemBlue), source: "shout", time: 4.2,
                                said: "…when you click on Add, it opens this text box right away",
                                detail: "under the mouse: button “Add Word”; window: Dictionary (Shout)"),
            PromptCaptureRecord(path: picture("two", .systemPurple), original: "/Users/sam/Desktop/Screenshot.png", source: "screenshot",
                                time: 9.8, said: "…and here on the snippets page, the same thing happens…"),
            PromptCaptureRecord(path: picturesDir.appendingPathComponent("gone.png").path, source: "clipboard", time: 12.1,
                                said: "…this one was deleted"),
        ])
        for dark in [false, true] {
            render(sheet(PromptPicturesCard(pictures: pictures).padding(20)), size: NSSize(width: 720, height: 560),
                   name: "history-pictures\(dark ? "-dark" : "")", dark: dark)
        }

        // Prompt mode: the page, light and dark.
        render(MainView.detail(.prompts, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
               size: NSSize(width: 820, height: 1500), name: "page-prompts-dark", dark: true)
        render(MainView.detail(.prompts, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
               size: NSSize(width: 820, height: 1500), name: "page-prompts-full")
        // With a model that can't do screenshots: the switch grayed out. A separate store, so no model is loaded.
        if let suite = UserDefaults(suiteName: "ShoutSnapshotSmallModel") {
            let small = SettingsStore(defaults: suite)
            small.settings.languageModelID = "qwen3.5-2b-q4"
            render(PromptsView().environmentObject(small).background(Color(nsColor: .windowBackgroundColor)),
                   size: NSSize(width: 820, height: 1500), name: "page-prompts-small-model")
            removeSuite("ShoutSnapshotSmallModel")
        }
        // "Show screenshots to the AI model" for a model that can't see, and for each that can (its image reader
        // downloaded or not, as on this Mac).
        for (id, name) in [("qwen3-4b-instruct-q4", "text-only"), ("qwen3.5-4b-q4", "4b"), ("qwen3.5-9b-q4", "9b")] {
            guard let suite = UserDefaults(suiteName: "ShoutSnapshotVision") else { continue }
            let store = SettingsStore(defaults: suite)
            store.settings.languageModelID = id
            render(Card(padding: 0, spacing: 0) { ScreenshotVisionRow() }.padding(20).environmentObject(store)
                    .background(Color(nsColor: .windowBackgroundColor)),
                   size: NSSize(width: 760, height: 120), name: "prompts-vision-\(name)")
            removeSuite("ShoutSnapshotVision")
        }
        render(Sidebar().frame(width: 216).background(.regularMaterial), size: NSSize(width: 216, height: 700), name: "sidebar")
        render(Sidebar().frame(width: 216).background(.regularMaterial), size: NSSize(width: 216, height: 700), name: "sidebar-dark", dark: true)
        render(MainView.detail(.scribe, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
               size: pageSize, name: "page-scribe-dark", dark: true)
        // Meeting notes need demo data (SHOUT_DEMO_DATA=1).
        if Store.shared.meeting(id: "demo-sync") != nil {
            for dark in [false, true] {
                render(MainView.detail(.scribe, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 1180, height: 860), name: "scribe-wide\(dark ? "-dark" : "")", dark: dark)
                render(MeetingDetailView(meetingID: "demo-sync", inNotepad: false, initialTab: .transcript),
                       size: NSSize(width: 820, height: 1000), name: "meeting-transcript\(dark ? "-dark" : "")", dark: dark)
                render(MeetingDetailView(meetingID: "demo-sync", inNotepad: false, initialTab: .tasks),
                       size: NSSize(width: 820, height: 640), name: "meeting-tasks\(dark ? "-dark" : "")", dark: dark)
            }
            router.settingsTab = .scribe
            for dark in [false, true] {
                render(MainView.detail(.settings, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 820, height: 2100), name: "settings-scribe\(dark ? "-dark" : "")", dark: dark)
            }
            router.settingsTab = .general
            router.meetingID = "demo-sync"
            for dark in [false, true] {
                render(MainView.detail(.scribe, controller: controller), size: NSSize(width: 820, height: 1100),
                       name: "meeting-detail\(dark ? "-dark" : "")", dark: dark)
                render(MeetingDetailView(meetingID: "demo-sync", inNotepad: true), size: NSSize(width: 520, height: 980),
                       name: "notepad\(dark ? "-dark" : "")", dark: dark)
            }
            scribe.previewLive(meetingID: "demo-sync", notices: [.systemAudioSilent])
            for dark in [false, true] {
                render(MeetingDetailView(meetingID: "demo-sync", inNotepad: true), size: NSSize(width: 520, height: 1500),
                       name: "notepad-live\(dark ? "-dark" : "")", dark: dark)
            }
            router.meetingID = nil
            for dark in [false, true] {
                render(MainView.detail(.scribe, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
                       size: NSSize(width: 820, height: 900), name: "page-scribe-live\(dark ? "-dark" : "")", dark: dark)
            }
            scribe.endPreview()
            renderScribeStates()
        }
        render(MainView.detail(.settings, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
               size: NSSize(width: 820, height: 2300), name: "page-settings-tall")
        render(MainView.detail(.settings, controller: controller).background(Color(nsColor: .windowBackgroundColor)),
               size: NSSize(width: 820, height: 2300), name: "page-settings-dark", dark: true)
        router.showOnboarding = true
        for step in 0..<5 {
            render(OnboardingView(controller: controller, startStep: step), size: NSSize(width: 1000, height: 720), name: "onboarding-\(step)")
        }
        router.showOnboarding = false

        // A separate model, so the live Flow Bar's hover polling cannot change state mid-capture.
        let model = FlowBarModel()
        model.hint = flowBar.model.hint
        model.level = 0.75
        model.listeningSince = Date().addingTimeInterval(-12)
        let states: [(String, FlowBarModel.Phase, Bool)] = [
            ("idle", .idle, false),
            ("idle-hover", .idle, true),
            ("ptt", .listening(handsFree: false, command: false), false),
            ("handsfree", .listening(handsFree: true, command: false), false),
            ("command", .listening(handsFree: false, command: true), false),
            ("processing", .processing(command: false), false),
            ("success", .success, false),
            ("message", .message("Added “Joaquin” to your dictionary", kind: .success, actionTitle: "Undo"), false),
            ("message-long", .message("Shout can't reach the microphone. Check System Settings → Privacy & Security → Microphone and try again.", kind: .error, actionTitle: nil), false),
        ]
        var meetingStates = states.map { ($0.0, $0.1, $0.2, TimeInterval?.none) }
        meetingStates.append(("meeting", .idle, false, 754))
        meetingStates.append(("meeting-dictating", .listening(handsFree: false, command: false), false, 754))
        meetingStates.append(("meeting-hour", .idle, false, 3725))
        var cards: [(String, FlowCard, Bool)] = [
            ("card-detected", FlowCard(kind: .detected, title: "Meeting detected", subtitle: "Zoom", bundleID: "us.zoom.xos",
                                       primary: "Start Scribe", secondary: "Not now", menu: ["Snooze for 2 Minutes"]), false),
            ("card-autostart", FlowCard(kind: .detected, title: "Meeting detected", subtitle: "Google Meet · starting in 10 s",
                                        symbol: "video.fill", primary: "Start Now", secondary: "Not now", menu: ["Snooze for 2 Minutes"],
                                        deadline: Date().addingTimeInterval(6), startedAt: Date().addingTimeInterval(-4)), false),
            ("card-reminder", FlowCard(kind: .reminder, title: "Weekly product sync", subtitle: "In 2 min · Zoom", symbol: "calendar",
                                       primary: "Join & Start", menu: ["Join Meeting Only", "Start Scribe Only", "Snooze for 2 Minutes"]), false),
            ("card-stopping", FlowCard(kind: .stopping, title: "Scribe stopping", subtitle: "The call ended", symbol: "stop.circle",
                                       primary: "Stop", secondary: "Keep going", deadline: Date().addingTimeInterval(3),
                                       startedAt: Date().addingTimeInterval(-3)), true),
            ("card-reminder-long", FlowCard(kind: .reminder, title: "Quarterly planning review with leadership and the platform team",
                                            subtitle: "In 1 min · Microsoft Teams", symbol: "calendar", primary: "Join & Start",
                                            menu: ["Join Meeting Only", "Start Scribe Only", "Snooze for 2 Minutes"]), false),
        ]
        // The Scribe's own cards, with the controller's wording.
        func edited(_ card: FlowCard, _ edit: (inout FlowCard) -> Void) -> FlowCard { var c = card; edit(&c); return c }
        let timed = (deadline: Date().addingTimeInterval(20), startedAt: Date().addingTimeInterval(-10))
        let resumeAfterSleep = FlowCard(kind: .resume, title: "Scribe stopped when your Mac went to sleep", symbol: "moon.zzz",
                                        primary: "Resume", deadline: Date().addingTimeInterval(8), startedAt: Date().addingTimeInterval(-4))
        let silence = FlowCard(kind: .info, title: "Meeting still going?", subtitle: "No one has spoken for 10 minutes",
                               symbol: "waveform.slash", primary: "Stop", secondary: "Keep going",
                               deadline: timed.deadline, startedAt: timed.startedAt)
        cards += [
            ("card-detected-event", edited(FlowCard(kind: .detected, title: "Weekly product sync", subtitle: "Meeting detected",
                                                    bundleID: "us.zoom.xos", primary: "Start Scribe", secondary: "Not now",
                                                    menu: ["Join meeting", "Start Scribe", "Snooze for 2 min",
                                                           "Start Scribe automatically", "Notification settings"],
                                                    deadline: Date().addingTimeInterval(8), startedAt: Date().addingTimeInterval(-2))) {
                $0.checkedMenu = ["Start Scribe automatically"]
                $0.countdownText = "starting in %d s"
            }, false),
            ("card-sleep-resume", resumeAfterSleep, false),
            ("card-sleep-resume-new-note", edited(resumeAfterSleep) { $0.secondary = "Start new note" }, false),
            ("card-silence", silence, true),
            ("card-check-in", FlowCard(kind: .info, title: "Still taking notes", subtitle: "Weekly product sync", symbol: "questionmark.circle",
                                       primary: "Keep going", secondary: "Stop", deadline: timed.deadline, startedAt: timed.startedAt), true),
            ("card-max-length", edited(FlowCard(kind: .info, title: "Continue transcribing?",
                                                subtitle: "We'll auto-end transcriptions at 2 hours. Would you like to extend this meeting?",
                                                symbol: "timer", primary: "Yes", secondary: "End recording",
                                                deadline: timed.deadline, startedAt: timed.startedAt)) {
                $0.subtitleLines = 3
                $0.tileDeadline = Date().addingTimeInterval(287)
            }, true),
            ("card-max-length-final", edited(FlowCard(kind: .info, title: "Transcription will end soon",
                                                      subtitle: "3 hours is the limit for transcriptions.", symbol: "timer",
                                                      primary: "End recording", deadline: timed.deadline, startedAt: timed.startedAt)) {
                $0.tileDeadline = Date().addingTimeInterval(287)
            }, true),
            ("card-auto-end-picker", edited(FlowCard(kind: .info, title: "Change auto-end time?",
                                                     subtitle: "We'll still check with you before ending it", symbol: "timer",
                                                     primary: "Save", deadline: timed.deadline, startedAt: timed.startedAt)) {
                $0.choices = ["1 hour", "2 hours", "3 hours"]
                $0.selectedChoice = "1 hour"
            }, true),
            ("card-mistake", FlowCard(kind: .alert, title: "Started by mistake?",
                                      subtitle: "Only a few words were captured. Keep this meeting or discard it.",
                                      symbol: "trash", primary: "Keep", secondary: "Discard",
                                      deadline: Date().addingTimeInterval(50), startedAt: Date().addingTimeInterval(-10)), false),
            ("card-start-failed", FlowCard(kind: .alert, title: "Couldn't start recording",
                                           subtitle: "We couldn't capture any audio, so nothing was saved.", symbol: "exclamationmark.triangle",
                                           primary: "Try again", secondary: "Discard",
                                           deadline: Date().addingTimeInterval(4), startedAt: Date().addingTimeInterval(-2)), false),
            // Hovered: the countdown and progress line stand still.
            ("card-paused", edited(silence) { $0.pausedAt = Date() }, true),
        ]
        let cardsMadeAt = Date()
        for (name, card, meeting) in cards {
            model.phase = .idle
            // Rendering takes a while: move each card's clock so its countdown is where it was written.
            let shift = Date().timeIntervalSince(cardsMadeAt)
            var shifted = card
            shifted.startedAt = card.startedAt.addingTimeInterval(shift)
            shifted.deadline = card.deadline?.addingTimeInterval(shift)
            shifted.tileDeadline = card.tileDeadline?.addingTimeInterval(shift)
            shifted.pausedAt = card.pausedAt?.addingTimeInterval(shift)
            model.card = shifted
            model.meeting = meeting ? FlowBarModel.MeetingPill(startedAt: Date().addingTimeInterval(-1934)) : nil
            for (bgName, colors) in [("light", [Color(red: 0.86, green: 0.89, blue: 0.95), Color(red: 0.96, green: 0.93, blue: 0.9)]),
                                     ("dark", [Color(red: 0.1, green: 0.11, blue: 0.16), Color(red: 0.2, green: 0.16, blue: 0.24)])] {
                render(FlowBarView(model: model)
                        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)),
                       size: FlowBarMetrics.panelSize, name: "flow-\(name)-\(bgName)")
            }
        }
        model.card = nil
        model.meetingLevel = { 0.7 }
        for (name, phase, hovering, elapsed) in meetingStates {
            model.phase = phase
            model.hovering = hovering
            model.meeting = elapsed.map { FlowBarModel.MeetingPill(startedAt: Date().addingTimeInterval(-$0)) }
            for (bgName, colors) in [("light", [Color(red: 0.86, green: 0.89, blue: 0.95), Color(red: 0.96, green: 0.93, blue: 0.9)]),
                                     ("dark", [Color(red: 0.1, green: 0.11, blue: 0.16), Color(red: 0.2, green: 0.16, blue: 0.24)])] {
                render(FlowBarView(model: model)
                        .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)),
                       size: FlowBarMetrics.panelSize, name: "flow-\(name)-\(bgName)")
            }
        }
        // A dictation that started in another app shows where it goes, while held, hands-free and processing.
        model.meeting = nil
        model.hovering = false
        model.awayTarget = FlowBarModel.Target(appName: "TextEdit", bundleID: "com.apple.TextEdit")
        for (name, phase, shots) in [("away-listening", FlowBarModel.Phase.listening(handsFree: false, command: true), 0),
                                     ("away-handsfree", .listening(handsFree: true, command: true), 2),
                                     ("away-processing", .processing(command: false), 0)] {
            model.phase = phase
            model.captureCount = shots
            render(FlowBarView(model: model)
                    .background(LinearGradient(colors: [Color(red: 0.1, green: 0.11, blue: 0.16), Color(red: 0.2, green: 0.16, blue: 0.24)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)),
                   size: FlowBarMetrics.panelSize, name: "flow-\(name)")
        }
        model.awayTarget = nil
        model.captureCount = 0
        NSApp.terminate(nil)
        return true
    }
}

/// Sample calendar events and notes for snapshot states (throwaway database only).
@MainActor
private enum SnapshotFixtures {
    private static func event(_ id: String, _ title: String, from: Double, to: Double, now: Date, link: String? = nil,
                              attendees: [String] = [], color: String, status: UpcomingEvent.Response = .accepted) -> UpcomingEvent {
        UpcomingEvent(id: id, externalID: id, title: title, start: now.addingTimeInterval(from * 60), end: now.addingTimeInterval(to * 60),
                      conferenceURL: link.flatMap(URL.init(string:)), attendees: attendees, colorHex: color, myStatus: status)
    }

    /// A meeting in progress and one later (minutes from `now`).
    static func events(now: Date) -> [UpcomingEvent] {
        [
            event("snap-design", "Design review", from: -10, to: 20, now: now, link: "https://zoom.us/j/123456789",
                  attendees: ["Priya Raman", "Joaquin Ortiz", "Mei Chen"], color: "#5B8DEF"),
            event("snap-1on1", "1:1 with Priya", from: 40, to: 70, now: now, link: "https://meet.google.com/abc-defg-hij",
                  attendees: ["Priya Raman"], color: "#E5A23B"),
        ]
    }

    /// Five meetings, two of them overlapping, one tentative.
    static func busyDay(now: Date) -> [UpcomingEvent] {
        [
            event("busy-standup", "Standup", from: 5, to: 20, now: now, link: "https://meet.google.com/abc-defg-hij", color: "#5B8DEF"),
            event("busy-design", "Design review", from: 30, to: 75, now: now, link: "https://zoom.us/j/123456789", color: "#5B8DEF"),
            event("busy-hiring", "Hiring sync", from: 45, to: 75, now: now, color: "#3DAA6A", status: .tentative),
            event("busy-customer", "Customer call: Northwind", from: 120, to: 150, now: now,
                  link: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0", color: "#C2559B"),
            event("busy-planning", "Quarter planning", from: 180, to: 240, now: now, color: "#E5A23B"),
        ]
    }

    private static func note(_ store: Store, _ id: String, _ title: String, minutes: Int = 25, stale: Bool = false) {
        let start = Date().addingTimeInterval(-3 * 3600)
        store.createMeeting(Meeting(id: id, title: title, createdAt: start, startedAt: start,
                                    endedAt: start.addingTimeInterval(Double(minutes) * 60), recordedMs: minutes * 60_000,
                                    status: .complete, latestStopSeq: stale ? 2 : 1, processedStopSeq: stale ? 2 : 1,
                                    hasSystemAudio: true, sourceApp: "Zoom", sourceBundleID: "us.zoom.xos"))
        store.addSegment(MeetingSegment(meetingID: id, source: .system, startMs: 2_000, endMs: 6_000, text: "Okay, let's get started."))
    }

    /// One note per Summary tab state, as (meeting id, snapshot name).
    static func summaryStates(in store: Store) -> [(id: String, name: String)] {
        let overview = "The team agreed to ship the beta to ten design partners next week and to collect feedback in a shared doc."
        let markdown = overview + "\n\n## Decisions\n- Beta goes to ten design partners.\n\n## Next steps\n- **You** — Send the invites on Monday."
        note(store, "snap-summary-generating", "Roadmap check-in")
        store.setSummaryStatus(id: "snap-summary-generating", .generating)
        note(store, "snap-summary-too-short", "Quick question", minutes: 2)
        store.setSummary(id: "snap-summary-too-short", markdown: nil, overview: nil, status: .tooShort, stopSeq: 1)
        note(store, "snap-summary-no-speech", "Muted call", stale: true)
        store.setSummary(id: "snap-summary-no-speech", markdown: nil, overview: nil, status: .noSpeech, stopSeq: 1)
        note(store, "snap-summary-failed-previous", "Beta planning", stale: true)
        store.setSummary(id: "snap-summary-failed-previous", markdown: markdown, overview: overview, status: .failed, stopSeq: 1)
        note(store, "snap-summary-failed", "Vendor call")
        store.setSummaryStatus(id: "snap-summary-failed", .failed,
                               error: "The language model stopped before finishing. Try again, or choose a smaller model in Models.")
        note(store, "snap-summary-none", "Coffee chat", minutes: 4)
        note(store, "snap-summary-stale", "Sprint planning", stale: true)
        store.setSummary(id: "snap-summary-stale", markdown: markdown, overview: overview, status: .ready, stopSeq: 1)
        return [("snap-summary-generating", "generating"), ("snap-summary-too-short", "too-short"),
                ("snap-summary-no-speech", "no-speech-stale"), ("snap-summary-failed-previous", "failed-previous"),
                ("snap-summary-failed", "failed"), ("snap-summary-none", "none"), ("snap-summary-stale", "stale")]
    }

    /// A calendar note with four attendees, an app and two folders, whose transcript has every kind of divider.
    /// A Teams call with eight named speakers (more than the chips show), one line the app couldn't name and
    /// one the user named.
    static func manySpeakers(in store: Store) -> String {
        let id = "snap-speakers"
        let start = Date().addingTimeInterval(-90 * 60)
        store.createMeeting(Meeting(id: id, title: "Design review", createdAt: start, startedAt: start, endedAt: start.addingTimeInterval(45 * 60),
                                    recordedMs: 44 * 60_000, status: .complete, latestStopSeq: 1, hasSystemAudio: true,
                                    sourceApp: "Microsoft Teams", sourceBundleID: "com.microsoft.teams2"))
        let people = ["Priya Raman", "Joaquin Ortiz", "Mei Chen", "Alex Johnson", "Maria Garcia", "Wei Zhang", "Sam Patel", "Lena Fischer"]
        let said = [
            "Let's start with the onboarding screens. I shared the latest mocks in the channel.",
            "The second screen still feels busy to me. Could we drop the progress bar?",
            "We tested both versions last week. People finished faster with the bar.",
            "Then let's keep it, but make it lighter.",
        ]
        var spans: [SpeakerSpan] = []
        var t = 2_000
        for (i, name) in people.enumerated() {
            let length = 4_000 + (i % 3) * 1_500
            spans.append(.matched(name, t - 200, t + length + 200, platform: .teams))
            store.addSegment(MeetingSegment(meetingID: id, source: .system, speaker: name, startMs: t, endMs: t + length,
                                            text: said[i % said.count], speakerOrigin: .ax))
            t += length + 1_500
            if i == 1 {
                store.addSegment(MeetingSegment(meetingID: id, source: .mic, startMs: t, endMs: t + 3_000,
                                                text: "I'd rather keep it. The numbers were clear."))
                t += 4_500
            }
        }
        store.addSegment(MeetingSegment(meetingID: id, source: .system, startMs: t, endMs: t + 3_000,
                                        text: "Sorry, I was on mute. Can someone repeat the last point?"))
        store.addSegment(MeetingSegment(meetingID: id, source: .system, speaker: "Grace Hopper", startMs: t + 4_000, endMs: t + 7_000,
                                        text: "We're keeping the progress bar, just lighter.", speakerOrigin: .user))
        store.appendSpeakerSpans(meetingID: id, spans)
        return id
    }

    static func notepadWithAttendees(in store: Store) -> String {
        let id = "snap-attendees"
        let start = Date().addingTimeInterval(-50 * 60)
        store.createMeeting(Meeting(id: id, title: "Partner onboarding: Northwind", createdAt: start, startedAt: start,
                                    endedAt: Date(), recordedMs: 38 * 60_000, status: .complete, latestStopSeq: 2,
                                    hasSystemAudio: true, sourceApp: "Microsoft Teams", sourceBundleID: "com.microsoft.teams2"))
        store.setMeetingCalendarEvent(id: id, eventID: "snap-northwind", occurrenceStart: start,
                                      participants: ["Alex Johnson", "Maria Garcia", "Wei Zhang", "Sam Patel"])
        let customers = store.createFolder(name: "Customers")
        store.setMeeting(id, inFolder: customers.id, true)
        if let product = store.folders().first(where: { $0.name == "Product" }) { store.setMeeting(id, inFolder: product.id, true) }
        let lines: [(MeetingSource, Int, String)] = [
            (.system, 3, "Thanks for making the time. Let's walk through the rollout plan."),
            (.mic, 9, "Sure. We start with the pilot team next Monday."),
            (.system, 16, "Who should we contact for the single sign-on setup?"),
        ]
        for l in lines {
            store.addSegment(MeetingSegment(meetingID: id, source: l.0, startMs: l.1 * 1000, endMs: l.1 * 1000 + 4500, text: l.2))
        }
        store.addSegment(MeetingSegment(meetingID: id, source: .marker, startMs: 21_000, endMs: 21_000, marker: .dictated,
                                        epoch: start.addingTimeInterval(21)))
        store.addSegment(MeetingSegment(meetingID: id, source: .mic, startMs: 26_000, endMs: 30_000,
                                        text: "That would be Wei. I'll send you an intro."))
        store.addSegment(MeetingSegment(meetingID: id, source: .marker, startMs: 31_000, endMs: 31_000, marker: .stopped,
                                        epoch: start.addingTimeInterval(31)))
        store.addSegment(MeetingSegment(meetingID: id, source: .marker, startMs: 31_000, endMs: 31_000, marker: .resumed,
                                        epoch: start.addingTimeInterval(400)))
        store.addSegment(MeetingSegment(meetingID: id, source: .system, startMs: 33_000, endMs: 37_000,
                                        text: "Back again. One more thing about the invoices."))
        return id
    }

    /// Saved chats about all meetings: two answered, one cut off. Returns the id of the newest.
    @discardableResult
    static func savedChats(in store: Store) -> String {
        let sources = ["demo-sync", "demo-1on1"].compactMap { store.meeting(id: $0) }
            .map { AskSource(id: $0.id, title: $0.displayTitle, date: $0.createdAt) }
        let chats: [(String, String?, AskMessage.Status)] = [
            ("Which tasks are still open from last week?", nil, .interrupted),
            ("When is Priya's pricing draft due?", "Priya will have a draft of the pricing proposal **by Friday**.", .succeeded),
            ("What did we decide about the launch?",
             "The launch moves **one week later**, so the load tests on the new cluster can finish.", .succeeded),
        ]
        var newest = ""
        for (question, answer, status) in chats {
            let chat = store.createAskChat(meetingID: nil, title: question)
            let pending = store.addAskQuestion(chatID: chat.id, question: question, sources: sources)
            if let answer { store.finishAskAnswer(id: pending.id, content: answer, status: status, model: "Qwen3 4B", latencyMs: 4200) }
            else { store.interruptPendingAskAnswers(chatID: chat.id) }
            newest = chat.id
        }
        return newest
    }

    static func askExchanges(in store: Store) -> [AskSheet.Exchange] {
        let sources = ["demo-sync", "demo-1on1"].compactMap { store.meeting(id: $0) }
            .map { AskMessage.Source(id: $0.id, title: $0.displayTitle) }
        return [
            AskSheet.Exchange(question: "What did we decide about the launch?",
                              answer: "The launch moves **one week later**, so the load tests on the new cluster can finish.\n\n- Priya drafts the pricing proposal by Friday.\n- You send the new date to the team.",
                              sources: sources),
            AskSheet.Exchange(question: "Who owns the load tests?", error: "Ask needs a language model. Choose one in Models."),
            AskSheet.Exchange(question: "Summarize this week's 1:1s", sources: Array(sources.suffix(1))),
        ]
    }
}
