import SwiftUI
import ShoutKit

/// The add or edit form showing over Dictionary or Snippets: `entry` is nil when adding.
private struct EntryForm: Identifiable {
    let entry: DictionaryEntry?
    var id: Int64 { entry?.id ?? 0 }
}

struct DictionaryView: View {
    @EnvironmentObject var store: Store
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var form: EntryForm?
    @State private var deleting: DictionaryEntry?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", manual = "Added by you", learned = "Learned"
        var id: String { rawValue }
    }

    var body: some View {
        Page(title: "Dictionary",
             subtitle: "Names, jargon and spellings Shout should always get right. Shout also learns words when you correct them.") {
            HStack(spacing: 10) {
                SearchField(text: $search, prompt: "Search").frame(width: 200)
                Button(action: add) { Label("Add Word", systemImage: "plus").padding(.horizontal, 2) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("n", modifiers: .command)
                    .help("Add a word (⌘N)")
            }
        } content: {
            HStack {
                Picker("", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("\(items.count) \(items.count == 1 ? "entry" : "entries")").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }

            if items.isEmpty {
                Card { empty.frame(height: 220) }
            } else {
                Card(padding: 0, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { Divider().padding(.leading, 44) }
                        DictionaryRow(entry: e, edit: { form = EntryForm(entry: e) }, delete: { deleting = e })
                    }
                }
            }
        }
        .sheet(item: $form) { DictionaryEntrySheet(entry: $0.entry) }
        .deleteConfirmation($deleting, message: "It's removed from your dictionary.")
    }

    @ViewBuilder private var empty: some View {
        if !search.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "No words match “\(search)”.")
        } else if filter == .learned {
            EmptyStateView(symbol: "sparkles", title: "Nothing learned yet",
                           message: "When you correct a word Shout got wrong, it learns the spelling and lists it here.")
        } else {
            EmptyStateView(symbol: "character.book.closed", title: "No words yet",
                           message: "Add people's names, product names, acronyms or technical terms.", action: ("Add Word", add))
        }
    }

    private func add() { form = EntryForm(entry: nil) }

    private var items: [DictionaryEntry] {
        store.dictionary.filter { !$0.isSnippet }.filter {
            switch filter { case .all: true; case .manual: $0.source == .manual; case .learned: $0.source == .auto }
        }.filter { search.isEmpty || $0.phrase.localizedCaseInsensitiveContains(search) || ($0.replacement ?? "").localizedCaseInsensitiveContains(search) }
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let edit: () -> Void
    let delete: () -> Void
    @EnvironmentObject var store: Store
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggleStar) {
                Image(systemName: entry.isStarred ? "star.fill" : "star")
                    .foregroundStyle(entry.isStarred ? Color.yellow : Color.secondary.opacity(hover ? 0.8 : 0.35))
            }
            .buttonStyle(.plain).frame(width: 18).help("Starred words are always used as hints")
            Text(entry.phrase).font(.system(size: 13, weight: .medium))
            if let r = entry.replacement {
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                Text(r).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            if entry.source == .auto {
                Badge(text: entry.observedAs.map { "Learned from “\($0)”" } ?? "Learned", tint: .teal)
            }
            Spacer(minLength: 8)
            if entry.useCount > 0 { Text("Used \(entry.useCount)×").font(.system(size: 11)).foregroundStyle(.tertiary) }
            RowActions(edit: edit, delete: delete).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: edit)
        .contextMenu {
            Button("Edit…", action: edit)
            Button(entry.isStarred ? "Unstar" : "Star", action: toggleStar)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
    }

    private func toggleStar() { var x = entry; x.isStarred.toggle(); store.updateDictionaryEntry(x) }
}

