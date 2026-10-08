import SwiftUI

struct HomeView: View {
    @Environment(Store.self) private var store
    @State private var path: [UUID] = []
    @State private var recording = false
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.meetings.isEmpty {
                    empty
                } else {
                    List {
                        ForEach(store.meetings) { m in
                            NavigationLink(value: m.id) { MeetingRow(meeting: m) }
                                .listRowBackground(Color.canvas)
                                .listRowSeparatorTint(Color.hairline)
                        }
                        .onDelete { $0.map { store.meetings[$0].id }.forEach(store.delete) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle("Minutes")
            .navigationDestination(for: UUID.self) { MeetingView(id: $0) }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .fullScreenCover(isPresented: $recording) {
            RecordView { id in path = [id] }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio]) { result in
            do { path = [try store.importAudio(from: result.get())] } catch { importError = error.localizedDescription }
        }
        #if DEBUG
        // CLI test hook: `-autoImport <path>` imports a file and opens it, as the Import button would.
        .task {
            if UserDefaults.standard.double(forKey: "autoRecord") > 0 { recording = true } // `-autoRecord <seconds>`
            if let p = UserDefaults.standard.string(forKey: "autoImport") {
                let url = p.hasPrefix("/") ? URL(filePath: p) : URL.documentsDirectory.appending(path: p) // relative = Documents/
                do { path = [try store.importAudio(from: url)] } catch { importError = error.localizedDescription }
            }
        }
        #endif
        .alert("Couldn't import audio", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(Color.inkSecondary)
            Text("No meetings yet").font(.title3.weight(.semibold)).foregroundStyle(Color.ink)
            Text("Record a conversation or import audio. Transcripts, speakers and notes are made on this iPhone.")
                .font(.subheadline).foregroundStyle(Color.inkSecondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { importing = true } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.title3.weight(.medium))
                    .frame(width: 56, height: 56)
                    .background(Color.surface, in: .circle)
                    .overlay(Circle().stroke(Color.hairline))
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Import audio")

            PrimaryButton(title: "Record", systemImage: "mic.fill", tint: .record) { recording = true }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(.regularMaterial)
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title).font(.headline).foregroundStyle(Color.ink).lineLimit(1)
            Text("\(meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(meeting.duration.clock)")
                .font(.subheadline.monospacedDigit()).foregroundStyle(Color.inkSecondary)
            switch meeting.stage {
            case .done:
                if let summary = meeting.notes?.summary {
                    Text(summary).font(.subheadline).foregroundStyle(Color.inkSecondary).lineLimit(2)
                }
            case .failed:
                Label("Needs attention", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color.record)
            default:
                HStack(spacing: 6) {
                    PulsingDot()
                    Text(meeting.stage.rawValue + "…").font(.footnote).foregroundStyle(Color.accent)
                }
            }
        }
        .padding(.vertical, 6)
    }
}

/// Soft "working" indicator — used instead of a bare spinner.
struct PulsingDot: View {
    var color: Color = .accent
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .opacity(on ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true }
            }
    }
}
