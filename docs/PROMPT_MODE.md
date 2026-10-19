# Prompt mode

Say what you want for an AI assistant (Claude Code, Cursor, ChatGPT) and Shout pastes it as a clear prompt, on this
Mac. It keeps your words, like a dictation, and makes them precise: it names what you point at in screenshots, uses the
domain's terms where you mean them, and adds the pictures.

**Design:** the prompt stays your message, cleaned up. It isn't rewritten into a structured brief (Goal / Current
behaviour / Acceptance criteria…), which adds things that weren't said.

Three steps:

| Step | What | Status |
|---|---|---|
| 1 | Prompt mode on a shortcut | Built |
| 1b | Sticky target: the text goes back to the field you started in | Built |
| 2 | Screenshots while you talk, tied to the words you said at that moment, kept in History | Built |
| 3 | Walkthrough recording: key frames, annotations, steps | Planned |

## Design choices

- **Your words, not a template:** the message is made clearer and more precise, not restructured.
- **One shortcut** for every kind of prompt.
- **Works on speech directly,** no dictate-then-select-then-transform. Selected text works too.

## Step 1: Prompt mode (built)

### Using it

| You do | Shout does |
|---|---|
| Hold **fn ⇧** and talk, then release | Writes a prompt from what you said and pastes it |
| Hold **fn ⇧** with text selected and talk | Turns the selection into a prompt, following what you said, and replaces the selection |
| Tap **fn ⇧** with text selected | Turns the selection into a prompt |
| Tap **fn ⇧** with nothing selected | Listens hands-free; tap again (or click stop) to finish, Esc cancels |
| Hold **fn**, then add **⇧** within a second | The dictation becomes a prompt, as fn then ⌃ becomes Command Mode |

- **Shortcut:** fn ⇧ by default, changeable in Settings → Shortcuts → Prompt mode.
- **Flow Bar:** while listening and working, it shows the Command Mode colours. Afterwards it flashes "Prompt", or
  "Prompt with 2 screenshots".
- **History:** a Prompt badge, the prompt, your original speech, the screenshots, and in Details how many of them the
  model looked at.
- **Selection:** comes only from Accessibility. Unlike Command Mode, there's no ⌘C fallback: ⇧ is still held then, and
  some editors copy the whole line when nothing is selected.

### How the prompt is written

`PromptBuilder.promptMessages`, `DictationPipeline.runPrompt`:

- **System:** shared rules, then rules for screenshots, pictures and selected text when there are any. The rules:
  - keep the user's words, order, meaning and voice;
  - no summarising, restructuring, headings, or anything they didn't say (requirements, suggestions, questions);
  - remove filler, false starts and repetition; apply self-corrections; fix grammar and mis-hearings, but keep error
    messages, code and names exactly as said;
  - make vague references precise from what screenshots point at, as interface elements are called and where they
    are ("this settings here" becomes "the Settings item in the sidebar"), never describing more than that;
  - spell words as in the spelling list;
  - lists only where things are listed;
  - write as the user, to the assistant.
- **Example:** one example shows a vague "this button here" next to a screenshot becoming "The Add button in the
  toolbar (screenshot 1)".
- **User turn:**
  - what each screenshot points at (`<screenshots>`);
  - your words, with filler removed and markers as "(see screenshot N)";
  - the selection, if any;
  - a spelling list: your Dictionary.
- **No app name.** The app the prompt goes to isn't passed to the model: it took it for the subject ("the Dictionary
  page in Cursor").
- **Generation:**
  - temperature 0, sized to the model's context;
  - a reply cut off by the length limit fails (`failIfTruncated`);
  - refused when less than 256 tokens would be left.
- **Too much added:** a reply more than about twice as long as what was said (plus room per screenshot) counts as a
  failure, since the model added content.
- **Clean-up** (`PromptBuilder.cleanPrompt`): a code fence around the whole reply, a "Here is the prompt:" line,
  placeholder lines, empty sections, anything copied from the instructions, and a list of screenshots the model wrote
  itself (Shout writes that list).
