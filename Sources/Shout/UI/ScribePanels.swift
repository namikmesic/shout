import SwiftUI
import ShoutKit

// MARK: - Preview panel

/// Right-hand preview of the hovered note (overview, action items) or of the next calendar meeting.
struct PreviewPanel: View {
    let preview: ScribePreview?
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            switch preview {
            case .meeting(let id):
                if let m = store.meeting(id: id) { MeetingPreview(meeting: m) } else { placeholder }
            case .event(let e):
                EventPreview(event: e)
            case nil:
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.025))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.below.photo").font(.system(size: 24)).foregroundStyle(.tertiary)
            Text("Hover over a note to preview it").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Overline: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
    }
}

private struct MeetingPreview: View {
    let meeting: Meeting
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var scribe: ScribeController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(meeting.displayTitle).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(timeLine).font(.system(size: 12)).foregroundStyle(.secondary)
                    if !meeting.participants.isEmpty {
                        Text(meeting.participants.prefix(4).joined(separator: ", ") + (meeting.participants.count > 4 ? " +\(meeting.participants.count - 4)" : ""))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Overline(text: "Overview")
                    overview
                }
                let tasks = store.tasks(meetingID: meeting.id)
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Overline(text: "Action items \(tasks.filter { $0.status == .done }.count)/\(tasks.count)")
                        ForEach(tasks.prefix(5)) { TaskLine(task: $0, compact: true) }
                        if tasks.count > 5 { Text("+\(tasks.count - 5) more").font(.system(size: 11.5)).foregroundStyle(.secondary) }
                    }
                }
                Button("Open Notes") { router.meetingID = meeting.id }
                    .controlSize(.regular)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timeLine: String {
        var s = meeting.createdAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        s += " · " + meeting.createdAt.formatted(date: .omitted, time: .shortened)
        if let end = meeting.endedAt, scribe.activeMeetingID != meeting.id {
            s += " – " + end.formatted(date: .omitted, time: .shortened)
        }
        if let app = meeting.sourceApp { s += " · " + app }
        return s
    }

    @ViewBuilder private var overview: some View {
        if scribe.activeMeetingID == meeting.id {
            Text("Recording now. The summary is written when the meeting ends.").previewBody()
        } else if scribe.processingIDs.contains(meeting.id) || meeting.status == .processing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Transcribing the last few sentences…").previewBody() }
        } else {
            switch meeting.summaryStatus {
            case .ready:
                Text(meeting.summaryOverview ?? "").previewBody().textSelection(.enabled)
            case .generating:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Writing the summary…").previewBody() }
            case .tooShort:
                Text("The meeting was too short to summarize.").previewBody()
            case .noSpeech:
                Text("No speech was transcribed in this meeting.").previewBody()
            case .failed:
                VStack(alignment: .leading, spacing: 6) {
                    Text("The summary couldn't be written.").previewBody()
                    Button("Try Again") { scribe.summarize(meeting.id, rerun: true) }.controlSize(.small)
                }
            case .none:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Not summarized yet.").previewBody()
                    Button("Generate Summary") { scribe.summarize(meeting.id, rerun: true) }.controlSize(.small)
                }
            }
        }
    }
}

private extension Text {
    func previewBody() -> some View {
        font(.system(size: 13)).lineSpacing(3).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
    }
}

private struct EventPreview: View {
    let event: UpcomingEvent
    @EnvironmentObject var scribe: ScribeController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.start <= Date() ? "NOW" : "UP NEXT")
                        .font(.system(size: 10, weight: .bold)).tracking(0.6)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    Text(event.displayTitle).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    TimelineView(.periodic(from: .now, by: 30)) { tl in
                        Text("\(EventTime.range(event)) · \(CalendarText.relativeLabel(event, now: tl.date))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if !event.attendees.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Overline(text: "\(event.attendees.count) attendee\(event.attendees.count == 1 ? "" : "s")")
                        // By position: two attendees (different addresses) can share a display name.
                        ForEach(Array(event.attendees.prefix(8).enumerated()), id: \.offset) { _, name in
                            HStack(spacing: 8) {
                                Avatar(name: name)
                                Text(name).font(.system(size: 12.5)).lineLimit(1)
                            }
                        }
                        if event.attendees.count > 8 {
                            Text("+\(event.attendees.count - 8) more").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                }
                JoinStartButton(event: event)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Initials in a tinted circle.
struct Avatar: View {
    let name: String
    var size: CGFloat = 22
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        // FNV-1a, so a person keeps their colour across launches (`hashValue` is seeded per process).
        let hash = name.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        let hue = Double(hash % 360) / 360
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.75)))
    }
}

