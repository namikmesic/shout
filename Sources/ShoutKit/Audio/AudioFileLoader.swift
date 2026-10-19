import Foundation
import AVFoundation

enum AudioFileLoader {
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw NSError(domain: "Shout", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
        }
        let inCap: AVAudioFrameCount = 16_384
        var out: [Float] = []
        if file.processingFormat.sampleRate > 0 {
            out.reserveCapacity(max(0, Int(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate)))
        }
        // A failed read ends the input like the end of the file does; it is thrown once the converter returns,
        // so a damaged file fails instead of loading as a shorter one.
        var readError: Error?
        var done = false
        while !done {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else { throw failure("Out of memory") }
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, statusPtr in
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: inCap) else {
                    readError = failure("Unsupported audio format")
                    statusPtr.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: inBuf) } catch {
                    // A read at the very end is the end, not damage.
                    if file.framePosition < file.length { readError = error }
                    statusPtr.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 { statusPtr.pointee = .endOfStream; return nil }
                statusPtr.pointee = .haveData
                return inBuf
            }
            if let err { throw err }
            if let readError { throw readError }
            if status == .error { throw failure("Could not decode the audio") }
            if let ch = outBuf.floatChannelData, outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || outBuf.frameLength == 0 { done = true }
        }
        return out
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Shout", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
