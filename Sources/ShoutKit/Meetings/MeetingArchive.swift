import Foundation
import AVFoundation

/// A meeting's audio once it is no longer being recorded: one stereo AAC file, `audio.m4a`, with the
/// microphone ("You") on the left and system audio ("Others") on the right, 16 kHz, about 48 kbps
/// (≈ 22 MB per hour instead of 230 MB of raw tracks). Recordings are kept; deleting the meeting deletes
/// its folder.
///
/// - **Archive** (after a leg is transcribed): both raw tracks are encoded to `audio.partial.m4a`, which is
///   synced and verified (length, every frame decodable), renamed to `audio.m4a`, and only then are
///   `mic.pcm`/`system.pcm` deleted: both, and only if neither changed since the encode began. Any failure
///   keeps the raw tracks. An archive is never replaced by a shorter one (that would drop earlier legs).
/// - **Resume**: the raw tracks are recreated at the archive's full length at once (sparse files, so nothing
///   waits) and the archived audio is decoded back into them in the background; `restore.pending` marks
///   that work until it is done. Preparing is idempotent: a second attempt finishes what a failed or
///   interrupted one left.
/// - **Crash recovery**: a stray partial file is deleted, a pending restore is finished, an archive that
///   sits next to both raw tracks is kept only if it verifies, and a raw track missing next to its partner
///   and the archive (a commit cut short between its deletions) is decoded back from the archive before
///   anything is encoded again.
///
/// Sample N of the archive is position N of the meeting timeline (transcript times map directly:
/// frame = ms × 16). `MeetingArchiver` runs this work on one background queue.
public enum MeetingArchive {
    public static let fileName = "audio.m4a"
    static let partialName = "audio.partial.m4a"
    static let restoreMarkerName = "restore.pending"
    static let sampleRate = Double(MeetingTrack.sampleRate)
    /// Requested bit rate; the nearest one the encoder offers at or above it is used.
    public static let targetBitRate = 48_000
    /// The encoder's priming and padding: an archive's length may differ from its source by this much.
    static let lengthTolerance = 2048

    public enum ArchiveError: LocalizedError {
        case encoder(String), verification(String), restore(String)
        public var errorDescription: String? {
            switch self {
            case .encoder(let s): "Could not compress the meeting audio: \(s)"
            case .verification(let s): "The compressed meeting audio did not verify: \(s)"
            case .restore(let s): "Could not restore the meeting audio: \(s)"
            }
        }
    }

    static func trackURL(_ source: MeetingSource, in folder: URL) -> URL {
        folder.appendingPathComponent(source == .mic ? "mic.pcm" : "system.pcm")
    }

    // MARK: Locating audio

    /// Where a meeting's audio is, for playback and reading.
    public struct Files: Sendable, Equatable {
        public enum Source: Sendable, Equatable {
            /// Stereo AAC: channel 0 = You, channel 1 = Others.
            case archive(URL)
            /// The raw 16 kHz mono Int16 tracks (recording, not archived yet, or encoding failed).
            case tracks(mic: URL, system: URL)
        }
        public let folder: URL
        public let archive: URL?
        public let mic: URL?
        public let system: URL?
        /// Raw tracks recreated next to the archive (for a Resume, or one a cut-short commit deleted) whose
        /// archived part is still being decoded back into them; until then they hold silence before
        /// `restoreFrames`, and the archive is the truth there.
        public let restoreSources: Set<MeetingSource>
        public let restoreFrames: Int
        public var restorePending: Bool { !restoreSources.isEmpty }

        /// What to play: the raw tracks when they are complete (they then include the newest leg),
        /// otherwise the archive.
        public var preferred: Source? {
            if let mic, let system, !restorePending { return .tracks(mic: mic, system: system) }
            if let archive { return .archive(archive) }
            if let mic, let system { return .tracks(mic: mic, system: system) }
            return nil
        }
    }

    public static func files(for meetingID: String) -> Files { files(in: AppPaths.meetingFolder(meetingID)) }

