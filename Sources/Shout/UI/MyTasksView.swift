import SwiftUI
import ShoutKit

/// My Tasks: the action items of every meeting (and ones added here) in one list, grouped by when they came up,
/// with search and an Archived view to bring archived items back.
struct MyTasksView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: AppRouter
    @State private var items: [TaskListItem] = []
    @State private var archivedCount = 0
    /// Tasks already done when the page opened sink to the end of their section; ticking one off doesn't move it.
    @State private var doneAtLoad: Set<String> = []
    @State private var showingArchived: Bool
    @State private var search = ""
    @State private var adding = false
    @State private var newTitle = ""
    @FocusState private var addFocused: Bool
    @State private var reloadTask: Task<Void, Never>?
    @State private var confirmArchive: (group: TaskGroup, ids: [String])?
    @State private var undo: UndoAction?
    @State private var undoTimer: Task<Void, Never>?
    @AppStorage("ShoutMyTasksCollapsed") private var collapsed = "lastWeek,older"

    /// Offered for a few seconds after archiving or deleting.
    struct UndoAction: Equatable {
        enum Kind { case archived, deleted }
        let kind: Kind
        let ids: [String]
        let text: String
    }

    init(showingArchived: Bool = false) {
        _showingArchived = State(initialValue: showingArchived)
    }

    var body: some View {
        Page(title: "My Tasks", subtitle: "Action items from your meetings, and anything you add here.") {
            Button(action: startAdding) { Label("Add Task", systemImage: "plus").padding(.horizontal, 2) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a task (⌘N)")
                .disabled(showingArchived)
        } content: {
            toolbar
            if showingArchived { archivedList } else { openList }
        }
        .overlay(alignment: .bottom) {
            if let undo { undoToast(undo).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.easeOut(duration: 0.2), value: undo)
        .onAppear {
            let loaded = reload()
            // The open list's, whichever tab the page opens on.
            let open = showingArchived ? store.taskList(archived: false) : loaded
            doneAtLoad = Set(open.filter { $0.task.status == .done }.map(\.id))
        }
        // Nothing left running for a page that is gone; its Undo goes with it.
        .onDisappear { reloadTask?.cancel(); undoTimer?.cancel(); undo = nil }
        // Coalesced: during a meeting the store changes with every transcript line. Changes made on this page
        // refresh at once (`changed`).
        .onChange(of: store.meetingsRevision) { _, _ in scheduleReload() }
        .onChange(of: search) { _, _ in scheduleReload() }
        .onChange(of: showingArchived) { _, _ in reload() }
        // ⌘Q with a task typed in the add row keeps it, as Return or clicking elsewhere would.
        .onReceive(NotificationCenter.default.publisher(for: .shoutFlushEdits)) { _ in if adding { commitAdd() } }
        .confirmationDialog(archiveTitle, isPresented: Binding(get: { confirmArchive != nil }, set: { if !$0 { confirmArchive = nil } })) {
            Button("Archive All") {
                if let c = confirmArchive { archive(c.ids, text: "Archived \(c.ids.count == 1 ? "1 task" : "\(c.ids.count) tasks")") }
                confirmArchive = nil
            }
        } message: { Text("You can restore them any time from Archived.") }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                tabButton("Tasks", selected: !showingArchived) { showingArchived = false }
                tabButton(archivedCount == 0 ? "Archived" : "Archived (\(archivedCount))", selected: showingArchived) {
                    showingArchived = true
                    adding = false
                }
                Spacer()
                SearchField(text: $search, prompt: "Search tasks", onEscape: { search = "" })
                    .frame(width: 220)
                    .padding(.bottom, 6)
            }
            Divider()
        }
    }

    private func tabButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15), action) } label: {
            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                Rectangle().fill(selected ? Color.primary : .clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Open tasks

    @ViewBuilder private var openList: some View {
        if adding { addRow }
        if items.isEmpty && !adding {
            if search.isEmpty {
                Card {
                    EmptyStateView(symbol: "checklist", title: "No tasks yet", message: "Action items from your meetings show up here.")
                        .frame(height: 200)
                }
            } else {
                noMatches
            }
        } else {
            ForEach(TaskGroup.sections(items, doneAtLoad: doneAtLoad), id: \.group) { section in
                sectionView(section.group, section.items)
            }
        }
    }

    private func sectionView(_ group: TaskGroup, _ list: [TaskListItem]) -> some View {
        let isCollapsed = collapsedGroups.contains(group.rawValue)
        let done = list.filter { $0.task.status == .done }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { toggle(group) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .bold))
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Text(group.title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6)
                        Text("\(done)/\(list.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(done) of \(list.count) done")
                .accessibilityValue(isCollapsed ? "collapsed" : "expanded")
                Spacer()
                if !isCollapsed {
                    Button("Archive All") { confirmArchive = (group, list.map(\.id)) }
                        .buttonStyle(.borderless).font(.system(size: 12))
                }
            }
            .padding(.leading, 2)
            if !isCollapsed {
                Card(padding: 0, spacing: 0) {
                    ForEach(list) { item in
                        row(item) { EmptyView() }
                        if item.id != list.last?.id { Divider().padding(.leading, 38) }
                    }
                }
            }
        }
    }

    private var addRow: some View {
        Card(padding: 0, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.secondary)
                TextField("Untitled task", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($addFocused)
                    .onSubmit(commitAdd)
                    .onExitCommand { newTitle = ""; adding = false }
                    // Focused once the field exists (asking before it does can be dropped).
                    .onAppear { addFocused = true }
                    .onChange(of: addFocused) { _, f in if !f { commitAdd(); adding = false } }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    // MARK: Archived

    @ViewBuilder private var archivedList: some View {
        if items.isEmpty {
            if search.isEmpty {
                Card {
                    EmptyStateView(symbol: "archivebox", title: "Nothing archived", message: "Tasks you archive show up here.")
                        .frame(height: 200)
                }
            } else {
                noMatches
            }
        } else {
            Card(padding: 0, spacing: 0) {
                ForEach(items) { item in
                    row(item) {
                        Button("Unarchive") { store.setTasksArchived(ids: [item.id], false); changed() }
                            .buttonStyle(.borderless).font(.system(size: 12))
                    }
                    if item.id != items.last?.id { Divider().padding(.leading, 38) }
                }
            }
        }
    }

    private var noMatches: some View {
        Text("No tasks match your search.").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(.vertical, 8)
    }

    // MARK: Rows

    private func row<Trailing: View>(_ item: TaskListItem, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            TaskLine(task: item.task,
                     onArchiveToggled: { t in if t.isArchived { offerUndo(.archived, [t.id], "Archived “\(t.title)”") } },
                     onDeleted: { t in offerUndo(.deleted, [t.id], "Deleted “\(t.title)”") },
                     onChanged: changed)
            if let from = item.meetingTitle { source(from, item) }
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// "From <meeting>": opens the meeting on its Tasks tab while it still exists.
    @ViewBuilder private func source(_ title: String, _ item: TaskListItem) -> some View {
        let label = HStack(spacing: 3) {
            Text(title).lineLimit(1).truncationMode(.tail)
            if item.canOpenMeeting { Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.system(size: 11.5)).foregroundStyle(.secondary)
        .frame(maxWidth: 200, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
        if let id = item.task.meetingID, item.canOpenMeeting {
            Button { router.openMeeting(id, tab: .tasks) } label: { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("From “\(title)”. Click to open it.")
                .accessibilityLabel("Open \(title)")
        } else {
            label.help("From “\(title)”, which was deleted")
        }
    }

    private func undoToast(_ u: UndoAction) -> some View {
        HStack(spacing: 12) {
            Text(u.text).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
            Button("Undo") {
                switch u.kind {
                case .archived: store.setTasksArchived(ids: u.ids, false)
                case .deleted: store.restoreDeletedTasks(ids: u.ids)
                }
                undo = nil
                changed()
            }
            .buttonStyle(.borderless).font(.system(size: 12.5, weight: .semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .frame(maxWidth: 480)
        .padding(.bottom, 18)
    }

    // MARK: Data

    @discardableResult
    private func reload() -> [TaskListItem] {
        let loaded = store.taskList(archived: showingArchived, search: search)
        items = loaded
        archivedCount = showingArchived && search.isEmpty ? loaded.count : store.archivedTaskCount()
        return loaded
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { reload() }
        }
    }

    /// A change made on this page shows at once: rows, section counts and the Archived count don't wait for the
    /// coalescing delay, so a quick second click acts on what the first one did.
    private func changed() {
        reloadTask?.cancel()
        reload()
    }

    private var collapsedGroups: Set<String> { Set(collapsed.split(separator: ",").map(String.init)) }

    private func toggle(_ g: TaskGroup) {
        var set = collapsedGroups
        if set.contains(g.rawValue) { set.remove(g.rawValue) } else { set.insert(g.rawValue) }
        withAnimation(.easeOut(duration: 0.15)) { collapsed = set.sorted().joined(separator: ",") }
    }

    private var archiveTitle: String {
        guard let c = confirmArchive else { return "" }
        return "Archive \(c.ids.count == 1 ? "1 task" : "\(c.ids.count) tasks") from \(c.group.title)?"
    }

    private func archive(_ ids: [String], text: String) {
        store.setTasksArchived(ids: ids, true)
        changed()
        offerUndo(.archived, ids, text)
    }

    /// Opens the add row, which focuses itself as it appears (or focuses it if it is already open).
    private func startAdding() {
        showingArchived = false
        if adding { addFocused = true } else { adding = true }
    }

    /// Return adds the task at the top and keeps the field open for the next one.
    private func commitAdd() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        newTitle = ""
        guard !title.isEmpty else { return }
        store.addTask(meetingID: nil, title: title, atTop: true)
        changed()
    }

    private func offerUndo(_ kind: UndoAction.Kind, _ ids: [String], _ text: String) {
        let action = UndoAction(kind: kind, ids: ids, text: text)
        undo = action
        undoTimer?.cancel()
        undoTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled && undo == action { undo = nil }
        }
    }
}
