import Foundation

/// One picture of a prompt, as kept with its History entry.
public struct PromptCaptureRecord: Codable, Equatable, Sendable {
    /// Shout's copy, which the prompt points to.
    public var path: String
    /// Where the picture came from when it wasn't Shout's own (a macOS screenshot, a copied image file).
    public var original: String?
    public var source: String
    /// Seconds into the recording.
    public var time: Double
    /// What the user was saying when it was taken.
    public var said: String
    /// What was under the mouse, and in which window.
    public var detail: String?
    /// Text that was selected, and where ("/path/File.swift:12-18").
    public var selection: String?
    public var location: String?

    public init(path: String, original: String? = nil, source: String, time: Double, said: String, detail: String? = nil,
                selection: String? = nil, location: String? = nil) {
        self.path = path; self.original = original; self.source = source; self.time = time; self.said = said; self.detail = detail
        self.selection = selection; self.location = location
    }
}

/// The pictures of one prompt: a folder of Shout's copies and `captures.json` (what was said with each), linked to
/// its History entry so History can show them and they go when the entry goes. Files only: the database is
/// unchanged (docs/PROMPT_MODE.md, step 2).
public enum PromptCaptureArchive {
    public struct Saved: Codable, Equatable, Sendable {
        public var historyID: Int64?
        public var createdAt: Date
        public var captures: [PromptCaptureRecord]

        public init(historyID: Int64?, createdAt: Date, captures: [PromptCaptureRecord]) {
            self.historyID = historyID; self.createdAt = createdAt; self.captures = captures
        }
    }

    static let fileName = "captures.json"
    /// Unlinked folders (a cancelled or failed prompt, or History turned off) are kept this long.
    public static let unlinkedLifetime: TimeInterval = 7 * 86_400

    static func link(_ id: Int64, root: URL) -> URL { root.appendingPathComponent("history-\(id)") }

    public static func save(_ saved: Saved, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(saved).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    public static func load(folder: URL) -> Saved? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Saved.self, from: data)
    }

    /// Ties the folder to History entry `id` (recorded in the folder, and a link `history-<id>` for finding it).
    public static func attach(folder: URL, historyID id: Int64, root: URL) {
        guard var saved = load(folder: folder) else { return }
        saved.historyID = id
        try? save(saved, in: folder)
        let link = link(id, root: root)
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    }

    /// The folder and pictures of History entry `id`, if it has any.
    public static func load(historyID id: Int64, root: URL) -> (folder: URL, saved: Saved)? {
        let folder = link(id, root: root).resolvingSymlinksInPath()
        guard let saved = load(folder: folder), saved.historyID == id else { return nil }
        return (folder, saved)
    }

    /// Deletes the pictures of these History entries.
    public static func remove(historyIDs: [Int64], root: URL) {
        let fm = FileManager.default
        for id in historyIDs {
            let link = link(id, root: root)
            let folder = link.resolvingSymlinksInPath()
            if folder != link, load(folder: folder)?.historyID == id { try? fm.removeItem(at: folder) }
            try? fm.removeItem(at: link)
        }
    }

    /// Deletes every History entry's pictures (History was cleared).
    public static func removeAllLinked(root: URL) {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap { name -> Int64? in
            name.hasPrefix("history-") ? Int64(name.dropFirst("history-".count)) : nil
        }
        remove(historyIDs: ids, root: root)
    }

    /// Keeps the pictures of entries still in History (`exists`); deletes those of entries that are gone, dangling
    /// links, and unlinked folders older than `unlinkedLifetime`.
    public static func prune(root: URL, now: Date = Date(), exists: (Int64) -> Bool) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            let url = root.appendingPathComponent(name)
            if name.hasPrefix("history-") {
                // A link: kept while its entry and folder exist.
                let target = url.resolvingSymlinksInPath()
                if let id = Int64(name.dropFirst("history-".count)), exists(id), target != url, fm.fileExists(atPath: target.path) { continue }
                try? fm.removeItem(at: url)
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let id = load(folder: url)?.historyID {
                if !exists(id) { try? fm.removeItem(at: url) }
                continue
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? now
            if now.timeIntervalSince(created) > unlinkedLifetime { try? fm.removeItem(at: url) }
        }
    }
}
