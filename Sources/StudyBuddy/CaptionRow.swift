#if canImport(SwiftUI)
import SwiftUI

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
                    // A streaming line sits slightly back, so the eye goes to finished text and
                    // knows the rest is still arriving.
                    .opacity(caption.isStreaming ? 0.94 : 1)
            }
            if caption.who != .learner { Spacer(minLength: 44) }
        }
    }
}
#endif
