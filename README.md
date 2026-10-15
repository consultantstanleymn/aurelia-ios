# Aurelia

A voice tutor that talks, listens, and knows what you got wrong last week.

Three curricula — AWS Solutions Architect Professional (70 days), LSAT (168 days), quant finance
(24 weeks) — taught by conversation. It speaks, it listens, it puts things on a whiteboard, and it
remembers every graded answer.

Built and signed on a Fedora laptop and installed on an iPhone. No Mac was involved at any point.

## What it is

A native SwiftUI app. The tutor's replies arrive as a token stream that interleaves speech with
hidden tags — put this on the board, log that answer, file a note, assign homework — and the app
takes each one as it arrives rather than waiting for the reply to finish.

It knows:

- **the material.** 238 days of AWS and LSAT prose plus practice questions, and 24 weeks of
  quant checklist, all parsed from the bundled curriculum files, with the answer key withheld from the prompt so the tutor has to hear what you
  actually say
- **what you miss.** A spaced-repetition ladder per topic; miss and it comes back tomorrow, hit and
  it climbs 1 / 3 / 7 / 16 / 35 days
- **your streak**, in days and minutes, and which syllabus sections you have covered
- **what you said**, spoken or typed, with a partial transcript you can correct before sending

## Building

```sh
export PATH="$HOME/.local/swift/usr/bin:$PATH"     # Swift 6.4.1 is not on PATH by default

bash tools/stage-content.sh                        # copy the curricula in
bash tools/inject-key.sh                           # bake the provider key in
swift test                                         # 145 tests, runs natively on Linux

xtool dev build                                    # -> xtool/Aurelia.app
xtool dev build --configuration release --ipa      # -> xtool/Aurelia.ipa
xtool install xtool/Aurelia.ipa
```

