import AppKit

/// Short UI sounds synthesised at runtime (no bundled audio assets).
@MainActor
final class SoundPlayer {
    enum Sound { case start, stop, lock, cancel, error }

    private var cache: [Sound: NSSound] = [:]
    var enabled = true
    var volume: Float = 0.5

    func play(_ s: Sound) {
        guard enabled else { return }
        let sound = cache[s] ?? make(s)
        cache[s] = sound
        sound?.stop()
        sound?.volume = volume
        sound?.play()
    }

    private func make(_ s: Sound) -> NSSound? {
        // (frequency Hz, duration s) note sequences.
        let notes: [(Double, Double)]
        switch s {
        case .start: notes = [(659.25, 0.055), (987.77, 0.085)]
        case .stop: notes = [(987.77, 0.055), (659.25, 0.085)]
        case .lock: notes = [(659.25, 0.045), (830.61, 0.045), (987.77, 0.09)]
        case .cancel: notes = [(523.25, 0.06), (392.0, 0.09)]
        case .error: notes = [(220.0, 0.09), (196.0, 0.14)]
        }
        let rate = 44_100.0
        var samples: [Float] = []
        for (freq, dur) in notes {
            let n = Int(dur * rate)
            for i in 0..<n {
                let t = Double(i) / rate
                let attack = min(1, t / 0.006)
                let release = min(1, (dur - t) / 0.03)
                let env = attack * max(0, release)
                // Sine with a soft second harmonic for a rounded "pop".
                let v = sin(2 * .pi * freq * t) * 0.8 + sin(4 * .pi * freq * t) * 0.12
                samples.append(Float(v * env * 0.35))
            }
        }
        return NSSound(data: Self.wav(samples, rate: Int(rate)))
    }

    private static func wav(_ x: [Float], rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 4)) }
        func u16(_ v: UInt16) { var le = v.littleEndian; d.append(Data(bytes: &le, count: 2)) }
        let bytes = UInt32(x.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        var pcm = x.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        d.append(Data(bytes: &pcm, count: pcm.count * 2))
        return d
    }
}
