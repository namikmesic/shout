import Foundation

/// Monotonic host clock shared by every capture source (mach_absolute_time, the clock behind
/// `AudioTimeStamp.mHostTime` and `AVAudioTime.hostTime`).
public enum MeetingClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func seconds(hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// Host ticks per second.
    public static let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)

    /// The host time of `seconds` on this clock (the inverse of `seconds(hostTime:)`).
    public static func hostTime(seconds: Double) -> UInt64 { UInt64(max(0, seconds * ticksPerSecond).rounded()) }

    public static func now() -> Double { seconds(hostTime: mach_absolute_time()) }
}

/// One source of a meeting recording: an append-only 16 kHz mono Int16 file, kept aligned to the host
/// clock so the microphone and system tracks share one timeline, plus live speech segmentation over
/// exactly the samples that are written.
///
/// Gaps (a source that starts late, the meeting mic paused for dictation, a device switch) are filled
/// with silence, so sample N in one track happened at the same moment as sample N in the other. Silence
/// extends the file sparsely (no data blocks are written for it).
///
/// A failed write (disk full, I/O error) never moves the timeline: the next successful write first fills
/// the lost stretch with silence, so later audio stays at its own position. Segmentation keeps going in
/// the meantime, so the live transcript continues; `stats.writeFailed` reports the failure.
public final class MeetingTrack: @unchecked Sendable {
    public static let sampleRate = 16_000
    /// A chunk arriving more than this late (in samples) is treated as a gap and padded.
    static let gapTolerance = 960 // 60 ms

    public struct Stats: Sendable {
        public var level: Float = 0          // RMS of the latest chunk, 0…1
        public var speaking = false
        /// Any audio (silent or not) arrived this leg.
        public var delivered = false
        public var nonZeroSeen = false       // any non-silent sample this leg
        /// Host time (`MeetingClock`) of the latest chunk with a non-silent sample this leg.
        public var lastNonZeroTime: Double?
        public var zeroRunSeconds: Double = 0
        public var quietSeconds: Double = 0  // consecutive time below −70 dBFS
        /// The latest write or sync of the file failed (disk full, I/O error): audio is not being kept.
        public var writeFailed = false
        public var writeError: String?
    }

    public let source: MeetingSource
    public let url: URL
    /// Called on the track's queue whenever an utterance ends. Set it before the leg begins (before any
    /// audio is appended); the handler must not call back into the track, which would wait on its own queue.
    public var onSegment: ((SpeechSegment) -> Void)?

    private let queue: DispatchQueue
    private let handle: FileHandle
    /// Timeline position: samples placed in this track, whether or not they reached the file.
    private var length: Int
    /// Samples actually in the file (successful writes only).
    private var fileLength: Int
    private var legStartSample = 0
    private var legStartTime: Double = 0
    private var segmenter: SpeechSegmenter
    private var alignNext = true
    private var lastSync = MeetingClock.now()
    private var writeError: Error?
    private var syncError: Error?
    /// Set by `close()`: late audio (a conversion still in flight at Stop) is dropped.
    private var closed = false
    private let statsLock = NSLock()
    private var _stats = Stats()

    public init(source: MeetingSource, url: URL) throws {
        self.source = source
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        let end = try handle.seekToEnd()
        length = Int(end) / 2
        if end % 2 != 0 { try handle.truncate(atOffset: end - 1); length = Int(end - 1) / 2 }
        fileLength = length
        segmenter = SpeechSegmenter(startPosition: length)
        queue = DispatchQueue(label: "shout.scribe.track.\(source.rawValue)", qos: .userInitiated)
    }

    deinit { try? handle.close() }

    public var stats: Stats { statsLock.lock(); defer { statsLock.unlock() }; return _stats }

    /// Timeline length in samples (blocks until queued writes are done). The file holds the same
    /// number of samples unless writes are failing.
    public var sampleCount: Int { queue.sync { length } }

    /// Starts a recording leg: positions from now on are measured from `time`.
    public func beginLeg(at time: Double) {
        queue.sync {
            legStartSample = length
            legStartTime = time
            alignNext = true
            segmenter = SpeechSegmenter(startPosition: length)
            statsLock.lock()
            let failed = _stats.writeFailed, error = _stats.writeError
            _stats = Stats()
            _stats.writeFailed = failed; _stats.writeError = error
            statsLock.unlock()
        }
    }

    /// Track position that corresponds to a host-clock time during the current leg.
    public func position(at time: Double) -> Int {
        queue.sync { expected(at: time) }
    }

    /// The source was restarted: place its next chunk exactly, even if only slightly late.
    public func realign() {
        queue.async { [self] in alignNext = true }
    }

    /// Appends captured audio whose first sample was captured at `time` (host-clock seconds).
    /// Late audio is preceded by silence; audio from a clock running ahead is trimmed back.
    public func append(_ chunk: [Float], at time: Double) {
        queue.async { [self] in
            guard !closed else { return }
            let late = expected(at: time) - length
            var samples = chunk
            if late > Self.gapTolerance || (alignNext && late > 0) { writeSilence(late, segment: true) }
            else if -late > Self.gapTolerance { samples = Array(samples.dropFirst(min(-late, samples.count))) }
            alignNext = false
            write(samples)
            emit(segmenter.process(samples))
            updateStats(samples, time: time)
            if MeetingClock.now() - lastSync > 5 { sync(); lastSync = MeetingClock.now() }
        }
    }