- **Nothing to act on:** a few words with no request ("so this", fewer than two meaningful words, or one with a
  screenshot) aren't sent to the model. The model may also answer `NO_REQUEST`. Either way nothing is pasted, and the
  Flow Bar says it was too short.
- **Off-topic replies:** a prompt sharing none of three or more meaningful words with what was said counts as a
  failure. The clean-up also drops anything copied from the fixed text of the messages (the spelling list, the
  instructions).
- **On failure** (no model, too long, cut off, empty):
  - **with no selection:** your words are pasted as a normal dictation, with a warning, so nothing you said is lost;
  - **with a selection:** it's never replaced, and an error is shown.
- **Model:** loaded on demand, like Ask, so Prompt mode works with AI formatting off.

### Results with the local models

Measured on an M5 Mac with `shout-cli prompt`, on real requests.

**A sidebar request**, with screenshots of the sidebar. Said: "what I really want is this settings here [1] to go away.
And then each of these items… [2][3][4] and the rest of them have their own gear icon…"

| Model | Result |
|---|---|
| Qwen3 4B Instruct (default) | "The 'Settings' row in the sidebar (screenshot 1) should be removed. Each of the following sidebar items, 'Home' (screenshot 2), 'Scribe' (screenshot 3) and 'My Tasks' (screenshot 4), should have their own gear icon. Clicking the gear icon for any of these items should open a modal containing the settings for that specific card." (2.8 s) |
| Qwen3.5 9B | Keeps "and the rest", but doesn't name the items (4.8 s) |

- **Without screenshots,** the Dictionary/Snippets request and the AirPods bug come back as the user's own words,
  cleaned up, in about 2 s ("text box" became "text field").
- **Context:** the prompts fit a 4,096-token context (Apple Intelligence, local servers).

### Files

| Area | Files |
|---|---|
| Prompt, clean-up | `Sources/ShoutKit/Text/PromptBuilder.swift` (Prompt mode section) |
| Pipeline | `Sources/ShoutKit/Pipeline/DictationPipeline.swift` (`runPrompt`, `promptTokenBudget`) |
| Settings | `AppSettings` (`promptModeEnabled`, `promptShortcut`, `promptScreenshots`, `promptShowScreenshotsToModel`), `ShortcutSlot.prompt`, `KeyCombo.defaultPrompt` |
| Shortcut | `Sources/Shout/System/HotkeyManager.swift` (`promptDown` / `promptUp`) |
| Session | `Sources/Shout/App/DictationController.swift` (`.prompt` mode) |
| UI | `Sources/Shout/UI/PromptsView.swift`, the Settings shortcut row, the History badge |
| CLI | `shout-cli prompt <spoken> [--selected TEXT] [--llm ID] [--context N] [--shots …] [--images …]` |
| Tests | `Tests/ShoutKitTests/PromptModeTests.swift` |

## Sticky target (built)

The text goes back to where you started, wherever you went meanwhile: another app, another window, another screen.
This is what lets you show things on screen while you talk. Hands-free Prompt mode (tap fn ⇧) leaves your hands free
for that.

- **At the start:** Shout notes the app, the window (`AXFocusedWindow`), the field, and the caret or selection
  (`AXSelectedTextRange`, read even when no text is).
- **At the end** (`ContextReader.returnTo`):
  - **App:** brought back to the front. A plain `activate()` from a background app is ignored since macOS 14, so
    Accessibility's `AXFrontmost` is set too (`bringToFront`), and it checks that it took.
  - **Window:** raised, and un-minimised if needed.
  - **Field:** focused again, and the caret restored if focus had to move.
- **When replacing a selection** (Command and Prompt mode): the selection is restored, and it must still be the same
  text. If it changed, nothing is replaced.
- **Never pasted somewhere else:** if the app quit, the window closed, the selection changed, or the app can't be
  brought forward, the result goes to the clipboard with "Couldn't get back to <app>: … It's on your clipboard."
