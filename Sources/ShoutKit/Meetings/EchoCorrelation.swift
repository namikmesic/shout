import Foundation
import Accelerate

/// Acoustic evidence that the microphone picked up the call audio (speakers instead of headphones).
///
/// The two tracks share one timeline, so call audio that leaks into the microphone shows up as the same
/// signal in both, the microphone's copy a few tens of milliseconds later. This measures that with
/// GCC-PHAT (the method Wispr Flow's echo gate uses): the stretch is cut into overlapping 1 s windows at
/// 8 kHz; for each window where both tracks carry sound, the phase-transform cross-correlation peak gives
/// a delay and a score. Echo means most windows agree on one delay with the microphone behind the call
/// audio. Two people saying the same words, a repeat-back, or headphones give scattered or no peaks.
public enum EchoCorrelation {
    public struct Config: Sendable {
        /// Analysis window and hop, in samples at 8 kHz.
        public var window = 8_192
        public var hop = 2_048
        /// Both windows must reach this RMS (−50 dBFS), like Wispr's energy floor.
        public var energyFloor: Float = 0.003
        /// Normalised peak a window needs (1 = identical signals). Unrelated speech peaks around 0.05 and
        /// rarely reaches it; echo under double talk scores 0.1–0.3, plain echo 0.5 and more.
        public var scoreFloor: Float = 0.1
        /// Delays searched: the microphone hears the call after it is played, so only positive ones, with
        /// a little negative slack for the tracks' placement tolerance. (The reverse, the call audio behind
        /// the microphone, is the far end echoing the user back: that "You" line is the user's own.)
        public var minLagMs = -40
        public var maxLagMs = 350
        /// Windows within this of the median delay agree.
        public var lagToleranceMs = 35
        /// Speech band used for the correlation.
        public var lowHz: Double = 150
        public var highHz: Double = 3_800
        public init() {}
    }

    public struct Evidence: Sendable, Equatable {
        /// Windows where the microphone carries sound (the line's speech).
        public var windows = 0
        /// Of those, windows where the call audio carries sound too.
        public var bothActive = 0
        /// Windows whose correlation peak passed the score floor and agrees on one delay.
        public var locked = 0
        /// That delay (microphone after call audio), when any window locked.
        public var lagMs: Int?

        public init(windows: Int = 0, bothActive: Int = 0, locked: Int = 0, lagMs: Int? = nil) {
            self.windows = windows; self.bothActive = bothActive; self.locked = locked; self.lagMs = lagMs
        }

        /// Share of the microphone's sound that is echo.
        public var coverage: Double { windows == 0 ? 0 : Double(locked) / Double(windows) }
        /// Enough to cut echoed words out of a line: at least two windows, and at least half of those where
        /// both sides had sound, agree on one delay. (Overlapping windows share audio, so a chance peak can
        /// show up twice; it doesn't show up across half of them.)
        public var supportsCut: Bool { locked >= 2 && locked * 2 >= bothActive }
        /// Enough to hide a whole line: the correlation holds over most of it.
        public var supportsHiding: Bool { supportsCut && coverage >= 0.6 }
    }

    /// One analysis window: where the correlation peaks (ms, microphone after call audio) and how
    /// strongly (nil when either track was too quiet to compare).
    public struct Window: Sendable, Equatable {
        public var startMs: Int
        public var micActive: Bool
        public var lagMs: Int?
        public var score: Float?
    }

    /// Compares two 16 kHz stretches that start at the same timeline position.
    public static func measure(mic: [Float], system: [Float], config: Config = Config()) -> Evidence {
        var evidence = Evidence()
        var found: [(lag: Int, score: Float)] = []
        for w in windows(mic: mic, system: system, config: config) where w.micActive {
            evidence.windows += 1
            guard let lag = w.lagMs, let score = w.score else { continue }
            evidence.bothActive += 1
            if score >= config.scoreFloor { found.append((lag * 8, score)) }
        }
        guard !found.isEmpty else { return evidence }
        let lags = found.map(\.lag).sorted()
        let median = lags[lags.count / 2]
        let tolerance = config.lagToleranceMs * 8
        let agreeing = found.filter { abs($0.lag - median) <= tolerance }
        evidence.locked = agreeing.count
        evidence.lagMs = median / 8
        return evidence
    }