    /// Ends the leg at `time`: pads to that moment, finishes any utterance in progress and syncs the file.
    /// Returns the track length in samples.
    @discardableResult
    public func endLeg(at time: Double) -> Int {
        queue.sync {
            let missing = expected(at: time) - length
            if missing > 0 { writeSilence(missing, segment: true) }
            emit(segmenter.flush())
            sync()
            return length
        }
    }

    /// Pads with silence up to `target` samples (so both tracks of a meeting end at the same position).
    public func pad(toLength target: Int) {
        queue.sync {
            if target > length { writeSilence(target - length, segment: false) }
            sync()
        }
    }

    public func close() {
        queue.sync {
            guard !closed else { return }
            sync()
            closed = true
            try? handle.close()
        }
    }

    /// Free space for meeting audio on the volume holding `url` (nil if unknown).
    public static func availableCapacity(at url: URL) -> Int64? {
        try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    }

    // MARK: Internals (on queue)

    private func expected(at time: Double) -> Int {
        legStartSample + max(0, Int(((time - legStartTime) * Double(Self.sampleRate)).rounded()))
    }

    private func write(_ samples: [Float]) {
        // Closed: nothing moves, so the timeline never runs ahead of the file.
        guard !samples.isEmpty, !closed else { return }
        let start = length
        length += samples.count
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767).littleEndian }
        do {
            // A stretch lost to an earlier failure becomes silence, so this audio lands at its own position.
            try extendFile(to: start)
            try pcm.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
            fileLength = length
            setFailure(write: .some(nil))
        } catch {
            writeFailed(error)
        }
    }

    private func writeSilence(_ count: Int, segment: Bool) {
        guard count > 0, !closed else { return }
        if segment { emit(segmenter.processSilence(count)) }
        length += count
        do { try extendFile(to: length) } catch { writeFailed(error) }
    }

    /// Extends the file with zeros up to `samples` (sparse: no data is written).
    private func extendFile(to samples: Int) throws {
        guard fileLength < samples else { return }
        try handle.truncate(atOffset: UInt64(samples) * 2) // also moves the file pointer to the new end
        fileLength = samples
    }

    private func writeFailed(_ error: Error) {
        // Whatever part of the write landed stays; the next write fills up to its own start first.
        if let end = try? handle.seekToEnd() {
            if end % 2 != 0 { try? handle.truncate(atOffset: end - 1) }
            fileLength = Int(end / 2)
        }
        if writeError == nil { NSLog("Shout: meeting audio (\(source.rawValue)) not saved: \(error.localizedDescription)") }
        setFailure(write: .some(error))
    }

    private func sync() {
        guard !closed else { return }
        do { try handle.synchronize(); setFailure(sync: .some(nil)) } catch { setFailure(sync: .some(error)) }
    }

    /// Updates the write and/or sync error (`.none` leaves one unchanged) and the stats that report them.
    private func setFailure(write: Error?? = .none, sync: Error?? = .none) {
        if let write { writeError = write }
        if let sync { syncError = sync }
        let error = writeError ?? syncError
        statsLock.lock()
        _stats.writeFailed = error != nil
        _stats.writeError = error?.localizedDescription
        statsLock.unlock()
    }

    private func emit(_ segments: [SpeechSegment]) {
        for s in segments { onSegment?(s) }
    }

    private func updateStats(_ x: [Float], time: Double) {
        guard !x.isEmpty else { return }
        var sum: Float = 0, peak: Float = 0
        for s in x { sum += s * s; peak = max(peak, abs(s)) }
        let rms = (sum / Float(x.count)).squareRoot()
        let seconds = Double(x.count) / Double(Self.sampleRate)
        let db = 20 * log10(max(rms, 1e-7))
        statsLock.lock()
        _stats.delivered = true
        _stats.level = max(0, min(1, (db + 60) / 50))
        _stats.speaking = segmenter.isSpeaking
        if peak > 0 { _stats.nonZeroSeen = true; _stats.lastNonZeroTime = time; _stats.zeroRunSeconds = 0 }
        else { _stats.zeroRunSeconds += seconds }
        _stats.quietSeconds = db < -70 ? _stats.quietSeconds + seconds : 0
        statsLock.unlock()
    }

    // MARK: Reading

    /// Reads `count` samples (or to the end) starting at `offset` from a track file.
    public static func read(_ url: URL, offset: Int, count: Int? = nil) throws -> [Float] {
        guard offset >= 0, (count ?? 0) >= 0 else { throw POSIXError(.EINVAL) }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset) * 2)
        let data = try (count.map { try h.read(upToCount: $0 * 2) } ?? h.readToEnd()) ?? Data()
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            // `Data` promises no alignment.
            for i in 0..<n { out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32767 }
        }
        return out
    }

    public static func sampleCount(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attrs?[.size] as? NSNumber)?.intValue ?? 0) / 2
    }

    /// Finds the utterances in a stretch of a track file, from `start` to `end` (default: the end of the
    /// file as it is now). Used to finish transcription after a crash.
    public static func segments(in url: URL, from start: Int, to end: Int? = nil, chunkSeconds: Int = 60) throws -> [SpeechSegment] {
        let total = min(end ?? .max, sampleCount(url))
        guard start < total else { return [] }
        let segmenter = SpeechSegmenter(startPosition: start)
        var out: [SpeechSegment] = []
        var offset = start
        while offset < total {
            let chunk = try read(url, offset: offset, count: min(chunkSeconds * sampleRate, total - offset))
            if chunk.isEmpty { break }
            out.append(contentsOf: segmenter.process(chunk))
            offset += chunk.count
        }
        out.append(contentsOf: segmenter.flush())
        return out
    }
}
