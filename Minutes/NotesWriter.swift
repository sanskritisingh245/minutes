import Foundation
import LLM

/// Qwen3-1.7B (Q4_K_M GGUF, Apache-2.0) via llama.cpp/Metal. Granola-style: enhances the user's own notes with the transcript.
enum NotesWriter {
    static let remoteURL = URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!
    static let modelFile = URL.applicationSupportDirectory.appending(path: "Models/Qwen3-1.7B-Q4_K_M.gguf")

    static let system = """
    You are an expert meeting note-taker. Using ONLY facts from the transcript (and the user's own notes, \
    which show what they care about), reply in Markdown with exactly this structure and nothing else:
    # <title, max 6 words>
    ## Summary
    <3-5 sentence summary>
    ## Key Decisions
    - <one decision per line, or "- None">
    ## Action Items
    - [<owner: a speaker name, or Unassigned>] <task>   (or "- None" if nobody committed to doing anything)
    Be concise and specific. List each action item once. Its owner is the speaker who said they \
    would do it ("I'll ..."), not the speaker who asked for it. Decisions are agreements, not tasks. \
    Never invent names, numbers or dates.
    """

    struct Output { var title: String?; var notes: Notes }

    static func write(_ m: Meeting, onText: @escaping @MainActor (String) -> Void) async throws -> Output {
        var prompt = ""
        if !m.userNotes.isEmpty { prompt += "My notes:\n\(m.userNotes)\n\n" }
        prompt += "Transcript:\n\(fit(m.transcriptText))\n\nWrite the meeting notes. /no_think"

        // KV cache + compute buffers scale with context, so size it to this prompt (~3 chars/token worst case)
        // + system prompt + answer, in 1k steps. Full 8k context peaked at 2.5 GB on a 6 GB iPhone 15.
        let context = Int32(min(8192, max(2048, (prompt.count / 3 + 1200 + 1023) / 1024 * 1024)))
        // Model load is synchronous and ~1 s; keep it off the main thread. Weights are mmapped, freed when `bot` goes away.
        let bot = await Task.detached {
            LLM(from: modelFile, topK: 20, topP: 0.8, temp: 0.2, repeatPenalty: 1.05, maxTokenCount: context)
        }.value
        guard let bot else { throw CocoaError(.fileReadCorruptFile) }
        bot.systemPrompt = system

        let streamed = StreamBuffer()
        bot.update = { [weak bot] delta in // weak: a strong capture would leak the model + KV cache (~2 GB)
            guard let delta else { return }
            let text = streamed.append(delta)
            if text.count > 6000 { bot?.stop() } // runaway guard; real notes are < 3000 chars
            Task { @MainActor in onText(text) }
        }

        await bot.respond(to: prompt, thinking: .suppressed)
        print("[Minutes] memory with LLM loaded: \(footprintMB()) MB (context \(context))")
        return parse(bot.output)
    }

    /// Physical footprint — the number iOS uses for jetsam limits and Xcode's memory gauge shows.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// ponytail: char-based budget (≤ ~7k tokens even at 3 chars/token) fits the 8k context with room for the answer;
    /// keeps the start and end of very long (>35 min) meetings. Map-reduce over chunks if that ever matters.
    static func fit(_ transcript: String, limit: Int = 20_000) -> String {
        guard transcript.count > limit else { return transcript }
        return transcript.prefix(limit * 2 / 3) + "\n[…]\n" + transcript.suffix(limit / 3)
    }

    static func parse(_ raw: String) -> Output {
        let text = raw.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
        var out = Output(title: nil, notes: Notes())
        var section = ""
        var summary: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") || (l.hasPrefix("**") && l.hasSuffix("**")) {
                let heading = l.trimmingCharacters(in: CharacterSet(charactersIn: "#*: ")).lowercased()
                if heading.contains("summary") { section = "summary" }
                else if heading.contains("decision") { section = "decisions" }
                else if heading.contains("action") { section = "actions" }
                else if out.title == nil, l.hasPrefix("# ") { out.title = l.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                continue
            }
            let item = l.replacingOccurrences(of: "^([-*•]|\\d+[.)])\\s+", with: "", options: .regularExpression)
            if item.isEmpty || ["none", "none.", "n/a"].contains(item.lowercased()) { continue }
            switch section {
            case "summary": summary.append(item)
            case "decisions": out.notes.decisions.append(item)
            case "actions":
                if let match = item.firstMatch(of: #/^\[(.*?)\]\s*(.+)$/#) {
                    let owner = match.1.trimmingCharacters(in: .whitespaces)
                    let unassigned = owner.isEmpty || ["x", "unassigned"].contains(owner.lowercased())
                    out.notes.actions.append(ActionItem(text: String(match.2), owner: unassigned ? nil : owner))
                } else {
                    out.notes.actions.append(ActionItem(text: item))
                }
            default: break
            }
        }
        out.notes.summary = summary.joined(separator: " ")
        // Never lose output: if the model ignored the format, keep its text as the summary.
        if out.notes.summary.isEmpty && out.notes.decisions.isEmpty && out.notes.actions.isEmpty {
            out.notes.summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}

/// Accumulates streamed deltas from llama.cpp's generation thread.
private final class StreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ delta: String) -> String { lock.withLock { text += delta; return text } }
}
