import SwiftUI

struct MeetingView: View {
    let id: UUID
    @Environment(Store.self) private var store
    @State private var tab = Tab.notes
    @State private var player = Player()
    @State private var narrator = Narrator()
    @State private var renaming: Int?
    @State private var newName = ""

    enum Tab: String, CaseIterable { case notes = "Notes", transcript = "Transcript" }

    var body: some View {
        if let m = store.meeting(id) {
            content(m)
        } else {
            ContentUnavailableView("Meeting deleted", systemImage: "trash")
        }
    }

    private func content(_ m: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(m)
                if m.stage != .done { StageStepper(meeting: m) { store.process(id) } }
                Picker("View", selection: $tab.animation(.ui)) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .notes: notes(m)
                case .transcript: transcript(m)
                }
            }
            .padding(16)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let notes = m.notes {
                Button { narrator.toggle(speech(m.title, notes)) } label: {
                    Image(systemName: narrator.isSpeaking ? "stop.circle" : "speaker.wave.2")
                }
                .accessibilityLabel(narrator.isSpeaking ? "Stop reading" : "Read notes aloud")
            }
            ShareLink(item: m.markdown, subject: Text(m.title)) { Image(systemName: "square.and.arrow.up") }
        }
        .safeAreaInset(edge: .bottom) { if tab == .transcript && !m.turns.isEmpty { playerBar(m) } }
        .alert("Rename speaker", isPresented: .constant(renaming != nil)) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let i = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.update(id) { $0.speakerNames[i] = newName.trimmingCharacters(in: .whitespaces) }
                }
                renaming = nil
            }
        }
        .onDisappear { player.pause() }
        #if DEBUG
        .task { if UserDefaults.standard.string(forKey: "tab") == "transcript" { tab = .transcript } } // CLI test hook
        #endif
    }

    // MARK: Header

    private func header(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: Binding(get: { m.title }, set: { t in store.update(id) { $0.title = t } }), axis: .vertical)
                .font(.largeTitle.weight(.bold)).tracking(-0.5)
                .foregroundStyle(Color.ink)
            HStack(spacing: 6) {
                Text(m.date.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(m.duration.clock).monospacedDigit()
                if m.speakerCount > 0 {
                    Text("·")
                    Text("\(m.speakerCount) speaker\(m.speakerCount == 1 ? "" : "s")")
                }
            }
            .font(.subheadline).foregroundStyle(Color.inkSecondary)
        }
    }

    // MARK: Notes

    @ViewBuilder
    private func notes(_ m: Meeting) -> some View {
        if let notes = m.notes {
            VStack(alignment: .leading, spacing: 28) {
                section("Summary") {
                    Text(notes.summary).font(.body).foregroundStyle(Color.ink).lineSpacing(4)
                }
                section("Key decisions") {
                    if notes.decisions.isEmpty { muted("No decisions recorded.") }
                    ForEach(notes.decisions, id: \.self) { d in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•").fontWeight(.heavy).foregroundStyle(Color.accent)
                            Text(d).foregroundStyle(Color.ink)
                        }
                    }
                }
                section("Action items") {
                    if notes.actions.isEmpty { muted("No action items.") }
                    ForEach(notes.actions) { item in actionRow(item) }
                }
                if !m.userNotes.isEmpty {
                    section("Your notes") {
                        Text(m.userNotes).foregroundStyle(Color.inkSecondary)
                    }
                }
                footer(m)
            }
        } else if let partial = store.streamingNotes[id] {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) { PulsingDot(); Text("Writing on-device…").sectionLabel() }
                Text(partial.replacingOccurrences(of: "<think>\\s*</think>", with: "", options: .regularExpression))
                    .font(.callout).foregroundStyle(Color.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
        } else if m.stage == .writing {
            // Prompt prefill: the model is reading the transcript before its first token.
            HStack(spacing: 6) { PulsingDot(); Text("Reading the transcript…").sectionLabel() }
        } else if m.stage != .failed {
            muted("Notes appear here once the transcript and speakers are ready.")
        }
    }

    private func actionRow(_ item: ActionItem) -> some View {
        Button {
            store.update(id) { m in
                if let i = m.notes?.actions.firstIndex(where: { $0.id == item.id }) { m.notes?.actions[i].done.toggle() }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Color.accent : Color.inkSecondary)
                    .font(.title3)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).strikethrough(item.done).foregroundStyle(item.done ? Color.inkSecondary : Color.ink)
                    if let owner = item.owner { Text(owner).font(.footnote.weight(.medium)).foregroundStyle(Color.inkSecondary) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.success, trigger: item.done) { _, done in done }
        .accessibilityLabel("\(item.text), \(item.done ? "done" : "not done")")
    }

    private func footer(_ m: Meeting) -> some View {
        let t = m.timings
        let parts = [Stage.diarizing, .writing].compactMap { s in t[s.rawValue].map { "\(s.rawValue) \(String(format: "%.1f", $0)) s" } }
        return VStack(alignment: .leading, spacing: 6) {
            Label("Made on this iPhone · " + parts.joined(separator: " · "), systemImage: "lock.fill")
            if !Narrator.hasNaturalVoice {
                Label("For a more natural read-aloud voice, download a Premium voice (e.g. Ava) in Settings › Accessibility › Spoken Content › Voices › English.", systemImage: "speaker.wave.2")
            }
        }
        .font(.caption).foregroundStyle(Color.inkSecondary)
    }

    // MARK: Transcript

    @ViewBuilder
    private func transcript(_ m: Meeting) -> some View {
        if m.turns.isEmpty {
            if m.words.isEmpty { muted("The transcript appears here shortly.") }
            else { Text(m.words.map(\.text).joined(separator: " ")).foregroundStyle(Color.ink) }
        } else {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(m.turns) { turn in
                    let playing = player.isPlaying && (turn.start...max(turn.start, turn.end)).contains(player.currentTime)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button { newName = m.speakerName(turn.speaker); renaming = turn.speaker } label: {
                                SpeakerChip(name: m.speakerName(turn.speaker), index: turn.speaker)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Rename speaker")
                            Text(turn.start.clock).font(.footnote.monospacedDigit()).foregroundStyle(Color.inkSecondary)
                        }
                        Text(turn.text).font(.body).foregroundStyle(Color.ink).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(playing ? Color.surface2 : .clear, in: .rect(cornerRadius: 12))
                    .contentShape(.rect)
                    .onTapGesture { player.play(Store.audioURL(m), from: turn.start) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .animation(.ui, value: playing)
                }
            }
            .padding(.horizontal, -12)
        }
    }

    private func playerBar(_ m: Meeting) -> some View {
        HStack(spacing: 16) {
            Button {
                player.isPlaying ? player.pause() : player.play(Store.audioURL(m))
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3).frame(width: 44, height: 44)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            ProgressView(value: min(player.currentTime, max(player.duration, 0.01)), total: max(player.duration, 0.01))
                .tint(.accent)
            Text(player.currentTime.clock).font(.footnote.monospacedDigit()).foregroundStyle(Color.inkSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).sectionLabel()
            content()
        }
    }

    private func muted(_ s: String) -> some View {
        Text(s).font(.subheadline).foregroundStyle(Color.inkSecondary)
    }

    /// One utterance per section/item so the voice pauses naturally between them.
    private func speech(_ title: String, _ n: Notes) -> [String] {
        func sentence(_ t: String) -> String { t.last.map { ".!?".contains($0) } == true ? t : t + "." }
        var parts = [sentence(title), "Summary.", n.summary]
        if !n.decisions.isEmpty { parts += ["Key decisions."] + n.decisions.map(sentence) }
        if !n.actions.isEmpty { parts += ["Action items."] + n.actions.map { sentence(($0.owner.map { "\($0): " } ?? "") + $0.text) } }
        return parts
    }
}

