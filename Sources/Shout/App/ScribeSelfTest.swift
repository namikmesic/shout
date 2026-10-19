import AppKit
import AVFoundation
import ShoutKit

/// Development aid: an end-to-end Scribe test on real hardware, run inside the signed app so the app's
/// own Microphone and System Audio Recording permissions apply:
///
///     open -n /Applications/Shout.app --env SHOUT_DEMO_DATA=1 --env SHOUT_SCRIBE_SELFTEST=/path/report.txt
///
/// It plays a synthesized voice through the speakers (as "the other side of the call"), records it with the
/// real ScribeController (process tap + voice-processing microphone), waits for transcription, writes a
/// summary, and reports levels, transcript, echo handling and timings. Uses the throwaway demo database.
///
/// Echo is measured before the text-level filter too: the raw microphone track is transcribed directly,
/// its level is compared with the call audio (echo return loss), and the tracks are cross-correlated
/// (alignment, and whether the microphone carries the call). Simulated dictations time the hand-off.
/// With `SHOUT_SCRIBE_SELFTEST_COMPARE=1` the clip is recorded a second time with echo cancellation
/// off (the setting is restored afterwards).
@MainActor
enum ScribeSelfTest {
    static let script = """
        Hi, thanks for joining. Quick update on the launch. The load tests on the new cluster finished this morning \
        and the results look good, so we can keep the release on Thursday. Priya will send the pricing proposal by \
        Friday, and Marco is going to update the onboarding guide before the demo. One open question is whether \
        the mobile app ships at the same time. Let's decide that on Monday.
        """

    static func runIfRequested(scribe: ScribeController) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["SHOUT_SCRIBE_SELFTEST"] else { return false }
        scribe.onOpenNotepad = nil
        Task { @MainActor in
            var report: [String] = []
            func log(_ s: String) { report.append(s); try? report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
            await run(scribe: scribe, log: log)
            log("DONE")
            NSApp.terminate(nil)
        }
        return true
    }

