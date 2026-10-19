import XCTest
import Combine
import CryptoKit
@testable import ShoutKit

/// Canned replies for ModelManager's session, keyed by URL, so downloads run without a network.
private final class StubRegistry: @unchecked Sendable {
    struct Reply { var status = 200; var body = Data(); var hang = false }
    let lock = NSLock()
    var replies: [URL: Reply] = [:]
    var requests: [URL: Int] = [:]
    var started: [URL: XCTestExpectation] = [:]

    func set(_ url: URL, _ reply: Reply) { lock.withLock { replies[url] = reply } }
    func count(_ url: URL) -> Int { lock.withLock { requests[url, default: 0] } }
}

private final class StubProtocol: URLProtocol {
    static let registry = StubRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let r = Self.registry
        let (reply, started) = r.lock.withLock { () -> (StubRegistry.Reply?, XCTestExpectation?) in
            r.requests[url, default: 0] += 1
            return (r.replies[url], r.started[url])
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        started?.fulfill()
        guard !reply.hang else { return } // ends only when cancelled
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// What a `download` call ended with, and whether the file was in place at that moment.
@MainActor
private final class Outcome {
    var error: Error?
    var settled = false
    var fileExistedOnReturn = false
}

@MainActor
final class Review3G01ModelManagerTests: XCTestCase {
    private func makeManager() throws -> (ModelManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shout-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let manager = ModelManager(configuration: config, modelFile: { m in m.fileName.map { dir.appendingPathComponent($0) } })
        return (manager, dir)
    }

    private func model(_ name: String, sha256: String? = nil, fileName: String? = "model.bin") -> ModelInfo {
        ModelInfo(id: "review3g01-\(name)", kind: .speech, engine: .whisper, name: name, summary: "",
                  fileName: fileName, url: URL(string: "https://stub.invalid/\(name)/\(UUID().uuidString)"),
                  sizeBytes: 5, sha256: sha256, badge: nil)
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Starts a download; the returned outcome fills in when it settles.
    private func start(_ manager: ModelManager, _ model: ModelInfo, dest: URL?, settled: XCTestExpectation) -> Outcome {
        let outcome = Outcome()
        Task {
            do { try await manager.download(model) } catch { outcome.error = error }
            outcome.fileExistedOnReturn = dest.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            outcome.settled = true
            settled.fulfill()
        }
        return outcome
    }

    private func download(_ manager: ModelManager, _ model: ModelInfo, dest: URL? = nil) async -> Outcome {
        let done = expectation(description: "download settles")
        let outcome = start(manager, model, dest: dest, settled: done)
        await fulfillment(of: [done], timeout: 5)
        return outcome
    }

    func testVerifiedDownloadIsInstalled() async throws {
        let (manager, dir) = try makeManager()
        let body = Data("hello".utf8)
        let m = model("ok", sha256: sha(body))
        StubProtocol.registry.set(m.url!, .init(body: body))
        let outcome = await download(manager, m)
        XCTAssertTrue(outcome.settled)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("model.bin")), body)
        XCTAssertNil(manager.downloads[m.id])
    }

    func testDownloadReplacesAnExistingFile() async throws {
        let (manager, dir) = try makeManager()
        let dest = dir.appendingPathComponent("model.bin")
        try Data("old".utf8).write(to: dest)
        let body = Data("new".utf8)
        let m = model("replace", sha256: sha(body))
        StubProtocol.registry.set(m.url!, .init(body: body))
        let outcome = await download(manager, m)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(try Data(contentsOf: dest), body)
    }

    func testChecksumMismatchFailsAndInstallsNothing() async throws {
        let (manager, dir) = try makeManager()
        let m = model("corrupt", sha256: String(repeating: "0", count: 64))
        StubProtocol.registry.set(m.url!, .init(body: Data("hello".utf8)))
        let outcome = await download(manager, m)
        XCTAssertTrue(outcome.settled)
        XCTAssertNotNil(outcome.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.bin").path))
        guard case .failed = manager.downloads[m.id] else { return XCTFail("expected .failed, got \(String(describing: manager.downloads[m.id]))") }
    }

    func testHTTPErrorFailsAndARetryStartsAFreshDownload() async throws {
        let (manager, _) = try makeManager()
        let body = Data("hello".utf8)
        let m = model("retry", sha256: sha(body))
        StubProtocol.registry.set(m.url!, .init(status: 404))
        let first = await download(manager, m)
        XCTAssertEqual((first.error as NSError?)?.code, 404)
        StubProtocol.registry.set(m.url!, .init(body: body))
        let second = await download(manager, m)
        XCTAssertTrue(second.settled)
        XCTAssertNil(second.error)
        XCTAssertEqual(StubProtocol.registry.count(m.url!), 2)
    }

    /// The download used to hang forever (and block every retry) when the finished file had nowhere to go.
    func testDownloadWithNoInstallLocationFailsInsteadOfHanging() async throws {
        let (manager, _) = try makeManager()
        let m = model("nowhere", fileName: nil)
        StubProtocol.registry.set(m.url!, .init(body: Data("hello".utf8)))
        let first = await download(manager, m)
        XCTAssertTrue(first.settled, "download never returned")
        XCTAssertNotNil(first.error)
        let second = await download(manager, m)
        XCTAssertTrue(second.settled)
        XCTAssertNotNil(second.error, "a retry must not report success without installing anything")
        XCTAssertEqual(StubProtocol.registry.count(m.url!), 2)
    }

    /// A second caller used to return at once, as if the model were installed, while the first was still downloading.
    func testSecondCallerWaitsForTheDownloadInFlight() async throws {
        let (manager, dir) = try makeManager()
        let dest = dir.appendingPathComponent("model.bin")
        let body = Data("hello".utf8)
        let m = model("join", sha256: sha(body))
        StubProtocol.registry.set(m.url!, .init(body: body))
        let a = expectation(description: "first"), b = expectation(description: "second")
        let first = start(manager, m, dest: dest, settled: a)
        let second = start(manager, m, dest: dest, settled: b)
        await fulfillment(of: [a, b], timeout: 5)
        XCTAssertNil(first.error)
        XCTAssertNil(second.error)
        XCTAssertTrue(first.fileExistedOnReturn)
        XCTAssertTrue(second.fileExistedOnReturn)
        XCTAssertEqual(StubProtocol.registry.count(m.url!), 1)
    }

    func testCancelClearsStateWithoutShowingAFailure() async throws {
        let (manager, _) = try makeManager()
        let m = model("cancel")
        let started = expectation(description: "request started")
        StubProtocol.registry.lock.withLock { StubProtocol.registry.started[m.url!] = started }
        StubProtocol.registry.set(m.url!, .init(hang: true))
        var states: [ModelManager.DownloadState?] = []
        let watch = manager.$downloads.sink { states.append($0[m.id]) }
        defer { watch.cancel() }
        let done = expectation(description: "download settles")
        let outcome = start(manager, m, dest: nil, settled: done)
        await fulfillment(of: [started], timeout: 5)
        manager.cancel(m)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(outcome.error is CancellationError)
        XCTAssertNil(manager.downloads[m.id])
        XCTAssertFalse(states.contains { if case .failed = $0 { return true } else { return false } })
    }
}
