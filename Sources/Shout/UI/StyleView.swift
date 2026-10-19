import SwiftUI
import ShoutKit

/// Style as a mixing board: one row per setting, each with its slider in the same column on the right, and a single
/// preview below for the row last moved or clicked.
struct StyleView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var addingApp = false
    @State private var channel: Channel

    /// A row of the board.
    enum Channel: Hashable {
        case formatting
        case tone(StyleCategory)
    }

    init(channel: Channel = .formatting) {
        _channel = State(initialValue: channel)
    }

    var body: some View {
        Page(title: "Style", subtitle: "How Shout edits what you say. Tones adapt to the kind of app you're typing in.") {
            Card(padding: 0, spacing: 0) {
                ChannelRow(symbol: "wand.and.stars", title: "AI formatting", detail: "How much Shout rewrites what you say",
                           labels: CleanupLevel.allCases.map(\.title), index: levelIndex,
                           selected: channel == .formatting) { select(.formatting) }
                Divider()
                Text("Tone by app type")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 2)
                ForEach(StyleCategory.allCases) { cat in
                    if cat != StyleCategory.allCases.first { Divider().padding(.leading, 56) }
                    ChannelRow(symbol: cat.symbol, title: cat.title, detail: cat.appsDescription,
                               labels: Tone.allCases.map(\.title), index: toneIndex(cat),
                               selected: channel == .tone(cat)) { select(.tone(cat)) }
                }
                Spacer().frame(height: 4)
            }

            StyleMonitor(channel: channel, level: settings.settings.cleanupLevel,
                         tone: { if case .tone(let c) = channel { settings.settings.tone(for: c) } else { .formal } }())

            appOverrides
            emailSignature
        }
        .sheet(isPresented: $addingApp) { AppPicker { bundleID, name in
            guard !settings.settings.appOverrides.contains(where: { $0.bundleID == bundleID }) else { return }
            settings.settings.appOverrides.append(AppOverride(bundleID: bundleID, appName: name, mode: .noAI))
        } }
    }

    private func select(_ c: Channel) {
        guard channel != c else { return }
        withAnimation(.easeOut(duration: 0.15)) { channel = c }
    }

    private var levelIndex: Binding<Int> {
        Binding(get: { CleanupLevel.allCases.firstIndex(of: settings.settings.cleanupLevel) ?? 1 },
                set: { settings.settings.cleanupLevel = CleanupLevel.allCases[$0] })
    }

    private func toneIndex(_ cat: StyleCategory) -> Binding<Int> {
        Binding(get: { Tone.allCases.firstIndex(of: settings.settings.tone(for: cat)) ?? 0 },
                set: { settings.settings.tones[cat] = Tone.allCases[$0] })
    }

    private var appOverrides: some View {
        Card(padding: 0, spacing: 0) {
            CardHeader(title: "App-specific formatting", caption: "Override formatting for individual apps") {
                Button { addingApp = true } label: { Label("Add App", systemImage: "plus") }
            }
            .padding(16)
            ForEach(settings.settings.appOverrides) { o in
                Divider().padding(.leading, o.bundleID == settings.settings.appOverrides.first?.bundleID ? 0 : 48)
                HStack(spacing: 12) {
                    AppIconView(bundleID: o.bundleID, size: 22)
                    Text(o.appName).font(.system(size: 13))
                    Spacer(minLength: 12)
                    Picker("", selection: mode(of: o)) { ForEach(FormatMode.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().fixedSize()
                    Button(role: .destructive) {
                        settings.settings.appOverrides.removeAll { $0.bundleID == o.bundleID }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove \(o.appName)")
                }
                .settingRowPadding()
            }
        }
    }

    private var emailSignature: some View {
        Card(padding: 0, spacing: 0) {
            SettingRow(title: "Email signature", detail: "Added when you dictate a whole email in a mail app") {
                SwitchControl(isOn: $settings.settings.emailSignatureEnabled.animation(.easeOut(duration: 0.15)))
            }
            if settings.settings.emailSignatureEnabled {
                Divider()
                PlaceholderEditor(text: $settings.settings.emailSignature, placeholder: "Best,\nYour Name", minHeight: 60)
                    .padding(16)
            }
        }
    }

    /// Looks the override up by bundle ID on every access. `ForEach($array)` hands out index-based bindings, and a row
    /// that reads its old index after the minus button shrinks the array traps with "Index out of range".
    private func mode(of o: AppOverride) -> Binding<FormatMode> {
        Binding(get: { settings.settings.appOverrides.first { $0.bundleID == o.bundleID }?.mode ?? o.mode },
                set: { mode in
                    if let i = settings.settings.appOverrides.firstIndex(where: { $0.bundleID == o.bundleID }) {
                        settings.settings.appOverrides[i].mode = mode
                    }
                })
    }
}

private extension StyleCategory {
    var symbol: String {
        switch self {
        case .personal: "bubble.left.and.bubble.right"
        case .work: "briefcase"
        case .email: "envelope"
        case .other: "doc.text"
        }
    }
}

/// One row of the board: icon, name and what it covers, then its slider. Moving the slider or clicking the row
/// shows it in the preview.
private struct ChannelRow: View {
    let symbol: String
    let title: String
    let detail: String
    let labels: [String]
    @Binding var index: Int
    let selected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 16)
            SteppedSlider(labels: labels, index: Binding(get: { index }, set: { index = $0; select() }))
                .frame(width: 300)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.06) : Color.clear)
            .padding(.horizontal, 6).padding(.vertical, 3))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

// MARK: - Preview

