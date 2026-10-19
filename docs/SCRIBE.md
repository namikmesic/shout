# Scribe

Scribe records calls on this Mac: your microphone ("You") and the Mac's audio ("Others") as two aligned tracks,
transcribed live, then summarized with titles, tasks and Ask, all with local models. Nothing leaves the Mac.

Decisions:

- Auto-detection **and** manual start.
- The **You / Others** split is required.
- **Audio is kept on disk** after transcription.
- Summaries use the shared dictation model and run when dictation is idle.
- An always-visible recording indicator, plus a one-time reminder to tell participants.

## 1. Design

| Concern | How Scribe does it |
|---|---|
| System audio | Core Audio process tap: `CATapDescription` global tap, **excluding Shout's own process**, private aggregate device, IO proc. **macOS 14.4+**; older systems record mic-only with a banner. Stereo is downmixed, not left channel only. |
| Permission check | A private TCC call for status and request (with a timeout). An all-zero stream while another app plays is treated as "broken" → rebuild ladder, then a notice. Listen for `kAudioHardwarePropertyServiceRestarted`. |
| Meeting mic | Apple's voice-processing unit on the default input (Apple AEC uses the system output as reference). Ducking minimized. Follows default-device changes. Kept separate from the dictation recorder. |
| Dictation during a meeting | The meeting mic pauses (a `dictated` marker), so the two recorders never fight over the input. |
| Tracks on disk | `~/Library/Application Support/Shout/Meetings/<id>/mic.pcm` and `system.pcm` (16 kHz mono Int16, periodic fsync). **Zero-padded to wall-clock time**, so both tracks stay aligned. |
| Archive | Stereo **AAC .m4a, L = mic, R = system**, 16 kHz, about 48 kbps (≈ 21.6 MB/h). Written as partial, verified, then renamed; PCM deleted only after verification. **Kept indefinitely** (user's choice); deleting a meeting deletes it. |
| Echo bleed into "You" | Voice processing, plus a text match that may cut or hide a "You" line only when GCC-PHAT on the two tracks confirms the echo. Hidden lines are flagged `latched`; the original text is kept. There is no streaming gate. |
| Live transcript | Per source, VAD-endpointed segments (cut at pauses, ≤ 30 s) transcribed by the shared recognizer as recording goes. Parakeet takes about 0.1 s per 10 s, so dictation is barely delayed. Entries labelled **You** (mic) / **Others** (system). |
| Refine | Not built. Planned: an optional Whisper pass using the dictionary and attendee names as prompt; diarization of "Others" into Speaker 1…n (needs a speaker-embedding model). |
| Speaker names | Built (§4): an AX speaker timeline from Zoom, Meet, Teams and Slack, with vote rules applied to each "Others" line, plus Rename and "Not X". Not yet tested on a live call. |
| Summary | Local LLM, **map-reduce** within the model's context (Qwen3 4B: 8192 tokens). Same Markdown shape (overview, `##` topics, `## Next steps` with owners). "Too short" sentinel. Not auto-run for meetings ≤ 5 min ("Generate summary" button). "Update summary" after Resume. `EngineHub.primeCleanupCache` afterwards. |
| Title | Local LLM, 3–6 words, at every stop and in a launch scan, only when the title is blank. |
| To-dos | Local structured pass over Next steps → `todos` rows (open / in progress / done, archived, `sortOrder` steps of 1000; deleting a meeting archives its to-dos). My Tasks page. |
| Detection | Microphone holders, read natively: process objects with `kAudioProcessPropertyIsRunningInput`/`BundleID` and listeners, read on a private queue. A bundle-ID allowlist of call apps and browsers (`MeetingDetection`), compared case-insensitively. `AXWebArea`→`AXURL` for browsers; Slack huddle titles; Zoom by `AXIdentifier`. |
| Prompt | A card in the Flow Bar panel: event title or "Meeting detected", [Start Scribe] [Not now], ⌄ menu (Join meeting, Snooze for 2 min, Start automatically, Notification settings), 20 s auto-dismiss, decline latch, optional 10 s auto-start (default off). |
| Auto-stop | A confidence ladder: holder loss 1.5 s → window 1 / 3.5 / 5.5 s → "Scribe stopping" [Keep going] [Stop] ≥ 6 s → stop. Auto-resume on the same meeting code within 120 s (600 s for the same event). Safety nets: the "Meeting still going?" and "Still taking notes" cards and the maximum length (§3). |
| Calendar | **EventKit** (local; sees every account in Calendar.app). Conference URL from `url`/`notes`/`location`. Calls are matched to events in 3 steps (`CalendarMatcher`); `EKEventStoreChanged` keeps the list current. Reminder card 15 s before start. Needs `NSCalendarsFullAccessUsageDescription`. |
| Transcript storage | SQLite `meeting_segments` (enables search, simple migrations); corrections stored in-row. |
| Playback | Built: a player under the meeting header, with click-to-seek from transcript timestamps (possible because audio is kept). |
| Ask | Built without a tool loop: one prompt per question, fitted to the local model's context (transcript head, tail and keyword lines), with saved chats. |
| Consent | One-time reminder plus a "Copy consent message" button; no auto-typing into other apps. |

## 2. Storage

The schema is created in one step (`Store.migrate`, `user_version` 1): `Store.schema` for History, the Dictionary
and Notes, `Store.meetingsSchema` and `Store.speakersSchema` for Scribe. A later version adds a step that runs once,
in one transaction with its version.

```
meetings(id TEXT PK, title, created_at, started_at, ended_at, recorded_ms, status,         -- recording|processing|complete|failed|idle
         calendar_event_id, calendar_occurrence_start, participant_names JSON, notes, summary,
         summary_stop_seq, latest_stop_seq, processed_stop_seq, audio_path, has_system_audio,
         source_app, source_bundle_id, error, modified_at,
         summary_status, summary_overview, summary_edited, summary_ready_seq, summary_notified_seq,
         title_attempt_seq)
meeting_segments(id TEXT PK, meeting_id FK, seq, source,                                    -- mic|system|marker
                 speaker, start_ms, end_ms, text, raw_text, edited_text, words, latched, marker,
                 epoch, speaker_origin)                                                     -- ax|user
todos(id TEXT PK, meeting_id NULL FK, title, status, is_archived, sort_order, created_at, modified_at,
      owner, is_deleted, source_key, archived_at, meeting_title, meeting_created_at)
folders(id TEXT PK, name, created_at, sort_order);  meeting_folders(meeting_id, folder_id)
ask_chats(id TEXT PK, meeting_id NULL FK, title, created_at, modified_at, last_accessed_at)
ask_messages(id TEXT PK, chat_id FK, turn_id, local_order, role, status, content, metadata, created_at)
meeting_speaker_spans(id PK, meeting_id FK, leg, start_ms, end_ms, platform, state, speaker_name,
                      speaking JSON, muted JSON, self_name, source, reason)
meeting_speaker_aliases(meeting_id FK, from_key, to_name)                                   -- the user's renames
```

## 3. As built

**Capture** (`Shout/System`, `ShoutKit/Meetings`)

| Piece | Where | Notes |
|---|---|---|
| System audio | `SystemAudioCapture.swift` | **Tap.** Private mono global tap excluding Shout, in a tap-only private aggregate; no `tapautostart`. The output-device-clocked fallback is used only for a device with no input streams and no Bluetooth transport, so a headset never joins and stays out of call mode. <br>**Rebuilds.** A stall rebuilds in the same layout; it flips only after 2 failed rebuilds, and only to a safe device. A Core Audio service restart rebuilds everything (listeners included) after 1 s. Also rebuilt on output, rate and (macOS 14) tap-format changes. <br>**Threads.** The IO proc runs on the HAL thread and only pushes into the real-time queue. |
| Meeting microphone | `MeetingMicCapture.swift`, `VoiceProcessingInput.swift` | **Unit.** Apple's voice-processing unit on the default input, started and stopped on a private queue, so the main thread never waits. S16 fallback, then the raw mic. A failure is latched per device and retried after 60 s. <br>**Watchdog.** No buffer for 4 s → restart (4/4/8/16/30 s), then the "Shout isn't hearing your microphone" card. <br>**Devices.** Follows the default devices by comparing them with the bound ones; changes are coalesced. <br>**Dictation.** Paused during dictation (`dictated` marker). The dictation recorder waits at most 0.3 s for the release (`MicrophoneRelease`). Stale chunks from an old unit are dropped. |
| Real-time hand-off | `RealtimeAudioQueue.swift` | Preallocated lock-free pool (256 × 2048 frames, at least 2 s at any callback size). Callbacks are packed. Drops are counted, logged once per episode and realigned. No locks or allocation on IO threads. |
| Aligned tracks | `MeetingTrack.swift` | Append-only 16 kHz Int16 per source, on the host clock. Gaps over 60 ms are padded, sparsely. Both tracks are equalised at every Stop, so Resume appends at the same position. A failed write keeps the timeline, and the next write lands in place. Errors show a banner and the "Meeting audio isn't being saved" card. |
| Liveness | `CaptureHealth.swift` | Silence ≥ 10 s while the call's own processes (else any other app) play audio → rebuild (3, or 1 if the tap never heard anything; 0/10/30 s), then a notice with backoff. A tap heard since its last rebuild is only suspected after 60 s and never shows the notice, so a muted audience is not a dead tap. |
| Archive | `MeetingArchive.swift` | **Encode.** After transcription: stereo AAC `.m4a` (L = You, R = Others, 16 kHz, 48 kbps). It is written as a partial file with full fsyncs, decoded in full to verify, then atomically renamed. Both raw tracks are deleted together, or neither. <br>**Resume** recreates the raw tracks at once, sparsely, and decodes the archive back into them in the background (`restore.pending`). <br>**Discard** of a leg trims and re-archives. <br>**Launch** finishes interrupted encodes and restores. |
| Echo | `EchoCorrelation.swift`, `EchoMatcher` | Runs of 3+ words a "You" line shares with overlapping "Others" lines are cut, or the line is hidden (`latched`). That happens only when GCC-PHAT on the two tracks agrees: 8 kHz, 1 s windows every 256 ms, lags −40…350 ms, within ±35 ms. With headphones or double talk, the user's words stay. The original is kept in `raw_text`. |
| Segmentation, transcription | `SpeechSegmenter.swift`, `MeetingTranscriber.swift` | 30 ms energy VAD with an adaptive floor. An utterance ends at a 0.7 s pause, at 0.3 s past 15 s, and is hard-cut at 28 s. One utterance at a time on the shared recognizer. Padding skips the VAD. |

**Recorder and cards** (`ScribeController.swift`, `FlowBar.swift`)

- **Start, Stop, Resume.** Tracks are opened before any row or marker is written. A failure shows "Couldn't start
  recording" [Discard] [Try again]. Left unanswered, a leg with no audio is discarded unless the user typed notes.
- **Card slot.** Priorities run reminder < info < detected < resume < stopping < alert. A refused or superseded
  stopping banner hands the stop back. Card callbacks act only on their own card.
- **Cards:**
  - detected, with the event title, a ticking countdown and a ⌄ menu (Join meeting, Snooze for 2 min, Start automatically, Notification settings); hover pauses it;
  - reminder; stopping; stopped / Resume;
  - sleep Resume (12 s), with "Start new note" when another call is waiting;
  - "Meeting still going?": 10 min, only after a line in the leg;
  - "Still taking notes": at the event end + 10 min or after 1 h of leg time, with a setting;
  - "Continue transcribing?" and the "Change auto-end time?" picker; "Transcription will end soon";
  - "Started by mistake?": under 20 words in the leg, and Discard removes only that leg;
  - "Shout isn't hearing your microphone"; "Meeting audio isn't being saved".
- **Max length.** The cap is the setting, at most 2 h 58 min, counted over the whole note. Resume of a full note is
  refused.
- **Sleep and quitting:**
  - Sleep stops synchronously, at the sleep time. Wake shows the Resume card, and a call with the same meeting code
    auto-resumes.
  - A fast user switch stops at once.
  - Display sleep is blocked while recording.
  - Quit flushes unsaved edits.
- **Crash recovery** uses the newest audio mtime and a bounded scan, and knows about the archive.
- **Summary ready.** "Your summary is ready!" is a system notification, posted once per summary and not while that
  note is in front.

**Detection and calendar** (`MeetingDetection.swift`, `CallDetector`, `MicActivityMonitor`, `CallContextProbe`,
`CalendarModels.swift`, `CalendarService`)

- **Core Audio** reads and listener updates run on a private queue. Every listener is re-registered after a Core
  Audio restart. The bound app is re-read every 0.5 s.
- **Browsers.** A marked tab keeps its own URL and never adopts a stale one. Confirmed browser calls are re-probed
  every 15 s, preferring the code already followed.
- **Native apps.** Zoom is recognized by `AXIdentifier`. The Slack huddle marker lasts 5 min.
- **Card.** It is matched with the calendar before it shows, and updated in place up to 3 times. A late update
  restarts its timeout. A prompt is held while hidden behind another card.
- **Auto-start** needs the setting, onboarding done, someone at the Mac, nothing recording, the microphone allowed and
  system audio not refused, the speech model, and a call that may auto-start (or a native call of a calendar event).
  Lock, screen sleep, user switch and opening the menu cancel the countdown but keep the card.
- **Binding:**
  - Join + Start binds the event's call, not one already holding the mic;
  - an unbound recording binds only a call of its event (≤ 24 tries);
  - a manual start binds only a qualifying call;
  - a vague `.other` browser result never latches or keeps alive a real meeting.
- **Auto-resume** needs the same meeting code: within 120 s, or 600 s for the same calendar occurrence, at most 2
  times. Code-less calls get a normal prompt.
- **Near the calendar end** the windows are 3.5 s / 1 s, with no 15 s guard. Banner [Stop] expedites the stop.
- **Calendar.** EventKit, reminders and a 120 s join intent.
- **Menu-bar title:** 10-min lead, "now", "N left", midpoint, "Free until / from / after",
  "N meetings", 30 characters, every minute.
- **Tray menu:** Join Meeting, Now / Today / Tomorrow, Past Notes ▸, the next-meeting toggle.

**After the meeting** (`MeetingSummarizer`, `MeetingAsk`, `Store+Meetings/+Tasks/+Ask`, `EngineHub`)

- **Summary:**
  - Only "Summarize Anyway" skips the too-short check.
  - A too-short or no-speech rerun never erases an existing summary or its edits.
  - Interrupted summaries re-run at launch.
- **Title** at every stop: 3 tries, a 240 s cap and a compare-and-set. A launch scan names up to 10 meetings in
  90 s, each once per recording.
- **Tasks:**
  - Dedupe: owners must match ("You" = the user's name). Stored rows match only exactly. Rewording is recognized only
    against the replaced summary's items.
  - My Tasks page: Today / Yesterday / Last week / Older, Archived, search, Undo, "From …" links. The meeting's Tasks
    tab has Archive All and Show Archived.
- **Ask:**
  - The prompt is budgeted in tokens to the model's context: the transcript's head and tail plus keyword lines.
  - Chats are saved per meeting and across meetings (pruned beyond 130 chats or 5000 messages), with Past chats and
    reopening.
- **Search** covers title, notes, transcript, summary, attendees and tasks, with wildcards escaped. Past notes page
  100 at a time.
- **EngineHub.** A model loaded on demand stays loaded. A model still in use is adopted, never loaded twice.
- **Text without spaces** (Japanese, Chinese, Thai) is cut at clauses or characters.

**UI** (`Shout/UI`, `AppDelegate`)

- **Playback bar** on finished notes: −15 s / +15 s, a scrubber with a tick per Resume, and transcript timestamps
  that seek. The audio engine is built only on Play, paused on Pause and torn down at the end.
- **Pages and windows:**
  - the My Tasks sidebar page;
  - the Ask sheet with history;
  - wrapping info pills at 500 pt;
  - You and Others colours independent of the accent.
- **Notepad:**
  - re-docks when off-screen, deminiaturizes and opens on the current Space;
  - follows a deleted note to the live one, or closes;
  - with "Hide from screen sharing" on, it and its sheets and alerts are always hidden from capture.
- **Menus:**
  - status menu built on open;
  - app menu "Scribe", with New Note ⌘N only on the Scribe page;
  - Dock "Open Scribe".
- **Shortcut ⌥M** (Left ⌥) by default when free. A clashing shortcut is refused, and ⌥M gives way to push to talk.
  Keys are named for the current keyboard layout.

## 4. Speaker names

An "Others" line gets the name of the person that Zoom, Meet, Teams or Slack shows as speaking.
**This has not been tested on a live call.**

**What is built**

| Piece | Where | Notes |
|---|---|---|
| Platform choice | `ShoutKit/Meetings/SpeakerParsing.swift` (`SpeakerTarget`) | **Zoom:** native `us.zoom.xos` only. <br>**Meet:** Chrome, Edge, Brave, Chromium and Arc, whose trees are woken; Safari, which is not woken. <br>**Teams:** native, or Chromium (not Arc). <br>**Slack:** native only. <br>Anything else, Webex and FaceTime included, gets no names. |
| Parsers and tile rules | `SpeakerParsing.swift`, `SpeakerTiles.swift` | **Names:** the name filter (overflow, timers, initials, status words); a key (NFC, trailing "(…)" removed, lowercased); self labels ("You", "… (You)"). <br>**Per app:** Zoom person boxes and `Talking:`; Teams tile fields, badges and the call-monitor label; Slack's "View X's profile". <br>**Classes:** the web class names can be overridden in user defaults (`ShoutSpeaker…Classes`). <br>All pure, and tested on fixture trees. |
| Poller | `Shout/System/MeetingSpeakerPoller.swift` | **Timing:** a utility serial queue with a one-shot timer every 0.15 s ±10 %. Discovery runs at start, every 7 s and on an invalid element; every 1 s while a Teams gallery is empty. <br>**Bounds:** AX timeouts 0.1 s per read and 0.2 s for discovery. The walk goes to depth 30 (Teams 40) and 20 000 elements, with a 1.5 s discovery and a 0.12 s tick budget. After 3 timeouts an app is backed off for 2 s. <br>**Waking:** Chromium and Electron trees are woken once (`AXManualAccessibility`, else `AXEnhancedUserInterface`, which is turned off again at stop). <br>**Output:** the first 0.5 s is ignored. It emits on every change and every 1 s while unchanged. Without the Accessibility permission it does nothing. |
| Reading each app | same | **Zoom:** the main window by `zm.meeting.window.main` (else a window titled "Zoom Meeting"). Person boxes come from `AXDescription`, only inside the window frame. `Talking:` comes from the floating `AXSystemDialog` window. <br>**Meet:** the visible window with the call's code; `oZRSLe` tiles; the `kssMZb` speaking marker. <br>**Teams:** `vdi-dynamic-occlusion` and `fui-Primitive` tiles; the `vdi-frame-occlusion` marker; the roster; the call monitor, where "you are speaking" means the user. <br>**Slack:** the "huddle:" window, `p-huddle_peer_tile` tiles, the active-speaker overlay class. |
| Timeline and attribution | `SpeakerAttribution.swift` | **Spans.** Readings become spans on the recording timeline. A repeated reading extends the open span; any other closes it. Readings never cross a `stopped` marker. The user's own tile and name are removed first, and mic lines are never touched. <br>**Voting.** Each "Others" line is sampled every 250 ms (at least 3 samples), looking 300 ms later for the app's indicator lag. A span counts only if it was confirmed within 1.5 s. Only single-speaker readings vote. <br>**Naming.** A name sticks after 3 consecutive votes. It switches after 5, but not within 30 s of the last switch. A line is named only if the name has a strict majority of its votes, more votes than overlap samples, and at least 25 % of the samples. Otherwise it stays "Others". |
| Controller | `ScribeController.swift` | **Following.** The poller follows the call the recording is bound to, re-checked every second, so a late bind or a setting or permission change applies within 1 s. <br>**Storing.** Closed spans are stored every second, and the poller stops before the tracks close at Stop. <br>**Naming.** New lines are named as they arrive. The whole meeting is labelled again when a leg finishes transcribing, and after crash recovery. <br>**Editing.** Discard deletes that leg's spans. A rename also applies to later readings. |
| Storage | `Store+Speakers.swift` | **Table** `meeting_speaker_spans`: leg, start and end ms, platform, state, `speaker_name`, speaking and muted (JSON), `self_name`, source, reason. Deleted with the meeting; indexed on `(meeting_id, start_ms)`. <br>**Column** `meeting_segments.speaker_origin` (`ax` / `user`). <br>**Writes.** Applying names changes system lines only, never a `user` line or a speaker that didn't come from AX, and is idempotent. |
| UI and setting | `MeetingDetailView`, `ScribeSettingsView`, `AppSettings` | **Transcript.** Names replace "Others", with one colour per person in order of appearance. A name read from the app has a `person.wave.2` glyph ("Name read from Zoom's window"). <br>**Turn menu:** Rename "X"… (whole meeting), Not X, Name This Speaker…. <br>**Chips** under the info pills show each speaker's talk time, with "+N" overflow and Rename. <br>**Live:** the typing bubble shows who is speaking. <br>**Setting:** Settings › Scribe › Transcript › **Detect speaker names**, default on, with Allow… when Accessibility isn't granted. <br>Named lines reach summaries and Ask. |

**Needs a live call**, roughly from most to least likely to be stale. The obfuscated web class names come first:

1. **Meet:** the `oZRSLe` tile and `kssMZb` speaking classes (they can be overridden in user defaults). Is
   `AXDOMClassList` exposed after `AXManualAccessibility` in Chrome, Edge, Brave and Arc, and by Safari at all?
2. **Teams:**
   - the `vdi-frame-occlusion` marker;
   - which `AXDescription` field holds the name for `vdi-dynamic-occlusion` and `fui-Primitive` tiles. `fui-Primitive`
     is generic, so false tiles are possible, but they never light up, so they never name a line.
3. **Slack:** the "huddle:" window title, `p-huddle_peer_tile` and its `__overlay--active_speaker` class, and
   "View X's profile".
4. **Zoom:**
   - the person-box `AXDescription` format ("Name, Active speaker, Computer audio unmuted"), and whether "Active
     speaker" appears in gallery view;
   - `Talking:` in the floating `AXSystemDialog` window.
5. **Less likely:**
   - Teams' call-monitor text and roster ids, and whether new Teams accepts `AXManualAccessibility`;
   - Meet's own tile reading "You", and that the Meet tab must be its window's active tab;
   - Zoom boxes on another gallery page, and Zoom in other languages (all matching is on English text).
6. **Every app:**
   - the 300 ms indicator lag and its hangover, which tune `indicatorLagMs` and the 25 % coverage;
   - CPU per tick in calls with 10+ people;
   - the 1.5 s discovery budget on big Chrome windows.

## 5. Verification

- **Unit tests:** 512, all passing (`swift test`), among them `MeetingDetectionFixTests`, `CallSessionTrackerFixTests`
  (Zoom start to end, Meet with background tabs, Slack rejoin, FaceTime, manual recording, sleep mid-call, dictation
  mid-call), `CaptureTests`, `StoreSchemaTests`, `ScribeStoreTests`, `MeetingAskTests`, `EngineHubTests`,
  `MenuBarTitleTests`, `ScribeShortcutDefaultTests`, `ShortcutConflictTests`, `SpeakerParsingTests`,
  `SpeakerAttributionTests` and `SpeakerStoreTests`.
- **Snapshots** rendered with `SHOUT_SNAPSHOT_DIR` from fixed calendar events, light and dark: every Flow Bar card,
  My Tasks, every summary state, the Ask sheet, playback, the Notepad with every notice, speaker names, folders and
  Settings › Scribe.
- **Offline harness** (`shout-cli`, Qwen3 4B): `meeting` (segmentation, You/Others, echo on synthesized speech),
  `summarize --allow-short`, `title`, and `ask --context 4096`.
- **Hardware self-test** (`SHOUT_SCRIBE_SELFTEST`): permissions, system-audio capture, the voice-processing mic and a
  synthesized other side through the speakers. Its last run gave 100 % word recall, 0 echo words credited to You,
  and a summary, title and tasks; the checks added since (raw echo words, echo return loss, hand-off timing, an
  on/off comparison) haven't run yet.
- **Reviews:** two static audits and a full automated code review; every finding was fixed or answered.

## 6. Not verified on hardware

None of this has run on a Mac with real audio yet:

- a live Zoom, Meet, Teams, Slack or FaceTime call. That covers detection, AX titles and URLs, the auto-stop ladder,
  auto-resume, the cards in a real session, and dictation during a call;
- real capture with the new code: the real-time hand-off, the voice-processing unit on its own queue, the mic
  watchdog, the liveness oracle, the Core Audio restart rebuild, and the archive of a real meeting;
- sleep, lock and user switch; `killall coreaudiod`; a full disk; AirPods and device switches; macOS 14.x;
- playback through speakers, and screen sharing with the hide setting;
- speaker names against a real Zoom, Meet, Teams or Slack window (§4);
- the notification permission prompt, ⌥M from other apps, and AZERTY.

Also unsettled:

- whether Apple's voice processing cancels other apps' audio, not only its own (headphones avoid the question);
- the echo-correlation thresholds, which are calibrated on synthetic signals only.

## 7. Open questions

- The bundle IDs that real microphone holders report; Chrome's "- Microphone recording" tab suffix; Zoom and Slack
  titles in other languages.
- Whether a tap-only aggregate calls back during silence, and AirPods profile switches.
- Speaker names: each app's accessibility labels and classes, the lag between voice and highlight, and whether apps
  flag the user's own tile (§4).
