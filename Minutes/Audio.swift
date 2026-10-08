import Accelerate
import AVFoundation

/// Mic → (convert once to the speech model's format) → live transcriber + WAV on disk + waveform levels.
@MainActor @Observable
final class Recorder {
    private(set) var levels = [Float](repeating: 0, count: 40)
    private(set) var startDate: Date?
    private(set) var transcriber: Transcriber?
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?

    func start(writingTo url: URL) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw NSError(domain: "Minutes", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Microphone access is off. Turn it on in Settings › Minutes."])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        // Live transcription when Apple's model is supported; otherwise just record and transcribe after Stop.
        let transcriber = Transcriber.isAvailable ? try await Transcriber() : nil
        let format = transcriber?.format
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        // Written incrementally, so an interruption or crash still leaves a playable file.
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let converter = Converter(to: format)
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let converted = try? converter.convert(buffer) else { return }
            try? file.write(from: converted)
            transcriber?.feed(converted)
            let level = Self.level(buffer)
            Task { @MainActor in self?.push(level) }
        }
        engine.prepare()
        try engine.start()
        self.transcriber = transcriber
        self.file = file
        startDate = .now
    }

    /// Returns the timestamped words (already transcribed live) and the duration.
    func stop() async throws -> (words: [Word], duration: Double) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file?.close()
        file = nil
        let duration = startDate.map { Date.now.timeIntervalSince($0) } ?? 0
        let words = try await transcriber?.finish() ?? []
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (words, duration)
    }

    private func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
    }

    /// RMS → 0…1 on a -50…0 dB scale.
    nonisolated private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        return max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
    }
}

@MainActor @Observable
final class Player {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(_ url: URL, from time: Double? = nil) {
        if player?.url != url {
            player = try? AVAudioPlayer(contentsOf: url)
            duration = player?.duration ?? 0
        }
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let time { player.currentTime = time }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        tick()
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            timer?.invalidate()
        }
    }
}

/// Reads the notes aloud, fully on-device, with the best English voice installed (Premium/Enhanced neural
/// voices sound far more natural than the default compact one). Cloud TTS (e.g. ElevenLabs) would break the
/// offline requirement; Kokoro via FluidAudio was ruled out — documented BNNS segfaults on iOS 26.4–26.5.
@MainActor @Observable
final class Narrator: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    private let synth = AVSpeechSynthesizer()
    private var last: AVSpeechUtterance?

    static let voice = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") }
        .max { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0) < ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0) }
    static var hasNaturalVoice: Bool { (voice?.quality ?? .default) != .default }

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speaks each section as its own utterance so there's a natural pause between them.
    func toggle(_ sections: [String]) {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        for text in sections where !text.isEmpty {
            let u = AVSpeechUtterance(string: text)
            u.voice = Self.voice
            u.postUtteranceDelay = 0.35
            synth.speak(u)
            last = u
        }
        isSpeaking = true
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if u === self.last { self.isSpeaking = false } }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
