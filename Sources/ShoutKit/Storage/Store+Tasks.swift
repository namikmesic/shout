import Foundation

/// A task with the meeting it came from, for the My Tasks page.
public struct TaskListItem: Identifiable, Hashable, Sendable {
    public var task: MeetingTask
    /// "From …": the source meeting's title ("Untitled meeting" when it has none), kept after the meeting is
    /// deleted; nil for a task added by hand.
    public var meetingTitle: String?
    public var meetingCreatedAt: Date?
    /// When the task was archived (Archived view order).
    public var archivedAt: Date?

    public var id: String { task.id }
    /// The meeting still exists, so "Open meeting note" can go to it.
    public var canOpenMeeting: Bool { task.meetingID != nil }
    /// What My Tasks groups by: the meeting's date, else the task's own.
    public var groupDate: Date { meetingCreatedAt ?? task.createdAt }

    public init(task: MeetingTask, meetingTitle: String? = nil, meetingCreatedAt: Date? = nil, archivedAt: Date? = nil) {
        self.task = task; self.meetingTitle = meetingTitle; self.meetingCreatedAt = meetingCreatedAt; self.archivedAt = archivedAt
    }
}

/// The date sections of My Tasks.
public enum TaskGroup: String, CaseIterable, Sendable {
    case today, yesterday, lastWeek, older

    public var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .lastWeek: "Last week"
        case .older: "Older"
        }
    }

    public static func of(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> TaskGroup {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case 2..<7: return .lastWeek
        default: return .older
        }
    }

    /// Non-empty sections in order. Within a section, tasks that were already done when the page loaded
    /// (`doneAtLoad`, a snapshot, so ticking a box doesn't move the row) go last; the rest keep `sortOrder`.
    public static func sections(_ items: [TaskListItem], doneAtLoad: Set<String> = [], now: Date = Date(),
                                calendar: Calendar = .current) -> [(group: TaskGroup, items: [TaskListItem])] {
        let byGroup = Dictionary(grouping: items) { of($0.groupDate, now: now, calendar: calendar) }
        return allCases.compactMap { g in
            guard let list = byGroup[g], !list.isEmpty else { return nil }
            return (g, list.sorted { a, b in
                let da = doneAtLoad.contains(a.id), db = doneAtLoad.contains(b.id)
                if da != db { return !da }
                return (a.task.sortOrder, a.task.createdAt) < (b.task.sortOrder, b.task.createdAt)
            })
        }
    }
}

