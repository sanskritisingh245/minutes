import FluidAudio
import Foundation

/// Fallback ASR where Apple's SpeechTranscriber is unsupported (the Simulator, older iPhones):
/// NVIDIA Parakeet TDT 0.6B v2 (English, CoreML via FluidAudio, ~450 MB). Batch only, so no live preview.
enum Parakeet {
    static func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await AsrModels.downloadAndLoad(version: .v2, progressHandler: { progress($0.fractionCompleted) })
        progress(1)
    }

    static func transcribe(_ url: URL) async throws -> [Word] {
        let asr = AsrManager(config: .default)
        try await asr.loadModels(try await AsrModels.loadFromCache(version: .v2))
        var state = TdtDecoderState.make(decoderLayers: 2) // v2 decoder depth
        let result = try await asr.transcribe(url, decoderState: &state)
        await asr.cleanup()
        return buildWordTimings(from: result.tokenTimings ?? []).compactMap {
            let text = $0.word.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : Word(text: text, start: $0.startTime, end: $0.endTime)
        }
    }
}
