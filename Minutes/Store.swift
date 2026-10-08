import Foundation
import Observation

/// One folder per meeting in Application Support: meeting.json + the audio file.
@MainActor @Observable
final class Store {
    private(set) var meetings: [Meeting] = []
    /// Live LLM output while a meeting is in `.writing`.
    var streamingNotes: [UUID: String] = [:]

    static let root = URL.applicationSupportDirectory.appending(path: "Meetings", directoryHint: .isDirectory)

    init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        meetings = dirs.compactMap { try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: $0.appending(path: "meeting.json"))) }
            .sorted { $0.date > $1.date }
        // A pipeline killed mid-run (app quit) can't resume; mark it so the user can retry.
        for m in meetings where ![.done, .failed].contains(m.stage) {
            update(m.id) { $0.stage = .failed; $0.error = "Processing was interrupted." }
        }
    }

    static func folder(_ id: UUID) -> URL {
        let url = root.appending(path: id.uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func audioURL(_ m: Meeting) -> URL { folder(m.id).appending(path: m.audioFile) }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func insert(_ m: Meeting) {
        meetings.insert(m, at: 0)
        save(m)
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        save(meetings[i])
    }

    func delete(_ id: UUID) {
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder(id))
    }

    private func save(_ m: Meeting) {
        try? JSONEncoder().encode(m).write(to: Self.folder(m.id).appending(path: "meeting.json"), options: .atomic)
    }
}