- **Fields that can't be focused** (some Electron apps rebuild theirs): the app and window come back, and the text goes
  where that window's cursor is, as before.
- **Flow Bar:** while you're in another app, the pill shows the icon of the app the text goes to.
- **Self-test:** `open -n /Applications/Shout.app --env SHOUT_DEMO_DATA=1 --env SHOUT_RETURN_SELFTEST=/path/report.txt`
  runs TextEdit with temporary files and Calculator as the other app (it skips when TextEdit is open). 12 checks:
  - the caret's field gets the text after leaving and coming back;
  - a newer window of the same app doesn't take it;
  - a moved selection is restored;
  - a changed selection is refused;
  - a closed window is refused.

  Finder with no window can't be brought to the front from the background, which is why Calculator is used.

## Step 2: Screenshots tied to your words (built)

**The point:** a picture alone doesn't say what it shows. What links it to the request is what you were saying when you
took it ("…and then this button opens a text box…"). Shout notes when each screenshot is taken and puts those words
next to it, in the prompt and in History.

**Taking screenshots.** In Prompt mode, preferably hands-free (tap fn ⇧, talk, show things, tap again), any of these:

| How | Caught by | Timed by |
|---|---|---|
| ⌘⇧3 / ⌘⇧4 / ⌘⇧5, saved to a file | New screen captures in the screenshot folder (`com.apple.screencapture location`, Desktop by default), read at the end: images with `kMDItemIsScreenCapture` or a screenshot-style name | The time in the file name (to the second; any language, 12 or 24 h) |
| ⌃⌘⇧4 (to the clipboard), or copying an image or image file | The clipboard, every 0.25 s | When it appears |
| A tap of ⌥ | Shout captures the window under the mouse (ScreenCaptureKit), with a red ring where the mouse was, and notes what's there (Accessibility: role, label, window, app) | The recording's position at the tap |

- **Waiting for a saved screenshot:** macOS writes the file once its floating thumbnail goes away (about 5 s). If
  Shout saw ⌘⇧3/4/5, it waits up to 6 s at the end for that file. If it didn't, swipe the thumbnail away first, or use
  the clipboard or ⌥ capture.
- **The ⌥ tap:** a lone tap only (pressed and released within 0.6 s with no other key). ⌥ used with another key, or
  inside a Shout shortcut, isn't a tap.
- **Flow Bar:** shows a camera and the count while you talk.

**Tying words to each screenshot** (`DictationPipeline.transcribeMarked`, `PromptScreenshots`). The speech engines
give no word timings, so:
- **Split:** the recording is split at each screenshot's moment, moved to the quietest 30 ms within 0.6 s so no word
  is cut.
- **Transcribe in order:** each part is transcribed in turn; Whisper gets the earlier parts as its prompt.
- **Marker:** "[screenshot N]" then sits exactly between the words before and after.
- **Words around it:** up to 8 words before and 4 after, for example
  "…when you click on Add, it opens this text box right away…".

Tested on this Mac with Parakeet and three spoken clips joined, screenshots placed 0.3 s off the joins: both markers
landed exactly at the sentence breaks.

**In the prompt:**
- **For the model:** the markers become "(see screenshot N)", since plain words survive a small model's rewriting
  better, and a rule asks it to keep each one next to what it shows.
- **Backstop:** the 4B model still often drops them. Any screenshot the prompt doesn't mention gets "(screenshot N)"
  on the line sharing the most words with what was said around it, never in "Also consider" or "Open questions".
- **The list:** Shout itself appends `## Screenshots`, never the model, so paths are exact. One line per picture:
  ``1. `/…/Captures/2026-10-18 18.49.12/screenshot-1.png`: taken as I said "…it opens this text box right away…"
  (under the mouse: button "Add Word"; window: Dictionary (Shout))``.
- **Copies:** every picture the prompt points to is Shout's own copy in a folder for that prompt, macOS screenshots
  included. The prompt and History keep working when a screenshot is moved off the Desktop.