/// Adds a word, or edits one. A word can also correct a misspelling: Shout then writes the word whenever it hears
/// the misspelling (saved as phrase = misspelling, replacement = word, and listed as "misspelling → word").
struct DictionaryEntrySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let entry: DictionaryEntry?
    @State private var word: String
    @State private var misspelling: String
    @State private var correcting: Bool
    @State private var failed = false
    @FocusState private var focus: Field?

    private enum Field { case word, misspelling }

    /// `word` and `misspelling` prefill a new entry (snapshots).
    init(entry: DictionaryEntry?, word: String = "", misspelling: String = "") {
        self.entry = entry
        let fixes = entry.map { $0.replacement != nil } ?? !misspelling.isEmpty
        _correcting = State(initialValue: fixes)
        _word = State(initialValue: entry.map { $0.replacement ?? $0.phrase } ?? word)
        _misspelling = State(initialValue: entry.map { $0.replacement != nil ? $0.phrase : "" } ?? misspelling)
    }

    var body: some View {
        FormSheet(title: entry == nil ? "Add to Dictionary" : (entry?.replacement == nil ? "Edit Word" : "Edit Correction"),
                  subtitle: entry == nil ? "A name, term or piece of jargon Shout should always spell right." : nil,
                  confirmTitle: entry == nil ? "Add Word" : "Save Changes",
                  canConfirm: canSave, problem: problem, confirm: save) {
            FormField(label: "Word or phrase") {
                TextField("e.g. Kubernetes, Priya Raman, OKR", text: $word)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .focused($focus, equals: .word)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Correct a misspelling").font(.system(size: 13))
                        Text("Shout writes the word above whenever it hears the misspelling, e.g. “btw” → “by the way”.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("Correct a misspelling", isOn: $correcting.animation(.easeOut(duration: 0.15)))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                if correcting {
                    FormField(label: "Misspelling") {
                        TextField("What Shout hears, e.g. Cooper Netties", text: $misspelling)
                            .textFieldStyle(.roundedBorder).controlSize(.large)
                            .focused($focus, equals: .misspelling)
                    }
                    .transition(.opacity)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
        .defaultFocus($focus, .word)
        .onChange(of: correcting) { _, on in focus = on ? .misspelling : .word }
        .onChange(of: word) { _, _ in failed = false }
        .onChange(of: misspelling) { _, _ in failed = false }
    }

    private var phrase: String { (correcting ? misspelling : word).trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phrase.isEmpty && duplicate == nil
    }

    /// Another word (or correction) with the same phrase: the database allows one per phrase, ignoring case.
    private var duplicate: DictionaryEntry? {
        let p = phrase.lowercased()
        guard !p.isEmpty else { return nil }
        return store.dictionary.first { !$0.isSnippet && $0.id != entry?.id && $0.phrase.lowercased() == p }
    }

    private var problem: String? {
        if let d = duplicate {
            if let r = d.replacement { return "“\(d.phrase)” is already corrected to “\(r)”." }
            return "“\(d.phrase)” is already in your dictionary."
        }
        return failed ? "Couldn't save. Try again." : nil
    }

    private func save() {
        // Return reaches this even while the button is disabled.
        guard canSave else { return }
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved: Bool
        if var e = entry {
            e.phrase = phrase
            e.replacement = correcting ? w : nil
            saved = store.updateDictionaryEntry(e)
        } else {
            saved = store.addDictionaryEntry(phrase: phrase, replacement: correcting ? w : nil)
        }
        if saved { dismiss() } else { failed = true }
    }
}

struct SnippetsView: View {
    @EnvironmentObject var store: Store
    @State private var form: EntryForm?
    @State private var deleting: DictionaryEntry?

    var body: some View {
        Page(title: "Snippets", subtitle: "Say a short phrase and Shout types the full text: links, addresses, sign-offs or templates.") {
            Button(action: add) { Label("Add Snippet", systemImage: "plus").padding(.horizontal, 2) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("n", modifiers: .command)
                .help("Add a snippet (⌘N)")
        } content: {
            if store.snippets.isEmpty {
                Card {
                    EmptyStateView(symbol: "text.badge.plus", title: "No snippets yet",
                                   message: "Try “my email address” or “my zoom link”.", action: ("Add Snippet", add))
                        .frame(height: 220)
                }
            } else {
                Card(padding: 0, spacing: 0) {
                    ForEach(Array(store.snippets.enumerated()), id: \.element.id) { i, s in
                        if i > 0 { Divider().padding(.leading, 14) }
                        SnippetRow(entry: s, edit: { form = EntryForm(entry: s) }, delete: { deleting = s })
                    }
                }
            }
        }
        .sheet(item: $form) { SnippetSheet(entry: $0.entry) }
        .deleteConfirmation($deleting, message: "Saying it will no longer type the text.")
    }

    private func add() { form = EntryForm(entry: nil) }
}

private struct SnippetRow: View {
    let entry: DictionaryEntry
    let edit: () -> Void
    let delete: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(entry.phrase)”").font(.system(size: 13, weight: .semibold))
                Text(entry.replacement ?? "").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 8)
            if entry.useCount > 0 { Text("Used \(entry.useCount)×").font(.system(size: 11)).foregroundStyle(.tertiary) }
            RowActions(edit: edit, delete: delete).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: edit)
        .contextMenu {
            Button("Edit…", action: edit)
            Divider()
            Button("Delete…", role: .destructive, action: delete)
        }
    }
}

