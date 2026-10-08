import SwiftUI

// Warm paper + ink, one teal accent, record is the only red. Dark mode is charcoal, never #000.
extension Color {
    static let canvas = Color(light: 0xFBFAF6, dark: 0x1C1E22)
    static let surface = Color(light: 0xFFFFFF, dark: 0x262930)
    static let surface2 = Color(light: 0xF3F1EB, dark: 0x2F333B)
    static let hairline = Color(light: 0xE7E4DC, dark: 0x363A42)
    static let ink = Color(light: 0x1F2126, dark: 0xECEDEF)
    static let inkSecondary = Color(light: 0x6E727A, dark: 0x9DA3AD)
    static let accent = Color(light: 0x0F766E, dark: 0x2DB3A6)
    static let record = Color(light: 0xE5484D, dark: 0xEC5D62)

    static func speaker(_ i: Int) -> Color {
        [Color(light: 0x4F6BED, dark: 0x7C93F5), Color(light: 0xD97A2B, dark: 0xF0A05C),
         Color(light: 0x2F9E7E, dark: 0x5CC4A4), Color(light: 0xB5508F, dark: 0xD67FB6)][i % 4]
    }

    init(light: UInt32, dark: UInt32) {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

extension Animation {
    /// Critically damped, interruptible — the default for every state change.
    static let ui = Animation.spring(response: 0.35, dampingFraction: 1.0)
}

/// Feedback on press-down, not release.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

/// Full-width primary action.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var tint: Color = .accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(title) } icon: { if let systemImage { Image(systemName: systemImage) } }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(.white)
                .background(tint, in: .rect(cornerRadius: 14))
        }
        .buttonStyle(PressStyle())
    }
}

struct SpeakerChip: View {
    let name: String
    let index: Int
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.speaker(index)).frame(width: 8, height: 8)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.speaker(index))
        }
    }
}

extension View {
    func sectionLabel() -> some View {
        font(.footnote.weight(.semibold)).textCase(.uppercase).tracking(0.6).foregroundStyle(Color.inkSecondary)
    }
}
