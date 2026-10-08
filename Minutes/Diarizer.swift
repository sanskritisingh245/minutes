import FluidAudio
import Foundation

/// Two on-device diarizers from FluidAudio, chosen by testing every option on real recordings:
/// - pyannote community-1 + VBx (~22 MB): globally consistent IDs (91/91 turns over 10 min), handles podcasts
///   and videos — but merged two similar in-person voices into one speaker.
/// - NVIDIA Sortformer v2.1 high-context (~252 MB): separates those in-person voices.
/// So: pyannote first; if it hears only one speaker, ask Sortformer. A true monologue stays one speaker in both.
enum Diarizer {
    static let sortformer = SortformerConfig.highContextV2_1

    static func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let parts = PartialProgress(2, progress)
        _ = try await OfflineDiarizerModels.load(progressHandler: { parts.report(0, $0.fractionCompleted) })
        _ = try await SortformerModels.loadFromHuggingFace(config: sortformer, progressHandler: { parts.report(1, $0.fractionCompleted) })
        progress(1)
    }

    static func segments(for url: URL) async throws -> [Merge.Segment] {
        let primary = try await pyannote(url)
        if Set(primary.map(\.speaker)).count >= 2 { return primary }
        let second = try await sortformerSegments(url)
        print("[Minutes] pyannote heard 1 speaker; Sortformer heard \(Set(second.map(\.speaker)).count)")
        return second.isEmpty ? primary : second
    }

    private static func pyannote(_ url: URL) async throws -> [Merge.Segment] {
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: try await OfflineDiarizerModels.load())
        return try await manager.process(url).segments.map {
            Merge.Segment(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    private static func sortformerSegments(_ url: URL) async throws -> [Merge.Segment] {
        let diarizer = SortformerDiarizer(config: sortformer)
        diarizer.initialize(models: try await SortformerModels.loadFromHuggingFace(config: sortformer))
        let segments = try diarizer.processComplete(audioFileURL: url).speakers.values.flatMap(\.finalizedSegments)
        // Drop phantom speakers: Sortformer sometimes flickers an extra label for a few seconds (≈5 % of speech);
        // real participants in tests always held ≥ 16 %. Their words fall back to the nearest real speaker in Merge.
        var share: [Int: Float] = [:]
        for s in segments { share[s.speakerIndex, default: 0] += s.duration }
        let total = share.values.reduce(0, +)
        return segments.filter { share[$0.speakerIndex, default: 0] >= 0.1 * total }.map {
            Merge.Segment(speaker: "sf\($0.speakerIndex)", start: Double($0.startTime), end: Double($0.endTime))
        }
    }
}

/// Combines the progress of N sequential downloads into one 0…1 value.
final class PartialProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [Double]
    private let report: @Sendable (Double) -> Void
    init(_ n: Int, _ report: @escaping @Sendable (Double) -> Void) { parts = Array(repeating: 0, count: n); self.report = report }
    func report(_ i: Int, _ p: Double) {
        let total = lock.withLock { parts[i] = p; return parts.reduce(0, +) / Double(parts.count) }
        report(total)
    }
}
