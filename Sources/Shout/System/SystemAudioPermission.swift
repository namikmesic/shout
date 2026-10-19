import Foundation
import AppKit
import os

/// The "System Audio Recording" permission (TCC service `kTCCServiceAudioCapture`, macOS 14.4+).
/// macOS has no public API to read it, so, like Wispr Flow's helper, this calls the TCC framework's
/// `TCCAccessPreflight` / `TCCAccessRequest` when they exist. If they don't, the status is `.unknown`
/// and the Scribe falls back to judging the permission from captured audio.
enum SystemAudioPermission {
    enum Status: Equatable { case authorized, denied, notDetermined, unknown }

    private static let service = "kTCCServiceAudioCapture" as CFString
    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let tcc: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private static let preflight: PreflightFn? = tcc.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: PreflightFn.self) }
    private static let requestAccess: RequestFn? = tcc.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: RequestFn.self) }

    static var isSupported: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    static func status() -> Status {
        guard isSupported, let preflight else { return .unknown }
        let s: Status
        switch preflight(service, nil) {
        case 0: s = .authorized
        case 1: s = .denied
        default: s = .notDetermined
        }
        cache.withLock { $0 = (s, Date()) }
        return s
    }

    /// `status()`, reusing a value read within `maxAge` seconds: each read is an XPC round trip to
    /// tccd, too slow for a 1 Hz watchdog on the main thread.
    static func status(maxAge: TimeInterval) -> Status {
        if let (s, at) = cache.withLock({ $0 }), Date().timeIntervalSince(at) < maxAge { return s }
        return status()
    }

    private static let cache = OSAllocatedUnfairLock<(Status, Date)?>(initialState: nil)

    /// Shows the macOS prompt (only while the permission is undecided). Returns whether it was granted,
    /// or nil when the request API is unavailable or macOS has not answered within `timeout` (read
    /// `status()` again then). Concurrent calls share one prompt.
    static func request(timeout: TimeInterval = 20) async -> Bool? {
        guard isSupported, let requestAccess else { return nil }
        let id = UUID()
        return await withCheckedContinuation { cont in
            let first = pending.withLock { p -> Bool in
                p.waiters[id] = cont
                defer { p.inFlight = true }
                return !p.inFlight
            }
            if first {
                requestAccess(service, nil) { granted in
                    cache.withLock { $0 = nil } // the answer just changed the status
                    let waiters = pending.withLock { p -> [CheckedContinuation<Bool?, Never>] in
                        defer { p.waiters = [:]; p.inFlight = false }
                        return Array(p.waiters.values)
                    }
                    waiters.forEach { $0.resume(returning: granted) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                // The in-flight latch lasts as long as someone waits (Wispr's helper: < 20 s): a request
                // macOS never answers must not stop every later one from prompting.
                pending.withLock { p -> CheckedContinuation<Bool?, Never>? in
                    let c = p.waiters.removeValue(forKey: id)
                    if p.waiters.isEmpty { p.inFlight = false }
                    return c
                }?.resume(returning: nil)
            }
        }
    }

    private struct Pending {
        var inFlight = false
        var waiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]
    }
    private static let pending = OSAllocatedUnfairLock(initialState: Pending())
}

/// "Test system audio": records the Mac's output for a moment while a short sound plays in another
/// process (the tap ignores Shout's own sounds) and reports whether Shout heard it.
@MainActor
enum SystemAudioCheck {
    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Float = 0
        func add(_ samples: [Float]) {
            let m = samples.reduce(Float(0)) { max($0, abs($1)) }
            lock.withLock { value = max(value, m) }
        }
        var peak: Float { lock.withLock { value } }
    }

    static func run() async -> Bool {
        guard #available(macOS 14.4, *) else { return false }
        let capture = SystemAudioCapture()
        let peak = Peak()
        capture.onSamples = { samples, _ in peak.add(samples) }
        do { try await capture.start() } catch { return false }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.25", "/System/Library/Sounds/Tink.aiff"]
        try? player.run()
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        capture.stop()
        return peak.peak > 0.0005
    }
}
