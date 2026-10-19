import SwiftUI
import ShoutKit

/// Fixed system colours (not the accent colour, which can be purple too), so You and Others always differ.
enum TranscriptStyle {
    static let you = Color(nsColor: .systemBlue)
    static let others = Color(nsColor: .systemPurple)
    /// Named speakers: system colours other than You's blue and Others' purple (indigo, closest to it, last).
    static let named: [NSColor] = [.systemOrange, .systemTeal, .systemPink, .systemGreen, .systemBrown, .systemIndigo]
    static func color(_ s: MeetingSource) -> Color { s == .mic ? you : others }

    /// A named speaker's colour: by their place in the meeting's `order` (name keys, first to speak first), so the
    /// first six people never share one; a stable pick by name for anyone not in it. You and Others otherwise.
    static func color(_ s: MeetingSource, name: String?, order: [String] = []) -> Color {
        guard s == .system, let name else { return color(s) }
        let key = SpeakerNames.key(name)
        let index = order.firstIndex(of: key)
            ?? Int(key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % UInt32(named.count))
        return Color(nsColor: named[index % named.count])
    }
}

/// The meeting's named speakers in order of appearance (name keys), for `TranscriptStyle.color`.
private struct SpeakerOrderKey: EnvironmentKey {
    static let defaultValue: [String] = []
}

extension EnvironmentValues {
    var speakerOrder: [String] {
        get { self[SpeakerOrderKey.self] }
        set { self[SpeakerOrderKey.self] = newValue }
    }
}

/// Asks for a speaker's name with a native alert (usable from menus).
@MainActor
enum SpeakerNamePrompt {
    static func ask(title: String, message: String, current: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if SettingsStore.shared.settings.scribeHideFromScreenCapture { alert.window.sharingType = .none }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return SpeakerNames.clean(field.stringValue)
    }
}

/// One meeting: editable title, info pills, and tabs for the user's notes, the live or finished
/// transcript, the summary and action items, with Start/Stop/Resume and Ask at the bottom.
/// Used in the main window and in the Notepad window beside the call.
struct MeetingDetailView: View {
    let meetingID: String
    let inNotepad: Bool
    /// Tab to open on (snapshots); nil picks one from the meeting's state.
    var initialTab: Tab? = nil

    @EnvironmentObject var store: Store
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var scribe: ScribeController
    @EnvironmentObject var notepad: NotepadOpener
    @State private var meeting: Meeting?
    @State private var segments: [MeetingSegment] = []
    /// Named speakers, for the chips under the title.
    @State private var speakers: [SpeakerAttribution.Speaker] = []
    @State private var tab: Tab?
    @State private var title = ""
    @State private var notes = ""
    @State private var saveTask: Task<Void, Never>?
    /// The window this view is in, for the Delete confirmation sheet.
    @State private var host = HostWindow()
    @State private var asking: AskRequest?
    @State private var loadedID: String?
    @State private var savedTitle = ""
    @State private var savedNotes = ""
    @StateObject private var player = MeetingPlayer()
    /// Recording state the player last loaded for; it reloads when the meeting stops, resumes or grows.
    @State private var audioKey = ""

    enum Tab: String, CaseIterable, Identifiable {
        case notes = "My Notes", transcript = "Transcript", summary = "Summary", tasks = "Tasks"
        var id: String { rawValue }
    }

    private var isLive: Bool { scribe.activeMeetingID == meetingID }
    private var horizontalPadding: CGFloat { inNotepad ? 20 : Theme.pagePadding }

    /// Live meetings open on the transcript (or notes when the live transcript is hidden); past ones on
    /// the summary once it exists.
    private var currentTab: Tab {
        if let tab { return tab }
        if isLive { return settings.settings.scribeShowLiveTranscript ? .transcript : .notes }
        if meeting?.summaryStatus == .ready || meeting?.summaryStatus == .generating { return .summary }
        return .transcript
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, horizontalPadding)
                .padding(.top, inNotepad ? 34 : 18)
            ZStack(alignment: .bottom) {
                Group {
                    switch currentTab {
                    case .transcript:
                        if isLive && !settings.settings.scribeShowLiveTranscript {
                            HiddenTranscriptNote()
                        } else {
                            TranscriptView(segments: segments, isLive: isLive, horizontalPadding: horizontalPadding,
                                           notices: isLive ? scribe.notices : [], appName: meeting?.sourceApp)
                                // A turn's time plays the recording from there.
                                .environment(\.transcriptSeek, !isLive && player.duration > 0 ? TranscriptSeek(player) : nil)
                        }
                    case .notes:
                        PlaceholderEditor(text: $notes, placeholder: "Write your notes here. Shout writes a separate summary at the end.",
                                          minHeight: 200)
                            .padding(.horizontal, horizontalPadding - 6)
                            .padding(.top, 14)
                            .padding(.bottom, 84)
                            .frame(maxHeight: .infinity, alignment: .top)
                    case .summary:
                        // Keyed by meeting so an edit draft never carries over to another note.
                        if let meeting { SummaryTab(meeting: meeting, isLive: isLive, horizontalPadding: horizontalPadding).id(meeting.id) }
                    case .tasks:
                        TasksTab(meetingID: meetingID, horizontalPadding: horizontalPadding).id(meetingID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                MeetingControlBar(meetingID: meetingID, isProcessing: isProcessing, inNotepad: inNotepad) { q in
                    asking = AskRequest(question: q, meetingID: meetingID)
                }
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.speakerOrder, speakers.map(\.id))
        .onAppear(perform: load)
        .onChange(of: meetingID) { _, _ in saveTask?.cancel(); saveNow(); load() }
        .onChange(of: store.meetingsRevision) { _, _ in reload() }
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: notes) { _, _ in scheduleSave() }
        .onChange(of: router.meetingTab) { _, _ in takeRequestedTab() }
        .onChange(of: scribe.activeMeetingID) { _, _ in refreshAudio() }
        .onDisappear { saveTask?.cancel(); saveNow(); player.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .shoutFlushEdits)) { _ in saveTask?.cancel(); saveNow() }
        .readingHostWindow(host)
        .sheet(item: $asking) {
            AskSheet(request: $0).frame(minWidth: 600, minHeight: 500)
                .hiddenFromScreenCapture(inNotepad && settings.settings.scribeHideFromScreenCapture)
        }
    }

