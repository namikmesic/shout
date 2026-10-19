import Foundation
import Combine

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public enum Mode: String, Sendable { case dictation, command, transform }
    public enum Status: String, Sendable { case inserted, copied, cancelled, empty, failed }

    public var id: Int64
    public var createdAt: Date
    public var mode: Mode
    public var status: Status
    public var rawText: String
    public var finalText: String
    public var editedText: String?
    public var appName: String?
    public var bundleID: String?
    public var url: String?
    public var audioSeconds: Double
    public var asrSeconds: Double
    public var llmSeconds: Double
    public var totalSeconds: Double
    public var wordCount: Int
    public var language: String?
    public var asrModel: String?
    public var llmModel: String?
    public var audioPath: String?
    public var error: String?
    public var instruction: String?

    public init(id: Int64, createdAt: Date, mode: Mode, status: Status, rawText: String, finalText: String,
                editedText: String? = nil, appName: String? = nil, bundleID: String? = nil, url: String? = nil,
                audioSeconds: Double, asrSeconds: Double, llmSeconds: Double, totalSeconds: Double, wordCount: Int,
                language: String? = nil, asrModel: String? = nil, llmModel: String? = nil, audioPath: String? = nil,
                error: String? = nil, instruction: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.mode = mode; self.status = status; self.rawText = rawText
        self.finalText = finalText; self.editedText = editedText; self.appName = appName; self.bundleID = bundleID
        self.url = url; self.audioSeconds = audioSeconds; self.asrSeconds = asrSeconds; self.llmSeconds = llmSeconds
        self.totalSeconds = totalSeconds; self.wordCount = wordCount; self.language = language; self.asrModel = asrModel
        self.llmModel = llmModel; self.audioPath = audioPath; self.error = error; self.instruction = instruction
    }
}

public struct DictionaryEntry: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable { case manual, auto }
    public var id: Int64
    /// The correct spelling (vocabulary) or, for replacements/snippets, the spoken trigger.
    public var phrase: String
    /// When set, `phrase` is replaced by this text ("say X, write Y" or snippet expansion).
    public var replacement: String?
    public var isSnippet: Bool
    public var isStarred: Bool
    public var source: Source
    public var observedAs: String?
    public var useCount: Int
    public var createdAt: Date

    public var isReplacement: Bool { replacement != nil && !isSnippet }

    public init(id: Int64, phrase: String, replacement: String?, isSnippet: Bool, isStarred: Bool, source: Source,
                observedAs: String?, useCount: Int, createdAt: Date) {
        self.id = id; self.phrase = phrase; self.replacement = replacement; self.isSnippet = isSnippet
        self.isStarred = isStarred; self.source = source; self.observedAs = observedAs; self.useCount = useCount
        self.createdAt = createdAt
    }
}

public struct Note: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
}

public struct UsageStats: Sendable, Equatable {
    public var totalWords = 0
    public var totalDictations = 0
    public var averageWPM: Double = 0
    public var dayStreak = 0
    public var weekStreak = 0
    public var wordsToday = 0
    public var minutesSaved: Double = 0
    public var topApps: [(name: String, words: Int)] = []

    public init() {}

    public static func == (a: UsageStats, b: UsageStats) -> Bool {
        a.totalWords == b.totalWords && a.totalDictations == b.totalDictations && a.dayStreak == b.dayStreak &&
            a.averageWPM == b.averageWPM && a.wordsToday == b.wordsToday && a.weekStreak == b.weekStreak &&
            a.minutesSaved == b.minutesSaved &&
            a.topApps.map(\.name) == b.topApps.map(\.name) && a.topApps.map(\.words) == b.topApps.map(\.words)
    }
}

/// Local persistence for history, dictionary, snippets and notes.
@MainActor
public final class Store: ObservableObject {
    public static let shared: Store = {
        // Demo mode (snapshots, screenshots): a throwaway database with sample data, so the user's
        // real history is never read.
        if ProcessInfo.processInfo.environment["SHOUT_DEMO_DATA"] != nil {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("shout-demo-\(UUID().uuidString).sqlite").path
            let store = try! Store(path: path)
            store.seedDemoData()
            return store
        }
        do { return try Store(path: AppPaths.database.path) }
        catch { fatalError("Cannot open database: \(error)") }
    }()

