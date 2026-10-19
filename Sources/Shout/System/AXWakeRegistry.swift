import AppKit
import ApplicationServices
import ShoutKit

/// Wakes the Accessibility tree of the Chromium and Electron apps the speaker poller reads, and puts them back.
///
/// One registry for the whole process, so the pollers of successive legs (or a target change on the same pid)
/// share one wake state per app: a poller registers its pid synchronously when it starts and unregisters when it
/// stops, and an app is put back only once no poller uses it. Wakes and restores run one at a time on one queue.
/// Only what Shout itself turned on is turned off again:
/// - `AXManualAccessibility`, unless it was already on, or call detection relies on it (`keepAwake`);
/// - `AXEnhancedUserInterface` (the fallback), unless VoiceOver is running, since VoiceOver needs it.
/// What is on is also recorded in user defaults (`AXWakeLedger`): a quit restores synchronously
/// (`restoreAll`), and a crash is undone at the next launch (`recoverAfterCrash`). What an app didn't answer to
/// putting back stays in the ledger, for its next wake or the next launch.
final class AXWakeRegistry: @unchecked Sendable {
    static let shared = AXWakeRegistry()
    static let timeout: Float = 0.25
    /// A wake that didn't take is asked again no sooner than this: each try can wait about a second on an app
    /// that doesn't answer, holding this queue (and a quit's `restoreAll`).
    static let retryInterval: TimeInterval = 10

    private let queue = DispatchQueue(label: "shout.ax-wake", qos: .utility)
    private let lock = NSLock()
    // Under `lock`:
    private var users: [pid_t: Int] = [:]
    private var kept: Set<pid_t> = []
    // On `queue` only:
    private var attempted: Set<pid_t> = []
    private var nextRetry: [pid_t: Date] = [:]
    private var changed: [pid_t: AXWakeLedger.Entry] = [:]
    /// What an earlier run left on (it crashed), or a restore the app didn't answer, until it is undone or taken
    /// over by a wake of the same app; kept in the ledger meanwhile.
    private var leftover = AXWakeLedger(data: UserDefaults.standard.data(forKey: AXWakeLedger.defaultsKey)).entries

    /// A poller starts reading `pid` (call before its first tick).
    func register(_ pid: pid_t) {
        lock.lock(); users[pid, default: 0] += 1; lock.unlock()
    }

    /// A poller stopped reading `pid`; the app is put back once no poller uses it.
    func unregister(_ pid: pid_t) {
        lock.lock()
        let left = max(0, (users[pid] ?? 0) - 1)
        users[pid] = left == 0 ? nil : left
        lock.unlock()
        guard left == 0 else { return }
        queue.async { [self] in if !isInUse(pid) { restore(pid) } }
    }

    /// Another part of Shout (call detection) relies on `AXManualAccessibility` for this app: never turned off.
    func keepAwake(_ pid: pid_t) {
        lock.lock(); kept.insert(pid); lock.unlock()
    }

    /// Asks the app to build its tree, once until it is put back. Called on a poller's queue; waits for any wake or
    /// restore of another poller first.
    func wake(pid: pid_t, bundleID: String) {
        queue.sync {
            if let t = nextRetry[pid], Date() < t { return }
            guard attempted.insert(pid).inserted else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, Self.timeout)
            var entry = AXWakeLedger.Entry(pid: pid, bundleID: bundleID,
                                           launchTime: NSRunningApplication(processIdentifier: pid)?.launchDate?.timeIntervalSince1970)
            let manualBefore = Self.bool(app, "AXManualAccessibility")
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
                entry.manualAccessibility = manualBefore != true
            } else if Self.bool(app, "AXEnhancedUserInterface") == true {
                // Already on (VoiceOver): the tree is built.
            } else if AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) == .success {
                entry.enhancedUserInterface = true
            } else {
                // Neither took (an app busy building its window): a discovery after `retryInterval` asks again.
                attempted.remove(pid)
                nextRetry[pid] = Date().addingTimeInterval(Self.retryInterval)
                return
            }
            nextRetry[pid] = nil
            // Still on from a run that crashed, or from a restore the app didn't answer: put back with this run's changes.
            if let i = leftover.firstIndex(where: { $0.pid == pid }),
               AXWakeLedger.applies(leftover[i], runningBundleID: bundleID, runningLaunchTime: entry.launchTime) {
                entry.manualAccessibility = entry.manualAccessibility || leftover[i].manualAccessibility
                entry.enhancedUserInterface = entry.enhancedUserInterface || leftover[i].enhancedUserInterface
                leftover.remove(at: i)
            }
            guard entry.changedAnything else { return }
            changed[pid] = entry
            saveLedger()
        }
    }

    /// Quit: puts back every app now, before the process exits (whatever pollers are still winding down).
    func restoreAll() {
        queue.sync {
            for pid in Array(changed.keys) { restore(pid, save: false) }
            saveLedger()
        }
    }

    /// Launch: undoes what a crashed run left on, for apps still running from then. An app that doesn't answer
    /// keeps its entry for the next launch; one that quit took its settings with it.
    func recoverAfterCrash() {
        queue.async { [self] in
            leftover = leftover.compactMap { e in
                guard changed[e.pid] == nil else { return nil }
                let app = NSRunningApplication(processIdentifier: e.pid)
                guard AXWakeLedger.applies(e, runningBundleID: app?.bundleIdentifier,
                                           runningLaunchTime: app?.launchDate?.timeIntervalSince1970) else { return nil }
                return undo(e)
            }
            saveLedger()
        }
    }

    // MARK: On `queue`

    private func isInUse(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return users[pid] != nil
    }

    private func restore(_ pid: pid_t, save: Bool = true) {
        attempted.remove(pid)
        guard let e = changed.removeValue(forKey: pid) else { return }
        if let left = undo(e) {
            leftover.removeAll { $0.pid == pid }
            leftover.append(left)
        }
        if save { saveLedger() }
    }

    /// Puts back what `e` turned on. Returns what may still be on because the app didn't answer (or Shout lost
    /// Accessibility); nil when nothing is.
    private func undo(_ e: AXWakeLedger.Entry) -> AXWakeLedger.Entry? {
        let app = AXUIElementCreateApplication(e.pid)
        AXUIElementSetMessagingTimeout(app, Self.timeout)
        lock.lock(); let keep = kept.contains(e.pid); lock.unlock()
        var left = e
        left.manualAccessibility = e.manualAccessibility && !keep && !Self.turnOff(app, "AXManualAccessibility")
        left.enhancedUserInterface = e.enhancedUserInterface && !NSWorkspace.shared.isVoiceOverEnabled
            && !Self.turnOff(app, "AXEnhancedUserInterface")
        return left.changedAnything ? left : nil
    }

    /// Sets `attribute` to false. False only when it may still be on: a timeout, or no Accessibility (an app that
    /// quit, or never had the attribute, has nothing left to put back).
    private static func turnOff(_ app: AXUIElement, _ attribute: String) -> Bool {
        switch AXUIElementSetAttributeValue(app, attribute as CFString, kCFBooleanFalse) {
        case .cannotComplete, .apiDisabled: false
        default: true
        }
    }

    private func saveLedger() {
        let ledger = AXWakeLedger(entries: changed.values.sorted { $0.pid < $1.pid } + leftover.filter { changed[$0.pid] == nil })
        if let data = ledger.data { UserDefaults.standard.set(data, forKey: AXWakeLedger.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: AXWakeLedger.defaultsKey) }
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? Bool
    }
}
