import FluidAudio
import Foundation
import SwiftUI

/// First-run setup: fetch the three on-device models once, then the app never touches the network.
@MainActor @Observable
final class ModelManager {
    enum Item: String, CaseIterable {
        case speech = "Speech recognition"
        case speakers = "Speaker detection"
        case notes = "Notes writer"

        var detail: String {
            switch self {
            case .speech: "Parakeet TDT 0.6B · 450 MB" + (Transcriber.isAvailable ? " + Apple live preview" : "")
            case .speakers: "pyannote + Sortformer · 274 MB"
            case .notes: "Qwen3 1.7B · 1.1 GB"
            }
        }
    }

    private(set) var progress: [Item: Double] = [:]
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var isReady = UserDefaults.standard.bool(forKey: "modelsReady.v5")
        && FileManager.default.fileExists(atPath: NotesWriter.modelFile.path)

    init() {
        if isReady { ModelHub.offlineMode = true }
    }

    func setUp() async {
        isWorking = true
        error = nil
        let report: (Item) -> @Sendable (Double) -> Void = { item in
            { p in Task { @MainActor in self.progress[item] = p } }
        }
        do {
            async let speech: Void = Self.prepareSpeech(progress: report(.speech))
            async let speakers: Void = Diarizer.prepare(progress: report(.speakers))
            async let notes: Void = Self.downloadLLM(progress: report(.notes))
            _ = try await (speech, speakers, notes)
            UserDefaults.standard.set(true, forKey: "modelsReady.v5")
            ModelHub.offlineMode = true
            withAnimation(.ui) { isReady = true }
        } catch {
            self.error = "Download failed: \(error.localizedDescription). Check your connection and try again."
        }
        isWorking = false
    }

    /// Parakeet for the final transcript; Apple's model too where supported, for the live preview.
    private static func prepareSpeech(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard Transcriber.isAvailable else { return try await Parakeet.prepare(progress: progress) }
        let parts = PartialProgress(2, progress)
        try await Transcriber.installAssets { parts.report(0, $0) }
        try await Parakeet.prepare { parts.report(1, $0) }
    }

    // ponytail: restarts from zero if interrupted; add resumeData handling if flaky networks become a problem.
    private static func downloadLLM(progress: @escaping @Sendable (Double) -> Void) async throws {
        var dest = NotesWriter.modelFile
        if FileManager.default.fileExists(atPath: dest.path) { return progress(1) }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let (tmp, response) = try await URLSession.shared.download(from: NotesWriter.remoteURL, delegate: ProgressDelegate(progress))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try FileManager.default.moveItem(at: tmp, to: dest)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dest.setResourceValues(values)
        progress(1)
    }
}

/// Async `download(from:delegate:)` doesn't deliver didWriteData to task delegates; observe the task's Progress instead.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.progress.observe(\.fractionCompleted) { [onProgress] p, _ in onProgress(p.fractionCompleted) }
    }
}
