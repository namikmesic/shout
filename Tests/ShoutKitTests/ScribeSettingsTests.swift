import XCTest
@testable import ShoutKit

final class ScribeShortcutDefaultTests: XCTestCase {
    private func decode(_ edit: (inout [String: Any]) -> Void) throws -> AppSettings {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as! [String: Any]
        edit(&json)
        return try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func keys(_ combo: KeyCombo) -> [UInt16] { combo.keys.sorted() }

    func testNewSettingsUseOptionM() {
        XCTAssertEqual(AppSettings().scribeShortcut, KeyCombo.defaultScribe)
        XCTAssertEqual(KeyCombo.defaultScribe.displayString, "⌥ + M")
        XCTAssertTrue(AppSettings().defaultScribeShortcutIsFree)
    }

    func testEmptyShortcutFromBeforeTheDefaultGetsOptionM() throws {
        let s = try decode { json in
            json["scribeShortcut"] = ["keys": [UInt16]()]
            json.removeValue(forKey: "scribeShortcutRemoved")
        }
        XCTAssertEqual(s.scribeShortcut, KeyCombo.defaultScribe)
    }

    func testClearedShortcutStaysCleared() throws {
        let s = try decode { json in
            json["scribeShortcut"] = ["keys": [UInt16]()]
            json["scribeShortcutRemoved"] = true
        }
        XCTAssertTrue(s.scribeShortcut.isEmpty)
    }

    func testChosenShortcutIsKept() throws {
        let s = try decode { json in json["scribeShortcut"] = ["keys": [KeyCombo.Key.leftControl, KeyCombo.Key.leftOption, 46]] }
        XCTAssertEqual(keys(s.scribeShortcut), [46, KeyCombo.Key.leftOption, KeyCombo.Key.leftControl].sorted())
    }

    func testSpeakerNamesDefaultOnAndAreKept() throws {
        XCTAssertTrue(AppSettings().scribeDetectSpeakers)
        XCTAssertTrue(try decode { $0.removeValue(forKey: "scribeDetectSpeakers") }.scribeDetectSpeakers,
                      "a key missing from the saved settings")
        XCTAssertFalse(try decode { $0["scribeDetectSpeakers"] = false }.scribeDetectSpeakers)
    }

    func testLongMeetingCheckInDefaultsOnAndIsKept() throws {
        XCTAssertTrue(AppSettings().scribeLongMeetingCheckIn)
        XCTAssertTrue(try decode { $0.removeValue(forKey: "scribeLongMeetingCheckIn") }.scribeLongMeetingCheckIn)
        XCTAssertFalse(try decode { $0["scribeLongMeetingCheckIn"] = false }.scribeLongMeetingCheckIn)
    }

    func testNotAddedWhenAnotherShortcutUsesItsKeys() throws {
        // Push to talk on Left ⌥: ⌥M would fire mid-dictation.
        let s = try decode { json in
            json["scribeShortcut"] = ["keys": [UInt16]()]
            json["pushToTalk"] = ["keys": [KeyCombo.Key.leftOption]]
        }
        XCTAssertFalse(s.defaultScribeShortcutIsFree)
        XCTAssertTrue(s.scribeShortcut.isEmpty)
        // Right ⌥ doesn't collide, nor do keys that share ⌥ without one containing the other.
        var right = AppSettings(); right.pushToTalk = KeyCombo([KeyCombo.Key.rightOption])
        XCTAssertTrue(right.defaultScribeShortcutIsFree)
        var optionShift = AppSettings(); optionShift.pushToTalk = KeyCombo([KeyCombo.Key.leftOption, KeyCombo.Key.leftShift])
        XCTAssertTrue(optionShift.defaultScribeShortcutIsFree)
    }

    func testSavedClashIsResolvedOnLoad() throws {
        // Saved by a build that kept ⌥M after push to talk was recorded as Left ⌥.
        let s = try decode { json in
            json["scribeShortcut"] = ["keys": KeyCombo.defaultScribe.keys.sorted()]
            json["pushToTalk"] = ["keys": [KeyCombo.Key.leftOption]]
        }
        XCTAssertTrue(s.scribeShortcut.isEmpty)
        XCTAssertFalse(s.scribeShortcutRemoved)
    }
}

/// Recording a shortcut that clashes with another (R5-1: push to talk on Left ⌥ and ⌥M both fired).
@MainActor
final class ShortcutConflictTests: XCTestCase {
    private let leftOption = KeyCombo([KeyCombo.Key.leftOption])

    private func makeStore() -> (SettingsStore, UserDefaults) {
        let suite = "ShoutTests.shortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { removeTestDefaults(suite) }
        return (SettingsStore(defaults: defaults), defaults)
    }

    func testDefaultsDontClash() {
        let s = AppSettings()
        for slot in ShortcutSlot.allCases {
            XCTAssertNil(s.shortcutConflict(s[shortcut: slot], for: slot), slot.title)
        }
    }

