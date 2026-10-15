import Foundation

/// One line in the conversation.
struct Caption: Identifiable, Equatable {
    enum Who: Equatable { case tutor, learner, system }
    let id = UUID()
    var who: Who
    var text: String
    /// Set while the tutor is still writing this line, so the view can show it differently.
    var isStreaming = false
}
