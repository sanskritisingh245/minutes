# Minutes

Offline AI meeting notes for iPhone. Record or import a meeting, and Minutes transcribes it, labels **Speaker 1 / Speaker 2**, and writes a summary, key decisions and action items, **entirely on-device**. After a one-time model download it works in Airplane Mode.

## Features

- **Record or import** audio (m4a, wav, …); recording continues in the background
- **Transcript with timestamps**: live preview while recording, accurate final pass after Stop
- **Speaker diarization**: consistent Speaker 1 / Speaker 2 labels across the whole meeting
- **AI notes**: summary, decisions, action items, merged with what you typed during the meeting (Granola-style)
- **Read aloud**: plays the notes back with Apple's on-device neural voices
- **No cloud, no Apple Intelligence, no Foundation Models**

## How it works

```
Record ─► 16 kHz mono WAV ──► live preview (Apple SpeechAnalyzer, display only)
Stop   ─► Parakeet ─► words + timestamps
       ─► pyannote (+ Sortformer if 1 speaker found) ─► who spoke when
       ─► merge words with speakers ─► transcript
       ─► Qwen3-1.7B ─► summary · decisions · action items
```

Each model is loaded, used and released in turn, so only one is in memory at a time.

## Models & libraries

| Stage | Model / library | Size |
|---|---|---|
| Transcription | NVIDIA Parakeet TDT 0.6B v2 via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML, ANE) | 450 MB |
| Diarization | pyannote community-1 + VBx, with NVIDIA Sortformer v2.1 as a second opinion (FluidAudio 0.17.7) | 22 MB + 252 MB |
| Notes | Qwen3-1.7B Q4_K_M via [LLM.swift](https://github.com/eastriverlee/LLM.swift) 3.0.3 (llama.cpp, Metal) | 1.03 GB |
| Live preview | iOS 26 `SpeechAnalyzer`: on-screen preview only; every saved output comes from the open-source models above | OS-managed |
| Read aloud | `AVSpeechSynthesizer` | 0 MB |

**App size:** ~40 MB (App Store build). **Models:** ~1.8 GB, downloaded once on first launch (~40 s on Wi-Fi).

## Performance (iPhone 15, iOS 26.5.2)

| Input | Transcribe | Speakers | Notes | Total | Peak RAM | Speaker accuracy |
|---|---|---|---|---|---|---|
| Live, 68 s, 2 people, Airplane Mode | live | 3.6 s | 4.8 s | **~8 s after Stop** | 0.6 GB | 2 speakers, 14 turns |
| Import, 65 s, 2 voices | 1.3 s | 3–4 s | 7.6 s | 12 s | 0.6 GB | 11/11 turns |
| Import, 9.7 min, 2 voices | 10 s | 26.6 s | 20 s | 57 s | 2.2 GB | 91/91 turns |
| Import, 35 s, 1 speaker | 0.9 s | 2.5 s | 6.9 s | 10 s | 0.5 GB | 1 speaker ✓ |

## Key decisions

- **Parakeet over Apple speech for the final transcript.** On real Indian-English recordings, Apple's model misheard content words ("kid" for "feed"); Parakeet got them right.
- **Hybrid diarizer, chosen by testing real recordings.** pyannote's only failure was merging two similar voices into one; Sortformer separates them. So Sortformer runs only when pyannote hears a single speaker.
- **llama.cpp over MLX.** Prebuilt binary, and memory-mapped weights keep RAM low.
- **LLM context sized to the transcript** (2k–8k tokens): peak memory for a 1-min meeting dropped from 2.5 GB to 0.6 GB.
- **Markdown output, not JSON.** Small models follow headings more reliably; a lenient parser falls back to raw text, so nothing is lost.
- **Models downloaded, not bundled**, which keeps the app binary small.

## Requirements

- iPhone with iOS 26+ (the LLM needs Metal; the Simulator runs CPU-only and slowly)
- Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting started

```sh
brew install xcodegen
xcodegen generate
open Minutes.xcodeproj   # set your Team under Signing & Capabilities, run on a device
```

On first launch, the Setup screen downloads the models. After that, everything works offline.

## Tests

Run with ⌘U in Xcode:

- `MergeTests`: assigning words to speakers
- `NotesParseTests`: parsing the notes output

## Project structure

```
Minutes/
  Audio.swift         recording, playback, read-aloud
  Transcriber.swift   live preview (SpeechAnalyzer)
  Parakeet.swift      final transcription
  Diarizer.swift      pyannote + Sortformer
  Merge.swift         words → speaker turns
  NotesWriter.swift   Qwen3 prompt, context sizing, parsing
  Pipeline.swift      runs the stages after Stop / import
  ModelManager.swift  model downloads
  *View.swift         SwiftUI screens
MinutesTests/         unit tests
```

## Known limitations

- English only; tested mainly on two-person conversations.
- Cannot record phone or VoIP calls on the same iPhone (iOS blocks it). Use a call recording via Import instead.
- Noisy rooms: a speaker change can land one sentence late, and quiet or distant speakers may be missed.
- Overlapping speech goes to one speaker.
- Meetings over ~40 min are trimmed in the middle to fit the 8k LLM context.
- The notes model sometimes assigns an action item to the person who asked rather than the person who agreed.
- Interrupted model downloads restart from zero; processing needs the app in the foreground.

## Docs

- [AI workflow reflection](docs/ai-workflow.md)
- [Agent session history](docs/sessions/)