/// Matching generated action items against tasks a meeting already has, so "Update summary" doesn't add a
/// task again after the user edited, deleted or archived it, or the model reworded it. A missed match costs a
/// duplicate the user can delete; a wrong one silently loses an action item, so matching is strict: the owner
/// must be the same, stored tasks match by their exact text, and rewordings are recognized only against the
/// items of the summary being replaced (see `Store.addGeneratedTasks`).
enum TaskMatch {
    /// Lower-cased words joined by single spaces.
    static func key(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The keys in `todos.source_key`, one per line: the text the task was generated as, then each rewording a
    /// later summary was matched to it with. A task added by hand has none until it is edited or matched.
    static func sourceKeys(_ column: String?) -> [String] {
        column?.split(separator: "\n").map(String.init) ?? []
    }

    /// The owner as matching sees it: no owner, "You" and the user's name (or first name) are all the user.
    static func owner(_ owner: String?, userName: String?) -> String {
        let o = (owner ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = (userName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let first = user.split(separator: " ").first.map(String.init) ?? user
        return o.isEmpty || o == "you" || (!user.isEmpty && (o == user || o == first)) ? "you" : o
    }

    static let stopWords: Set<String> = ["a", "an", "the", "to", "for", "of", "on", "in", "at", "by", "with", "and", "or",
                                         "about", "from", "into", "up", "out", "it", "its", "this", "that", "these",
                                         "those", "their", "them", "his", "her", "our", "your", "my", "will", "should",
                                         "need", "needs", "please", "be", "is", "are", "also", "all", "any", "some"]

    /// Words the model swaps between rewordings of one task ("Share the deck with Priya" = "Send the deck to Priya").
    static let synonyms: [String: String] = ["share": "send", "email": "send", "forward": "send", "doc": "document"]

    /// Content words, with a plural "s" dropped ("decks" = "deck") and synonyms folded.
    static func words(_ key: String) -> Set<String> {
        Set(key.split(separator: " ").map(String.init).filter { !stopWords.contains($0) }.map { w in
            let singular = w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") ? String(w.dropLast()) : w
            return synonyms[singular] ?? singular
        })
    }

    /// A rewording of the same task: the same content words in any order, or the same plus a qualifier
    /// ("the updated deck"), with at least three quarters of the words shared. A different word on each side
    /// ("send"/"review", "Q3"/"Q4", "iOS"/"Android") is a different task, however long the rest.
    static func reworded(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        let (small, large) = x.count <= y.count ? (x, y) : (y, x)
        return small.isSubset(of: large) && Double(small.count) / Double(large.count) >= 0.75
    }
}

/// Tasks (action items): per meeting and across meetings (My Tasks, Archived).
extension Store {
    /// Tasks of one meeting (or all meetings when nil), not archived unless asked, in display order.
    public func tasks(meetingID: String? = nil, includeArchived: Bool = false) -> [MeetingTask] {
        var sql = "SELECT * FROM todos WHERE is_deleted = 0"
        var params: [Any?] = []
        if let meetingID { sql += " AND meeting_id = ?"; params.append(meetingID) }
        if !includeArchived { sql += " AND is_archived = 0" }
        sql += " ORDER BY sort_order, created_at"
        return ((try? db.query(sql, params: params)) ?? []).map(Self.task)
    }

    /// Tasks across all meetings for My Tasks. `archived` picks the Archived view (most recently archived
    /// first) instead of the others (newest meeting first, then display order); `done` keeps only done (true)
    /// or only open and in-progress (false) tasks; `search` matches titles.
    /// The rows `taskList(archived: true)` returns, counted.
    public func archivedTaskCount() -> Int {
        Int((try? db.scalar("SELECT COUNT(*) FROM todos WHERE is_deleted = 0 AND is_archived = 1").int) ?? 0)
    }

    public func taskList(archived: Bool = false, done: Bool? = nil, search: String? = nil) -> [TaskListItem] {
        var sql = """
            SELECT t.*, m.title AS m_title, m.created_at AS m_created_at FROM todos t LEFT JOIN meetings m ON m.id = t.meeting_id
            WHERE t.is_deleted = 0 AND t.is_archived = ?
            """
        var params: [Any?] = [archived]
        if let done { sql += done ? " AND t.status = 'done'" : " AND t.status != 'done'" }
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            sql += " AND t.title LIKE ? ESCAPE '\\'"
            params.append(Self.likePattern(search))
        }
        sql += archived
            ? " ORDER BY t.archived_at DESC, t.modified_at DESC"
            : " ORDER BY COALESCE(m.created_at, t.meeting_created_at, t.created_at) DESC, t.sort_order, t.created_at"
        return ((try? db.query(sql, params: params)) ?? []).map { r in
            let created = (r["m_created_at"]?.double ?? r["meeting_created_at"]?.double).map { Date(timeIntervalSince1970: $0) }
            // A meeting row, or the snapshot kept when it was deleted (its date is always set then).
            let title: String? = created == nil ? nil : {
                let t = (r["m_title"]?.string ?? r["meeting_title"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? "Untitled meeting" : t
            }()
            return TaskListItem(task: Self.task(r), meetingTitle: title, meetingCreatedAt: created,
                                archivedAt: r["archived_at"]?.double.map { Date(timeIntervalSince1970: $0) })
        }
    }

    /// Adds a task at the end of the list, or at the top (`atTop`, for "+ Add task" in My Tasks).
    @discardableResult
    public func addTask(meetingID: String?, title: String, owner: String? = nil, atTop: Bool = false) -> MeetingTask {
        insertTask(meetingID: meetingID, title: title, owner: owner, atTop: atTop, sourceKey: nil)
    }

    @discardableResult
    private func insertTask(meetingID: String?, title: String, owner: String?, atTop: Bool, sourceKey: String?) -> MeetingTask {
        var t = MeetingTask(meetingID: meetingID, title: title, owner: owner)
        try? insertTaskRow(&t, atTop: atTop, sourceKey: sourceKey)
        meetingsRevision += 1
        return t
    }

    /// Inserts `t` at the end of the list, or at the top, setting its `sortOrder`.
    private func insertTaskRow(_ t: inout MeetingTask, atTop: Bool, sourceKey: String?) throws {
        t.sortOrder = atTop
            ? (try db.scalar("SELECT COALESCE(MIN(sort_order), 0) FROM todos").double ?? 0) - 1000
            : (try db.scalar("SELECT COALESCE(MAX(sort_order), 0) FROM todos").double ?? 0) + 1000
        try db.run("""
            INSERT INTO todos (id, meeting_id, title, owner, status, is_archived, sort_order, created_at, modified_at, source_key)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """, t.id, t.meetingID, t.title, t.owner, t.status.rawValue, t.isArchived, t.sortOrder, t.createdAt, t.modifiedAt,
            sourceKey)
    }

    /// Adds generated action items, skipping the ones the meeting already has or had. An item is skipped when,
    /// for the same owner (no owner, "You" and `userName` are all the user):
    /// - a task of the meeting (deleted and archived ones too) has exactly its text, as generated or matched
    ///   (so edits don't matter) or as it reads now;
    /// - it rewords (`TaskMatch.reworded`) an item of the summary being replaced (`previous`, e.g.
    ///   `MeetingSummarizer.actionItems(in: oldSummary)`) that became, or was matched to, a task. Its wording is
    ///   then saved as another key of that task: the new summary has this wording, which the next Update's
    ///   rewording must still match. Items the user typed into the summary never became tasks, so they don't
    ///   keep the model's matching item from becoming one;
    /// - an earlier item of `items` has exactly its text.
    public func addGeneratedTasks(meetingID: String, items: [(owner: String?, text: String)], previous: [String] = [],
                                  userName: String? = nil) {
        var inserted = false
        do {
            // All or nothing, and the stored tasks are read in the same transaction: a failed read must not pass
            // for "no tasks yet" and add back the ones the user deleted or edited.
            try db.transaction {
                let rows = try db.query("SELECT id, title, owner, source_key FROM todos WHERE meeting_id = ?", meetingID)
                let stored = rows.map { r in
                    let title = TaskMatch.key(r["title"]?.string ?? "")
                    return (id: r["id"]?.string ?? "", title: title, owner: TaskMatch.owner(r["owner"]?.string, userName: userName),
                            keys: Set([title] + TaskMatch.sourceKeys(r["source_key"]?.string)))
                }
                let previousKeys = Set(previous.map(TaskMatch.key))
                let replaced = stored.flatMap { s in
                    s.keys.intersection(previousKeys).map { (id: s.id, title: s.title, owner: s.owner, key: $0) }
                }
                var added = Set<String>()
                for item in items {
                    let key = TaskMatch.key(item.text), owner = TaskMatch.owner(item.owner, userName: userName)
                    guard !key.isEmpty, added.insert(owner + "|" + key).inserted,
                          !stored.contains(where: { $0.owner == owner && $0.keys.contains(key) }) else { continue }
                    if let match = replaced.first(where: { $0.owner == owner && TaskMatch.reworded($0.key, key) }) {
                        // A task with no source key yet (added by hand) keeps its title as one.
                        try db.run("UPDATE todos SET source_key = COALESCE(source_key, ?) || char(10) || ? WHERE id = ?",
                                   match.title, key, match.id)
                        continue
                    }
                    var t = MeetingTask(meetingID: meetingID, title: item.text, owner: item.owner)
                    try insertTaskRow(&t, atTop: false, sourceKey: key)
                    inserted = true
                }
            }
        } catch {
            NSLog("Shout: action items of meeting \(meetingID) not saved: \(error.localizedDescription)")
            return
        }
        if inserted { meetingsRevision += 1 }
    }

    public func updateTask(_ t: MeetingTask) {
        // A task added by hand has no source key, so its title is its only key: the first
        // edit keeps the title it replaces as the key, so the next summary doesn't add the task again.
        let before = (try? db.query("SELECT title FROM todos WHERE id = ? AND source_key IS NULL", t.id))?.first?["title"]?.string
        let oldKey = before.map(TaskMatch.key).flatMap { $0.isEmpty || $0 == TaskMatch.key(t.title) ? nil : $0 }
        _ = try? db.run("""
            UPDATE todos SET title = ?, owner = ?, status = ?, sort_order = ?, modified_at = ?,
              archived_at = CASE WHEN ? = 0 THEN NULL WHEN is_archived = 0 THEN ? ELSE archived_at END, is_archived = ?,
              source_key = COALESCE(source_key, ?)
            WHERE id = ?
            """, t.title, t.owner, t.status.rawValue, t.sortOrder, Date(), t.isArchived, Date(), t.isArchived, oldKey, t.id)
        meetingsRevision += 1
    }

    /// Archives or restores tasks (My Tasks bulk actions, "Archive all", Undo).
    public func setTasksArchived(ids: [String], _ archived: Bool) {
        guard !ids.isEmpty else { return }
        let now = Date()
        try? db.transaction {
            for id in ids {
                try db.run("""
                    UPDATE todos SET archived_at = CASE WHEN ? = 0 THEN NULL WHEN is_archived = 0 THEN ? ELSE archived_at END,
                      is_archived = ?, modified_at = ? WHERE id = ?
                    """, archived, now, archived, now, id)
            }
        }
        meetingsRevision += 1
    }

    public func deleteTask(id: String) {
        deleteTasks(ids: [id])
    }

    /// Deleted tasks are kept, hidden, so a later summary doesn't add them back (and Undo can restore them).
    public func deleteTasks(ids: [String]) {
        guard !ids.isEmpty else { return }
        try? db.transaction {
            for id in ids { try db.run("UPDATE todos SET is_deleted = 1, modified_at = ? WHERE id = ?", Date(), id) }
        }
        meetingsRevision += 1
    }

    /// Undo for `deleteTasks`.
    public func restoreDeletedTasks(ids: [String]) {
        guard !ids.isEmpty else { return }
        try? db.transaction {
            for id in ids { try db.run("UPDATE todos SET is_deleted = 0, modified_at = ? WHERE id = ?", Date(), id) }
        }
        meetingsRevision += 1
    }

    static func task(_ r: SQLiteDB.Row) -> MeetingTask {
        MeetingTask(id: r["id"]?.string ?? "", meetingID: r["meeting_id"]?.string, title: r["title"]?.string ?? "",
                    owner: r["owner"]?.string, status: MeetingTask.Status(rawValue: r["status"]?.string ?? "") ?? .open,
                    isArchived: (r["is_archived"]?.int ?? 0) != 0, sortOrder: r["sort_order"]?.double ?? 0,
                    createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
                    modifiedAt: Date(timeIntervalSince1970: r["modified_at"]?.double ?? 0))
    }
}
