import SwiftUI
import ShoutKit

/// The Scribe page: today's meetings, past notes and folders, with a preview of the hovered note on
/// the right and an Ask bar at the bottom. Opening a note shows it in place (with a back button).
struct ScribeView: View {
    /// Where the list starts (snapshots).
    var initialTab: ScribeListTab = .past
    var initialFolderID: String? = nil
    var initialSearch = ""
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var store: Store

    var body: some View {
        if let id = router.meetingID, store.meeting(id: id) != nil {
            // A new view per note, so nothing typed or opened for one note (a delete confirmation, a summary
            // draft, a half-written action item) carries over to the next.
            MeetingDetailView(meetingID: id, inNotepad: false).id(id)
        } else {
            ScribeHome(tab: initialTab, folderID: initialFolderID, search: initialSearch)
        }
    }
}

enum ScribeListTab: String, CaseIterable { case past = "Past notes", folders = "Folders" }

extension ScribeController {
    /// A note can be deleted unless it is being recorded, transcribed or summarized (its files and rows are in use).
    func canDelete(_ m: Meeting) -> Bool {
        activeMeetingID != m.id && !processingIDs.contains(m.id) && m.status != .processing && m.summaryStatus != .generating
    }
}

/// What the preview panel shows.
enum ScribePreview: Equatable {
    case meeting(String)
    case event(UpcomingEvent)
}