/// Transcribing → Identifying speakers → Writing notes, with elapsed time per finished stage.
private struct StageStepper: View {
    let meeting: Meeting
    let retry: () -> Void
    private let stages: [Stage] = [.transcribing, .diarizing, .writing]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(stages, id: \.self) { s in
                HStack(spacing: 12) {
                    icon(for: s).frame(width: 20)
                    Text(s.rawValue).font(.subheadline.weight(isCurrent(s) ? .semibold : .regular))
                        .foregroundStyle(isCurrent(s) || isDone(s) ? Color.ink : Color.inkSecondary)
                    Spacer()
                    if let t = meeting.timings[s.rawValue] {
                        Text(t == 0 ? "live" : String(format: "%.1f s", t))
                            .font(.footnote.monospacedDigit()).foregroundStyle(Color.inkSecondary)
                    }
                }
            }
            if meeting.stage == .failed {
                Divider().overlay(Color.hairline)
                Text(meeting.error ?? "Something went wrong.").font(.footnote).foregroundStyle(Color.record)
                Button("Try again", action: retry).font(.subheadline.weight(.semibold))
            }
        }
        .padding(16)
        .background(Color.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.hairline))
        .animation(.ui, value: meeting.stage)
    }

    private func isDone(_ s: Stage) -> Bool { meeting.timings[s.rawValue] != nil }
    private func isCurrent(_ s: Stage) -> Bool { meeting.stage == s }

    @ViewBuilder
    private func icon(for s: Stage) -> some View {
        if isDone(s) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accent)
        } else if isCurrent(s) {
            PulsingDot()
        } else if meeting.stage == .failed {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.record)
        } else {
            Image(systemName: "circle").foregroundStyle(Color.hairline)
        }
    }
}
