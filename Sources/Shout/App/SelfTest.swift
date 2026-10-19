import AppKit
import ShoutKit

/// Development aid: `SHOUT_SELFTEST=/path/audio.wav Shout` runs the full local pipeline inside the
/// signed app bundle (embedded frameworks, Metal, hardened runtime), prints the result and quits.
@MainActor
enum SelfTest {
    static func runIfRequested() -> Bool {
        guard let path = ProcessInfo.processInfo.environment["SHOUT_SELFTEST"] else { return false }
        Task { @MainActor in
            func log(_ s: String) { FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!) }
            let settings = SettingsStore.shared.settings
            let hub = EngineHub.shared
            hub.configure(settings)
            do {
                let t0 = Date()
                let rec = try await hub.currentRecognizer()
                let gen = try await hub.currentGenerator()
                log(String(format: "engines ready in %.2fs: %@ + %@", Date().timeIntervalSince(t0), rec.displayName, gen?.displayName ?? "none"))
                let samples = try AudioDSP.loadAudioFile(URL(fileURLWithPath: path))
                let ctx = DictationContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", isEditable: true)
                let input = PipelineInput(samples: samples, context: ctx, settings: settings, dictionary: Store.shared.dictionary)
                try await Task.sleep(nanoseconds: 3_000_000_000) // let background cache priming finish
                for run in 1...2 {
                    let t1 = Date()
                    let partial = try await DictationPipeline.transcribe(input, recognizer: rec)
                    let out = await DictationPipeline.format(partial, input: input, generator: gen)
                    if run == 1 {
                        log("raw:   \(out.rawText)")
                        log("final: \(out.finalText)")
                    }
                    log(String(format: "run %d: asr %.3fs | llm %.3fs | total %.3fs", run, out.asrSeconds, out.llmSeconds, Date().timeIntervalSince(t1)))
                }
            } catch {
                log("SELFTEST FAILED: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        }
        return true
    }
}
