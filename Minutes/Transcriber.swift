import AVFoundation
import Speech

/// iOS 26 on-device speech-to-text (SpeechAnalyzer) with word timestamps.
/// One instance per recording or imported file. Not Apple Intelligence: the model is an OS-managed asset.
@MainActor @Observable
final class Transcriber {
    private(set) var finalText = ""
    private(set) var volatileText = ""
    private(set) var words: [Word] = []

    let format: AVAudioFormat
    private let module: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<Void, Error>?

    nonisolated static let locale = Locale(identifier: "en-US")

    /// False in the Simulator and on unsupported iPhones; the app then falls back to `Parakeet`.
    nonisolated static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    nonisolated static func makeModule() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
    }

    /// Reserves the locale for this app (required before use) and installs the English model once.
    nonisolated static func installAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            try await AssetInventory.reserve(locale: locale)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule()]) {
            let observation = request.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            try await request.downloadAndInstall()
            observation.invalidate()
        }
        progress(1)
    }

    init() async throws {
        module = Self.makeModule()
        analyzer = SpeechAnalyzer(modules: [module])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw CocoaError(.featureUnsupported)
        }
        self.format = format
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        results = Task { [module] in
            for try await result in module.results { self.handle(result) }
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Apple stretches the first word after a pause back over the silence ("Great." 36.78–38.04 s, spoken at
    /// ~37.8 s), which would hand it to the previous speaker; keep only its last 0.6 s. (Parakeet stretches the
    /// other way — the last word before a pause — which plain overlap in `Merge` already handles.)
    nonisolated static func trimmed(_ w: Word) -> Word {
        Word(text: w.text, start: max(w.start, w.end - 0.6), end: w.end)
    }

    /// Thread-safe: called from the audio tap. `buffer` must already be in `format`.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func finish() async throws -> [Word] {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await results?.value
        return words
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        guard result.isFinal else {
            volatileText = String(result.text.characters)
            return
        }
        finalText += String(result.text.characters)
        volatileText = ""
        // Runs split on the audioTimeRange attribute: one per word (or sub-word / punctuation, glued back below).
        for (k, run) in result.text.runs.enumerated() {
            let raw = String(result.text[run.range].characters)
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let continuesWord = k > 0 && !(raw.first?.isWhitespace ?? true)
            if let range = run.audioTimeRange, !continuesWord || words.isEmpty {
                words.append(Self.trimmed(Word(text: text, start: range.start.seconds, end: range.end.seconds)))
            } else if !words.isEmpty {
                words[words.count - 1].text += text
                if let range = run.audioTimeRange { words[words.count - 1].end = range.end.seconds }
            }
        }
    }
}

/// Stateful sample-rate/format converter for streamed buffers.
final class Converter {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?

    init(to format: AVAudioFormat) { self.format = format }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none // no timestamp drift
        }
        guard let converter,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity:
                AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 1)
        else { throw CocoaError(.featureUnsupported) }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return out
    }
}
