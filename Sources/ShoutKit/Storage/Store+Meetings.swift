import Foundation
import ShoutLLM

/// Meetings (Scribe): schema and queries.
extension Store {
    /// Meetings, their transcript lines, tasks, folders and Ask chats.
    /// - `meetings.summary_ready_seq`: every generated summary gets the next number, and its "summary ready"
    ///   notification claims it once (`summary_notified_seq`).
    /// - `meetings.title_attempt_seq`: the recording (`latest_stop_seq`) the launch title scan last tried to name, so
    ///   it moves on to other meetings instead of trying the same ones at every launch.
    /// - `todos.is_deleted`: deleted tasks are kept, so "Update summary" doesn't bring them back.
    /// - `todos.source_key`: the normalized texts a generated task was generated or matched as, never changed by edits
    ///   (`TaskMatch.sourceKeys`). `meeting_title` and `meeting_created_at` keep "From …" after the meeting is deleted.
    static let meetingsSchema = """
    CREATE TABLE meetings (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL,
        started_at REAL,
        ended_at REAL,
        recorded_ms INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'recording',
        calendar_event_id TEXT,
        calendar_occurrence_start REAL,
        participant_names TEXT,
        notes TEXT NOT NULL DEFAULT '',
        summary TEXT,
        summary_stop_seq INTEGER,
        latest_stop_seq INTEGER NOT NULL DEFAULT 0,
        processed_stop_seq INTEGER NOT NULL DEFAULT 0,
        audio_path TEXT,
        has_system_audio INTEGER NOT NULL DEFAULT 0,
        source_app TEXT,
        source_bundle_id TEXT,
        error TEXT,
        modified_at REAL NOT NULL,
        summary_status TEXT,
        summary_overview TEXT,
        summary_edited INTEGER NOT NULL DEFAULT 0,
        summary_ready_seq INTEGER NOT NULL DEFAULT 0,
        summary_notified_seq INTEGER NOT NULL DEFAULT 0,
        title_attempt_seq INTEGER
    );
    CREATE INDEX meetings_created ON meetings(created_at);
    CREATE INDEX meetings_created_id ON meetings(created_at, id);
    CREATE TABLE meeting_segments (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        seq INTEGER NOT NULL,
        source TEXT NOT NULL,
        speaker TEXT,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        text TEXT NOT NULL DEFAULT '',
        raw_text TEXT,
        edited_text TEXT,
        words INTEGER NOT NULL DEFAULT 0,
        latched INTEGER NOT NULL DEFAULT 0,
        marker TEXT,
        epoch REAL,
        speaker_origin TEXT
    );
    CREATE INDEX meeting_segments_meeting ON meeting_segments(meeting_id, start_ms);
    CREATE TABLE todos (
        id TEXT PRIMARY KEY,
        meeting_id TEXT REFERENCES meetings(id) ON DELETE SET NULL,
        title TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'open',
        is_archived INTEGER NOT NULL DEFAULT 0,
        sort_order REAL NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        modified_at REAL NOT NULL,
        owner TEXT,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        source_key TEXT,
        archived_at REAL,
        meeting_title TEXT,
        meeting_created_at REAL
    );
    CREATE INDEX todos_meeting ON todos(meeting_id);
    CREATE TABLE folders (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at REAL NOT NULL,
        sort_order REAL NOT NULL DEFAULT 0
    );
    CREATE TABLE meeting_folders (
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        folder_id TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
        PRIMARY KEY (meeting_id, folder_id)
    );
    CREATE TABLE ask_chats (
        id TEXT PRIMARY KEY,
        meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,
        title TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL,
        modified_at REAL NOT NULL,
        last_accessed_at REAL NOT NULL
    );
    CREATE INDEX ask_chats_meeting ON ask_chats(meeting_id, modified_at);
    CREATE TABLE ask_messages (
        id TEXT PRIMARY KEY,
        chat_id TEXT NOT NULL REFERENCES ask_chats(id) ON DELETE CASCADE,
        turn_id TEXT NOT NULL,
        local_order INTEGER NOT NULL,
        role TEXT NOT NULL,
        status TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        metadata TEXT,
        created_at REAL NOT NULL
    );
    CREATE UNIQUE INDEX ask_messages_order ON ask_messages(chat_id, local_order);

    """

    nonisolated private static let meetingColumns = """
        m.*,
        (SELECT COALESCE(SUM(words), 0) FROM meeting_segments s WHERE s.meeting_id = m.id AND s.latched = 0) AS word_count,
        (SELECT COUNT(*) FROM todos t WHERE t.meeting_id = m.id AND t.is_archived = 0 AND t.is_deleted = 0) AS task_total,
        (SELECT COUNT(*) FROM todos t WHERE t.meeting_id = m.id AND t.is_archived = 0 AND t.is_deleted = 0 AND t.status = 'done') AS task_done
        """

    // MARK: Meetings