    private static func run(scribe: ScribeController, log: (String) -> Void) async {
        let t0 = Date()
        func ts() -> String { String(format: "[%5.1fs]", Date().timeIntervalSince(t0)) }
        log("Shout Scribe self-test · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let perms = Permissions.shared
        perms.refresh()
        log("microphone permission: \(perms.microphone == .authorized ? "authorized" : "NOT authorized (\(perms.microphone.rawValue))")")
        log("system audio permission (TCC): \(perms.systemAudio)")

        // Engines.
        let hub = EngineHub.shared
        do {
            let rec = try await hub.currentRecognizer()
            log("\(ts()) speech model ready: \(rec.displayName)")
        } catch { log("FAIL speech model: \(error.localizedDescription)"); return }

        // 1. Plain system-audio check (another process plays a sound; the tap must hear it).
        if #available(macOS 14.4, *) {
            let heard = await SystemAudioCheck.run()
            log("\(ts()) system audio test sound heard: \(heard ? "YES" : "NO")")
            perms.refresh()
            log("system audio permission after test: \(perms.systemAudio)")
        }

        // 1b. The plain microphone, as dictation uses it.
        let recorder = AudioRecorder()
        do {
            try recorder.start(deviceUID: nil)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let samples = recorder.stop()
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            log(String(format: "\(ts()) dictation microphone: %d samples, peak %.4f (default input: %@)", samples.count, peak,
                       AudioRecorder.defaultInputName() ?? "?"))
        } catch { log("dictation microphone failed: \(error.localizedDescription)") }

        // 1c. Voice processing (echo cancellation) setups on this microphone.
        log("\(ts()) \(await MeetingMicCapture.probeUnit())")

        // 2. Synthesize the "other side" of the call.
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("shout-selftest-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: clip) }
        guard runProcess("/usr/bin/say", ["-v", "Samantha", "-o", clip.path, script]), FileManager.default.fileExists(atPath: clip.path) else {
            log("FAIL could not synthesize speech with say"); return
        }
        let clipSeconds = (try? AVAudioDuration.seconds(clip)) ?? 25
        log(String(format: "\(ts()) synthesized %.1f s of speech", clipSeconds))

        // 3. Record it with the real Scribe, and analyse what was recorded and transcribed.
        let settings = SettingsStore.shared
        let echoSetting = settings.settings.scribeEchoCancellation
        guard let first = await record(scribe: scribe, clip: clip, clipSeconds: clipSeconds, ts: ts, log: log) else { return }
        await analyse(first, ts: ts, log: log)
        if ProcessInfo.processInfo.environment["SHOUT_SCRIBE_SELFTEST_COMPARE"] == "1" {
            settings.settings.scribeEchoCancellation = !echoSetting
            log("\(ts()) comparison run with echo cancellation \(echoSetting ? "off" : "on")")
            if let second = await record(scribe: scribe, clip: clip, clipSeconds: clipSeconds, ts: ts, log: log) {
                await analyse(second, ts: ts, log: log)
                Store.shared.deleteMeeting(id: second.id)
            }
            settings.settings.scribeEchoCancellation = echoSetting
        }
        let id = first.id
        let store = Store.shared

        // 5. Summary with the local language model.
        log("\(ts()) writing the summary")
        scribe.summarize(id, force: true)
        let sWait = Date().addingTimeInterval(240)
        while store.meeting(id: id)?.summaryStatus == .generating && Date() < sWait { try? await Task.sleep(nanoseconds: 500_000_000) }
        if let m = store.meeting(id: id) {
            log("\(ts()) summary status: \(m.summaryStatus.rawValue)\(m.error.map { " (\($0))" } ?? "")")
            log("title: \(m.title)")
            if let summary = m.summary { log("summary:\n" + summary) }
            for t in store.tasks(meetingID: id) { log("task: \(t.owner.map { "[\($0)] " } ?? "")\(t.title)") }
        }
        log(String(format: "total %.1f s", Date().timeIntervalSince(t0)))
        // The demo database is thrown away; remove the test recording from disk too.
        store.deleteMeeting(id: id)
    }

    private struct Run {
        let id: String
        let echoCancellation: Bool
        /// The clip's span on the meeting timeline.
        let clipStartMs: Int
        let clipEndMs: Int
    }

    /// Records the clip played through the speakers, then a few simulated dictations, and stops.
    private static func record(scribe: ScribeController, clip: URL, clipSeconds: Double,
                               ts: () -> String, log: (String) -> Void) async -> Run? {
        let echoCancellation = SettingsStore.shared.settings.scribeEchoCancellation
        scribe.start()
        guard let id = scribe.activeMeetingID else { log("FAIL Scribe did not start (permissions or speech model)"); return nil }
        log("\(ts()) recording started, meeting \(id), echo cancellation \(echoCancellation ? "on" : "off")")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let clipStartMs = Int(scribe.elapsed * 1000)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.6", clip.path]
        try? player.run()
        log("\(ts()) playing the clip through the speakers")
        var maxSys: Float = 0, maxMic: Float = 0
        let end = Date().addingTimeInterval(clipSeconds + 3)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 200_000_000)
            maxSys = max(maxSys, scribe.systemLevel); maxMic = max(maxMic, scribe.micLevel)
        }
        log(String(format: "\(ts()) peak meter levels: system %.2f, microphone %.2f", maxSys, maxMic))
        log("notices during recording: \(scribe.notices.isEmpty ? "none" : scribe.notices.map { "\($0)" }.joined(separator: ", "))")
        for line in scribe.micDiagnostics { log("meeting microphone: \(line)") }

        // Dictation hand-off: how long the main thread is held when the meeting microphone pauses and resumes.
        for i in 1...3 {
            var t = Date()
            scribe.dictationWillStart()
            let pause = Date().timeIntervalSince(t)
            try? await Task.sleep(nanoseconds: 800_000_000)
            t = Date()
            scribe.dictationDidEnd()
            let resume = Date().timeIntervalSince(t)
            log(String(format: "dictation hand-off %d: pause %.1f ms, resume %.1f ms on the main thread", i, pause * 1000, resume * 1000))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        for line in scribe.micDiagnostics { log("meeting microphone after the hand-offs: \(line)") }

        scribe.stop()
        log("\(ts()) stopped; waiting for transcription")
        let wait = Date().addingTimeInterval(60)
        while scribe.processingIDs.contains(id) && Date() < wait { try? await Task.sleep(nanoseconds: 300_000_000) }
        return Run(id: id, echoCancellation: echoCancellation, clipStartMs: clipStartMs,
                   clipEndMs: clipStartMs + Int(clipSeconds * 1000))
    }

