import AppKit
import UniformTypeIdentifiers
import ShoutKit

/// Collects the screenshots taken during a Prompt mode session, each with the moment it was taken (seconds into
/// the recording), so the prompt can tie it to the words said then (docs/PROMPT_MODE.md, step 2):
/// - images put on the clipboard (⌃⌘⇧4, or a copied image or image file): the moment they appear;
/// - macOS screenshots saved as files: found in the screenshot folder at the end, timed by their file name;
/// - Shout's own captures (a tap of ⌥), added by the caller.
@MainActor
final class ScreenshotWatcher {
    /// Where the prompts' pictures are kept (`Store.capturesRoot`).
    let root: URL
    init(root: URL) { self.root = root }

    private(set) var captures: [PromptCapture] = []
    /// Where to look for saved screenshots instead of macOS's folder (self-test).
    var screenshotFolderOverride: URL?
    /// Whether the screenshot folder may be read (`Permissions.canReadScreenshotFolder`): a protected one is read
    /// only once the user allowed it, so macOS never asks at the end of a dictation.
    private var readSavedScreenshots = true
    /// ⌘⇧3/4/5 was pressed but the folder couldn't be read: the prompt left those screenshots out.
    private(set) var missedSavedScreenshots = false
    /// Called on every new screenshot (to count them in the Flow Bar).
    var onChange: ((Int) -> Void)?
    /// Called with every screenshot as it's taken (for the model to read it while the user is still talking).
    var onCapture: ((PromptCapture) -> Void)?
    private(set) var isActive = false
    private var timer: Timer?
    private var changeCount = 0
    /// When the recording's first sample was taken: times count from here.
    private var audioStart = Date()
    private var startedAt = Date()
    private var lastScreenshotKeys: Date?
    /// Folder for the images Shout saves (clipboard images, ⌥ captures) in this session.
    private(set) var sessionFolder: URL?
    /// ⌥ captures still being taken: finishing waits for them.
    private var inFlight: [Task<Void, Never>] = []

    func start(audioStart: Date, readSavedScreenshots: Bool = true) {
        stopTimer()
        captures = []
        self.readSavedScreenshots = readSavedScreenshots
        missedSavedScreenshots = false
        isActive = true
        self.audioStart = audioStart
        startedAt = Date()
        lastScreenshotKeys = nil
        sessionFolder = nil
        changeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onChange?(0)
    }

    /// ⌘⇧3/4/5 was pressed: a saved screenshot may arrive after its floating thumbnail (about 5 s).
    func noteScreenshotKeys() { lastScreenshotKeys = Date() }

    /// A folder for this session's own images.
    func folder() -> URL {
        if let sessionFolder { return sessionFolder }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = root.appendingPathComponent(f.string(from: startedAt), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        sessionFolder = url
        return url
    }

    func seconds(at date: Date) -> Double { max(0, date.timeIntervalSince(audioStart)) }

    func add(_ capture: PromptCapture) {
        captures.append(capture)
        captures.sort { $0.time < $1.time }
        onChange?(captures.count)
        onCapture?(capture)
    }

    /// Runs a capture that finishing waits for (a screenshot taken just before the end still counts).
    func run(_ work: @escaping @MainActor () async -> Void) {
        inFlight.append(Task { @MainActor in await work() })
    }

    /// Stops watching and returns the screenshots in the order taken, with macOS screenshots saved as files. After
    /// ⌘⇧3/4/5 it waits up to 6 s for a file whose thumbnail is still showing.
    func finish() async -> [PromptCapture] {
        guard isActive else { return [] }
        stopTimer()
        pollClipboard()
        let end = Date()
        for task in inFlight { await task.value }
        inFlight = []
        isActive = false
        let shotFolder = screenshotFolderOverride ?? Self.screenshotFolder()
        guard readSavedScreenshots || screenshotFolderOverride != nil else {
            missedSavedScreenshots = lastScreenshotKeys != nil
            let all = captures
            captures = []
            onChange?(0)
            return all
        }
        var files = savedScreenshots(until: end, in: shotFolder)
        if let keys = lastScreenshotKeys, end.timeIntervalSince(keys) < 8 {
            let deadline = Date().addingTimeInterval(6)
            while !files.contains(where: { $0.time >= seconds(at: keys) - 1 }), Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                files = savedScreenshots(until: end, in: shotFolder)
            }
        }
        let all = (captures + files).sorted { $0.time < $1.time }
        captures = []
        onChange?(0)
        return all
    }

    /// Every picture the prompt points to becomes Shout's own copy in the session folder, sized for the assistant
    /// (`PromptImages.maxLongEdge`), so the prompt and History keep working when a screenshot is moved or deleted from
    /// the Desktop. The original isn't touched.
    func keepCopies(_ captures: [PromptCapture]) -> [PromptCapture] {
        guard !captures.isEmpty else { return captures }
        let dir = folder()
        return captures.enumerated().map { i, c in
            guard !c.path.hasPrefix(dir.path) else { return c }
            let source = URL(fileURLWithPath: c.path)
            let copy = dir.appendingPathComponent("screenshot-\(i + 1).png")
            try? FileManager.default.removeItem(at: copy)
            guard (try? PromptImages.fit(source, to: copy)) != nil else { return c }
            var kept = c
            kept.original = c.path
            kept.path = copy.path
            return kept
        }
    }

    /// The session was cancelled: its own images are deleted. Only while it's running: after `finish()` the folder
    /// belongs to the History entry, and a later dictation that's cancelled (it never starts the watcher) must not
    /// delete it.
    func cancel() {
        stopTimer()
        inFlight.forEach { $0.cancel() }
        inFlight = []
        if isActive, let sessionFolder { try? FileManager.default.removeItem(at: sessionFolder) }
        isActive = false
        captures = []
        sessionFolder = nil
        onChange?(0)
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    // MARK: Clipboard

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard isActive, pb.changeCount != changeCount else { return }
        changeCount = pb.changeCount
        let now = Date()
        // A copied image file (Finder) is used where it is.
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first,
           let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            add(PromptCapture(time: seconds(at: now), path: url.path, source: .clipboard))
            return
        }
        guard pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = folder().appendingPathComponent("clipboard-\(captures.count + 1).png")
        guard (try? png.write(to: url)) != nil else { return }
        // Sized for the assistant that reads it (a Retina screenshot is four times the pixels it needs).
        _ = try? PromptImages.fit(url, to: url)
        add(PromptCapture(time: seconds(at: now), path: url.path, source: .clipboard))
    }

    // MARK: Saved screenshots

    /// Where macOS saves screenshots (Screenshot app → Options → Save to), Desktop by default.
    nonisolated static func screenshotFolder() -> URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Screen captures in the screenshot folder taken during the session. Reading the folder may ask for access
    /// once (Desktop); without it, saved screenshots are left out.
    private func savedScreenshots(until end: Date, in folder: URL = ScreenshotWatcher.screenshotFolder()) -> [PromptCapture] {
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
                  Self.isScreenCapture(url) else { return nil }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard let taken = PromptScreenshots.captureDate(fileName: url.lastPathComponent) ?? created,
                  taken >= startedAt.addingTimeInterval(-1), taken <= end.addingTimeInterval(1) else { return nil }
            return PromptCapture(time: seconds(at: taken), path: url.path, source: .screenshot)
        }
    }

    /// macOS marks its screenshots with kMDItemIsScreenCapture in an extended attribute.
    nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
            || PromptScreenshots.captureDate(fileName: url.lastPathComponent) != nil
    }
}
