// swift-tools-version: 6.2
import PackageDescription

// JesseKit is the local Swift package that gives the app a real compile-time
// module boundary. Until now the model layer was "shared" between the iOS and
// macOS targets only by dropping the same .swift files into both targets' compile
// phases (the JesseCore synchronized folder), which is not a boundary at all: the
// Mac target could and did grow parallel re-implementations. JesseCore is the
// first library product — the Foundation/SwiftData model layer (JesseMode, the
// @Model entities, and the versioned schema + migration plan) — extracted verbatim
// with zero behavior change.
//
// The JesseCore target replicates the app targets' concurrency context so the
// move is truly behavior-preserving: the app compiles with
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor and Swift 6 language mode, and the
// model code (see OrderedTurnsMemo in Models.swift) was authored against that
// default. defaultIsolation(MainActor.self) reproduces it here.
let package = Package(
    name: "JesseKit",
    platforms: [
        .iOS("26.5"),
        .macOS("26.0"),
    ],
    products: [
        .library(name: "JesseCore", targets: ["JesseCore"]),
    ],
    targets: [
        .target(
            name: "JesseCore",
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "JesseCoreTests",
            dependencies: ["JesseCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
