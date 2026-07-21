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
        .library(name: "JesseNetworking", targets: ["JesseNetworking"]),
        .library(name: "JesseConversations", targets: ["JesseConversations"]),
        .library(name: "JesseSearch", targets: ["JesseSearch"]),
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
        // The bridge HTTP contract and the one concrete client both apps share:
        // config, wire types, the SSE parser, endpoint construction, error mapping,
        // and the diet snapshot models. View-free and health-free — the iOS app layers
        // its per-turn health_context body on top. Unlike JesseCore (whose @Model layer
        // was authored against the app's MainActor default isolation), the networking
        // surface is nonisolated Sendable value types and a nonisolated client used off
        // the main actor, so this target keeps Swift's default (nonisolated) isolation.
        .target(
            name: "JesseNetworking",
            dependencies: ["JesseCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "JesseNetworkingTests",
            dependencies: ["JesseNetworking"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // The pure, view-free list-presentation layer both apps drive their thread
        // list from: date sectioning, the collapsible-folder / favorites / origin
        // layout, and the multi-token match predicate. It reads @Model state on
        // JesseThread, so like JesseCore it runs under the app's MainActor default
        // isolation (the free functions were authored against that default and are
        // only ever called from the MainActor list views). Extracted verbatim from
        // the iOS target with zero behavior change so iOS and macOS share one source.
        .target(
            name: "JesseConversations",
            dependencies: ["JesseCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "JesseConversationsTests",
            dependencies: ["JesseConversations"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // The two-tier conversation search extracted from the iOS app so iOS and
        // macOS share one implementation: the framework-agnostic query-expansion
        // seam (`QueryExpanding`), the debounce/gate/cache/cancel orchestration
        // model (`ThreadSearchModel`), the pure gating decision (`shouldExpand`),
        // and the ONE FoundationModels-backed on-device expander. Like JesseCore
        // and JesseConversations it runs under the app's MainActor default
        // isolation (the model and expander are @MainActor, authored against that
        // default). FoundationModels is present on iOS 26 and macOS 26, and the
        // expander degrades to [] at runtime when the model is unavailable, so the
        // one file that imports it compiles and runs on both platforms. Depends on
        // JesseCore and JesseConversations to sit alongside the list-presentation
        // layer it widens.
        //
        // GOTCHA (applies to any class here): under .defaultIsolation(MainActor.self)
        // a class's synthesized deinit is MainActor-isolated, so releasing an instance
        // off the main actor (a unit-test host tears objects down off-actor) routes
        // through the isolated-deinit executor hop and aborts. Give any class that can
        // be released off the main actor an explicit `nonisolated deinit {}` (see
        // ThreadSearchModel and FoundationModelExpander).
        .target(
            name: "JesseSearch",
            dependencies: ["JesseCore", "JesseConversations"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "JesseSearchTests",
            dependencies: ["JesseSearch"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
