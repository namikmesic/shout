import XCTest
import AVFoundation
@testable import ShoutKit

/// Reproducible noise at about `rms` (16 kHz).
private func noise(seconds: Double, seed: UInt32, rms: Float) -> [Float] {
    var state = seed
    return (0..<Int(seconds * 16_000)).map { _ in
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: state)) / Float(Int32.max) * rms * 1.732
    }
}

private func delayed(_ x: [Float], ms: Int, gain: Float) -> [Float] {
    let d = ms * 16
    return (0..<x.count).map { $0 >= d ? x[$0 - d] * gain : 0 }
}

final class Review3G06Tests: XCTestCase {
    // MARK: RealtimeAudioQueue

    func testANonFiniteSampleRateDoesNotTrapTheProducer() {
        let q = RealtimeAudioQueue(blocks: 8, framesPerBlock: 64)
        let x = [Float](repeating: 0.25, count: 48)
        x.withUnsafeBufferPointer { p in
            XCTAssertTrue(q.push(p.baseAddress!, count: 48, hostTime: 1_000, sampleRate: .infinity, generation: 1))
            XCTAssertTrue(q.push(p.baseAddress!, count: 48, hostTime: 2_000, sampleRate: .nan, generation: 2))
        }
        var frames = 0
        q.drain { frames += $0.samples.count }
        XCTAssertEqual(frames, 96)
    }

    func testATinySampleRateDoesNotOverflowTheContinuationTime() {
        // A block that waits for more audio computes where the next callback continues it: at a rate this small
        // that is far beyond UInt64.
        let q = RealtimeAudioQueue(blocks: 8, framesPerBlock: 64, publishSeconds: 1e305)
        let x = [Float](repeating: 0.25, count: 48)
        x.withUnsafeBufferPointer { p in
            XCTAssertTrue(q.push(p.baseAddress!, count: 48, hostTime: 1_000, sampleRate: 1e-300, generation: 1))
        }
        q.push(nil, count: 0, hostTime: 2_000, sampleRate: 48_000, generation: 2) // hands on what waits
        var counts: [Int] = []
        q.drain { counts.append($0.samples.count) }
        XCTAssertEqual(counts, [48, 0])
    }

    // MARK: EchoCorrelation

    func testDecimationNeedsAFullFilterLength() {
        // 30 samples used to give one output, which reads 31.
        XCTAssertTrue(EchoCorrelation.decimate([Float](repeating: 1, count: 30)).isEmpty)
        XCTAssertEqual(EchoCorrelation.decimate([Float](repeating: 1, count: 31)).count, 1)
        XCTAssertEqual(EchoCorrelation.decimate([Float](repeating: 1, count: 33)).count, 2)
    }

    func testASmallerWindowSearchesOnlyTheLagsItsFFTHolds() {
        let far = noise(seconds: 3, seed: 3, rms: 0.08)
        let mic = delayed(far, ms: 40, gain: 0.5)
        var small = EchoCorrelation.Config()
        small.window = 1_024 // a 2048-point FFT: the default 350 ms search reaches past it
        small.hop = 512
        let e = EchoCorrelation.measure(mic: mic, system: far, config: small)
        XCTAssertGreaterThan(e.locked, 0)
        XCTAssertEqual(e.lagMs ?? 0, 40, accuracy: 2)
    }

    func testAnEmptyLagRangeOrStepFindsNothing() {
        let far = noise(seconds: 2, seed: 4, rms: 0.08)
        let mic = delayed(far, ms: 40, gain: 0.5)
        var inverted = EchoCorrelation.Config()
        inverted.minLagMs = 100
        inverted.maxLagMs = 50
        let e = EchoCorrelation.measure(mic: mic, system: far, config: inverted)
        XCTAssertGreaterThan(e.windows, 0)
        XCTAssertEqual(e.locked, 0)
        var noHop = EchoCorrelation.Config()
        noHop.hop = 0
        XCTAssertTrue(EchoCorrelation.windows(mic: mic, system: far, config: noHop).isEmpty)
    }

    // MARK: AudioFileLoader

    func testAFileLoadsWholeAndResampled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("review3g06-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tone = (0..<72_000).map { 0.3 * Float(sin(2 * .pi * 440 * Double($0) / 48_000)) } // 1.5 s at 48 kHz
        let wav = dir.appendingPathComponent("tone.wav")
        try AudioDSP.wavData(tone, sampleRate: 48_000).write(to: wav)
        XCTAssertEqual(Double(try AudioDSP.loadAudioFile(wav).count), 24_000, accuracy: 64)

        // A compressed file: reaching its end is the end, not a read error.
        let m4a = dir.appendingPathComponent("tone.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
            buffer.frameLength = 32_000
            for i in 0..<32_000 { buffer.floatChannelData![0][i] = 0.3 * Float(sin(2 * .pi * 440 * Double(i) / 16_000)) }
            try file.write(from: buffer)
        }
        XCTAssertEqual(Double(try AudioDSP.loadAudioFile(m4a).count), 32_000, accuracy: 2_048)
    }

    func testAFileThatIsNotAudioFails() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review3g06-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x5A, count: 4_096).write(to: url)
        XCTAssertThrowsError(try AudioDSP.loadAudioFile(url))
    }
}
