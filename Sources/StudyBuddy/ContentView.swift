#if canImport(SwiftUI)
import SwiftUI

/// Placeholder while the toolchain is proved. Replaced by the real tutor screen.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Study Buddy")
                .font(.largeTitle.bold())
            Text("SwiftUI compiled on Linux")
                .foregroundStyle(.secondary)
        }
    }
}
#endif