- **Sized for the assistant** (`PromptImages`):
  - **⌥ captures** are taken at one pixel per point, not Retina.
  - **Every picture the prompt points to** has its long side capped at 1280 px; the originals aren't touched.
  - **Why 1280:** Claude reads images up to 1568 px and charges about width × height / 750 tokens. At 1280 px a full
    screen costs about 1,400 tokens (a Retina original is around 7,000 before Claude shrinks it), a window often
    under 1,000, and interface text stays readable.
- **If the prompt can't be written:** the words are pasted with the markers, and the list is still appended.

**History** (`PromptCaptureArchive`, files only, no database change):
- **Each prompt's folder** holds its pictures and `captures.json`: for each picture its path, original location,
  source, time, the words said and what was under the mouse.
- **Link:** `history-<id>` ties the folder to the History entry.
- **History detail** shows a Screenshots card with each thumbnail, the words in quotes, what was under the mouse, and
  Open and Show in Finder. A picture removed outside Shout shows "No longer available".
- **Original speech** shows the transcript with the markers.
- **Lifetime:** pictures live as long as their History entry. Deleting an entry, Delete All, and the retention setting
  delete them too. Folders of prompts that weren't saved (cancelled, or History off) go after 7 days.
- **Location:** a test or demo database keeps its pictures beside it, never in the user's folder.

**Needs a capable AI model.** Screenshots only work with a model shown to name what they point at and keep your
words: Qwen3 4B Instruct (default), Qwen3.5 4B and Qwen3.5 9B (`ModelCatalog.screenshotPromptModelIDs`).
- **With any other model** (Qwen3.5 2B, Apple Intelligence, Ollama), the Screenshots switch is grayed out and shown off,
  with a note and **Choose Model…**. Your choice is kept for when a capable model is selected.
- **During Prompt mode,** screenshots aren't collected then. An ⌥ tap plays the error sound, and after the paste a
  message with **Fix** opens Models.

