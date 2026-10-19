import AppKit
import CoreAudio
import Darwin
import ShoutKit

/// Which processes are using audio input right now, from Core Audio's process objects (macOS 14.2+):
/// `kAudioHardwarePropertyProcessObjectList`, then per process `IsRunningInput`, `PID` and `BundleID`.
/// No permission is needed. Shout's own process is excluded.
///
/// Changes are pushed by property listeners (process list, each process's `IsRunningInput`, default
/// input device, Core Audio restart) and re-checked by a timer, because an app can stop input without
/// any notification. Core Audio is only ever called on a private serial queue (a busy `coreaudiod` must
/// not stall the Flow Bar or dictation); results are delivered on the main thread. Before macOS 14.2 it
/// reports nothing.
@MainActor
final class MicActivityMonitor: ObservableObject {
    /// Processes with input running, sorted by pid. Published only when it changes.
    @Published private(set) var holders: [MicHolder] = []
    /// Called after every check (listener push or timer), changed or not.
    var onCheck: (([MicHolder]) -> Void)?
    var onDefaultInputChanged: (() -> Void)?
    var onServiceRestarted: (() -> Void)?

    /// Re-read cadence of the watched app's input (`watch(appPID:)`), as Wispr Flow asks of its helper
    /// while a recording follows a call.
    static let watchInterval: TimeInterval = 0.5

    private(set) var isRunning = false
    private var pollInterval: TimeInterval = 5
    private var timer: Timer?
    private var watchTimer: Timer?
    private var watchedApp: pid_t?
    private var checkPending = false
    private let core = CoreAudioReader()

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    init() {
        // Set once, before any listener exists: listener callbacks read it on their own queue.
        core.onEvent = { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        guard Self.isSupported else { return }
        core.queue.async { [core] in core.addSystemListeners() }
        restartTimer()
        updateWatchTimer()
        check()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        watchTimer?.invalidate()
        watchTimer = nil
        core.queue.async { [core] in core.removeAllListeners() }
        if !holders.isEmpty { holders = [] }
    }

    /// Timer re-check cadence: 3 s while recording, 5 s otherwise, 30 s while nothing needs detection.
    func setPollInterval(_ seconds: TimeInterval) {
        let s = max(0.5, seconds)
        guard s != pollInterval else { return }
        pollInterval = s
        if isRunning && Self.isSupported { restartTimer() }
    }

    /// While a recording follows a call: re-read that app's input every `watchInterval`, so its release
    /// is noticed even when Core Audio sends no notification. nil stops watching.
    func watch(appPID: pid_t?) {
        guard appPID != watchedApp else { return }
        watchedApp = appPID
        updateWatchTimer()
    }

    /// Re-reads now (for example right after a prompt was answered).
    func checkNow() {
        guard isRunning, Self.isSupported else { return }
        check()
    }

    // MARK: Internals

    private func handle(_ event: CoreAudioReader.Event) {
        guard isRunning else { return }
        switch event {
        case .processesChanged: break
        case .defaultInputChanged: onDefaultInputChanged?()
        case .serviceRestarted: onServiceRestarted?()
        }
        scheduleCheck()
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.check()
            }
        }
        t.tolerance = min(0.5, pollInterval * 0.1)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func updateWatchTimer() {
        watchTimer?.invalidate()
        watchTimer = nil
        guard isRunning, Self.isSupported, let app = watchedApp else { return }
        let t = Timer(timeInterval: Self.watchInterval, repeats: true) { [weak self, core] t in
            guard self != nil else { t.invalidate(); return } // the monitor is gone: let go of the reader
            core.queue.async {
                guard core.inputStopped(appPID: app) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.scheduleCheck() } }
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    /// Coalesces bursts of listener callbacks (a call app opening input touches several properties).
    private func scheduleCheck() {
        guard !checkPending else { return }
        checkPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkPending = false
                if self.isRunning { self.check() }
            }
        }
    }

    private func check() {
        core.queue.async { [weak self, core] in
            let found = core.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isRunning else { return }
                    if found != self.holders { self.holders = found }
                    self.onCheck?(found)
                }
            }
        }
    }

    // MARK: Owning app

    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// The app a process belongs to: itself if it is a regular app, else the nearest regular app up
    /// its parent chain (browser and Electron helpers). WebKit's GPU process and FaceTime's daemon are
    /// started by launchd, so they map to Safari / FaceTime when those are running.
    nonisolated static func resolve(pid: pid_t, bundleID: String) -> MicHolder {
        var current = pid
        for _ in 0..<6 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return MicHolder(pid: pid, bundleID: bundleID, appPID: current,
                                 appBundleID: app.bundleIdentifier ?? bundleID, appName: app.localizedName ?? bundleID)
            }
            guard let parent = parentPID(of: current), parent > 1 else { break }
            current = parent
        }
        let lower = bundleID.lowercased()
        let host: [String] = lower.hasPrefix("com.apple.webkit.") ? ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
            : lower == "com.apple.avconferenced" ? ["com.apple.FaceTime"] : []
        for id in host {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
                return MicHolder(pid: pid, bundleID: bundleID, appPID: app.processIdentifier, appBundleID: id,
                                 appName: app.localizedName ?? id)
            }
        }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? processName(pid) ?? bundleID
        return MicHolder(pid: pid, bundleID: bundleID, appName: name)
    }

    private nonisolated static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// True while the process exists (kill with signal 0 only checks).
    nonisolated static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }
}

