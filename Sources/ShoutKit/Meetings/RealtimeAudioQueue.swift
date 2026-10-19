import Foundation
import Darwin

/// Hands captured audio from a real-time IO thread to a worker queue without locks, allocation or
/// dispatch on the IO thread.
///
/// A fixed pool of blocks moves between two lock-free stacks (libkern `OSAtomicEnqueue`/`OSAtomicDequeue`):
/// the producer takes a free block, copies the samples and their timing in, and pushes it on `filled`;
/// the worker pops everything filled, restores capture order by sequence number, hands each chunk on
/// and recycles the block. When no block is free the audio is dropped and counted, never waited for.
///
/// Callbacks are packed: audio that continues the block being filled (same stream, next in time) goes into
/// it, and the block is handed on once it holds `publishSeconds` of audio or is full. So every block holds
/// at least that much unless the stream breaks, and the pool holds `guaranteedSeconds` whatever the
/// callback size (an IO cycle of 128 frames would otherwise take a whole block).
///
/// One producer at a time (an IO callback) and one consumer at a time (a serial queue).
public final class RealtimeAudioQueue: @unchecked Sendable {
    public struct Chunk {
        /// Valid only inside the `drain` callback.
        public let samples: UnsafeBufferPointer<Float>
        /// Host time (mach ticks) of the callback the chunk's first sample came from.
        public let hostTime: UInt64
        /// Frames between `hostTime` and the first sample (a long callback is split over blocks).
        public let frameOffset: Int
        public let sampleRate: Double
        /// The producer's build or session; a change means the stream restarted.
        public let generation: Int
        /// Frames lost just before this chunk because the pool was empty.
        public let dropped: Int

        /// Host-clock seconds of the first sample (`MeetingClock`).
        public var time: Double {
            MeetingClock.seconds(hostTime: hostTime) + (sampleRate > 0 ? Double(frameOffset) / sampleRate : 0)
        }
    }

    /// Block header; the link used by the lock-free stacks must come first (offset 0).
    private struct Header {
        var link: UnsafeMutableRawPointer?
        var seq: UInt64
        var hostTime: UInt64
        var frameOffset: Int
        var sampleRate: Double
        var generation: Int
        var frames: Int
        var dropped: Int
    }

    public let framesPerBlock: Int
    public let blockCount: Int
    /// A block is handed on once it holds this much audio (or is full, or the stream breaks).
    public let publishSeconds: Double
    private let free: OpaquePointer
    private let filled: OpaquePointer
    private let heads: UnsafeMutableRawPointer
    private let blocks: [UnsafeMutableRawPointer]
    private static let samplesOffset = (MemoryLayout<Header>.stride + 15) & ~15
    /// Read on the IO thread, so computed up front (no lazy statics there).
    private let ticksPerSecond = MeetingClock.ticksPerSecond
    /// A callback starting within this of where the previous one ended continues it.
    private let continuityTicks = UInt64(MeetingClock.ticksPerSecond / 1000)

    // Producer only.
    private var seq: UInt64 = 0
    private var droppedFrames = 0
    /// The block being filled (not on either stack), and the host time at which audio continuing it starts.
    private var open: UnsafeMutableRawPointer?
    private var openNext: UInt64 = 0
    // Consumer only.
    private var batch: [UnsafeMutableRawPointer] = []