/// Adds a snippet, or edits one: the phrase to say and the text Shout types for it.
struct SnippetSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let entry: DictionaryEntry?
    @State private var trigger: String
    @State private var text: String
    @State private var failed = false
    @FocusState private var triggerFocused: Bool

    /// `trigger` and `text` prefill a new snippet (snapshots).
    init(entry: DictionaryEntry?, trigger: String = "", text: String = "") {
        self.entry = entry
        _trigger = State(initialValue: entry?.phrase ?? trigger)
        _text = State(initialValue: entry?.replacement ?? text)
    }

    var body: some View {
        FormSheet(title: entry == nil ? "Add Snippet" : "Edit Snippet",
                  subtitle: entry == nil ? "Say the phrase while dictating and Shout types the text in its place." : nil,
                  confirmTitle: entry == nil ? "Add Snippet" : "Save Changes",
                  canConfirm: canSave, problem: problem,
                  confirmShortcut: KeyboardShortcut(.return, modifiers: .command),
                  width: 520, confirm: save) {
            FormField(label: "When you say") {
                TextField("e.g. my calendly link", text: $trigger)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .focused($triggerFocused)
            }
            FormField(label: "Shout types") {
                PlaceholderEditor(text: $text, placeholder: "A link, an address, a sign-off or a whole template", minHeight: 160)
                    .frame(height: 160)
            }
            Text("Press ⌘Return to \(entry == nil ? "add" : "save").").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .defaultFocus($triggerFocused, true)
        .onChange(of: trigger) { _, _ in failed = false }
        .onChange(of: text) { _, _ in failed = false }
    }

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && duplicate == nil
    }

    /// Another snippet with the same phrase: the database allows one per phrase, ignoring case.
    private var duplicate: DictionaryEntry? {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        return store.snippets.first { $0.id != entry?.id && $0.phrase.lowercased() == t }
    }

    private var problem: String? {
        if let d = duplicate { return "You already have a snippet for “\(d.phrase)”." }
        return failed ? "Couldn't save. Try again." : nil
    }

    private func save() {
        guard canSave else { return }
        let saved: Bool
        if var e = entry {
            e.phrase = trigger
            e.replacement = text
            saved = store.updateDictionaryEntry(e)
        } else {
            saved = store.addDictionaryEntry(phrase: trigger, replacement: text, isSnippet: true)
        }
        if saved { dismiss() } else { failed = true }
    }
}

/// Edit and Delete buttons at the end of a row, shown on hover.
private struct RowActions: View {
    let edit: () -> Void
    let delete: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button(action: edit) { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
            Button(role: .destructive, action: delete) { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete")
        }
    }
}

private extension View {
    /// Asks before deleting a word or snippet.
    func deleteConfirmation(_ entry: Binding<DictionaryEntry?>, message: String) -> some View {
        modifier(DeleteConfirmation(entry: entry, message: message))
    }
}

private struct DeleteConfirmation: ViewModifier {
    @Binding var entry: DictionaryEntry?
    let message: String
    @EnvironmentObject var store: Store

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete “\(entry?.phrase ?? "")”?",
                                   isPresented: Binding(get: { entry != nil }, set: { if !$0 { entry = nil } }),
                                   presenting: entry) { e in
            Button("Delete", role: .destructive) { store.deleteDictionaryEntry(id: e.id) }
        } message: { _ in
            Text(message)
        }
    }
}
