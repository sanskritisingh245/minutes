import SwiftUI

struct SetupView: View {
    @Environment(ModelManager.self) private var models

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.accent)
            VStack(alignment: .leading, spacing: 8) {
                Text("Minutes").font(.largeTitle.weight(.bold)).tracking(-0.5).foregroundStyle(Color.ink)
                Text("Private meeting notes, made entirely on your iPhone. A one-time download sets up three on-device models — after that, Minutes works in Airplane Mode.")
                    .font(.body).foregroundStyle(Color.inkSecondary)
            }

            VStack(spacing: 0) {
                ForEach(ModelManager.Item.allCases, id: \.self) { item in
                    row(item)
                    if item != ModelManager.Item.allCases.last { Divider().overlay(Color.hairline).padding(.leading, 16) }
                }
            }
            .background(Color.surface, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.hairline))

            if let error = models.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Color.record)
            }
            Spacer()
            VStack(spacing: 12) {
                PrimaryButton(title: models.isWorking ? "Setting up…" : models.error == nil ? "Download models · 1.8 GB" : "Try again",
                              systemImage: models.isWorking ? nil : "arrow.down.circle") {
                    Task { await models.setUp() }
                }
                .disabled(models.isWorking)
                Text(models.isWorking ? "Keep Minutes open until this finishes." : "Wi-Fi recommended. Nothing you record ever leaves this device.")
                    .font(.footnote).foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .background(Color.canvas.ignoresSafeArea())
        .animation(.ui, value: models.isWorking)
        #if DEBUG
        // CLI test hook: `-autoSetup YES` taps Download (used to drive the simulator without UI automation).
        .task { if UserDefaults.standard.bool(forKey: "autoSetup") { await models.setUp() } }
        #endif
    }

    private func row(_ item: ModelManager.Item) -> some View {
        let p = models.progress[item]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.rawValue).font(.headline).foregroundStyle(Color.ink)
                Text(item.detail).font(.footnote).foregroundStyle(Color.inkSecondary)
                if let p, p < 1 {
                    ProgressView(value: p).tint(.accent).padding(.top, 4)
                }
            }
            Spacer()
            if p == 1 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accent).transition(.scale.combined(with: .opacity))
            } else if let p {
                Text(p, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Color.inkSecondary)
                    .frame(minWidth: 44, alignment: .trailing) // keeps progress bars equal width
            }
        }
        .padding(16)
        .animation(.ui, value: p)
    }
}
