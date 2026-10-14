// SwiftUI does not exist on Linux, so on Linux this file compiles to nothing and the package
// still builds — which is what lets `swift test` run the core suite natively here.
// xtool builds it for real against the Darwin SDK.
#if canImport(SwiftUI)
import SwiftUI

// The entry point, and the first thing worth proving on this toolchain.
//
// openGym's shell cannot use this pattern: it is UIKit with an AppDelegate, because a WKWebView
// has to be built and installed as the root before anything draws. This app has no such ordering
// problem — a SwiftUI App owns its window — so `@main` on an App is the simpler and more honest
// shape here.
//
// What this file actually exists to prove is that SwiftUI compiles against the Darwin SDK on
// Linux at all. Everything else in the app is ordinary; that is not.

@main
struct StudyBuddyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

#endif