private struct ScribeHome: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var scribe: ScribeController
    @EnvironmentObject var calendar: CalendarService
    @State private var meetings: [Meeting] = []
    @State private var folders: [MeetingFolder] = []
    @State private var folderIDs: [String: [String]] = [:]
    /// The open folder's notes, read with the rest rather than on every redraw (each keystroke and hover).
    @State private var folderMeetings: (folderID: String, items: [Meeting]) = ("", [])
    @State private var tab: ScribeListTab
    @State private var openFolderID: String?
    @State private var search: String
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// ⌘F asked for the search field before it was shown.
    @State private var focusSearchOnAppear = false
    @State private var searchTask: Task<Void, Never>?
    /// Past notes load a page at a time; scrolling to the end loads the next.
    @State private var hasMore = false
    @State private var preview: ScribePreview?
    @State private var newFolderName = ""
    @State private var creatingFolder = false
    @State private var askText = ""
    @State private var asking: AskRequest?

    static let pageSize = 100

    init(tab: ScribeListTab, folderID: String?, search: String) {
        _tab = State(initialValue: tab)
        _openFolderID = State(initialValue: folderID)
        _search = State(initialValue: search)
        _searching = State(initialValue: !search.isEmpty)
    }

    private var openFolder: MeetingFolder? { openFolderID.flatMap { id in folders.first { $0.id == id } } }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                listColumn
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) { askBar }
                if geo.size.width >= 900 {
                    Divider()
                    PreviewPanel(preview: currentPreview)
                        .frame(width: min(340, max(280, geo.size.width * 0.3)))
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: store.meetingsRevision) { _, _ in reload() }
        .onChange(of: openFolderID) { _, _ in loadFolder() }
        .onChange(of: search) { _, _ in searchChanged() }
        .onChange(of: scribe.processingIDs) { _, _ in reload() }
        .onChange(of: searchFocused) { _, focused in if !focused && search.isEmpty { searching = false } }
        .onDisappear { searchTask?.cancel() }
        // ⌘F works whether or not the field is showing.
        .background {
            Button("Search Past Notes", action: showSearch)
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .alert("New Folder", isPresented: $creatingFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.createFolder(name: name) }
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .sheet(item: $asking) { request in
            AskSheet(request: request).frame(minWidth: 620, minHeight: 520)
        }
    }

    // MARK: List column

    private var listColumn: some View {
        PageScroll {
            // Lazy so the "more" row below only appears (and loads the next page) once scrolled to.
            LazyVStack(alignment: .leading, spacing: 20) {
                header
                if needsSetup { SetupCard() }
                if let id = scribe.activeMeetingID, let m = meetings.first(where: { $0.id == id }) {
                    LiveCard(meeting: m)
                }
                TodayCard(preview: $preview)
                tabStrip
                switch tab {
                case .past:
                    pastNotes
                    if hasMore {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading older notes…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .onAppear(perform: loadMore)
                        .id(meetings.count)
                    }
                case .folders: foldersTab
                }
            }
            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 22)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Scribe").font(.system(size: 26, weight: .bold)).tracking(-0.3)
            Spacer(minLength: 12)
            Button {
                router.settingsTab = .scribe
                router.page = .settings
            } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Scribe settings")
            RecordButton()
        }
    }

    private var tabStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach(ScribeListTab.allCases, id: \.self) { t in
                    Button { withAnimation(.easeOut(duration: 0.15)) { tab = t; openFolderID = nil } } label: {
                        VStack(spacing: 7) {
                            Text(t.rawValue)
                                .font(.system(size: 13.5, weight: tab == t ? .semibold : .regular))
                                .foregroundStyle(tab == t ? .primary : .secondary)
                            Rectangle().fill(tab == t ? Color.primary : .clear).frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if searching || !search.isEmpty {
                    // Esc clears the text, then closes the field.
                    SearchField(text: $search, prompt: "Search past notes", focus: $searchFocused) {
                        if search.isEmpty { hideSearch() } else { search = "" }
                    }
                    .frame(width: 220)
                    .padding(.bottom, 6)
                    .onAppear { if focusSearchOnAppear { focusSearchOnAppear = false; searchFocused = true } }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                } else {
                    Button(action: showSearch) {
                        Image(systemName: "magnifyingglass").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Search past notes (⌘F)")
                    .accessibilityLabel("Search past notes")
                    .padding(.bottom, 9)
                }
            }
            Divider()
        }
    }

    // MARK: Past notes

    @ViewBuilder private var pastNotes: some View {
        let groups = Self.groups(meetings.filter { $0.id != scribe.activeMeetingID })
        if groups.isEmpty {
            if search.isEmpty {
                EmptyNotes()
            } else {
                Text("No notes found for “\(search)”.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        } else {
            MeetingGroups(groups: groups, folders: folders, folderIDs: folderIDs, preview: $preview)
        }
    }

    static func groups(_ meetings: [Meeting]) -> [(day: Date, items: [Meeting])] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: meetings) { cal.startOfDay(for: $0.createdAt) }
        return byDay.keys.sorted(by: >).map { ($0, byDay[$0]!.sorted { $0.createdAt > $1.createdAt }) }
    }

    // MARK: Folders

    @ViewBuilder private var foldersTab: some View {
        if let folder = openFolder {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { openFolderID = nil } } label: {
                        Label("Folders", systemImage: "chevron.left").font(.system(size: 12.5))
                    }
                    .buttonStyle(.borderless)
                    Text("/").foregroundStyle(.tertiary)
                    Text(folder.name).font(.system(size: 13, weight: .semibold))
                }
                // Read directly only until the cache catches up with a folder just opened.
                let items = folderMeetings.folderID == folder.id ? folderMeetings.items : store.meetings(inFolder: folder.id)
                if items.isEmpty {
                    Text("No notes in this folder yet. Add one from its ⋯ menu.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                } else {
                    MeetingGroups(groups: Self.groups(items), folders: folders, folderIDs: folderIDs, preview: $preview)
                }
            }
        } else if folders.isEmpty {
            Card {
                VStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("No folders").font(.system(size: 14, weight: .semibold))
                    Text("Organize your notes").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Button("Create Folder") { creatingFolder = true }.padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(folders) { f in
                    FolderCard(folder: f) { withAnimation(.easeOut(duration: 0.15)) { openFolderID = f.id } }
                }
                Button { creatingFolder = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .medium))
                        Text("New Folder").font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 86)
                    .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Ask

    private var askBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("Ask about your meetings…", text: $askText)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .onSubmit(submitAsk)
            Button { asking = AskRequest(question: "", meetingID: nil) } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Past chats")
            .accessibilityLabel("Past chats")
            Button(action: submitAsk) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(askText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.4) : Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(askText.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Ask")
        }
        .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 7)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        .frame(maxWidth: 640)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.bottom, 18)
    }

    private func submitAsk() {
        let q = askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        asking = AskRequest(question: q, meetingID: nil)
        askText = ""
    }

    // MARK: Data

    private var needsSetup: Bool {
        permissions.microphone != .authorized || (ScribeController.systemAudioSupported && !permissions.systemAudioAllowed)
    }

    /// The hovered row, else the next calendar meeting, else the newest note.
    private var currentPreview: ScribePreview? {
        if let preview { return preview }
        if let next = calendar.nextEvent { return .event(next) }
        return meetings.first.map { .meeting($0.id) }
    }

    /// Re-reads as many past notes as are loaded (at least a page, or just the first page), and the folders.
    /// One extra row tells whether there are more.
    private func reload(firstPage: Bool = false) {
        let count = firstPage ? Self.pageSize : max(Self.pageSize, meetings.count)
        let rows = store.meetings(search: search, limit: count + 1)
        hasMore = rows.count > count
        meetings = Array(rows.prefix(count))
        folders = store.folders()
        folderIDs = store.meetingFolderIDs()
        loadFolder()
    }

    private func loadFolder() {
        if let id = openFolderID { folderMeetings = (id, store.meetings(inFolder: id)) }
    }

    /// Appends the page after the last note shown.
    private func loadMore() {
        guard let last = meetings.last else { return }
        let rows = store.meetings(search: search, before: last, limit: Self.pageSize + 1)
        hasMore = rows.count > Self.pageSize
        meetings += rows.prefix(Self.pageSize)
    }

    /// Search reads every transcript, so it waits for a pause in typing, and starts again from the first page.
    private func searchChanged() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { reload(firstPage: true) }
        }
    }

    private func showSearch() {
        let showing = searching || !search.isEmpty
        withAnimation(.easeOut(duration: 0.15)) { searching = true; tab = .past; openFolderID = nil }
        // A field that is only about to appear takes focus from its own onAppear (asking before it exists can be dropped).
        if showing { searchFocused = true } else { focusSearchOnAppear = true }
    }

    private func hideSearch() {
        searchFocused = false
        withAnimation(.easeOut(duration: 0.15)) { searching = false }
    }
}