    /// Fills an empty database with realistic sample content (demo mode only).
    public func seedDemoData() {
        let samples: [(Int, String, String, String)] = [
            (0, "Slack", "com.tinyspeck.slackmacgap", "Can we move the sync to 3 PM and add the roadmap to the agenda?"),
            (0, "Mail", "com.apple.mail", "Hi Priya,\n\nThanks for the update on the Q3 numbers. I'll review them tonight and get back to you by Thursday.\n\nBest,\nSam"),
            (0, "Cursor", "com.todesktop.230313mzl4w4u92", "Rename getUserId to fetchUserId and update the import in index.ts."),
            (1, "Messages", "com.apple.MobileSMS", "Running 10 minutes late, save me a seat"),
            (1, "Notes", "com.apple.Notes", "For the launch we need three things: update the Kubernetes config, run the load tests, and write the release notes."),
            (2, "Slack", "com.tinyspeck.slackmacgap", "Shipped the fix for the login bug, let me know if you still see it"),
            (3, "Safari", "com.apple.Safari", "What's the difference between a process and a thread?"),
            (4, "Mail", "com.apple.mail", "Hi Joaquin, attaching the signed contract. Let me know if anything else is needed."),
            (6, "Notes", "com.apple.Notes", "Ideas for the offsite: a short retro, a planning session and a team dinner on Thursday."),
            (8, "Slack", "com.tinyspeck.slackmacgap", "Great work on the demo today, the new onboarding flow looks fantastic"),
            (9, "Cursor", "com.todesktop.230313mzl4w4u92", "Add a retry with exponential backoff around the upload call."),
            (11, "Messages", "com.apple.MobileSMS", "Happy birthday! Hope you have an amazing day"),
            (12, "Mail", "com.apple.mail", "Following up on our call, here are the next steps we agreed on."),
        ]
        let cal = Calendar.current
        for (i, s) in samples.enumerated() {
            let day = cal.date(byAdding: .day, value: -s.0, to: Date())!
            let date = cal.date(byAdding: .minute, value: -(i * 37 + 12), to: day)!
            let words = TextRules.wordCount(s.3)
            // Repeat entries so the activity chart has realistic daily totals.
            for k in 0..<(3 + (i * 7) % 9) {
                addHistory(HistoryEntry(id: 0, createdAt: date.addingTimeInterval(Double(-k * 400)), mode: .dictation,
                                        status: .inserted, rawText: s.3, finalText: s.3, appName: s.1, bundleID: s.2,
                                        audioSeconds: Double(words) / 2.6, asrSeconds: 0.09, llmSeconds: 0.6,
                                        totalSeconds: 0.72, wordCount: words, language: "en",
                                        asrModel: "Parakeet TDT 0.6B v3", llmModel: "Qwen3 4B Instruct"))
            }
        }
        addDictionaryEntry(phrase: "Kubernetes")
        addDictionaryEntry(phrase: "Priya")
        addDictionaryEntry(phrase: "Joaquin", source: .auto, observedAs: "Wakeen")
        addDictionaryEntry(phrase: "btw", replacement: "by the way")
        addDictionaryEntry(phrase: "my calendly link", replacement: "https://calendly.com/sam/30min", isSnippet: true)
        addDictionaryEntry(phrase: "my address", replacement: "1 Infinite Loop, Cupertino, CA 95014", isSnippet: true)
        // Notes over several days, so the Notes page shows its day sections.
        let now = Date().timeIntervalSince1970
        for (ago, title, body) in [
            (600.0, "Offsite ideas", "Short retro, planning session, team dinner on Thursday."),
            (3_400.0, "", "Call the venue about Thursday\nAsk whether the room has a projector and if lunch can be moved to 12:30."),
            (90_000.0, "Hiring loop", "Panel for the design role: Priya on portfolio, Joaquin on systems, Mei on collaboration. Debrief Friday."),
            (360_000.0, "Q4 goals", "Ship the Scribe beta, cut dictation latency below half a second, and publish the pricing page."),
        ] as [(Double, String, String)] {
            _ = try? db.run("INSERT INTO notes (title, body, created_at, updated_at) VALUES (?,?,?,?)",
                            title, body, now - ago - 86_400, now - ago)
        }
        reloadNotes()
        seedDemoMeetings()
    }

