import AppKit
import Combine
import ShoutKit

/// The dictation state machine: hotkeys → recording → local pipeline → insertion → learning.
@MainActor
final class DictationController {
    enum Mode { case dictation, command, prompt }

    struct Session {
        let id = UUID()
        var mode: Mode
        var locked: Bool
        let startedAt = Date()
        var pressAt = Date()
        var lockedAt: Date?
        var awaitingSecondPress = false
        var context: DictationContext
        var focus: ContextReader.FocusHandle?
        let app: NSRunningApplication?
        /// When the recording's first sample was taken (screenshots are timed from it).
        var audioStart = Date()
    }

    let settingsStore: SettingsStore
    let store: Store
    let hub: EngineHub
    let flowBar: FlowBarController
    let hotkeys: HotkeyManager
    private let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let sounds = SoundPlayer()
    private let media = MediaController()
    private let editWatcher = EditWatcher()
    /// Screenshots taken during a Prompt mode session (docs/PROMPT_MODE.md, step 2).
    private let screenshots: ScreenshotWatcher
    /// Why a screenshot couldn't be taken, shown once the prompt is pasted (not over the recording), and the page
    /// its Fix button opens.
    private var captureNotice: (text: String, page: String)?

    private(set) var session: Session?
    private var processing: Task<Void, Never>?
    /// The session whose `processing` run owns the state. A cancelled run can still be finishing after a new
    /// session started; it must not clear the new run's state or the Escape hook.
    private var processingID: UUID?
    private var tapTimer: Timer?
    private var warnTimer: Timer?
    private var maxTimer: Timer?
    private var finishedAt = Date.distantPast
    private var lastTranscript: String?
    private var cancellables: Set<AnyCancellable> = []
    /// The app a running dictation goes back to (from its start until it is pasted or cancelled).
    private var targetApp: NSRunningApplication?
    /// Keeps the Flow Bar menu's target alive while the menu is open (menu items hold their target weakly).
    private var menuTarget: MenuTarget?

    var onOpenMainWindow: ((String?) -> Void)?
    /// The Scribe pauses its meeting microphone while dictation uses the microphone. `onMicrophoneDidStop`
    /// comes as soon as the dictation recorder has stopped (key-up, cancel, failure), so the meeting misses
    /// nothing said while the dictation is transcribed and pasted; the meeting microphone restarts off this
    /// path (one run-loop turn later, and without waiting for the voice-processing unit).
    var onMicrophoneWillStart: (() -> Void)?
    var onMicrophoneDidStop: (() -> Void)?
    /// While a meeting is recorded, media is left alone (pausing could pause the call itself).
    var isMeetingRecording: (() -> Bool)?
    /// The Scribe shortcut was pressed.
    var onScribeToggle: (() -> Void)?

    static let tapWindow: TimeInterval = 0.5
    static let commandSwitchWindow: TimeInterval = 1.0

