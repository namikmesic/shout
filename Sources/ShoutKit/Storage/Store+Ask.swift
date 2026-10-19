import Foundation

/// A saved Ask conversation, about one meeting or about all meetings (`meetingID` nil).
public struct AskChat: Identifiable, Hashable, Sendable {
    public var id: String
    public var meetingID: String?
    /// The first question.
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastAccessedAt: Date
}

/// One message of a saved Ask chat. A question and its answer share `turnID`.
public struct AskMessage: Identifiable, Hashable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public enum Status: String, Sendable {
        case pending, succeeded, failed
        /// The sheet closed or the app quit before the answer came.
        case interrupted
    }
    /// A meeting the answer drew on.
    public struct Source: Hashable, Sendable, Codable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public var id: String
    public var chatID: String
    public var turnID: String
    public var order: Int
    public var role: Role
    public var status: Status
    /// The question, the answer (Markdown), or the error shown for a failed answer.
    public var content: String
    public var sources: [Source]
    public var model: String?
    public var latencyMs: Int?
    public var createdAt: Date
}

/// Ask: the material for a question, and saved chats.
extension Store {
    /// Saved chats beyond these are dropped, least recently opened first.
    static let maxAskChats = 130
    static let maxAskMessages = 5000

    /// Material for answering a question: one meeting in full, or the meetings that best match it. Safe to call
    /// off the main thread.
    nonisolated public func askSources(question: String, meetingID: String?) -> [AskSource] {
        if let id = meetingID, let m = meeting(id: id) {
            let lines = MeetingAsk.transcriptLines(segments(meetingID: id))
            return [AskSource(id: m.id, title: m.displayTitle, date: m.createdAt, summary: m.summary, notes: m.notes,
                              transcript: lines.joined(separator: "\n"))]
        }
        let keywords = MeetingAsk.keywords(question)
        let candidates = meetings(limit: 80)
        var scored: [(meeting: Meeting, lines: [String], hits: Int)] = []
        for m in candidates {
            let lines = MeetingAsk.transcriptLines(segments(meetingID: m.id))
            let haystack = ([m.title, m.summary ?? "", m.notes] + lines).joined(separator: "\n").lowercased()
            let hits = keywords.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
            scored.append((m, lines, hits))
        }
        let matched = scored.filter { $0.hits > 0 }.sorted { ($0.hits, $0.meeting.createdAt) > ($1.hits, $1.meeting.createdAt) }
        let picked = matched.isEmpty ? Array(scored.prefix(5)) : Array(matched.prefix(6))
        return picked.map { p in
            let excerpt = matched.isEmpty || p.meeting.summary == nil
                ? p.lines.prefix(30).joined(separator: "\n")
                : MeetingAsk.excerpts(p.lines, keywords: keywords)
            return AskSource(id: p.meeting.id, title: p.meeting.displayTitle, date: p.meeting.createdAt,
                             summary: p.meeting.summary, notes: p.meeting.notes, transcript: excerpt)
        }
    }

    // MARK: Saved chats

    /// Saved chats, most recently active first: about one meeting, or about all meetings when `meetingID` is nil.
    /// A meeting's chats are deleted with it.
    public func askChats(meetingID: String?) -> [AskChat] {
        let rows = meetingID.map { (try? db.query("SELECT * FROM ask_chats WHERE meeting_id = ? ORDER BY modified_at DESC", $0)) ?? [] }
            ?? (try? db.query("SELECT * FROM ask_chats WHERE meeting_id IS NULL ORDER BY modified_at DESC")) ?? []
        return rows.map(Self.askChat)
    }

