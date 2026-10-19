import SwiftUI
import ShoutKit

struct MainView: View {
    let controller: DictationController
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var hub: EngineHub
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
            Self.detail(router.page, controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .overlay {
            if router.showOnboarding {
                OnboardingView(controller: controller)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: router.showOnboarding)
        .modifier(HideToolbarTitle())
    }

    @ViewBuilder
    static func detail(_ page: AppRouter.Page, controller: DictationController) -> some View {
        switch page {
        case .home: HomeView()
        case .scribe: ScribeView()
        case .tasks: MyTasksView()
        case .history: HistoryView(controller: controller)
        case .dictionary: DictionaryView()
        case .snippets: SnippetsView()
        case .prompts: PromptsView()
        case .style: StyleView()
        case .notes: NotesView()
        case .models: ModelsView()
        case .settings: SettingsView(controller: controller)
        }
    }
}

/// Removes the redundant "Shout" title SwiftUI places in the toolbar (each page has its own title).
private struct HideToolbarTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.toolbar(removing: .title) } else { content.navigationTitle("") }
    }
}

struct Sidebar: View {
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var hub: EngineHub
    @EnvironmentObject var scribe: ScribeController

    var body: some View {
        List(selection: Binding(get: { router.page }, set: { if let p = $0 { router.page = p } })) {
            Section {
                ForEach([AppRouter.Page.home, .scribe, .tasks, .history, .dictionary, .snippets, .prompts, .style, .notes]) { p in
                    HStack {
                        Label(p.title, systemImage: p.symbol)
                        if p == .scribe && scribe.isRecording {
                            Spacer()
                            Circle().fill(Color.red).frame(width: 7, height: 7).accessibilityLabel("Recording")
                        }
                    }
                    .tag(p)
                }
            } header: {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 22, height: 22)
                    Text("Shout").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.primary)
                }
                .padding(.bottom, 6)
            }
            Section("App") {
                ForEach([AppRouter.Page.models, .settings]) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            ScribeSetupChecklist().padding(.bottom, 8)
            statusRow(hub.speechState, fallback: "Speech model")
            statusRow(hub.languageState, fallback: "AI formatting", disabledText: "AI formatting off")
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                Text("Runs on this Mac").font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusRow(_ state: EngineHub.State, fallback: String, disabledText: String? = nil) -> some View {
        HStack(spacing: 7) {
            EngineStatusDot(state: state).frame(width: 13)
            Text(state == .disabled ? (disabledText ?? fallback) : state.label)
                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var hub: EngineHub
    @State private var stats = UsageStats()
    @State private var recent: [HistoryEntry] = []
    @State private var days: [(day: Date, words: Int)] = []

    var body: some View {
        Page(title: greeting, subtitle: "Speak naturally in any app. Shout writes it down, cleans it up and types it for you.") {
            ReadyPill(hub: hub, combo: settings.settings.pushToTalk)
        } content: {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                StatTile(value: stats.totalWords.formatted(), label: "Words dictated", symbol: "text.alignleft")
                StatTile(value: stats.averageWPM > 0 ? "\(Int(stats.averageWPM))" : "–", label: "Words per minute", symbol: "speedometer", tint: .orange)
                StatTile(value: "\(stats.dayStreak) \(stats.dayStreak == 1 ? "day" : "days")", label: "Streak", symbol: "flame.fill", tint: .red)
                StatTile(value: formatMinutes(stats.minutesSaved), label: "Time saved", symbol: "clock.fill", tint: .green)
            }

            Card {
                CardHeader(title: "Activity", caption: "Words per day, last 14 days") {
                    Text("\(stats.wordsToday.formatted()) today").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                }
                ActivityChart(days: days)
            }

            Card(spacing: 10) {
                CardHeader(title: "Shortcuts", caption: "Work in every app") {
                    Button("Customize") { router.page = .settings }.buttonStyle(.link).font(.system(size: 12))
                }
                Divider().opacity(0.6)
                let s = settings.settings
                ShortcutLine(keys: { ComboCaps(combo: s.pushToTalk) }, title: "Dictate", detail: "Hold, speak, release")
                ShortcutLine(keys: {
                    HStack(spacing: 6) {
                        ComboCaps(combo: s.handsFree)
                        Text("or double-tap").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }, title: "Hands-free", detail: "Press again to finish")
                if s.commandModeEnabled {
                    ShortcutLine(keys: { ComboCaps(combo: s.command) }, title: "Command Mode", detail: "Edit selected text by voice")
                }
                ShortcutLine(keys: { ComboCaps(combo: s.pasteLast) }, title: "Paste last", detail: "Insert your last transcript again")
                ShortcutLine(keys: { KeyCap(text: "esc") }, title: "Cancel", detail: "While recording")
            }

            Card(spacing: 0) {
                CardHeader(title: "Recent") {
                    if !recent.isEmpty { Button("Show all") { router.page = .history }.buttonStyle(.link).font(.system(size: 12)) }
                }
                .padding(.bottom, 8)
                if recent.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "waveform").foregroundStyle(.tertiary)
                        Text("Your dictations will appear here.").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(recent) { e in
                        RecentRow(entry: e)
                        if e.id != recent.last?.id { Divider().padding(.leading, 34) }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: store.revision) { _, _ in reload() }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let name = settings.settings.userName.split(separator: " ").first.map { ", \($0)" } ?? ""
        switch h {
        case 5..<12: return "Good morning\(name)"
        case 12..<18: return "Good afternoon\(name)"
        default: return "Good evening\(name)"
        }
    }

    private func reload() {
        stats = store.stats()
        recent = store.history(limit: 5)
        days = store.dailyWords(days: 14)
    }

    private func formatMinutes(_ m: Double) -> String {
        if m < 1 { return "0 min" }
        if m < 60 { return "\(Int(m)) min" }
        return String(format: "%.1f h", m / 60)
    }
}

private struct ReadyPill: View {
    @ObservedObject var hub: EngineHub
    let combo: KeyCombo
    var body: some View {
        HStack(spacing: 6) {
            EngineStatusDot(state: hub.speechState).frame(width: 13)
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .fixedSize()
    }
    private var label: String {
        switch hub.speechState {
        case .ready: "Ready · hold \(combo.displayString)"
        case .loading: "Loading models…"
        case .missingModel: "Download a speech model"
        case .failed: "Speech model error"
        default: "Starting…"
        }
    }
}

private struct ShortcutLine<Keys: View>: View {
    @ViewBuilder var keys: Keys
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 12.5, weight: .medium)).frame(width: 118, alignment: .leading)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            keys
        }
        .frame(minHeight: 24)
    }
}

