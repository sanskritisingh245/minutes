import SwiftUI

/// Granola-style capture: a blank notepad for your own thoughts while Minutes listens and transcribes live.
struct RecordView: View {
    let onFinish: (UUID) -> Void
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = Recorder()
    @State private var meeting = Meeting(title: "Meeting \(Date.now.formatted(date: .omitted, time: .shortened))") // replaced by the LLM's title
    @State private var notes = ""
    @State private var showTranscript = true
    @State private var stopping = false
    @State private var error: String?
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Jot down anything — Minutes will weave your notes into the summary.")
                        .foregroundStyle(Color.inkSecondary.opacity(0.7))
                        .padding(.horizontal, 21).padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notes)
                    .focused($editing)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
            }
            .font(.body)
            .foregroundStyle(Color.ink)
            liveTranscript
            stopButton
        }
        .background(Color.canvas.ignoresSafeArea())
        .task { await start() }
        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.startDate)
        .alert("Can't record", isPresented: .constant(error != nil)) {
            Button("OK") { dismiss() }
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Discard", role: .destructive) { discard() }
                    .font(.body).foregroundStyle(Color.inkSecondary)
                Spacer()
                HStack(spacing: 8) {
                    PulsingDot(color: .record)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text((recorder.startDate.map { ctx.date.timeIntervalSince($0) } ?? 0).clock)
                            .font(.headline.monospacedDigit()).foregroundStyle(Color.ink)
                    }
                }
                Spacer()
                Button("Done") { editing = false }
                    .font(.body.weight(.semibold))
                    .opacity(editing ? 1 : 0)
            }
            Waveform(levels: recorder.levels).frame(height: 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.ui) { showTranscript.toggle() }
            } label: {
                HStack {
                    Text("Live transcript").sectionLabel()
                    Spacer()
                    Image(systemName: "chevron.up").rotationEffect(.degrees(showTranscript ? 0 : 180))
                        .font(.footnote.weight(.semibold)).foregroundStyle(Color.inkSecondary)
                }
            }
            if showTranscript {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text("\(recorder.transcriber?.finalText ?? "")\(Text(recorder.transcriber?.volatileText ?? "").foregroundStyle(Color.inkSecondary))")
                            .font(.subheadline)
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 110)
                    .onChange(of: recorder.transcriber?.volatileText) { proxy.scrollTo("end") }
                    .overlay {
                        if (recorder.transcriber?.finalText ?? "").isEmpty && (recorder.transcriber?.volatileText ?? "").isEmpty {
                            Text(Transcriber.isAvailable ? "Listening…" : "Transcript will be ready right after you stop.")
                                .font(.subheadline).foregroundStyle(Color.inkSecondary)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(16)
        .background(Color.surface2)
        .overlay(alignment: .top) { Divider().overlay(Color.hairline) }
    }

    private var stopButton: some View {
        Button { Task { await stop() } } label: {
            ZStack {
                Circle().fill(Color.record).frame(width: 72, height: 72)
                if stopping { ProgressView().tint(.white) } else {
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 24, height: 24)
                }
            }
        }
        .buttonStyle(PressStyle())
        .disabled(stopping || recorder.startDate == nil)
        .accessibilityLabel("Stop recording")
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color.surface2)
    }

    private func start() async {
        do {
            try await recorder.start(writingTo: Store.audioURL(meeting))
            #if DEBUG
            let seconds = UserDefaults.standard.double(forKey: "autoRecord") // CLI test hook: auto-stop
            if seconds > 0 {
                notes = "Offline mode is the key differentiator"
                try await Task.sleep(for: .seconds(seconds))
                await stop()
            }
            #endif
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() async {
        stopping = true
        do {
            let (words, duration) = try await recorder.stop()
            meeting.words = words
            meeting.duration = duration
            meeting.userNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            store.insert(meeting)
            store.process(meeting.id)
            dismiss()
            onFinish(meeting.id)
        } catch {
            stopping = false
            self.error = error.localizedDescription
        }
    }

    private func discard() {
        Task {
            _ = try? await recorder.stop()
            try? FileManager.default.removeItem(at: Store.folder(meeting.id))
            dismiss()
        }
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        Canvas { ctx, size in
            let step = size.width / CGFloat(levels.count)
            for (i, level) in levels.enumerated() {
                let h = max(3, CGFloat(level) * size.height)
                let rect = CGRect(x: CGFloat(i) * step + step * 0.25, y: (size.height - h) / 2, width: step * 0.5, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: step * 0.25), with: .color(.record.opacity(0.35 + Double(level) * 0.65)))
            }
        }
        .accessibilityHidden(true)
    }
}
