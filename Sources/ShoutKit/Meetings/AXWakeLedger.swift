import Foundation

/// What the speaker poller turned on in other apps to read them (`AXManualAccessibility`, `AXEnhancedUserInterface`)
/// and hasn't turned off yet. Kept in user defaults, so a crash is undone at the next launch.
public struct AXWakeLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var pid: Int32
        public var bundleID: String
        /// The app's launch time (seconds since 1970), to tell it from a later process with the same pid.
        public var launchTime: Double?
        public var enhancedUserInterface: Bool
        public var manualAccessibility: Bool

        public init(pid: Int32, bundleID: String, launchTime: Double?, enhancedUserInterface: Bool = false,
                    manualAccessibility: Bool = false) {
            self.pid = pid; self.bundleID = bundleID; self.launchTime = launchTime
            self.enhancedUserInterface = enhancedUserInterface; self.manualAccessibility = manualAccessibility
        }

        public var changedAnything: Bool { enhancedUserInterface || manualAccessibility }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public static let defaultsKey = "ShoutAXWakeLedger"

    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(AXWakeLedger.self, from: $0) } ?? AXWakeLedger()
    }

    public var data: Data? { entries.isEmpty ? nil : try? JSONEncoder().encode(self) }

    /// Whether `entry` still describes the process running with its pid: the same app and, when both are known,
    /// the same launch (within a second).
    public static func applies(_ entry: Entry, runningBundleID: String?, runningLaunchTime: Double?) -> Bool {
        guard let id = runningBundleID, id.lowercased() == entry.bundleID.lowercased() else { return false }
        guard let a = entry.launchTime, let b = runningLaunchTime else { return true }
        return abs(a - b) < 1
    }
}