enum EventTime {
    static func range(_ e: UpcomingEvent) -> String {
        let f = Date.FormatStyle(date: .omitted, time: .shortened)
        return "\(e.start.formatted(f)) – \(e.end.formatted(f))"
    }
}

/// "Join + Start" when the event has a call link, else "Start Scribe". While another meeting is being
/// recorded it only joins.
struct JoinStartButton: View {
    let event: UpcomingEvent
    var compact = false
    @EnvironmentObject var scribe: ScribeController

    var body: some View {
        if let url = event.conferenceURL {
            // Joining from here tells the Scribe which event the call that follows belongs to.
            if scribe.isRecording {
                Button { join(url) } label: { Label(compact ? "Join" : "Join Meeting", systemImage: "video.fill") }
            } else {
                Menu {
                    Button("Join Meeting") { join(url) }
                    Button("Start Scribe") { scribe.start(event: event) }
                } label: {
                    Label(compact ? "Join + Start" : "Join & Start Scribe", systemImage: "video.fill")
                } primaryAction: {
                    NSWorkspace.shared.open(url)
                    scribe.start(event: event)
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
        } else {
            Button { scribe.start(event: event) } label: {
                Label(compact ? "Start" : "Start Scribe", systemImage: "record.circle")
            }
            .disabled(scribe.isRecording)
        }
    }

    private func join(_ url: URL) {
        scribe.noteJoinIntent(event)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Today

/// Today's meetings from the user's calendars, or an invitation to connect them.
struct TodayCard: View {
    @Binding var preview: ScribePreview?
    @EnvironmentObject var calendar: CalendarService
    @State private var expanded = false

    var body: some View {
        Card(padding: 0, spacing: 0) {
            HStack {
                Text(heading).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                if calendar.access == .granted {
                    Button { calendar.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                        .buttonStyle(.borderless).help("Refresh calendar")
                }
            }
            .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 8)
            content
        }
    }

    private var upcoming: [UpcomingEvent] {
        let now = Date()
        let today = calendar.events.filter { Calendar.current.isDateInToday($0.start) && $0.end > now && !$0.isAllDay }
        if !today.isEmpty { return today }
        return calendar.events.filter { Calendar.current.isDateInTomorrow($0.start) && !$0.isAllDay }
    }

    private var heading: String {
        let now = Date()
        let hasToday = calendar.events.contains { Calendar.current.isDateInToday($0.start) && $0.end > now && !$0.isAllDay }
        return !hasToday && !upcoming.isEmpty ? "TOMORROW" : "TODAY"
    }

    @ViewBuilder private var content: some View {
        if calendar.access != .granted {
            HStack(spacing: 12) {
                Image(systemName: "calendar").font(.system(size: 18)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("See today's meetings here").font(.system(size: 13, weight: .medium))
                    Text("Shout reads your calendars on this Mac for reminders, meeting titles and attendee names.")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                ConnectCalendarButton()
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        } else if upcoming.isEmpty {
            Text("No more meetings today").font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 18)
        } else {
            let shown = expanded ? upcoming : Array(upcoming.prefix(3))
            VStack(spacing: 0) {
                ForEach(shown) { e in
                    EventRow(event: e, conflict: CalendarText.conflicts(e, in: upcoming))
                        .onHover { if $0 { preview = .event(e) } }
                    if e.id != shown.last?.id { Divider().padding(.leading, 30) }
                }
                if upcoming.count > 3 {
                    Button(expanded ? "Show less" : "Show \(upcoming.count - 3) more") {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .buttonStyle(.borderless).font(.system(size: 12)).padding(.vertical, 8)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

private struct EventRow: View {
    let event: UpcomingEvent
    let conflict: Bool
    @EnvironmentObject var scribe: ScribeController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tl in
            let now = tl.date
            let live = event.start <= now && event.end > now
            let soon = event.start.timeIntervalSince(now) < 15 * 60
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: event.colorHex) ?? .accentColor).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.displayTitle).font(.system(size: 13, weight: live ? .semibold : .medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        if conflict { Text("Conflict").foregroundStyle(.orange); Text("·") }
                        if event.myStatus == .tentative { Text("Maybe"); Text("·") }
                        Text(EventTime.range(event))
                        if let p = event.platform { Text("·"); Text(p) }
                    }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(CalendarText.relativeLabel(event, now: now))
                    .font(.system(size: 11.5, weight: live || soon ? .semibold : .regular))
                    .foregroundStyle(live ? Color.red : (soon ? Color.accentColor : Color.secondary))
                if live || soon { JoinStartButton(event: event, compact: true).controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

extension Color {
    /// "#RRGGBB" → Color.
    init?(hex: String?) {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Tasks

/// One action item: tri-state checkbox (open → in progress → done), title and owner.
///
/// Every change is built from `current`, the last change made here until `task` (the parent's copy) catches up. So a
/// second click before the list refreshes moves on from the first (open → in progress → done, not in progress twice),
/// and a click or Archive right after a rename keeps the new title.
struct TaskLine: View {
    let task: MeetingTask
    var compact = false
    /// After Archive or Unarchive from its menu, with the updated task (My Tasks offers Undo).
    var onArchiveToggled: ((MeetingTask) -> Void)? = nil
    /// After Delete from its menu (My Tasks offers Undo).
    var onDeleted: ((MeetingTask) -> Void)? = nil
    /// After any change made here (My Tasks refreshes its list at once rather than after its coalescing delay).
    var onChanged: (() -> Void)? = nil
    @EnvironmentObject var store: Store
    @State private var editing = false
    @State private var draft = ""
    /// The last change written from here, until `task` reflects it.
    @State private var pending: MeetingTask?
    @FocusState private var focused: Bool

    private var current: MeetingTask { pending.flatMap { $0.id == task.id ? $0 : nil } ?? task }

    var body: some View {
        let task = current
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                var t = current; t.status = t.status.next; write(t)
            } label: {
                Image(systemName: symbol(task.status))
                    .font(.system(size: compact ? 13 : 15))
                    .foregroundStyle(task.status == .done ? Color.green : (task.status == .inProgress ? Color.accentColor : Color.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(task.status == .open ? "Mark in progress" : (task.status == .inProgress ? "Mark done" : "Mark open"))
            .accessibilityLabel("Change status of \(task.title)")
            .accessibilityValue(task.status == .open ? "open" : (task.status == .inProgress ? "in progress" : "done"))
            if editing && !compact {
                // Focused when it opens; Return or clicking elsewhere saves, Esc cancels.
                TextField("Action item", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, f in if !f && editing { commit() } }
            } else {
                Text(task.title)
                    .font(.system(size: compact ? 12.5 : 13.5))
                    .strikethrough(task.status == .done, color: .secondary)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2) { if !compact { draft = current.title; editing = true } }
            }
            if let owner = task.owner, !compact {
                Text(owner).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            Spacer(minLength: 0)
        }
        .opacity(task.isArchived ? 0.6 : 1)
        .contextMenu {
            if !compact { Button("Edit") { draft = current.title; editing = true } }
            Button(task.isArchived ? "Unarchive" : "Archive") {
                var t = current; t.isArchived.toggle(); write(t)
                onArchiveToggled?(t)
            }
            Divider()
            Button("Delete", role: .destructive) {
                let t = current
                store.deleteTask(id: t.id)
                onDeleted?(t)
                onChanged?()
            }
        }
        // The parent's copy now includes what was written here (or a newer change from elsewhere).
        .onChange(of: self.task) { _, _ in pending = nil }
        // ⌘Q while renaming keeps the new title, as clicking elsewhere would.
        .onReceive(NotificationCenter.default.publisher(for: .shoutFlushEdits)) { _ in if editing { commit() } }
    }

    private func symbol(_ status: MeetingTask.Status) -> String {
        switch status {
        case .open: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }

    private func write(_ t: MeetingTask) {
        pending = t
        store.updateTask(t)
        onChanged?()
    }

    private func commit() {
        editing = false
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != current.title else { return }
        var updated = current; updated.title = t; write(updated)
    }
}

// MARK: - Markdown export

enum MeetingMarkdown {
    /// Title, date, summary, the user's notes and the transcript as Markdown.
    @MainActor
    static func export(_ m: Meeting, store: Store) -> String {
        var out = "# \(m.displayTitle)\n\n"
        out += m.createdAt.formatted(date: .complete, time: .shortened)
        if m.recordedMs > 0 { out += " · " + MeetingRowFormat.duration(m.duration) }
        if !m.participants.isEmpty { out += "\nAttendees: " + m.participants.joined(separator: ", ") }
        out += "\n\n"
        if let summary = m.summary, !summary.isEmpty { out += "## Summary\n\n\(summary)\n\n" }
        let tasks = store.tasks(meetingID: m.id)
        if !tasks.isEmpty {
            out += "## Action items\n\n"
            for t in tasks { out += "- [\(t.status == .done ? "x" : " ")] \(t.owner.map { "**\($0)**: " } ?? "")\(t.title)\n" }
            out += "\n"
        }
        if !m.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += "## My notes\n\n\(m.notes)\n\n" }
        let transcript = TranscriptView.plainText(store.segments(meetingID: m.id))
        if !transcript.isEmpty { out += "## Transcript\n\n\(transcript)\n" }
        return out
    }
}
