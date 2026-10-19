import Foundation

public enum AppPaths {
    public static let appName = "Shout"

    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent(appName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var models: URL {
        let url = support.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static let databaseName = "shout.sqlite"
    public static var database: URL { support.appendingPathComponent(databaseName) }
    public static var recordings: URL {
        let url = support.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Screenshots Shout takes for Prompt mode (⌥) and images copied while talking; kept 7 days.
    public static var captures: URL {
        let url = support.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// One folder per meeting holding its audio tracks.
    public static var meetings: URL {
        let url = support.appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func meetingFolder(_ id: String) -> URL {
        meetings.appendingPathComponent(id, isDirectory: true)
    }

    public static func modelFile(_ model: ModelInfo) -> URL? {
        model.fileName.map { models.appendingPathComponent($0) }
    }
}
