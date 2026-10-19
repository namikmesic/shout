import XCTest
@testable import ShoutKit
import ShoutASR
import ShoutLLM

/// Returns the next text for each part it's given, and records the parts' lengths.
private final class PartRecognizer: SpeechRecognizer, @unchecked Sendable {
    let displayName = "Parts"
    let texts: [String]
    private let lock = NSLock()
    private var _lengths: [Int] = []
    var lengths: [Int] { lock.withLock { _lengths } }
    init(_ texts: [String]) { self.texts = texts }
    func warmUp() async {}
    func transcribe(_ samples: [Float], options: TranscriptionOptions) async throws -> TranscriptionResult {
        let i = lock.withLock { _lengths.append(samples.count); return _lengths.count - 1 }
        return TranscriptionResult(text: i < texts.count ? texts[i] : "")
    }
}

private final class FixedGenerator: TextGenerator, @unchecked Sendable {
    let displayName = "Fixed"
    let reply: String
    private(set) var messages: [ChatMessage] = []
    init(_ reply: String) { self.reply = reply }
    func warmUp() async {}
    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        self.messages = messages
        return reply
    }
}

final class PromptScreenshotsTests: XCTestCase {
    /// Speech-like: 170 ms syllables with quieter 80 ms between them (a steady tone reads as no speech).
    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { i in
            let loud = i % 4_000 < 2_720
            return (loud ? 0.3 : 0.03) * sin(Float(i) * 2 * .pi * 220 / 16_000)
        }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * 16_000)) }

    func testSplitPointsMoveToTheNearestPause() {
        // Speech 0–1.0 s, pause 1.0–1.4 s, speech 1.4–2.4 s, pause 2.4–2.8 s, speech 2.8–3.8 s.
        let audio = tone(1) + silence(0.4) + tone(1) + silence(0.4) + tone(1)
        // Screenshots "taken" mid-word, 0.3 s off the pauses.
        let points = PromptScreenshots.splitPoints(samples: audio, times: [0.8, 2.95])
        XCTAssertEqual(points.count, 2)
        XCTAssertTrue((16_000...22_400).contains(points[0]), "in the first pause: \(points[0])")
        XCTAssertTrue((38_400...44_800).contains(points[1]), "in the second pause: \(points[1])")
        XCTAssertEqual(PromptScreenshots.splitPoints(samples: audio, times: [99]).first, audio.count, "clamped to the end")
    }

    func testTranscribeMarkedSplitsAtEachScreenshot() async throws {
        let audio = tone(1) + silence(0.4) + tone(1) + silence(0.4) + tone(1)
        let rec = PartRecognizer(["On the dictionary page the add button", "opens this text box right away.",
                                  "And the snippets page does the same."])
        let input = PipelineInput(samples: audio, context: DictationContext(), settings: AppSettings(), dictionary: [])
        let (out, marked) = try await DictationPipeline.transcribeMarked(input, times: [0.8, 2.95], recognizer: rec)
        XCTAssertEqual(rec.lengths.count, 3, "one recognition per part")
        XCTAssertEqual(out.rawText, "On the dictionary page the add button [screenshot 1] opens this text box right away. [screenshot 2] And the snippets page does the same.")
        XCTAssertEqual(marked.anchors.count, 2)
        XCTAssertEqual(marked.anchors[0], "On the dictionary page the add button opens this text box…")
        XCTAssertTrue(marked.anchors[1].hasPrefix("…"))
        XCTAssertTrue(marked.anchors[1].contains("right away. And the snippets"), marked.anchors[1])
    }

    func testCaptureTimeComesFromTheScreenshotsName() {
        let cal = Calendar(identifier: .gregorian)
        func parts(_ name: String) -> [Int]? {
            PromptScreenshots.captureDate(fileName: name, calendar: cal).map {
                let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0)
                return [c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!]
            }
        }
        XCTAssertEqual(parts("Screenshot 2026-10-18 at 18.49.12.png"), [2026, 10, 18, 18, 49, 12])
        XCTAssertEqual(parts("Screenshot 2026-10-18 at 6.49.12 PM.png"), [2026, 10, 18, 18, 49, 12])
        XCTAssertEqual(parts("Screenshot 2026-10-18 at 12.05.00 AM.png"), [2026, 10, 18, 0, 5, 0])
        XCTAssertEqual(parts("Bildschirmfoto 2026-10-18 um 18.49.12.png"), [2026, 10, 18, 18, 49, 12])
        XCTAssertNil(parts("holiday.png"))
    }

    func testReferencesAreNormalizedAndMissingOnesPlaced() {
        XCTAssertEqual(PromptScreenshots.normalizeReferences("Opens a box [screenshot 1] and (See Screenshot 2)."),
                       "Opens a box (screenshot 1) and (screenshot 2).")
        let prompt = """
        ## Current behaviour
        - Clicking Add on the dictionary page opens a text box immediately.
        - The snippets page always shows the big editor.

        ## Open questions
        - Should the dictionary dialog have a title?
        """
        let spoken = "on the dictionary page when you click add it opens this text box (see screenshot 1) and on the snippets page the big editor is always there (see screenshot 2)"
        let placed = PromptScreenshots.placeMissingReferences(prompt, contexts: PromptScreenshots.contexts(in: spoken, count: 2))
        XCTAssertTrue(placed.contains("opens a text box immediately (screenshot 1)."), placed)
        XCTAssertTrue(placed.contains("shows the big editor (screenshot 2)."), placed)
        XCTAssertFalse(placed.contains("title? (screenshot"), "open questions are left alone")
        // Already referenced: unchanged.
        let referenced = "## Goal\n- Fix the box (screenshot 1)."
        XCTAssertEqual(PromptScreenshots.placeMissingReferences(referenced, contexts: ["fix the box"]), referenced)
    }

    func testTheListShowsEachPictureWithItsWords() {
        let list = PromptScreenshots.section([
            PromptCapture(time: 1, path: "/tmp/a b.png", source: .shout, detail: "button “Add” in the toolbar"),
            PromptCapture(time: 2, path: "/tmp/c.png", source: .clipboard),
        ], anchors: ["…it opens this text box", ""])
        XCTAssertEqual(list, """
        ## Screenshots
        1. `/tmp/a b.png`: taken as I said “…it opens this text box” (pointed at button “Add” in the toolbar)
        2. `/tmp/c.png`
        """)
        XCTAssertEqual(PromptScreenshots.section([], anchors: []), "")
    }

    func testRunPromptTiesScreenshotsToTheirLines() async throws {
        // The model drops the reference and writes its own list: Shout places the reference and writes the list.
        let gen = FixedGenerator("""
        ## Current behaviour
        - Clicking Add on the dictionary page opens a text box immediately.

        ## Screenshots
        - screenshot.png
        """)
        let captures = [PromptCapture(time: 3, path: "/captures/screenshot-1.png", source: .screenshot)]
        let input = PipelineInput(samples: [], context: DictationContext(), settings: AppSettings(), dictionary: [])
        let r = try await DictationPipeline.runPrompt(
            spoken: "on the dictionary page when you click add it opens this text box [screenshot 1] I want a dialog",
            input: input, generator: gen, captures: captures, anchors: ["…it opens this text box I want a dialog"])
        XCTAssertEqual(r.text, """
        ## Current behaviour
        - Clicking Add on the dictionary page opens a text box immediately (screenshot 1).

        ## Screenshots
        1. `/captures/screenshot-1.png`: taken as I said “…it opens this text box I want a dialog”
        """)
        XCTAssertTrue(gen.messages[0].content.contains("(see screenshot N)"), "the screenshots rule is in")
        XCTAssertTrue(gen.messages[1].content.contains("text box (see screenshot 1) I want"), "markers as plain words")
    }

    func testNoScreenshotsNoRule() {
        let msgs = PromptBuilder.promptMessages(spoken: "x", material: nil, vocabulary: [])
        XCTAssertFalse(msgs[0].content.contains(PromptBuilder.promptScreenshotsRule))
        XCTAssertFalse(msgs[1].content.contains("<screenshots>"))
    }
}

