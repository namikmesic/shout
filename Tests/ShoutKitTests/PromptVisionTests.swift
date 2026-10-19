import XCTest
import CoreGraphics
import ImageIO
@testable import ShoutKit
import ShoutLLM

/// A model that may see pictures: records each request, and can refuse the ones with pictures.
private final class SeeingGenerator: TextGenerator, @unchecked Sendable {
    let displayName = "Seeing"
    let reply: String
    let readsImages: Bool
    let failsWithPictures: Bool
    private let lock = NSLock()
    private var _requests: [[ChatMessage]] = []
    private var _readAhead: [Data] = []
    var requests: [[ChatMessage]] { lock.withLock { _requests } }
    var readAheadPictures: [Data] { lock.withLock { _readAhead } }
    init(_ reply: String, readsImages: Bool = true, failsWithPictures: Bool = false) {
        self.reply = reply; self.readsImages = readsImages; self.failsWithPictures = failsWithPictures
    }
    func warmUp() async {}
    func readAhead(_ image: Data) async { lock.withLock { _readAhead.append(image) } }
    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        lock.withLock { _requests.append(messages) }
        if failsWithPictures && messages.contains(where: { !$0.images.isEmpty }) {
            throw TextGeneratorError.generationFailed("a picture couldn't be read")
        }
        return reply
    }
}