    /// What was recorded and transcribed, and how much of the call reached the microphone.
    private static func analyse(_ run: Run, ts: () -> String, log: (String) -> Void) async {
        let store = Store.shared
        guard let meeting = store.meeting(id: run.id), let path = meeting.audioPath else { log("FAIL meeting missing"); return }
        let folder = URL(fileURLWithPath: path)
        let length = max(meeting.recordedMs, run.clipEndMs) * 16
        for source in [MeetingSource.mic, .system] {
            let samples = (try? MeetingArchive.read(source, in: folder, offset: 0, count: length)) ?? []
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            log(String(format: "track %@: %.1f s, peak %.3f", source.rawValue, Double(samples.count) / 16_000, peak))
        }
        log("status: \(meeting.status.rawValue), recorded \(meeting.recordedMs / 1000) s, has system audio: \(meeting.hasSystemAudio)")

        // Signal level, before any text filter.
        let start = run.clipStartMs * 16, count = (run.clipEndMs - run.clipStartMs + 1_500) * 16
        let mic = (try? MeetingArchive.read(.mic, in: folder, offset: start, count: count)) ?? []
        let system = (try? MeetingArchive.read(.system, in: folder, offset: start, count: count)) ?? []
        func rms(_ x: [Float]) -> Float { x.isEmpty ? 0 : (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }
        let erle = 20 * log10(max(rms(system), 1e-7) / max(rms(mic), 1e-7))
        log(String(format: "echo return loss over the clip (call audio vs microphone): %.1f dB (mic rms %.4f, call rms %.4f)",
                   erle, rms(mic), rms(system)))
        let evidence = EchoCorrelation.measure(mic: mic, system: system)
        let lags = EchoCorrelation.windows(mic: mic, system: system).compactMap { w in w.score.map { (w.lagMs ?? 0, $0) } }
        let best = lags.max { $0.1 < $1.1 }
        log("track alignment: \(evidence.locked) of \(evidence.bothActive) windows agree on a delay of \(evidence.lagMs.map { "\($0) ms" } ?? "–")"
            + (best.map { String(format: " (best window: %d ms, score %.2f)", $0.0, $0.1) } ?? "")
            + "; the microphone \(evidence.supportsCut ? "CARRIES" : "does not carry") the call audio")

        // The microphone track transcribed directly: echo that voice processing let through.
        let expected = Set(EchoWords.words(script))
        if let recognizer = try? await EngineHub.shared.currentRecognizer() {
            let segmenter = SpeechSegmenter(startPosition: start)
            var raw: [String] = []
            for segment in segmenter.process(mic) + segmenter.flush() {
                let text = (try? await MeetingTranscription.transcribe(segment, recognizer: recognizer,
                                                                       settings: MeetingTranscriptionSettings(language: "en"))) ?? ""
                if !text.isEmpty { raw.append(text) }
            }
            let rawEcho = Set(EchoWords.words(raw.joined(separator: " "))).intersection(expected).count
            log("raw microphone during the clip (before the echo filter): \(rawEcho) of \(expected.count) clip words | \(raw.joined(separator: " "))")
        }

        let segments = store.segments(meetingID: run.id)
        log("transcript (\(segments.count) rows):")
        for s in segments {
            if let m = s.marker { log("  · marker \(m.rawValue) @\(formatTimestamp(ms: s.startMs))"); continue }
            log("  \(s.speakerLabel)\(s.latched ? " [hidden echo]" : "") @\(formatTimestamp(ms: s.startMs)): \(s.displayText)")
        }
        let others = segments.filter { $0.source == .system && !$0.latched }.map(\.displayText).joined(separator: " ")
        let you = segments.filter { $0.source == .mic && !$0.latched }.map(\.displayText).joined(separator: " ")
        let heard = Set(EchoWords.words(others))
        let recall = expected.isEmpty ? 0 : Double(expected.intersection(heard).count) / Double(expected.count)
        log(String(format: "Others transcript word recall vs script: %.0f%%", recall * 100))
        let youEcho = Set(EchoWords.words(you)).intersection(expected).count
        let hidden = segments.filter { $0.source == .mic && $0.latched }.count
        log("words of the clip still credited to You after the echo filter: \(youEcho); You lines hidden as echo: \(hidden)"
            + " (echo cancellation \(run.echoCancellation ? "on" : "off"))")
        log("\(ts()) analysis done")
    }

    @discardableResult
    private static func runProcess(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}

private enum EchoWords {
    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
    }
}

private enum AVAudioDuration {
    static func seconds(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
