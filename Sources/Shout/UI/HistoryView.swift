import SwiftUI
import AVFoundation
import ShoutKit

struct HistoryView: View {
    let controller: DictationController
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: SettingsStore
    @State private var entries: [HistoryEntry] = []
    @State private var days: [(String, [HistoryEntry])] = []
    @State private var search = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var selection: HistoryEntry.ID?
    @State private var confirmClear = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    SearchField(text: $search, prompt: "Search")
                    if !entries.isEmpty {
                        Menu {
                            Button("Delete All History…", role: .destructive) { confirmClear = true }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

                if entries.isEmpty {
                    EmptyStateView(symbol: search.isEmpty ? "waveform" : "magnifyingglass",
                                   title: search.isEmpty ? "No dictations yet" : "No results",
                                   message: search.isEmpty ? "Hold \(settings.settings.pushToTalk.displayString) in any app and start talking." : "Try a different search.")
                } else {
                    List(selection: $selection) {
                        ForEach(days, id: \.0) { day, items in
                            Section {
                                ForEach(items) { e in HistoryRow(entry: e).tag(e.id).contextMenu { menu(e) } }
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
                if let id = selection, let e = entries.first(where: { $0.id == id }) {
                    HistoryDetail(entry: e) { store.deleteHistory(id: e.id); selection = nil }
                } else {
                    EmptyStateView(symbol: "text.bubble", title: "Select a dictation", message: "See the original speech, the cleaned-up text and how long each step took.")
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reload)
        .onChange(of: search) { _, new in
            // Wait for a pause in typing: every reload is a LIKE scan of the whole table plus a rebuilt list.
            searchTask?.cancel()
            if new.isEmpty { reload(); return }
            searchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                if !Task.isCancelled { reload() }
            }
        }
        .onChange(of: store.revision) { _, _ in reload() }
        .onDisappear { searchTask?.cancel() }
        .confirmationDialog("Delete all history?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { store.deleteAllHistory() }
        } message: { Text("This removes every saved transcript and recording from this Mac.") }
    }

    @ViewBuilder private func menu(_ e: HistoryEntry) -> some View {
        Button("Copy") { TextInserter.copy(e.finalText) }
        Button("Copy Original Speech") { TextInserter.copy(e.rawText) }
        Divider()
        Button("Delete", role: .destructive) { store.deleteHistory(id: e.id) }
    }

    private func reload() {
        searchTask?.cancel()
        entries = store.history(limit: 500, search: search.isEmpty ? nil : search)
        // Built once per reload, not on every redraw (up to 500 rows).
        days = DaySections.group(entries) { $0.createdAt }
    }
}

/// Day sections for History and Notes: "Today", "Yesterday", then the full date.
@MainActor
enum DaySections {
    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none; f.doesRelativeDateFormatting = true
        return f
    }()

    /// The items by day, keeping their order (newest first when they come that way).
    static func group<T>(_ items: [T], date: (T) -> Date) -> [(String, [T])] {
        var order: [String] = []
        var map: [String: [T]] = [:]
        for item in items {
            let k = formatter.string(from: date(item))
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(item)
        }
        return order.map { ($0, map[$0]!) }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String
    /// Lets the owner move focus into the field (e.g. on ⌘F).
    var focus: FocusState<Bool>.Binding? = nil
    /// Esc in the field.
    var onEscape: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            field
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder private var field: some View {
        let base = TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 13))
        switch (focus, onEscape) {
        case let (focus?, escape?): base.focused(focus).onExitCommand(perform: escape)
        case let (focus?, nil): base.focused(focus)
        case let (nil, escape?): base.onExitCommand(perform: escape)
        case (nil, nil): base
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIconView(bundleID: entry.bundleID, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.appName ?? "Unknown app").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if entry.mode == .command { Badge(text: "Command", tint: .purple) }
                    if entry.mode == .transform { Badge(text: "Prompt", tint: .indigo) }
                    if entry.status == .copied { Badge(text: "Copied", tint: .orange) }
                    if entry.editedText != nil { Badge(text: "Edited", tint: .teal) }
                    Spacer(minLength: 4)
                    Text(entry.createdAt, style: .time).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Text(entry.finalText.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct HistoryDetail: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @EnvironmentObject var store: Store
    @State private var player: AVAudioPlayer?
    /// The prompt's pictures, if it had any.
    @State private var pictures: PromptCaptureArchive.Saved?

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    AppIconView(bundleID: entry.bundleID, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.appName ?? "Unknown app").font(.system(size: 16, weight: .semibold))
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let path = entry.audioPath, FileManager.default.fileExists(atPath: path) {
                        Button { play(path) } label: { Image(systemName: "play.fill") }.help("Play recording")
                    }
                    CopyButton(text: entry.finalText, label: "Copy")
                    Menu {
                        Button("Copy Original Speech") { TextInserter.copy(entry.rawText) }
                        Divider()
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }

                if let instruction = entry.instruction {
                    textCard("Instruction", instruction, symbol: "sparkles")
                }
                textCard(entry.mode == .command ? "Result" : (entry.mode == .transform ? "Prompt" : "Transcript"), entry.finalText,
                         symbol: "text.alignleft", prominent: true)
                if let pictures, !pictures.captures.isEmpty { PromptPicturesCard(pictures: pictures) }
                if let edited = entry.editedText { textCard("After your edits", edited, symbol: "pencil") }
                if entry.rawText != entry.finalText && entry.mode != .command && !entry.rawText.isEmpty {
                    textCard("Original speech", entry.rawText, symbol: "waveform", secondary: true)
                }

                Card(spacing: 0) {
                    CardHeader(title: "Details").padding(.bottom, 8)
                    infoRow("Words", "\(entry.wordCount)")
                    infoRow("Recording", String(format: "%.1f s", entry.audioSeconds))
                    if entry.audioSeconds > 0 { infoRow("Speaking pace", "\(Int(Double(entry.wordCount) / max(entry.audioSeconds / 60, 0.01))) words per minute") }
                    infoRow("Speech recognition", String(format: "%.2f s · %@", entry.asrSeconds, entry.asrModel ?? "–"))
                    if let llm = entry.llmModel { infoRow("AI editing", String(format: "%.2f s · %@", entry.llmSeconds, llm)) }
                    infoRow("Total processing", String(format: "%.2f s", entry.totalSeconds))
                    if let lang = entry.language { infoRow("Language", Locale.current.localizedString(forLanguageCode: lang) ?? lang) }
                    if let note = entry.error { infoRow("Note", note) }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .task(id: entry.id) { pictures = PromptCaptureArchive.load(historyID: entry.id, root: store.capturesRoot)?.saved }
        }
        // The detail view is reused when the selection changes, so stop the previous dictation's recording.
        .onChange(of: entry.id) { _, _ in stop() }
        .onDisappear(perform: stop)
    }

    private var subtitle: String {
        var parts = [entry.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let host = entry.url.flatMap({ URL(string: $0)?.host }) { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    private func textCard(_ title: String, _ text: String, symbol: String, prominent: Bool = false, secondary: Bool = false) -> some View {
        Card(spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: prominent ? 14 : 13))
                .lineSpacing(3)
                .foregroundStyle(secondary ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(k).font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer(minLength: 16)
                Text(v).font(.system(size: 12.5)).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .padding(.vertical, 7)
            Divider().opacity(0.5)
        }
    }

    private func play(_ path: String) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)), p.play() else {
            NSSound.beep() // the recording was removed or can't be read
            return
        }
        player = p
    }

    private func stop() {
        player?.stop()
        player = nil
    }
}

/// A prompt's screenshots in History: each picture, what was said when it was taken, and what was under the mouse.
struct PromptPicturesCard: View {
    let pictures: PromptCaptureArchive.Saved

    var body: some View {
        Card(spacing: 14) {
            CardHeader(title: "Screenshots", caption: "Taken while you described the prompt, with what you were saying")
            ForEach(Array(pictures.captures.enumerated()), id: \.offset) { i, c in
                if i > 0 { Divider() }
                HStack(alignment: .top, spacing: 14) {
                    PictureThumbnail(path: c.path)
                        .frame(width: 168, height: 105)
                        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: c.path)) }
                        .help("Open")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Screenshot \(i + 1)").font(.system(size: 13, weight: .semibold))
                        if !c.said.isEmpty {
                            Text("“\(c.said)”").font(.system(size: 12.5)).italic().foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let selection = c.selection {
                            Text("Selected" + (c.location.map { " in \($0)" } ?? "") + (c.detail.map { " · \($0)" } ?? ""))
                                .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                                .lineLimit(2).truncationMode(.middle)
                            Text(selection.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(size: 11.5, design: c.location == nil ? .default : .monospaced))
                                .lineLimit(6)
                                .textSelection(.enabled)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05)))
                        } else if let detail = c.detail {
                            Text("Pointed at \(detail)").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: c.path)) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.path)]) }
                        }
                        .controlSize(.small)
                        .disabled(!FileManager.default.fileExists(atPath: c.path))
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A downsampled preview of an image file, loaded off the main thread.
struct PictureThumbnail: View {
    let path: String
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(4)
            } else if missing {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(.tertiary)
                    Text("No longer available").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .task(id: path) {
            let p = path
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
                let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                             kCGImageSourceThumbnailMaxPixelSize: 480,
                                             kCGImageSourceCreateThumbnailWithTransform: true]
                return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            }.value
            if let cg { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) } else { missing = true }
        }
    }
}
