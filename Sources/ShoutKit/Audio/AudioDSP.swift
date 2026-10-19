import Foundation
import Accelerate

/// Small DSP helpers for 16 kHz mono Float32 audio.
public enum AudioDSP {
    public static let sampleRate = 16_000

    public static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        var r: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &r, vDSP_Length($0.count)) }
        return r
    }

    public static func peak(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var m: Float = 0
        vDSP_maxmgv(x, 1, &m, vDSP_Length(x.count))
        return m
    }

    /// Converts an RMS value to a 0...1 level suitable for a waveform meter.
    public static func meterLevel(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 55) / 45))
    }

    /// Per-frame (30 ms) RMS energies.
    static func frameEnergies(_ x: [Float], frame: Int = 480) -> [Float] {
        guard x.count >= frame else { return [rms(x[...])] }
        return stride(from: 0, to: x.count - frame + 1, by: frame).map { rms(x[$0..<($0 + frame)]) }
    }

    /// Adaptive voice activity estimate: returns total seconds of frames that rise clearly above the noise floor.
    public static func speechSeconds(_ x: [Float]) -> Double {
        let e = frameEnergies(x)
        guard !e.isEmpty else { return 0 }
        let sorted = e.sorted()
        let noise = max(sorted[Int(Double(sorted.count) * 0.1)], 0.0008)
        let threshold = max(noise * 3.0, 0.004)
        let active = e.filter { $0 > threshold }.count
        return Double(active) * 0.03
    }

    /// True when the clip almost certainly contains no speech.
    public static func isSilent(_ x: [Float]) -> Bool {
        peak(x) < 0.006 || speechSeconds(x) < 0.12
    }

    /// Trims leading/trailing silence, keeping a small margin so word onsets are not clipped.
    public static func trimSilence(_ x: [Float], margin: Double = 0.25) -> [Float] {
        let frame = 480
        let e = frameEnergies(x, frame: frame)
        guard e.count > 4 else { return x }
        let sorted = e.sorted()
        let noise = max(sorted[Int(Double(sorted.count) * 0.1)], 0.0008)
        let threshold = max(noise * 2.5, 0.003)
        guard let first = e.firstIndex(where: { $0 > threshold }),
              let last = e.lastIndex(where: { $0 > threshold }) else { return x }
        let pad = Int(margin * Double(sampleRate))
        let start = max(0, first * frame - pad)
        let end = min(x.count, (last + 1) * frame + pad)
        return start < end ? Array(x[start..<end]) : x
    }

    /// Peak-normalises quiet recordings (e.g. whispering) to help recognition. Loud audio is left alone.
    public static func normalize(_ x: [Float], targetPeak: Float = 0.7, maxGain: Float = 12) -> [Float] {
        let p = peak(x)
        guard p > 1e-4 else { return x }
        let gain = min(maxGain, targetPeak / p)
        guard gain > 1.05 else { return x }
        var out = [Float](repeating: 0, count: x.count)
        var g = gain
        vDSP_vsmul(x, 1, &g, &out, 1, vDSP_Length(x.count))
        return out
    }

    /// Simple first-order high-pass at ~80 Hz to remove rumble and DC offset.
    public static func highPass(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        let rc: Float = 1 / (2 * .pi * 80)
        let dt: Float = 1 / Float(sampleRate)
        let a = rc / (rc + dt)
        var out = [Float](repeating: 0, count: x.count)
        var prevIn = x[0], prevOut: Float = 0
        for i in 0..<x.count {
            let y = a * (prevOut + x[i] - prevIn)
            out[i] = y
            prevIn = x[i]; prevOut = y
        }
        return out
    }

    /// Writes 16-bit PCM WAV (for keeping recordings / debugging).
    public static func wavData(_ x: [Float], sampleRate: Int = 16_000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 4)) }
        func u16(_ v: UInt16) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 2)) }
        let dataBytes = UInt32(x.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        var pcm = x.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        d.append(Data(bytes: &pcm, count: pcm.count * 2))
        return d
    }

    /// Reads any audio file macOS can decode and returns 16 kHz mono Float32.
    public static func loadAudioFile(_ url: URL) throws -> [Float] {
        try AudioFileLoader.load(url)
    }
}