    /// Asks before deleting `m`, then deletes that note (even if this view shows another by then), unless it has
    /// started recording, transcribing or summarizing since. Only leaves the Scribe page's note if that is the
    /// one deleted; a Notepad showing it closes on its own.
    private func confirmDelete(_ m: Meeting) {
        let id = m.id, store = store, scribe = scribe, router = router
        Confirmation.present(on: host.window, title: "Delete “\(m.displayTitle)”?",
                             message: "The transcript, summary, your notes and the audio recording are removed from this Mac.",
                             confirm: "Delete") {
            guard let m = store.meeting(id: id), scribe.canDelete(m) else { return }
            store.deleteMeeting(id: id)
            if router.meetingID == id { router.meetingID = nil }
        }
    }

    private var isProcessing: Bool {
        scribe.processingIDs.contains(meetingID) || (meeting?.status == .processing && !isLive)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !inNotepad {
                HStack {
                    Button { saveNow(); router.meetingID = nil } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text("Scribe")
                        }
                        .font(.system(size: 12.5))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("[", modifiers: .command)
                    Spacer()
                    Button { saveNow(); notepad.open(meetingID) } label: {
                        Image(systemName: "macwindow.on.rectangle").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Open in Notepad window")
                    moreMenu
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("Untitled meeting", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: inNotepad ? 20 : 24, weight: .bold))
                if inNotepad {
                    Spacer(minLength: 8)
                    moreMenu
                }
            }
            if let meeting { InfoPills(meeting: meeting, isLive: isLive) }
            if !speakers.isEmpty { SpeakerChips(meetingID: meetingID, speakers: speakers, appName: meeting?.sourceApp) }
            if !isLive && player.duration > 0 { PlaybackBar(player: player).padding(.top, 2) }
            tabBar.padding(.top, 4)
        }
    }

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                ForEach(visibleTabs) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 7) {
                            HStack(spacing: 5) {
                                tabIcon(t)
                                Text(tabTitle(t))
                            }
                            .font(.system(size: 13, weight: currentTab == t ? .semibold : .regular))
                            .foregroundStyle(currentTab == t ? .primary : .secondary)
                            Rectangle().fill(currentTab == t ? Color.primary : .clear).frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Divider()
        }
    }

    private var visibleTabs: [Tab] {
        var tabs: [Tab] = [.notes, .transcript, .summary]
        if (meeting?.taskTotal ?? 0) > 0 || meeting?.summaryStatus == .ready { tabs.append(.tasks) }
        return tabs
    }

    private func tabTitle(_ t: Tab) -> String {
        guard t == .tasks, let m = meeting, m.taskTotal > 0 else { return t.rawValue }
        return "Tasks (\(m.taskDone)/\(m.taskTotal))"
    }

    @ViewBuilder private func tabIcon(_ t: Tab) -> some View {
        switch t {
        case .transcript where isLive: LiveWaveGlyph()
        case .summary where meeting?.summaryStatus == .generating: ProgressView().controlSize(.mini)
        case .summary: Image(systemName: "sparkles").font(.system(size: 11))
        default: EmptyView()
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Copy as Markdown") { if let m = meeting { TextInserter.copy(MeetingMarkdown.export(m, store: store)) } }
            Button("Copy Transcript") { TextInserter.copy(TranscriptView.plainText(segments)) }
                .disabled(segments.allSatisfy { $0.marker != nil || $0.latched })
            if let path = meeting?.audioPath {
                Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            if inNotepad {
                Button("Open in Shout") {
                    router.meetingID = meetingID
                    (NSApp.delegate as? AppDelegate)?.openMainWindow(page: "scribe")
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { if let m = meeting { confirmDelete(m) } }
                .disabled(meeting.map { !scribe.canDelete($0) } ?? true)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    // MARK: Data

    /// Title and notes are saved to the meeting they were loaded from (`loadedID`), and only when they
    /// differ from what was last loaded or saved, so switching meetings or a second window on the same
    /// meeting never writes stale text.
    private func load() {
        tab = initialTab
        takeRequestedTab()
        loadedID = meetingID
        meeting = store.meeting(id: meetingID)
        title = meeting?.title ?? ""
        notes = meeting?.notes ?? ""
        savedTitle = title
        savedNotes = notes
        segments = store.segments(meetingID: meetingID)
        loadSpeakers()
        audioKey = ""
        refreshAudio()
    }

    private func loadSpeakers() {
        let found = SpeakerAttribution.speakers(segments: segments, talkMs: store.speakerTalkTime(meetingID: meetingID))
        if found != speakers { speakers = found }
    }

    /// Loads the recording for playback once the meeting isn't being recorded (and again after a Resume adds
    /// to it), and stops playback when recording starts again.
    private func refreshAudio() {
        guard let m = meeting else { return }
        let key = "\(isLive)-\(m.status.rawValue)-\(m.recordedMs)-\(m.latestStopSeq)"
        guard key != audioKey else { return }
        // Only taken once acted on: a change while playing reloads on a later refresh, after playback stops.
        if isLive {
            audioKey = key
            player.stop()
        } else if !player.isPlaying {
            audioKey = key
            player.load(meetingID: meetingID, segments: segments)
        }
    }

    /// A tab asked for along with this meeting on the Scribe page (e.g. Tasks from My Tasks).
    private func takeRequestedTab() {
        guard !inNotepad, router.meetingID == meetingID, let t = router.meetingTab else { return }
        tab = t
        router.meetingTab = nil
    }

    /// Store changed (new transcript line, status, generated title, the other window's edits): refresh
    /// the fields the user hasn't changed here.
    private func reload() {
        meeting = store.meeting(id: meetingID)
        segments = store.segments(meetingID: meetingID)
        loadSpeakers()
        refreshAudio()
        guard let m = meeting, loadedID == meetingID else { return }
        if title == savedTitle && m.title != savedTitle { title = m.title; savedTitle = m.title }
        if notes == savedNotes && m.notes != savedNotes { notes = m.notes; savedNotes = m.notes }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        guard let id = loadedID, store.meeting(id: id) != nil else { return }
        if title != savedTitle { store.setMeetingTitle(id: id, title: title); savedTitle = title }
        if notes != savedNotes { store.setMeetingNotes(id: id, notes: notes); savedNotes = notes }
    }
}

/// Date, length, app, folders and attendees under the title.
private struct InfoPills: View {
    let meeting: Meeting
    let isLive: Bool
    @EnvironmentObject var store: Store

    var body: some View {
        let folders = store.folders()
        let mine = Set(store.meetingFolderIDs()[meeting.id] ?? [])
        // Wraps at the Notepad's narrow width instead of pushing the folder menu out of the window.
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Pill(symbol: "calendar", text: meeting.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
            if meeting.recordedMs > 0 && !isLive { Pill(symbol: "clock", text: MeetingRowFormat.duration(meeting.duration)) }
            if let app = meeting.sourceApp { Pill(symbol: "video", text: app) }
            if !meeting.participants.isEmpty {
                Pill(symbol: "person.2", text: meeting.participants.prefix(2).joined(separator: ", ")
                     + (meeting.participants.count > 2 ? " +\(meeting.participants.count - 2)" : ""))
                    .help(meeting.participants.joined(separator: ", "))
            }
            Menu {
                ForEach(folders) { f in
                    Button { store.setMeeting(meeting.id, inFolder: f.id, !mine.contains(f.id)) } label: {
                        if mine.contains(f.id) { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                    }
                }
                if !folders.isEmpty { Divider() }
                Button("New Folder…") { NewFolderPrompt.ask { name in
                    let f = store.createFolder(name: name); store.setMeeting(meeting.id, inFolder: f.id, true)
                } }
            } label: {
                let names = folders.filter { mine.contains($0.id) }.map(\.name)
                Pill(symbol: names.isEmpty ? "folder.badge.plus" : "folder", text: names.isEmpty ? "Add to folder" : names.joined(separator: ", "))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }
}

struct Pill: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10.5))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .fixedSize()
    }
}

/// The people named in the transcript (and others the meeting app showed talking), each with their talk time.
/// Clicking one offers to rename it throughout the meeting.
private struct SpeakerChips: View {
    let meetingID: String
    let speakers: [SpeakerAttribution.Speaker]
    let appName: String?
    @EnvironmentObject var scribe: ScribeController
    /// More than this many collapse into "+N".
    static let shown = 6

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Text("Speakers").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).padding(.trailing, 2)
            ForEach(speakers.prefix(Self.shown)) { chip($0) }
            if speakers.count > Self.shown {
                Menu {
                    ForEach(speakers.dropFirst(Self.shown)) { s in Button("Rename “\(s.name)”…") { rename(s) } }
                } label: {
                    Text("+\(speakers.count - Self.shown)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help(speakers.dropFirst(Self.shown).map(\.name).joined(separator: ", "))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speakers")
    }

    private func chip(_ s: SpeakerAttribution.Speaker) -> some View {
        let color = TranscriptStyle.color(.system, name: s.name, order: speakers.map(\.id))
        return Menu {
            Text(summary(s))
            Divider()
            Button("Rename “\(s.name)”…") { rename(s) }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(s.name).lineLimit(1)
                if s.talkMs >= 1_000 {
                    Text(MeetingRowFormat.duration(Double(s.talkMs) / 1000)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
            .fixedSize()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("\(s.name): \(summary(s)). Names come from \(appName ?? "the meeting app")'s window.")
    }

    private func summary(_ s: SpeakerAttribution.Speaker) -> String {
        let lines = s.lines == 0 ? "No lines" : (s.lines == 1 ? "1 line" : "\(s.lines) lines")
        return s.talkMs >= 1_000 ? "\(lines) · talked \(MeetingRowFormat.duration(Double(s.talkMs) / 1000))" : lines
    }

    private func rename(_ s: SpeakerAttribution.Speaker) {
        guard let name = SpeakerNamePrompt.ask(title: "Rename “\(s.name)”",
                                               message: "Every line of this meeting with this name changes.", current: s.name) else { return }
        scribe.renameSpeaker(meetingID: meetingID, from: s.name, to: name)
    }
}

/// Asks for a folder name with a native alert (usable from menus, where SwiftUI alerts are awkward).
@MainActor
enum NewFolderPrompt {
    static func ask(_ create: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // Also asked from the Notepad, which "Hide Notepad and Flow Bar from screen sharing" covers.
        if SettingsStore.shared.settings.scribeHideFromScreenCapture { alert.window.sharingType = .none }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { create(name) }
    }
}

/// Three bars that move while the meeting is recording.
private struct LiveWaveGlyph: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
            HStack(spacing: 1.5) {
                ForEach(0..<3) { i in
                    let h = 4 + 5 * abs(sin(tl.date.timeIntervalSinceReferenceDate * 5 + Double(i) * 1.3))
                    Capsule().fill(Color.red).frame(width: 2, height: h)
                }
            }
            .frame(height: 10)
        }
    }
}

private struct HiddenTranscriptNote: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash").font(.system(size: 22)).foregroundStyle(.tertiary)
            Text("The live transcript is hidden").font(.system(size: 13.5, weight: .semibold))
            Text("It's still being written and appears here when the meeting ends. Change this in Settings › Scribe.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Summary

private struct SummaryTab: View {
    let meeting: Meeting
    let isLive: Bool
    let horizontalPadding: CGFloat
    @EnvironmentObject var store: Store
    @EnvironmentObject var scribe: ScribeController
    @State private var editing = false
    @State private var draft = ""
    /// The meeting `draft` was taken from; Save writes only to that one.
    @State private var draftID: String?
    @State private var host = HostWindow()

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 16)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readingHostWindow(host)
        // ⌘Q while editing keeps the edit, as for My Notes.
        .onReceive(NotificationCenter.default.publisher(for: .shoutFlushEdits)) { _ in if editing { save() } }
    }

    /// Saves the edit to the meeting it was started on.
    private func save() {
        if draftID == meeting.id && draft != (meeting.summary ?? "") {
            store.setSummary(id: meeting.id, markdown: draft, overview: SummaryText.overview(draft), status: .ready, edited: true)
        }
        editing = false
    }

    @ViewBuilder private var content: some View {
        if isLive {
            StateMessage(symbol: "sparkles", title: "Summaries appear when a meeting ends",
                         detail: "Keep notes in My Notes while you talk; they shape the summary.")
        } else if scribe.processingIDs.contains(meeting.id) {
            StageCard(text: "Transcribing the last few sentences…")
        } else {
            switch meeting.summaryStatus {
            case .generating:
                StageCard(text: scribe.summaryStage[meeting.id] ?? "Writing the summary…")
            case .ready:
                readyView
            case .tooShort:
                StateMessage(symbol: "text.badge.xmark", title: "The meeting was too short to summarize",
                             detail: meeting.summaryIsStale ? "There's new recording since then." : nil) {
                    // Only "Summarize Anyway" skips the too-short check.
                    Button(meeting.summaryIsStale ? "Update Summary" : "Summarize Anyway") {
                        scribe.summarize(meeting.id, rerun: true, allowShort: !meeting.summaryIsStale)
                    }
                }
            case .noSpeech:
                StateMessage(symbol: "waveform.slash", title: "No speech was transcribed",
                             detail: meeting.summaryIsStale ? "There's new recording since then." : "There's nothing to summarize in this meeting.") {
                    if meeting.summaryIsStale { Button("Update Summary") { scribe.summarize(meeting.id, rerun: true) } }
                }
            case .failed:
                if meeting.summary != nil {
                    // A failed update keeps the previous summary visible.
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Update failed. Showing the previous summary.").font(.system(size: 12.5))
                        Spacer()
                        Button("Try Again") { scribe.summarize(meeting.id, rerun: true) }.controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.1)))
                    MarkdownText(markdown: meeting.summary ?? "")
                } else {
                    StateMessage(symbol: "exclamationmark.triangle", title: "The summary couldn't be written",
                                 detail: meeting.error) {
                        Button("Try Again") { scribe.summarize(meeting.id, rerun: true) }
                    }
                }
            case .none:
                StateMessage(symbol: "sparkles", title: "No summary yet",
                             detail: meeting.duration < 300 ? "Short meetings aren't summarized automatically." : nil) {
                    Button("Generate Summary") { scribe.summarize(meeting.id, rerun: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// Rewrites the summary, asking first when the user has edited it.
    private func regenerate() {
        guard meeting.summaryEdited else { scribe.summarize(meeting.id, rerun: true); return }
        let id = meeting.id, scribe = scribe
        Confirmation.present(on: host.window, title: "Replace your edited summary?",
                             message: "Writing a new summary replaces the changes you made to this one.",
                             confirm: "Replace Summary") { scribe.summarize(id, rerun: true) }
    }

    @ViewBuilder private var readyView: some View {
        let words = TextRules.wordCount(meeting.summary ?? "")
        HStack(spacing: 8) {
            Label("\(max(1, Int((Double(words) / 200).rounded(.up)))) min read", systemImage: "lightbulb")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if editing {
                Button("Cancel") { editing = false }.controlSize(.small)
                Button("Save", action: save)
                    .controlSize(.small).buttonStyle(.borderedProminent)
            } else {
                CopyButton(text: meeting.summary ?? "").buttonStyle(.borderless).help("Copy summary")
                Button { draft = meeting.summary ?? ""; draftID = meeting.id; editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("Edit summary")
                Menu {
                    Button("Regenerate Summary") { regenerate() }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        if meeting.summaryIsStale && !editing {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor)
                Text("New recording since this summary.").font(.system(size: 12.5))
                Spacer()
                Button("Update Summary") { regenerate() }.controlSize(.small)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        }
        if editing {
            PlaceholderEditor(text: $draft, placeholder: "Summary (Markdown)", minHeight: 360)
        } else {
            MarkdownText(markdown: meeting.summary ?? "")
        }
    }
}

enum SummaryText {
    /// First paragraph that isn't a heading or list.
    static func overview(_ markdown: String) -> String? {
        MarkdownText.blocks(markdown).compactMap { if case .paragraph(let t) = $0 { return t } else { return nil } }.first
    }
}

private struct StageCard: View {
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.system(size: 13, weight: .medium))
                Text("Written on this Mac. Dictation always goes first.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(CardSurface())
    }
}

private struct StateMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.tertiary).symbolRenderingMode(.hierarchical)
            Text(title).font(.system(size: 14, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380) }
            actions.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

extension StateMessage where Actions == EmptyView {
    init(symbol: String, title: String, detail: String?) {
        self.symbol = symbol; self.title = title; self.detail = detail; self.actions = EmptyView()
    }
}

// MARK: - Tasks

private struct TasksTab: View {
    let meetingID: String
    let horizontalPadding: CGFloat
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: AppRouter
    @State private var newTask = ""
    @State private var showArchived = false
    @State private var host = HostWindow()

    var body: some View {
        let all = store.tasks(meetingID: meetingID, includeArchived: true)
        let tasks = all.filter { !$0.isArchived }
        let archived = all.filter(\.isArchived)
        let archivedShown = showArchived && !archived.isEmpty
        PageScroll {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(tasks.isEmpty ? "No action items" : "\(tasks.filter { $0.status == .done }.count) of \(tasks.count) done")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if tasks.contains(where: { $0.status != .done }) {
                        Button("Mark All as Completed") {
                            for var t in tasks where t.status != .done { t.status = .done; store.updateTask(t) }
                        }
                        .controlSize(.small)
                    }
                    if !tasks.isEmpty {
                        Button("Archive All") { confirmArchiveAll(tasks) }.controlSize(.small)
                    }
                }
                Card(padding: 0, spacing: 0) {
                    ForEach(tasks) { t in
                        TaskLine(task: t).padding(.horizontal, 14).padding(.vertical, 10)
                        Divider().padding(.leading, 38)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 15)
                        TextField("Add action item", text: $newTask)
                            .textFieldStyle(.plain).font(.system(size: 13.5))
                            .onSubmit(addTask)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Click a circle to mark an item in progress, then done. Double-click to edit.")
                        .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    if !archived.isEmpty {
                        Button(archivedShown ? "Hide Archived" : "Show Archived (\(archived.count))") {
                            withAnimation(.easeOut(duration: 0.15)) { showArchived = !archivedShown }
                        }
                        .buttonStyle(.link).font(.system(size: 12)).fixedSize()
                    }
                    Button { router.page = .tasks } label: {
                        HStack(spacing: 3) { Text("All Tasks"); Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)) }
                    }
                    .buttonStyle(.link).font(.system(size: 12)).fixedSize()
                    .help("Open My Tasks")
                }
                if archivedShown {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ARCHIVED").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        Card(padding: 0, spacing: 0) {
                            ForEach(archived) { t in
                                HStack(spacing: 8) {
                                    TaskLine(task: t)
                                    Button("Unarchive") { store.setTasksArchived(ids: [t.id], false) }
                                        .buttonStyle(.borderless).controlSize(.small).font(.system(size: 12))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                if t.id != archived.last?.id { Divider().padding(.leading, 38) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 16)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .readingHostWindow(host)
        // ⌘Q with an item typed in the add field keeps it, as Return would.
        .onReceive(NotificationCenter.default.publisher(for: .shoutFlushEdits)) { _ in addTask() }
    }

    private func addTask() {
        let t = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { store.addTask(meetingID: meetingID, title: t) }
        newTask = ""
    }

    /// Archives the items listed when it was asked (not ones added since).
    private func confirmArchiveAll(_ tasks: [MeetingTask]) {
        let ids = tasks.map(\.id), store = store
        Confirmation.present(on: host.window, title: "Archive \(ids.count == 1 ? "1 action item" : "\(ids.count) action items")?",
                             message: "You can restore them any time with Show Archived, or in My Tasks.",
                             confirm: "Archive All", destructive: false) { store.setTasksArchived(ids: ids, true) }
    }
}

enum MeetingRowFormat {
    static func duration(_ t: TimeInterval) -> String {
        let minutes = Int((t / 60).rounded())
        if t < 60 { return "\(max(1, Int(t))) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let segments: [MeetingSegment]
    let isLive: Bool
    let horizontalPadding: CGFloat
    let notices: [ScribeController.Notice]
    /// The meeting app names were read from ("Zoom"), for their tooltip.
    var appName: String? = nil
    @EnvironmentObject var scribe: ScribeController
    @EnvironmentObject var store: Store
    @State private var atBottom = true
    @State private var viewport: CGFloat = 0

    enum Item: Identifiable {
        case turn(id: String, source: MeetingSource, label: String, startMs: Int, lines: [MeetingSegment])
        case divider(id: String, text: String, symbol: String)
        var id: String {
            switch self { case .turn(let id, _, _, _, _), .divider(let id, _, _): id }
        }
    }

    var body: some View {
        let items = Self.items(segments)
        ScrollViewReader { proxy in
            scroll {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(notices, id: \.self) { NoticeBanner(notice: $0) }
                    if items.isEmpty && !isLive {
                        Text("No speech was transcribed in this meeting.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 8)
                    }
                    if items.isEmpty && isLive && !scribe.micSpeaking && !scribe.systemSpeaking {
                        ListeningHint()
                    }
                    // Lazy, so a long transcript only builds the turns on screen when a new line arrives.
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(items) { item in
                            switch item {
                            case .turn(_, let source, let label, let start, let lines):
                                TurnView(source: source, label: label, startMs: start, lines: lines, appName: appName)
                            case .divider(_, let text, let symbol):
                                DividerLabel(text: text, symbol: symbol)
                            }
                        }
                    }
                    if isLive { LiveActivity() }
                    Color.clear.frame(height: 1).id("bottom")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: BottomOffsetKey.self, value: g.frame(in: .named("transcript")).maxY)
                        })
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 16)
                .padding(.bottom, 92)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "transcript")
            .background(GeometryReader { g in Color.clear.onAppear { viewport = g.size.height }
                .onChange(of: g.size.height) { _, h in viewport = h } })
            .onPreferenceChange(BottomOffsetKey.self) { maxY in atBottom = maxY <= viewport + 80 }
            .onChange(of: segments.count) { _, _ in
                if isLive && atBottom { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            // A live meeting opens on its latest line; a finished one from the start.
            .onAppear { if isLive { proxy.scrollTo("bottom", anchor: .bottom) } }
            .overlay(alignment: .bottom) {
                if isLive && !atBottom {
                    Button { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } label: {
                        Label("Jump to latest", systemImage: "arrow.down").font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(.regularMaterial))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 72)
                    .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder private func scroll<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if SnapshotMode.active { VStack(spacing: 0) { content() }.frame(maxHeight: .infinity, alignment: .top) }
        else { ScrollView { content() } }
    }

    /// Groups consecutive lines of the same speaker into turns and turns markers into dividers.
    static func items(_ segments: [MeetingSegment]) -> [Item] {
        var out: [Item] = []
        var current: (source: MeetingSource, label: String, start: Int, lines: [MeetingSegment])?
        func flush() {
            if let c = current { out.append(.turn(id: c.lines[0].id, source: c.source, label: c.label, startMs: c.start, lines: c.lines)) }
            current = nil
        }
        let visible = segments.filter { !$0.latched && ($0.marker != nil || !$0.displayText.isEmpty) }
        var i = 0
        while i < visible.count {
            let s = visible[i]
            if let marker = s.marker {
                switch marker {
                case .stopped:
                    // Only meaningful when the recording was resumed afterwards.
                    if let j = visible[(i + 1)...].firstIndex(where: { $0.marker != nil }), visible[j].marker == .resumed,
                       !visible[(i + 1)..<j].contains(where: { $0.marker == nil }) {
                        let next = visible[j]
                        flush()
                        let stopped = s.epoch.map { $0.formatted(date: .omitted, time: .shortened) }
                        let resumed = next.epoch.map { $0.formatted(date: .omitted, time: .shortened) }
                        out.append(.divider(id: s.id, text: ["Stopped \(stopped ?? "")", "Resumed \(resumed ?? "")"].joined(separator: " · "),
                                            symbol: "pause.circle"))
                        i = j + 1
                        continue
                    }
                case .resumed:
                    flush()
                    out.append(.divider(id: s.id, text: "Resumed \(s.epoch?.formatted(date: .omitted, time: .shortened) ?? "")",
                                        symbol: "play.circle"))
                case .dictated:
                    // Several dictations in a row read as one gap.
                    if case .divider(_, let t, _) = out.last, t.hasPrefix("You dictated"), current == nil { break }
                    flush()
                    out.append(.divider(id: s.id, text: "You dictated in another app (not recorded)", symbol: "mic.slash"))
                }
                i += 1
                continue
            }
            if let c = current, c.source == s.source, c.label == s.speakerLabel,
               s.startMs - (c.lines.last?.endMs ?? s.startMs) < 60_000 {
                current?.lines.append(s)
            } else {
                flush()
                current = (s.source, s.speakerLabel, s.startMs, [s])
            }
            i += 1
        }
        flush()
        return out
    }

    static func plainText(_ segments: [MeetingSegment]) -> String {
        items(segments).compactMap { item -> String? in
            guard case .turn(_, _, let label, let start, let lines) = item else { return nil }
            return "\(label) (\(formatTimestamp(ms: start))): " + lines.map(\.displayText).joined(separator: " ")
        }.joined(separator: "\n\n")
    }
}

private struct BottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct TurnView: View {
    let source: MeetingSource
    let label: String
    let startMs: Int
    let lines: [MeetingSegment]
    var appName: String? = nil
    @Environment(\.transcriptSeek) private var seek
    @Environment(\.speakerOrder) private var speakerOrder
    @EnvironmentObject var store: Store
    @EnvironmentObject var scribe: ScribeController

    private var name: String? { lines.first?.speaker }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(label).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TranscriptStyle.color(source, name: name, order: speakerOrder))
                    if source == .system, lines.first?.speakerOrigin == .ax {
                        Image(systemName: "person.wave.2").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            .help("Name read from \(appName ?? "the meeting app")'s window")
                            .accessibilityLabel("Detected name")
                    }
                }
                .contextMenu { if source == .system { speakerMenu } }
                if let seek {
                    Button { seek(startMs) } label: {
                        Text(formatTimestamp(ms: startMs)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Play from here")
                } else {
                    Text(formatTimestamp(ms: startMs)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            ForEach(lines) { LineBubble(segment: $0) }
        }
    }

    /// Rename the speaker everywhere in the meeting, take the name off this turn, or name an "Others" turn.
    @ViewBuilder private var speakerMenu: some View {
        let ids = lines.map(\.id)
        let meetingID = lines.first?.meetingID ?? ""
        if let name {
            Button("Rename “\(name)”…") {
                guard let new = SpeakerNamePrompt.ask(title: "Rename “\(name)”",
                                                      message: "Every line of this meeting with this name changes.", current: name) else { return }
                scribe.renameSpeaker(meetingID: meetingID, from: name, to: new)
            }
            Button("Not \(name)") { store.setSpeaker(segmentIDs: ids, name: nil) }
        } else {
            Button("Name This Speaker…") {
                guard let new = SpeakerNamePrompt.ask(title: "Who is speaking?", message: "Names the lines of this turn.") else { return }
                store.setSpeaker(segmentIDs: ids, name: new)
            }
        }
    }
}

/// One transcript line. Double-click to correct it; right-click to copy or delete.
private struct LineBubble: View {
    let segment: MeetingSegment
    @EnvironmentObject var store: Store
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.speakerOrder) private var speakerOrder

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                    // Clicking elsewhere keeps the correction, like Return.
                    .onChange(of: focused) { _, f in if !f && editing { commit() } }
            } else {
                Text(segment.displayText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 13.5))
        .lineSpacing(2)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(TranscriptStyle.color(segment.source, name: segment.speaker, order: speakerOrder).opacity(scheme == .dark ? 0.16 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(editing ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        .onTapGesture(count: 2) { draft = segment.displayText; editing = true }
        .contextMenu {
            Button("Copy") { TextInserter.copy(segment.displayText) }
            Button("Edit") { draft = segment.displayText; editing = true }
            if segment.editedText != nil { Button("Revert to Original") { store.editSegment(id: segment.id, text: nil) } }
            Divider()
            Button("Delete Line", role: .destructive) { store.deleteSegment(id: segment.id) }
        }
        // ⌘Q while correcting a line keeps the correction, as clicking elsewhere would.
        .onReceive(NotificationCenter.default.publisher(for: .shoutFlushEdits)) { _ in if editing { commit() } }
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied line keeps its text (Delete Line removes it); retyping the original drops the correction.
        guard !t.isEmpty, t != segment.displayText else { return }
        store.editSegment(id: segment.id, text: t == segment.text ? nil : t)
    }
}

private struct DividerLabel: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
            Label(text, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }
}

/// "Others are speaking…": shown while an utterance is still being captured, before its text arrives.
private struct LiveActivity: View {
    @EnvironmentObject var scribe: ScribeController
    @Environment(\.speakerOrder) private var speakerOrder
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if scribe.systemSpeaking {
                TypingBubble(label: scribe.liveSpeakerName ?? MeetingSource.system.speakerLabel,
                             color: TranscriptStyle.color(.system, name: scribe.liveSpeakerName, order: speakerOrder))
            }
            if scribe.micSpeaking { TypingBubble(label: "You", color: TranscriptStyle.you) }
        }
        .animation(.easeOut(duration: 0.2), value: scribe.systemSpeaking)
        .animation(.easeOut(duration: 0.2), value: scribe.micSpeaking)
    }
}

private struct TypingBubble: View {
    let label: String
    let color: Color
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        let phase = tl.date.timeIntervalSinceReferenceDate * 4 - Double(i) * 0.6
                        Circle().fill(Color.secondary).frame(width: 6, height: 6).opacity(0.35 + 0.45 * max(0, sin(phase)))
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(scheme == .dark ? 0.16 : 0.08)))
        }
        .transition(.opacity)
        .accessibilityLabel("\(label) speaking")
    }
}

private struct ListeningHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").foregroundStyle(.tertiary)
            Text("Listening. What you and others say appears here a moment after each sentence.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }
}

private struct NoticeBanner: View {
    let notice: ScribeController.Notice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 13))
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                if notice == .systemAudioSilent || notice == .systemAudioDenied {
                    Button("Open System Settings…") { Permissions.openSystemAudioSettings() }.controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.25), lineWidth: 0.5))
    }

    private var text: String {
        switch notice {
        case .systemAudioSilent:
            "Shout isn't hearing the call yet. If others are already speaking, allow Shout under Privacy & Security › Screen & System Audio Recording › System Audio Recording Only."
        case .systemAudioDenied:
            "System Audio Recording is turned off for Shout, so only your side of the call is recorded. Allow Shout under Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then stop and resume."
        case .systemAudioUnavailable(let s): s
        case .micUnavailable(let s): "Your microphone isn't being recorded. \(s)"
        case .micSilent: "Shout hasn't heard your microphone for 3 minutes. If you're speaking, check the input selected in System Settings › Sound."
        case .noEchoCancellation: "Echo cancellation isn't available for this microphone. Use headphones so the call isn't transcribed as you."
        case .transcriptionFailed(let s): "Transcription stopped: \(s) The audio is still being recorded."
        }
    }
}

