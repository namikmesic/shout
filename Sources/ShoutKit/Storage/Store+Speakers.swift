import Foundation

/// Speaker names read from the meeting app's window: what it showed over time (spans, per recording leg) and
/// the names on the transcript's "Others" lines.
extension Store {
    /// The speaker spans of each meeting leg (`meeting_segments.speaker_origin` says who named each line), and the
    /// user's speaker renames per meeting, so they also apply to what is read in later legs.
    static let speakersSchema = """
    CREATE TABLE meeting_speaker_spans (
        id INTEGER PRIMARY KEY,
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        leg INTEGER NOT NULL DEFAULT 0,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        platform TEXT NOT NULL,
        state TEXT NOT NULL,
        speaker_name TEXT,
        speaking TEXT,
        muted TEXT,
        self_name TEXT,
        source TEXT,
        reason TEXT
    );
    CREATE INDEX meeting_speaker_spans_meeting ON meeting_speaker_spans(meeting_id, start_ms);
    CREATE TABLE meeting_speaker_aliases (
        meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
        from_key TEXT NOT NULL,
        to_name TEXT NOT NULL,
        PRIMARY KEY (meeting_id, from_key)
    );

    """

    /// The meeting's renames: name key (as the meeting app shows it) → the user's name.
    public func speakerAliases(meetingID: String) -> [String: String] {
        var out: [String: String] = [:]
        for r in (try? db.query("SELECT from_key, to_name FROM meeting_speaker_aliases WHERE meeting_id = ?", meetingID)) ?? [] {
            if let k = r["from_key"]?.string, let n = r["to_name"]?.string { out[k] = n }
        }
        return out
    }

    // MARK: Spans

    /// Stores spans of a leg (batched; the poller's ticks never write).
    public func appendSpeakerSpans(meetingID: String, _ spans: [SpeakerSpan]) {
        guard !spans.isEmpty else { return }
        try? db.transaction {
            for s in spans {
                try db.run("""
                    INSERT INTO meeting_speaker_spans (meeting_id, leg, start_ms, end_ms, platform, state, speaker_name,
                      speaking, muted, self_name, source, reason) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                    """, meetingID, s.leg, s.startMs, s.endMs, s.platform.rawValue, s.state.rawValue, s.speakerName,
                    Self.json(s.speakingNames), Self.json(s.mutedNames), s.selfName, s.source?.rawValue, s.reason?.rawValue)
            }
        }
    }

    /// The meeting's spans in timeline order.
    public func speakerSpans(meetingID: String) -> [SpeakerSpan] {
        ((try? db.query("SELECT * FROM meeting_speaker_spans WHERE meeting_id = ? ORDER BY start_ms, id", meetingID)) ?? [])
            .compactMap(Self.speakerSpan)
    }

    /// Removes the spans of a discarded leg.
    public func deleteSpeakerSpans(meetingID: String, leg: Int) {
        _ = try? db.run("DELETE FROM meeting_speaker_spans WHERE meeting_id = ? AND leg = ?", meetingID, leg)
    }

    /// Time each person was shown speaking alone (matched spans), by display name after the meeting's renames.
    public func speakerTalkTime(meetingID: String) -> [String: Int] {
        let aliases = speakerAliases(meetingID: meetingID)
        var out: [String: Int] = [:]
        for r in (try? db.query("""
            SELECT speaker_name, SUM(end_ms - start_ms) AS ms FROM meeting_speaker_spans
            WHERE meeting_id = ? AND state = 'matched' AND speaker_name IS NOT NULL GROUP BY speaker_name
            """, meetingID)) ?? [] {
            guard let raw = r["speaker_name"]?.string else { continue }
            out[aliases[SpeakerNames.key(raw)] ?? raw, default: 0] += Int(r["ms"]?.int ?? 0)
        }
        return out
    }

    // MARK: Names on lines