// MARK: - Rows

private struct MeetingGroups: View {
    let groups: [(day: Date, items: [Meeting])]
    let folders: [MeetingFolder]
    let folderIDs: [String: [String]]
    @Binding var preview: ScribePreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.dayTitle(group.day).uppercased())
                        .font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        .padding(.leading, 2)
                    Card(padding: 0, spacing: 0) {
                        ForEach(group.items) { m in
                            MeetingRow(meeting: m, folders: folders.filter { (folderIDs[m.id] ?? []).contains($0.id) },
                                       allFolders: folders, preview: $preview)
                            if m.id != group.items.last?.id { Divider().padding(.leading, 58) }
                        }
                    }
                }
            }
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        let date = day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        if cal.isDateInToday(day) { return "Today, " + day.formatted(.dateTime.month(.abbreviated).day()) }
        if cal.isDateInYesterday(day) { return "Yesterday, " + day.formatted(.dateTime.month(.abbreviated).day()) }
        if cal.isDate(day, equalTo: Date(), toGranularity: .year) { return date }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct MeetingRow: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var store: Store
    @EnvironmentObject var scribe: ScribeController
    @EnvironmentObject var notepad: NotepadOpener
    let meeting: Meeting
    let folders: [MeetingFolder]
    let allFolders: [MeetingFolder]
    @Binding var preview: ScribePreview?
    @State private var hover = false
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            MeetingIcon(bundleID: meeting.sourceBundleID)
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(meeting.title.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(meeting.createdAt.formatted(date: .omitted, time: .shortened))
                    if let status = statusText {
                        Text("·")
                        if isBusy { ProgressView().controlSize(.mini).scaleEffect(0.8) }
                        Text(status)
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let first = folders.first {
                Chip(symbol: "folder", text: first.name + (folders.count > 1 ? " +\(folders.count - 1)" : ""))
            } else if hover && !allFolders.isEmpty {
                folderMenu(label: AnyView(Chip(symbol: "folder.badge.plus", text: "Add to folder", dashed: true)))
            }
            if meeting.taskTotal > 0 {
                Button { router.openMeeting(meeting.id, tab: .tasks) } label: {
                    Chip(symbol: meeting.taskDone == meeting.taskTotal ? "checkmark.circle.fill" : "circle",
                         text: "\(meeting.taskDone) / \(meeting.taskTotal)")
                }
                .buttonStyle(.plain)
                .help("Action items done. Click to see them.")
            }
            moreMenu.opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(hover ? 0.035 : 0))
        .onHover { h in
            hover = h
            if h { preview = .meeting(meeting.id) }
        }
        .onTapGesture { router.meetingID = meeting.id }
        .contextMenu { menuItems }
        .confirmationDialog("Delete “\(meeting.displayTitle)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                // It may have been resumed or started summarizing while the dialog was open.
                if let m = store.meeting(id: meeting.id), scribe.canDelete(m) {
                    store.deleteMeeting(id: m.id)
                    if router.meetingID == m.id { router.meetingID = nil }
                }
            }
        } message: { Text("The transcript, summary, your notes and the audio recording are removed from this Mac.") }
    }

    private var isBusy: Bool {
        scribe.processingIDs.contains(meeting.id) || meeting.status == .processing || meeting.summaryStatus == .generating
    }

    private var statusText: String? {
        if scribe.processingIDs.contains(meeting.id) || meeting.status == .processing { return "Transcribing" }
        if meeting.summaryStatus == .generating { return "Summarizing" }
        if meeting.status == .failed || (meeting.error != nil && meeting.summaryStatus == .failed) { return "Needs attention" }
        if meeting.recordedMs > 0 { return MeetingRowFormat.duration(meeting.duration) }
        return nil
    }

    private var moreMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    @ViewBuilder private var menuItems: some View {
        Button("Open") { router.meetingID = meeting.id }
        Button("Open in Notepad Window") { notepad.open(meeting.id) }
        Button("Copy as Markdown") { TextInserter.copy(MeetingMarkdown.export(meeting, store: store)) }
        if !allFolders.isEmpty {
            Menu("Folders") {
                ForEach(allFolders) { f in
                    let inside = folders.contains { $0.id == f.id }
                    Button { store.setMeeting(meeting.id, inFolder: f.id, !inside) } label: {
                        if inside { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                    }
                }
            }
        }
        if !scribe.isRecording { Button("Resume Recording") { scribe.resume(meeting.id) } }
        if let path = meeting.audioPath {
            Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = true }
            .disabled(!scribe.canDelete(meeting))
    }

    private func folderMenu(label: AnyView) -> some View {
        Menu {
            ForEach(allFolders) { f in Button(f.name) { store.setMeeting(meeting.id, inFolder: f.id, true) } }
        } label: { label }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// Small rounded label used for folders and task counts.
struct Chip: View {
    let symbol: String
    let text: String
    var dashed = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(dashed ? Color.clear : Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(dashed ? 0.2 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        .fixedSize()
    }
}

private struct FolderCard: View {
    @EnvironmentObject var store: Store
    let folder: MeetingFolder
    let open: () -> Void
    @State private var renaming = false
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "folder.fill").font(.system(size: 20)).foregroundStyle(Color.accentColor.opacity(0.85))
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(folder.meetingCount == 1 ? "1 note" : "\(folder.meetingCount) notes")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
            .padding(14)
            .background(CardSurface())
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Color.primary.opacity(hover ? 0.03 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Rename…") { name = folder.name; renaming = true }
            Button("Delete Folder…", role: .destructive) { confirmDelete = true }
        }
        .alert("Rename Folder", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Rename") { if !name.trimmingCharacters(in: .whitespaces).isEmpty { store.renameFolder(id: folder.id, name: name) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(folder.name)”?", isPresented: $confirmDelete) {
            Button("Delete Folder", role: .destructive) { store.deleteFolder(id: folder.id) }
        } message: { Text("The notes in it are kept.") }
    }
}

struct EmptyNotes: View {
    var body: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.mic").font(.system(size: 26)).foregroundStyle(.tertiary)
                    .symbolRenderingMode(.hierarchical)
                Text("No notes yet").font(.system(size: 14, weight: .semibold))
                Text("Start Scribe when a call begins. The transcript, a summary and action items appear here.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        }
    }
}

// MARK: - Header button, setup and live card

/// Start / Stop in the page header.
struct RecordButton: View {
    @EnvironmentObject var scribe: ScribeController

    var body: some View {
        if scribe.isRecording {
            Button { scribe.stop() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Stop · \(Self.clock(scribe.elapsed))").monospacedDigit()
                    }
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.red)
        } else {
            Button { scribe.start() } label: {
                Label("Start Scribe", systemImage: "record.circle").padding(.horizontal, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Permission checklist shown while something blocks a complete recording.
struct SetupCard: View {
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        Card(padding: 0, spacing: 0) {
            CardHeader(title: "Complete setup to start Scribe", caption: "Scribe records two things, both only on this Mac.")
                .padding(16)
            Divider()
            SetupRow(symbol: "mic.fill", tint: .orange, title: "Microphone", detail: "Captures what you say") {
                if permissions.microphone == .authorized { GrantedLabel() }
                else { Button("Turn On") { Task { _ = await permissions.requestMicrophone() } } }
            }
            Divider().padding(.leading, 58)
            SetupRow(symbol: "speaker.wave.2.fill", tint: .purple, title: "System audio", detail: systemDetail) {
                systemTrailing
            }
        }
        .onAppear { permissions.refresh() }
    }

    private var systemDetail: String {
        guard ScribeController.systemAudioSupported else { return "Needs macOS 14.4 or later. Until then only your microphone is recorded." }
        switch permissions.systemAudio {
        case .authorized: return "Captures what others say on the call"
        case .denied: return "Turned off. Allow Shout under System Settings › Privacy & Security › Screen & System Audio Recording › System Audio Recording Only."
        case .notDetermined: return "Captures what others say on the call. Turn it on and macOS asks for permission."
        case .unknown:
            switch settings.settings.scribeSystemAudio {
            case .working: return "Captures what others say on the call"
            case .unknown: return "Captures what others say on the call. macOS asks for permission when you turn it on."
            case .silent: return "Shout didn't hear any call audio last time. Allow Shout under System Audio Recording Only."
            }
        }
    }

    @ViewBuilder private var systemTrailing: some View {
        if ScribeController.systemAudioSupported {
            if permissions.systemAudioAllowed { GrantedLabel() }
            else if permissions.systemAudio == .denied { Button("Open Settings…") { Permissions.openSystemAudioSettings() } }
            else { Button("Turn On") { Task { await permissions.requestSystemAudio() } } }
        }
    }
}

private struct SetupRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }
}

struct GrantedLabel: View {
    var body: some View {
        Label("On", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.green)
            .labelStyle(.titleAndIcon)
    }
}

/// The meeting being recorded right now.
private struct LiveCard: View {
    @EnvironmentObject var scribe: ScribeController
    @EnvironmentObject var router: AppRouter
    let meeting: Meeting

    var body: some View {
        Card(padding: 14, spacing: 10) {
            HStack(spacing: 12) {
                RecordingDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.displayTitle).font(.system(size: 13, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("Recording · \(RecordButton.clock(scribe.elapsed))\(meeting.sourceApp.map { " · \($0)" } ?? "")")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                SpeakerActivity(label: "You", active: scribe.micSpeaking, color: TranscriptStyle.you)
                SpeakerActivity(label: "Others", active: scribe.systemSpeaking, color: TranscriptStyle.others)
                Button("Open Notes") { router.meetingID = meeting.id }
            }
        }
    }
}

struct RecordingDot: View {
    var size: CGFloat = 10
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let pulse = 0.5 + 0.5 * cos(tl.date.timeIntervalSinceReferenceDate * .pi / 1.1)
            Circle().fill(Color.red).frame(width: size, height: size)
                .background(Circle().fill(Color.red.opacity(0.25 * pulse)).frame(width: size * 2, height: size * 2))
        }
        .frame(width: size * 2, height: size * 2)
        .accessibilityLabel("Recording")
    }
}

/// "You ●" / "Others ●": lights up while that side is speaking.
struct SpeakerActivity: View {
    let label: String
    let active: Bool
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(active ? color : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(active ? .primary : .secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(active ? color.opacity(0.12) : Color.primary.opacity(0.04)))
        .animation(.easeOut(duration: 0.15), value: active)
        .accessibilityLabel(active ? "\(label) speaking" : label)
    }
}

struct MeetingIcon: View {
    let bundleID: String?
    var body: some View {
        if let bundleID, AppIcons.icon(for: bundleID) != nil {
            AppIconView(bundleID: bundleID, size: 30)
        } else {
            Image(systemName: "doc.text")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
    }
}
