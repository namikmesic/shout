import SwiftUI
import ShoutKit
import ShoutLLM

/// A question for Ask: about all meetings, or one meeting. An empty question opens the past chats instead.
struct AskRequest: Identifiable {
    let id = UUID()
    let question: String
    let meetingID: String?
    /// A saved chat to reopen (with an empty question).
    var chatID: String? = nil
}

/// Ask: answers questions about meetings with the local language model, with follow-up questions
/// and the meetings each answer drew on. Chats are saved on this Mac and can be reopened.
struct AskSheet: View {
    let request: AskRequest
    /// Snapshots: show these exchanges instead of asking the model.
    var preview: [Exchange]? = nil
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.dismiss) private var dismiss
    @State private var turns: [Exchange] = []
    @State private var draft = ""
    @State private var task: Task<Void, Never>?
    /// Where this conversation is saved (created with its first question).
    @State private var chatID: String?
    @State private var pastChats: [AskChat] = []
    /// The request has been acted on: `onAppear` can run again for the same sheet, and must not ask twice.
    @State private var requestHandled = false

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var error: String?
        var sources: [AskMessage.Source] = []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                Text(scopeTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                historyMenu
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if turns.isEmpty {
                chatList
            } else {
                conversation
            }
            Divider()
            HStack(spacing: 10) {
                TextField(turns.isEmpty ? "Ask a question…" : "Ask a follow-up…", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 13.5))
                    .onSubmit { ask(draft) }
                Button { ask(draft) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(canAsk ? Color.accentColor : Color.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canAsk)
                .accessibilityLabel("Ask")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .onAppear {
            pastChats = store.askChats(meetingID: request.meetingID)
            guard !requestHandled else { return }
            requestHandled = true
            if let preview { turns = preview }
            else if let id = request.chatID { open(id) }
            else { ask(request.question) }
        }
        .onDisappear(perform: stop)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(turns) { t in
                        ExchangeView(exchange: t) { id in
                            router.openMeeting(id)
                            dismiss()
                            // Asked from the Notepad, the main window may be closed or behind the call.
                            (NSApp.delegate as? AppDelegate)?.openMainWindow(page: nil)
                        }
                        .id(t.id)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: turns.last?.answer) { _, _ in
                if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    /// No conversation yet: the saved chats for this meeting (or for all meetings), newest first.
    @ViewBuilder private var chatList: some View {
        if pastChats.isEmpty {
            EmptyStateView(symbol: "bubble.left.and.text.bubble.right", title: "No chats yet",
                           message: "Ask a question below. Your questions and answers are saved on this Mac.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECENT CHATS").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                        .padding(.leading, 2)
                    Card(padding: 0, spacing: 0) {
                        ForEach(pastChats) { chat in
                            ChatRow(chat: chat) { open(chat.id) }
                                .contextMenu {
                                    Button("Delete Chat", role: .destructive) {
                                        store.deleteAskChat(id: chat.id)
                                        // A question asked next must not go to the deleted chat.
                                        if chat.id == chatID { chatID = nil }
                                        pastChats = store.askChats(meetingID: request.meetingID)
                                    }
                                }
                            if chat.id != pastChats.last?.id { Divider().padding(.leading, 44) }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var historyMenu: some View {
        Menu {
            Button("New Chat") { stop(); chatID = nil; turns = [] }
                .disabled(turns.isEmpty)
            if !pastChats.isEmpty {
                Divider()
                Section("Recent Chats") {
                    ForEach(pastChats.prefix(12)) { chat in
                        Button(chat.title) { open(chat.id) }.disabled(chat.id == chatID)
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(busy)
        .help("Past chats")
        .accessibilityLabel("Past chats")
    }

    private var scopeTitle: String {
        if let id = request.meetingID, let m = store.meeting(id: id) { return "Ask about “\(m.displayTitle)”" }
        return "Ask about your meetings"
    }

    private var busy: Bool { turns.last.map { $0.answer == nil && $0.error == nil } ?? false }
    private var canAsk: Bool { !busy && !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func close() {
        stop()
        dismiss()
    }

    /// An answer still being written when the sheet closes (or another chat opens) is saved as interrupted.
    private func stop() {
        guard busy else { return }
        task?.cancel()
        if let chatID { store.interruptPendingAskAnswers(chatID: chatID) }
        if let i = turns.indices.last { turns[i].error = "Stopped before answering." }
    }

    /// Shows a saved chat; new questions continue it.
    private func open(_ id: String) {
        stop()
        var questions: [String: String] = [:]
        var out: [Exchange] = []
        for m in store.askMessages(chatID: id).sorted(by: { $0.order < $1.order }) {
            switch m.role {
            case .user:
                questions[m.turnID] = m.content
            case .assistant:
                guard let q = questions[m.turnID] else { continue }
                switch m.status {
                case .succeeded: out.append(Exchange(question: q, answer: m.content, sources: m.sources))
                case .failed: out.append(Exchange(question: q, error: m.content.isEmpty ? "The answer couldn't be written." : m.content,
                                                  sources: m.sources))
                case .pending, .interrupted: out.append(Exchange(question: q, error: "Stopped before answering.", sources: m.sources))
                }
            }
        }
        chatID = id
        turns = out
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        draft = ""
        let history = turns.compactMap { t in t.answer.map { MeetingAsk.Turn(question: t.question, answer: $0) } }
        let chat = chatID ?? store.createAskChat(meetingID: request.meetingID, title: q).id
        chatID = chat
        let exchange = Exchange(question: q)
        turns.append(exchange)
        let meetingID = request.meetingID
        let settingsStore = settings
        let userName = settingsStore.settings.userName.isEmpty ? nil : settingsStore.settings.userName
        let started = Date()
        task = Task { @MainActor in
            // Searching all meetings reads every candidate's transcript: off the main thread.
            let sources = await Task.detached(priority: .userInitiated) { [store] in
                store.askSources(question: q, meetingID: meetingID)
            }.value
            // Ask can be open for one meeting in the main window and the Notepad: if the other deleted this chat,
            // the question starts a new one instead of failing to save (nothing awaits between check and save).
            var chat = chat
            if !store.askChatExists(id: chat) {
                guard !Task.isCancelled else { return }
                chat = store.createAskChat(meetingID: meetingID, title: q).id
                chatID = chat
            }
            // Saved even when stopped meanwhile, so the chat isn't left empty.
            let pending = store.addAskQuestion(chatID: chat, question: q, sources: sources)
            pastChats = store.askChats(meetingID: meetingID)
            if Task.isCancelled {
                store.interruptPendingAskAnswers(chatID: chat)
                return
            }
            if let i = turns.firstIndex(where: { $0.id == exchange.id }) { turns[i].sources = pending.sources }
            do {
                guard let generator = try await EngineHub.shared.generatorLoadingIfNeeded() else {
                    throw TextGeneratorError.unavailable("Ask needs a language model. Choose one in Models.")
                }
                let answer = try await MeetingAsk.answer(question: q, history: history, sources: sources,
                                                         userName: userName, generator: generator)
                if Task.isCancelled { return }
                let text = answer.isEmpty ? "I couldn't find an answer in your meetings." : answer
                if let i = turns.firstIndex(where: { $0.id == exchange.id }) { turns[i].answer = text }
                store.finishAskAnswer(id: pending.id, content: text, status: .succeeded, model: generator.displayName,
                                      latencyMs: Int(Date().timeIntervalSince(started) * 1000))
            } catch {
                if Task.isCancelled { return }
                if let i = turns.firstIndex(where: { $0.id == exchange.id }) { turns[i].error = error.localizedDescription }
                store.finishAskAnswer(id: pending.id, content: error.localizedDescription, status: .failed)
            }
            EngineHub.shared.primeCleanupCache(settingsStore.settings)
        }
    }
}

/// A saved chat in the list: its first question and when it was last used.
private struct ChatRow: View {
    let chat: AskChat
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(CalendarText.noteTime(chat.modifiedAt, now: Date())).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.primary.opacity(hover ? 0.035 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ExchangeView: View {
    let exchange: AskSheet.Exchange
    let openMeeting: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 60)
                Text(exchange.question)
                    .font(.system(size: 13.5))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                    .textSelection(.enabled)
            }
            if let answer = exchange.answer {
                MarkdownText(markdown: answer)
                if !exchange.sources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(exchange.sources, id: \.id) { s in
                                Button { openMeeting(s.id) } label: {
                                    Chip(symbol: "doc.text", text: s.title)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(s.title)")
                            }
                        }
                    }
                }
            } else if let error = exchange.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(exchange.sources.isEmpty ? "Thinking…" : "Reading \(exchange.sources.count) meeting\(exchange.sources.count == 1 ? "" : "s")…")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