    public let db: SQLiteDB
    @Published public private(set) var dictionary: [DictionaryEntry] = []
    @Published public private(set) var notes: [Note] = []
    @Published public private(set) var revision = 0 // bumps whenever history changes
    /// Bumps whenever a meeting or one of its transcript lines changes.
    @Published public internal(set) var meetingsRevision = 0
    /// Sends the id of each meeting as it is deleted (so work still running for it can be cancelled).
    public let meetingDeleted = PassthroughSubject<String, Never>()
    /// Meetings whose summary a quit or crash left "generating" and that have no summary yet. Their status
    /// was reset when the database opened, before this process could start a summary of its own.
    public internal(set) var interruptedSummaryIDs: [String] = []

    /// Prompt mode's pictures (`PromptCaptureArchive`), next to this database: the real one's are in
    /// Application Support/Shout/Captures, a test or demo database's beside it.
    public let capturesRoot: URL

    public init(path: String) throws {
        capturesRoot = path == AppPaths.database.path ? AppPaths.captures : URL(fileURLWithPath: path + "-captures", isDirectory: true)
        db = try SQLiteDB(path: path)
        try migrate()
        // Nothing in this process can be summarizing or answering yet.
        interruptedSummaryIDs = resetSummariesLeftGenerating()
        interruptPendingAskAnswers()
        reloadDictionary()
        reloadNotes()
    }

    /// The schema, one step per version. A new database gets them all; a later version adds a step that changes
    /// the tables, and only steps newer than the database's `user_version` run, each in one transaction with it.
    private func migrate() throws {
        let steps: [(version: Int, apply: () throws -> Void)] = [
            (1, { try self.db.exec(Self.schema + Self.meetingsSchema + Self.speakersSchema) }),
        ]
        // Read once and throwing: a failed read must not run every step again as if the database were new.
        let current = try db.userVersion
        for step in steps where current < step.version {
            try db.transaction {
                try step.apply()
                try db.setUserVersion(step.version)
            }
        }
    }

    /// Dictation history, the Dictionary (words and snippets) and Notes.
    static let schema = """
    CREATE TABLE history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        created_at REAL NOT NULL,
        mode TEXT NOT NULL,
        status TEXT NOT NULL,
        raw_text TEXT NOT NULL DEFAULT '',
        final_text TEXT NOT NULL DEFAULT '',
        edited_text TEXT,
        app_name TEXT, bundle_id TEXT, url TEXT,
        audio_seconds REAL DEFAULT 0, asr_seconds REAL DEFAULT 0,
        llm_seconds REAL DEFAULT 0, total_seconds REAL DEFAULT 0,
        word_count INTEGER DEFAULT 0,
        language TEXT, asr_model TEXT, llm_model TEXT,
        audio_path TEXT, error TEXT, instruction TEXT
    );
    CREATE INDEX history_created ON history(created_at);
    CREATE TABLE dictionary (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        phrase TEXT NOT NULL,
        replacement TEXT,
        is_snippet INTEGER NOT NULL DEFAULT 0,
        is_starred INTEGER NOT NULL DEFAULT 0,
        source TEXT NOT NULL DEFAULT 'manual',
        observed_as TEXT,
        use_count INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL
    );
    CREATE UNIQUE INDEX dictionary_phrase ON dictionary(lower(phrase), is_snippet);
    CREATE TABLE notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        body TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    """

    // MARK: History

