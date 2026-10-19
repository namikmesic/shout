import XCTest
@testable import ShoutKit

/// Ask can be open for one meeting in the main window and the Notepad: a chat deleted in one must not swallow
/// the other's next question (Greptile PR #2). AskSheet checks `askChatExists` before saving to the chat.
@MainActor
final class Review4GFAskTests: XCTestCase {
    private var paths: [String] = []

    private func tempPath() -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("shout-gf-\(UUID().uuidString).sqlite").path
        paths.append(p)
        return p
    }

    override func tearDown() async throws {
        for p in paths { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: p + suffix) } }
    }

    func testADeletedChatIsReportedGoneSoTheNextQuestionStartsANewOne() throws {
        let store = try Store(path: tempPath())
        let chat = store.createAskChat(meetingID: nil, title: "First?")
        XCTAssertTrue(store.askChatExists(id: chat.id))
        store.deleteAskChat(id: chat.id) // in the other window
        XCTAssertFalse(store.askChatExists(id: chat.id))
        XCTAssertFalse(store.askChatExists(id: "never-saved"))
        // Why it matters: a question for the deleted chat fails its foreign key and is lost.
        store.addAskQuestion(chatID: chat.id, question: "Follow-up?", sources: [])
        XCTAssertTrue(store.askMessages(chatID: chat.id).isEmpty)
        // What AskSheet does instead: a new chat, which keeps the question.
        let fresh = store.createAskChat(meetingID: nil, title: "Follow-up?")
        let pending = store.addAskQuestion(chatID: fresh.id, question: "Follow-up?", sources: [])
        store.finishAskAnswer(id: pending.id, content: "Yes.", status: .succeeded)
        XCTAssertEqual(store.askMessages(chatID: fresh.id).map(\.content), ["Follow-up?", "Yes."])
        XCTAssertEqual(store.askChats(meetingID: nil).map(\.id), [fresh.id])
    }
}
