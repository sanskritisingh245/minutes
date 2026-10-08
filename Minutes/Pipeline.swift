import AVFoundation
import UIKit

/// Transcribe (if not done live) → diarize → merge → write notes. Each stage is timed and persisted,
/// so a failure in a later stage never loses the earlier ones.
extension Store {
    func process(_ id: UUID) {
        Task { await run(id) }
    }

    private func run(_ id: UUID) async {
        guard let m = meeting(id) else { return }
        let url = Self.audioURL(m)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        do {
            // Final transcript always comes from Parakeet: on real accented, noisy speech it got the content
            // words right where Apple's live model didn't ("feed" vs "kid"). Apple's live words are the fallback.
            try await stage(.transcribing, id) {
                do {
                    let words = try await Parakeet.transcribe(url)
                    self.update(id) { $0.words = words }
                } catch where !m.words.isEmpty {
                    print("[Minutes] Parakeet failed (\(error)); keeping the live transcript")
                }
            }
            try await stage(.diarizing, id) {
                let segments = try await Diarizer.segments(for: url)
                self.update(id) { $0.turns = Merge.turns(words: $0.words, segments: segments) }
            }
            guard let current = meeting(id), !current.turns.isEmpty else {
                update(id) { $0.stage = .failed; $0.error = "No speech was detected in this recording." }
                return
            }
            try await stage(.writing, id) {
                let out = try await NotesWriter.write(current) { self.streamingNotes[id] = $0 }
                self.update(id) {
                    $0.notes = out.notes
                    if let title = out.title, !title.isEmpty, $0.title.hasPrefix("Meeting ") { $0.title = title }
                }
            }
            streamingNotes[id] = nil
            update(id) { $0.stage = .done; $0.error = nil }
        } catch {
            streamingNotes[id] = nil
            update(id) { $0.stage = .failed; $0.error = error.localizedDescription }
        }
    }

    private func stage(_ s: Stage, _ id: UUID, _ work: () async throws -> Void) async throws {
        update(id) { $0.stage = s }
        let start = Date()
        try await work()
        let seconds = Date().timeIntervalSince(start)
        update(id) { $0.timings[s.rawValue] = seconds }
        print("[Minutes] \(s.rawValue): \(String(format: "%.2f", seconds)) s · \(NotesWriter.footprintMB()) MB")
    }

    /// Copies an imported file into the sandbox and starts processing.
    func importAudio(from source: URL) throws -> UUID {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        var m = Meeting(title: source.deletingPathExtension().lastPathComponent, audioFile: "audio.\(ext)")
        let dest = Self.audioURL(m)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            let file = try AVAudioFile(forReading: dest) // also rejects files iOS can't decode
            m.duration = Double(file.length) / file.processingFormat.sampleRate
        } catch {
            try? FileManager.default.removeItem(at: Self.folder(m.id))
            throw error
        }
        insert(m)
        process(m.id)
        return m.id
    }
}
