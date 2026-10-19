import Foundation
import Accelerate
import AudioToolbox
import CoreAudio
import ShoutKit

/// The microphone through Apple's voice-processing audio unit (echo cancellation against everything the
/// speakers play, noise suppression, gain control), driven directly the way Chromium does it.
/// AVAudioEngine's voice processing fails on some Macs (multi-channel microphone arrays report formats the
/// engine can't start with); asking the unit itself for mono at the microphone's rate avoids that.
///
/// The input callback runs on the audio thread and only renders into preallocated memory and pushes it
/// to `queue` (no locks, allocation or dispatch). Start and stop block for a while (hundreds of ms);
/// call them from one serial queue, never the main thread (MeetingMicCapture does that).
final class VoiceProcessingInput: @unchecked Sendable {
    enum VPError: LocalizedError {
        case noComponent, failed(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .noComponent: "Voice processing is not available."
            case .failed(let step, let s): "Voice processing failed at \(step) (error \(s))."
            }
        }
    }

    private(set) var sampleRate: Double = 0
    /// Devices the unit was started on (to tell a real device change from our own reconfiguration).
    private(set) var inputDevice: AudioDeviceID?
    private(set) var outputDevice: AudioDeviceID?
    /// "Float32" or "Int16" (the fallback when the unit refuses Float32, as Chromium does).
    private(set) var sampleFormat = ""

    private let queue: RealtimeAudioQueue
    private let generation: Int
    private var context: RenderContext?
    private static let inputBus: AudioUnitElement = 1
    private static let outputBus: AudioUnitElement = 0

    /// Samples go to `queue`, tagged with `generation`.
    init(queue: RealtimeAudioQueue, generation: Int) {
        self.queue = queue
        self.generation = generation
    }

    deinit { stop() }

    /// What the audio thread touches: fixed for the life of one unit, freed only after it is disposed.
    private final class RenderContext {
        var unit: AudioUnit?
        let floats: UnsafeMutablePointer<Float>
        let ints: UnsafeMutablePointer<Int16>
        let capacity = 16_384
        var isInt16 = false
        var sampleRate: Double = 0
        let queue: RealtimeAudioQueue
        let generation: Int

        init(queue: RealtimeAudioQueue, generation: Int) {
            self.queue = queue; self.generation = generation
            floats = .allocate(capacity: capacity); floats.initialize(repeating: 0, count: capacity)
            ints = .allocate(capacity: capacity); ints.initialize(repeating: 0, count: capacity)
        }
        deinit { floats.deallocate(); ints.deallocate() }

        func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>,
                    _ bus: UInt32, _ frames: UInt32) -> OSStatus {
            let host = timeStamp.pointee.mFlags.contains(.hostTimeValid) ? timeStamp.pointee.mHostTime : mach_absolute_time()
            guard let unit, Int(frames) <= capacity else {
                queue.push(nil, count: 0, hostTime: host, sampleRate: sampleRate, generation: generation)
                return noErr
            }
            let n = Int(frames)
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: frames * UInt32(isInt16 ? 2 : 4),
                mData: isInt16 ? UnsafeMutableRawPointer(ints) : UnsafeMutableRawPointer(floats)))
            let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &list)
            guard status == noErr else { return status }
            if isInt16 {
                vDSP_vflt16(ints, 1, floats, 1, vDSP_Length(n))
                var scale: Float = 1 / 32_768
                vDSP_vsmul(floats, 1, &scale, floats, 1, vDSP_Length(n))
            }
            queue.push(floats, count: n, hostTime: host, sampleRate: sampleRate, generation: generation)
            return noErr
        }
    }

    func start() throws {
        stop()
        guard let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) else { throw VPError.failed("input device", -1) }
        let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        if Self.isAggregate(input) { throw VPError.failed("aggregate input device", -1) } // as Chromium: VPIO refuses those

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw VPError.noComponent }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "create")
        guard let unit = instance else { throw VPError.noComponent }
        let ctx = RenderContext(queue: queue, generation: generation)
        ctx.unit = unit
        context = ctx

        do {
            var inDevice = input
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, Self.inputBus,
                                           &inDevice, UInt32(MemoryLayout<AudioDeviceID>.size)), "input device")
            if var outDevice = output {
                // The output device's mix is the echo reference.
                try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, Self.outputBus,
                                               &outDevice, UInt32(MemoryLayout<AudioDeviceID>.size)), "output device")
            }
            let refCon = Unmanaged.passUnretained(ctx).toOpaque()
            var inputCallback = AURenderCallbackStruct(inputProc: Self.inputProc, inputProcRefCon: refCon)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, Self.inputBus,
                                           &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "input callback")
            var renderCallback = AURenderCallbackStruct(inputProc: Self.silenceProc, inputProcRefCon: refCon)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, Self.outputBus,
                                           &renderCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "render callback")

            // Mono at the microphone's own rate, on both sides of the unit: Float32, or 16-bit integers
            // when the unit refuses Float32 (as Chromium falls back).
            let rate = Self.nominalRate(input) ?? 48_000
            do {
                try configure(unit, rate: rate, int16: false)
            } catch {
                AudioUnitUninitialize(unit)
                try configure(unit, rate: rate, int16: true)
            }
            sampleRate = rate
            ctx.sampleRate = rate
            inputDevice = input
            outputDevice = output

            var agc: UInt32 = 1
            AudioUnitSetProperty(unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, Self.inputBus,
                                 &agc, UInt32(MemoryLayout<UInt32>.size))
            // Keep the call itself at full volume: voice processing ducks other audio by default.
            var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
            AudioUnitSetProperty(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
                                 &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
            if let output { Self.undoDucking(output) }
            try check(AudioOutputUnitStart(unit), "start")
        } catch {
            stop()
            throw error
        }
    }

    /// Sets the stream format on both sides and initialises the unit.
    private func configure(_ unit: AudioUnit, rate: Double, int16: Bool) throws {
        let bytes: UInt32 = int16 ? 2 : 4
        let flags = int16 ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
                          : kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                                 mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: bytes * 8, mReserved: 0)
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let name = int16 ? "Int16" : "Float32"
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, Self.inputBus, &format, size), "input format (\(name))")
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, Self.outputBus, &format, size), "output format (\(name))")
        try check(AudioUnitInitialize(unit), "initialize (\(name))")
        context?.isInt16 = int16
        sampleFormat = name
    }

    func stop() {
        if let unit = context?.unit {
            // Synchronous with the audio thread: once disposed, no callback can use the context any more.
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            // The device the unit ducked, which is no longer the default after an output change.
            if let output = outputDevice ?? Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) { Self.undoDucking(output) }
        }
        context = nil
        inputDevice = nil
        outputDevice = nil
        sampleRate = 0
        sampleFormat = ""
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw VPError.failed(step, status) }
    }

    // MARK: Callbacks (audio thread)

    private static let inputProc: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
        Unmanaged<RenderContext>.fromOpaque(refCon)._withUnsafeGuaranteedRef { $0.render(flags, timeStamp, bus, frames) }
    }

    /// Shout plays nothing through this unit: the output side only provides the echo reference.
    private static let silenceProc: AURenderCallback = { _, flags, _, _, _, data in
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
        if let data {
            for b in UnsafeMutableAudioBufferListPointer(data) { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
        }
        return noErr
    }

    // MARK: Devices

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func nominalRate(_ device: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : nil
    }

    private static func isAggregate(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &t)
        return t == kAudioDeviceTransportTypeAggregate
    }

    /// Voice processing lowers other apps' volume; restore it (CoreAudio's AudioDeviceDuck, as Chromium does).
    private typealias DuckFn = @convention(c) (AudioDeviceID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus
    private static let duck: DuckFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck").map { unsafeBitCast($0, to: DuckFn.self) }

    private static func undoDucking(_ output: AudioDeviceID) {
        _ = duck?(output, 1.0, nil, 0.5)
    }
}
