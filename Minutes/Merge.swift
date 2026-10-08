import Foundation

/// Assigns diarization speakers to ASR words and folds them into readable turns.
/// Port of whisperX `assign_word_speakers` plus island smoothing.
enum Merge {
    struct Segment { let speaker: String; let start: Double; let end: Double }

    static func turns(words: [Word], segments: [Segment], paragraphGap: Double = 2.0) -> [Turn] {
        guard !words.isEmpty else { return [] }
        guard !segments.isEmpty else {
            return [Turn(speaker: 0, start: words[0].start, end: words.last!.end, text: join(words))]
        }

        // 1. Max temporal overlap, else nearest segment by gap distance.
        // ponytail: O(words × segments) scan — fine for ≤ 1 h meetings; binary search if it ever shows in profiles.
        let labels: [String] = words.map { w in
            var best: (id: String, score: Double)?
            for s in segments {
                let overlap = min(w.end, s.end) - max(w.start, s.start)
                let score = overlap > 0 ? overlap : -max(s.start - w.end, w.start - s.end)
                if best == nil || score > best!.score { best = (s.speaker, score) }
            }
            return best!.id
        }

        // 2. Runs of same-label words; absorb ≤2-word islands sandwiched by one speaker.
        var runs: [(label: String, words: [Word])] = []
        for (w, l) in zip(words, labels) {
            if runs.last?.label == l { runs[runs.count - 1].words.append(w) } else { runs.append((l, [w])) }
        }
        var i = 1
        while i < runs.count - 1 {
            if runs[i].words.count <= 2, runs[i - 1].label == runs[i + 1].label {
                runs[i - 1].words += runs[i].words + runs[i + 1].words
                runs.removeSubrange(i...i + 1)
            } else { i += 1 }
        }

        // 3. Speaker index by first appearance; split long monologues at pauses.
        var index: [String: Int] = [:]
        var turns: [Turn] = []
        for run in runs {
            if index[run.label] == nil { index[run.label] = index.count }
            let speaker = index[run.label]!
            var chunk: [Word] = []
            for w in run.words {
                if let last = chunk.last, w.start - last.end > paragraphGap {
                    turns.append(Turn(speaker: speaker, start: chunk[0].start, end: last.end, text: join(chunk)))
                    chunk = []
                }
                chunk.append(w)
            }
            turns.append(Turn(speaker: speaker, start: chunk[0].start, end: chunk.last!.end, text: join(chunk)))
        }
        return turns
    }

    private static func join(_ words: [Word]) -> String {
        words.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