/// What you say and what Shout types, for the row last moved or clicked.
private struct StyleMonitor: View {
    let channel: StyleView.Channel
    let level: CleanupLevel
    /// The tone of the category shown (ignored for formatting).
    let tone: Tone

    var body: some View {
        Card(spacing: 12) {
            HStack(spacing: 6) {
                Text("Preview").font(.system(size: 13, weight: .semibold))
                Text("·").foregroundStyle(.tertiary)
                Text(heading).font(.system(size: 12.5)).foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("You say", systemImage: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    Text("“\(spoken)”").font(.system(size: 12.5)).foregroundStyle(.secondary).italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().opacity(0.6)
                VStack(alignment: .leading, spacing: 6) {
                    Label("Shout types", systemImage: "text.cursor").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                    result
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                        .id(channel == .formatting ? "f-\(level.rawValue)" : "t-\(heading)")
                        .transition(.opacity.combined(with: .offset(y: 3)))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
        }
        .animation(.easeOut(duration: 0.2), value: level)
        .animation(.easeOut(duration: 0.2), value: tone)
    }

    private var heading: String {
        switch channel {
        case .formatting: "AI formatting, \(level.title)"
        case .tone(let c): "\(c.title), \(tone.title)"
        }
    }

    private var spoken: String {
        switch channel {
        case .formatting: Self.formattingSpoken
        case .tone(let c): Self.toneSpoken[c] ?? ""
        }
    }

    @ViewBuilder private var result: some View {
        switch channel {
        case .formatting:
            Text(Self.formattingResults[level] ?? "").font(.system(size: 13.5))
        case .tone(let c):
            let text = Self.toneSamples[c]?[tone] ?? tone.example
            switch c {
            case .personal, .work:
                // A sent message, as the chat app would show it.
                HStack {
                    Spacer(minLength: 80)
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(c == .personal ? Color(red: 0.2, green: 0.55, blue: 1).gradient : Color(red: 0.36, green: 0.36, blue: 0.4).gradient))
                }
            case .email, .other:
                Text(text).font(.system(size: 13.5))
            }
        }
    }

    private static let formattingSpoken = "um so I was thinking we should uh meet on tuesday at two actually no three and can you send the deck to priya before then"
    private static let formattingResults: [CleanupLevel: String] = [
        .off: "Um, so I was thinking we should, uh, meet on Tuesday at two, actually no, three, and can you send the deck to Priya before then?",
        .light: "So I was thinking we should meet on Tuesday at 3. Can you send the deck to Priya before then?",
        .medium: "Let's meet on Tuesday at 3. Can you send the deck to Priya before then?",
        .high: "Meet Tuesday at 3? Please send Priya the deck first.",
    ]

    private static let toneSpoken: [StyleCategory: String] = [
        .personal: "hey are you free for lunch tomorrow let's do twelve if that works for you",
        .work: "could you review the pull request before standup I'd like to merge it today",
        .email: "hi priya thank you for the proposal I'll review it this afternoon and reply by friday",
        .other: "the launch moves to thursday marketing will update the announcement",
    ]

    private static let toneSamples: [StyleCategory: [Tone: String]] = [
        .personal: [
            .formal: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you.",
            .casual: "Hey are you free for lunch tomorrow? Let's do 12 if that works for you",
            .veryCasual: "hey are you free for lunch tomorrow? let's do 12 if that works for you",
            .excited: "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you!",
        ],
        .work: [
            .formal: "Could you review the pull request before standup? I'd like to merge it today.",
            .casual: "Could you review the PR before standup? I'd like to merge it today",
            .veryCasual: "could you look at the PR before standup? want to merge it today",
            .excited: "Could you review the PR before standup? I'd love to merge it today!",
        ],
        .email: [
            .formal: "Hi Priya, thank you for the proposal. I'll review it this afternoon and reply by Friday.",
            .casual: "Hi Priya, thanks for the proposal. I'll take a look this afternoon and get back to you by Friday",
            .veryCasual: "hi priya, thanks for the proposal, will look at it this afternoon and get back to you by friday",
            .excited: "Hi Priya, thank you so much for the proposal! I'll dig in this afternoon and reply by Friday.",
        ],
        .other: [
            .formal: "The launch moves to Thursday. Marketing will update the announcement.",
            .casual: "Launch moves to Thursday. Marketing will update the announcement",
            .veryCasual: "launch moves to thursday, marketing will update the announcement",
            .excited: "The launch moves to Thursday! Marketing will update the announcement.",
        ],
    ]
}

/// Lists installed/running apps to pick one for an override.
struct AppPicker: View {
    let onPick: (String, String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    @State private var apps: [(id: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose an app").font(.headline)
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            List(apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }, id: \.id) { app in
                HStack {
                    // Resolved per visible row and cached, rather than one icon per installed app up front.
                    AppIconView(bundleID: app.id, size: 20)
                    Text(app.name)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { onPick(app.id, app.name); dismiss() }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() } }
        }
        .padding(20)
        .frame(width: 380, height: 460)
        .task {
            // Reading every app's Info.plist takes a noticeable moment, so do it off the main thread.
            apps = await Task.detached(priority: .userInitiated) { Self.installedApps() }.value
        }
    }

    private nonisolated static func installedApps() -> [(id: String, name: String)] {
        var seen = Set<String>()
        var out: [(id: String, name: String)] = []
        let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let path = dir + "/" + name
                guard let b = Bundle(path: path), let id = b.bundleIdentifier, !seen.contains(id) else { continue }
                seen.insert(id)
                out.append((id, (name as NSString).deletingPathExtension))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