    /// The per-window analysis behind `measure` (also used by the self-test to report alignment).
    public static func windows(mic: [Float], system: [Float], config: Config = Config()) -> [Window] {
        let x = decimate(mic), y = decimate(system)
        let count = min(x.count, y.count)
        guard count > 0, config.window > 0, config.hop > 0 else { return [] }
        let n = config.window
        let log2n = vDSP_Length((Int(log2(Double(2 * n - 1))) + 1))
        let size = 1 << Int(log2n)
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }
        let correlator = Correlator(size: size, log2n: log2n, fft: fft, config: config)
        // Short stretches still get one window (zero-padded).
        let starts = count <= n ? [0] : Array(stride(from: 0, through: count - n, by: config.hop))
        return starts.map { start in
            let len = min(n, count - start)
            var w = Window(startMs: start / 8, micActive: rms(x, start, len) >= config.energyFloor)
            if w.micActive && rms(y, start, len) >= config.energyFloor {
                let (lag, score) = correlator.peak(x, y, start: start, count: len)
                w.lagMs = lag / 8; w.score = score
            }
            return w
        }
    }

    /// Reads both tracks of a meeting folder for a stretch of the timeline (plus `marginMs` on each side)
    /// and measures it. Reads files: call off the main thread.
    public static func measure(folder: URL, fromMs: Int, toMs: Int, marginMs: Int = 500, config: Config = Config()) -> Evidence {
        let start = max(0, fromMs - marginMs) * 16
        let count = max(0, toMs + marginMs) * 16 - start
        guard count > 0,
              let mic = try? MeetingArchive.read(.mic, in: folder, offset: start, count: count),
              let system = try? MeetingArchive.read(.system, in: folder, offset: start, count: count)
        else { return Evidence() }
        return measure(mic: mic, system: system, config: config)
    }

    // MARK: Internals

    /// 16 → 8 kHz with a half-band low-pass.
    static func decimate(_ x: [Float]) -> [Float] {
        let taps = halfBand
        // At least one full filter length: below it the division rounds toward zero, and vDSP would read
        // past the end (30 samples give one output that needs 31).
        guard x.count >= taps.count else { return [] }
        let out = (x.count - taps.count) / 2 + 1
        var y = [Float](repeating: 0, count: out)
        vDSP_desamp(x, 2, taps, &y, vDSP_Length(out), vDSP_Length(taps.count))
        return y
    }

    private static let halfBand: [Float] = {
        let m = 31, mid = Double(m - 1) / 2
        return (0..<m).map { i in
            let t = Double(i) - mid
            let sinc = t == 0 ? 0.5 : sin(.pi * t / 2) / (.pi * t)
            let hamming = 0.54 - 0.46 * cos(2 * .pi * Double(i) / Double(m - 1))
            return Float(sinc * hamming)
        }
    }()

    private static func rms(_ x: [Float], _ start: Int, _ count: Int) -> Float {
        var r: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + start, 1, &r, vDSP_Length(count)) }
        return r
    }

    /// GCC-PHAT for one window, with buffers reused across windows.
    private final class Correlator {
        let size: Int, half: Int, log2n: vDSP_Length, fft: FFTSetup
        let minLag: Int, maxLag: Int
        var xr: [Float], xi: [Float], yr: [Float], yi: [Float], mag: [Float], out: [Float], padded: [Float]
        let band: [Float]
        let norm: Float

        init(size: Int, log2n: vDSP_Length, fft: FFTSetup, config: Config) {
            self.size = size; self.half = size / 2; self.log2n = log2n; self.fft = fft
            // Only lags the circular correlation holds (a smaller window means a smaller FFT).
            minLag = max(config.minLagMs * 8, -(size / 2 - 1)); maxLag = min(config.maxLagMs * 8, size / 2 - 1)
            xr = .init(repeating: 0, count: size / 2); xi = xr; yr = xr; yi = xr; mag = xr
            out = .init(repeating: 0, count: size); padded = out
            let binHz = 8_000.0 / Double(size)
            band = (0..<(size / 2)).map { k in
                let hz = Double(k) * binHz
                return k > 0 && hz >= config.lowHz && hz <= config.highHz ? 1 : 0
            }
            // Peak of a perfectly coherent pair (every in-band bin in phase) at lag 0, to scale scores to 0…1.
            var r = [Float](repeating: 0, count: size / 2), i = [Float](repeating: 0, count: size / 2)
            for k in 0..<(size / 2) { r[k] = band[k] }
            var probe = [Float](repeating: 0, count: size)
            r.withUnsafeMutableBufferPointer { rp in
                i.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                    probe.withUnsafeMutableBufferPointer { op in
                        op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(size / 2))
                        }
                    }
                }
            }
            norm = max(probe[0], 1e-9)
        }

        /// Delay of `x` behind `y` (8 kHz samples) and its normalised score.
        func peak(_ x: [Float], _ y: [Float], start: Int, count: Int) -> (Int, Float) {
            guard minLag <= maxLag else { return (0, 0) }
            transform(x, start, count, &xr, &xi)
            transform(y, start, count, &yr, &yi)
            // Cross spectrum X·conj(Y), whitened (phase transform), restricted to the speech band.
            xr.withUnsafeMutableBufferPointer { xrp in xi.withUnsafeMutableBufferPointer { xip in
            yr.withUnsafeMutableBufferPointer { yrp in yi.withUnsafeMutableBufferPointer { yip in
                var a = DSPSplitComplex(realp: yrp.baseAddress!, imagp: yip.baseAddress!)
                var b = DSPSplitComplex(realp: xrp.baseAddress!, imagp: xip.baseAddress!)
                vDSP_zvmul(&a, 1, &b, 1, &b, 1, vDSP_Length(half), -1)
                mag.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&b, 1, mp.baseAddress!, 1, vDSP_Length(half))
                    var eps: Float = 1e-12
                    vDSP_vsadd(mp.baseAddress!, 1, &eps, mp.baseAddress!, 1, vDSP_Length(half))
                    vDSP_vdiv(mp.baseAddress!, 1, xrp.baseAddress!, 1, xrp.baseAddress!, 1, vDSP_Length(half))
                    vDSP_vdiv(mp.baseAddress!, 1, xip.baseAddress!, 1, xip.baseAddress!, 1, vDSP_Length(half))
                }
                vDSP_vmul(xrp.baseAddress!, 1, band, 1, xrp.baseAddress!, 1, vDSP_Length(half))
                vDSP_vmul(xip.baseAddress!, 1, band, 1, xip.baseAddress!, 1, vDSP_Length(half))
                xip[0] = 0 // packed Nyquist bin
                vDSP_fft_zrip(fft, &b, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { op in
                    op.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&b, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }}}}
            var best: Float = -.infinity, bestLag = 0
            for lag in minLag...maxLag {
                let v = out[lag >= 0 ? lag : size + lag]
                if v > best { best = v; bestLag = lag }
            }
            return (bestLag, best / norm)
        }

        private func transform(_ s: [Float], _ start: Int, _ count: Int, _ re: inout [Float], _ im: inout [Float]) {
            padded.withUnsafeMutableBufferPointer { pp in
                s.withUnsafeBufferPointer { pp.baseAddress!.update(from: $0.baseAddress! + start, count: count) }
                if count < size { vDSP_vclr(pp.baseAddress! + count, 1, vDSP_Length(size - count)) }
            }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                padded.withUnsafeBufferPointer { pp in
                    pp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }}
        }
    }
}

public extension EchoMatcher {
    /// `resolve`, gated by the audio: a microphone line is only cut when its audio correlates with the
    /// call audio, and only hidden when that holds over most of the line. Shared words alone (a
    /// repeat-back, a quote, a stock phrase, anything said with headphones on) never change a line.
    /// `evidence` is asked only for lines that share words with the call audio.
    static func resolve(_ segments: [MeetingSegment],
                        evidence: (MeetingSegment) -> EchoCorrelation.Evidence) -> [String: Resolution] {
        var out: [String: Resolution] = [:]
        for (id, r) in resolve(segments) {
            guard let line = segments.first(where: { $0.id == id }) else { continue }
            let e = evidence(line)
            if r.text.isEmpty ? e.supportsHiding : e.supportsCut { out[id] = r }
        }
        return out
    }

    /// `resolve` with the evidence measured from the meeting's audio folder. Reads files: call off the
    /// main thread.
    static func resolve(_ segments: [MeetingSegment], folder: URL) -> [String: Resolution] {
        resolve(segments) { EchoCorrelation.measure(folder: folder, fromMs: $0.startMs, toMs: $0.endMs) }
    }
}
