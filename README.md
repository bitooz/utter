# Utter

A Mac menu bar dictation app with four modes, each started by its own key. Hold a mode's key (**fn** for Auto by default)
and talk, let go, and the text is pasted into the focused field. **Double-tap** the key for hands-free, then tap it once
to finish. **Esc** cancels, while recording and while the text is on its way. Speech becomes text through a model on
OpenRouter, on the user's own key.

Where the text goes:
- Into the text field that had the focus when you let go.
- With no text field focused (the desktop, a web page you're reading, a list), it is copied to the clipboard instead and
  the pill says *Copied to clipboard*. If the focus moved to something else before the text arrived, it is copied too,
  not pasted there (*Copied, not pasted*).
- A paste borrows the clipboard and puts yours back once the text shows in the field (or after a few seconds where
  that can't be seen; longer for remote desktops and virtual machines).
- The mic starts the moment the key goes down, so the first word isn't cut; if the key turns out to be part of a
  shortcut, that audio is dropped.
- A long dictation's part that fails is tried again with the Instant model; if it still fails, the rest is pasted with
  `[…]` where it's missing, and **Retry Last Dictation** in the menu sends the whole recording again (kept in memory only).

## First launch

A setup window walks through:

1. **Welcome.**
2. **OpenRouter key**, checked live with OpenRouter (and the credit left on it shown), then saved to the login Keychain
   (service `OpenRouter`, account `dictation`). If a key is already there, it is filled in.
3. **Microphone and Accessibility**, each with its status updating live and a button for the right System Settings pane.
   Accessibility lets Utter notice the keys in any app and paste. Nothing is asked at launch before this step.
4. **A key per mode**: four rows (Auto, Instant, Balanced, Thorough), each with its own recorder that takes one modifier
   on its own (fn, ⌥, right ⌘…), several modifiers together (fn ⇧, ⇧⌘) or a key combination (⌃⌥D). Rows keep fixed
   heights; what to press, errors and clashes appear in one reserved line under them, so nothing moves while recording. A new install starts with fn for Auto and the others empty.
   With fn, one compact line offers to set macOS's own action for the fn key to *Do Nothing* (or opens Keyboard Settings),
   so holding fn doesn't also open the emoji picker or Apple Dictation.
5. **Modes**: the four modes, each with its model and key (information; nothing to choose).
   Every step fits its window without scrolling.
6. **Try it**: a field to dictate into, showing how long the text took and which model wrote it.

*Set Up Utter…* in the menu runs it again. Everything in it can be changed later in **Settings…** (⌘,), laid out like
System Settings with a sidebar: General (key, the keys per mode, permissions), Hotkeys, Modes (the model behind each),
Prompt, Vocabulary.

**Logo.** A text cursor sending out sound waves, white on a graphite tile: speech becoming typing. It is drawn in code
(`Sources/Utter/Logo.swift`), so the app icon, the menu bar icon (an 18 pt template glyph, red while recording,
struck through only when Utter can't dictate: no key for any mode, no OpenRouter key, no microphone or no Accessibility)
and the setup window match. Previews on light and dark backgrounds and two alternatives (a waveform and a speech bubble)
are in `design/icons/`; switching is one line (`Logo.current`) and `scripts/make-icons.sh`.

## A key per mode

There is no selected mode: every mode (Auto, Instant, Balanced, Thorough) simply has its own key, and a mode without one
can't be started. Hold a mode's key to talk in that mode, let go to paste; double-tap it (a modifier) or press it quickly
(a key combination) for hands-free. The menu lists each mode with its key. New installs give Auto fn and the others none.
Installs from before this had a main key for the mode chosen in the menu; it became Auto's key (⌥ Option where none had
been saved), and the per-mode keys they already had stayed.

A **modifier on its own** starts once it has been held alone for 0.3 s. It keeps working as usual: Utter never swallows it,
and with another key, modifier, click or scroll (⌥←, ⌥-typed characters, ⌘C with right ⌘) it is a shortcut, not a dictation.
Held past 0.3 s and then used in a shortcut, the recording is dropped and the shortcut goes through.
Left and right keys can be told apart, and a key for one side wins that side over a key for either side: with Auto on
⌥ Option and Thorough on Left ⌥ Option, Left ⌥ starts Thorough and Right ⌥ starts Auto (holding and double-tapping alike).
A **chord of modifiers** (two or more held together, no other key: fn ⇧, ⇧⌘, ⌃⌥, fn ⌃) is recorded when all are let go.
It starts once exactly those modifiers are held for 0.3 s, ends when any is let go, and a double tap of the chord
(within 0.5 s) goes hands-free. It never also starts a mode bound to one of its modifiers alone (fn ⇧ doesn't start
fn's mode), an extra modifier or a key makes it a shortcut (⇧⌘4 still takes a screenshot), and after an extra modifier
the chord counts again only once all its keys are let go.
A **key combination** starts the moment it is pressed and its key presses are swallowed so they don't type.
Let go to finish, or let go within 0.3 s to keep going hands-free; press it again to finish.
With fn as a key, macOS's own action for the fn key (System Settings › Keyboard) must be *Do Nothing*, or it opens its
popup too. The setup and Settings › Hotkeys show its state and set it with one click (`com.apple.HIToolbox AppleFnUsageType = 0`).

Settings warns when two modes have the same key (only the first works), says what happens where a one-side key meets an
either-side one, warns when no mode has a key, and flags well-known macOS shortcuts (⌘Space, ⌃Space…).

## Modes and models

(The modes were called Fast, Accurate and Very Accurate before; saved keys carry over. Internally, and in
`utter-bench --mode` and `--model`, they are still `fast`, `accurate` and `veryAccurate`.)

| mode | model (default) | |
|---|---|---|
| **Auto** | Instant under 20 s, Balanced from then on | the line is set under Settings › Modes |
| **Instant** | Gemini 3.1 Flash-Lite (`google/gemini-3.1-flash-lite`), reasoning off | about 1–1.5 s after release |
| **Balanced** | Gemini 3.8 Flash (`google/gemini-3.8-flash`), reasoning minimal | fewer wrong words, 2.5–3.5 s |
| **Thorough** | Gemini 4 Argon (`google/gemini-4-argon`), reasoning minimal | the strongest audio-input Gemini on OpenRouter (Oct 2026); about 4.5 s for 39 s of speech |

Each mode's model can be changed under Settings › Modes, in a searchable picker: the three tuned models on top as
recommended, then every OpenRouter model that takes audio input (fetched live), each with its name, id, audio price and
an Audio tag; any model id can be typed at the bottom. The three defaults are raced over tuned Vertex routes;
other models are left to OpenRouter's routing and get the smallest reasoning effort.
Balanced and Thorough run Instant's model alongside as a backup. Its text is used if theirs errors
(3.8 Flash has returned SAFETY refusals), stops early, takes too long (8 s; Thorough also gets 4 s per minute of audio),
or comes back far shorter than the backup's.

**Clean text.** The default prompt asks for what the speaker meant to write: no fillers or stutters, no phrase said twice
by accident, and only the corrected version when the speaker corrects themselves. It is editable under Settings › Prompt,
which can also preview the exact system message sent (prompt plus vocabulary) and *Reset to Default* (after asking). Utter also removes any phrase of two or more words that still comes back doubled
("the menu, the menu will" → "the menu will").

**Vocabulary.** Settings › Vocabulary (also *Edit Vocabulary…* in the menu): add words in a field (commas add several) and
remove them from their chips, or *Edit as text* (one per line, # for notes). Sent after the prompt
with every request as required spellings ("Claude Code", not "Cloud Code"). It is stored in
`~/Library/Application Support/Utter/vocabulary.txt` and starts with Filo, Utter, Retype, Claude Code, OpenRouter and Gemini.

All settings apply from the next dictation.

## Build and run

```sh
scripts/build.sh          # → build/Utter.app (and build/TestPad.app for the self-test)
open build/Utter.app
```

The menu bar icon shows a crossed-out mic until the key and permissions are in place, and the menu says what is missing,
with a button that fixes it. The hotkey starts within a second of the Accessibility grant, with no relaunch.
The build is signed with your Apple Development identity, so the grants carry over to later rebuilds
(`UTTER_SIGN_IDENTITY` picks another).

The key is read and written through `/usr/bin/security`, which the Keychain item trusts, so no Keychain prompt appears.
The key goes in on its standard input, never on a command line, and it never touches the repo.

## How it turns speech into text

Quality comes first: every cut in the audio is a place where a word can be lost or doubled, so Utter cuts as little as it can.

1. **Up to 45 s: one request.** The whole recording goes to the model in one request when you let go.
   A whole-clip request takes about the same time whatever its length (≈0.8 s for 1 s of audio, ≈0.95 s for 23 s).
2. **Longer: ~30 s blocks at real pauses.** Once a recording passes 45 s, it is cut only where you paused for 0.8 s or more,
   into blocks of about 30 s. Each block is sent while you keep talking, so at release only the last block is left.
   Each block starts 1 s before the previous one ended, so nothing falls into the gap. It carries the earlier text as
   context, so names, wording and language stay consistent, and the model is told where the overlap picks up.
   When the texts are joined, any words the overlap repeated are dropped.
   With no real pause at all, a block grows to 120 s before it is cut at its longest shorter pause.
3. **Racing.** The request sent at release goes to `google-vertex/global`, `google-vertex/global/priority` and
   `google-vertex/eu` at once, and the first answer wins. This removes the occasional multi-second stall.
4. **Warm connection.** Pressing the hotkey opens the TLS connection if it is idle, and a 20 s keep-alive runs for 30 min after use.
5. **Compact upload.** Audio goes up as 32 kbps AAC in an M4A file (about 4 KB/s) instead of WAV (32 KB/s).
   Not raw AAC (ADTS): Gemini drops the last second or more of those.

### Measured

`utter-bench` runs WAV files through the same pipeline in real time (with 0–40 ms of extra silence in front on each run, so no two requests are identical).
It reports the time from simulated key release to the full transcript.
The clips are macOS `say` voices (`bench/clips`, scripts in `bench/scripts`), not human recordings.
Gemini 3.1 Flash-Lite, release 0.3 s after the last word, 2026-10-30 around 11:40, when Vertex was slower than earlier in the day:

| dictation | requests | n | release→text median (range) | one plain request for the whole clip, same hour |
|---|---|---|---|---|
| short (1.8–5.1 s, 8 clips) | 1 | 24 | 1015 ms (926–1459) | 1120–1230 ms (2.6 s clip) |
| ~25 s (`mid25`, 23 s) | 1 | 3 | 1334 ms (1326–1982) | 1433–1570 ms |
| ~70 s, paragraph pauses (`long70`, 66 s) | 2 | 5 | 1457 ms (1321–2160) | 1604–1752 ms |
| ~75 s, pauses mid-sentence (`long70-midsentence`) | 3 | 5 | 1235 ms (1216–1523) | — |

Release-to-text is now the provider's own time for one request (racing three routes shaves a little off it).
For long dictations only the last block is left at release, so they finish about as fast as a 25–35 s one.

**Word for word.** `scripts/compare.py` checks transcripts against the script. Both long clips came back exact
(177 and 209 words, 0 differences, all runs), so no words were dropped or doubled at the block joins.
The 25 s clip has one miss in every run, "hotkey" heard as "hot", which a single request with the original WAV gets wrong too.

**A real recording.** A 39 s dictation in the user's own voice (reference text in `bench/real/option-hold.txt`),
run through the full pipeline and scored with `scripts/score.py` (word-level edit distance against the reference,
case and punctuation ignored). 2026-10-30, around 12:30:

| mode | runs | words wrong (median, range) | release→text (median, range) | model used |
|---|---|---|---|---|
| Instant | 4 | 12.6% (9.9–23.4%) | 1.68 s (1.56–1.87) | 3.1 Flash-Lite |
| Balanced | 4 | 9.5% (4.5–10.8%) | 2.87 s (2.63–3.34) | 3.8 Flash every time |
| Auto (39 s, so Balanced) | 3 | 9.0% (9.0–11.7%) | 2.82 s (2.75–3.23) | 3.8 Flash every time |

Every run spelled "Claude Code" right and none doubled "the menu". Short clips on Auto stay on Lite (about 1.2 s).
Instant's misses are mishearings that change from run to run; it also writes "Utter" as "after" despite the vocabulary.

**Thorough, and no slowdown from the settings.** 2026-10-31, the same 39 s recording, scored the same way.
Old and new builds took turns on the same clips:

| | round 5 build | this build |
|---|---|---|
| Instant, 4 short clips (1.9–3.3 s), n=24 each | 1.13 s | 1.07 s |
| Balanced, 4 short clips, n=24 each | 2.30 s | 2.32 s |
| Instant, 39 s recording, n=3 each | 1.92 s | 1.98 s |
| Balanced, 39 s recording, single requests, n=16 / 20 | 3.90 s | 3.69 s |
| Thorough (Gemini 4 Argon), 39 s recording, n=3 | — | 5.48 s (4.83–5.57), 3.6–4.5% words wrong |

Balanced came in at 5.4–10.8% words wrong and Instant at 11.7–25.2% in the same runs. That day 3.8 Flash refused the recording
(content_filter) or stalled past 8 s in about a quarter of requests, on both builds alike; Instant's backup text was used then.

The bench makes each run unique with 0–40 ms of extra silence in front, not added noise:
faint white noise over the whole clip made 3.8 Flash refuse 2 of 3 requests (SAFETY) and hurt accuracy.

```sh
swift build -c release --product utter-bench
.build/release/utter-bench --reps 3 --hold-after 0.3 bench/clips/*.wav
.build/release/utter-bench --verbose bench/clips/long70.wav  # shows each block being sent and returned
.build/release/utter-bench --mode accurate bench/clips/*.wav   # auto (default), fast, accurate or veryAccurate
.build/release/utter-bench --mode accurate --model accurate=google/gemini-3.7-flash bench/clips/*.wav   # try another model
.build/release/utter-bench --transcripts /tmp/tx bench/clips/long70.wav && scripts/compare.py bench/scripts/long70.txt /tmp/tx/long70.*.txt
```

**Real use is logged too.** Every dictation appends one line to `~/Library/Application Support/Utter/timings.csv`
(audio length, requests, release→text ms and the model used; no text). The details go to `~/Library/Logs/Utter/utter.log`:
timings, routes and errors, never what was said (each block's text appears as its length; `defaults write dev.utter.Utter
UtterLogTranscripts -bool YES` puts the text in, for debugging). Past 1 MB the log moves to `utter.old.log`. Quitting
(menu, ⌘Q or a signal) is logged too.
Turn on *Keep Recordings for Benchmarks* in the menu to also save the audio to `…/Utter/recordings/` (failed ones to
`…/Utter/failed/`); with it off, no audio is saved, failed or not.
Feed those files to `utter-bench` to measure your own voice.

## Hidden settings and checks

```sh
defaults write dev.utter.Utter UtterExtraInstructions "Translate everything into English."   # appended to the prompt
defaults write dev.utter.Utter UtterAudioFormat wav    # upload WAV instead of M4A
UTTER_DEFAULTS_SUITE=utter-fresh open -n build/Utter.app   # a first launch with empty settings (the key is still read from Keychain)
build/Utter.app/Contents/MacOS/Utter --check-hotkeys     # feeds made-up key events to the hotkey logic, no window, prints PASS/FAIL
open -n build/Utter.app --args --capture-ui /tmp/ui   # opens the real Settings and setup windows, saves every page in light and dark
scripts/make-icons.sh                                   # redraws the logo into Resources/AppIcon.icns and design/icons/
```

## Self-test (end to end)

This test opens one TestPad window (a native text view, or with `--field web` a web `<textarea>`).
Utter then holds (or double-taps) Option with synthetic key events and plays a clip in place of the microphone.
The test checks that the transcript landed in the field and that nothing else was typed.
Synthetic keys and the paste happen only while TestPad is frontmost with its window key. If focus leaves, the run stops.
It needs Utter's Accessibility grant.

```sh
open -n build/TestPad.app --args --state /tmp/pad.json --field native
open -n build/Utter.app --args --selftest --pad-state /tmp/pad.json --out /tmp/selftest.json \
     --clip "$PWD/bench/clips/short1.wav" --clip "$PWD/bench/clips/med1.wav" [--mode handsfree]
cat /tmp/selftest.json
```

Quit any running Utter before starting the self-test, so that two hotkey taps don't compete.

The modifier gesture logic (hold, tap, double tap, shortcuts, clicks), hotkeys (sides, clashes), modes and the segmenter
have unit tests: `swift test`.

## Layout

- `Sources/UtterCore`: Segmenter (VAD and where to cut), DictationPipeline (blocks, context, joining), Transcriber (OpenRouter),
  Models (modes, tiers, models), Settings, Hotkey and ModifierGesture (hotkey logic), OpenRouter (key check, model list),
  Vocabulary, AAC encoder, Keychain, log
- `Sources/Utter`: menu bar app (hotkey tap, mic, paste, HUD, self-test), setup and Settings windows (SwiftUI:
  `OnboardingView`, `SettingsView`, `Components`, `AppModel`, `Windows`), `Logo`, `HotkeyCheck`
- `Resources/AppIcon.icns`, `design/icons/`: the app icon and the logo alternatives (from `scripts/make-icons.sh`)
- `Sources/ObjCCatch`: turns AVAudioEngine's Objective-C exceptions into Swift errors, so a mic problem can't crash the app
- `Sources/utter-bench`: latency benchmark
- `Sources/TestPad`: self-test target window
- `scripts/build.sh`: builds and signs the app bundles
- `scripts/probe.py`: quick per-provider latency probe
- `scripts/compare.py`: word-for-word check of transcripts against `bench/scripts`
- `scripts/score.py`: words-wrong rate against a reference text (`bench/real` holds references for real recordings)
