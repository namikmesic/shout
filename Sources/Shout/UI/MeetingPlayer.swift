import AVFoundation
import SwiftUI
import ShoutKit

/// The playhead, published apart from the player: while playing it changes 10 times a second, and only the bar's
/// elapsed time and scrubber should redraw for that, not the meeting view and its transcript.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var position: TimeInterval = 0
}

/// Plays a finished meeting's recording: both sides mixed to mono (so "You" isn't in one ear only), read from
/// the archive or the raw tracks a couple of seconds at a time, so seeking anywhere in a long meeting is instant.
/// Positions are meeting-timeline seconds, the same as the transcript's times.
///
/// The audio engine exists only while it is needed: built on the first Play (opening a note never touches the audio
/// hardware), paused on Pause, and let go at the end, on Stop and when the output device changes, so the Mac can
/// idle-sleep and a missing or switching output device is never wired into a graph.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    /// Where each Resume began, for marks on the scrubber.
    @Published private(set) var legStarts: [TimeInterval] = []
    let clock = PlaybackClock()
    var position: TimeInterval {
        get { clock.position }
        set { clock.position = newValue }
    }
    /// The scrubber is being dragged: the playhead doesn't move `position`.
    var isScrubbing = false

    private var meetingID: String?
    private var folder: URL?
    private var frames = 0
    /// Bumped by every load, so a length read for an earlier load is dropped.
    private var loadGeneration = 0
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    /// The output format the engine's graph was built for.
    private var builtFor: OutputFormat?
    private var configObserver: NSObjectProtocol?
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(MeetingTrack.sampleRate), channels: 1)!
    /// Timeline frame where the current schedule began, the next frame to read, and buffers not yet played.
    private var startFrame = 0, nextFrame = 0, queued = 0
    /// Bumped by every seek and stop, so reads and completions of an older schedule are dropped.
    private var generation = 0
    private var ticker: Timer?

    private struct OutputFormat: Equatable {
        let sampleRate: Double
        let channels: AVAudioChannelCount
    }

    private static let sampleRate = Double(MeetingTrack.sampleRate)
    private static let chunkFrames = MeetingTrack.sampleRate * 2
    private static let reader = DispatchQueue(label: "shout.meeting-playback", qos: .userInitiated)

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    /// A player showing a recording of this length that plays nothing (snapshots).
    static func preview(duration: TimeInterval, position: TimeInterval, legStarts: [TimeInterval] = []) -> MeetingPlayer {
        let p = MeetingPlayer()
        p.duration = duration
        p.position = position
        p.legStarts = legStarts
        return p
    }

    /// Points the player at a meeting's audio, stopping any playback. With no audio, `duration` stays 0. Finding the
    /// files and the archive's length (which parses its sample table, large for a long meeting) happens off the
    /// main thread; until then a reload of the same meeting keeps showing the previous length.
    func load(meetingID: String, segments: [MeetingSegment]) {
        stop()
        if meetingID != self.meetingID {
            self.meetingID = meetingID
            folder = nil
            frames = 0
            duration = 0
        }
        legStarts = MeetingArchive.legStarts(segments).dropFirst().map { Double($0) / 1000 }
        position = 0
        loadGeneration += 1
        let gen = loadGeneration
        Self.reader.async { [weak self] in
            let files = MeetingArchive.files(for: meetingID)
            let folder = files.preferred == nil ? nil : files.folder
            let frames = folder.map(MeetingArchive.length(in:)) ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.loadGeneration else { return }
                    self.folder = folder
                    self.frames = frames
                    self.duration = Double(frames) / Self.sampleRate
                }
            }
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard folder != nil, frames > 0 else { return }
        // Starting over: drop any tail still queued from a pause at the end, so the schedule begins at 0.
        if position >= duration - 0.05 { position = 0; dropSchedule() }
        guard let node = readyNode() else { return }
        // Resuming after Pause continues the buffers already queued; anything else starts a new schedule.
        if queued == 0 { begin(at: frame(position)) }
        node.play()
        isPlaying = true
        startTicker()
    }

    /// Keeps the place and the queued audio, and pauses the engine so the audio device can go idle.
    func pause() {
        position = playhead
        node?.pause()
        engine?.pause()
        isPlaying = false
        stopTicker()
    }

    /// Moves the playhead; keeps playing if it was (or starts, with `play`). At the end there is nothing left to
    /// play, so it stops there.
    func seek(to seconds: TimeInterval, play: Bool = false) {
        guard frames > 0 else { return }
        position = max(0, min(duration, seconds))
        guard isPlaying || play else {
            // Paused or stopped: the next Play starts from here.
            dropSchedule()
            return
        }
        guard frame(position) < frames else { finish(); return }
        guard let node = readyNode() else { halt(); return }
        begin(at: frame(position))
        node.play()
        isPlaying = true
        startTicker()
    }

    func skip(_ seconds: TimeInterval) { seek(to: position + seconds) }

    /// Stops and lets go of the audio device (the view went away or the meeting changed).
    func stop() {
        halt()
        teardown()
    }

    // MARK: Engine

    /// The player node on a running engine, building the engine on first use (and again after the output device
    /// changed). Nil when there is no usable output device, so Play does nothing rather than AVAudioEngine
    /// raising an exception for an invalid format.
    private func readyNode() -> AVAudioPlayerNode? {
        if let engine, let node {
            if engine.isRunning { return node }
            // Resuming after Pause, on the device the graph was built for.
            if Self.outputFormat(engine) == builtFor, (try? engine.start()) != nil { return node }
            teardown()
        }
        let engine = AVAudioEngine()
        // Wiring the mixer to an output with no valid format raises an exception that can't be caught.
        guard let output = Self.outputFormat(engine) else { return nil }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do { try engine.start() } catch { return nil }
        // A new or lost output device stops the engine and invalidates its graph: keep the place, build a new
        // engine on the next Play.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
        self.engine = engine
        self.node = node
        builtFor = output
        return node
    }

    private static func outputFormat(_ engine: AVAudioEngine) -> OutputFormat? {
        let f = engine.outputNode.outputFormat(forBus: 0)
        return f.sampleRate > 0 && f.channelCount > 0 ? OutputFormat(sampleRate: f.sampleRate, channels: f.channelCount) : nil
    }

    private func outputChanged() {
        if isPlaying { position = playhead }
        halt()
        teardown()
    }

    /// Lets go of the engine (and the audio device); anything queued on it is gone.
    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        dropSchedule()
        engine?.stop()
        engine = nil
        node = nil
        builtFor = nil
    }

    // MARK: Scheduling

    private func halt() {
        dropSchedule()
        isPlaying = false
        stopTicker()
    }

    /// Reads and completions still in flight are ignored from here on.
    private func dropSchedule() {
        generation += 1
        node?.stop()
        queued = 0
    }

    /// Played to the end: stop there and let go of the audio device.
    private func finish() {
        halt()
        teardown()
        position = duration
    }

    private func frame(_ seconds: TimeInterval) -> Int { min(frames, max(0, Int(seconds * Self.sampleRate))) }

    private func begin(at frame: Int) {
        dropSchedule()
        startFrame = frame
        nextFrame = frame
        fill()
    }

    /// Keeps about three chunks (6 s) queued ahead of the playhead.
    private func fill() {
        guard let folder else { return }
        while queued < 3 && nextFrame < frames {
            let offset = nextFrame, count = min(Self.chunkFrames, frames - offset), gen = generation
            nextFrame += count
            queued += 1
            Self.reader.async { [weak self] in
                let mic = Self.read(.mic, in: folder, offset: offset, count: count)
                let system = Self.read(.system, in: folder, offset: offset, count: count)
                let mixed = (0..<count).map { i in
                    max(-1, min(1, (i < mic.count ? mic[i] : 0) + (i < system.count ? system[i] : 0)))
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.schedule(mixed, generation: gen) } }
            }
        }
    }

    /// One source's samples. When the archiver finishes the note between finding the raw tracks and reading them,
    /// they are gone and the read fails; the second try finds the archive instead of playing that side as silence.
    nonisolated private static func read(_ source: MeetingSource, in folder: URL, offset: Int, count: Int) -> [Float] {
        for _ in 0..<2 {
            if let samples = try? MeetingArchive.read(source, in: folder, offset: offset, count: count) { return samples }
        }
        return []
    }

    private func schedule(_ samples: [Float], generation gen: Int) {
        guard gen == generation else { return }
        guard let node, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            // Nothing will report this chunk played: count it now, or `queued` never drains and playback never ends.
            played(generation: gen)
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.played(generation: gen) } }
        }
    }

    private func played(generation gen: Int) {
        guard gen == generation else { return }
        queued -= 1
        if nextFrame < frames {
            fill()
        } else if queued == 0 {
            finish()
        }
    }

    // MARK: Playhead

    private var playhead: TimeInterval {
        guard let node, let t = node.lastRenderTime, let p = node.playerTime(forNodeTime: t), p.sampleRate > 0 else { return position }
        return min(duration, Double(startFrame) / Self.sampleRate + Double(p.sampleTime) / p.sampleRate)
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            // The run loop keeps the timer: a player let go without Stop must not leave it firing.
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor in
                guard let self, self.isPlaying, !self.isScrubbing else { return }
                self.position = self.playhead
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

/// The compact player under a finished meeting's title: back and forward 15 s, play/pause, a scrubber with a
/// mark where each Resume began, and elapsed / total time.
struct PlaybackBar: View {
    @ObservedObject var player: MeetingPlayer

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.system(size: 12.5)) }
                    .help("Back 15 seconds")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13)).foregroundStyle(.primary).frame(width: 16)
                }
                .help(player.isPlaying ? "Pause" : "Play the recording")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play the recording")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.system(size: 12.5)) }
                    .help("Forward 15 seconds")
            }
            .buttonStyle(.borderless)
            Elapsed(clock: player.clock)
            Scrubber(player: player, clock: player.clock)
            Text(RecordButton.clock(player.duration)).monospacedDigit().frame(minWidth: 34, alignment: .leading)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.leading, 10).padding(.trailing, 14)
        .frame(height: 32)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

