import SwiftUI
import ShoutKit

/// A scratchpad for longer dictation. Click into a note and hold the shortcut to dictate. The list matches History:
/// search, then notes by the day they were last edited.
struct NotesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: SettingsStore
    @State private var selection: Int64?
    @State private var title = ""
    @State private var body_ = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var search = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SearchField(text: $search, prompt: "Search")
                    Button(action: newNote) { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless).help("New note")
                }
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

                let found = filtered
                if found.isEmpty {
                    EmptyStateView(symbol: search.isEmpty ? "note.text" : "magnifyingglass",
                                   title: search.isEmpty ? "No notes yet" : "No results",
                                   message: search.isEmpty ? "Notes you write or dictate show up here." : "Try a different search.")
                } else {
                    List(selection: Binding(get: { selection }, set: { if let id = $0 { select(id) } })) {
                        ForEach(DaySections.group(found) { $0.updatedAt }, id: \.0) { day, items in
                            Section {
                                ForEach(items) { n in NoteRow(note: n).tag(n.id).contextMenu { menu(n) } }
                            } header: {
                                Text(day).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 460)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Group {
                if selection != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Title", text: $title).font(.title2.bold()).textFieldStyle(.plain)
                        Divider()
                        TextEditor(text: $body_).font(.system(size: 15)).scrollContentBackground(.hidden)
                    }
                    .padding(20)
                    .onChange(of: title) { _, _ in scheduleSave() }
                    .onChange(of: body_) { _, _ in scheduleSave() }
                } else {
                    EmptyStateView(symbol: "note.text", title: "Scratchpad",
                                   message: "Create a note, click into it and hold \(settings.settings.pushToTalk.displayString) to think out loud.",
                                   action: ("New note", newNote))
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Leaving the page inside the save delay would otherwise drop the last edits.
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
            saveNow()
        }
    }

    /// Matches titles and text, ignoring case and accents. Notes are few, so this filters in memory.
    private var filtered: [Note] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return store.notes }
        return store.notes.filter { $0.title.localizedStandardContains(q) || $0.body.localizedStandardContains(q) }
    }

    @ViewBuilder private func menu(_ n: Note) -> some View {
        Button("Copy") { TextInserter.copy(n.title.isEmpty ? n.body : n.title + "\n\n" + n.body) }
        Divider()
        Button("Delete", role: .destructive) {
            store.deleteNote(id: n.id)
            if selection == n.id { selection = nil }
        }
    }

    private func newNote() {
        search = "" // so the new note is in the list
        select(store.addNote())
    }

    private func select(_ id: Int64) {
        saveNow()
        // A failed insert returns id 0. Opening it would leave the previous note's text in an editor that saves nowhere.
        guard let n = store.notes.first(where: { $0.id == id }) else { return }
        selection = id
        title = n.title; body_ = n.body
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { saveNow() }
        }
    }

    private func saveNow() {
        guard let id = selection, let n = store.notes.first(where: { $0.id == id }), n.title != title || n.body != body_ else { return }
        store.updateNote(id: id, title: title, body: body_)
    }
}

/// A note in the list, laid out like a History row: title and time, then a two-line preview.
private struct NoteRow: View {
    let note: Note

    var body: some View {
        let (heading, preview) = parts
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(heading).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(note.updatedAt, style: .time).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(preview.isEmpty ? "No additional text" : preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(preview.isEmpty ? HierarchicalShapeStyle.tertiary : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }

    /// The title, or for an untitled note its first line (the preview then starts after it). Only the start of a
    /// long note is read: the row shows two lines.
    private var parts: (String, String) {
        let lines = note.body.prefix(1_000).split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return (title, lines.joined(separator: " ")) }
        guard let first = lines.first else { return ("New note", "") }
        return (first, lines.dropFirst().joined(separator: " "))
    }
}
