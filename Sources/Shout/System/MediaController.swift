import Foundation
import CoreAudio
import AudioToolbox
import ShoutKit

/// Mutes system output or pauses media while the user dictates, and restores it afterwards.
@MainActor
final class MediaController {
    private var mutedDevice: AudioDeviceID?
    private var previousMute: UInt32 = 0
    private var previousVolume: Float32?
    private var pausedMedia = false
    /// Between `begin` and `end`; `session` counts `begin`s so a late pause check knows whose it is.
    private var active = false
    private var session = 0

    private typealias SendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool
    private lazy var mrSendCommand: SendCommandFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendCommandFn.self)
    }()

    func begin(_ behavior: ShoutMediaBehavior) {
        active = true
        session &+= 1
        switch behavior {
        case .nothing: return
        case .mute: mute()
        case .pause: pause()
        }
    }

    func end() {
        active = false
        if let dev = mutedDevice {
            if let v = previousVolume { setVolume(dev, v) } else { setMute(dev, previousMute) }
            mutedDevice = nil; previousVolume = nil
        }
        if pausedMedia {
            pausedMedia = false
            _ = mrSendCommand?(0, nil) // kMRPlay
        }
    }

    // MARK: Pause

    private func pause() {
        // Without the process list (before macOS 14.2) there's no telling what plays: mute instead.
        guard let playingBefore = Self.processesPlayingAudio() else { mute(); return }
        guard !playingBefore.isEmpty else { return }
        guard let send = mrSendCommand else { mute(); return }
        _ = send(1, nil) // kMRPause (idempotent, unlike the play/pause toggle)
        // Only resume later if pausing actually silenced someone; otherwise fall back to muting.
        let session = self.session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            let playingAfter = Self.processesPlayingAudio() ?? []
            let silenced = playingAfter.count < playingBefore.count
            if self.active && self.session == session {
                if silenced { self.pausedMedia = true }
                else if !playingAfter.isEmpty { self.mute() }
            } else if silenced {
                // The dictation ended before this check (a quick tap): resume now and never mute, or
                // let a newer dictation resume it when it ends.
                if self.active { self.pausedMedia = true } else { _ = send(0, nil) } // kMRPlay
            }
        }
    }

    /// Process objects currently producing output audio (macOS 14.2+ Core Audio process API), or nil
    /// when the list can't be read.
    static func processesPlayingAudio() -> [AudioObjectID]? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        return ids.filter { id in
            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0; var psize = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(id, &pidAddr, 0, nil, &psize, &pid)
            if pid == me { return false }
            var runAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0; var rsize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &runAddr, 0, nil, &rsize, &running)
            return running != 0
        }
    }

    // MARK: Mute

    private func mute() {
        guard mutedDevice == nil, let dev = Self.defaultOutputDevice() else { return }
        if let m = getMute(dev) {
            previousMute = m
            if setMute(dev, 1) { mutedDevice = dev; return }
        }
        if let v = getVolume(dev) {
            previousVolume = v
            setVolume(dev, 0)
            mutedDevice = dev
        }
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    private func getMute(_ dev: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    private func setMute(_ dev: AudioDeviceID, _ value: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var v = value
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v) == noErr
    }

    private func getVolume(_ dev: AudioDeviceID) -> Float32? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private func setVolume(_ dev: AudioDeviceID, _ value: Float32) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var v = value
        AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}

typealias ShoutMediaBehavior = ShoutKit.MediaBehavior