final class PromptVisionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func png(_ w: Int, _ h: Int, name: String) throws -> String {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 3, height: h / 5))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url.path
    }

    private func pixelSize(_ data: Data) -> CGSize? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    private func settings(model: String = "qwen3.5-9b-q4") -> AppSettings {
        var s = AppSettings()
        s.languageModelID = model
        return s
    }

    private func input(_ s: AppSettings) -> PipelineInput {
        PipelineInput(samples: [], context: DictationContext(appName: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
                      settings: s, dictionary: [])
    }

    // MARK: Catalog and settings

    func testQwen35ModelsHaveImageReaders() {
        XCTAssertEqual(ModelCatalog.model(id: "qwen3.5-4b-q4")?.imageReader?.id, "qwen3.5-4b-vision")
        XCTAssertEqual(ModelCatalog.model(id: "qwen3.5-9b-q4")?.imageReader?.id, "qwen3.5-9b-vision")
        for id in ["qwen3-4b-instruct-q4", "qwen3.5-2b-q4", "ollama", "apple-intelligence"] {
            XCTAssertNil(ModelCatalog.model(id: id)?.imageReader, "\(id) can't see pictures here")
        }
        for reader in ModelCatalog.vision {
            XCTAssertEqual(reader.kind, .vision)
            XCTAssertNotNil(reader.sha256, "a download is checked")
            XCTAssertFalse(ModelCatalog.language.contains(reader), "never offered as an editing model")
        }
        XCTAssertEqual(Set(ModelCatalog.vision.compactMap(\.fileName)).count, ModelCatalog.vision.count,
                       "both repos call it mmproj-F16.gguf: the files must not overwrite each other")
    }

    func testTheModelSeesScreenshotsOnlyWhenItCan() {
        var s = settings()
        XCTAssertTrue(s.promptModelSeesScreenshots)
        s.promptShowScreenshotsToModel = false
        XCTAssertFalse(s.promptModelSeesScreenshots, "switched off")
        s = settings(model: "qwen3-4b-instruct-q4")
        XCTAssertTrue(s.promptScreenshotsOn, "screenshots still work with a text-only model")
        XCTAssertFalse(s.promptModelSeesScreenshots, "but it can't look at them")
        s = settings()
        s.promptScreenshots = false
        XCTAssertFalse(s.promptModelSeesScreenshots, "no screenshots, nothing to see")
    }

    // MARK: Messages

    func testPicturesGoInWhereTheScreenshotsAreListed() {
        let captures = [
            PromptCapture(time: 1, path: "/a.png", source: .shout, detail: "button “Add Task”; window: Shout (Shout)"),
            PromptCapture(time: 2, path: "/b.png", source: .screenshot),
        ]
        let pictures: [Data?] = [Data([1]), Data([2])]
        let msgs = PromptBuilder.promptMessages(spoken: "make this (see screenshot 1) smaller and this (see screenshot 2) bigger",
                                                material: nil, vocabulary: [], captures: captures, images: pictures)
        XCTAssertEqual(msgs[1].images, [Data([1]), Data([2])])
        XCTAssertEqual(msgs[1].content.components(separatedBy: ChatMessage.imageMarker).count - 1, 2, "one marker per picture")
        XCTAssertTrue(msgs[1].content.contains("Screenshot 1 (the red ring is where they pointed; pointed at: button “Add Task”; window: Shout (Shout)):\n\(ChatMessage.imageMarker)"))
        XCTAssertTrue(msgs[1].content.contains("Screenshot 2:\n\(ChatMessage.imageMarker)"), "a macOS screenshot has no ring")
        XCTAssertTrue(msgs[0].content.contains(PromptBuilder.promptPicturesRule))
        XCTAssertTrue(msgs[0].images.isEmpty)
    }

    func testWithoutPicturesTheMessagesAreUnchanged() {
        let captures = [PromptCapture(time: 1, path: "/a.png", source: .shout, detail: "button “Add”")]
        let plain = PromptBuilder.promptMessages(spoken: "make this (see screenshot 1) smaller", material: nil,
                                                 vocabulary: [],
                                                 captures: captures)
        XCTAssertFalse(plain[1].content.contains(ChatMessage.imageMarker))
        XCTAssertFalse(plain[0].content.contains(PromptBuilder.promptPicturesRule))
        XCTAssertTrue(plain[1].content.contains("Screenshot 1: pointed at: button “Add”"))
        // A picture list that doesn't match the captures is ignored rather than misnumbered.
        let mismatched = PromptBuilder.promptMessages(spoken: "make this (see screenshot 1) smaller", material: nil,
                                                      vocabulary: [],
                                                      captures: captures, images: [Data([1]), Data([2])])
        XCTAssertEqual(mismatched, plain)
    }

    func testAPictureThatCouldNotBeMadeFallsBackToItsLabel() {
        let captures = [PromptCapture(time: 1, path: "/a.png", source: .shout, detail: "button “Add”"),
                        PromptCapture(time: 2, path: "/gone.png", source: .shout, detail: "tab “Archived”")]
        let msgs = PromptBuilder.promptMessages(spoken: "this (see screenshot 1) and this (see screenshot 2)", material: nil,
                                                vocabulary: [],
                                                captures: captures, images: [Data([1]), nil])
        XCTAssertEqual(msgs[1].images.count, 1)
        XCTAssertTrue(msgs[1].content.contains("Screenshot 2: pointed at: tab “Archived”"))
    }

    /// Accessibility often names only a container ("scroll area"): next to the picture that misled the model.
    func testVagueLabelsAreDroppedNextToAPicture() {
        XCTAssertEqual(PromptScreenshots.withoutVagueThing("scroll area; window: Shout (Shout)"), "window: Shout (Shout)")
        XCTAssertEqual(PromptScreenshots.withoutVagueThing("under the mouse: cell; window: Shout (Shout)"), "window: Shout (Shout)")
        XCTAssertEqual(PromptScreenshots.withoutVagueThing("group in a list; window: Notes (Notes)"), "window: Notes (Notes)")
        XCTAssertEqual(PromptScreenshots.withoutVagueThing("text “Follow up.”; window: Shout (Shout)"),
                       "pointed at: text “Follow up.”; window: Shout (Shout)", "a labelled thing is kept")
        XCTAssertEqual(PromptScreenshots.withoutVagueThing("row “Settings” in the sidebar; window: Shout (Shout)"),
                       "pointed at: row “Settings” in the sidebar; window: Shout (Shout)")
        XCTAssertEqual(PromptScreenshots.withoutVagueThing("button in the toolbar; window: Mail (Mail)"),
                       "pointed at: button in the toolbar; window: Mail (Mail)", "a control says something even unlabelled")
        XCTAssertEqual(PromptScreenshots.withoutVagueThing("window: Finder (Finder)"), "window: Finder (Finder)")
    }

    // MARK: Picture sizes

    func testPicturesAreSizedForTheLocalModel() throws {
        XCTAssertEqual(PromptImages.modelTokens(width: 1280, height: 800), 40 * 25 + 2)
        XCTAssertEqual(PromptImages.modelTokens(width: 33, height: 1), 2 * 1 + 2, "a partial block counts")
        for n in 1...4 { XCTAssertEqual(PromptImages.modelTokenBudget(count: n, contextTokens: 8192), PromptImages.maxModelTokens) }
        XCTAssertLessThan(PromptImages.modelTokenBudget(count: 5, contextTokens: 8192), PromptImages.maxModelTokens, "many share the room")
        XCTAssertEqual(PromptImages.modelTokenBudget(count: 50, contextTokens: 8192), 160, "never below a readable minimum")
        XCTAssertEqual(PromptImages.modelTokenBudget(count: 0, contextTokens: 8192), 0)

        let retina = try png(2940, 1846, name: "retina.png")
        let picture = try XCTUnwrap(PromptImages.forModel(retina, maxTokens: 1_100))
        let size = try XCTUnwrap(pixelSize(picture.data))
        XCTAssertLessThanOrEqual(max(size.width, size.height), CGFloat(PromptImages.maxLongEdge))
        XCTAssertLessThanOrEqual(picture.tokens, 1_100)
        XCTAssertEqual(picture.tokens, PromptImages.modelTokens(width: Int(size.width), height: Int(size.height)))
        // The same file at the same budget gives the same bytes: the picture read while talking is the one sent.
        XCTAssertEqual(PromptImages.forModel(retina, maxTokens: 1_100)?.data, picture.data)

        let smaller = try XCTUnwrap(PromptImages.forModel(retina, maxTokens: 300))
        XCTAssertLessThanOrEqual(smaller.tokens, 300)
        let icon = try png(60, 60, name: "icon.png")
        XCTAssertEqual(PromptImages.forModel(icon, maxTokens: 1_100).flatMap { pixelSize($0.data) }, CGSize(width: 60, height: 60),
                       "a small screenshot isn't enlarged")
        XCTAssertNil(PromptImages.forModel(dir.appendingPathComponent("missing.png").path, maxTokens: 1_100))
    }

    // MARK: Pipeline

    func testAModelThatSeesGetsTheScreenshots() async throws {
        let a = try png(1600, 1000, name: "a.png"), b = try png(800, 500, name: "b.png")
        let captures = [PromptCapture(time: 1, path: a, source: .shout, detail: "button “Add Task”; window: Shout (Shout)"),
                        PromptCapture(time: 3, path: b, source: .screenshot)]
        let gen = SeeingGenerator("Make the Add Task button at the top right (screenshot 1) smaller, and the gear icon (screenshot 2) bigger.")
        let r = try await DictationPipeline.runPrompt(spoken: "make this [screenshot 1] smaller and this icon [screenshot 2] bigger",
                                                      input: input(settings()), generator: gen, captures: captures,
                                                      anchors: ["make this", "and this icon"])
        XCTAssertEqual(r.picturesSeen, 2)
        XCTAssertEqual(gen.requests.count, 1)
        XCTAssertEqual(gen.requests[0][1].images.count, 2)
        XCTAssertTrue(r.text.hasPrefix("Make the Add Task button at the top right (screenshot 1)"))
        XCTAssertTrue(r.text.contains("## Screenshots"), "the list with the paths is still added")
    }

    func testNoPicturesWhenTheModelCantOrMayNotSee() async throws {
        let a = try png(1600, 1000, name: "a.png")
        let captures = [PromptCapture(time: 1, path: a, source: .shout, detail: "button “Add Task”")]
        let spoken = "make this [screenshot 1] a bit smaller please"
        // The image reader isn't downloaded.
        let blind = SeeingGenerator("Make the Add Task button (screenshot 1) a bit smaller.", readsImages: false)
        var r = try await DictationPipeline.runPrompt(spoken: spoken, input: input(settings()), generator: blind, captures: captures)
        XCTAssertEqual(r.picturesSeen, 0)
        XCTAssertTrue(blind.requests[0].allSatisfy { $0.images.isEmpty })
        // Switched off.
        var off = settings()
        off.promptShowScreenshotsToModel = false
        let seeing = SeeingGenerator("Make the Add Task button (screenshot 1) a bit smaller.")
        r = try await DictationPipeline.runPrompt(spoken: spoken, input: input(off), generator: seeing, captures: captures)
        XCTAssertEqual(r.picturesSeen, 0)
        XCTAssertTrue(seeing.requests[0].allSatisfy { $0.images.isEmpty })
    }

    func testPicturesThatFailFallBackToTheWords() async throws {
        let a = try png(1600, 1000, name: "a.png")
        let captures = [PromptCapture(time: 1, path: a, source: .shout, detail: "button “Add Task”")]
        let gen = SeeingGenerator("Make the Add Task button (screenshot 1) a bit smaller.", failsWithPictures: true)
        let r = try await DictationPipeline.runPrompt(spoken: "make this [screenshot 1] a bit smaller please", input: input(settings()),
                                                      generator: gen, captures: captures)
        XCTAssertEqual(r.picturesSeen, 0)
        XCTAssertEqual(gen.requests.count, 2, "tried with the pictures, then without")
        XCTAssertTrue(gen.requests[1].allSatisfy { $0.images.isEmpty })
        XCTAssertTrue(r.text.contains("Add Task button"))
    }

    func testAScreenshotReadWhileTalkingIsTheOneSent() async throws {
        let a = try png(2940, 1846, name: "a.png"), b = try png(1200, 700, name: "b.png")
        let captures = [PromptCapture(time: 1, path: a, source: .shout), PromptCapture(time: 2, path: b, source: .clipboard)]
        let gen = SeeingGenerator("Make the Add Task button (screenshot 1) and the tabs (screenshot 2) smaller.")
        for c in captures { await DictationPipeline.readAhead(c, settings: settings(), generator: gen) }
        _ = try await DictationPipeline.runPrompt(spoken: "make this [screenshot 1] and these [screenshot 2] smaller",
                                                  input: input(settings()), generator: gen, captures: captures)
        XCTAssertEqual(gen.readAheadPictures, gen.requests[0][1].images, "same bytes, so the engine reuses what it read")

        let off = SeeingGenerator("x")
        await DictationPipeline.readAhead(captures[0], settings: settings(model: "qwen3-4b-instruct-q4"), generator: off)
        XCTAssertTrue(off.readAheadPictures.isEmpty, "nothing read for a model that can't see")
    }
}

@MainActor
final class ImageReaderDeleteTests: XCTestCase {
    /// An image reader is no use without its model: deleting the model deletes it too.
    func testDeletingAModelDeletesItsImageReader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("readers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = ModelManager(configuration: .ephemeral, modelFile: { m in m.fileName.map { dir.appendingPathComponent($0) } })
        let model = try XCTUnwrap(ModelCatalog.model(id: "qwen3.5-9b-q4")), reader = try XCTUnwrap(model.imageReader)
        for m in [model, reader] { try Data([1]).write(to: dir.appendingPathComponent(m.fileName!)) }
        manager.refresh()
        XCTAssertTrue(manager.isInstalled(reader))
        manager.delete(model)
        XCTAssertFalse(manager.isInstalled(model))
        XCTAssertFalse(manager.isInstalled(reader))
    }
}