/// The Core Audio side of `MicActivityMonitor`: property listeners and reads. Everything except the
/// listener callbacks runs on `queue`.
private final class CoreAudioReader: @unchecked Sendable {
    enum Event: Sendable { case processesChanged, defaultInputChanged, serviceRestarted }

    let queue = DispatchQueue(label: "shout.mic-activity.read", qos: .utility)
    /// Listener callbacks arrive here and only hand off, so removing a listener on `queue` never waits
    /// on work queued behind it.
    private let listenerQueue = DispatchQueue(label: "shout.mic-activity")
    /// Set once before the first listener is added.
    var onEvent: (@Sendable (Event) -> Void)?

    /// Between `addSystemListeners` and `removeAllListeners` (on `queue`).
    private var active = false
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// Process objects with input running at the last scan, with the app each belongs to.
    private var running: [AudioObjectID: pid_t] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func addSystemListeners() {
        active = true
        let selectors: [(AudioObjectPropertySelector, Event)] = [
            (kAudioHardwarePropertyProcessObjectList, .processesChanged),
            (kAudioHardwarePropertyDefaultInputDevice, .defaultInputChanged),
            (kAudioHardwarePropertyServiceRestarted, .serviceRestarted),
        ]
        for (selector, event) in selectors {
            var addr = Self.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.fired(event) }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, block) == noErr {
                systemListeners.append((selector, block))
            }
        }
    }

    func removeAllListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for (selector, block) in systemListeners {
            var addr = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(system, &addr, listenerQueue, block)
        }
        systemListeners = []
        for (id, block) in processListeners {
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(id, &addr, listenerQueue, block)
        }
        processListeners = [:]
        running = [:]
        active = false
    }

    /// On `listenerQueue`.
    private func fired(_ event: Event) {
        if event == .serviceRestarted {
            // After a restart every listener has to be registered again (AudioHardware.h); process objects
            // are new as well.
            queue.async { [self] in
                guard active else { return } // stopped meanwhile: nothing to re-register
                removeAllListeners()
                addSystemListeners()
            }
        }
        onEvent?(event)
    }

    /// The processes with input running now (and keeps one `IsRunningInput` listener per process object).
    func scan() -> [MicHolder] {
        let ids = Self.processObjects()
        syncProcessListeners(ids)
        var found: [MicHolder] = []
        var nowRunning: [AudioObjectID: pid_t] = [:]
        for id in ids where Self.uint32(id, kAudioProcessPropertyIsRunningInput) != 0 {
            guard let pid = Self.pid(id), pid > 0, pid != ownPID, MicActivityMonitor.parentPID(of: pid) != ownPID else { continue }
            let bundleID = Self.bundleID(id) ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            let holder = MicActivityMonitor.resolve(pid: pid, bundleID: bundleID)
            found.append(holder)
            nowRunning[id] = holder.appPID
        }
        running = nowRunning
        return found.sorted { $0.pid < $1.pid }
    }

    /// Whether input of `appPID` that was running at the last scan has stopped (one read per process object).
    func inputStopped(appPID: pid_t) -> Bool {
        running.contains { id, app in app == appPID && Self.uint32(id, kAudioProcessPropertyIsRunningInput) == 0 }
    }

    private func syncProcessListeners(_ ids: [AudioObjectID]) {
        let live = Set(ids)
        for (id, block) in processListeners where !live.contains(id) {
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(id, &addr, listenerQueue, block) // fails harmlessly if the object is gone
            processListeners[id] = nil
        }
        for id in ids where processListeners[id] == nil {
            var addr = Self.address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onEvent?(.processesChanged) }
            if AudioObjectAddPropertyListenerBlock(id, &addr, listenerQueue, block) == noErr { processListeners[id] = block }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func pid(_ id: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func bundleID(_ id: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let cf = value else { return nil }
        let s = cf.takeRetainedValue() as String
        return s.isEmpty ? nil : s
    }
}