    /// Starts a chat named after its first question.
    @discardableResult
    public func createAskChat(meetingID: String?, title: String) -> AskChat {
        let now = Date()
        let chat = AskChat(id: UUID().uuidString, meetingID: meetingID,
                           title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)),
                           createdAt: now, modifiedAt: now, lastAccessedAt: now)
        _ = try? db.run("INSERT INTO ask_chats (id, meeting_id, title, created_at, modified_at, last_accessed_at) VALUES (?,?,?,?,?,?)",
                        chat.id, chat.meetingID, chat.title, now, now, now)
        pruneAskChats()
        return chat
    }

    /// Whether a chat is still saved: Ask can be open for one meeting in the main window and the Notepad, and
    /// either may delete it (or pruning may drop it). A failed read counts as saved, so the chat isn't split.
    public func askChatExists(id: String) -> Bool {
        ((try? db.scalar("SELECT EXISTS(SELECT 1 FROM ask_chats WHERE id = ?)", id).int) ?? 1) != 0
    }

    /// The chat's messages in order. Opening a chat keeps it from being dropped early.
    public func askMessages(chatID: String) -> [AskMessage] {
        _ = try? db.run("UPDATE ask_chats SET last_accessed_at = ? WHERE id = ?", Date(), chatID)
        return ((try? db.query("SELECT * FROM ask_messages WHERE chat_id = ? ORDER BY local_order", chatID)) ?? []).map(Self.askMessage)
    }

    /// Records a question and its answer as pending, with the meetings it is answered from. Complete the
    /// returned answer with `finishAskAnswer`.
    @discardableResult
    public func addAskQuestion(chatID: String, question: String, sources: [AskSource]) -> AskMessage {
        let now = Date(), turn = UUID().uuidString
        let refs = sources.map { AskMessage.Source(id: $0.id, title: $0.title) }
        var answer = AskMessage(id: UUID().uuidString, chatID: chatID, turnID: turn, order: 0, role: .assistant,
                                status: .pending, content: "", sources: refs, createdAt: now)
        do {
            try db.transaction {
                // Read in the transaction: a failed read writes nothing rather than an order that collides.
                guard let n = try db.scalar("SELECT COALESCE(MAX(local_order), 0) + 1 FROM ask_messages WHERE chat_id = ?",
                                            chatID).int else { throw SQLiteDB.DBError(message: "no next order") }
                let next = Int(n)
                answer.order = next + 1
                try db.run("""
                    INSERT INTO ask_messages (id, chat_id, turn_id, local_order, role, status, content, created_at)
                    VALUES (?,?,?,?,?,?,?,?)
                    """, UUID().uuidString, chatID, turn, next, AskMessage.Role.user.rawValue, AskMessage.Status.succeeded.rawValue,
                    question, now)
                try db.run("""
                    INSERT INTO ask_messages (id, chat_id, turn_id, local_order, role, status, content, metadata, created_at)
                    VALUES (?,?,?,?,?,?,?,?,?)
                    """, answer.id, chatID, turn, answer.order, answer.role.rawValue, answer.status.rawValue, "",
                    Self.encodeAskMetadata(AskMetadata(sources: refs)), now)
                try db.run("UPDATE ask_chats SET modified_at = ?, last_accessed_at = ? WHERE id = ?", now, now, chatID)
            }
        } catch {
            NSLog("Shout: Ask question not saved: \(error.localizedDescription)")
        }
        return answer
    }

    /// Stores the answer (or, for `.failed`, the error message) of a pending turn.
    public func finishAskAnswer(id: String, content: String, status: AskMessage.Status, model: String? = nil,
                                latencyMs: Int? = nil) {
        do {
            // One transaction: a failed read of the stored metadata writes nothing rather than dropping its sources.
            try db.transaction {
                let old = try db.scalar("SELECT metadata FROM ask_messages WHERE id = ?", id).string.flatMap(Self.decodeAskMetadata)
                let meta = AskMetadata(sources: old?.sources, model: model ?? old?.model, latencyMs: latencyMs ?? old?.latencyMs)
                try db.run("UPDATE ask_messages SET content = ?, status = ?, metadata = ? WHERE id = ?",
                           content, status.rawValue, Self.encodeAskMetadata(meta), id)
                try db.run("UPDATE ask_chats SET modified_at = ? WHERE id = (SELECT chat_id FROM ask_messages WHERE id = ?)", Date(), id)
            }
        } catch {
            NSLog("Shout: Ask answer not saved: \(error.localizedDescription)")
        }
    }

    /// Answers still pending become interrupted: call it when the Ask sheet closes mid-answer. (At launch it
    /// runs for every chat, since no answer can still be coming.)
    public func interruptPendingAskAnswers(chatID: String? = nil) {
        if let chatID {
            _ = try? db.run("UPDATE ask_messages SET status = 'interrupted' WHERE status = 'pending' AND chat_id = ?", chatID)
        } else {
            _ = try? db.run("UPDATE ask_messages SET status = 'interrupted' WHERE status = 'pending'")
        }
    }

    public func deleteAskChat(id: String) {
        _ = try? db.run("DELETE FROM ask_chats WHERE id = ?", id)
    }

    /// Keeps at most `maxAskChats` chats and about `maxAskMessages` messages, dropping the least recently opened
    /// chats (never the most recent one).
    func pruneAskChats() {
        let rows = (try? db.query("""
            SELECT c.id, (SELECT COUNT(*) FROM ask_messages m WHERE m.chat_id = c.id) AS n
            FROM ask_chats c ORDER BY c.last_accessed_at DESC, c.created_at DESC
            """)) ?? []
        var kept = 0, messages = 0
        var drop: [String] = []
        for r in rows {
            let n = Int(r["n"]?.int ?? 0)
            if kept > 0 && (kept >= Self.maxAskChats || messages + n > Self.maxAskMessages) {
                if let id = r["id"]?.string { drop.append(id) }
            } else {
                kept += 1; messages += n
            }
        }
        guard !drop.isEmpty else { return }
        try? db.transaction {
            for id in drop { try db.run("DELETE FROM ask_chats WHERE id = ?", id) }
        }
    }

    struct AskMetadata: Codable {
        var sources: [AskMessage.Source]?
        var model: String?
        var latencyMs: Int?
        enum CodingKeys: String, CodingKey { case sources, model, latencyMs = "latency_ms" }
    }

    static func encodeAskMetadata(_ m: AskMetadata) -> String? {
        (try? JSONEncoder().encode(m)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decodeAskMetadata(_ json: String) -> AskMetadata? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(AskMetadata.self, from: $0) }
    }

    private static func askChat(_ r: SQLiteDB.Row) -> AskChat {
        func date(_ k: String) -> Date { Date(timeIntervalSince1970: r[k]?.double ?? 0) }
        return AskChat(id: r["id"]?.string ?? "", meetingID: r["meeting_id"]?.string, title: r["title"]?.string ?? "",
                       createdAt: date("created_at"), modifiedAt: date("modified_at"), lastAccessedAt: date("last_accessed_at"))
    }

    private static func askMessage(_ r: SQLiteDB.Row) -> AskMessage {
        let meta = r["metadata"]?.string.flatMap(decodeAskMetadata)
        return AskMessage(id: r["id"]?.string ?? "", chatID: r["chat_id"]?.string ?? "", turnID: r["turn_id"]?.string ?? "",
                          order: Int(r["local_order"]?.int ?? 0),
                          role: AskMessage.Role(rawValue: r["role"]?.string ?? "") ?? .user,
                          status: AskMessage.Status(rawValue: r["status"]?.string ?? "") ?? .succeeded,
                          content: r["content"]?.string ?? "", sources: meta?.sources ?? [], model: meta?.model,
                          latencyMs: meta?.latencyMs, createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0))
    }
}
