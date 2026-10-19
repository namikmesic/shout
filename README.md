# Shout

A local-only voice dictation app for macOS, modelled on Wispr Flow. Hold a key, speak, let go, and
clean, punctuated text appears wherever your cursor is. Speech recognition and AI editing both run
on your Mac with Metal acceleration; nothing you say is sent anywhere.

## Features

| Feature | How it works in Shout |
|---|---|
| Push-to-talk | Hold **fn**, speak, release. Text is pasted into the focused app. |
| Hands-free | Double-tap **fn**, or press **fn + Space**. Press again to finish. Click the Flow Bar to start. |
| Command Mode | Select text, hold **fn + ⌃**, and say "make this more formal" or "translate to German". With nothing selected, it writes text at the cursor. |
| Prompt mode | Hold **fn + ⇧** and say what you want; Shout pastes it as a clear prompt for Claude Code, Cursor or any assistant, in your words, naming what you point at in screenshots (Qwen3.5 4B and 9B look at them) and quoting text you select (with its file and lines in an editor). See docs/PROMPT_MODE.md. |
| AI cleanup | Removes ums and false starts, applies self-corrections ("2pm, actually 3"), fixes punctuation, formats lists, emails, numbers and URLs. Four levels: Off, Light, Medium, High. |
| Context awareness | Reads the app, URL and text around the cursor (Accessibility) to match casing, spacing and names. |
| Tones per app type | Formal, Casual, Very casual or Excited for personal messages, work messages, email and everything else. Per-app overrides. |
| Dictionary | Custom words become recognition hints; "say X, write Y" replacements; auto-learns words you correct after a paste. |
| Snippets | Say "my calendly link" and the stored text is inserted. |
| History & stats | Searchable history with raw vs. final text and timings; words, words per minute, streaks, time saved. |
| Notes | A scratchpad for longer dictation. |
| Scribe | Records calls: your microphone ("You") and the Mac's audio ("Others") as two aligned tracks, transcribed live on this Mac. Detects calls (Zoom, Teams, Meet, FaceTime, Slack huddles…) and stops when they end; calendar reminders with Join & Start, and the next meeting in the menu bar. Speaker names read from the Zoom, Meet, Teams or Slack window. Summaries, titles and action items from the local model; My Tasks across meetings. Ask about your meetings, with saved chats. A compressed audio archive with playback from any transcript line. Folders, search, a Notepad window beside the call, and ⌥M to start or stop. See [docs/SCRIBE.md](docs/SCRIBE.md). |
| Extras | Paste/copy last transcript (⌃⌘V / ⌃⌘C), Esc to cancel, "press enter" voice command, mute or pause media while dictating, email signature, start/stop sounds, launch at login. |

## Requirements

- Apple Silicon Mac, macOS 14 or later (macOS 26 adds the optional Apple Speech and Apple Intelligence engines)
- macOS 14.4 or later for Scribe to record the other people on a call (system audio); earlier versions record your microphone only
- Xcode with the Swift 6 toolchain to build
- About 3.2 GB of disk for the default models

## Download

Each release on the [Releases page](../../releases) has `Shout-<version>.dmg`: open it and drag Shout to
Applications. The release notes say how to open a build that isn't notarized. Releases are built by GitHub Actions;
see [docs/RELEASING.md](docs/RELEASING.md) for making one and for signing.

## Build and install

```sh
scripts/build-app.sh            # builds dist/Shout.app and signs it with your Apple Development identity
scripts/build-app.sh --install  # also copies it to /Applications
scripts/make-dmg.sh             # packages dist/Shout.app as dist/Shout-<version>.dmg
```

The script signs with the first "Developer ID Application" identity it finds, else "Apple Development", else
ad-hoc. Set `SHOUT_SIGN_IDENTITY` to choose one. A stable signature matters: macOS ties the Accessibility
permission to it, so ad-hoc builds lose the permission on every rebuild.

On first launch the onboarding asks for **Microphone** and **Accessibility**, downloads the two default
models, and checks the 🌐 key setting. If macOS opens the emoji picker when you press fn, set
System Settings → Keyboard → "Press 🌐 key to" → "Do Nothing" (onboarding has a button for this).