    func testPushToTalkOnLeftOptionTakesOverTheDefault() {
        let (store, defaults) = makeStore()
        XCTAssertEqual(store.settings.scribeShortcut, KeyCombo.defaultScribe)
        // The default gives way instead of blocking the new push to talk.
        XCTAssertNil(store.settings.shortcutConflict(leftOption, for: .pushToTalk))
        store.settings.pushToTalk = leftOption
        XCTAssertTrue(store.settings.scribeShortcut.isEmpty)
        XCTAssertFalse(store.settings.scribeShortcutRemoved)
        // What was saved is the resolved settings.
        XCTAssertTrue(SettingsStore(defaults: defaults).settings.scribeShortcut.isEmpty)
        // ⌥M can't be recorded while push to talk is Left ⌥.
        XCTAssertEqual(store.settings.shortcutConflict(KeyCombo.defaultScribe, for: .scribe), .pushToTalk)
        // Back on fn, ⌥M returns.
        store.settings.pushToTalk = KeyCombo.defaultPushToTalk
        XCTAssertEqual(store.settings.scribeShortcut, KeyCombo.defaultScribe)
    }

    func testClearedDefaultStaysClearedWhenItBecomesFreeAgain() {
        let (store, _) = makeStore()
        store.settings.scribeShortcut = KeyCombo([])
        store.settings.scribeShortcutRemoved = true
        store.settings.pushToTalk = leftOption
        store.settings.pushToTalk = KeyCombo.defaultPushToTalk
        XCTAssertTrue(store.settings.scribeShortcut.isEmpty)
    }

    func testAChosenScribeShortcutBlocksAClashingPushToTalk() {
        var s = AppSettings()
        s.scribeShortcut = KeyCombo([KeyCombo.Key.leftControl, KeyCombo.Key.leftOption, 45])   // ⌃⌥N
        XCTAssertEqual(s.shortcutConflict(KeyCombo([KeyCombo.Key.leftControl, KeyCombo.Key.leftOption]), for: .pushToTalk), .scribe)
        XCTAssertEqual(s.shortcutConflict(leftOption, for: .pushToTalk), .scribe)
        XCTAssertNil(s.shortcutConflict(KeyCombo([KeyCombo.Key.rightOption]), for: .pushToTalk))
        // It is never dropped for one: only the default gives way.
        var resolved = s
        resolved.pushToTalk = leftOption
        resolved.resolveScribeDefault()
        XCTAssertEqual(resolved.scribeShortcut, s.scribeShortcut)
    }

    func testExactAndNestedClashes() {
        let s = AppSettings()
        let fn = KeyCombo.Key.fn, space = KeyCombo.Key.space
        // The same keys as another shortcut.
        XCTAssertEqual(s.shortcutConflict(s.pasteLast, for: .handsFree), .pasteLast)
        XCTAssertEqual(s.shortcutConflict(KeyCombo([fn]), for: .handsFree), .pushToTalk)
        XCTAssertEqual(s.shortcutConflict(s.handsFree, for: .command), .handsFree)
        // Containing another: ⌃⌘⇧V fires Paste on the way.
        XCTAssertEqual(s.shortcutConflict(KeyCombo(s.pasteLast.keys.union([KeyCombo.Key.leftShift])), for: .scribe), .pasteLast)
        // Contained in another: ⌃⌘ fires on the way to ⌃⌘V.
        XCTAssertEqual(s.shortcutConflict(KeyCombo([KeyCombo.Key.leftControl, KeyCombo.Key.leftCommand]), for: .scribe), .pasteLast)
        XCTAssertEqual(s.shortcutConflict(KeyCombo([fn]), for: .scribe), .pushToTalk)
        // Hands-free and Command Mode may extend push to talk, but not the other way round.
        XCTAssertNil(s.shortcutConflict(KeyCombo([fn, KeyCombo.Key.rightShift]), for: .command))
        XCTAssertNil(s.shortcutConflict(KeyCombo([fn]), for: .pushToTalk))
        XCTAssertEqual(s.shortcutConflict(KeyCombo([fn, space, KeyCombo.Key.leftShift]), for: .pushToTalk), .handsFree)
        // Sharing a modifier is fine: neither contains the other.
        XCTAssertNil(s.shortcutConflict(KeyCombo([KeyCombo.Key.leftControl, KeyCombo.Key.leftOption, 45]), for: .scribe))
        XCTAssertNil(s.shortcutConflict(KeyCombo([]), for: .scribe))
    }

    func testKeyNamesFallBackToANSIOffTheMainThread() {
        let done = expectation(description: "background")
        DispatchQueue.global().async {
            XCTAssertEqual(KeyNames.character(for: 46), "M")
            XCTAssertNil(KeyNames.typed(by: 46))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(KeyCombo.name(for: 123), "←")
        // On the main thread the default is the key that types "m" in this Mac's layout.
        let m = KeyCombo.defaultScribe.keys.subtracting([KeyCombo.Key.leftOption])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(KeyCombo.name(for: m.first!), "M")
    }
}
