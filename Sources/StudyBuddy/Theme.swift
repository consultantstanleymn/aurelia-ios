// The iOS-only half of the package. On Linux this file compiles to nothing, which is what
// lets `swift test` run the core suite natively here. xtool builds it for real.
#if canImport(SwiftUI)
import SwiftUI
import StudyBuddyCore

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

    /// Warm white rather than pure #FFFFFF: a page this large in flat white vibrates against dark
    /// surroundings, and a tutor used at a desk at night should not be a lamp.
    static let background = Color(red: 0.992, green: 0.988, blue: 0.976)
    static let raised = Color(red: 1.0, green: 1.0, blue: 1.0)

    /// Sampled from `crab.svg`'s `#F0C94A`.
    ///
    /// Two golds, because one cannot do both jobs. The bright one is a fill and sits under dark
    /// text; on white it measures about 1.8:1 and would fail contrast outright as a foreground, so
    /// anything readable in gold uses `goldInk` instead, which is the same hue taken down to a
    /// bronze. Keeping both derived from one sample is what stops the icon and the text drifting.
    static let gold = Color(red: 0.941, green: 0.788, blue: 0.290)
    static let goldDeep = Color(red: 0.831, green: 0.627, blue: 0.090)
    /// For gold text on a light background. About 5.4:1 on `background`.
    static let goldInk = Color(red: 0.478, green: 0.361, blue: 0.043)
    static let goldPale = Color(red: 0.976, green: 0.941, blue: 0.831)

    static let text = Color(red: 0.086, green: 0.082, blue: 0.063)
    static let textMuted = Color(red: 0.404, green: 0.388, blue: 0.333)
    static let hairline = Color(red: 0.086, green: 0.082, blue: 0.063).opacity(0.12)

    /// The tutor's bubble is white on the cream page, so it lifts by being lighter rather than by
    /// being tinted; the learner's is gold-tinted so the two sides of the conversation are
    /// distinguishable at a glance without an avatar on every line.
    static let tutorBubble = Color.white
    static let learnerBubble = Color(red: 0.976, green: 0.941, blue: 0.831)

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
                    .fill(.thinMaterial)
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
                                        caption.who == .tutor ? Theme.gold.opacity(0.38) : .clear,
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
