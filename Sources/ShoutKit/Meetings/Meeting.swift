import Foundation

/// Where a transcript line came from. The microphone is "You"; system audio is everyone else on the call.
public enum MeetingSource: String, Sendable, CaseIterable {
    case mic, system, marker

    public var speakerLabel: String {
        switch self {
        case .mic: "You"
        case .system: "Others"
        case .marker: ""
        }
    }
}

/// Timeline events that are not speech.
public enum MeetingMarker: String, Sendable {
    /// Recording stopped (a later `resumed` marker at the same position continues the same note).
    case stopped
    case resumed
    /// The meeting microphone was paused while the user dictated into another app.
    case dictated
}

public struct Meeting: Identifiable, Hashable, Sendable {
    /// Where the generated summary stands.
    public enum SummaryStatus: String, Sendable {
        case none, generating, ready, tooShort, noSpeech, failed
    }

    public enum Status: String, Sendable {
        /// A leg is being captured right now.
        case recording
        /// Stopped; queued audio is still being transcribed.
        case processing
        case complete
        case failed
    }

    public var id: String
    public var title: String
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    /// Length of the recorded timeline (both tracks), excluding time between Stop and Resume.
    public var recordedMs: Int
    public var status: Status
    public var notes: String
    /// Generated (and user-editable) Markdown summary.
    public var summary: String?
    public var summaryStatus: SummaryStatus
    /// First paragraph of the summary, for previews.
    public var summaryOverview: String?
    /// `latestStopSeq` when the summary was made; "Update summary" is offered when newer audio exists.
    public var summaryStopSeq: Int?
    public var calendarEventID: String?
    public var calendarOccurrenceStart: Date?
    /// Attendee names (calendar), used for summaries and speaker suggestions.
    public var participants: [String]
    /// Action items of this meeting that are not archived.
    public var taskTotal: Int
    public var taskDone: Int
    /// The user edited the summary.
    public var summaryEdited: Bool
    /// Incremented on every Stop; later phases compare it with `processedStopSeq` to offer "Update summary".
    public var latestStopSeq: Int
    public var processedStopSeq: Int
    public var audioPath: String?
    public var hasSystemAudio: Bool
    public var sourceApp: String?
    public var sourceBundleID: String?
    public var wordCount: Int
    public var error: String?
    public var modifiedAt: Date

    public init(id: String = UUID().uuidString, title: String = "", createdAt: Date = Date(), startedAt: Date? = nil,
                endedAt: Date? = nil, recordedMs: Int = 0, status: Status = .recording, notes: String = "",
                summary: String? = nil, summaryStatus: SummaryStatus = .none, summaryOverview: String? = nil,
                summaryStopSeq: Int? = nil, calendarEventID: String? = nil, calendarOccurrenceStart: Date? = nil,
                participants: [String] = [], taskTotal: Int = 0, taskDone: Int = 0, summaryEdited: Bool = false,
                latestStopSeq: Int = 0, processedStopSeq: Int = 0, audioPath: String? = nil,
                hasSystemAudio: Bool = false, sourceApp: String? = nil, sourceBundleID: String? = nil, wordCount: Int = 0,
                error: String? = nil, modifiedAt: Date = Date()) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.startedAt = startedAt; self.endedAt = endedAt
        self.recordedMs = recordedMs; self.status = status; self.notes = notes; self.summary = summary
        self.summaryStatus = summaryStatus; self.summaryOverview = summaryOverview; self.summaryStopSeq = summaryStopSeq
        self.calendarEventID = calendarEventID; self.calendarOccurrenceStart = calendarOccurrenceStart
        self.participants = participants; self.taskTotal = taskTotal; self.taskDone = taskDone
        self.summaryEdited = summaryEdited
        self.latestStopSeq = latestStopSeq; self.processedStopSeq = processedStopSeq; self.audioPath = audioPath
        self.hasSystemAudio = hasSystemAudio; self.sourceApp = sourceApp; self.sourceBundleID = sourceBundleID
        self.wordCount = wordCount; self.error = error; self.modifiedAt = modifiedAt
    }

    /// The title shown in lists: the user's (or generated) title, else a neutral fallback.
    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled meeting" : t
    }

    public var duration: TimeInterval { Double(recordedMs) / 1000 }

    /// Audio was recorded after the current summary (or the attempt that found too little to summarize).
    public var summaryIsStale: Bool {
        summaryStatus != .none && summaryStatus != .generating && (summaryStopSeq ?? 0) < latestStopSeq
    }
}

/// An action item, usually extracted from a meeting's summary.
public struct MeetingTask: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable, CaseIterable {
        case open, inProgress = "in_progress", done
        /// Open → in progress → done → open.
        public var next: Status { self == .open ? .inProgress : (self == .inProgress ? .done : .open) }
    }
    public var id: String
    public var meetingID: String?
    public var title: String
    public var owner: String?
    public var status: Status
    public var isArchived: Bool
    public var sortOrder: Double
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: String = UUID().uuidString, meetingID: String?, title: String, owner: String? = nil, status: Status = .open,
                isArchived: Bool = false, sortOrder: Double = 0, createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id; self.meetingID = meetingID; self.title = title; self.owner = owner; self.status = status
        self.isArchived = isArchived; self.sortOrder = sortOrder; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

public struct MeetingFolder: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var meetingCount: Int
    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), meetingCount: Int = 0) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.meetingCount = meetingCount
    }
}

/// Who named a transcript line's speaker.
public enum SpeakerOrigin: String, Sendable {
    /// Read from the meeting app's window (`SpeakerAttribution`); replaced whenever the names are worked out again.
    case ax
    /// Set or changed by the user; never replaced automatically.
    case user
}

public struct MeetingSegment: Identifiable, Hashable, Sendable {
    public var id: String
    public var meetingID: String
    public var seq: Int
    public var source: MeetingSource
    /// The person speaking ("Ada Lovelace"); nil means the source's default label ("You", "Others").
    public var speaker: String?
    /// Where `speaker` came from (nil while it is the default label).
    public var speakerOrigin: SpeakerOrigin?
    /// Position on the recording timeline (same clock for both tracks).
    public var startMs: Int
    public var endMs: Int
    public var text: String
    public var editedText: String?
    /// True when a microphone line only repeated the call audio (speaker bleed), so it is hidden.
    public var latched: Bool
    public var marker: MeetingMarker?
    /// Wall-clock time of a marker.
    public var epoch: Date?

    public init(id: String = UUID().uuidString, meetingID: String, seq: Int = 0, source: MeetingSource, speaker: String? = nil,
                startMs: Int, endMs: Int, text: String = "", editedText: String? = nil, latched: Bool = false,
                marker: MeetingMarker? = nil, epoch: Date? = nil, speakerOrigin: SpeakerOrigin? = nil) {
        self.id = id; self.meetingID = meetingID; self.seq = seq; self.source = source; self.speaker = speaker
        self.startMs = startMs; self.endMs = endMs; self.text = text; self.editedText = editedText
        self.latched = latched; self.marker = marker; self.epoch = epoch; self.speakerOrigin = speakerOrigin
    }

    public var displayText: String { editedText ?? text }
    public var speakerLabel: String { speaker ?? source.speakerLabel }
}

/// Formats a timeline position as M:SS or H:MM:SS.
public func formatTimestamp(ms: Int) -> String {
    let total = max(0, ms / 1000)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