    public static func files(in folder: URL) -> Files {
        let fm = FileManager.default
        func existing(_ name: String) -> URL? {
            let url = folder.appendingPathComponent(name)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let pending = pendingRestore(folder)
        return Files(folder: folder, archive: existing(fileName), mic: existing("mic.pcm"), system: existing("system.pcm"),
                     restoreSources: Set(pending?.sources ?? []), restoreFrames: pending?.frames ?? 0)
    }

    /// The meeting's length in samples: the longer of its raw tracks and its archive.
    public static func length(in folder: URL) -> Int {
        let f = files(in: folder)
        let pcm = [f.mic, f.system].compactMap { $0 }.map(MeetingTrack.sampleCount).max() ?? 0
        let archived = f.archive.flatMap { try? AVAudioFile(forReading: $0).length }.map(Int.init) ?? 0
        return max(pcm, archived)
    }

    /// Timeline positions (ms) where recording legs begin: 0 and every Resume. A player can show these
    /// as boundaries on its scrubber.
    public static func legStarts(_ segments: [MeetingSegment]) -> [Int] {
        [0] + segments.filter { $0.marker == .resumed }.map(\.startMs).filter { $0 > 0 }.sorted()
    }

    /// Reads `count` samples of one source starting at `offset` (16 kHz timeline positions), from the raw
    /// track where it holds them, else from the archive. Missing audio reads as silence; reading stops at
    /// the end of the longer of the two.
    public static func read(_ source: MeetingSource, in folder: URL, offset: Int, count: Int) throws -> [Float] {
        let f = files(in: folder)
        let pcm = source == .mic ? f.mic : f.system
        let pcmCount = pcm.map(MeetingTrack.sampleCount) ?? 0
        let archiveFrames = f.archive.flatMap { try? AVAudioFile(forReading: $0).length }.map(Int.init) ?? 0
        let end = min(offset + count, max(pcmCount, archiveFrames))
        guard end > offset else { return [] }
        // The raw track is the truth from `pcmFrom` on; before that (no raw track, or a part still
        // waiting to be restored) the archive is.
        let pcmFrom = pcm == nil ? end : (f.restoreSources.contains(source) ? f.restoreFrames : 0)
        var out = [Float](repeating: 0, count: end - offset)
        if let archive = f.archive, offset < min(end, pcmFrom) {
            let samples = try readArchive(archive, channel: source == .mic ? 0 : 1, offset: offset, count: min(end, pcmFrom) - offset)
            for i in 0..<samples.count { out[i] = samples[i] }
        }
        let from = max(offset, pcmFrom)
        if let pcm, from < min(end, pcmCount) {
            let samples = try MeetingTrack.read(pcm, offset: from, count: min(end, pcmCount) - from)
            for i in 0..<samples.count { out[from - offset + i] = samples[i] }
        }
        return out
    }

    static func readArchive(_ url: URL, channel: Int, offset: Int, count: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard offset < Int(file.length), count > 0 else { return [] }
        file.framePosition = AVAudioFramePosition(offset)
        let total = min(count, Int(file.length) - offset)
        var out = [Float]()
        out.reserveCapacity(total)
        let block = 16_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)) else { return [] }
        while out.count < total {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(block, total - out.count)))
            guard buffer.frameLength > 0, let ch = buffer.floatChannelData else { break }
            let c = min(channel, Int(buffer.format.channelCount) - 1)
            out.append(contentsOf: UnsafeBufferPointer(start: ch[c], count: Int(buffer.frameLength)))
        }
        return out
    }

    // MARK: Encoding

    /// What an encode read, so the commit can tell whether the raw tracks changed since.
    struct Encoded {
        let folder: URL
        let partial: URL
        let frames: Int
        let snapshots: [URL: FileSnapshot]
        /// May replace a longer archive (the end of the audio was cut on purpose).
        let replacingLonger: Bool
    }

    struct FileSnapshot: Equatable {
        let size: Int
        let modified: Date
        init?(_ url: URL) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (a[.size] as? NSNumber)?.intValue, let modified = a[.modificationDate] as? Date else { return nil }
            self.size = size; self.modified = modified
        }
    }

    /// Encodes the raw tracks to the partial file and verifies it. Returns nil when there is nothing to
    /// encode. Throws `CancellationError` as soon as `isCancelled` turns true (the partial file is removed).
    /// Refuses a folder where one raw track is missing next to the archive: that channel exists only in the
    /// archive and must be decoded back first (`prepareTracks`, `restore`), never encoded as silence.
    static func encode(folder: URL, isCancelled: () -> Bool = { false }, replacingLonger: Bool = false) throws -> Encoded? {
        let mic = trackURL(.mic, in: folder), system = trackURL(.system, in: folder)
        let fm = FileManager.default
        // The archived part of a resumed meeting must be back in the raw tracks before they replace it.
        if pendingRestore(folder) != nil { try restore(folder: folder) }
        let sources = [mic, system].filter { fm.fileExists(atPath: $0.path) }
        guard !sources.isEmpty else { return nil }
        if sources.count == 1, fm.fileExists(atPath: folder.appendingPathComponent(fileName).path) {
            throw ArchiveError.encoder("a raw track is missing next to the archive")
        }
        var snapshots: [URL: FileSnapshot] = [:]
        for url in sources { snapshots[url] = FileSnapshot(url) }
        let frames = sources.map(MeetingTrack.sampleCount).max() ?? 0
        guard frames > 0 else { return nil }

        let partial = folder.appendingPathComponent(partialName)
        try? fm.removeItem(at: partial)
        do {
            try write(partial, mic: mic, system: system, frames: frames, isCancelled: isCancelled)
            fullSync(partial)
            try verify(partial, expectedFrames: frames)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        return Encoded(folder: folder, partial: partial, frames: frames, snapshots: snapshots, replacingLonger: replacingLonger)
    }

    private static func write(_ url: URL, mic: URL, system: URL, frames: Int, isCancelled: () -> Bool) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)
        else { throw ArchiveError.encoder("no stereo format") }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: bitRate(from: format),
        ]
        let readers = [try PCMReader(mic), try PCMReader(system)]
        let block = 16_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block)),
              let channels = buffer.floatChannelData else { throw ArchiveError.encoder("no buffer") }
        // The file is finalised when it is released (AVAudioFile has no close() before macOS 15).
        try autoreleasepool {
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch { throw ArchiveError.encoder(error.localizedDescription) }
            var done = 0
            while done < frames {
                if isCancelled() { throw CancellationError() }
                let n = min(block, frames - done)
                do {
                    for (c, reader) in readers.enumerated() { try reader.read(into: channels[c], count: n) }
                } catch { throw ArchiveError.encoder("reading the raw tracks: \(error.localizedDescription)") }
                buffer.frameLength = AVAudioFrameCount(n)
                do { try file.write(from: buffer) } catch { throw ArchiveError.encoder(error.localizedDescription) }
                done += n
            }
            if #available(macOS 15.0, *) { file.close() }
        }
    }

    /// The encoder's bit rate nearest to `targetBitRate` from above (or its highest).
    static func bitRate(from pcm: AVAudioFormat) -> Int {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let aac = AVAudioFormat(streamDescription: &asbd), let converter = AVAudioConverter(from: pcm, to: aac),
              let rates = converter.applicableEncodeBitRates?.map(\.intValue), let highest = rates.max()
        else { return targetBitRate }
        return rates.filter { $0 >= targetBitRate }.min() ?? highest
    }

    /// Opens the archive, checks its length against `expectedFrames` (± the encoder's priming and padding)
    /// and decodes all of it (a damaged stretch in the middle must not pass before the raw tracks are
    /// deleted). Returns its length in frames.
    @discardableResult
    static func verify(_ url: URL, expectedFrames: Int? = nil) throws -> Int {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw ArchiveError.verification(error.localizedDescription) }
        let length = Int(file.length)
        guard file.processingFormat.channelCount == 2, length > 0 else { throw ArchiveError.verification("empty or not stereo") }
        if let expectedFrames, abs(length - expectedFrames) > lengthTolerance {
            throw ArchiveError.verification("\(length) frames instead of \(expectedFrames)")
        }
        let block = 16_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)) else {
            throw ArchiveError.verification("no buffer")
        }
        var decoded = 0
        while decoded < length {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(block, length - decoded))) } catch {
                throw ArchiveError.verification("at frame \(decoded): \(error.localizedDescription)")
            }
            guard buffer.frameLength > 0 else { break }
            decoded += Int(buffer.frameLength)
        }
        guard decoded == length else { throw ArchiveError.verification("decoded \(decoded) of \(length) frames") }
        return length
    }

    /// Makes the verified archive the meeting's audio (rename, then a full sync of the folder). Refuses to
    /// replace a longer archive unless the encode was asked to: that would drop earlier legs (the partial
    /// file is removed and the raw tracks stay).
    static func install(_ e: Encoded) throws {
        let final = e.folder.appendingPathComponent(fileName)
        if !e.replacingLonger, let existing = try? AVAudioFile(forReading: final).length,
           Int(existing) > e.frames + lengthTolerance {
            discard(e)
            throw ArchiveError.verification("\(e.frames) frames would replace an archive of \(existing)")
        }
        guard rename(e.partial.path, final.path) == 0 else {
            let error = ArchiveError.encoder(String(cString: strerror(errno)))
            discard(e)
            throw error
        }
        fullSync(e.folder)
    }

    /// Deletes the raw tracks the archive was made from: all of them, and only if none changed since the
    /// encode began. (A crash between the two deletions leaves one; its partner then exists only in the
    /// archive, and `MeetingArchiver` decodes it back before encoding again.)
    static func deleteTracks(_ e: Encoded) {
        guard e.snapshots.allSatisfy({ FileSnapshot($0.key) == $0.value }) else { return }
        for url in e.snapshots.keys { try? FileManager.default.removeItem(at: url) }
    }

    /// `install`, then `deleteTracks`.
    static func commit(_ e: Encoded) throws {
        try install(e)
        deleteTracks(e)
    }

    static func discard(_ e: Encoded) { try? FileManager.default.removeItem(at: e.partial) }

    // MARK: Resume

    /// The marker of a restore still to do: how many frames of which tracks come from the archive.
    struct PendingRestore: Equatable {
        var frames: Int
        var sources: [MeetingSource]

        var text: String { "\(frames)\n" + sources.map(\.rawValue).joined(separator: ",") }

        init(frames: Int, sources: [MeetingSource]) { self.frames = frames; self.sources = sources }

        /// A marker with only a frame count (written before tracks were named) means both tracks.
        init?(text: String) {
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = lines.first, let frames = Int(first) else { return nil }
            let named = lines.dropFirst().first.map {
                $0.split(separator: ",").compactMap { MeetingSource(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
                    .filter { $0 != .marker }
            } ?? []
            self.frames = frames
            sources = named.isEmpty ? [.mic, .system] : named
        }
    }

    static func pendingRestore(_ folder: URL) -> PendingRestore? {
        (try? String(contentsOf: folder.appendingPathComponent(restoreMarkerName), encoding: .utf8)).flatMap(PendingRestore.init(text:))
    }

    static func restoreFrames(_ folder: URL) -> Int? { pendingRestore(folder)?.frames }

    /// Before recording into the folder again, or encoding it: if raw tracks were archived (both, or one a
    /// cut-short commit deleted), recreates them at the archive's full length (sparse, instant) and leaves
    /// `restore.pending` for `restore`, naming the tracks to decode back. Returns whether a restore is
    /// needed. Idempotent: with the marker already there it still makes sure both tracks exist and reach
    /// its length, so recording never starts at position 0 over the archived legs. Throws if the tracks
    /// could not be prepared (recording must not start then).
    @discardableResult
    static func prepareTracks(folder: URL) throws -> Bool {
        let fm = FileManager.default
        let marker = folder.appendingPathComponent(restoreMarkerName)
        let pending: PendingRestore
        if let existing = pendingRestore(folder) {
            pending = existing
        } else {
            let archive = folder.appendingPathComponent(fileName)
            let missing = [MeetingSource.mic, .system].filter { !fm.fileExists(atPath: trackURL($0, in: folder).path) }
            guard fm.fileExists(atPath: archive.path), !missing.isEmpty else { return false }
            let frames: Int
            do { frames = Int(try AVAudioFile(forReading: archive).length) } catch { throw ArchiveError.restore(error.localizedDescription) }
            pending = PendingRestore(frames: frames, sources: missing)
            // Marker first, on disk before the tracks grow: a crash (or power loss) after this point still
            // restores, instead of leaving full-length silent tracks that the next encode would archive.
            do { try pending.text.write(to: marker, atomically: true, encoding: .utf8) } catch {
                throw ArchiveError.restore(error.localizedDescription)
            }
            // A barrier, not a full flush: this runs on the main thread, and the order is what matters.
            barrierSync(marker)
            barrierSync(folder)
        }
        for source in [MeetingSource.mic, .system] { try extend(trackURL(source, in: folder), toFrames: pending.frames) }
        return true
    }

    /// The folder's only raw track sits next to the archive (a commit cut short between its deletions), or
    /// a restore is pending: prepares the tracks (`prepareTracks`) so the archive's copy is decoded back
    /// before the next encode. Returns whether a restore is needed.
    static func prepareMissingTrack(folder: URL) throws -> Bool {
        let fm = FileManager.default
        let present = [MeetingSource.mic, .system].filter { fm.fileExists(atPath: trackURL($0, in: folder).path) }
        guard present.count == 1 || pendingRestore(folder) != nil else { return false }
        return try prepareTracks(folder: folder)
    }

    /// Decodes the archive back into the first frames of the tracks the marker names (recording may be
    /// appending after them meanwhile), then removes the marker.
    static func restore(folder: URL) throws {
        guard let pending = pendingRestore(folder) else { return }
        let marker = folder.appendingPathComponent(restoreMarkerName)
        let archive = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            // Nothing left to restore from: the raw tracks (silent before `frames`) are all there is.
            try? FileManager.default.removeItem(at: marker)
            throw ArchiveError.restore("the archive is missing")
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: archive) } catch { throw ArchiveError.restore(error.localizedDescription) }
        let total = min(pending.frames, Int(file.length))
        let targets = try pending.sources.map { source in
            (channel: source == .mic ? 0 : 1, handle: try FileHandle(forUpdating: trackURL(source, in: folder)))
        }
        defer { targets.forEach { try? $0.handle.close() } }
        let block = 16_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block)) else {
            throw ArchiveError.restore("no buffer")
        }
        var done = 0
        var pcm = [Int16](repeating: 0, count: block)
        while done < total {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(min(block, total - done))) } catch {
                throw ArchiveError.restore(error.localizedDescription)
            }
            let n = Int(buffer.frameLength)
            guard n > 0, let ch = buffer.floatChannelData else { break }
            for (c, h) in targets {
                let src = ch[min(c, Int(buffer.format.channelCount) - 1)]
                for i in 0..<n { pcm[i] = Int16(max(-1, min(1, src[i])) * 32767).littleEndian }
                try h.seek(toOffset: UInt64(done) * 2)
                try pcm.withUnsafeBytes { try h.write(contentsOf: Data($0.prefix(n * 2))) }
            }
            done += n
        }
        // The marker goes only when everything it names is back and on disk: otherwise the next encode would
        // archive the silence in its place.
        guard done >= total else { throw ArchiveError.restore("decoded \(done) of \(total) frames") }
        for (_, h) in targets {
            try h.synchronize()
            if fcntl(h.fileDescriptor, F_FULLFSYNC) != 0 { fsync(h.fileDescriptor) }
        }
        try FileManager.default.removeItem(at: marker)
    }

    /// Cuts a raw track back to `frames` (if it is longer).
    static func truncate(_ url: URL, toFrames frames: Int) throws {
        guard FileManager.default.fileExists(atPath: url.path), MeetingTrack.sampleCount(url) > frames else { return }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: UInt64(max(0, frames)) * 2)
    }

    /// A cut (`MeetingArchiver.trim`) applied before recording into the folder again: the raw tracks go
    /// back to `frames`. Throws, changing nothing, when audio past `frames` is also in the archive (or due
    /// from it in a pending restore): only the trim, which rewrites the archive, can remove it.
    static func cutTracks(folder: URL, toFrames frames: Int) throws {
        let archived = (try? AVAudioFile(forReading: folder.appendingPathComponent(fileName)).length).map(Int.init) ?? 0
        if archived > frames + lengthTolerance || (pendingRestore(folder)?.frames ?? 0) > frames {
            throw ArchiveError.restore("the discarded audio is still being removed from the archive")
        }
        for source in [MeetingSource.mic, .system] { try truncate(trackURL(source, in: folder), toFrames: frames) }
    }

    // MARK: Crash recovery

    /// Cleans up what an interrupted encode or restore left in the folder. An archive next to both raw
    /// tracks is kept only if it verifies (they are the truth); next to one, it is kept (it holds the other
    /// track's only copy). Returns whether raw tracks remain to be archived.
    @discardableResult
    static func recover(folder: URL) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: folder.appendingPathComponent(partialName))
        if pendingRestore(folder) != nil {
            do { try restore(folder: folder) } catch { NSLog("Shout: \(error.localizedDescription) (\(folder.lastPathComponent))") }
        }
        let f = files(in: folder)
        if let archive = f.archive, f.mic != nil, f.system != nil, !f.restorePending {
            if (try? verify(archive)) == nil { try? fm.removeItem(at: archive) }
        }
        return f.mic != nil || f.system != nil
    }

    // MARK: Helpers

    /// Creates a raw track if it is missing (never truncating one that exists, which may be recording) and
    /// grows it with sparse zeros to `frames`.
    static func extend(_ url: URL, toFrames frames: Int) throws {
        func failure() -> ArchiveError { .restore("\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        let fd = open(url.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw failure() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw failure() }
        let bytes = off_t(frames) * 2
        if info.st_size < bytes, ftruncate(fd, bytes) != 0 { throw failure() }
    }

    /// Flushes a file (or folder) to permanent storage.
    static func fullSync(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        close(fd)
    }

    /// Writes before this reach the disk before writes after it (much cheaper than `fullSync`).
    static func barrierSync(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        if fcntl(fd, F_BARRIERFSYNC) != 0 { fsync(fd) }
        close(fd)
    }

    /// Reads a raw track in blocks as Float; past its end (or if it is missing) reads silence. A track that
    /// is there but can't be opened, and a read error, throw, so the encode fails and the raw tracks are
    /// kept rather than archived with a gap.
    final class PCMReader {
        private let handle: FileHandle?
        init(_ url: URL) throws {
            let fd = open(url.path, O_RDONLY)
            if fd >= 0 {
                handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            } else {
                let error = errno
                // Only a track that doesn't exist is silence (permissions, I/O errors are not).
                guard error == ENOENT else { throw ArchiveError.encoder("\(url.lastPathComponent): \(String(cString: strerror(error)))") }
                handle = nil
            }
        }
        deinit { try? handle?.close() }

        func read(into out: UnsafeMutablePointer<Float>, count: Int) throws {
            try Self.read(into: out, count: count) { [handle] in try handle?.read(upToCount: $0) }
        }

        /// Fills `count` samples from `next(bytes)`, asking again for what a short read left out until it
        /// returns nothing (the end), so a short or odd-sized read never shifts the rest of the track.
        static func read(into out: UnsafeMutablePointer<Float>, count: Int, next: (Int) throws -> Data?) rethrows {
            var data = try next(count * 2) ?? Data()
            while data.count < count * 2, let more = try next(count * 2 - data.count), !more.isEmpty { data.append(more) }
            let n = data.count / 2 // an odd last byte can only be the end of the file
            data.withUnsafeBytes { raw in
                for i in 0..<n { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32767 }
            }
            for i in n..<count { out[i] = 0 }
        }
    }
}

/// Runs archive work for every meeting on one background queue, and keeps it away from folders that are
/// being recorded.
public final class MeetingArchiver: @unchecked Sendable {
    public static let shared = MeetingArchiver()

    private let queue = DispatchQueue(label: "shout.scribe.archive", qos: .utility)
    private let lock = NSLock()
    /// Bumped whenever recording into a folder begins (or its audio is cut): queued or running encodes of
    /// it give up.
    private var generations: [String: Int] = [:]
    private var recording: Set<String> = []
    /// Cuts (`trim`) not finished yet, by folder: the frames to keep. Recording into the folder applies the
    /// cut first, since it cancels the trim.
    private var cuts: [String: Int] = [:]

    public init() {}

    /// Before recording into `folder` (a new meeting, or Resume): stops any encode of it and, if its raw
    /// tracks were archived, recreates them at once (the archived audio is decoded back into them in the
    /// background). A discarded leg whose `trim` hasn't finished is cut from the raw tracks first, so
    /// recording never starts after it. Returns quickly; call before opening the tracks.
    ///
    /// Returns false when the tracks could not be prepared: recording must not start then (it would begin
    /// at position 0, over the archived legs). The folder is then left as it was before the call (an
    /// archive this cancelled is queued again). Also false while a discarded leg is still being removed
    /// from the archive (the trim goes on; try again once it is done).
    @discardableResult
    public func prepareForRecording(folder: URL) -> Bool {
        let key = folder.standardizedFileURL.path
        let (prepared, generation, requeue): (Result<Bool, Error>, Int, Bool) = lock.withLock {
            if let frames = cuts[key] {
                // Before the generation changes: if the cut can't be made here, the trim must go on.
                do { try MeetingArchive.cutTracks(folder: folder, toFrames: frames) } catch {
                    return (.failure(error), generations[key, default: 0], false)
                }
                cuts[key] = nil
            }
            generations[key, default: 0] += 1
            let wasIdle = recording.insert(key).inserted
            let result = Result { try MeetingArchive.prepareTracks(folder: folder) }
            if case .failure = result, wasIdle { recording.remove(key) }
            return (result, generations[key, default: 0], wasIdle)
        }
        switch prepared {
        case .success(let restore):
            if restore {
                queue.async {
                    do { try MeetingArchive.restore(folder: folder) } catch { NSLog("Shout: \(error.localizedDescription)") }
                }
            }
            return true
        case .failure(let error):
            NSLog("Shout: could not prepare the meeting audio for recording (\(folder.lastPathComponent)): \(error.localizedDescription)")
            if requeue { queue.async { [self] in _ = encodeAndCommit(folder: folder, key: key, generation: generation) } }
            return false
        }
    }

    /// Compresses the folder's raw tracks into `audio.m4a` once its recording has stopped and its audio is
    /// transcribed. Recording into the folder again cancels it. `completion` (on the archiver's queue)
    /// gets the archive's length in frames, nil when there was nothing to do, or the error (the raw tracks
    /// are then kept).
    public func archive(folder: URL, completion: (@Sendable (Result<Int?, Error>) -> Void)? = nil) {
        let key = folder.standardizedFileURL.path
        let generation: Int = lock.withLock {
            recording.remove(key)
            return generations[key, default: 0]
        }
        queue.async { [self] in
            let result = encodeAndCommit(folder: folder, key: key, generation: generation)
            completion?(result)
        }
    }

    /// Cuts the folder's audio back to its first `frames` samples (a discarded resumed leg), whether that
    /// audio is still in the raw tracks or was compressed already, then compresses it again. Like
    /// `archive`, this ends the folder's recording. `completion` (on the archiver's queue) gets the error,
    /// if any (the audio is then left as it was, or in raw tracks; `CancellationError` when recording into
    /// the folder began again meanwhile: `prepareForRecording` made the cut then).
    public func trim(folder: URL, toFrames frames: Int, completion: (@Sendable (Error?) -> Void)? = nil) {
        let key = folder.standardizedFileURL.path
        // A queued or running encode would commit the audio being cut.
        let generation: Int = lock.withLock {
            recording.remove(key)
            generations[key, default: 0] += 1
            cuts[key] = frames
            return generations[key, default: 0]
        }
        queue.async { [self] in
            let current = { self.generations[key, default: 0] == generation && !self.recording.contains(key) }
            var failure: Error?
            do {
                // Compressed already: the raw tracks come back first, as for a Resume.
                let restore: Bool = try lock.withLock {
                    guard current() else { throw CancellationError() }
                    return try MeetingArchive.prepareTracks(folder: folder)
                }
                if restore { try MeetingArchive.restore(folder: folder) }
                try lock.withLock {
                    guard current() else { throw CancellationError() }
                    for source in [MeetingSource.mic, .system] {
                        try MeetingArchive.truncate(MeetingArchive.trackURL(source, in: folder), toFrames: frames)
                    }
                }
                if case .failure(let error) = encodeAndCommit(folder: folder, key: key, generation: generation, replacingLonger: true) {
                    throw error
                }
            } catch is CancellationError {
                failure = CancellationError() // recording into the folder began again
            } catch {
                NSLog("Shout: could not cut the meeting audio (\(folder.lastPathComponent)): \(error.localizedDescription)")
                failure = error
            }
            // Done (or failed): a later recording no longer has this cut to make or wait for.
            lock.withLock { if generations[key, default: 0] == generation { cuts[key] = nil } }
            completion?(failure)
        }
    }

    /// At launch: cleans up after interrupted work in every meeting folder and archives idle meetings that
    /// still have raw tracks. `skipping` are meetings that are recording or still being transcribed; they
    /// are archived when their transcription finishes.
    public func recoverAll(skipping ids: Set<String> = [], in root: URL = AppPaths.meetings) {
        queue.async { [self] in
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let key = folder.standardizedFileURL.path
                guard !lock.withLock({ recording.contains(key) }) else { continue }
                // Safe even if recording starts meanwhile: it only restores the archived part of the tracks
                // and drops partial files, and this queue is the only one that writes those.
                let hasTracks = MeetingArchive.recover(folder: folder)
                guard hasTracks, !ids.contains(folder.lastPathComponent) else { continue }
                let generation: Int? = lock.withLock { recording.contains(key) ? nil : generations[key, default: 0] }
                // Here, not queued again: `waitUntilIdle` then also waits for these.
                if let generation { _ = encodeAndCommit(folder: folder, key: key, generation: generation) }
            }
        }
    }

    /// On `queue`. Gives up as soon as recording into the folder begins (or began again) after `generation`.
    private func encodeAndCommit(folder: URL, key: String, generation: Int, replacingLonger: Bool = false) -> Result<Int?, Error> {
        // `current` reads the archiver's state: call it with `lock` held. (This function takes the lock itself:
        // call it without.)
        let current = { self.generations[key, default: 0] == generation && !self.recording.contains(key) }
        let cancelled = { self.lock.withLock { !current() } }
        let result = Result<Int?, Error> {
            // A raw track missing next to the archive is decoded back from it first, so the encode never
            // writes that channel as silence over the archive. Prepared under the lock: no recording can
            // begin meanwhile.
            let restore: Bool = try lock.withLock {
                guard current() else { throw CancellationError() }
                return try MeetingArchive.prepareMissingTrack(folder: folder)
            }
            if restore { try MeetingArchive.restore(folder: folder) }
            guard !cancelled(),
                  let encoded = try MeetingArchive.encode(folder: folder, isCancelled: cancelled, replacingLonger: replacingLonger)
            else { return nil }
            guard !cancelled() else {
                MeetingArchive.discard(encoded)
                throw CancellationError()
            }
            // Renamed and synced outside the lock, which a meeting start waits on. A recording that begins
            // meanwhile finds both raw tracks, so it restores nothing and appends to them.
            try MeetingArchive.install(encoded)
            lock.withLock {
                // Checked again under the lock that `prepareForRecording` takes, so raw tracks are never
                // deleted from under a recording that has just begun.
                if current() { MeetingArchive.deleteTracks(encoded) }
            }
            return encoded.frames
        }
        if case .failure(let error) = result, !(error is CancellationError) {
            NSLog("Shout: meeting audio kept uncompressed (\(folder.lastPathComponent)): \(error.localizedDescription)")
        }
        return result
    }

    /// Runs after everything queued so far (tests, shutdown).
    public func waitUntilIdle() { queue.sync {} }
}