    /// Inserts a new meeting's title, notes, summary and recording state. The calendar link and attendees
    /// (`setMeetingCalendarEvent`) and the summary's status and overview (`setSummary`) have their own setters.
    public func createMeeting(_ m: Meeting) {
        _ = try? db.run("""
            INSERT INTO meetings (id, title, created_at, started_at, ended_at, recorded_ms, status, notes, summary,
              latest_stop_seq, processed_stop_seq, audio_path, has_system_audio, source_app, source_bundle_id, error, modified_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, m.id, m.title, m.createdAt, m.startedAt, m.endedAt, m.recordedMs, m.status.rawValue, m.notes, m.summary,
            m.latestStopSeq, m.processedStopSeq, m.audioPath, m.hasSystemAudio, m.sourceApp, m.sourceBundleID, m.error, Date())
        meetingsRevision += 1
    }

    /// Writes the recording state of the meeting (not the title, notes or summary, which have their own setters).
    public func updateMeetingState(_ m: Meeting) {
        _ = try? db.run("""
            UPDATE meetings SET started_at = ?, ended_at = ?, recorded_ms = ?, status = ?, latest_stop_seq = ?,
              processed_stop_seq = ?, audio_path = ?, has_system_audio = ?, source_app = ?, source_bundle_id = ?, error = ?,
              modified_at = ? WHERE id = ?
            """, m.startedAt, m.endedAt, m.recordedMs, m.status.rawValue, m.latestStopSeq, m.processedStopSeq,
            m.audioPath, m.hasSystemAudio, m.sourceApp, m.sourceBundleID, m.error, Date(), m.id)
        meetingsRevision += 1
    }

    /// Links a meeting to a calendar event and records its attendees.
    public func setMeetingCalendarEvent(id: String, eventID: String?, occurrenceStart: Date?, participants: [String]) {
        let json = (try? JSONEncoder().encode(participants)).flatMap { String(data: $0, encoding: .utf8) }
        _ = try? db.run("""
            UPDATE meetings SET calendar_event_id = ?, calendar_occurrence_start = ?, participant_names = ?, modified_at = ?
            WHERE id = ?
            """, eventID, occurrenceStart, json, Date(), id)
        meetingsRevision += 1
    }

    // MARK: Summary

    public func setSummaryStatus(id: String, _ status: Meeting.SummaryStatus, error: String? = nil) {
        _ = try? db.run("UPDATE meetings SET summary_status = ?, error = COALESCE(?, error), modified_at = ? WHERE id = ?",
                        status.rawValue, error, Date(), id)
        meetingsRevision += 1
    }

    /// Stores a generated or edited summary. `stopSeq` is the recording it covers (nil keeps the current one);
    /// `edited` marks the user's own changes, which "Update summary" asks before replacing.
    /// A too-short or no-speech result never erases a summary the meeting already has (it was allowed once,
    /// with "Summarize Anyway", and may hold the user's edits): that summary stays, ready, still covering the
    /// recording it covered.
    public func setSummary(id: String, markdown: String?, overview: String?, status: Meeting.SummaryStatus, stopSeq: Int? = nil,
                           edited: Bool = false) {
        if markdown == nil, status == .tooShort || status == .noSpeech {
            let kept = (try? db.update("""
                UPDATE meetings SET summary_status = 'ready', processed_stop_seq = COALESCE(?, processed_stop_seq), modified_at = ?
                WHERE id = ? AND summary IS NOT NULL
                """, stopSeq, Date(), id)) ?? 0
            if kept > 0 { meetingsRevision += 1; return }
        }
        // A newly generated summary gets the next number, which its "summary ready" notification claims.
        let generated = status == .ready && markdown != nil && !edited
        _ = try? db.run("""
            UPDATE meetings SET summary = ?, summary_overview = ?, summary_status = ?, summary_edited = ?,
              summary_stop_seq = COALESCE(?, summary_stop_seq), processed_stop_seq = COALESCE(?, processed_stop_seq),
              summary_ready_seq = summary_ready_seq + ?, modified_at = ? WHERE id = ?
            """, markdown, overview, status.rawValue, edited, stopSeq, stopSeq, generated ? 1 : 0, Date(), id)
        meetingsRevision += 1
    }

    /// Claims the "Your summary is ready!" notification for the meeting's latest generated summary. True exactly
    /// once per summary (also claim it without posting when the user is already looking at the meeting).
    public func claimSummaryReadyNotification(id: String) -> Bool {
        let claimed = (try? db.update("""
            UPDATE meetings SET summary_notified_seq = summary_ready_seq
            WHERE id = ? AND summary_status = 'ready' AND summary IS NOT NULL AND summary_notified_seq < summary_ready_seq
            """, id)) ?? 0
        return claimed > 0
    }

    /// Puts summaries a quit or crash left "generating" back to what they were (runs when the database opens).
    /// Returns the meetings among them that have no summary yet.
    func resetSummariesLeftGenerating() -> [String] {
        let ids = ((try? db.query("SELECT id FROM meetings WHERE summary_status = 'generating' AND summary IS NULL")) ?? [])
            .compactMap { $0["id"]?.string }
        _ = try? db.run("""
            UPDATE meetings SET summary_status = CASE WHEN summary IS NULL THEN 'none' ELSE 'ready' END
            WHERE summary_status = 'generating'
            """)
        return ids
    }

    /// Summaries left "generating" by a quit or crash were reset when the database opened, before this process
    /// could start one, so a summary started right after launch is never touched. Returns the interrupted
    /// meetings that have no summary yet, to run again: once (later calls return none).
    @discardableResult
    public func resetInterruptedSummaries() -> [String] {
        defer { interruptedSummaryIDs = [] }
        return interruptedSummaryIDs
    }

    public func setMeetingTitle(id: String, title: String) {
        _ = try? db.run("UPDATE meetings SET title = ?, modified_at = ? WHERE id = ?", title, Date(), id)
        meetingsRevision += 1
    }

    /// Sets a generated title only while the meeting has none, so a title the user typed or the calendar gave
    /// in the meantime wins. Returns whether it was written.
    @discardableResult
    public func setTitleIfBlank(id: String, title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let changed = (try? db.update("UPDATE meetings SET title = ?, modified_at = ? WHERE id = ? AND \(Self.isBlank("title"))",
                                      t, Date(), id)) ?? 0
        if changed > 0 { meetingsRevision += 1 }
        return changed > 0
    }

    /// SQL: the text column is empty or only whitespace.
    nonisolated static func isBlank(_ column: String) -> String { "trim(\(column), ' ' || char(9, 10, 13)) = ''" }

    public func setMeetingNotes(id: String, notes: String) {
        _ = try? db.run("UPDATE meetings SET notes = ?, modified_at = ? WHERE id = ?", notes, Date(), id)
        meetingsRevision += 1
    }

    // Read-only lookups are nonisolated so Ask can gather its sources off the main thread; `db` serializes access.
    nonisolated public func meeting(id: String) -> Meeting? {
        (try? db.query("SELECT \(Self.meetingColumns) FROM meetings m WHERE m.id = ?", id))?.first.map(Self.meeting)
    }

    /// Newest first, a page at a time: pass the last meeting of the previous page as `before` to get the next
    /// one. `search` matches titles, notes, summaries, attendees, task titles and transcript text.
    nonisolated public func meetings(search: String? = nil, before: Meeting? = nil, limit: Int = 500) -> [Meeting] {
        var conditions: [String] = [], params: [Any?] = []
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
            conditions.append("""
                (m.title LIKE ?1 ESCAPE '\\' OR m.notes LIKE ?1 ESCAPE '\\' OR m.summary LIKE ?1 ESCAPE '\\'
                 OR m.participant_names LIKE ?1 ESCAPE '\\'
                 OR EXISTS (SELECT 1 FROM todos t WHERE t.meeting_id = m.id AND t.is_deleted = 0 AND t.title LIKE ?1 ESCAPE '\\')
                 OR EXISTS (SELECT 1 FROM meeting_segments s
                            WHERE s.meeting_id = m.id AND COALESCE(s.edited_text, s.text) LIKE ?1 ESCAPE '\\'))
                """)
            params.append(Self.likePattern(search))
        }
        if let before {
            // Keyset paging on (created_at, id): stable while meetings are added or deleted.
            conditions.append("(m.created_at < ?\(params.count + 1) OR (m.created_at = ?\(params.count + 1) AND m.id < ?\(params.count + 2)))")
            params += [before.createdAt, before.id]
        }
        let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        params.append(limit)
        return ((try? db.query("""
            SELECT \(Self.meetingColumns) FROM meetings m \(filter)
            ORDER BY m.created_at DESC, m.id DESC LIMIT ?\(params.count)
            """, params: params)) ?? []).map(Self.meeting)
    }

    /// Finished meetings with no title that may have something to name them by (speech or notes) and that the
    /// launch scan hasn't tried since they were last recorded, newest first.
    public func meetingsNeedingTitle(limit: Int = 10) -> [Meeting] {
        ((try? db.query("""
            SELECT \(Self.meetingColumns) FROM meetings m
            WHERE m.status = 'complete' AND \(Self.isBlank("m.title"))
              AND (m.title_attempt_seq IS NULL OR m.title_attempt_seq < m.latest_stop_seq)
              AND (NOT \(Self.isBlank("m.notes"))
                   OR EXISTS (SELECT 1 FROM meeting_segments s WHERE s.meeting_id = m.id AND s.latched = 0 AND s.words > 0))
            ORDER BY m.created_at DESC, m.id DESC LIMIT ?
            """, limit)) ?? []).map(Self.meeting)
    }

    /// The launch scan tried to name the meeting as it is now recorded (or found nothing to name it by): it
    /// is not tried again until it is recorded again (Resume).
    func markTitleAttempted(id: String) {
        _ = try? db.run("UPDATE meetings SET title_attempt_seq = latest_stop_seq WHERE id = ?", id)
    }

    /// The note already recorded for one occurrence of a calendar event.
    public func meeting(calendarEventID: String, occurrenceStart: Date) -> Meeting? {
        (try? db.query("""
            SELECT \(Self.meetingColumns) FROM meetings m WHERE m.calendar_event_id = ? AND ABS(m.calendar_occurrence_start - ?) < 1
            ORDER BY m.created_at DESC LIMIT 1
            """, calendarEventID, occurrenceStart))?.first.map(Self.meeting)
    }

    /// Meetings whose recording or transcription was interrupted (app quit or crash).
    public func unfinishedMeetings() -> [Meeting] {
        ((try? db.query("SELECT \(Self.meetingColumns) FROM meetings m WHERE m.status IN ('recording','processing')")) ?? [])
            .map(Self.meeting)
    }

    /// Deletes the meeting, its transcript, its Ask chats and its audio folder. Its to-dos are kept but archived,
    /// with the meeting's title and date for "From …". Observers of `meetingDeleted` hear about it.
    public func deleteMeeting(id: String) {
        guard let m = meeting(id: id) else { return }
        let now = Date()
        do {
            try db.transaction {
                try db.run("""
                    UPDATE todos SET archived_at = CASE WHEN is_archived = 1 THEN archived_at ELSE ? END, is_archived = 1,
                      meeting_title = ?, meeting_created_at = ?, modified_at = ? WHERE meeting_id = ?
                    """, now, m.title, m.createdAt, now, id)
                try db.run("DELETE FROM meeting_segments WHERE meeting_id = ?", id)
                try db.run("DELETE FROM meetings WHERE id = ?", id)
            }
        } catch {
            NSLog("Shout: could not delete meeting \(id): \(error.localizedDescription)")
            return
        }
        // Only once the rows are gone, so a failure never leaves a meeting without its audio.
        if let path = m.audioPath { try? FileManager.default.removeItem(atPath: path) }
        meetingsRevision += 1
        meetingDeleted.send(id)
    }

    nonisolated private static func meeting(_ r: SQLiteDB.Row) -> Meeting {
        func date(_ k: String) -> Date? { r[k]?.double.map { Date(timeIntervalSince1970: $0) } }
        let participants = r["participant_names"]?.string.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let summary = r["summary"]?.string
        let status = Meeting.SummaryStatus(rawValue: r["summary_status"]?.string ?? "") ?? (summary == nil ? .none : .ready)
        return Meeting(
            id: r["id"]?.string ?? "", title: r["title"]?.string ?? "",
            createdAt: date("created_at") ?? Date(), startedAt: date("started_at"), endedAt: date("ended_at"),
            recordedMs: Int(r["recorded_ms"]?.int ?? 0),
            status: Meeting.Status(rawValue: r["status"]?.string ?? "") ?? .complete,
            notes: r["notes"]?.string ?? "", summary: summary, summaryStatus: status,
            summaryOverview: r["summary_overview"]?.string, summaryStopSeq: r["summary_stop_seq"]?.int.map(Int.init),
            calendarEventID: r["calendar_event_id"]?.string, calendarOccurrenceStart: date("calendar_occurrence_start"),
            participants: participants, taskTotal: Int(r["task_total"]?.int ?? 0), taskDone: Int(r["task_done"]?.int ?? 0),
            summaryEdited: (r["summary_edited"]?.int ?? 0) != 0,
            latestStopSeq: Int(r["latest_stop_seq"]?.int ?? 0), processedStopSeq: Int(r["processed_stop_seq"]?.int ?? 0),
            audioPath: r["audio_path"]?.string, hasSystemAudio: (r["has_system_audio"]?.int ?? 0) != 0,
            sourceApp: r["source_app"]?.string, sourceBundleID: r["source_bundle_id"]?.string,
            wordCount: Int(r["word_count"]?.int ?? 0), error: r["error"]?.string,
            modifiedAt: date("modified_at") ?? Date())
    }

    // MARK: Generated titles

    /// Names a meeting that still has no title from its transcript and notes, independently of the summary
    /// (call it at every stop, whatever the meeting's length). Tries once, then again after each of
    /// `retryDelays` seconds, and gives up after `deadline` seconds, also in the middle of an attempt.
    /// Returns the title it wrote, if any.
    @discardableResult
    public func generateTitleIfBlank(meetingID id: String, userName: String?,
                                     generator: @escaping () async throws -> TextGenerator?,
                                     retryDelays: [TimeInterval] = [5, 20], deadline: TimeInterval = 240) async -> String? {
        if case .named(let title) = await titleIfBlank(meetingID: id, userName: userName, generator: generator,
                                                       retryDelays: retryDelays, deadline: deadline) { return title }
        return nil
    }

    /// What naming one meeting came to.
    enum TitleOutcome: Equatable {
        case named(String)
        /// Gone, unfinished, titled in the meantime, or nothing to name it by.
        case skipped
        /// No language model is chosen, or it couldn't be loaded.
        case noModel
        /// The model was asked but gave no usable title.
        case failed
        /// Out of time, or cancelled.
        case stopped
    }

    func titleIfBlank(meetingID id: String, userName: String?, generator: @escaping () async throws -> TextGenerator?,
                      retryDelays: [TimeInterval], deadline: TimeInterval) async -> TitleOutcome {
        enum Attempt { case noModel, title(String?) }
        struct ModelUnavailable: Error {}
        let start = Date()
        var outcome = TitleOutcome.failed
        for attempt in 0...retryDelays.count {
            if attempt > 0 {
                let wait = retryDelays[attempt - 1]
                guard Date().timeIntervalSince(start) + wait < deadline else { return outcome }
                do { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) } catch { return .stopped }
            }
            guard !Task.isCancelled else { return .stopped }
            guard let m = meeting(id: id), m.status == .complete,
                  m.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skipped }
            let input = MeetingSummaryInput(date: m.createdAt, participants: m.participants, userName: userName,
                                            notes: m.notes, segments: segments(meetingID: id))
            guard MeetingSummarizer.canTitle(input) else { return .skipped }
            do {
                // The deadline holds within an attempt too: one waiting for dictation to end or for a slow model
                // is cancelled rather than waited for.
                let result = try await Self.within(deadline - Date().timeIntervalSince(start)) { () async throws -> Attempt in
                    let g: TextGenerator?
                    do { g = try await generator() } catch is CancellationError { throw CancellationError() } catch { throw ModelUnavailable() }
                    guard let g else { return .noModel }
                    return .title(try await MeetingSummarizer.title(for: input, generator: g, contextTokens: g.contextTokens))
                }
                switch result {
                case nil: return .stopped
                case .noModel?: return .noModel
                case .title(let title?)?: return setTitleIfBlank(id: id, title: title) ? .named(title) : .skipped
                case .title(nil)?: outcome = .failed
                }
            } catch is CancellationError {
                return .stopped
            } catch is ModelUnavailable {
                outcome = .noModel
            } catch {
                outcome = .failed
            }
        }
        return outcome
    }

    /// Launch scan: names up to `limit` finished meetings that still have no title, newest first, within
    /// `budget` seconds (an attempt still running then is cancelled). Each meeting is tried once per recording:
    /// it is marked when named, when the model gave nothing usable, and when there is nothing to name it by
    /// (only "um"s, no notes; these don't count towards `limit`), so the scan reaches older meetings and later
    /// launches don't try the same ones again. Without a model it stops and marks nothing. Returns how many it named.
    @discardableResult
    public func generateMissingTitles(limit: Int = 10, budget: TimeInterval = 90, userName: String?,
                                      generator: @escaping () async throws -> TextGenerator?) async -> Int {
        let start = Date()
        var named = 0, attempts = 0, seen = Set<String>()
        while attempts < limit {
            let page = meetingsNeedingTitle(limit: limit).filter { seen.insert($0.id).inserted }
            guard !page.isEmpty else { break }
            for m in page where attempts < limit {
                let left = budget - Date().timeIntervalSince(start)
                guard left > 0, !Task.isCancelled else { return named }
                switch await titleIfBlank(meetingID: m.id, userName: userName, generator: generator, retryDelays: [],
                                          deadline: left) {
                case .named: named += 1; attempts += 1
                case .failed: attempts += 1
                case .skipped: break
                case .noModel, .stopped: return named // tried again at the next launch
                }
                markTitleAttempted(id: m.id)
            }
        }
        return named
    }

    /// `operation`'s result, or nil when it hasn't finished within `seconds`: it is then cancelled and not
    /// waited for (a model can take a while to notice). Cancelling the caller cancels it too.
    static func within<T>(_ seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T? {
        guard seconds > 0 else { return nil }
        let race = DeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T?, Error>) in
                race.start(c, seconds: seconds, operation)
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    // MARK: Transcript

    @discardableResult
    public func addSegment(_ s: MeetingSegment) -> MeetingSegment {
        var seg = s
        do {
            // The next number is read in the insert's transaction: a failed read stores nothing rather than a
            // line whose number collides with an earlier one (Discard deletes a resumed leg by number).
            try db.transaction {
                guard let next = try db.scalar("SELECT COALESCE(MAX(seq), 0) + 1 FROM meeting_segments WHERE meeting_id = ?",
                                               s.meetingID).int else { throw SQLiteDB.DBError(message: "no next seq") }
                seg.seq = Int(next)
                try db.run("""
                    INSERT INTO meeting_segments (id, meeting_id, seq, source, speaker, speaker_origin, start_ms, end_ms, text,
                      edited_text, words, latched, marker, epoch) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, seg.id, seg.meetingID, seg.seq, seg.source.rawValue, seg.speaker,
                    seg.speaker == nil ? nil : seg.speakerOrigin?.rawValue, seg.startMs, seg.endMs, seg.text, seg.editedText,
                    TextRules.wordCount(seg.displayText), seg.latched, seg.marker?.rawValue, seg.epoch)
            }
        } catch {
            NSLog("Shout: transcript line of meeting \(s.meetingID) not saved: \(error.localizedDescription)")
        }
        meetingsRevision += 1
        return seg
    }

    /// The transcript in timeline order.
    nonisolated public func segments(meetingID: String) -> [MeetingSegment] {
        ((try? db.query("SELECT * FROM meeting_segments WHERE meeting_id = ? ORDER BY start_ms, seq", meetingID)) ?? [])
            .map(Self.segment)
    }

    /// The lines that overlap `lo..<hi` ms, in timeline order.
    public func segments(meetingID: String, overlappingMs lo: Int, _ hi: Int) -> [MeetingSegment] {
        ((try? db.query("""
            SELECT * FROM meeting_segments WHERE meeting_id = ? AND end_ms > ? AND start_ms < ? ORDER BY start_ms, seq
            """, meetingID, lo, hi)) ?? []).map(Self.segment)
    }

    /// Whether any note exists, and whether any has a summary (the setup checklist's two note steps).
    public func meetingSetupProgress() -> (hasNote: Bool, hasSummary: Bool) {
        let note = (try? db.scalar("SELECT EXISTS(SELECT 1 FROM meetings)").int) ?? 0
        // Same rule as the row mapper: a summary saved without a status (`createMeeting`) counts as ready.
        let summary = (try? db.scalar("""
            SELECT EXISTS(SELECT 1 FROM meetings WHERE summary_status = 'ready'
                OR (summary IS NOT NULL AND (summary_status IS NULL
                    OR summary_status NOT IN ('none', 'generating', 'ready', 'tooShort', 'noSpeech', 'failed'))))
            """).int) ?? 0
        return (note != 0, summary != 0)
    }

    public func setSegmentLatched(ids: Set<String>, latched: Bool) {
        guard !ids.isEmpty else { return }
        try? db.transaction {
            for id in ids { try db.run("UPDATE meeting_segments SET latched = ? WHERE id = ?", latched, id) }
        }
        meetingsRevision += 1
    }

    /// Stores a correction; nil restores the original text.
    public func editSegment(id: String, text: String?) {
        let original = (try? db.scalar("SELECT text FROM meeting_segments WHERE id = ?", id).string) ?? ""
        _ = try? db.run("UPDATE meeting_segments SET edited_text = ?, words = ? WHERE id = ?",
                        text, TextRules.wordCount(text ?? original), id)
        meetingsRevision += 1
    }

    /// Applies echo removal to a microphone line: keeps the recognizer's original in `raw_text`, and
    /// hides the line when nothing of the user's own speech is left.
    public func applyEchoCleanup(id: String, text: String, startMs: Int) {
        if text.isEmpty {
            _ = try? db.run("UPDATE meeting_segments SET latched = 1 WHERE id = ?", id)
        } else {
            _ = try? db.run("""
                UPDATE meeting_segments SET raw_text = COALESCE(raw_text, text), text = ?, words = ?, start_ms = MIN(?, end_ms)
                WHERE id = ?
                """, text, TextRules.wordCount(text), startMs, id)
        }
        meetingsRevision += 1
    }

    public func deleteSegment(id: String) {
        _ = try? db.run("DELETE FROM meeting_segments WHERE id = ?", id)
        meetingsRevision += 1
    }

    /// End of the last transcribed utterance from a source (where crash recovery resumes).
    public func lastSegmentEndMs(meetingID: String, source: MeetingSource) -> Int {
        Int((try? db.scalar("SELECT COALESCE(MAX(end_ms), 0) FROM meeting_segments WHERE meeting_id = ? AND source = ?",
                            meetingID, source.rawValue).int) ?? 0)
    }

    nonisolated private static func segment(_ r: SQLiteDB.Row) -> MeetingSegment {
        MeetingSegment(
            id: r["id"]?.string ?? "", meetingID: r["meeting_id"]?.string ?? "", seq: Int(r["seq"]?.int ?? 0),
            source: MeetingSource(rawValue: r["source"]?.string ?? "") ?? .system, speaker: r["speaker"]?.string,
            startMs: Int(r["start_ms"]?.int ?? 0), endMs: Int(r["end_ms"]?.int ?? 0), text: r["text"]?.string ?? "",
            editedText: r["edited_text"]?.string, latched: (r["latched"]?.int ?? 0) != 0,
            marker: r["marker"]?.string.flatMap(MeetingMarker.init(rawValue:)),
            epoch: r["epoch"]?.double.map { Date(timeIntervalSince1970: $0) },
            speakerOrigin: r["speaker_origin"]?.string.flatMap(SpeakerOrigin.init(rawValue:)))
    }

    // MARK: Folders

    public func folders() -> [MeetingFolder] {
        ((try? db.query("""
            SELECT f.*, (SELECT COUNT(*) FROM meeting_folders mf WHERE mf.folder_id = f.id) AS meeting_count
            FROM folders f ORDER BY f.sort_order, lower(f.name)
            """)) ?? []).map { r in
            MeetingFolder(id: r["id"]?.string ?? "", name: r["name"]?.string ?? "",
                          createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
                          meetingCount: Int(r["meeting_count"]?.int ?? 0))
        }
    }

    @discardableResult
    public func createFolder(name: String) -> MeetingFolder {
        let f = MeetingFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try? db.run("INSERT INTO folders (id, name, created_at) VALUES (?,?,?)", f.id, f.name, f.createdAt)
        meetingsRevision += 1
        return f
    }

    public func renameFolder(id: String, name: String) {
        _ = try? db.run("UPDATE folders SET name = ? WHERE id = ?", name.trimmingCharacters(in: .whitespacesAndNewlines), id)
        meetingsRevision += 1
    }

    /// Deletes the folder only; its meetings stay.
    public func deleteFolder(id: String) {
        _ = try? db.run("DELETE FROM folders WHERE id = ?", id)
        meetingsRevision += 1
    }

    public func setMeeting(_ meetingID: String, inFolder folderID: String, _ included: Bool) {
        if included {
            _ = try? db.run("INSERT OR IGNORE INTO meeting_folders (meeting_id, folder_id) VALUES (?,?)", meetingID, folderID)
        } else {
            _ = try? db.run("DELETE FROM meeting_folders WHERE meeting_id = ? AND folder_id = ?", meetingID, folderID)
        }
        meetingsRevision += 1
    }

    /// Folder ids for every meeting that is in at least one folder.
    public func meetingFolderIDs() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for r in (try? db.query("SELECT meeting_id, folder_id FROM meeting_folders")) ?? [] {
            if let m = r["meeting_id"]?.string, let f = r["folder_id"]?.string { out[m, default: []].append(f) }
        }
        return out
    }

    public func meetings(inFolder folderID: String) -> [Meeting] {
        ((try? db.query("""
            SELECT \(Self.meetingColumns) FROM meetings m JOIN meeting_folders mf ON mf.meeting_id = m.id
            WHERE mf.folder_id = ? ORDER BY m.created_at DESC
            """, folderID)) ?? []).map(Self.meeting)
    }

    // MARK: Demo data

    func seedDemoMeetings() {
        let cal = Calendar.current
        func at(_ daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date()))!
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let sync = Meeting(id: "demo-sync", title: "Weekly product sync", createdAt: at(0, 9, 30), startedAt: at(0, 9, 30),
                           endedAt: at(0, 10, 2), recordedMs: 31 * 60_000 + 12_000, status: .complete,
                           notes: "Launch date?\nPricing owner: Priya\nAsk Joaquin about the load tests",
                           latestStopSeq: 2, hasSystemAudio: true, sourceApp: "Zoom", sourceBundleID: "us.zoom.xos")
        createMeeting(sync)
        let lines: [(MeetingSource, Int, String)] = [
            (.system, 4, "Morning everyone. Let's start with the launch timeline, then pricing."),
            (.mic, 11, "Sounds good. Quick update from my side: the onboarding flow is done and in review."),
            (.system, 19, "Nice. Are we still on track for the fourteenth?"),
            (.mic, 24, "I think we should move the launch by one week. The load tests on the new cluster aren't finished."),
            (.mic, 31, "Joaquin is running them today, and I'd rather not ship without the numbers."),
            (.system, 39, "That's fair. A week is fine on our side if pricing can follow later."),
            (.system, 46, "Priya, can you own the pricing proposal?"),
            (.system, 52, "Yes. I can have a draft by Friday."),
            (.mic, 58, "Great. I'll update the release notes and send the new date to the team this afternoon."),
        ]
        for (i, l) in lines.enumerated() {
            let start = l.1 * 1000 + i * 1300
            addSegment(MeetingSegment(meetingID: sync.id, source: l.0, startMs: start, endMs: start + 5200, text: l.2))
        }
        addSegment(MeetingSegment(meetingID: sync.id, source: .marker, startMs: 64_000, endMs: 64_000, marker: .stopped,
                                  epoch: at(0, 9, 31)))
        addSegment(MeetingSegment(meetingID: sync.id, source: .marker, startMs: 64_000, endMs: 64_000, marker: .resumed,
                                  epoch: at(0, 9, 34)))
        addSegment(MeetingSegment(meetingID: sync.id, source: .system, startMs: 66_000, endMs: 71_000,
                                  text: "Okay, we're back. Last item: who's presenting the demo on Thursday?"))
        addSegment(MeetingSegment(meetingID: sync.id, source: .mic, startMs: 72_500, endMs: 76_000,
                                  text: "I can do it. I'll keep it to ten minutes."))
        // What Zoom showed during the first leg; the resumed leg has no readings, so its line stays "Others".
        func quiet(_ start: Int, _ end: Int) -> SpeakerSpan {
            SpeakerSpan(startMs: start, endMs: end, platform: .zoom, state: .unknown, speakingNames: [], source: .zoomMain)
        }
        appendSpeakerSpans(meetingID: sync.id, [
            .matched("Mei Chen", 3_800, 9_400), quiet(9_400, 21_400), .matched("Mei Chen", 21_400, 27_000), quiet(27_000, 45_300),
            .matched("Joaquin Ortiz", 45_300, 50_900), quiet(50_900, 53_600), .matched("Mei Chen", 53_600, 59_200),
            quiet(59_200, 60_900), .matched("Priya Raman", 60_900, 64_000),
        ])
        applySpeakerNames(meetingID: sync.id, SpeakerAttribution.attribute(segments: segments(meetingID: sync.id),
                                                                           spans: speakerSpans(meetingID: sync.id)))
        let overview = "The team agreed to move the launch by one week so the load tests on the new cluster can finish. Pricing will follow separately, with Priya drafting a proposal by Friday."
        setSummary(id: sync.id, markdown: """
            \(overview)

            ## Decisions
            - Launch moves one week later; the onboarding flow is done and in review.
            - Pricing ships separately from the launch.

            ## Open questions
            - Load-test results from the new cluster are still pending.

            ## Next steps
            - **Priya** — Draft the pricing proposal by Friday.
            - **You** — Update the release notes and send the new date to the team this afternoon.
            - **You** — Present the demo on Thursday (about ten minutes).
            """, overview: overview, status: .ready, stopSeq: 2)
        let t1 = addTask(meetingID: sync.id, title: "Draft the pricing proposal by Friday", owner: "Priya")
        addTask(meetingID: sync.id, title: "Update the release notes and send the new date to the team", owner: "You")
        var done = t1; done.status = .done; updateTask(done)
        addTask(meetingID: sync.id, title: "Present the demo on Thursday", owner: "You")
        let product = createFolder(name: "Product")
        setMeeting(sync.id, inFolder: product.id, true)

        let oneOnOne = Meeting(id: "demo-1on1", title: "1:1 with Priya", createdAt: at(1, 14, 0), startedAt: at(1, 14, 0),
                               endedAt: at(1, 14, 28), recordedMs: 27 * 60_000 + 40_000, status: .complete,
                               latestStopSeq: 1, hasSystemAudio: true, sourceApp: "Google Meet")
        createMeeting(oneOnOne)
        addSegment(MeetingSegment(meetingID: oneOnOne.id, source: .system, startMs: 2_000, endMs: 6_000,
                                  text: "How did the planning session go?"))
        addSegment(MeetingSegment(meetingID: oneOnOne.id, source: .mic, startMs: 6_500, endMs: 12_000,
                                  text: "Really well. We agreed on three priorities for the quarter."))
        appendSpeakerSpans(meetingID: oneOnOne.id, [.matched("Priya Raman", 1_800, 6_300, platform: .meet)])
        applySpeakerNames(meetingID: oneOnOne.id, SpeakerAttribution.attribute(segments: segments(meetingID: oneOnOne.id),
                                                                               spans: speakerSpans(meetingID: oneOnOne.id)))
        let oneOverview = "Quarter planning went well: three priorities are agreed, and the team wants clearer ownership for the API migration."
        setSummary(id: oneOnOne.id, markdown: oneOverview + "\n\n## Updates\n- Three priorities agreed for the quarter.\n\n## Next steps\n- **You** — Share the priorities doc with the team.",
                   overview: oneOverview, status: .ready, stopSeq: 1)
        addTask(meetingID: oneOnOne.id, title: "Share the priorities doc with the team", owner: "You")
        let ones = createFolder(name: "1:1s")
        setMeeting(oneOnOne.id, inFolder: ones.id, true)

        let standup = Meeting(id: "demo-standup", title: "", createdAt: at(1, 9, 15), startedAt: at(1, 9, 15),
                              endedAt: at(1, 9, 24), recordedMs: 9 * 60_000 + 5_000, status: .complete,
                              latestStopSeq: 1, hasSystemAudio: true)
        createMeeting(standup)
        addSegment(MeetingSegment(meetingID: standup.id, source: .mic, startMs: 1_000, endMs: 4_000,
                                  text: "Yesterday I fixed the login bug."))
    }
}

/// `Store.within`: whichever comes first, the operation's result or the deadline, resumes the caller once.
@MainActor
private final class DeadlineRace<T> {
    private var continuation: CheckedContinuation<T?, Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func start(_ c: CheckedContinuation<T?, Error>, seconds: TimeInterval, _ operation: @escaping () async throws -> T) {
        continuation = c
        work = Task { @MainActor in
            do { self.finish(.success(try await operation())) } catch { self.finish(.failure(error)) }
        }
        timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            self.finish(.success(nil))
        }
    }

    func finish(_ result: Result<T?, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        work?.cancel(); timer?.cancel()
        c.resume(with: result)
    }
}
