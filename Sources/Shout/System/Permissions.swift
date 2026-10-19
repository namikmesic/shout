import AppKit
import AVFoundation
import ApplicationServices
import ShoutKit

/// TCC permission checks and deep links into System Settings.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    /// "System Audio Recording" (Scribe); `.unknown` when macOS doesn't let us read it.
    @Published private(set) var systemAudio: SystemAudioPermission.Status = .unknown
    /// Screen Recording, for Prompt mode's ⌥ screenshots. Read without asking (`CGPreflightScreenCaptureAccess`).
    @Published private(set) var screenRecording = false
    /// Asked from Setup, Settings or the Prompts page this run: macOS applies a new grant once Shout restarts.
    @Published private(set) var screenRecordingRequested = false
    /// Reading the folder macOS saves screenshots to (Prompt mode's ⌘⇧4 screenshots).
    @Published private(set) var screenshotFolder: FolderAccess = .notAsked

    enum FolderAccess: Equatable {
        /// Not a folder macOS protects (e.g. ~/Pictures/Screenshots): read freely.
        case notNeeded
        case granted
        /// Protected and not asked yet: it isn't read, so macOS never asks mid-dictation.
        case notAsked
        case denied
    }

    private var timer: Timer?
    private var pollers = 0
    private var activationObserver: NSObjectProtocol?

    /// Microphone + Accessibility are required; Accessibility also covers the keyboard event tap.
    var allGranted: Bool { microphone == .authorized && accessibility }

    private init() {
        refresh()
        // Pick up changes made in System Settings as soon as the user comes back.
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Assigns only changed values: `@Published` notifies on every write, and this runs once a second
    /// while polling.
    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
        let listen = CGPreflightListenEventAccess()
        if listen != inputMonitoring { inputMonitoring = listen }
        let audio = SystemAudioPermission.status()
        if audio != systemAudio { systemAudio = audio }
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenRecording { screenRecording = screen }
        let folder = Self.screenshotFolderAccess()
        if folder != screenshotFolder { screenshotFolder = folder }
    }

    // MARK: Prompt mode screenshots

    /// Puts Shout in System Settings' Screen Recording list (macOS asks only the first time) and opens that pane,
    /// where the switch is. The grant applies once Shout restarts.
    func requestScreenRecording() {
        screenRecordingRequested = true
        _ = CGRequestScreenCaptureAccess()
        Self.openPrivacyPane("Privacy_ScreenCapture")
        refresh()
    }
    private static let folderAccessKey = "ShoutScreenshotFolderAccess"

    var canReadScreenshotFolder: Bool { screenshotFolder == .notNeeded || screenshotFolder == .granted }

    /// Folders macOS asks about before an app may read them.
    static func isProtected(_ folder: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.resolvingSymlinksInPath().path
        let guarded = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { home + "/" + $0 }
        return guarded.contains { path == $0 || path.hasPrefix($0 + "/") } || path.hasPrefix("/Volumes/")
    }

    static func screenshotFolderAccess() -> FolderAccess {
        let folder = ScreenshotWatcher.screenshotFolder()
        guard isProtected(folder) else { return .notNeeded }
        let saved = UserDefaults.standard.dictionary(forKey: folderAccessKey) as? [String: String] ?? [:]
        switch saved[folder.path] {
        case "granted": return .granted
        case "denied": return .denied
        default: return .notAsked
        }
    }

    /// Reads the screenshot folder once, so macOS asks now (from Setup, Settings or the Prompts page) rather than
    /// in the middle of a dictation. Once denied, opens Files & Folders in System Settings.
    func requestScreenshotFolder() async {
        let folder = ScreenshotWatcher.screenshotFolder()
        if screenshotFolder == .denied { Self.openPrivacyPane("Privacy_FilesAndFolders") }
        // The read waits while macOS shows its question.
        let ok = await Task.detached(priority: .userInitiated) {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
        }.value
        var saved = UserDefaults.standard.dictionary(forKey: Self.folderAccessKey) as? [String: String] ?? [:]
        saved[folder.path] = ok ? "granted" : "denied"
        UserDefaults.standard.set(saved, forKey: Self.folderAccessKey)
        refresh()
    }

    /// Restarts Shout (a new Screen Recording grant applies to new processes only).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Asks for System Audio Recording: the macOS prompt while undecided, System Settings once denied.
    /// Where the status can't be read, a short capture test triggers the prompt and checks the result.
    func requestSystemAudio() async {
        switch SystemAudioPermission.status() {
        case .authorized:
            break
        case .denied:
            Self.openSystemAudioSettings()
        case .notDetermined:
            _ = await SystemAudioPermission.request()
        case .unknown:
            if await SystemAudioCheck.run() { SettingsStore.shared.settings.scribeSystemAudio = .working }
            else { Self.openSystemAudioSettings() }
        }
        refresh()
    }

    /// True once System Audio Recording is allowed (read from TCC) or has been seen working.
    var systemAudioAllowed: Bool {
        systemAudio == .authorized || (systemAudio == .unknown && SettingsStore.shared.settings.scribeSystemAudio == .working)
    }

    /// Polls while onboarding/settings are visible so the UI updates when the user flips a switch.
    /// Counted: onboarding can overlay Settings, and the first to disappear must not stop the other.
    func startPolling() {
        pollers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        pollers = max(0, pollers - 1)
        guard pollers == 0 else { return }
        timer?.invalidate(); timer = nil
    }

    func requestMicrophone() async -> Bool {
        let ok = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        if !ok { open(.microphone) }
        return ok
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { open(.accessibility) }
        refresh()
    }

    func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { open(.inputMonitoring) }
        refresh()
    }

    enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    /// "Screen & System Audio Recording", which holds "System Audio Recording Only". macOS has no
    /// public API to query that permission, so the Scribe infers it from captured audio.
    static func openSystemAudioSettings() { openPrivacyPane("Privacy_ScreenCapture") }

    func open(_ pane: Pane) { Self.openPrivacyPane(pane.rawValue) }

    /// Privacy & Security panes moved to a new identifier in macOS 26 (Wispr Flow switches the same way).
    static func openPrivacyPane(_ anchor: String) {
        let host = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            ? "com.apple.settings.PrivacySecurity.extension" : "com.apple.preference.security"
        if let url = URL(string: "x-apple.systempreferences:\(host)?\(anchor)") { NSWorkspace.shared.open(url) }
    }

    // MARK: Globe key behaviour

    /// What macOS does when the Globe/Fn key is pressed (com.apple.HIToolbox AppleFnUsageType).
    /// 0 = do nothing, 1 = change input source, 2 = show emoji & symbols, 3 = start dictation.
    static var globeKeyUsage: Int {
        let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (v as? Int) ?? 2
    }

    static var globeKeyConflicts: Bool { globeKeyUsage != 0 }

    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sets "Press 🌐 key to" = "Do Nothing". Only called after the user explicitly asks for it.
    static func disableGlobeKeyAction() {
        CFPreferencesSetAppValue("AppleFnUsageType" as CFString, 0 as CFNumber, "com.apple.HIToolbox" as CFString)
        CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.HIToolbox.AppleFnUsageTypeChanged"), object: nil, userInfo: nil, deliverImmediately: true)
    }
}
