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
    name: "Aurelia",
    platforms: [
        .iOS("17.4"),
        .macOS(.v14),
    ],
    products: [
        // xtool wants a library product and supplies the entry point and the bundle itself.
        .library(
            name: "Aurelia",
            targets: ["Aurelia"]
        ),
        .library(
            name: "StudyBuddyCore",
            targets: ["StudyBuddyCore"]
        ),
    ],
    targets: [
        // A C target whose only job is its header.
//
// The Darwin SDK ships a SQLite3 module, so the iOS build imports SQLite3 directly. Linux has the
// headers and the library but no module map for them, so `canImport(SQLite3)` was false there and
// every method in ProgressStore compiled to nothing under `swift test` — the store had never been
// executed by anything. SwiftPM generates a module map from a C target's include directory, which
// makes this the supported way to get there without an absolute path or an unsafe flag.
// See Sources/CSQLiteShim/include/CSQLiteShim.h.
.target(
            name: "CSQLiteShim",
            path: "Sources/CSQLiteShim",
            linkerSettings: [
                // The generated module map makes the module importable but does not put the library
                // on the link line, so without this the tests compile and then fail to link on
                // every sqlite3_* call. Linux only, so the iOS build keeps using the SDK's own
                // SQLite3 and its autolinking.
                .linkedLibrary("sqlite3", .when(platforms: [Platform.linux]))
            ]
        ),
        .target(
            name: "StudyBuddyCore",
            dependencies: ["CSQLiteShim"],
            path: "Sources/StudyBuddyCore"
        ),
        .target(
            name: "Aurelia",
            dependencies: ["StudyBuddyCore"],
            path: "Sources/StudyBuddy",
            resources: [
                // The mark. PNG rather than SVG because SwiftUI's Image does not rasterise SVG,
                // and xtool has no actool and no asset catalog — so there is no .xcassets to hang
                // an imageset on. A loose @1x/@2x/@3x trio in the bundle is the only shape that
                // works here, and Image("aurelia") finds it by name.
                .copy("Resources/aurelia@1x.png"),
                .copy("Resources/aurelia@2x.png"),
                .copy("Resources/aurelia@3x.png"),
                // The three curricula, staged by tools/stage-content.sh from the sibling
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
