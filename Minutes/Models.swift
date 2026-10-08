import Foundation

struct Word: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

struct Turn: Codable, Hashable, Identifiable {
    var id = UUID()
    var speaker: Int // 0-based, ordered by first appearance
    var start: Double
    var end: Double
    var text: String
}

struct ActionItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var owner: String?
    var done = false
}

struct Notes: Codable, Hashable {
    var summary = ""
    var decisions: [String] = []
    var actions: [ActionItem] = []
}

enum Stage: String, Codable {
    case transcribing = "Transcribing"
    case diarizing = "Identifying speakers"
    case writing = "Writing notes"
    case done, failed
}

struct Meeting: Codable, Hashable, Identifiable {
    var id = UUID()
    var title = "New meeting"
    var date = Date()
    var duration: Double = 0
    var audioFile = "audio.wav" // inside the meeting folder
    var userNotes = ""
    var words: [Word] = []
    var turns: [Turn] = []
    var notes: Notes?
    var speakerNames: [Int: String] = [:]
    var stage: Stage = .transcribing
    var error: String?
    var timings: [String: Double] = [:] // stage → seconds, shown in UI and README

    var speakerCount: Int { (turns.map(\.speaker).max() ?? -1) + 1 }
    func speakerName(_ i: Int) -> String { speakerNames[i] ?? "Speaker \(i + 1)" }

    var transcriptText: String {
        turns.map { "\(speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n")
    }

    var markdown: String {
        var md = "# \(title)\n\n_\(date.formatted(date: .abbreviated, time: .shortened)) · \(duration.clock)_\n\n"
        if let notes {
            md += "## Summary\n\(notes.summary)\n\n## Key Decisions\n"
            md += notes.decisions.isEmpty ? "- None\n" : notes.decisions.map { "- \($0)\n" }.joined()
            md += "\n## Action Items\n"
            md += notes.actions.isEmpty ? "- None\n" : notes.actions.map { "- [\($0.done ? "x" : " ")] \($0.owner.map { "\($0): " } ?? "")\($0.text)\n" }.joined()
        }
        if !userNotes.isEmpty { md += "\n## My Notes\n\(userNotes)\n" }
        md += "\n## Transcript\n" + turns.map { "**\(speakerName($0.speaker))** (\($0.start.clock)): \($0.text)\n" }.joined(separator: "\n")
        return md
    }
}

extension Double {
    /// 75.4 → "1:15", 3725 → "1:02:05"
    var clock: String {
        let s = Int(self.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
