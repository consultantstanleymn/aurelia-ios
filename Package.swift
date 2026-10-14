// swift-tools-version: 6.0

import PackageDescription

// Two targets, and the split is not cosmetic.
//
// StudyBuddyCore is Foundation and nothing else. It holds the tag parser, the arithmetic, the
// brain client and the prompt builder — all of which are ordinary string and data work. Because
// none of it touches UIKit or SwiftUI it compiles on Linux, which means `swift test` runs the real
// suite natively here instead of cross-compiling it for a device that is not attached.
//
// StudyBuddy is the app: SwiftUI, AVFoundation, Speech, SQLite. It only ever builds through xtool
// against the Darwin SDK, because those frameworks do not exist on Linux.
//
// The original study mentor is a Python FastAPI server plus a static web frontend, self-hosted
// behind `docker compose`. This is the same tutor rebuilt as a native iOS app.
//
// The voice change is what makes native worth more than merely nicer. The Python version runs
// faster-whisper for hearing and Kokoro for speaking, both on the server's CPU, so the tutor only
// exists while a machine is running and reachable. iOS ships both halves on-device, so the same
// tutor works on a plane with the network off.
let package = Package(
    name: "StudyBuddy",
    platforms: [
        .iOS("17.4"),
        .macOS(.v14),
    ],
    products: [
        // xtool wants a library product and supplies the entry point and the bundle itself.
        .library(
            name: "StudyBuddy",
            targets: ["StudyBuddy"]
        ),
        .library(
            name: "StudyBuddyCore",
            targets: ["StudyBuddyCore"]
        ),
    ],
    targets: [
        .target(
            name: "StudyBuddyCore",
            path: "Sources/StudyBuddyCore"
        ),
        .target(
            name: "StudyBuddy",
            dependencies: ["StudyBuddyCore"],
            path: "Sources/StudyBuddy",
            resources: [
                // The mascot. PNG rather than SVG because SwiftUI's Image does not rasterise SVG,
                // and xtool has no actool and no asset catalog — so there is no .xcassets to hang
                // an imageset on. A loose @1x/@2x/@3x trio in the bundle is the only shape that
                // works here, and Image("crab") finds it by name.
                .copy("Resources/crab@1x.png"),
                .copy("Resources/crab@2x.png"),
                .copy("Resources/crab@3x.png"),
                // The three curricula, staged by scripts/stage-content.sh from the sibling
                // curriculum repositories. A build input, so .gitignore says so.
                .copy("Resources/Content")
            ]
        ),
        .testTarget(
            name: "StudyBuddyCoreTests",
            dependencies: ["StudyBuddyCore"],
            path: "Tests/StudyBuddyCoreTests"
        ),
    ]
)
