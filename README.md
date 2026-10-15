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
swift test                                         # 74 tests, runs natively on Linux

xtool dev build                                    # -> xtool/Aurelia.app
xtool dev build --configuration release --ipa      # -> xtool/Aurelia.ipa
xtool install xtool/Aurelia.ipa
```

Requires Swift 6.4.1, [xtool](https://github.com/xtool-org/xtool) 1.22.2, and a Darwin SDK built
from Xcode 27 with `xtool sdk install --slim`.

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
Sources/StudyBuddyCore/     Foundation only. No UIKit, no SwiftUI, so `swift test` runs on Linux.
  TagParser.swift           the speech/side-effect split, and where naive ports break
  BrainClient.swift         streaming chat completions
  SSEReader.swift           one AVAudioSession-safe reader; see the note below
  PromptBuilder.swift       the persona and prompt assembly
  ContentStore.swift        reads the bundled curricula
  MiniHTML.swift            just enough HTML reading for fixed generated pages
  ProgressStore.swift        SQLite, a direct port of the Python schema
  ProgressMath.swift        the ladder and streak, extracted so they are testable
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

## Diagnostics

`xtool launch` cannot start apps on this device, and Xcode 27 ships no Developer Disk Image, so
there are no device screenshots and `NSLog` goes nowhere. The app therefore appends everything to
`Documents/aurelia.log`, which is pulled over USB:

```sh
mkdir -p /tmp/aurelia && ifuse -u <udid> --documents <bundle-id> /tmp/aurelia
cat /tmp/aurelia/aurelia.log
```

It logs every permission decision, audio-format and engine state change, partial transcript, tutor
event, and each stage of the HTTP request. This is not decoration: the turn that hung silently for
fifteen minutes was one log line away from being found.

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
