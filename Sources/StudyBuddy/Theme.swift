// The iOS-only half of the package. On Linux this file compiles to nothing, which is what
// lets `swift test` run the core suite natively here. xtool builds it for real.
#if canImport(SwiftUI)
import SwiftUI

/// The app's look: gold and white on near-black, with Apple's Liquid Glass over the top.
///
/// Dark only, deliberately. This is a study app used at a desk at night, and the phone is the
/// thing lighting the room; a light theme would be brighter than everything around it.
///
/// The gold is not a free choice — it is sampled from the crab logo's mid gradient stop, so the
/// accent and the mascot are the same colour rather than two decisions that happen to sit near
/// each other.
enum Theme {
    // MARK: - colour

    static let background = Color(red: 0.039, green: 0.039, blue: 0.043)
    static let raised = Color(red: 0.075, green: 0.075, blue: 0.086)

    /// Sampled from `crab.svg`'s `#F0C94A`.
    static let gold = Color(red: 0.941, green: 0.788, blue: 0.290)
    static let goldDeep = Color(red: 0.831, green: 0.627, blue: 0.090)
    static let goldPale = Color(red: 1.0, green: 0.953, blue: 0.769)

    static let text = Color.white
    static let textMuted = Color(red: 0.647, green: 0.647, blue: 0.678)
    static let hairline = Color.white.opacity(0.10)

    /// The two bubbles. The tutor's is gold-tinted and slightly raised so the eye can find it
    /// without needing an avatar on every line.
    static let tutorBubble = Color(red: 0.110, green: 0.106, blue: 0.098)
    static let learnerBubble = Color.white.opacity(0.07)

    // MARK: - type

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func body(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .regular, design: .rounded) }
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

// MARK: - Liquid Glass

/// One place to ask for glass, so the app looks like one thing.
///
/// `glassEffect` is iOS 26+. On anything older this falls back to a thin material with a hairline
/// border, which is close enough in a dark UI that the difference only shows if you go looking.
private struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat
    var prominent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(prominent ? .regular : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            )
        }
    }
}

extension View {
    /// The standard floating surface: header, board, composer.
    func glass(cornerRadius: CGFloat = 22, prominent: Bool = false) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, prominent: prominent))
    }
}

// MARK: - shared pieces

/// The speaking indicator. Three gold bars, animated only while the tutor is actually talking.
struct SpeakingBars: View {
    var isActive: Bool
    @State private var phase = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 3, id: \.self) { index in
                Capsule()
                    .fill(Theme.gold)
                    .frame(width: 3, height: isActive ? (phase ? 14 : 6) : 5)
            }
        }
        .animation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true), value: phase)
        .onAppear { if isActive { phase = true } }
        .onChange(of: isActive) { _, active in phase = active }
        .accessibilityHidden(true)
    }
}

/// A caption row. One bubble, tinted by who is speaking.
struct CaptionRow: View {
    let caption: Caption

    var body: some View {
        HStack {
            if caption.who == .learner { Spacer(minLength: 44) }
            VStack(alignment: caption.who == .learner ? .trailing : .leading, spacing: 0) {
                Text(caption.text)
                    .font(Theme.body())
                    .foregroundStyle(caption.who == .system ? Theme.textMuted : Theme.text)
                    .multilineTextAlignment(caption.who == .learner ? .trailing : .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .fill(caption.who == .learner ? Theme.learnerBubble : Theme.tutorBubble)
                            .overlay(
                                RoundedRectangle(cornerRadius: 19, style: .continuous)
                                    .strokeBorder(
                                        caption.who == .tutor ? Theme.gold.opacity(0.16) : .clear,
                                        lineWidth: 1
                                    )
                            )
                    }
                    // A streaming line fades up as it fills, so the eye follows the newest words
                    // without the row jumping around as it grows.
                    .opacity(caption.isStreaming ? 0.94 : 1)
            }
            if caption.who != .learner { Spacer(minLength: 44) }
        }
    }
}
#endif