    init(settingsStore: SettingsStore, store: Store, hub: EngineHub, flowBar: FlowBarController) {
        self.settingsStore = settingsStore
        self.store = store
        self.hub = hub
        self.flowBar = flowBar
        self.hotkeys = HotkeyManager(config: Self.hotkeyConfig(settingsStore.settings))
        self.screenshots = ScreenshotWatcher(root: store.capturesRoot)
        // Pictures of prompts whose History entry is gone, and unsaved ones after a week.
        store.pruneCaptures()

        hotkeys.onEvent = { [weak self] e in self?.handle(e) }
        recorder.onLevel = { [weak self] l in self?.flowBar.model.push(level: l) }
        recorder.onDeadMicrophone = { [weak self] in
            self?.flowBar.flash("No audio from the microphone. Check your input device.", kind: .warning, seconds: 4)
        }
        editWatcher.knownWords = { [weak self] in
            Set((self?.store.dictionary ?? []).map { $0.phrase.lowercased() })
        }
        editWatcher.onResult = { [weak self] r in self?.handleEdits(r) }
        screenshots.onChange = { [weak self] n in self?.flowBar.model.captureCount = n }
        screenshots.onCapture = { [weak self] capture in self?.readAhead(capture) }

        flowBar.model.onClick = { [weak self] in self?.startSession(mode: .dictation, locked: true) }
        flowBar.model.onCancel = { [weak self] in self?.cancel(sound: true) }
        flowBar.model.onFinish = { [weak self] in self?.finish() }
        flowBar.model.onRightClick = { [weak self] e in self?.showFlowBarMenu(e) }

        settingsStore.$settings
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.apply(settings: s) }
            .store(in: &cancellables)
        // While a dictation runs, the Flow Bar shows where it goes once the user is in another app.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateAwayTarget() }
            .store(in: &cancellables)
    }

    private func setTargetApp(_ app: NSRunningApplication?) {
        targetApp = app
        updateAwayTarget()
    }

    private func updateAwayTarget() {
        guard let app = targetApp, !app.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else {
            if flowBar.model.awayTarget != nil { flowBar.model.awayTarget = nil }
            return
        }
        let target = FlowBarModel.Target(appName: app.localizedName ?? "the app", bundleID: app.bundleIdentifier)
        if flowBar.model.awayTarget != target { flowBar.model.awayTarget = target }
    }

    static func hotkeyConfig(_ s: AppSettings) -> HotkeyManager.Config {
        .init(pushToTalk: s.pushToTalk, handsFree: s.handsFree, command: s.commandModeEnabled ? s.command : KeyCombo([]),
              pasteLast: s.pasteLast, copyLast: s.copyLast, scribe: s.scribeShortcut,
              prompt: s.promptModeEnabled ? s.promptShortcut : KeyCombo([]))
    }

    private func apply(settings s: AppSettings) {
        hotkeys.update(config: Self.hotkeyConfig(s))
        sounds.enabled = s.soundsEnabled
        sounds.volume = s.soundVolume
        flowBar.model.showWhenIdle = s.showFlowBarWhenIdle
        flowBar.model.hint = "Hold \(s.pushToTalk.displayString) to dictate"
        flowBar.layout(animated: false)
        hub.configure(s)
    }

    /// Starts listening for shortcuts. Returns false when Input Monitoring/Accessibility is missing.
    @discardableResult
    func startHotkeys() -> Bool { hotkeys.start() }

    // MARK: Hotkey state machine

    func handle(_ e: HotkeyEvent) {
        let now = Date()
        let s = settingsStore.settings
        switch e {
        case .pushToTalkDown:
            if var cur = session {
                if cur.awaitingSecondPress {
                    tapTimer?.invalidate()
                    cur.awaitingSecondPress = false
                    session = cur
                    if s.doubleTapLocksHandsFree { lock() }
                } else if cur.locked {
                    if let la = cur.lockedAt, now.timeIntervalSince(la) < Self.tapWindow { cancel(sound: true) }
                    else { finish() }
                }
                return
            }
            guard processing == nil else { return }
            startSession(mode: .dictation, locked: false)

        case .pushToTalkUp:
            guard var cur = session, !cur.locked, cur.mode == .dictation else { return }
            let held = now.timeIntervalSince(cur.pressAt)
            if held >= Self.tapWindow {
                finish()
            } else if s.doubleTapLocksHandsFree {
                cur.awaitingSecondPress = true
                session = cur
                let id = cur.id
                tapTimer?.invalidate()
                tapTimer = Timer.scheduledTimer(withTimeInterval: Self.tapWindow, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let c = self.session, c.id == id, c.awaitingSecondPress else { return }
                        self.cancel(sound: false)
                        self.flowBar.flash("Hold \(s.pushToTalk.displayString) to dictate, or double-tap for hands-free", seconds: 3)
                    }
                }
            } else {
                cancel(sound: false)
                flowBar.flash("Hold \(s.pushToTalk.displayString) to dictate", seconds: 2.5)
            }

        case .handsFreeToggle:
            if let cur = session {
                if !cur.locked { lock(); return }
                let sinceStart = now.timeIntervalSince(cur.lockedAt ?? cur.startedAt)
                if sinceStart < Self.tapWindow { cancel(sound: true) } else { finish() }
                return
            }
            // The fn press of a fn+Space "stop" already finished the session.
            guard processing == nil, now.timeIntervalSince(finishedAt) > 0.7 else { return }
            startSession(mode: .dictation, locked: true)

        case .commandDown:
            guard s.commandModeEnabled else { return }
            if var cur = session {
                if cur.mode == .dictation && !cur.locked && now.timeIntervalSince(cur.startedAt) < Self.commandSwitchWindow {
                    cur.mode = .command
                    session = cur
                    flowBar.show(.listening(handsFree: false, command: true))
                    captureSelectionIfNeeded()
                }
                return
            }
            guard processing == nil else { return }
            startSession(mode: .command, locked: false)

        case .commandUp:
            guard let cur = session, cur.mode == .command, !cur.locked else { return }
            if now.timeIntervalSince(cur.pressAt) < 0.3 { cancel(sound: false) } else { finish() }

        case .promptDown:
            guard s.promptModeEnabled else { return }
            if var cur = session {
                // The second press of a hands-free prompt finishes it.
                if cur.mode == .prompt && cur.locked { finish(); return }
                // fn first, then ⇧: the dictation just started becomes a prompt.
                if cur.mode == .dictation && !cur.locked && now.timeIntervalSince(cur.startedAt) < Self.commandSwitchWindow {
                    cur.mode = .prompt
                    if cur.context.selectedText == nil {
                        cur.context.selectedText = ContextReader.capture(includeText: true).0.selectedText
                    }
                    session = cur
                    if s.promptScreenshotsOn {
                        screenshots.start(audioStart: cur.audioStart, readSavedScreenshots: Permissions.shared.canReadScreenshotFolder)
                        boxedSelections = Set([cur.context.selectedText].compactMap { $0 })
                        getReadyToSeeScreenshots()
                    }
                    flowBar.show(.listening(handsFree: false, command: true))
                }
                return
            }
            guard processing == nil else { return }
            startSession(mode: .prompt, locked: false)

        case .promptUp:
            guard let cur = session, cur.mode == .prompt, !cur.locked else { return }
            if now.timeIntervalSince(cur.pressAt) >= 0.3 { finish() }
            // A tap: with text selected, that text becomes the prompt; otherwise keep listening hands-free.
            else if cur.context.hasSelection { finish(withoutSpeech: true) }
            else { lock() }

        case .markTap:
            guard let cur = session, cur.mode == .prompt else { return }
            // Switched on, but the AI model can't do screenshots: say so after the paste.
            if !screenshots.isActive && s.promptScreenshots && !s.promptScreenshotsAvailable {
                sounds.play(.error)
                captureNotice = ("Screenshots in prompts need a larger AI model, such as Qwen3 4B or Qwen3.5 9B.", "models")
                return
            }
            guard screenshots.isActive else { return }
            // Without Screen Recording: a sound now, and how to fix it once the prompt is pasted (never a macOS
            // question mid-dictation).
            guard WindowCapture.hasPermission else {
                sounds.play(.error)
                captureNotice = ("⌥ screenshots need Screen Recording permission.", "prompts")
                return
            }
            captureWindow()

        case .screenshotKeys:
            if screenshots.isActive { screenshots.noteScreenshotKeys() }

        case .cancel:
            if session != nil { cancel(sound: true) }
            else if let p = processing {
                p.cancel(); processing = nil; processingID = nil
                setTargetApp(nil)
                hotkeys.setSessionActive(false)
                flowBar.flash("Cancelled", seconds: 1.2)
            }

        case .interrupted:
            if let cur = session, !cur.locked, now.timeIntervalSince(cur.startedAt) < Self.commandSwitchWindow {
                cancel(sound: false, silent: true)
            }

        case .pasteLast:
            pasteLast()

        case .scribeToggle:
            onScribeToggle?()

        case .copyLast:
            if let t = lastTranscript ?? store.lastInsertableEntry()?.finalText {
                TextInserter.copy(t)
                flowBar.flash("Last transcript copied", kind: .success, seconds: 1.5)
            }
        }
    }

    // MARK: Session lifecycle

    func startSession(mode: Mode, locked: Bool) {
        guard session == nil, processing == nil else { return }
        let perms = Permissions.shared
        perms.refresh()
        guard perms.microphone == .authorized else {
            sounds.play(.error)
            flowBar.flash("Shout needs microphone access", kind: .error, action: "Fix", seconds: 4) { [weak self] in
                self?.onOpenMainWindow?("onboarding")
            }
            return
        }
        if case .missingModel(let name) = hub.speechState {
            sounds.play(.error)
            flowBar.flash("\(name) is not downloaded", kind: .warning, action: "Models", seconds: 4) { [weak self] in
                self?.onOpenMainWindow?("models")
            }
            return
        }
        let s = settingsStore.settings
        let app = NSWorkspace.shared.frontmostApplication
        // Start the microphone first: reading context can take a moment in slow apps,
        // and the first words must not be lost.
        onMicrophoneWillStart?()
        let audioStart = Date()
        do {
            do {
                try recorder.start(deviceUID: s.microphoneUID)
            } catch where isMeetingRecording?() == true {
                // The meeting microphone was just released; the device can need a moment to settle.
                Thread.sleep(forTimeInterval: 0.15)
                try recorder.start(deviceUID: s.microphoneUID)
            }
        } catch {
            onMicrophoneDidStop?()
            sounds.play(.error)
            flowBar.flash(error.localizedDescription, kind: .error, seconds: 4)
            return
        }
        let (ctx, focus) = ContextReader.capture(includeText: s.useContext || s.autoLearnWords || mode != .dictation)
        var newSession = Session(mode: mode, locked: locked, context: ctx, focus: focus, app: app)
        newSession.audioStart = audioStart
        if locked { newSession.lockedAt = Date() }
        session = newSession
        setTargetApp(app)
        captureNotice = nil
        if mode == .prompt && s.promptScreenshotsOn {
            Permissions.shared.refresh()
            screenshots.start(audioStart: audioStart, readSavedScreenshots: Permissions.shared.canReadScreenshotFolder)
            // A selection the prompt started with is its material, not something to box (unless pointed at).
            boxedSelections = Set([ctx.selectedText].compactMap { $0 })
            getReadyToSeeScreenshots()
        }
        hotkeys.setSessionActive(true)
        if isMeetingRecording?() != true { media.begin(s.mediaBehavior) }
        sounds.play(locked ? .lock : .start)
        flowBar.model.resetLevels()
        flowBar.show(.listening(handsFree: locked, command: mode != .dictation))
        if mode == .command { captureSelectionIfNeeded() }

        warnTimer?.invalidate(); maxTimer?.invalidate()
        warnTimer = Timer.scheduledTimer(withTimeInterval: 19 * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sounds.play(.lock) }
        }
        maxTimer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    private func lock() {
        guard var cur = session, !cur.locked else { return }
        cur.locked = true
        cur.lockedAt = Date()
        session = cur
        sounds.play(.lock)
        flowBar.show(.listening(handsFree: true, command: cur.mode != .dictation))
    }

    /// Command Mode needs the selection; fall back to ⌘C only for apps that expose no AXSelectedText at
    /// all (an empty string means "nothing selected", and ⌘C would copy the whole line in some editors).
    private func captureSelectionIfNeeded() {
        guard let cur = session, cur.context.selectedText == nil else { return }
        let id = cur.id
        Task { @MainActor in
            if let text = await ContextReader.selectedTextViaCopy(), var s = self.session, s.id == id {
                s.context.selectedText = text
                self.session = s
            }
        }
    }

    func cancel(sound: Bool, silent: Bool = false) {
        tapTimer?.invalidate(); warnTimer?.invalidate(); maxTimer?.invalidate()
        guard session != nil else { return }
        session = nil
        setTargetApp(nil)
        screenshots.cancel()
        recorder.cancel()
        onMicrophoneDidStop?()
        media.end()
        hotkeys.setSessionActive(false)
        if sound && !silent { sounds.play(.cancel) }
        flowBar.show(.idle)
    }

    /// `withoutSpeech`: a Prompt mode tap on selected text, which needs no recording.
    func finish(withoutSpeech: Bool = false) {
        tapTimer?.invalidate(); warnTimer?.invalidate(); maxTimer?.invalidate()
        guard let cur = session else { return }
        session = nil
        finishedAt = Date()
        var samples = recorder.stop()
        if withoutSpeech { samples = [] }
        onMicrophoneDidStop?()
        media.end()
        sounds.play(.stop)
        // Prompt mode works on selected text alone.
        let selectionPrompt = cur.mode == .prompt && cur.context.hasSelection
        guard samples.count > Int(0.25 * 16_000) || selectionPrompt else {
            setTargetApp(nil)
            screenshots.cancel()
            hotkeys.setSessionActive(false)
            flowBar.show(.idle)
            return
        }
        if samples.count <= Int(0.25 * 16_000) { samples = [] }
        flowBar.show(.processing(command: cur.mode != .dictation))
        processingID = cur.id
        processing = Task { [weak self] in
            await self?.process(cur, samples: samples)
        }
    }

    // MARK: Processing

    private func process(_ session: Session, samples: [Float]) async {
        defer {
            if processingID == session.id {
                processing = nil; processingID = nil
                hotkeys.setSessionActive(false)
                setTargetApp(nil)
            }
        }
        let s = settingsStore.settings
        let input = PipelineInput(samples: samples, context: session.context, settings: s, dictionary: store.dictionary)
        let started = Date()
        var promptWritten = false
        var promptFailed = false
        // Screenshots taken while describing the prompt, each tied to the words said then.
        // Shout's own copies: the prompt and History keep working when a screenshot leaves the Desktop.
        let captures = session.mode == .prompt ? screenshots.keepCopies(await screenshots.finish()) : []
        // Taken now: by the time the prompt is written, a new session may have started with a folder of its own.
        let captureFolder = captures.isEmpty ? nil : screenshots.sessionFolder
        if session.mode == .prompt && screenshots.missedSavedScreenshots && captureNotice == nil {
            captureNotice = ("Screenshots saved to \(ScreenshotWatcher.screenshotFolder().lastPathComponent) were left out: Shout needs to be allowed to read that folder.", "prompts")
        }
        var anchors: [String] = []
        do {
            var partial = PipelineOutput()
            if !samples.isEmpty {
                let recognizer = try await hub.currentRecognizer()
                if captures.isEmpty {
                    partial = try await DictationPipeline.transcribe(input, recognizer: recognizer)
                } else {
                    let (p, marked) = try await DictationPipeline.transcribeMarked(input, times: captures.map(\.time),
                                                                                    recognizer: recognizer)
                    partial = p
                    anchors = marked.anchors
                }
            }
            if Task.isCancelled { return }

            var out = partial
            var instruction: String?
            if session.mode == .prompt {
                guard !partial.rawText.isEmpty || session.context.hasSelection else { showEmpty(); return }
                do {
                    let gen = try await hub.generatorLoadingIfNeeded()
                    let r = try await DictationPipeline.runPrompt(spoken: partial.rawText, input: input, generator: gen,
                                                                  captures: captures, anchors: anchors)
                    out.finalText = r.text
                    out.llmSeconds = r.seconds
                    out.llmNote = r.picturesSeen > 0 ? "The model looked at \(r.picturesSeen) screenshot\(r.picturesSeen == 1 ? "" : "s")" : nil
                    promptWritten = true
                    hub.primeCleanupCache(s)
                } catch DictationPipeline.PromptModeError.tooShort {
                    // Nothing pasted: there was no request to write a prompt from. A missing permission explains more.
                    if let notice = captureNotice {
                        captureNotice = nil
                        flowBar.flash(notice.text, kind: .warning, action: "Fix", seconds: 8) { [weak self] in self?.onOpenMainWindow?(notice.page) }
                    } else {
                        flowBar.flash(DictationPipeline.PromptModeError.tooShort.localizedDescription, kind: .info, seconds: 4)
                    }
                    return
                } catch where !(error is CancellationError) && !session.context.hasSelection && !partial.rawText.isEmpty {
                    // What was said is pasted as dictated rather than lost. A selection is never replaced by it.
                    if Task.isCancelled { return }
                    out = await DictationPipeline.format(partial, input: input, generator: nil)
                    if !captures.isEmpty { out.finalText += "\n\n" + PromptScreenshots.section(captures, anchors: anchors) }
                    out.llmNote = "Prompt not written: \(error.localizedDescription)"
                    promptFailed = true
                }
            } else if session.mode == .command {
                guard !partial.rawText.isEmpty else { showEmpty(); return }
                instruction = partial.rawText
                let gen = try await hub.currentGenerator()
                let (result, secs) = try await DictationPipeline.runCommand(instruction: partial.rawText, input: input, generator: gen)
                out.finalText = result
                out.llmSeconds = secs
                hub.primeCleanupCache(s)
            } else {
                let gen = s.cleanupLevel == .off ? nil : (try? await hub.currentGenerator())
                out = await DictationPipeline.format(partial, input: input, generator: gen)
            }
            if Task.isCancelled { return }
            guard !out.isEmpty else { showEmpty(); return }

            if session.context.isSecure {
                flowBar.flash("Shout doesn't type into password fields", kind: .warning, seconds: 3)
                return
            }

            // Back to the field the dictation started in, wherever the user went meanwhile. Text that replaces a
            // selection (Command and Prompt mode) needs that selection still there.
            let replacing = session.mode != .dictation && session.context.hasSelection ? session.context.selectedText : nil
            let target = await ContextReader.returnTo(session.focus, app: session.app, selection: replacing)
            if Task.isCancelled { return }

            let outcome: TextInserter.Outcome
            var lostTarget: String?
            if case .lost(let why) = target {
                // Never pasted somewhere else: it waits on the clipboard.
                TextInserter.copy(out.finalText)
                outcome = .copiedOnly
                lostTarget = "Couldn't get back to \(session.app?.localizedName ?? "the app"): \(why). It's on your clipboard."
            } else {
                inserter.restoreClipboard = s.restoreClipboard
                outcome = await inserter.insert(out.finalText)
            }
            if out.pressEnter && outcome == .pasted {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if !Task.isCancelled { TextInserter.pressKey(36) }
            }
            lastTranscript = out.finalText

            var historyID: Int64 = 0
            if s.retention != .never {
                var audioPath: String?
                if s.saveAudio {
                    let url = AppPaths.recordings.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).wav")
                    if (try? AudioDSP.wavData(samples).write(to: url)) != nil { audioPath = url.path }
                }
                historyID = store.addHistory(HistoryEntry(
                    id: 0, createdAt: Date(),
                    mode: session.mode == .command ? .command : (session.mode == .prompt && !promptFailed ? .transform : .dictation),
                    status: outcome == .pasted ? .inserted : .copied, rawText: out.rawText, finalText: out.finalText,
                    editedText: nil, appName: session.context.appName, bundleID: session.context.bundleID,
                    url: session.context.url, audioSeconds: out.audioSeconds, asrSeconds: out.asrSeconds,
                    llmSeconds: out.llmSeconds, totalSeconds: Date().timeIntervalSince(started),
                    wordCount: TextRules.wordCount(out.finalText), language: out.language,
                    asrModel: samples.isEmpty ? nil : s.speechModel.name,
                    llmModel: s.cleanupLevel == .off && session.mode != .prompt ? nil : s.languageModel.name,
                    audioPath: audioPath, error: out.llmNote, instruction: instruction))
            }
            store.bumpUsage(ids: out.usedEntryIDs)
            // The pictures go with the History entry, with what was said when each was taken.
            if !captures.isEmpty, let folder = captureFolder {
                let saved = PromptCaptureArchive.Saved(historyID: nil, createdAt: Date(), captures: captures.enumerated().map { i, c in
                    c.record(said: i < anchors.count ? anchors[i] : "")
                })
                try? PromptCaptureArchive.save(saved, in: folder)
                if historyID != 0 { PromptCaptureArchive.attach(folder: folder, historyID: historyID, root: store.capturesRoot) }
            }

            // Esc during the paste wait cancels this run, but ⌘V already went out, so the history entry above
            // stays. The Flow Bar and the edit watcher may belong to a newer dictation by now.
            guard processingID == session.id else { return }
            if let lostTarget {
                flowBar.flash(lostTarget, kind: .warning, seconds: 5)
            } else if outcome == .copiedOnly {
                flowBar.flash("Copied to clipboard. Press ⌘V to paste.", kind: .info, seconds: 3)
            } else if outcome == .notPasted {
                flowBar.flash("Couldn't paste. The text is in History.", kind: .info, seconds: 3)
            } else if promptFailed {
                flowBar.flash("Couldn't write the prompt, so your words were pasted. See History.", kind: .warning, seconds: 4)
            } else if let notice = captureNotice {
                captureNotice = nil
                flowBar.flash(notice.text, kind: .warning, action: "Fix", seconds: 8) { [weak self] in
                    self?.onOpenMainWindow?(notice.page)
                }
            } else if promptWritten {
                let shots = captures.isEmpty ? "" : " with \(captures.count) screenshot\(captures.count == 1 ? "" : "s")"
                flowBar.flash("Prompt\(shots)", kind: .success, seconds: 2)
            } else {
                flowBar.success()
                if s.autoLearnWords, session.mode == .dictation, let focus = session.focus, historyID != 0 {
                    editWatcher.start(handle: focus, inserted: out.finalText, historyID: historyID)
                }
            }
        } catch {
            if Task.isCancelled { return }
            sounds.play(.error)
            flowBar.flash(error.localizedDescription, kind: .error, seconds: 4)
        }
    }

    /// A tap of ⌥ in Prompt mode: the window under the mouse, timed where the recording is now.
    /// Prompt mode with a model that looks at the screenshots: its image reader loads as the recording starts.
    private func getReadyToSeeScreenshots() {
        guard settingsStore.settings.promptModelSeesScreenshots else { return }
        Task { [hub] in await (try? await hub.generatorLoadingIfNeeded())?.prepareImages() }
    }

    /// The model reads each screenshot while the user is still talking, so feeding it in is all that's left when they
    /// finish. Not one of the captures finishing waits for: transcription needn't wait for it.
    private func readAhead(_ capture: PromptCapture) {
        let s = settingsStore.settings
        guard s.promptModelSeesScreenshots else { return }
        Task { [hub] in
            guard let generator = try? await hub.generatorLoadingIfNeeded() else { return }
            await DictationPipeline.readAhead(capture, settings: s, generator: generator)
        }
    }

    /// Selections already boxed in this prompt: one still selected later isn't boxed again unless the mouse is on it.
    private var boxedSelections: Set<String> = []

    /// The ⌥ capture: the window under the mouse with a ring; or, with text selected, its window with a box around the
    /// text, which the prompt then quotes (with its file and lines in an editor).
    private func captureWindow() {
        let time = recorder.duration
        let name = "capture-\(Int(time * 10))"
        let folder = screenshots.folder()
        let selection = selectionToBox()
        screenshots.run { [weak self] in
            guard let self else { return }
            do {
                let (path, detail) = try await WindowCapture.captureUnderMouse(into: folder, name: name, highlight: selection?.bounds)
                self.screenshots.add(PromptCapture(time: time, path: path, source: .shout,
                                                   detail: selection == nil ? detail : WindowCapture.windowOnly(detail),
                                                   selection: selection?.text, location: selection?.location))
            } catch {
                self.captureNotice = (error.localizedDescription, "prompts")
            }
        }
    }

    private func selectionToBox() -> ScreenSelection? {
        guard let selection = SelectionReader.current() else { return nil }
        let mouseOnIt = selection.bounds.map { $0.insetBy(dx: -40, dy: -40).contains(WindowCapture.mouse()) } ?? false
        guard mouseOnIt || !boxedSelections.contains(selection.text) else { return nil }
        boxedSelections.insert(selection.text)
        return selection
    }

    private func showEmpty() {
        flowBar.flash("No speech detected", kind: .info, seconds: 1.6)
    }

    private func handleEdits(_ r: EditWatcher.Result) {
        store.setEditedText(id: r.historyID, text: r.edited)
        guard settingsStore.settings.autoLearnWords, !r.candidates.isEmpty else { return }
        var added: [String] = []
        for c in r.candidates where store.addDictionaryEntry(phrase: c.corrected, source: .auto, observedAs: c.heard) {
            added.append(c.corrected)
        }
        guard !added.isEmpty else { return }
        let label = added.map { "“\($0)”" }.joined(separator: ", ")
        flowBar.flash("Added \(label) to your dictionary", kind: .success, action: "Undo", seconds: 5) { [weak self] in
            guard let self else { return }
            for e in self.store.dictionary where added.contains(e.phrase) && e.source == .auto {
                self.store.deleteDictionaryEntry(id: e.id)
            }
            self.flowBar.flash("Removed", seconds: 1.2)
        }
    }

    func pasteLast() {
        guard let text = lastTranscript ?? store.lastInsertableEntry()?.finalText else {
            flowBar.flash("Nothing to paste yet", seconds: 1.5); return
        }
        Task { @MainActor in
            let outcome = await inserter.insert(text)
            if outcome == .copiedOnly { flowBar.flash("Copied to clipboard. Press ⌘V to paste.", seconds: 2.5) }
            else if outcome == .notPasted { flowBar.flash("Couldn't paste.", seconds: 2.5) }
        }
    }

    func paste(_ text: String) {
        Task { @MainActor in _ = await inserter.insert(text) }
    }

    // MARK: Flow Bar menu

    private func showFlowBarMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Paste last transcript", action: #selector(MenuTarget.pasteLast), keyEquivalent: "")
        menu.addItem(withTitle: "Start hands-free dictation", action: #selector(MenuTarget.handsFree), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide for 1 hour", action: #selector(MenuTarget.hide), keyEquivalent: "")
        menu.addItem(withTitle: "Open History", action: #selector(MenuTarget.history), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(MenuTarget.settings), keyEquivalent: "")
        let target = MenuTarget(controller: self)
        for item in menu.items { item.target = target }
        menuTarget = target
        NSMenu.popUpContextMenu(menu, with: event, for: event.window?.contentView ?? NSView())
    }

    final class MenuTarget: NSObject {
        weak var controller: DictationController?
        init(controller: DictationController) { self.controller = controller }
        @MainActor @objc func pasteLast() { controller?.pasteLast() }
        @MainActor @objc func handsFree() { controller?.startSession(mode: .dictation, locked: true) }
        @MainActor @objc func hide() {
            controller?.flowBar.model.hiddenUntil = Date().addingTimeInterval(3600)
            controller?.flowBar.layout(animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3601) { [weak controller] in controller?.flowBar.layout(animated: false) }
        }
        @MainActor @objc func history() { controller?.onOpenMainWindow?("history") }
        @MainActor @objc func settings() { controller?.onOpenMainWindow?("settings") }
    }
}