If Wispr Flow is still running, quit it or change one app's shortcut. Both listen for fn.

## Models

| Role | Default | Alternatives |
|---|---|---|
| Speech recognition | Parakeet TDT 0.6B v3 (669 MB, 25 European languages) | Whisper Large v3 Turbo (99 languages, uses your dictionary as hints), Whisper Small/Base, Apple Speech (macOS 26) |
| AI editing | Qwen3 4B Instruct (2.5 GB) | Qwen3.5 2B / 4B / 9B, any model in a local Ollama server, Apple Intelligence (macOS 26) |

Models live in `~/Library/Application Support/Shout/Models`, are downloaded from Hugging Face on
request, and are verified against their SHA-256 before use.

Measured on an M5 MacBook with a 10-second dictation, inside the signed app:

```
speech recognition (Parakeet)   0.09 s
AI cleanup (Qwen3 4B)           0.62 s
total, release to paste         0.71 s
```

Whisper Large v3 Turbo takes about 1.0 s for the same clip.

## Privacy

- Dictation audio is processed in memory and discarded. Recordings are kept only if you turn that on.
- Meeting audio is kept with each meeting in `~/Library/Application Support/Shout/Meetings/<id>/` until you
  delete the meeting: raw tracks while recording, then `audio.m4a` (stereo AAC, about 22 MB per hour).
- The only network traffic is model downloads you start from the Models page.
- The Ollama option accepts only `localhost` servers.
- History can be kept, deleted after 24 hours, or never stored.

## Project layout

```
Sources/
  ShoutASR/    Whisper and Parakeet engines (whisper.cpp, Metal)
  ShoutLLM/    llama.cpp engine with prompt-prefix KV caching
  ShoutKit/    UI-free core: pipeline, prompts, text rules, edit learning, settings, SQLite store,
                model catalog/downloader, Apple Speech / Apple Intelligence / Ollama backends
  Shout/       The macOS app
    System/     global hotkeys (CGEventTap), Accessibility context, paste-based insertion,
                microphone capture, edit watcher, media control, sounds, permissions
    App/        app delegate, dictation state machine, snapshot and self-test modes
    UI/         Flow Bar overlay, main window pages, onboarding
  shout-cli/   command-line harness for the pipeline
Vendor/         prebuilt whisper.cpp (b5130) and llama.cpp (b11232) frameworks, macOS slice (MIT, see Vendor/LICENSE-*)
docs/           Prompt mode, Scribe, and CI and releases
```

## Development

```sh
swift test                                   # unit tests for ShoutKit
swift build -c release --product shout-cli
.build/release/shout-cli eval               # runs tricky dictations through the cleanup model
.build/release/shout-cli pipeline file.wav --bundle com.tinyspeck.slackmacgap
.build/release/shout-cli command "make this formal" --selected "hey can u send it"
.build/release/shout-cli meeting mic.wav system.wav --bleed 0.3  # simulated meeting: segmentation, You/Others, echo removal

SHOUT_SELFTEST=file.wav dist/Shout.app/Contents/MacOS/Shout     # full pipeline inside the app bundle
SHOUT_SNAPSHOT_DIR=/tmp/snaps dist/Shout.app/Contents/MacOS/Shout # renders every page to PNG
SHOUT_DEMO_DATA=1 SHOUT_SNAPSHOT_DIR=/tmp/snaps dist/Shout.app/Contents/MacOS/Shout  # same, with sample meetings
```

## Not included

These Wispr Flow features depend on its cloud service or team accounts, so Shout leaves them out:
cloud sync, team dictionaries and sharing, leaderboards, screen OCR context, saved "Polish"
transforms, MCP extensions, and Jabra or Bluetooth ring support. Command Mode covers ad-hoc rewrites, and Prompt mode
covers Wispr Flow's Prompt Engineer transform.

Scribe's design and status are in [docs/SCRIBE.md](docs/SCRIBE.md). Not yet: telling remote speakers apart by voice
(names come only from the meeting app's window), and importing notes from other apps. Cloud sharing is
deliberately left out. Scribe has unit tests, UI snapshots and an offline harness, but has not yet
been tested on a live call.