private struct RecentRow: View {
    let entry: HistoryEntry
    @State private var hover = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(bundleID: entry.bundleID, size: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.finalText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
                    .font(.system(size: 13)).lineLimit(2)
                Text([entry.appName, entry.createdAt.relativeShort].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            CopyButton(text: entry.finalText).buttonStyle(.borderless).opacity(hover ? 1 : 0)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// Words-per-day columns. Single series: one hue, no legend, thin columns with rounded tops on a
/// square baseline, hairline gridlines, compact ticks, neutral text and a hover tooltip.
struct ActivityChart: View {
    let days: [(day: Date, words: Int)]
    @State private var hover: Int?
    private let axisWidth: CGFloat = 34
    private let plotHeight: CGFloat = 112

    var body: some View {
        let top = Self.niceCeiling(days.map(\.words).max() ?? 0)
        VStack(spacing: 6) {
            GeometryReader { geo in
                // Layout passes can be narrower than the axis.
                let plotWidth = max(0, geo.size.width - axisWidth)
                let slot = plotWidth / CGFloat(max(days.count, 1))
                let barWidth = max(0, min(24, slot * 0.56))
                ZStack(alignment: .topLeading) {
                    ForEach([0.0, 0.5, 1.0], id: \.self) { f in
                        let y = plotHeight * (1 - f)
                        Path { p in
                            p.move(to: CGPoint(x: axisWidth, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(Color.primary.opacity(f == 0 ? 0.16 : 0.07), lineWidth: 0.5)
                        Text(Self.compact(Int(Double(top) * f)))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .frame(width: axisWidth - 8, alignment: .trailing)
                            .position(x: (axisWidth - 8) / 2, y: y)
                    }
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        let h = top > 0 ? max(d.words > 0 ? 3 : 0, plotHeight * CGFloat(d.words) / CGFloat(top)) : 0
                        UnevenRoundedRectangle(topLeadingRadius: min(4, barWidth / 2), topTrailingRadius: min(4, barWidth / 2), style: .continuous)
                            .fill(Color.accentColor.opacity(hover == nil || hover == i ? 1 : 0.35))
                            .frame(width: barWidth, height: h)
                            .position(x: axisWidth + slot * (CGFloat(i) + 0.5), y: plotHeight - h / 2)
                    }
                    if let i = hover, days.indices.contains(i) {
                        tooltip(days[i])
                            .fixedSize()
                            .position(x: min(max(axisWidth + slot * (CGFloat(i) + 0.5), axisWidth + 60), geo.size.width - 60), y: 10)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        // Checked before `Int(_:)`, which traps on NaN, infinity (zero-width slot) and huge values.
                        let x = slot > 0 ? (p.x - axisWidth) / slot : -1
                        hover = x >= 0 && x < CGFloat(days.count) ? Int(x) : nil
                    case .ended:
                        hover = nil
                    }
                }
                .animation(.easeOut(duration: 0.12), value: hover)
            }
            .frame(height: plotHeight)

            HStack(spacing: 0) {
                Color.clear.frame(width: axisWidth, height: 12)
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    Text(d.day.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 10, weight: Calendar.current.isDateInToday(d.day) ? .semibold : .regular))
                        .foregroundStyle(Calendar.current.isDateInToday(d.day) ? .secondary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words dictated per day, last 14 days")
        .accessibilityValue(days.map { "\($0.day.formatted(.dateTime.weekday().day())): \($0.words)" }.joined(separator: ", "))
    }

    private func tooltip(_ d: (day: Date, words: Int)) -> some View {
        HStack(spacing: 6) {
            Text(d.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .foregroundStyle(.secondary)
            Text("\(d.words.formatted()) words").fontWeight(.semibold)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(CardSurface(radius: 6).shadow(color: .black.opacity(0.12), radius: 6, y: 2))
    }

    static func niceCeiling(_ v: Int) -> Int {
        guard v > 0 else { return 100 }
        let magnitude = pow(10, floor(log10(Double(v))))
        for step in [1.0, 2.0, 2.5, 5.0, 10.0] where step * magnitude >= Double(v) { return Int(step * magnitude) }
        return Int(10 * magnitude)
    }

    static func compact(_ v: Int) -> String {
        v >= 1000 ? (v % 1000 == 0 ? "\(v / 1000)K" : String(format: "%.1fK", Double(v) / 1000)) : "\(v)"
    }
}