final class PromptImagesTests: XCTestCase {
    private func png(_ w: Int, _ h: Int, at url: URL) throws {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    private func size(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// A Retina screenshot is four times the pixels an assistant needs to read it.
    func testPicturesAreCappedForTheAssistant() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("retina.png"), copy = dir.appendingPathComponent("copy.png")
        try png(2940, 1912, at: big)
        XCTAssertEqual(try PromptImages.fit(big, to: copy), CGSize(width: 1280, height: 832))
        XCTAssertEqual(size(copy), CGSize(width: 1280, height: 832))
        XCTAssertEqual(size(big), CGSize(width: 2940, height: 1912), "the original isn't touched")

        let small = dir.appendingPathComponent("small.png")
        try png(640, 400, at: small)
        XCTAssertEqual(try PromptImages.fit(small, to: small), CGSize(width: 640, height: 400), "never enlarged, in place")

        let tall = dir.appendingPathComponent("tall.png")
        try png(900, 3000, at: tall)
        XCTAssertEqual(try PromptImages.fit(tall, to: tall), CGSize(width: 384, height: 1280), "the long side is capped")
        // Tokens Claude would charge (w × h / 750): about 1,400 for a full screen.
        XCTAssertLessThan(1280 * 832 / 750, 1_500)
    }
}

final class PromptCaptureArchiveTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func folder(_ name: String, root: URL, historyID: Int64? = nil) throws -> URL {
        let f = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: f.appendingPathComponent("screenshot-1.png"))
        try PromptCaptureArchive.save(.init(historyID: historyID, createdAt: Date(), captures: [
            PromptCaptureRecord(path: f.appendingPathComponent("screenshot-1.png").path, source: "screenshot", time: 2,
                                said: "…this text box", detail: nil),
        ]), in: f)
        return f
    }

    func testSavedPicturesAreFoundByTheirHistoryEntry() throws {
        let root = dir.appendingPathComponent("Captures")
        let f = try folder("2026-10-18 18.49.12", root: root)
        XCTAssertNil(PromptCaptureArchive.load(historyID: 7, root: root))
        PromptCaptureArchive.attach(folder: f, historyID: 7, root: root)
        let found = try XCTUnwrap(PromptCaptureArchive.load(historyID: 7, root: root))
        XCTAssertEqual(found.saved.historyID, 7)
        XCTAssertEqual(found.saved.captures.first?.said, "…this text box")
    }

    @MainActor func testPicturesGoWithTheirHistoryEntry() throws {
        let store = try Store(path: dir.appendingPathComponent("test.sqlite").path)
        XCTAssertEqual(store.capturesRoot.lastPathComponent, "test.sqlite-captures", "a test database's pictures stay beside it")
        func entry(_ daysAgo: Double) -> Int64 {
            store.addHistory(HistoryEntry(id: 0, createdAt: Date().addingTimeInterval(-daysAgo * 86_400), mode: .transform,
                                          status: .inserted, rawText: "a [screenshot 1]", finalText: "prompt",
                                          audioSeconds: 1, asrSeconds: 0, llmSeconds: 0, totalSeconds: 0, wordCount: 1))
        }
        let (a, b, c) = (entry(0), entry(3), entry(0))
        for (i, id) in [a, b, c].enumerated() {
            PromptCaptureArchive.attach(folder: try folder("session-\(i)", root: store.capturesRoot), historyID: id,
                                        root: store.capturesRoot)
        }
        store.deleteHistory(id: a)
        XCTAssertNil(PromptCaptureArchive.load(historyID: a, root: store.capturesRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.capturesRoot.appendingPathComponent("session-0").path))
        store.pruneHistory(olderThan: Date().addingTimeInterval(-86_400))
        XCTAssertNil(PromptCaptureArchive.load(historyID: b, root: store.capturesRoot), "pruned with its entry")
        XCTAssertNotNil(PromptCaptureArchive.load(historyID: c, root: store.capturesRoot))
        store.deleteAllHistory()
        XCTAssertNil(PromptCaptureArchive.load(historyID: c, root: store.capturesRoot))
    }

    func testPruneKeepsLinkedPicturesAndRecentUnsavedOnes() throws {
        let root = dir.appendingPathComponent("Captures")
        let kept = try folder("kept", root: root)
        PromptCaptureArchive.attach(folder: kept, historyID: 1, root: root)
        let gone = try folder("gone", root: root)
        PromptCaptureArchive.attach(folder: gone, historyID: 2, root: root)
        _ = try folder("recent", root: root)
        _ = try folder("old", root: root)
        let later = Date().addingTimeInterval(PromptCaptureArchive.unlinkedLifetime + 60)
        // Entry 2 was deleted outside Shout's delete (a crash).
        PromptCaptureArchive.prune(root: root, now: Date()) { $0 == 1 }
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        XCTAssertEqual(names, ["kept", "history-1", "recent", "old"])
        PromptCaptureArchive.prune(root: root, now: later) { $0 == 1 }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        XCTAssertEqual(after, ["kept", "history-1"], "unsaved pictures go after a week; History's stay")
    }
}
