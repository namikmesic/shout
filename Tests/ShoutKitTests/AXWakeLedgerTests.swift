import XCTest
@testable import ShoutKit

final class AXWakeLedgerTests: XCTestCase {
    private let entry = AXWakeLedger.Entry(pid: 4321, bundleID: "com.microsoft.teams2", launchTime: 1_000,
                                           enhancedUserInterface: true)

    func testItRoundTripsAndAnEmptyLedgerIsRemoved() {
        let ledger = AXWakeLedger(entries: [entry, .init(pid: 7, bundleID: "com.google.Chrome", launchTime: nil, manualAccessibility: true)])
        XCTAssertEqual(AXWakeLedger(data: ledger.data), ledger)
        XCTAssertNil(AXWakeLedger().data, "nothing left on: the defaults key is removed")
        XCTAssertEqual(AXWakeLedger(data: nil), AXWakeLedger())
        XCTAssertEqual(AXWakeLedger(data: Data("garbage".utf8)), AXWakeLedger())
        XCTAssertTrue(entry.changedAnything)
        XCTAssertFalse(AXWakeLedger.Entry(pid: 1, bundleID: "x", launchTime: nil).changedAnything)
    }

    func testOnlyTheSameRunningAppIsPutBack() {
        XCTAssertTrue(AXWakeLedger.applies(entry, runningBundleID: "com.microsoft.Teams2", runningLaunchTime: 1_000.4))
        XCTAssertFalse(AXWakeLedger.applies(entry, runningBundleID: "com.microsoft.teams2", runningLaunchTime: 5_000),
                       "the pid now belongs to a later launch")
        XCTAssertFalse(AXWakeLedger.applies(entry, runningBundleID: "com.apple.Safari", runningLaunchTime: 1_000), "another app")
        XCTAssertFalse(AXWakeLedger.applies(entry, runningBundleID: nil, runningLaunchTime: nil), "not running")
        XCTAssertTrue(AXWakeLedger.applies(entry, runningBundleID: "com.microsoft.teams2", runningLaunchTime: nil))
    }
}