    @discardableResult
    public func addHistory(_ e: HistoryEntry) -> Int64 {
        let id = (try? db.run("""
            INSERT INTO history (created_at, mode, status, raw_text, final_text, edited_text, app_name, bundle_id, url,
              audio_seconds, asr_seconds, llm_seconds, total_seconds, word_count, language, asr_model, llm_model,
              audio_path, error, instruction)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, e.createdAt, e.mode.rawValue, e.status.rawValue, e.rawText, e.finalText, e.editedText, e.appName,
            e.bundleID, e.url, e.audioSeconds, e.asrSeconds, e.llmSeconds, e.totalSeconds, e.wordCount, e.language,
            e.asrModel, e.llmModel, e.audioPath, e.error, e.instruction)) ?? 0
        revision += 1
        return id
    }

    public func setEditedText(id: Int64, text: String) {
        _ = try? db.run("UPDATE history SET edited_text = ? WHERE id = ?", text, id)
        revision += 1
    }

    public func history(limit: Int = 200, offset: Int = 0, search: String? = nil) -> [HistoryEntry] {
        let rows: [SQLiteDB.Row]
        if let search, !search.isEmpty {
            let like = Self.likePattern(search)
            rows = (try? db.query("""
                SELECT * FROM history WHERE final_text LIKE ?1 ESCAPE '\\' OR raw_text LIKE ?1 ESCAPE '\\'
                  OR app_name LIKE ?1 ESCAPE '\\'
                ORDER BY created_at DESC LIMIT ?2 OFFSET ?3
                """, like, limit, offset)) ?? []
        } else {
            rows = (try? db.query("SELECT * FROM history ORDER BY created_at DESC LIMIT ? OFFSET ?", limit, offset)) ?? []
        }
        return rows.map(Self.historyEntry)
    }

    /// A `LIKE … ESCAPE '\'` pattern that matches `text` anywhere, with `%`, `_` and `\` taken literally.
    nonisolated static func likePattern(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    public func lastInsertableEntry() -> HistoryEntry? {
        (try? db.query("""
            SELECT * FROM history WHERE status IN ('inserted','copied') AND final_text != ''
            ORDER BY created_at DESC LIMIT 1
            """))?.first.map(Self.historyEntry)
    }

    public func deleteHistory(id: Int64) {
        if let path = (try? db.scalar("SELECT audio_path FROM history WHERE id = ?", id))?.string {
            try? FileManager.default.removeItem(atPath: path)
        }
        _ = try? db.run("DELETE FROM history WHERE id = ?", id)
        PromptCaptureArchive.remove(historyIDs: [id], root: capturesRoot)
        revision += 1
    }

    public func deleteAllHistory() {
        _ = try? db.run("DELETE FROM history")
        try? FileManager.default.removeItem(at: AppPaths.recordings)
        PromptCaptureArchive.removeAllLinked(root: capturesRoot)
        revision += 1
    }

    public func pruneHistory(olderThan date: Date) {
        let rows = (try? db.query("SELECT id, audio_path FROM history WHERE created_at < ?", date)) ?? []
        for r in rows { if let p = r["audio_path"]?.string { try? FileManager.default.removeItem(atPath: p) } }
        _ = try? db.run("DELETE FROM history WHERE created_at < ?", date)
        PromptCaptureArchive.remove(historyIDs: rows.compactMap { $0["id"]?.int }, root: capturesRoot)
        revision += 1
    }

    public func historyExists(id: Int64) -> Bool {
        ((try? db.scalar("SELECT EXISTS(SELECT 1 FROM history WHERE id = ?)", id))?.int ?? 1) != 0
    }

    /// Deletes Prompt mode pictures whose History entry is gone, and unsaved ones after a week.
    public func pruneCaptures(now: Date = Date()) {
        PromptCaptureArchive.prune(root: capturesRoot, now: now) { historyExists(id: $0) }
    }

    private static func historyEntry(_ r: SQLiteDB.Row) -> HistoryEntry {
        HistoryEntry(
            id: r["id"]?.int ?? 0,
            createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
            mode: HistoryEntry.Mode(rawValue: r["mode"]?.string ?? "") ?? .dictation,
            status: HistoryEntry.Status(rawValue: r["status"]?.string ?? "") ?? .inserted,
            rawText: r["raw_text"]?.string ?? "", finalText: r["final_text"]?.string ?? "",
            editedText: r["edited_text"]?.string, appName: r["app_name"]?.string, bundleID: r["bundle_id"]?.string,
            url: r["url"]?.string, audioSeconds: r["audio_seconds"]?.double ?? 0, asrSeconds: r["asr_seconds"]?.double ?? 0,
            llmSeconds: r["llm_seconds"]?.double ?? 0, totalSeconds: r["total_seconds"]?.double ?? 0,
            wordCount: Int(r["word_count"]?.int ?? 0), language: r["language"]?.string,
            asrModel: r["asr_model"]?.string, llmModel: r["llm_model"]?.string,
            audioPath: r["audio_path"]?.string, error: r["error"]?.string, instruction: r["instruction"]?.string)
    }

    // MARK: Stats

    public func stats(typingWPM: Double = 40) -> UsageStats {
        var s = UsageStats()
        let ok = "status IN ('inserted','copied')"
        if let r = try? db.query("SELECT COALESCE(SUM(word_count),0) w, COUNT(*) n, COALESCE(SUM(audio_seconds),0) a FROM history WHERE \(ok)").first {
            s.totalWords = Int(r["w"]?.int ?? 0)
            s.totalDictations = Int(r["n"]?.int ?? 0)
            let minutes = (r["a"]?.double ?? 0) / 60
            s.averageWPM = minutes > 0.05 ? Double(s.totalWords) / minutes : 0
            // Time saved vs typing the same words, minus the time spent speaking.
            s.minutesSaved = max(0, Double(s.totalWords) / typingWPM - minutes)
        }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        s.wordsToday = Int((try? db.scalar("SELECT COALESCE(SUM(word_count),0) FROM history WHERE \(ok) AND created_at >= ?", startOfDay).int) ?? 0)

        // Day streak: consecutive days (ending today or yesterday) with at least one dictation.
        let dayRows = (try? db.query("SELECT DISTINCT date(created_at, 'unixepoch', 'localtime') d FROM history WHERE \(ok) ORDER BY d DESC LIMIT 400")) ?? []
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        let days = Set(dayRows.compactMap { $0["d"]?.string })
        var cursor = startOfDay
        if !days.contains(fmt.string(from: cursor)) { cursor = cal.date(byAdding: .day, value: -1, to: cursor)! }
        while days.contains(fmt.string(from: cursor)) {
            s.dayStreak += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        // Week streak: consecutive ISO weeks with activity.
        let weeks = Set(days.compactMap { fmt.date(from: $0) }.map { cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: $0) })
        var wk = Date()
        if !weeks.contains(cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: wk)) {
            wk = cal.date(byAdding: .weekOfYear, value: -1, to: wk)!
        }
        while weeks.contains(cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: wk)) {
            s.weekStreak += 1
            wk = cal.date(byAdding: .weekOfYear, value: -1, to: wk)!
        }
        let apps = (try? db.query("SELECT app_name, SUM(word_count) w FROM history WHERE \(ok) AND app_name IS NOT NULL GROUP BY app_name ORDER BY w DESC LIMIT 5")) ?? []
        s.topApps = apps.compactMap { r in r["app_name"]?.string.map { ($0, Int(r["w"]?.int ?? 0)) } }
        return s
    }

    /// Words dictated per calendar day for the last `days` days (oldest first, zero-filled).
    public func dailyWords(days: Int = 14) -> [(day: Date, words: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        let rows = (try? db.query("""
            SELECT date(created_at, 'unixepoch', 'localtime') d, SUM(word_count) w FROM history
            WHERE status IN ('inserted','copied') AND created_at >= ? GROUP BY d
            """, start)) ?? []
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX")
        var byDay: [String: Int] = [:]
        for r in rows { if let d = r["d"]?.string { byDay[d] = Int(r["w"]?.int ?? 0) } }
        return (0..<days).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            return (day, byDay[fmt.string(from: day)] ?? 0)
        }
    }

    // MARK: Dictionary & snippets

    public func reloadDictionary() {
        let rows = (try? db.query("SELECT * FROM dictionary ORDER BY is_starred DESC, created_at DESC")) ?? []
        dictionary = rows.map { r in
            DictionaryEntry(id: r["id"]?.int ?? 0, phrase: r["phrase"]?.string ?? "",
                            replacement: r["replacement"]?.string, isSnippet: (r["is_snippet"]?.int ?? 0) != 0,
                            isStarred: (r["is_starred"]?.int ?? 0) != 0,
                            source: DictionaryEntry.Source(rawValue: r["source"]?.string ?? "") ?? .manual,
                            observedAs: r["observed_as"]?.string, useCount: Int(r["use_count"]?.int ?? 0),
                            createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0))
        }
    }

    public var vocabulary: [DictionaryEntry] { dictionary.filter { !$0.isSnippet && $0.replacement == nil } }
    public var replacements: [DictionaryEntry] { dictionary.filter { !$0.isSnippet && $0.replacement != nil } }
    public var snippets: [DictionaryEntry] { dictionary.filter(\.isSnippet) }

    /// Words passed to recognizers/LLM as vocabulary: starred first, then most used.
    public func vocabularyWords(limit: Int = 200) -> [String] {
        let words = vocabulary.sorted { ($0.isStarred ? 1 : 0, $0.useCount) > ($1.isStarred ? 1 : 0, $1.useCount) }.map(\.phrase)
        let replacementTargets = replacements.compactMap(\.replacement).filter { $0.count < 40 }
        return Array((words + replacementTargets).prefix(limit))
    }

    @discardableResult
    public func addDictionaryEntry(phrase: String, replacement: String? = nil, isSnippet: Bool = false,
                                   source: DictionaryEntry.Source = .manual, observedAs: String? = nil) -> Bool {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        let r = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try db.run("INSERT INTO dictionary (phrase, replacement, is_snippet, source, observed_as, created_at) VALUES (?,?,?,?,?,?)",
                       p, (r?.isEmpty ?? true) ? nil : r, isSnippet, source.rawValue, observedAs, Date())
            reloadDictionary()
            return true
        } catch { return false }
    }

    /// Saves an edited entry, trimmed like `addDictionaryEntry`. False when it wasn't saved: an empty phrase, or one
    /// another entry of the same kind already has.
    @discardableResult
    public func updateDictionaryEntry(_ e: DictionaryEntry) -> Bool {
        let p = e.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        let r = e.replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { reloadDictionary() }
        do {
            try db.run("UPDATE dictionary SET phrase = ?, replacement = ?, is_snippet = ?, is_starred = ? WHERE id = ?",
                       p, (r?.isEmpty ?? true) ? nil : r, e.isSnippet, e.isStarred, e.id)
            return true
        } catch { return false }
    }

    public func deleteDictionaryEntry(id: Int64) {
        _ = try? db.run("DELETE FROM dictionary WHERE id = ?", id)
        reloadDictionary()
    }

    public func bumpUsage(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        try? db.transaction {
            for id in ids { try db.run("UPDATE dictionary SET use_count = use_count + 1 WHERE id = ?", id) }
        }
        reloadDictionary()
    }

    // MARK: Notes

    public func reloadNotes() {
        let rows = (try? db.query("SELECT * FROM notes ORDER BY updated_at DESC")) ?? []
        notes = rows.map { r in
            Note(id: r["id"]?.int ?? 0, title: r["title"]?.string ?? "", body: r["body"]?.string ?? "",
                 createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
                 updatedAt: Date(timeIntervalSince1970: r["updated_at"]?.double ?? 0))
        }
    }

    @discardableResult
    public func addNote(title: String = "", body: String = "") -> Int64 {
        let id = (try? db.run("INSERT INTO notes (title, body, created_at, updated_at) VALUES (?,?,?,?)", title, body, Date(), Date())) ?? 0
        reloadNotes()
        return id
    }

    public func updateNote(id: Int64, title: String, body: String) {
        _ = try? db.run("UPDATE notes SET title = ?, body = ?, updated_at = ? WHERE id = ?", title, body, Date(), id)
        reloadNotes()
    }

    public func deleteNote(id: Int64) {
        _ = try? db.run("DELETE FROM notes WHERE id = ?", id)
        reloadNotes()
    }
}
