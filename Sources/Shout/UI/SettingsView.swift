import SwiftUI
import ShoutKit

/// Settings, built from the same page and card components as every other page (a grouped `Form`
/// paints its own background and centres its rows, which broke alignment with the page title).
struct SettingsView: View {
    let controller: DictationController
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: AppRouter
    @State private var devices: [AudioRecorder.InputDevice] = []
    @State private var confirmDelete = false
    @State private var globeConflict = Permissions.globeKeyConflicts

    var body: some View {
        Page(title: "Settings", subtitle: router.settingsTab == .general ? "Shortcuts, dictation behaviour, sounds and privacy."
                                                                         : "Meeting detection, the Notepad, transcripts and summaries.") {
            Picker("", selection: $router.settingsTab) {
                ForEach(AppRouter.SettingsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        } content: {
            if router.settingsTab == .scribe {
                ScribeSettingsView(controller: controller)
            } else {
                general
            }
        }
        .onAppear {
            devices = AudioRecorder.inputDevices()
            permissions.refresh()
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
        // The 🌐 key's action is changed in System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            globeConflict = Permissions.globeKeyConflicts
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmDelete) {
            Button("Delete All", role: .destructive) { store.deleteAllHistory() }
        } message: { Text("This removes every saved transcript and recording from this Mac.") }
    }

    @ViewBuilder private var general: some View {
            SettingsCard(title: "Shortcuts", caption: "Work in every app") {
                ShortcutRow(title: "Push to talk", subtitle: "Hold to dictate", slot: .pushToTalk,
                            combo: $settings.settings.pushToTalk, controller: controller)
                    .settingRowPadding()
                RowDivider()
                ShortcutRow(title: "Hands-free", subtitle: "Press to start and again to finish", slot: .handsFree,
                            combo: $settings.settings.handsFree, controller: controller)
                    .settingRowPadding()
                RowDivider()
                SettingRow(title: "Double-tap push to talk for hands-free") { SwitchControl(isOn: $settings.settings.doubleTapLocksHandsFree) }
                RowDivider()
                ShortcutRow(title: "Command Mode", subtitle: "Edit selected text or ask for something by voice", slot: .command,
                            combo: $settings.settings.command, controller: controller)
                    .settingRowPadding()
                RowDivider()
                ShortcutRow(title: "Prompt mode", subtitle: "Turn what you say into a structured prompt for an AI assistant", slot: .prompt,
                            combo: $settings.settings.promptShortcut, controller: controller)
                    .settingRowPadding()
                RowDivider()
                ShortcutRow(title: "Paste last transcript", subtitle: nil, slot: .pasteLast,
                            combo: $settings.settings.pasteLast, controller: controller)
                    .settingRowPadding()
                RowDivider()
                ShortcutRow(title: "Copy last transcript", subtitle: nil, slot: .copyLast,
                            combo: $settings.settings.copyLast, controller: controller)
                    .settingRowPadding()
                if globeConflict && settings.settings.pushToTalk.keys.contains(KeyCombo.Key.fn) {
                    RowDivider()
                    GlobeKeyWarning { globeConflict = Permissions.globeKeyConflicts }
                        .settingRowPadding()
                }
            }

            SettingsCard(title: "Dictation", caption: "How Shout listens and edits") {
                LanguagePicker(languages: $settings.settings.languages).settingRowPadding()
                RowDivider()
                SettingRow(title: "Microphone") {
                    Picker("", selection: Binding(get: { settings.settings.microphoneUID ?? "" },
                                                  set: { settings.settings.microphoneUID = $0.isEmpty ? nil : $0 })) {
                        Text("System default\(AudioRecorder.defaultInputName().map { " (\($0))" } ?? "")").tag("")
                        ForEach(devices) { d in
                            Text(d.name + (d.isBluetooth ? " · Bluetooth (lower quality)" : "")).tag(d.uid)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                SettingRow(title: "Use context from the active app", detail: "Reads the text around your cursor to match names, casing and spacing.") {
                    SwitchControl(isOn: $settings.settings.useContext)
                }
                RowDivider()
                SettingRow(title: "Learn words from my corrections", detail: "When you fix a dictated word, Shout adds it to your dictionary.") {
                    SwitchControl(isOn: $settings.settings.autoLearnWords)
                }
                RowDivider()
                SettingRow(title: "Command Mode", detail: "Select text, hold the Command Mode shortcut and say “make this more formal”.") {
                    SwitchControl(isOn: $settings.settings.commandModeEnabled)
                }
                RowDivider()
                SettingRow(title: "“Press enter” voice command", detail: "End a dictation with “press enter” to send it.") {
                    SwitchControl(isOn: $settings.settings.pressEnterCommand)
                }
                RowDivider()
                SettingRow(title: "Your name", detail: "Used for sign-offs in Command Mode") {
                    TextField("", text: $settings.settings.userName, prompt: Text("Name"))
                        .textFieldStyle(.roundedBorder).frame(width: 200).labelsHidden()
                }
            }

            SettingsCard(title: "Sound & feedback", caption: nil) {
                SettingRow(title: "Play sounds") { SwitchControl(isOn: $settings.settings.soundsEnabled.animation(.easeOut(duration: 0.15))) }
                if settings.settings.soundsEnabled {
                    RowDivider()
                    SettingRow(title: "Volume") {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                            Slider(value: $settings.settings.soundVolume, in: 0.05...1).frame(width: 180).controlSize(.small)
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                RowDivider()
                SettingRow(title: "While dictating", detail: "What happens to music and videos while you speak") {
                    Picker("", selection: $settings.settings.mediaBehavior) {
                        ForEach(MediaBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                SettingRow(title: "Show Flow Bar when idle", detail: "The small pill at the bottom of the screen") {
                    SwitchControl(isOn: $settings.settings.showFlowBarWhenIdle)
                }
            }

            SettingsCard(title: "System", caption: nil) {
                SettingRow(title: "Appearance", detail: "System follows your Mac's light or dark setting") {
                    Picker("Appearance", selection: $settings.settings.appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                RowDivider()
                SettingRow(title: "Launch at login") { SwitchControl(isOn: $settings.settings.launchAtLogin) }
                RowDivider()
                SettingRow(title: "Show in Dock") { SwitchControl(isOn: $settings.settings.showInDock) }
                RowDivider()
                SettingRow(title: "Restore clipboard after pasting", detail: "Shout pastes through the clipboard and puts your previous clipboard back.") {
                    SwitchControl(isOn: $settings.settings.restoreClipboard)
                }
            }

            SettingsCard(title: "Permissions", caption: "Granted in System Settings › Privacy & Security") {
                PermissionRow(title: "Microphone", detail: "To hear you while you hold the shortcut", granted: permissions.microphone == .authorized) {
                    Task { _ = await permissions.requestMicrophone() }
                }
                .settingRowPadding()
                RowDivider()
                PermissionRow(title: "Accessibility", detail: "For shortcuts, reading context and pasting", granted: permissions.accessibility) {
                    permissions.requestAccessibility()
                }
                .settingRowPadding()
                RowDivider()
                PermissionRow(title: "Input Monitoring", detail: "Optional; only if shortcuts don't respond", granted: permissions.inputMonitoring) {
                    permissions.requestInputMonitoring()
                }
                .settingRowPadding()
                if ScribeController.systemAudioSupported {
                    RowDivider()
                    SystemAudioPermissionRow()
                        .settingRowPadding()
                }
                RowDivider()
                CalendarPermissionRow().settingRowPadding()
                RowDivider()
                ScreenshotPermissionRows()
            }

            SettingsCard(title: "Privacy", caption: "Speech recognition and AI editing run on this Mac. Shout only uses the network to download models you choose.") {
                SettingRow(title: "History") {
                    Picker("", selection: $settings.settings.retention) {
                        ForEach(RetentionPolicy.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                SettingRow(title: "Keep audio recordings", detail: "Saves a copy of each recording next to its transcript") {
                    SwitchControl(isOn: $settings.settings.saveAudio)
                }
                RowDivider()
                SettingRow(title: "Delete all history", detail: "Removes every saved transcript and recording") {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
            }

            SettingsCard(title: "About", caption: nil) {
                SettingRow(title: "Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                RowDivider()
                SettingRow(title: "Setup assistant", detail: "Walk through permissions, models and shortcuts again") {
                    Button("Show…") { router.showOnboarding = true }
                }
            }
    }
}

// MARK: - Settings building blocks

/// A card with the same header treatment as the Models page.
struct SettingsCard<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var content: Content
    var body: some View {
        Card(padding: 0, spacing: 0) {
            CardHeader(title: title, caption: caption).padding(16)
            Divider()
            content
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing.environment(\.settingRowTitle, title)
        }
        .settingRowPadding()
    }
}

private struct SettingRowTitleKey: EnvironmentKey { static let defaultValue: String? = nil }

extension EnvironmentValues {
    /// The title of the `SettingRow` a control is in: what VoiceOver calls a switch whose label is the row's text.
    var settingRowTitle: String? {
        get { self[SettingRowTitleKey.self] }
        set { self[SettingRowTitleKey.self] = newValue }
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 16) }
}

struct SwitchControl: View {
    @Binding var isOn: Bool
    /// What VoiceOver calls the switch. Inside a `SettingRow` it's the row's title unless given.
    var label: String? = nil
    @Environment(\.settingRowTitle) private var rowTitle
    var body: some View {
        // The label is hidden on screen (the row shows it) but still names the switch for VoiceOver.
        Toggle(label ?? rowTitle ?? "", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

extension View {
    func settingRowPadding() -> some View {
        padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 44)
    }
}

struct PermissionRow: View {
    let title: String
    var detail: String? = nil
    let granted: Bool
    let request: () -> Void
    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer()
            if granted { Text("Granted").font(.system(size: 13)).foregroundStyle(.secondary) }
            else { Button("Grant…", action: request) }
        }
    }
}

/// System Audio Recording, read from TCC where possible, with a test that plays a short sound and checks
/// that Shout hears it.
struct SystemAudioPermissionRow: View {
    @EnvironmentObject var permissions: Permissions
    @EnvironmentObject var settings: SettingsStore
    @State private var testing = false
    @State private var result: Bool?

    var body: some View {
        HStack {
            Image(systemName: permissions.systemAudioAllowed ? "checkmark.circle.fill" : (permissions.systemAudio == .denied ? "exclamationmark.circle.fill" : "circle.dashed"))
                .foregroundStyle(permissions.systemAudioAllowed ? .green : (permissions.systemAudio == .denied ? .orange : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text("System Audio Recording").font(.system(size: 13))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(result == false ? .orange : .secondary)
            }
            Spacer()
            if permissions.systemAudioAllowed {
                if testing { ProgressView().controlSize(.small) }
                Button("Test") { test() }.disabled(testing).help("Plays a short sound and checks that Shout hears it")
            } else if permissions.systemAudio == .denied {
                Button("Open Settings…") { Permissions.openSystemAudioSettings() }
            } else {
                Button("Turn On…") { Task { await permissions.requestSystemAudio() } }
            }
        }
    }

    private var detail: String {
        if let result { return result ? "Working: Shout heard the test sound" : "Shout heard nothing. Check System Audio Recording Only in System Settings." }
        return permissions.systemAudio == .denied ? "Turned off in System Settings" : "For Scribe, to hear the other people on a call"
    }

    private func test() {
        testing = true
        Task {
            let ok = await SystemAudioCheck.run()
            if ok { settings.settings.scribeSystemAudio = .working }
            result = ok
            testing = false
        }
    }
}

/// Calendar access (EventKit): optional, for meeting reminders, titles and attendee names.
struct CalendarPermissionRow: View {
    @EnvironmentObject var calendar: CalendarService
    var body: some View {
        HStack {
            Image(systemName: calendar.access == .granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(calendar.access == .granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calendars").font(.system(size: 13))
                Text("Optional; meeting reminders, titles and attendee names for Scribe")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if calendar.access == .granted { Text("Granted").font(.system(size: 13)).foregroundStyle(.secondary) }
            else { ConnectCalendarButton(title: calendar.access == .denied ? "Open Settings…" : "Connect…") }
        }
    }
}

struct GlobeKeyWarning: View {
    var onChange: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "globe").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("The 🌐 key also opens \(globeAction)").fontWeight(.medium)
                Text("Set “Press 🌐 key to” to “Do Nothing” so holding fn only dictates.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Set to Do Nothing") { Permissions.disableGlobeKeyAction(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: onChange) }
                    Button("Open Keyboard Settings") { Permissions.openKeyboardSettings() }
                }
            }
        }
        .padding(.vertical, 4)
    }
    private var globeAction: String {
        switch Permissions.globeKeyUsage {
        case 1: "the input source switcher"
        case 3: "Apple Dictation"
        default: "the Emoji & Symbols picker"
        }
    }
}

/// Records a new shortcut by capturing the keys held together. Keys that clash with another Shout shortcut are
/// refused, except the ⌥M Scribe default, which gives way.
struct ShortcutRow: View {
    let title: String
    let subtitle: String?
    /// Which shortcut this is, to check the new keys against the others.
    let slot: ShortcutSlot
    @Binding var combo: KeyCombo
    let controller: DictationController
    @State private var recording = false
    @State private var live: Set<UInt16> = []
    @State private var error: String?
    /// After the new keys took the place of the Scribe's ⌥M.
    @State private var note: String?
    @State private var hover = false
    @State private var host = HostWindow()

    /// While a row records, the hotkey tap swallows every key in every app, and keys pressed elsewhere would become
    /// the shortcut. Recording stops when its window closes or loses focus, or Shout goes to the background.
    private static let leaveEvents = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
        .merge(with: NotificationCenter.default.publisher(for: NSWindow.willCloseNotification),
               NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary) }
                if let error { Text(error).font(.system(size: 11.5)).foregroundStyle(.red) }
                if let note { Text(note).font(.system(size: 11.5)).foregroundStyle(.orange) }
            }
            Spacer()
            // The clear button sits before the keys so the keys stay flush with other trailing controls.
            if !combo.isEmpty && !recording {
                Button { combo = KeyCombo([]) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Clear shortcut")
                    .opacity(hover ? 1 : 0)
            }
            Button { recording ? stop() : start() } label: { recorderLabel }
                .buttonStyle(.plain)
                .help(recording ? "Press the keys you want to use, or Esc to cancel" : "Click to change")
        }
        .onHover { hover = $0 }
        .readingHostWindow(host)
        // Settings tab or page switched, onboarding dismissed.
        .onDisappear { if recording { stop() } }
        .onReceive(Self.leaveEvents) { n in
            guard recording else { return }
            if let window = n.object as? NSWindow, window !== host.window { return }
            stop()
        }
    }

    @ViewBuilder private var recorderLabel: some View {
        Group {
            if recording {
                Text(live.isEmpty ? "Press keys…" : KeyCombo(live).displayString)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
            } else if combo.isEmpty {
                Text("Record Shortcut")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            } else {
                // Hover highlight grows outward so the keys stay exactly on the trailing edge.
                ComboCaps(combo: combo)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hover ? 0.06 : 0)).padding(-3))
            }
        }
        .animation(.easeOut(duration: 0.12), value: recording)
    }

    private func start() {
        // One row records at a time: another one still waiting for keys gives up, as on Esc.
        controller.hotkeys.onCapture?([], true)
        error = nil
        note = nil
        recording = true
        live = []
        controller.hotkeys.onCapture = { keys, done in
            live = keys
            if done { finish(keys) }
        }
        controller.hotkeys.beginCapture()
    }

    private func stop() {
        controller.hotkeys.endCapture()
        // Keys already on their way to the main queue land nowhere.
        controller.hotkeys.onCapture = nil
        recording = false
    }

    private func finish(_ keys: Set<UInt16>) {
        recording = false
        controller.hotkeys.onCapture = nil
        guard !keys.isEmpty else { return }
        let c = KeyCombo(keys)
        let hasModifier = !keys.isDisjoint(with: KeyCombo.modifierKeys) || keys.contains { $0 >= KeyCombo.mouseBase }
        let isFunctionKey: Bool = keys.count == 1 && [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80].contains(keys.first!)
        if keys.count > 3 { error = "Use at most 3 keys."; return }
        if !hasModifier && !isFunctionKey { error = "Include fn, ⌃, ⌥, ⌘, ⇧ or a mouse button."; return }
        let store = controller.settingsStore
        if let other = store.settings.shortcutConflict(c, for: slot) {
            let theirs = store.settings[shortcut: other]
            error = theirs == c ? "Already used for \(other.title)." : "Clashes with \(other.title) (\(theirs.displayString))."
            return
        }
        let hadDefault = slot != .scribe && store.settings.scribeShortcut == KeyCombo.defaultScribe
        combo = c
        // The store drops ⌥M as soon as something clashes with it.
        if hadDefault && store.settings.scribeShortcut.isEmpty {
            note = "\(KeyCombo.defaultScribe.displayString) no longer starts the Scribe. Choose another shortcut in Settings › Scribe."
        }
    }
}

struct LanguagePicker: View {
    @Binding var languages: [String]
    @State private var showing = false
    static let all: [(String, String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"),
        ("nl", "Dutch"), ("pl", "Polish"), ("sv", "Swedish"), ("da", "Danish"), ("fi", "Finnish"), ("no", "Norwegian"),
        ("cs", "Czech"), ("sk", "Slovak"), ("sl", "Slovenian"), ("hr", "Croatian"), ("bs", "Bosnian"), ("sr", "Serbian"),
        ("hu", "Hungarian"), ("ro", "Romanian"), ("bg", "Bulgarian"), ("el", "Greek"), ("et", "Estonian"), ("lv", "Latvian"),
        ("lt", "Lithuanian"), ("uk", "Ukrainian"), ("ru", "Russian"), ("tr", "Turkish"), ("ar", "Arabic"), ("he", "Hebrew"),
        ("fa", "Persian"), ("hi", "Hindi"), ("ur", "Urdu"), ("bn", "Bengali"), ("ta", "Tamil"), ("te", "Telugu"),
        ("mr", "Marathi"), ("gu", "Gujarati"), ("kn", "Kannada"), ("ml", "Malayalam"), ("th", "Thai"), ("vi", "Vietnamese"),
        ("id", "Indonesian"), ("ms", "Malay"), ("tl", "Tagalog"), ("zh", "Chinese"), ("ja", "Japanese"), ("ko", "Korean"),
        ("sw", "Swahili"), ("af", "Afrikaans"), ("ca", "Catalan"), ("cy", "Welsh"), ("is", "Icelandic"), ("ga", "Irish"),
    ]

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Languages").font(.system(size: 13))
                Text(languages.count == 1 ? "Always transcribe as \(name(languages[0]))" : "Detect automatically\(languages.isEmpty ? "" : " among your languages")")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(summary) { showing.toggle() }
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select the languages you speak").font(.headline)
                        Text("Pick one to force it, or several (or none) for automatic detection.").font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                                ForEach(Self.all, id: \.0) { code, label in
                                    Toggle(label, isOn: Binding(get: { languages.contains(code) }, set: { on in
                                        if on { languages.append(code) } else { languages.removeAll { $0 == code } }
                                    }))
                                }
                            }
                        }
                        .frame(height: 300)
                    }
                    .padding(16)
                    .frame(width: 360)
                }
        }
    }

    private var summary: String {
        if languages.isEmpty { return "Auto-detect" }
        return languages.map(name).joined(separator: ", ")
    }

    private func name(_ code: String) -> String { Self.all.first { $0.0 == code }?.1 ?? code }
}