private struct Elapsed: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View {
        Text(RecordButton.clock(clock.position)).monospacedDigit().frame(minWidth: 34, alignment: .trailing)
    }
}

private struct Scrubber: View {
    @ObservedObject var player: MeetingPlayer
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        GeometryReader { g in
            let width = g.size.width
            let fraction = player.duration > 0 ? min(1, clock.position / player.duration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: max(4, width * fraction), height: 4)
                ForEach(player.legStarts.filter { $0 > 0 && $0 < player.duration }, id: \.self) { t in
                    Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1.5, height: 10)
                        .offset(x: width * t / player.duration - 0.75)
                }
                Circle().fill(Color.white).frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: width * fraction - 5.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    player.isScrubbing = true
                    clock.position = player.duration * min(1, max(0, v.location.x / max(1, width)))
                }
                .onEnded { _ in
                    player.isScrubbing = false
                    player.seek(to: clock.position)
                })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(RecordButton.clock(clock.position)) of \(RecordButton.clock(player.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(15)
            case .decrement: player.skip(-15)
            @unknown default: break
            }
        }
    }
}

/// Plays the meeting's recording from a transcript time (ms). Equal for the same player, so passing a new one down
/// on every update of the meeting view doesn't invalidate the transcript (a closure would).
struct TranscriptSeek: Equatable {
    private let player: MeetingPlayer
    init(_ player: MeetingPlayer) { self.player = player }
    @MainActor func callAsFunction(_ ms: Int) { player.seek(to: Double(ms) / 1000, play: true) }
    static func == (a: TranscriptSeek, b: TranscriptSeek) -> Bool { a.player === b.player }
}

/// Nil when there is nothing to play.
private struct TranscriptSeekKey: EnvironmentKey {
    static let defaultValue: TranscriptSeek? = nil
}

extension EnvironmentValues {
    var transcriptSeek: TranscriptSeek? {
        get { self[TranscriptSeekKey.self] }
        set { self[TranscriptSeekKey.self] = newValue }
    }
}