// MARK: - Control bar

/// Floating capsule at the bottom, like a meeting footer: the record control (Stop while recording,
/// Resume afterwards) and an Ask field for questions about this meeting.
struct MeetingControlBar: View {
    let meetingID: String
    let isProcessing: Bool
    var inNotepad = false
    var onAsk: ((String) -> Void)? = nil
    @EnvironmentObject var scribe: ScribeController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var notepad: NotepadOpener
    @State private var question = ""

    private var isLive: Bool { scribe.activeMeetingID == meetingID }

    var body: some View {
        VStack(spacing: 8) {
            if isLive && !settings.settings.scribeConsentDismissed { ConsentNote() }
            HStack(spacing: 8) {
                recordControl
                if let onAsk {
                    Divider().frame(height: 18)
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField(isLive ? "What did I miss?" : "Ask about this meeting…", text: $question)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .frame(minWidth: 120, maxWidth: 260)
                        .onSubmit {
                            let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !q.isEmpty { onAsk(q); question = "" }
                        }
                    // An empty question opens this meeting's past chats.
                    Button { onAsk("") } label: {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Past chats about this meeting")
                    .accessibilityLabel("Past chats")
                }
            }
            .padding(.leading, 6).padding(.trailing, onAsk == nil ? 6 : 14).padding(.vertical, 5)
            .frame(minHeight: 40)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var recordControl: some View {
        if isLive {
            HStack(spacing: 8) {
                RecordingDot(size: 8)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(RecordButton.clock(scribe.elapsed)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                }
                Button { scribe.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .help("Stop Scribe")
            }
            .padding(.leading, 4)
        } else if scribe.isRecording {
            HStack(spacing: 8) {
                Text("Recording another meeting").font(.system(size: 12)).foregroundStyle(.secondary)
                // In the Notepad the main window may be closed, so switch the Notepad itself to the live note.
                Button("Show") {
                    guard let live = scribe.activeMeetingID else { return }
                    if inNotepad { notepad.open(live) } else { router.meetingID = live }
                }
                .controlSize(.small)
            }
            .padding(.leading, 8)
        } else if isProcessing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing up…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
        } else {
            Button { scribe.resume(meetingID) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    Text("Resume")
                }
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Continue recording into this note")
        }
    }
}

private struct ConsentNote: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.wave.2").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("Let everyone know you're taking notes.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            CopyButton(text: settings.settings.scribeConsentMessage, label: "Copy message").buttonStyle(.link).font(.system(size: 11.5))
            Button { settings.settings.scribeConsentDismissed = true } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Don't show again")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