    /// Writes `SpeakerAttribution.attribute`'s names (nil: back to "Others"). Only system lines whose speaker came
    /// from the meeting app, or that have none, change; the user's labels stay. Returns how many lines changed.
    @discardableResult
    public func applySpeakerNames(meetingID: String, _ names: [String: String?]) -> Int {
        var changed = 0
        do {
            try db.transaction {
                for (id, name) in names {
                    changed += try db.update("""
                        UPDATE meeting_segments SET speaker = ?1, speaker_origin = CASE WHEN ?1 IS NULL THEN NULL ELSE 'ax' END
                        WHERE id = ?2 AND meeting_id = ?3 AND source = 'system'
                          AND (speaker_origin = 'ax' OR (speaker_origin IS NULL AND speaker IS NULL)) AND speaker IS NOT ?1
                        """, name, id, meetingID)
                }
            }
        } catch { return 0 }  // rolled back: no line changed
        if changed > 0 { meetingsRevision += 1 }
        return changed
    }

    /// Renames a speaker throughout the meeting: every system line with that name (by key) becomes the user's
    /// label, the stored readings use the new name, and the rename is kept (`speakerAliases`), so whatever the
    /// meeting app shows under the old name later (a resumed leg, a recording still going) gets the new one too.
    public func renameSpeaker(meetingID: String, from old: String, to new: String) {
        guard let name = SpeakerNames.clean(new) else { return }
        let oldKey = SpeakerNames.key(old)
        let ids = segments(meetingID: meetingID)
            .filter { $0.source == .system && $0.speaker.map(SpeakerNames.key) == oldKey }.map(\.id)
        let spans = ((try? db.query("SELECT * FROM meeting_speaker_spans WHERE meeting_id = ?", meetingID)) ?? [])
            .compactMap { r in r["id"]?.int.flatMap { id in Self.speakerSpan(r).map { (id, $0) } } }
            .filter { $0.1.mentions(key: oldKey) }
        try? db.transaction {
            for id in ids { try db.run("UPDATE meeting_segments SET speaker = ?, speaker_origin = 'user' WHERE id = ?", name, id) }
            for (rowID, span) in spans {
                let s = span.renaming(key: oldKey, to: name)
                try db.run("""
                    UPDATE meeting_speaker_spans SET state = ?, speaker_name = ?, speaking = ?, muted = ?, self_name = ? WHERE id = ?
                    """, s.state.rawValue, s.speakerName, Self.json(s.speakingNames), Self.json(s.mutedNames), s.selfName, rowID)
            }
            // Earlier renames to the old name follow it ("Bob" → "Robert", then "Robert" → "Rob").
            for (from, to) in speakerAliases(meetingID: meetingID) where SpeakerNames.key(to) == oldKey {
                try db.run("UPDATE meeting_speaker_aliases SET to_name = ? WHERE meeting_id = ? AND from_key = ?", name, meetingID, from)
            }
            try db.run("INSERT OR REPLACE INTO meeting_speaker_aliases (meeting_id, from_key, to_name) VALUES (?,?,?)",
                       meetingID, oldKey, name)
        }
        meetingsRevision += 1
    }

    /// The user names the speaker of these lines (nil: "Others"); never replaced automatically afterwards.
    public func setSpeaker(segmentIDs: [String], name: String?) {
        let cleaned = name.flatMap(SpeakerNames.clean)
        try? db.transaction {
            for id in segmentIDs {
                try db.run("UPDATE meeting_segments SET speaker = ?, speaker_origin = 'user' WHERE id = ? AND source = 'system'",
                           cleaned, id)
            }
        }
        meetingsRevision += 1
    }

    // MARK: Rows

    private static func json(_ names: [String]?) -> String? {
        names.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func names(_ value: SQLiteDB.Value?) -> [String]? {
        value?.string.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) }
    }

    private static func speakerSpan(_ r: SQLiteDB.Row) -> SpeakerSpan? {
        guard let platform = r["platform"]?.string.flatMap(SpeakerPlatform.init(rawValue:)),
              let state = r["state"]?.string.flatMap(SpeakerAttributionState.init(rawValue:)) else { return nil }
        return SpeakerSpan(leg: Int(r["leg"]?.int ?? 0), startMs: Int(r["start_ms"]?.int ?? 0), endMs: Int(r["end_ms"]?.int ?? 0),
                           platform: platform, state: state, speakerName: r["speaker_name"]?.string,
                           speakingNames: names(r["speaking"]), mutedNames: names(r["muted"]), selfName: r["self_name"]?.string,
                           source: r["source"]?.string.flatMap(SpeakerSource.init(rawValue:)),
                           reason: r["reason"]?.string.flatMap(SpeakerReadReason.init(rawValue:)))
    }
}
