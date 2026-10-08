# Minutes — offline AI meeting notes for iPhone

Record or import a meeting. Minutes transcribes it, tells **Speaker 1** from **Speaker 2**, and writes a summary, key decisions and action items — **entirely on-device**. After the one-time model download, it works in Airplane Mode.

Like Granola, Minutes gives you a blank notepad while it listens. Afterwards, the on-device LLM *enhances your notes* with the transcript instead of replacing them.

## Pipeline

```
mic ─► AVAudioEngine tap ─► convert once (16 kHz mono) ─┬─► SpeechAnalyzer (live, word timestamps)
                                                        └─► audio.wav
stop ─► FluidAudio diarizer (audio.wav) ─► Merge(words, speaker segments) ─► turns
     ─► Qwen3-1.7B via llama.cpp ─► Markdown notes (streamed) ─► parsed Notes
```

| Stage | Model / library | Runs on | Footprint |
|---|---|---|---|
| Live preview while recording | iOS 26 `SpeechAnalyzer` + `SpeechTranscriber` (on-device; **not** Apple Intelligence / Foundation Models) | ANE/CPU | 0 MB in app (OS-managed asset) |
| Final transcript (after Stop / on import) | **NVIDIA Parakeet TDT 0.6B v2** via FluidAudio (CoreML), with word timestamps | ANE | 450 MB |
| Speaker diarization | [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.7: **pyannote community-1 + VBx** (primary), with **NVIDIA Sortformer v2.1** (high-context) as the second opinion whenever pyannote hears only one speaker | ANE / CPU | 22 MB + 252 MB |
| Notes | [LLM.swift](https://github.com/eastriverlee/LLM.swift) 3.0.3 (prebuilt llama.cpp xcframework, Metal) + **Qwen3-1.7B Q4_K_M** GGUF (Apache-2.0) | GPU | 1.1 GB (mmapped) |
| Read notes aloud | `AVSpeechSynthesizer` with the best installed English voice (Premium/Enhanced neural voices preferred), section by section with pauses | on-device | 0 MB |

## Key decisions and trade-offs

- **Transcription runs live during recording.** SpeechAnalyzer streams, so the transcript is already done when you tap Stop. The only post-processing is diarization (seconds) and the notes. Imported files go through the same analyzer from disk.
- **Apple for the live preview, Parakeet for the final transcript.** Apple's streaming model gives an instant live transcript at 0 MB. But on real Indian-English conversations recorded on the iPhone, it misheard content words: "Why is your *kid* like that?" (feed), "I have a *2 Something*" (I'm up to something), "*1000000 copies soon*" (over a million copies). Apple's `en-IN` and `en-GB` models were no better, and `en-IN` dropped whole sentences. On the same audio, Parakeet got those words right and was word-perfect on the synthetic test. So after Stop, Parakeet re-transcribes the WAV (~2 s per minute of audio on an iPhone 15), and the live words stay as the fallback. Parakeet is weaker on some proper nouns ("Farahana Katar") and can invent a few words over loud background noise.
- **Diarizer chosen by testing on real recordings, not by benchmarks.** I ran every diarizer in FluidAudio on the same set of files with a small Mac CLI, then confirmed the results on the iPhone. No single model got everything right:

  | Recording | pyannote + VBx | LS-EEND (CALLHOME) | Sortformer | **Hybrid (shipped)** |
  |---|---|---|---|---|
  | 2 people in person, similar voices, noisy room | ❌ 1 speaker | ✅ | ✅ | ✅ 2 speakers, 14 turns |
  | Podcast played through a speaker | ✅ | ❌ 1 speaker | ✅ | ✅ |
  | Two different videos played back | ✅ | ❌ 1 speaker | ❌ on iPhone | ✅ |
  | Synthetic 2-voice meeting | ✅ 11/11 | ✅ 11/11 | ⚠️ 10/11 | ✅ 11/11 |
  | One speaker | ✅ | ✅ | ✅ | ✅ |
  | 10-min identity consistency | ✅ 91/91 | ✅ 91/91 | ✅ 97/99 | ✅ **91/91** |

  pyannote's only failure mode was *merging* two real voices into one, and Sortformer is the model that separates them. So Minutes runs pyannote first and asks Sortformer only when pyannote hears a single speaker. A true monologue stays one speaker in both. Sortformer's occasional phantom label (≈5 % of speech) is dropped below a 10 % share.
- **Word→speaker merge** ([Merge.swift](Minutes/Merge.swift)) ports whisperX `assign_word_speakers`: each word goes to the speaker segment it overlaps most (or the nearest one if none overlaps). Islands of 1–2 words inside another speaker's turn are absorbed (diarization jitter), and monologues are split at pauses over 2 s. Device testing found that Apple's timestamps stretch the first word after a pause back over the silence, which put it with the previous speaker. Long words are now judged by their last 0.6 s, and a test reproduces the real case.
- **llama.cpp over MLX.** It's a prebuilt binary (no 10-minute Metal/C++ compile), and mmapped weights keep resident memory far below MLX's. Decode is ~20 % slower, which doesn't matter for a ~500-token answer. Qwen3-1.7B has the best instruction-following of the Apache-licensed models under 1.2 GB; thinking is disabled (`.suppressed` + `/no_think`).
- **Markdown output, not JSON.** 1–2B models follow fixed headings more reliably than JSON. A lenient parser handles variations, and if the model ignores the format, its raw text becomes the summary, so nothing is lost.
- **Memory.** The stages never hold models at the same time: diarizer → released → LLM loaded → released (back to ~50 MB after notes). The LLM context is **sized to the transcript** (2k–8k tokens). A fixed 8k context peaked at 2.5 GB even for a 1-minute meeting on the 6 GB iPhone 15; adaptive sizing brings that to 0.6 GB. Meetings over ~35 min keep the beginning and end ([NotesWriter.fit](Minutes/NotesWriter.swift)). The `increased-memory-limit` entitlement would add headroom but needs a paid developer team.
- **Read-aloud stays on-device.** ElevenLabs would sound great but is a cloud API, which the brief forbids and which breaks Airplane Mode. Kokoro-82M (open source, in FluidAudio) was the quality pick, but FluidAudio documents BNNS segfaults on iOS 26.4–26.5.x (the test iPhone runs 26.5.2) and no iOS version yet proven safe. So Minutes uses Apple's neural Premium/Enhanced voices when installed, and tells the user where to get one if not.
- **Models download once on first launch rather than ship in the bundle.** This keeps the binary small and separates *binary size* from *model footprint*.

## Speech fallback

Apple's `SpeechTranscriber` is unsupported in the iOS Simulator and on older iPhones (`SpeechTranscriber.isAvailable == false`). In that case Minutes uses **Parakeet TDT 0.6B v2** through FluidAudio ([Parakeet.swift](Minutes/Parakeet.swift), ~450 MB, 2.1 % WER). That path transcribes right after Stop instead of live, and the Setup screen shows which engine the device uses.

## Simulator test run (iPhone 17 Pro simulator, M4 Mac, CPU only — no ANE/Metal)

Test input: a synthetic 65-second, 11-turn two-person product meeting (macOS voices Samantha and Daniel), imported as m4a.

| Stage | Time | Result |
|---|---|---|
| Model setup (first launch) | 80 s | 474 MB FluidAudio (Parakeet + diarizer) + 1.0 GB GGUF |
| Transcription (Parakeet fallback) | 5.4 s | 181 words, word-for-word correct |
| Speaker diarization | 6–8 s | **2 speakers, 11/11 turns attributed correctly** |
| Notes (Qwen3-1.7B, CPU-only in Simulator) | 62–87 s | 4/4 decisions; action-item owners correct |

The simulator runs llama.cpp on CPU only. On an iPhone it uses Metal, so expect notes in a fraction of that time.

## Measurements — iPhone 15 (A16, 6 GB), iOS 26.5.2, models warm

Each meeting stores per-stage timings, shown in the app footer and logged as `[Minutes] <stage>: N s · <memory> MB`.

| Test | Transcribe | Speakers | Notes | Total | Peak memory | Speaker accuracy |
|---|---|---|---|---|---|---|
| Live recording, 68 s, 2 real people, Airplane Mode | live (0 s) | 3.6 s (pyannote + Sortformer) | 4.8 s | **~8 s after Stop** | 0.6 GB | 2 speakers, 14 turns |
| Podcast replayed through a speaker, 105 s | 2.2 s | 2.5 s | 7.3 s | 12 s | 0.7 GB | 2 speakers (host ↔ guest) |
| Import, 65 s, 2 voices (synthetic) | 1.3 s | 3–4 s | 7.6 s | 12 s | 0.6 GB | **11/11 turns** |
| Import, 9.7 min, 2 voices | 10.0 s | 26.6 s | 20.0 s | **57 s** | 2.2 GB | **91/91 turns** |
| Import, 35 s, one speaker | 0.9 s | 2.5 s | 6.9 s | 10 s | 0.5 GB | 1 speaker ✓ (both models agree) |
| Import, 20 s silence | 0.4 s | — | — | — | — | "No speech detected" ✓ |

| Size | Value |
|---|---|
| App (Release, after App Store symbol stripping) | **~40 MB** (33 MB binary + 5.7 MB llama.framework); 21 MB unstripped IPA download |
| Models, downloaded once (~1.8 GB) | Qwen3-1.7B 1.03 GB + Parakeet 450 MB + Sortformer 252 MB + pyannote 22 MB + Apple speech (OS-managed) |
| First-run setup | ~40 s on Wi-Fi |

Transcription accuracy note: on the synthetic TTS voices, Apple's model made ~5 errors in 182 words ("sink engine" for "sync engine"), where Parakeet was word-perfect on the same audio. On real human speech, Apple's model transcribed both speakers cleanly.

## Known limitations

- English only; iOS 26+. Tested mainly on two-person conversations (three voices were separated in one playback test).
- Sortformer adds 252 MB for the in-person case. With less download budget, LS-EEND (43 MB) is a drop-in alternative, but it fails on audio played through a speaker.
- Live transcript preview needs Apple SpeechTranscriber hardware support (not available in the Simulator).
- In noisy rooms with fast back-and-forth (speech ~10 dB above the noise), a speaker change can land one sentence late, and Parakeet may invent a word or two from background noise. Quiet rooms and the phone between the speakers give the best results.
- Overlapping speech goes to whichever speaker overlaps the word most.
- Far-away or very quiet speakers in a noisy room may be missed (in one test, neither transcription nor diarization could hear a person across the room).
- The 1.7B notes model sometimes assigns an action item to the person who asked for it rather than the one who agreed to do it.
- The notes context is 8k tokens; meetings over ~40 min are trimmed in the middle (map-reduce would fix this).
- The LLM download restarts from zero if interrupted.
- Processing needs the app in the foreground (recording continues in the background).

## Build

Requires Xcode 26 and a real iPhone (the LLM runs on Metal).

```sh
brew install xcodegen
xcodegen generate && open Minutes.xcodeproj   # set your Team under Signing, run on device
```

Tests (⌘U): `MergeTests` (speaker assignment) and `NotesParseTests` (notes parser).

## Docs

- [AI workflow reflection](docs/ai-workflow.md)
- Agent session transcripts: `docs/sessions/`
