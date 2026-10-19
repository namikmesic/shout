import Foundation
import CryptoKit
import Combine

/// Downloads, verifies and deletes model files. Observable so the UI can show progress.
@MainActor
public final class ModelManager: NSObject, ObservableObject {
    public static let shared = ModelManager()

    public enum DownloadState: Equatable {
        case downloading(progress: Double, bytesPerSecond: Double)
        case verifying
        case failed(String)
    }

    @Published public private(set) var installed: Set<String> = []
    @Published public private(set) var downloads: [String: DownloadState] = [:]

    private var session: URLSession!
    private let modelFile: @Sendable (ModelInfo) -> URL?
    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// The model each task fetches. Whichever delegate callback takes the entry first settles the download:
    /// `didFinishDownloadingTo` when a file arrived, otherwise `didCompleteWithError`.
    private var taskModel: [Int: ModelInfo] = [:]
    private var progressSamples: [String: (date: Date, bytes: Int64)] = [:]
    /// Everyone awaiting a model's download: a second `download` call joins the one in flight.
    private var continuations: [String: [CheckedContinuation<Void, Error>]] = [:]

    override convenience init() {
        self.init(configuration: .default, modelFile: { AppPaths.modelFile($0) })
    }

    /// Tests pass a stub-protocol configuration and a scratch folder.
    init(configuration config: URLSessionConfiguration, modelFile: @escaping @Sendable (ModelInfo) -> URL?) {
        self.modelFile = modelFile
        super.init()
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        refresh()
    }

    public func refresh() {
        var set = Set<String>()
        for m in ModelCatalog.all {
            if let url = modelFile(m), FileManager.default.fileExists(atPath: url.path) {
                set.insert(m.id)
            }
        }
        installed = set
    }

    public func isInstalled(_ model: ModelInfo) -> Bool {
        model.isDownloadable ? installed.contains(model.id) : true
    }

    /// Starts a download (or joins the one in flight) and returns when it has finished and been verified.
    /// Models without a download URL (built in, external server) have nothing to fetch and return at once.
    public func download(_ model: ModelInfo) async throws {
        guard let url = model.url else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuations[model.id, default: []].append(cont)
            guard tasks[model.id] == nil else { return }
            downloads[model.id] = .downloading(progress: 0, bytesPerSecond: 0)
            let task = session.downloadTask(with: url)
            tasks[model.id] = task
            taskModel[task.taskIdentifier] = model
            progressSamples[model.id] = (Date(), 0)
            task.resume()
        }
    }

    public func cancel(_ model: ModelInfo) {
        tasks[model.id]?.cancel()
    }

    /// Deletes a model's file, and its image reader's (no use without it).
    public func delete(_ model: ModelInfo) {
        for m in [model] + [model.imageReader].compactMap({ $0 }) {
            if let url = modelFile(m) { try? FileManager.default.removeItem(at: url) }
        }
        refresh()
    }

    private func finish(_ id: String, error: Error?) {
        if let error, !(error is CancellationError) {
            downloads[id] = .failed(error.localizedDescription)
        } else {
            downloads[id] = nil
        }
        tasks[id] = nil
        progressSamples[id] = nil
        refresh()
        for cont in continuations.removeValue(forKey: id) ?? [] {
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        }
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 8 * 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                       totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            guard let model = taskModel[downloadTask.taskIdentifier] else { return }
            let id = model.id
            let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model.sizeBytes
            var speed: Double = 0
            if case .downloading(_, let s) = downloads[id] { speed = s }
            if let last = progressSamples[id] {
                let dt = Date().timeIntervalSince(last.date)
                if dt > 0.5 {
                    speed = Double(totalBytesWritten - last.bytes) / dt
                    progressSamples[id] = (Date(), totalBytesWritten)
                }
            }
            downloads[id] = .downloading(progress: expected > 0 ? Double(totalBytesWritten) / Double(expected) : 0,
                                         bytesPerSecond: speed)
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                       didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it synchronously.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let moveError: Error?
        do { try FileManager.default.moveItem(at: location, to: staged); moveError = nil } catch { moveError = error }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        MainActor.assumeIsolated {
            // Taking the entry makes this callback (or the verification it starts) the one that finishes the
            // download; `didCompleteWithError` then leaves it alone.
            guard let model = taskModel.removeValue(forKey: downloadTask.taskIdentifier) else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            let id = model.id
            if let moveError { finish(id, error: moveError); return }
            guard (200..<300).contains(status) else {
                try? FileManager.default.removeItem(at: staged)
                finish(id, error: NSError(domain: "Shout", code: status,
                                          userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(status)"]))
                return
            }
            guard let dest = modelFile(model) else {
                try? FileManager.default.removeItem(at: staged)
                finish(id, error: NSError(domain: "Shout", code: 2,
                                          userInfo: [NSLocalizedDescriptionKey: "\(model.name) has no file to install to."]))
                return
            }
            downloads[id] = .verifying
            Task.detached {
                var err: Error?
                if let expected = model.sha256 {
                    do {
                        let actual = try ModelManager.sha256(of: staged)
                        if actual != expected {
                            err = NSError(domain: "Shout", code: 1, userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch; the download was corrupted."])
                        }
                    } catch { err = error }
                }
                if err == nil {
                    do {
                        // Swap rather than delete-then-move, so a failed install keeps the old copy.
                        if FileManager.default.fileExists(atPath: dest.path) {
                            _ = try FileManager.default.replaceItemAt(dest, withItemAt: staged)
                        } else {
                            try FileManager.default.moveItem(at: staged, to: dest)
                        }
                    } catch { err = error }
                }
                if err != nil { try? FileManager.default.removeItem(at: staged) }
                let finalErr = err
                await MainActor.run { self.finish(id, error: finalErr) }
            }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            // Still listed only when no file was handed over: a failure, a cancel, or (never expected) a
            // success without `didFinishDownloadingTo`. Every path resumes the waiting callers.
            guard let model = taskModel.removeValue(forKey: task.taskIdentifier) else { return }
            if let error, (error as NSError).code == NSURLErrorCancelled {
                finish(model.id, error: CancellationError())
            } else {
                finish(model.id, error: error ?? NSError(domain: "Shout", code: 3,
                                                         userInfo: [NSLocalizedDescriptionKey: "The download ended without a file."]))
            }
        }
    }
}
