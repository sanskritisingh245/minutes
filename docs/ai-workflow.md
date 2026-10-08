# AI workflow reflection

Agent: Claude Code. Full transcripts are in `docs/sessions/`.

## How I broke the problem down

1. **Research before code.** Three research agents ran in parallel, one per hard choice: ASR, diarization, and the on-device LLM. Each had to return pinned versions, model sizes, measured iPhone numbers with sources, and a ranked pick. A planning agent then checked the exact API signatures at the pinned versions.
2. **Constraints first.** The brief bans cloud AI, Apple Intelligence and Foundation Models. Judging covers size, memory and speed. That ruled out MLX (long compile, high RSS) in favour of prebuilt llama.cpp, and favoured a 0-MB OS speech model plus a 22-MB diarizer.
3. **Thin wrappers, one pure function.** Every ML library sits behind a ~20-line wrapper. The only algorithm written by hand is the word→speaker merge, and it's pure and unit-tested.
4. **Verify against source, not READMEs.** I cloned the dependency repos at the pinned tags and grepped the public signatures.

## Where the agent was wrong or needed steering

- **Stale library docs.** FluidAudio's README shows `transcribe(samples, source:)`, but at 0.17.7 the only public overloads need an `inout TdtDecoderState`. That was caught by reading the source at the tag, before it cost a build cycle.
- **Regex literals.** The parser first used a bare `/regex/` literal, which doesn't compile in Swift 5 language mode (the project's setting). It was caught by compiling the parser with `swiftc` before Xcode was even installed; I switched to `#/…/#`.
- **A test that couldn't fail.** The first local check of the merge logic was compiled with `-O`, which strips `assert`, so it "passed" without testing anything. Rerun with `-Onone`.
- **A ~2 GB memory leak.** The LLM's streaming `update` closure captured the `LLM` instance strongly (`bot.stop()` inside it). That's a retain cycle that would keep the weights and KV cache alive after every meeting. Fixed with `[weak bot]`.
- **Main-thread decode.** Importing a file resampled the whole file on the main actor, which would freeze the UI on long files. Moved to a detached task.
- **Locale reservation.** The first simulator run failed with "not subscribed to transcription.en": iOS 26 requires `AssetInventory.reserve(locale:)` before using speech assets. The agent found the fix by reading a working open-source app (swift-scribe).
- **SpeechTranscriber is unsupported in the Simulator.** Diagnostic logging showed `isAvailable=false`, 0 supported locales and asset status `unsupported`. Instead of guessing, the agent wired in the Parakeet fallback the plan already named, which also covers older iPhones.
- **A false alarm, correctly diagnosed.** The simulator recording came out pure silence. Rather than "fixing" the recorder, the agent checked the WAV (correct 16 kHz Int16 format, RMS 0) and the Mac's audio setup: the default input was Bluetooth AirPods, so no microphone was hearing the test playback. Not an app bug.
- **UI issues caught from screenshots:** the setup progress bars had uneven widths, a caption was truncated, the decision bullets were misaligned, there was no feedback during LLM prefill, and recordings got an over-long default title.
- **Self-testing without UI automation.** To test the whole app, the agent synthesized a two-voice meeting with macOS `say`, added `#if DEBUG` launch-argument hooks (`-autoSetup`, `-autoImport`, `-autoRecord`, `-tab`), drove the simulator from the CLI and verified the saved JSON against the script.
- **"Why does it hear *kid* instead of *feed*?"** Rather than swap models on a hunch, the agent ran the user's own recordings through Apple en-US, en-IN and en-GB and Parakeet on the Mac. All three Apple locales made the same content errors (so it wasn't the accent setting, and en-IN was worse), and the audio measured only ~10 dB above the background noise. Parakeet got the content words right, so it became the final-pass transcriber and Apple stayed for the live preview. That switch exposed the opposite timestamp quirk: Parakeet stretches the *last* word before a pause forward. The Apple-specific correction moved out of the shared merge into Apple's transcriber, with one test covering both engines.
- **Real-device testing changed the architecture, twice.** Benchmarks pointed to pyannote+VBx, which scored perfectly on synthetic voices. The first real in-person recording came back as *one* speaker. A Mac CLI swept thresholds (no effect) and the other diarizers in the same library. LS-EEND fixed that file, and the app switched. Then my next recordings, a podcast and videos played through a speaker, failed with LS-EEND. Re-running the full matrix showed **no single model wins every case**: pyannote fails only by merging similar in-person voices, and Sortformer separates exactly those. The shipped design is pyannote first, Sortformer as a second opinion when pyannote hears one speaker. It's correct on all six test recordings and kept 91/91 over 10 minutes. Lessons: a benchmark choice is a hypothesis until it meets real audio, and a regression suite of real files has to grow every time a user finds a failure.
- **Apple's word timestamps after pauses.** Device data showed the first word of each turn landing with the previous speaker. The agent compared raw word times against the known turn boundaries of the synthetic file, found that Apple stretches post-pause words back over the silence, fixed it in the shared merge function, and added the real case as a test.
- **Memory measured, then fixed.** Logging the physical footprint showed 2.5 GB with the LLM loaded, even for a 1-minute meeting: the fixed 8k context allocated the KV cache and compute buffers up front. Sizing the context to the transcript cut short meetings to 0.6 GB. Trying the increased-memory entitlement failed on a free team, so it was reverted and documented.
- **Prompt iterations with evidence.** A one-shot example meant to fix action-item ownership made the 1.7B model *copy the example* into its output ("Send the deck"), so it was reverted the same cycle. Allowing "- None" for action items stopped the model inventing tasks for a casual chat.
- **Scope steering from me.** Mid-plan I redirected the agent: use Granola as the product reference, use iOS on-device speech-to-text and TTS, and keep the plan simple. The plan shrank from a five-stage design to three libraries and ~12 files.

## Prompting approach

- Gave the agent the full brief and the judging criteria, then asked for research *with citations* before any plan.
- Fixed hard constraints early (Xcode version, test device RAM, model delivery) with explicit questions instead of letting the agent guess.
- Asked for "the laziest stack that is actually good" (the ponytail skill): reuse library loaders, no custom ML code, one test per non-trivial function.
- Made the agent compile or run everything it could locally (merge and parser assertions, Speech framework type-check against the macOS 26 SDK, and the ML glue against the real packages) before touching a device.