    /// The defaults hold at least 2.5 s for the worker at any rate up to 204 kHz and any callback size
    /// (2 MB, touched up front so the IO thread never faults a page in).
    public init(blocks count: Int = 256, framesPerBlock: Int = 2048, publishSeconds: Double = 0.01) {
        // Checked here rather than found out on the IO thread.
        precondition(count > 0 && framesPerBlock > 0 && publishSeconds >= 0, "RealtimeAudioQueue: invalid sizes")
        self.framesPerBlock = framesPerBlock
        self.blockCount = count
        self.publishSeconds = publishSeconds
        // Two queue heads (16 bytes each, 16-byte aligned, zeroed = OS_ATOMIC_QUEUE_INIT).
        heads = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 16)
        heads.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
        free = OpaquePointer(heads)
        filled = OpaquePointer(heads + 16)
        let size = Self.samplesOffset + framesPerBlock * MemoryLayout<Float>.stride
        blocks = (0..<count).map { _ in
            let b = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            b.initializeMemory(as: UInt8.self, repeating: 0, count: Self.samplesOffset)
            (b + Self.samplesOffset).initializeMemory(as: Float.self, repeating: 0, count: framesPerBlock)
            return b
        }
        batch.reserveCapacity(count)
        for b in blocks { OSAtomicEnqueue(free, b, 0) }
    }

    deinit {
        for b in blocks { b.deallocate() }
        heads.deallocate()
    }

    /// How much audio at `sampleRate` the pool holds for the worker at least, before anything is dropped,
    /// for any callback size (one block may be the producer's, still being filled).
    public func guaranteedSeconds(sampleRate: Double) -> Double {
        Double(blockCount - 1) * min(publishSeconds, Double(framesPerBlock) / sampleRate)
    }

    /// IO thread: queues `count` samples captured at `hostTime`. Returns false if some were dropped.
    /// A `count` of 0 queues an empty chunk (a heartbeat for a callback whose audio was unusable). Nil
    /// `samples` with a count queues silence.
    @discardableResult
    public func push(_ samples: UnsafePointer<Float>?, count: Int, hostTime: UInt64, sampleRate: Double, generation: Int) -> Bool {
        if let block = open {
            let h = block.load(as: Header.self)
            if count <= 0 || h.generation != generation || h.sampleRate != sampleRate || !continues(at: hostTime) {
                publishOpen()
            }
        }
        guard count > 0 else {
            guard let block = OSAtomicDequeue(free, 0) else { return false }
            begin(block, hostTime: hostTime, frameOffset: 0, sampleRate: sampleRate, generation: generation)
            publish(block)
            return true
        }
        var offset = 0
        while offset < count {
            let block: UnsafeMutableRawPointer
            if let current = open {
                block = current
            } else {
                guard let fresh = OSAtomicDequeue(free, 0) else {
                    droppedFrames += count - offset
                    return false
                }
                begin(fresh, hostTime: hostTime, frameOffset: offset, sampleRate: sampleRate, generation: generation)
                open = fresh
                block = fresh
            }
            var h = block.load(as: Header.self)
            let n = min(framesPerBlock - h.frames, count - offset)
            let destination = (block + Self.samplesOffset).assumingMemoryBound(to: Float.self) + h.frames
            if let samples { destination.update(from: samples + offset, count: n) }
            else { destination.update(repeating: 0, count: n) }
            h.frames += n
            block.storeBytes(of: h, as: Header.self)
            offset += n
            if h.frames == framesPerBlock { publishOpen() }
        }
        if let block = open {
            if block.load(as: Header.self).frames >= publishFrames(sampleRate) { publishOpen() }
            else { openNext = hostTime &+ ticks(frames: count, sampleRate: sampleRate) }
        }
        return true
    }

    /// Worker: hands every queued chunk to `body` in capture order and recycles it. Returns the number
    /// of chunks.
    @discardableResult
    public func drain(_ body: (Chunk) -> Void) -> Int {
        batch.removeAll(keepingCapacity: true)
        while let block = OSAtomicDequeue(filled, 0) { batch.append(block) }
        guard !batch.isEmpty else { return 0 }
        // The stack pops newest first; everything pushed later is newer than all of this batch.
        batch.sort { $0.load(as: Header.self).seq < $1.load(as: Header.self).seq }
        for block in batch {
            let h = block.load(as: Header.self)
            let samples = UnsafeBufferPointer(start: (block + Self.samplesOffset).assumingMemoryBound(to: Float.self), count: h.frames)
            body(Chunk(samples: samples, hostTime: h.hostTime, frameOffset: h.frameOffset, sampleRate: h.sampleRate,
                       generation: h.generation, dropped: h.dropped))
            OSAtomicEnqueue(free, block, 0)
        }
        return batch.count
    }

    // MARK: Producer internals

    private func begin(_ block: UnsafeMutableRawPointer, hostTime: UInt64, frameOffset: Int, sampleRate: Double, generation: Int) {
        block.storeBytes(of: Header(link: nil, seq: 0, hostTime: hostTime, frameOffset: frameOffset, sampleRate: sampleRate,
                                    generation: generation, frames: 0, dropped: droppedFrames), as: Header.self)
        droppedFrames = 0
    }

    private func publish(_ block: UnsafeMutableRawPointer) {
        seq &+= 1
        var h = block.load(as: Header.self)
        h.seq = seq
        block.storeBytes(of: h, as: Header.self)
        OSAtomicEnqueue(filled, block, 0)
    }

    private func publishOpen() {
        guard let block = open else { return }
        open = nil
        publish(block)
    }

    private func continues(at hostTime: UInt64) -> Bool {
        (hostTime > openNext ? hostTime - openNext : openNext - hostTime) <= continuityTicks
    }

    // Both clamp in Double first: converting a non-finite or out-of-range value traps, here on the IO thread.
    private func publishFrames(_ sampleRate: Double) -> Int {
        guard sampleRate > 0, sampleRate.isFinite else { return 1 }
        return max(1, Int(min(Double(framesPerBlock), sampleRate * publishSeconds)))
    }

    private func ticks(frames: Int, sampleRate: Double) -> UInt64 {
        let t = sampleRate > 0 ? Double(frames) / sampleRate * ticksPerSecond : 0
        return t.isFinite && t > 0 ? UInt64(min(t, 9e18)) : 0
    }
}

/// Counts what a capture lost because its worker fell behind (`RealtimeAudioQueue.Chunk.dropped`), for its
/// stats, and says when to log: once per episode, an episode ending after `quietSeconds` without drops.
public struct AudioDropCounter: Sendable {
    public private(set) var totalSeconds: Double = 0
    public private(set) var episodes = 0
    /// Seconds lost in the current (or latest) episode.
    public private(set) var episodeSeconds: Double = 0
    public var quietSeconds: Double = 10
    private var lastDrop = -Double.infinity

    public init() {}

    /// Records `frames` lost at `sampleRate`, at host-clock time `now`. Returns true when this begins an
    /// episode (log it then).
    @discardableResult
    public mutating func record(frames: Int, sampleRate: Double, at now: Double) -> Bool {
        guard frames > 0, sampleRate > 0 else { return false }
        let seconds = Double(frames) / sampleRate
        totalSeconds += seconds
        let begins = now - lastDrop > quietSeconds
        if begins { episodes += 1; episodeSeconds = 0 }
        episodeSeconds += seconds
        lastDrop = now
        return begins
    }
}