**The model looks at the screenshots** (Qwen3.5 4B and 9B). Accessibility often names only a container ("scroll
area") or nothing at all (icons, web and Electron apps, every ⌘⇧4 screenshot), so "this icon" stayed vague. Models
that can see pictures now get them, to name what was shown in interface terms ("the gear icon", "the Add Task button
at the top right").
- **Image reader:** a separate file per model (its mmproj, `ModelCatalog.vision`): 672 MB for 4B, 918 MB for 9B. The
  Prompts page offers it under Screenshots ("Show screenshots to the AI model": Download, then a switch). Deleting the
  model deletes it too. Qwen3 4B Instruct (the default) can't see pictures; Qwen3.5 2B isn't offered.
- **Engine** (`LlamaEngine`): llama.cpp's multimodal library (mtmd), already in the bundled framework. The image
  reader loads on first use (0.2 s); a `ChatMessage` carries pictures, one per `ChatMessage.imageMarker` in its text.
- **Size for the model** (`PromptImages.forModel`): Qwen spends one token per 32 × 32 pixels, so a 1280 × 800 window is
  about 1,000 tokens. Up to four screenshots get 1,100 tokens each; more share what's left. Smaller pictures were
  faster but the model started guessing (600 tokens: the title became "the checkbox"; 350: a "three-dot menu" that
  isn't there). A close-up around the ring was faster too, and also invented a three-dot menu.
- **Read while you talk** (`TextGenerator.readAhead`): the image reader starts loading when the recording does, and
  each screenshot is encoded as it's taken (about 2 s each on 9B, hidden behind your talking). At the end only feeding
  it to the model is left. Pictures found at the end (saved ⌘⇧4 files) are encoded then.
- **What it's told:** the screenshots go where they're listed, with "the red ring is where they pointed" for ⌥
  captures, and a rule: look at a picture only to name what the vague words point at (kind, label or icon, place);
  describe nothing else and add no requests. Accessibility labels that name only a container are dropped next to a
  picture (`PromptScreenshots.withoutVagueThing`): "pointed at: scroll area" made the model write "the scroll area".
- **If it fails** (a picture can't be read, no room), the prompt is written from the words and labels as before.

Measured on this Mac (M5, 32 GB), `shout-cli prompt --images … --read-ahead`, with what the app did before
(no pictures) for comparison:

| Case | Without pictures | Qwen3.5 9B with | Qwen3.5 4B with |
|---|---|---|---|
| ⌘⇧4 of a gear icon: "this icon should open settings in a modal" | "This icon" | "The Settings icon" | "This gear icon" |
| ⌘⇧4 of two tabs: "these should look like a segmented control" | "These" | "The Tasks and Archived tabs" | "These" |
| ⌥ on Add Task, no Accessibility label (as in apps it can't read) | "this" | "the Add Task button" | "the Add Task button in the top right" |
| Three ⌥ captures of a task row | "When I click here … when I click There" | the title called "the checkbox" | right: the row, then the title, then the menu opening |
| Time with one picture (two without) | 2.4 s | about 5 s | about 3.7 s |

Qwen3.5 4B is the better choice for this: as accurate or more, and about twice as fast. With a good Accessibility
label, pictures add little; they matter where labels are missing.

**Selected text in an ⌥ capture.** With text selected, ⌥ boxes the selection instead of ringing the mouse, and the
prompt quotes it (`SelectionReader`, `PromptCapture.selection`).
- **Reading it:** Accessibility gives the selected text and where it is on screen (`AXBoundsForRange`, with the
  first and last characters' boxes added for apps that give only the first line). In an editor, the window's
  document (`AXDocument`) names the file, and the lines come from finding the text in the saved file
  (`SelectionLines`); when it's there more than once, the editor's own position decides. Unsaved changes: the file
  without lines.
- **Which selection:** one not used yet in this prompt, or one the mouse is on (within 40 pt). A selection left
  behind doesn't take over later ⌥ taps; the selection a prompt started with is its material, not boxed.
- **The picture:** the selection's window with a red box around the text. Windows are now cut from their display by
  their frame: the window-only capture came back shifted inside the image (transparent strips on two sides), which
  put the ring and box about 30 px off.
- **For the model:** `<selected in="/path/File.swift:40-42">…</selected>` next to its screenshot (up to 2,000
  characters), and a rule: "this" means that text; refer to it ("the selected text", "lines 3–4 of notes.txt"), quote
  it only when it's a few words, never edit or answer it.
- **In the prompt:** Shout adds it under the screenshot, so it's exact: a code block for a file's text, a quote
  otherwise, up to 80 lines. For example: ``1. `…/capture-20.png`: taken as I said "…this function should be async";
  the selected text (`/Users/…/Store.swift:40-42`):`` followed by the code. History shows it under the picture.
- **Results** (said: "this function should be async and throw instead of failing silently"): 4B and 9B wrote "The
  `save()` function in Store.swift (screenshot 1) should be async and throw…"; Qwen3 4B Instruct wrote "The function
  in the selected text (screenshot 1)…". Before the rule said "don't repeat it", 4B wrote the rewrite itself.
- **VS Code:** its editor doesn't report a selection to Accessibility unless "Screen Reader Optimized" is on, so ⌥
  there still rings the mouse. The window does report the open file.
- **Self-test:** `--env SHOUT_SELECTION_SELFTEST=/path/report.txt` (TextEdit with a temporary file; skipped if TextEdit
  is open): the text, its file and lines 3–4, a repeated line placed by the editor (line 6, not 2), no selection, and
  with Screen Recording the box in the picture (kept as `selection-boxed.png` next to the report). 8 of 8 on this Mac.

**Permissions: asked up front, never mid-dictation.**

| Permission | Needed for | How Shout handles it |
|---|---|---|
| Screen Recording | ⌥ captures | Checked silently (`CGPreflightScreenCaptureAccess`) |
| Reading the screenshot folder | ⌘⇧3/4/5 screenshots saved as files | macOS has no silent check: the first read of a protected folder (Desktop, Documents, Downloads, iCloud, other volumes) asks |

- **Screen Recording:**
  - **Allow** puts Shout in the list (macOS asks only the first time) and opens the Screen & System Audio Recording
    pane.
  - A new grant applies after a restart, so a **Restart Shout** row appears until it does.
  - The capture itself never asks. An ⌥ tap without permission plays the error sound, and after the paste a message
    with **Fix** opens the Prompts page.
- **Screenshot folder:**
  - A protected folder is read only after you allow it from Setup, Settings or the Prompts page. **Allow** reads it
    once so macOS asks then; the answer is remembered per folder.
  - Otherwise it isn't read. If ⌘⇧3/4/5 was seen, the message after the paste says those screenshots were left out,
    with **Fix**.
  - Folders that aren't protected (for example ~/Pictures/Screenshots) are read freely.
- **Where to allow them:** the setup wizard's "Allow access" step (an optional section), Settings → Permissions, and
  the Prompts page under Screenshots.
- **Without either:** clipboard screenshots (⌃⌘⇧4) need neither permission.
- **What ⌥ captures:** only the window under the mouse (or, with text selected, the selection's window), from any app,
  Shout's main window and Notepad included (you may be describing a change to Shout). Floating panels such as the Flow Bar, menus and the Dock are never picked.
  Over the empty desktop it captures the whole screen the mouse is on, without Shout's floating panels.

**Self-test:** `open -n /Applications/Shout.app --env SHOUT_DEMO_DATA=1 --env SHOUT_SCREENSHOT_SELFTEST=/path/report.txt`.
It puts the user's clipboard back afterwards, uses a temporary folder instead of the Desktop, and skips the ⌥ capture
unless Screen Recording is already allowed. Checks:
- a clipboard image is caught and timed;
- a screenshot-named file is found and timed by its name, and an ordinary image is left out;
- copies are made next to the prompt, with the original remembered;
- History finds the pictures.

**Not done yet:**
- **On-screen text for text-only models:** Qwen3 4B Instruct still gets only the labels; reading the pictures' text
  (Vision) could help it.
- **VS Code selections** without Screen Reader Optimized (a ⌘C fallback copies the whole line when nothing is
  selected, so it can't tell).
- **Not tried on real input:** the ⌥ tap and ⌘⇧ key detection with real key presses, and the ⌥ capture (no Screen
  Recording permission here).

## Step 3: Walkthrough recording (planned)

**fn ⇧ Space** starts and stops a recording of the screen, your voice and your clicks. Shout turns it into an
annotated, step-by-step prompt.

- **Capture:**
  - the display or front window at a few frames a second (ScreenCaptureKit);
  - the microphone;
  - clicks, from a listen-only event tap, with the element under each click (Accessibility).
  - **Not captured:** keystrokes. At most their count, never their content.
- **Key frames** come from events, not from AI:
  - each click;
  - each ⌥ "this" tap;
  - a large visual change (frame difference);
  - pauses in speech.
  - Near-duplicates are dropped.
- **Annotation:** a numbered ring at the click, and a label from Accessibility ("2. Clicked Settings").
- **Write-up:** the prompt engineer gets the transcript with step markers, the step list, and the text on each frame.
  It writes Steps (linked to the frames), Expected, Actual and the request.
- **Review window:** shows the frames and the prompt before copying or pasting, so frames can be removed.
- **Optional image model:** Shout's llama.cpp includes image support (`mtmd`). A vision model (a 3–4B VL model plus
  its projector, about 3–5 GB) could describe frames. Optional, because Accessibility and text recognition cover most
  needs.
- **While recording:** the Flow Bar shows a recording indicator, and recording stops at a time limit.

## Open questions

- **Turning selection into a prompt in apps without Accessibility selection** (VS Code, Cursor without accessibility
  support): Step 1 needs Accessibility selection; ⌘C after the keys are released could add it.
- **Where Step 2's images go:** the prompt lists their paths, or the paste carries the images, or both.
- **Screenshots after the session:** should one taken a few seconds after you finish still count? The file can arrive
  about 5 s late because of the thumbnail; today only one whose keys Shout saw is waited for.
