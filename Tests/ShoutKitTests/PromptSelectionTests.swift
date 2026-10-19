import XCTest
@testable import ShoutKit
import ShoutLLM

private final class Replying: TextGenerator, @unchecked Sendable {
    let displayName = "Replying"
    let reply: String
    private(set) var messages: [ChatMessage] = []
    init(_ reply: String) { self.reply = reply }
    func warmUp() async {}
    func generate(_ messages: [ChatMessage], options: GenerationOptions) async throws -> String {
        self.messages = messages
        return reply
    }
}

/// Selected text in an ⌥ capture: boxed in the picture, quoted to the model, and added to the prompt in full.
final class PromptSelectionTests: XCTestCase {
    private let code = "func save() {\n    store.write(entry)\n}"
    private var capture: PromptCapture {
        PromptCapture(time: 2, path: "/c/capture-20.png", source: .shout, detail: "window: Store.swift — Shout (Xcode)",
                      selection: code, location: "/p/Store.swift:40-42")
    }

    func testTheModelGetsTheSelectedText() {
        let msgs = PromptBuilder.promptMessages(spoken: "this (see screenshot 1) should be async", material: nil,
                                                vocabulary: [],
                                                captures: [capture])
        XCTAssertTrue(msgs[1].content.contains("Screenshot 1: they selected this text (window: Store.swift — Shout (Xcode)):\n<selected in=\"/p/Store.swift:40-42\">\n\(code)\n</selected>"),
                      msgs[1].content)
        XCTAssertTrue(msgs[0].content.contains(PromptBuilder.promptSelectionRule))

        // With the picture: the box is explained and the text follows it.
        let seen = PromptBuilder.promptMessages(spoken: "this (see screenshot 1) should be async", material: nil,
                                                vocabulary: [],
                                                captures: [capture], images: [Data([1])])
        XCTAssertTrue(seen[1].content.contains("Screenshot 1 (the red box marks the text they selected; window: Store.swift — Shout (Xcode)):\n\(ChatMessage.imageMarker)\nThe text they selected:\n<selected"),
                      seen[1].content)
        XCTAssertFalse(seen[1].content.contains("red ring"))
    }

    func testAVeryLongSelectionIsCutForTheModel() {
        let long = String(repeating: "word ", count: 2_000)
        let block = PromptBuilder.selectedBlock(long, location: nil)
        XCTAssertLessThan(block.count, PromptBuilder.maxSelectionForModel + 40)
        XCTAssertTrue(block.contains("…\n</selected>"))
        XCTAssertFalse(PromptBuilder.boilerplate([.init(.user, block)]).contains("word word"),
                       "selected text isn't instructions: the model may quote it")
    }

    func testThePromptQuotesTheSelectionInFull() {
        let section = PromptScreenshots.section([capture], anchors: ["…and this should be async"])
        XCTAssertEqual(section, """
        ## Screenshots
        1. `/c/capture-20.png`: taken as I said “…and this should be async”; the selected text (`/p/Store.swift:40-42`):
           ```
           func save() {
               store.write(entry)
           }
           ```
        """)
        var prose = capture
        prose.selection = "We ship on Fridays.\n\nNever on Mondays."
        prose.location = nil
        XCTAssertEqual(PromptScreenshots.section([prose], anchors: [""]), """
        ## Screenshots
        1. `/c/capture-20.png`: the selected text:
           > We ship on Fridays.
           >
           > Never on Mondays.
        """)
    }

    func testLongQuotesAreCutAndFencesKeptApart() {
        let many = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let q = PromptScreenshots.quote(many, code: true, indent: "   ")
        XCTAssertTrue(q.contains("   line 80\n   …\n   ```"))
        XCTAssertFalse(q.contains("line 81"))
        let markdown = PromptScreenshots.quote("```swift\nlet a = 1\n```", code: true, indent: "")
        XCTAssertTrue(markdown.hasPrefix("~~~\n```swift"), "a selection with its own fence gets another kind")
    }

    func testQuotingASelectionIsNotTooMuch() async throws {
        let selection = (1...60).map { "word\($0)" }.joined(separator: " ")
        var c = capture
        c.selection = selection
        c.location = nil
        let reply = "Rewrite the selected paragraph (screenshot 1) to be shorter: “\(selection)”"
        let input = PipelineInput(samples: [], context: DictationContext(), settings: AppSettings(), dictionary: [])
        let r = try await DictationPipeline.runPrompt(spoken: "please rewrite this [screenshot 1] to be a lot shorter and clearer",
                                                      input: input, generator: Replying(reply), captures: [c])
        XCTAssertTrue(r.text.hasPrefix("Rewrite the selected paragraph"))
        XCTAssertTrue(r.text.contains("> word1 word2"), "and it's quoted in the list")
    }

    func testTheArchiveKeepsTheSelection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try PromptCaptureArchive.save(.init(historyID: 7, createdAt: Date(), captures: [capture.record(said: "this")]), in: dir)
        let loaded = try XCTUnwrap(PromptCaptureArchive.load(folder: dir))
        XCTAssertEqual(loaded.captures[0].selection, code)
        XCTAssertEqual(loaded.captures[0].location, "/p/Store.swift:40-42")
    }

    func testSelectionLines() {
        let file = "# Notes\nrepeat me\nThe Add Task button should be smaller.\nIt sits at the top right.\nNothing.\nrepeat me\nEnd."
        XCTAssertEqual(SelectionLines.lines(of: "The Add Task button should be smaller.\nIt sits at the top right.", in: file, editorLine: nil), 3...4)
        XCTAssertEqual(SelectionLines.lines(of: "\n  It sits at the top right.\n", in: file, editorLine: nil), 4...4, "whitespace around it is ignored")
        XCTAssertNil(SelectionLines.lines(of: "repeat me", in: file, editorLine: nil), "twice in the file, no hint")
        XCTAssertEqual(SelectionLines.lines(of: "repeat me", in: file, editorLine: 6), 6...6)
        XCTAssertNil(SelectionLines.lines(of: "repeat me", in: file, editorLine: 4), "a hint that matches neither")
        XCTAssertNil(SelectionLines.lines(of: "not saved yet", in: file, editorLine: 2))
        XCTAssertEqual(SelectionLines.line(at: 0, in: file as NSString), 1)
        XCTAssertEqual(SelectionLines.line(at: (file as NSString).range(of: "End").location, in: file as NSString), 7)
    }
}