Requires Swift 6.4.1, [xtool](https://github.com/xtool-org/xtool) 1.22.2, and a Darwin SDK built
from Xcode 27 with `xtool sdk install --slim`.

`swift test` also needs `sqlite-devel` (`sudo dnf install sqlite-devel`). Without it the progress
store compiles to nothing on Linux — it sits behind `canImport(SQLite3)`, and Linux ships the
headers without a Clang module map for them — so the suite would pass while every query in it went
unrun. The `CSQLiteShim` target re-exports the system header to put that right.

## The brain

Any OpenAI-compatible `/chat/completions` endpoint. Defaults to DeepSeek.

OpenCode's free models are deliberately *not* wired in: that gateway answers a direct call from
another app with `403 "can only be used from within OpenCode"`. It is a restriction on the client,
not on the key, so there is no header that gets around it. A workaround exists: shell out to the opencode CLI, which is inside
OpenCode and therefore allowed. It is free, but it needs a machine switched on, so it is not the
default and is not included here.

## The voice

Two engines behind one protocol, so the app talks either way.

- **System voice** — Apple's Premium neural tier. Free, instant, offline.
- **Chatterbox** — MIT licensed, and the only free model with real paralinguistic control:
  `[laugh]`, `[chuckle]`, `[sigh]`, plus an exaggeration slider. At 350M parameters it runs on
  another machine and streams audio back. Set the URL in Settings.

A tutor's prosody carries meaning the text does not, so the engine is handed a mood rather than a
string — a hint slows down, praise lifts slightly, a correction stays level rather than dropping,
which reads as disappointment.

## Layout

```
Sources/CSQLiteShim/           re-exports the system SQLite header, so the store builds on Linux
Sources/StudyBuddyCore/     Foundation only. No UIKit, no SwiftUI, so `swift test` runs on Linux.
  TagParser.swift           the speech/side-effect split, and where naive ports break
  BrainClient.swift         streaming chat completions
  SSEReader.swift           one AVAudioSession-safe reader; see the note below
  PromptBuilder.swift       the persona and prompt assembly
  ContentStore.swift        reads the bundled curricula
  MiniHTML.swift            just enough HTML reading for fixed generated pages
  ProgressStore.swift        SQLite, a direct port of the Python schema
  ProgressMath.swift        the ladder and streak, extracted so they are testable
  ReminderSchedule.swift    when a reminder next fires, and why it is in here
  ComposerBuffer.swift      how speech gets into the composer
  BoardShape.swift          board kinds parsed into shapes
  ChatterboxVoice.swift     the HTTP voice engine
Sources/StudyBuddy/         the app. Builds only through xtool.
  SpeechRecognizer.swift    on-device listening
  Voice.swift               system voice and audio playback
  BoardView.swift           the whiteboard; one scoped web view, for mermaid only
  Reminders.swift           UNUserNotificationCenter
  DiagLog (in Core)         see below
tools/
  stage-content.sh          curricula in
  inject-key.sh             the key in
```

## Where the logic lives, and why it is where it is

The app is the only part that cannot be tested from this machine: `xtool launch` does not start apps
on the phone, so a SwiftUI view is only ever verified by a human looking at a screen. Anything with
a decision in it therefore lives in Core, where `swift test` reaches it, and the view above it stays
thin. That is why speech merging is a type with tests rather than a line in `ContentView`, and why
"when does this reminder next go off" is in Core rather than next to `UNUserNotificationCenter`.

It is also why the test count is 145 rather than a handful. Every one of them runs on Linux in
seconds.

## Two things worth knowing if you change this

**The audio session belongs to exactly one thing.** When the Chatterbox queue claimed it and set
`.playback` on init, the microphone could not open and the app failed with `Session activation
failed` and nothing in the log. The recogniser now walks a ladder of category/option combinations
and takes the first that activates, because which one is accepted depends on what the system is
already doing with audio.

**Install `installTap` can raise, and it does not throw.** A Swift `catch` cannot save you. Read
`inputNode.outputFormat(forBus:)` only after the session is configured *and* activated, and check
it — it reports 0 Hz and 0 channels before then, and `installTap` raises on that rather than
returning an error.

**A full stop only ends a sentence when whitespace follows it.** Otherwise the tutor says
`10.0.0.0/8` as eight separate fragments and `v1.0.44` as four, which is exactly the material this
app exists to teach. The rule was in this file's documentation long before it was in the code.

## Checking what a build actually contains

The build is green whether or not the feature is in it, so the payload gets checked directly:

```sh
unzip -q xtool/Aurelia.ipa -d /tmp/ipa
strings -a /tmp/ipa/Payload/Aurelia.app/Aurelia | grep -c 'SFSpeechRecognizer'
```

One trap worth knowing: **in a release build, `strings` cannot see string literals of 15 bytes or
fewer.** Swift stores those inline in the instruction stream, so `grep -c 'turn.begin'` returns 0 on
a release binary and 1 on a debug one, with identical behaviour. The code is there either way. Use
a longer literal — a sentence of copy rather than a log key — when confirming what shipped.

## Diagnostics

`xtool launch` cannot start apps on this device, and Xcode 27 ships no Developer Disk Image, so
there are no device screenshots and `NSLog` goes nowhere. The app therefore appends everything to
`Documents/aurelia.log`, which is pulled over USB:

```sh
mkdir -p /tmp/aurelia
idevice_id -l                                    # find the UDID
ifuse -u <udid> --documents <bundle-id> /tmp/aurelia
cat /tmp/aurelia/aurelia.log
fusermount -u /tmp/aurelia
```

`idevice_id -l` prints the UDID, and the bundle id is **not** the one in `xtool.yml`. Free-account
signing prefixes it on the device: `ch.stanley.aurelia` installs as
`XTL-V63Z8847B5.ch.stanley.aurelia`, and `ifuse` fails with `InstallationLookupFailed` if given the
unprefixed one.

It logs every permission decision, audio-format and engine state change, partial transcript, tutor
event, and each stage of the HTTP request. Progress writes are logged on failure too, rather than
swallowed — a bare `try?` in the app is how the store managed to be broken and look perfectly
healthy. This is not decoration: the turn that hung silently for fifteen minutes was one log line
away from being found.

## Credits

- [openGym](https://github.com/DuarteSantos8/openGym) — Duarte Santos. The iOS build in
  `openGym-ios` established that a SwiftUI app compiles on Linux with xtool, and the same techniques
  apply here.
- [xtool](https://github.com/xtool-org/xtool) — the cross-platform Xcode replacement that makes any
  of this possible.
- [Chatterbox](https://github.com/resemble-ai/chatterbox) — Resemble AI, MIT.
- The AWS and LSAT curricula in `content/` are Stanley's own, MIT. The quant checklist is
  Apache-2.0.

## Licence

MIT, © Stanley Sujith Nelavala. See `LICENSE`.
