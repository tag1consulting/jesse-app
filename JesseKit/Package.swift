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
        .library(name: "JesseDietDisplay", targets: ["JesseDietDisplay"]),
        .library(name: "JesseTodayDisplay", targets: ["JesseTodayDisplay"]),
        .library(name: "JesseOps", targets: ["JesseOps"]),
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
            // Checked-in wire fixtures for the day-file decode tests. They are the
            // bridge's OWN serializer's output over the bridge's OWN synthetic
            // `tests/fixtures/today/*.md` — invented content about a kiln rebuild, never
            // a copy of the real personal Today.md, which matters because this repo is
            // public. Regenerating them means re-running the bridge parser over those
            // same fixtures, not hand-editing the JSON.
            resources: [.copy("Fixtures")],
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
        // The portable diet/health DASHBOARD DISPLAY layer, extracted from the iOS
        // target so iOS and macOS render the same Health tab from the same source. It
        // holds the pure semantics (DietSemantics), the paging/history helpers, the
        // @MainActor view model (HealthDashboardModel, which fetches through the narrow
        // DietSnapshotProviding seam so each platform injects its own client), and the
        // SwiftUI dashboard views (Swift Charts based). It is HealthKit-FREE by
        // construction: HealthKit is an iOS-only enrichment/write concern that never
        // reaches the display, so no file here imports it and the Mac links this with
        // no HealthKit dependency. The one on-device insight (FoundationModels) is
        // cross-platform and degrades to nothing when the model is unavailable, so it
        // lives here behind its total `HealthInsightGenerating` seam.
        //
        // Isolation: default (nonisolated) like JesseNetworking, NOT MainActor-default.
        // DietSemantics and NutrientTrends are pure nonisolated functions called from
        // both the MainActor views and the iOS app's off-main per-turn context builder,
        // so forcing MainActor here would break the latter. The views get MainActor from
        // their `View` conformance; the model and the insight generator are explicitly
        // @MainActor. HealthDashboardModel carries a `nonisolated deinit` so an off-main
        // release (a unit-test host tears objects down off-actor) never routes through
        // the isolated-deinit executor hop and aborts.
        .target(
            name: "JesseDietDisplay",
            dependencies: ["JesseCore", "JesseNetworking"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "JesseDietDisplayTests",
            dependencies: ["JesseDietDisplay", "JesseNetworking"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // The portable DAY-FILE display layer — the Today tab — and the peer of
        // JesseDietDisplay in every structural respect: the pure semantics
        // (TodaySemantics: the optimistic overlay, the per-section open counts, the Do
        // Now total the tab badge reads), the @MainActor view model
        // (TodayDashboardModel, fetching through the narrow TodayProviding seam so each
        // platform injects its own client), and the SwiftUI views. One implementation,
        // every platform.
        //
        // HealthKit-free and UIKit-free BY CONSTRUCTION. JesseDietDisplay holds the
        // HealthKit line the same way (HealthKit is an iOS-only enrichment/write
        // concern that never reaches a display) but still reaches for UIKit behind
        // `#if canImport(UIKit)` in PlatformCompat.swift, to reproduce iOS's exact
        // system fills. This target has no such file and needs none: every color it
        // uses is a SwiftUI semantic (`.secondary`, `.tint`, the material fills), so
        // there is no `import UIKit` here at all, conditional or otherwise. `swift
        // build` on the macOS runner is what proves it — a UIKit reference would not
        // resolve there.
        //
        // Isolation: default (nonisolated), matching JesseNetworking and
        // JesseDietDisplay rather than the app targets' MainActor default. The
        // semantics are pure functions over value types, called from the MainActor
        // views AND from off-main callers (a badge count computed while building a
        // turn's context), so a MainActor default would break the latter; the views
        // get MainActor from their `View` conformance and the model is explicitly
        // @MainActor. TodayDashboardModel carries a `nonisolated deinit` so an
        // off-main release (a unit-test host tears objects down off-actor) never
        // routes through the isolated-deinit executor hop and aborts.
        .target(
            name: "JesseTodayDisplay",
            dependencies: ["JesseCore", "JesseNetworking"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "JesseTodayDisplayTests",
            dependencies: ["JesseTodayDisplay", "JesseNetworking"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // The OPERATIONS layer — the bridge and its sentinel as a screen. It holds the four
        // documents the ops endpoints answer with (the sentinel status page, the schedule,
        // the away profile, the deploy card), the pure decisions over them (chain grouping,
        // deploy-button enablement, which process a control verb is routed to), and the three
        // SwiftUI screens both apps embed. iOS and macOS each contribute one Settings row and
        // one menu item; neither owns a line of the logic.
        //
        // The DOCUMENTS live here rather than beside the wire types in JesseNetworking, and
        // that is the load-bearing choice: the schedule document arrives from three different
        // endpoints through two different processes (the bridge directly, and the sentinel's
        // proxy, which wraps it), so the clients answer with raw bytes and exactly one layer —
        // this one — knows what a schedule row is.
        //
        // Isolation: default (nonisolated), matching JesseNetworking and the two display
        // targets rather than the app targets' MainActor default. The documents are `Sendable`
        // value types decoded off the main actor by the models' own tasks, and the pure
        // functions over them are called from both; the views get MainActor from their `View`
        // conformance and each model is explicitly @MainActor with a `nonisolated deinit` (an
        // off-main release in a unit-test host must never route through the isolated-deinit
        // executor hop).
        .target(
            name: "JesseOps",
            dependencies: ["JesseNetworking"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "JesseOpsTests",
            dependencies: ["JesseOps", "JesseNetworking"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
