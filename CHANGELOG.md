# Changelog

All notable changes to this project are documented here.

The **bridge** (Rust, `bridge/Cargo.toml`) and the **iOS app** (`Jesse/`) are
**versioned independently** — each entry names the component and its version.
The bridge follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html);
the app uses `MARKETING_VERSION (CURRENT_PROJECT_VERSION)` (e.g. `1.0 (2)`),
where the build number increments every release. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Every commit that changes a component **must** bump that component's version and
add an entry here — enforced by `scripts/version-guard.sh` (the pre-push hook and
CI both run it). See the "Versioning" section of `bridge/README.md`.

## [Unreleased]

## [App 1.0 (64)] - 2026-07-21

### Added
- **The iPhone's two-tier conversation search now works on the Mac too, from one
  shared implementation.** The Mac sidebar gains a live search that matches the
  iPhone: instant Tier-1 token matching over conversation titles and transcript
  text, widened by Tier-2 on-device query expansion when the model is available,
  with a Settings toggle for the expansion tier and silent fallback to Tier-1
  everywhere. Nothing is ever sent off the device.
  - **Shared library (`JesseSearch`).** The search seams that lived only in the iOS
    target moved into a new `JesseSearch` library in `JesseKit`, so iOS and macOS
    search from one source: the framework-agnostic query-expansion seam
    (`QueryExpanding`), the debounce / gate / cache / cancel orchestration model
    (`ThreadSearchModel`), the pure gating decision (`shouldExpand`), and the single
    FoundationModels-backed on-device expander. The expander stays the only file
    that imports FoundationModels and guards model availability at runtime (it
    degrades to no expansion when the model is unavailable), so the same code
    compiles and runs on iOS 26 and macOS 26. The iOS app now imports the shared
    library with no behavior change.
  - **Mac search UI.** A `.searchable` field in the sidebar filters the list on the
    typed query immediately and widens if and when on-device expansion terms arrive;
    the model never blocks the list. An active search force-expands month folders so
    no match hides behind a collapsed header, and search composes with the existing
    Favorites and Archived scopes (scope is applied before the search filter, so
    searching within a scope searches only that subset). A "Smart search
    (on-device)" toggle in Mac Settings drives the expansion tier, matching the
    iPhone; when off, only Tier-1 runs.
  - **Tests.** The pure search tests (`filterExpansionTerms`, gating, and the
    orchestration model's debounce / gate / cache / cancel via a fake expander) moved
    into `JesseSearchTests` and run in the fast package suite. A new `JesseMacTests`
    case drives the Mac view model with a fake expander and asserts that typing a
    query narrows the layout to the Tier-1 matches and widens to include an
    expansion-only match, and that a disabled tier and a scoped search behave as
    expected.

## [App 1.0 (63)] - 2026-07-21

### Added
- **Archive a conversation to hide it from your list, with an Archived view to see
  or restore it, on both iOS and Mac from one shared implementation.** Archiving is
  the reversible "get this out of my way" action (for example a duplicate) that
  deletion is not: the conversation and all its turns stay put, it just leaves the
  main list until you unarchive it. It is distinct from deletion, which removes the
  thread and reclaims its remote transcript; neither affects the other.
  - **Schema (`JesseCore`).** `JesseThread` gains two additive, defaulted properties,
    `isArchived` (Bool = false) and `archivedAt` (Date?), plus `setArchived` /
    `toggleArchived` helpers mirroring the favorites ones (the timestamp is stamped on
    archive and cleared on restore).
  - **Store migration hardening (`JesseCore` / `AppModelContainer`).** The store now
    opens with SwiftData's automatic lightweight migration instead of a staged
    `SchemaMigrationPlan`. The staged plan keyed migration on each version's exact
    model checksum, but every `VersionedSchema` here references the same live `@Model`
    classes, so adding a property to an existing entity (like the archive fields)
    changed a version's checksum in place and turned every already-stamped store into
    an "unknown model version", throwing at open ("Cannot use staged migration with an
    unknown model version") and stranding the user behind the "Couldn't open your saved
    conversations" banner. That was a latent break on the first additive property after
    the plan shipped. Automatic migration infers a lightweight mapping from the store's
    entity hashes with no checksum pinning, which is exactly what carried every earlier
    additive property (favorites, origin, aiTitle) and the outbox entities. A new
    regression test writes a store stamped with a prior `JesseThread` shape and proves
    it opens after the attribute is added; the populated-store test also covers the
    archive-flip round-trip. A staged plan is only needed for a genuinely
    non-lightweight change (a rename/retype/entity split) and should be reintroduced
    only then.
  - **Shared filtering (`JesseConversations`).** `threadListLayout` takes a new
    `archivedOnly` scope. The normal list (All, Favorites, Watch) now excludes
    archived threads; a dedicated Archived view shows only archived threads as a flat,
    newest-first list like Favorites; an archived favorite drops out of Favorites until
    restored. The archive filter is applied before the favorites, origin, and search
    filters and before grouping, so it composes additively and the function stays pure.
  - **iOS.** The scope control gains an Archived filter, and each conversation has an
    Archive / Unarchive affordance (leading swipe action and context menu). Archived
    conversations no longer appear in All or Favorites. Existing behavior (favorites,
    folders, deletion, and every entry point) is unchanged apart from the new, opt-in
    archive affordance.
  - **Mac.** The sidebar scope control gains an Archived segment, each row has an
    Archive / Unarchive action (context menu and trailing swipe), and Command Shift A
    archives or restores the selected conversation.
  - Archive state is LOCAL to each device's SwiftData store: it is intentionally not
    synced through the bridge (which syncs only sessions, transcripts, and titles),
    exactly like favorite state. Archiving is a per-device "hide from my list" action.

## [App 1.0 (62)] - 2026-07-21

### Changed
- **Extracted the thread list's presentation logic into a shared
  `JesseConversations` library and brought Favorites to the Mac, so both apps drive
  their conversation list from one source instead of the Mac re-implementing it.**
  The date sectioning, the collapsible-folder / favorites / origin layout, and the
  multi-token match predicate were iOS-target-local; the Mac sidebar was a bare
  `@Query` sort with no favorites at all. This unifies the presentation seam and
  adds the Mac UI on top of it.
  - **New `JesseConversations` library product in `JesseKit`** (depends on
    `JesseCore`), holding `ThreadSectioning`, `ThreadFolders`, `ThreadOriginFilter`,
    and the pure `threadMatches` / `threadMatchesAny` predicate, moved verbatim from
    the iOS target and made public with zero behavior change. The iOS app now imports
    the shared module; its list behavior is unchanged. The on-device search-expansion
    orchestration (gating and the highlighted matched snippet) stays iOS-only.
  - **Favorites on the Mac.** The Mac sidebar now renders from the shared
    `threadListLayout` (via a testable `MacThreadListModel` seam), not a bare
    `@Query` sort: a segmented All / Favorites scope control switches between the full
    date-sectioned layout with collapsible month folders and the flat, newest-first
    favorites list, matching the iPhone. Each row has a star affordance, with a
    per-thread toggle via context menu and a leading swipe action; the favorites
    filter has a Command Shift F shortcut. The Mac's cache-first paint, selection
    restoration, and the New / Refresh / Settings shortcuts are preserved.
  - **Tests moved and added.** The pure sectioning / folder / origin / favorites /
    match tests moved into `JesseConversationsTests` (kept green); new
    `JesseMacTests` coverage exercises the Mac list-model wiring (starring updates
    `isFavorite` / `favoritedAt`, scope switching changes which threads the layout
    yields, folder toggling reveals month rows). No schema change and no bridge
    change: the favorites fields already existed.

## [App 1.0 (61)] - 2026-07-21

### Changed
- **Unified the iOS and macOS bridge clients into one shared `JesseNetworking`
  library, and deleted the macOS networking duplication. Pure structural refactor,
  no behavior change on either platform.**
  The single largest source of iOS/macOS drift was the networking layer: the Mac
  target's `MacJesseClient.swift` re-implemented from scratch what the iOS
  `JesseClient.swift` already did (send a turn, stream the SSE reply, poll a job,
  list sessions, hydrate a transcript, mint a title), with the wire structs, the SSE
  parser, and endpoint construction duplicated under `Mac`-prefixed names. This
  collapses that duplication into one place.
  - **New `JesseNetworking` library product in `JesseKit`** (depends on `JesseCore`),
    owning the whole bridge HTTP contract: the config value type (`JesseConfig`) plus a
    Keychain-backed config store seam (`BridgeConfigStoring` / `KeychainConfigStore`),
    the one canonical set of wire types (`JesseReply`, `JesseSendResult`,
    `JesseResultState`, `JesseStreamEvent`, `SessionSummary`, `HydratedTurn`, the
    request/response `Codable` DTOs, `JesseProvenance`, `JesseDirectives`, the `Diet*`
    snapshot models), one pure `SSEParser`, endpoint/URL construction, the bearer-auth
    request builder, ETag handling, error mapping (`JesseError` / `DietFetchError`), and
    a single concrete `JesseBridgeClient` implementing send, stream, poll, sessions,
    hydrate, title, diet, cancel, delete, health, and device registration.
  - **iOS `JesseClient` is now a thin platform layer over that shared client.** It adds
    only the iOS-specific concerns: the per-turn `health_context` body assembled from
    HealthKit, the classify-then-attach decision, and the needs-health fulfillment retry.
    The public `JesseClientProtocol` surface the app already consumes is unchanged, so
    `RunCoordinator` and the views compile without edits (`JesseNetworking` is
    re-exported from the iOS target).
  - **Deleted `MacJesseClient.swift` and every `Mac`-prefixed wire type and parser.**
    `MacStore`'s `MacCoordinator` now talks to the shared `JesseBridgeClient`; the Mac
    keeps its own thin cache-first single-turn coordinator, but the networking underneath
    is the shared one. `MacBridgeConfig` and `MacKeychain` are gone: `MacConfigStore`
    now persists host, port, and token through the shared Keychain seam, exactly as iOS
    does (token in the Keychain, not plaintext UserDefaults).
  - **Tests.** The SSE-framing and host-sanitizing tests (formerly duplicated in the iOS
    and macOS test targets) are consolidated as package tests in `JesseNetworkingTests`,
    alongside the reply display/spoken derivation tests. The macOS test target keeps its
    app-specific coverage (Markdown, pairing-link, notification snippet). The iOS wire and
    integration tests are unchanged.
  - **No bridge change.** The bridge HTTP contract, and every route the apps call, are
    untouched. Streaming, the 202 poll fallback, hydration deltas, ETag 304s, title
    minting, cancellation, and remote-session deletion all behave as before. The macOS
    stream now shares the iOS session ceilings (a day-long resource timeout), which only
    raises a cap and never changes which frames arrive.

## [Bridge 0.24.2] — 2026-07-21

### Fixed
- **The diet gate now recognizes "track", the most common real logging verb.**
  `DIET_KEYWORDS` had `log`/`logged`/`logging` but not `track`, so the bare
  imperative with a weight-and-food object ("track 30g of walnuts") never matched.
  A missed gate is silent and looks fine from the outside — the turn just takes the hosted
  path and logs correctly — which is why this went unnoticed: the local ladder was
  simply never entered.
  Measured over the 203 turns in one deployment's context ledger (2026-07-16 → -21):
  59 turns logged food or exercise and **16 (27%) missed the gate**, of which
  "track" alone accounts for **8**.
  **Only the bare imperative is added — not `tracked`/`tracking`.** All 36 real diet
  uses are the bare verb, while the inflected forms appear overwhelmingly in
  non-diet senses (asking how long something has been tracked). Since the vault-QA
  gate yields to diet intent (`vaultqagate.rs:164`), matching them would hijack
  ordinary vault questions — caught by two existing `vaultqagate` tests when a first
  cut added all three forms. A regression test now pins the inflected forms OUT.
  The remaining misses are elliptical continuations inside a logging thread — a bare
  quantity-and-food follow-up ("another 40g of the same") with no verb at all;
  per-deployment food nouns in `persona.diet_keywords_extra` cover those today, and
  a thread-context rule would address them structurally.

## [App 1.0 (60)] - 2026-07-21

### Changed
- **Extracted the model layer into a real local Swift package, `JesseKit`, with a
  first library product `JesseCore`. Pure structural refactor, no behavior change.**
  Until now the model layer was "shared" between the iOS and macOS targets only by
  compiling the same files into both (the `JesseCore` synchronized folder), which is
  not a boundary: the Mac target had already grown a parallel networking client. This
  establishes the compile-time boundary the rest of that cleanup needs.
  - **`JesseMode`, `Models.swift`, and `JesseSchema.swift` moved** from the app's
    synchronized `JesseCore/` folder into `JesseKit/Sources/JesseCore`. The types the
    apps reference (the `@Model` entities `JesseThread`, `Turn`, `TurnAttachment`,
    `OutboxItem`, `OutboxAttachment`, `WrittenMeal`; the enums `JesseMode`, `TurnRole`,
    `ThreadOrigin`, `OutboxState`; and `JesseSchemaV1`/`JesseSchemaV2`,
    `jesseCurrentSchema`, `JesseMigrationPlan`) are now `public`. Nothing was renamed.
  - **SwiftData store untouched.** Same entities, same schema versions, same
    `JesseMigrationPlan` (V1 to V2 lightweight). Entity names are the unqualified class
    names, so moving them to a new module does not change on-disk identity. The
    populated-store migration test still opens the store and passes.
  - **Concurrency preserved.** The `JesseCore` target sets `defaultIsolation(MainActor)`
    and Swift 6 language mode so the moved code keeps the exact isolation it had under
    the app's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
  - **Targets wired.** `JesseKit` is a package dependency of the iOS `Jesse` target, the
    `Jesse Mac` target, and the `JesseTests` target; the files that reference the moved
    types gained `import JesseCore`. The watch and widgets targets do not use these
    types and are unchanged.
  - **Tests.** The two pure model unit suites (`ThreadOrderedTurnsTests`,
    `ThreadOriginTests`) moved into the fast `swift test` package suite; the
    app-integration tests (container open, app wiring) stay in `JesseTests`, importing
    `JesseCore`.
  - **CI.** A new job builds and tests the package with warnings as errors; the app
    build steps pass `SWIFT_SUPPRESS_WARNINGS=NO` so warnings-as-errors no longer
    conflicts with the suppression Xcode applies to package dependencies. No bridge
    changes.


## [Bridge 0.24.1] — 2026-07-21

### Fixed
- **Concurrent device-token registrations no longer collide on a shared temp file.**
  `persist_device_token` derived its temp path from the target (`device.json.tmp`), so
  every writer used the *same* one. The phone re-registers on foreground, so two
  `POST /jesse/device` calls overlap routinely: the loser's rename found nothing
  (`ENOENT`, the `warning: could not persist device token` line seen 78 times in the
  Studio log, characteristically in pairs) while its still-open fd wrote into the file
  the winner had just renamed into place — defeating the atomicity the temp+rename
  discipline exists to provide. The temp name is now unique per write (pid + a
  process-wide counter), so each writer renames its own file and the last simply wins.
  A regression test drives 8 threads × 50 writes and asserts *every* write succeeds;
  against the old code it reproduces 233 `ENOENT` failures out of 400.

### Changed
- **A failed diet-extract child now logs why before falling through to rung 2.** The
  `Err` arm discarded the child's `ApiError` and reported only `reason=child_error`,
  which cannot distinguish a model failure from an unreachable backend. That silence
  hid a ~14-hour local-gateway outage (the Studio rebooted overnight; the bridge came
  back under launchd, the hand-started gateway and ds4 did not) behind what looked like
  ordinary rung-2 flakiness. The child's status and message are now logged — no
  utterance content, same rules as the provenance line.

## [App 1.0 (59)] — 2026-07-21

### Added
- **Native macOS Jesse client (`Jesse Mac`) — JESSE-WRAP B3 MVP.** A thin native
  client that talks to the same bridge on the Studio the iPhone uses, built as a
  SEPARATE macOS app target rather than the plan's originally-locked single
  multiplatform target: the iOS app is deeply UIKit/HealthKit-coupled and its
  `ContentView` isn't wanted on the Mac, so a separate target avoids invasive
  `#if` surgery on the shipping app.
  - **Shared core (`JesseCore/`).** A new synchronized folder, added to BOTH the
    iOS and Mac targets with zero iOS behavior change: `JesseMode` (extracted from
    `JesseClient.swift`) plus `Models.swift` and `JesseSchema.swift` (moved from
    `Jesse/`). The Mac target reuses the phone's `JesseThread`/`Turn` schema.
  - **`NavigationSplitView` shell** — cache-first thread list + conversation
    detail. The list renders from the local SwiftData store (instant, offline) and
    reconciles from `GET /jesse/sessions` (ETag-conditioned) in the background, so
    phone-started threads appear.
  - **`MacJesseClient`** — a health-free client covering `POST /jesse`,
    `GET /jesse/stream/{job_id}` (SSE, with a poll fallback), `GET /jesse/sessions`
    (`?since=`, ETag), `GET /jesse/sessions/{id}` (`?after=` byte-delta hydration),
    `POST /jesse/title`, and `GET /jesse/result/{job_id}`.
  - **Resume + hydration.** Opening a thread hydrates its transcript via the
    append-only `?after=` delta, tracked by a per-session byte-offset cursor, and
    continues the same Claude Code session by `session_id`.
  - **Config + notifications.** Manual host/token and `jesse://pair` link config
    (bearer token in the Keychain); a dependency-free SwiftUI Markdown renderer
    (the iOS path is UIKit-based); local completion notifications
    (`UserNotifications`) while the app runs.
  - **Tests (`Jesse MacTests`, 19 XCTest cases).** Cover the pure logic — SSE
    framing, host sanitizing, Markdown block parsing, and pairing-link parsing.
    Hosted in the Mac app but run unsigned.
  - **CI.** The `ios-app` job now also builds the Mac app (warnings-as-errors) and
    runs the Mac tests; a shared `Jesse Mac` scheme is checked in. No bridge changes.
  - Deliberately omitted (iOS-only): HealthKit, Siri, Live Activities, watch relay,
    camera. Deferred to polish: APNs-for-Mac (quit/asleep notify), camera QR pairing.


## [App 1.0 (58)] — 2026-07-21

### Changed
- **Health tab reframed from a strict grader into a supportive coach — presentation
  and wording only.** The numeric targets and the floor / ceiling / window model are
  **untouched**; what changed is how the day is shown and described.
  - **One color now means one thing, on every row.** The old `Status` band
    (red/yellow/green) mapped straight to color, so red meant "too low" on a floor,
    "too high" on a ceiling, and *both* on the fat window — and the same red calorie
    ring meant "ate too much" on a normal day but "ate too little" on a carb-load day.
    A new one-meaning `DietSemantics.Tone` drives all Health-tab color instead:
    `onTrack` (green = good), `inProgress` (grey = coming along / no judgment), `nudge`
    (amber = one gentle action helps), `takeNote` (a muted clay, never alarm-red =
    genuinely worth attention). Direction (too low vs too high) is carried by the words
    and the goal glyph (`≥`/`≤`/`↕`), never the color. `Status` is kept only for the
    per-nutrient trend chart, where a single nutrient's band is unambiguous over time.
  - **Mornings no longer look like failure.** `Tone` is hour-aware: a floor that's
    merely unfinished early in the day reads as neutral "coming along", not a problem;
    only once the day is winding down (after `nagHour`) does a still-low floor become a
    gentle nudge. A floor already basically there (≥ 80%) reads on-track and is never
    nagged over the last few grams.
  - **A plain summary leads the screen.** A new `DaySummary` answers "how am I doing"
    and "what would help next" in one short, kind pair of lines (e.g. "Solid day." →
    "To round out the day: some protein and some fiber this evening."), derived from the
    same gauges the rings draw so the two can't disagree. The rings and per-nutrient
    detail stay, quieter, below it.
  - **Kind, action-first wording.** The `*Remaining` strings and the explainer copy drop
    the punitive vocabulary: "need 20g more" → "20g to go"; "target hit" → "there —
    nice"; "300 left" → "room for 300"; "at limit" → "right on target"; "200 over limit"
    → "200 over"; "7g over cap" → "7g above the range"; and the carb-load explainers no
    longer say a day can "fail". The genuinely-honest signals (well over the calorie
    ceiling late in the day, a fat hard-cap breach) are kept — delivered as a gentle
    heads-up, not an alarm.
  - **Honest data is preserved.** Unknown is still not zero, a partial total still reads
    "≥ / at least", and a not-yet-tracked nutrient is still a data gap, not a miss.
  - New/updated unit coverage: `DaySummaryTests`, tone cases in `DietSemanticsTests`,
    and the reworded assertions in `DietSemanticsTests`/`HealthRingsTests`. All 941 app
    tests pass; build is warning-free.

## [Bridge 0.24.0] — 2026-07-21

### Changed
- **The deterministic ASCII diet dashboard (printed into chat after a local meal-log)
  now tells the same supportive-coach story as the app's Health tab.** Presentation
  only — the CSV-derived totals, targets, and floor/ceiling/window model are unchanged.
  - **A plain summary line leads** ("how am I doing / what would help next"), the same
    opening the Health tab uses.
  - **Bars are monochrome** (`█`/`░`) instead of pass/fail color emoji (🟥/🟨/🟩), which
    made one color mean three different things across rows. Status now lives in the
    trailing words; the goal glyph (`≤`/`≥`/`↕`) carries direction.
  - **Kind, action-first wording** mirroring the app: "room for X" for calorie headroom,
    "Xg to go" for a short floor, "in range" / "Xg above the range" for fat — never
    "over limit"/"over cap".

## [Bridge 0.23.0] — 2026-07-20

### Added
- **Transcript hydration endpoint — `GET /jesse/sessions/{session_id}`.** A client
  that never saw a session's earlier turns can now render its history. Returns the
  session transcript as ordered, client-renderable turns
  (`{ "session_id", "turns": [ { "role", "text", "timestamp? } ], "next_offset" }`),
  shaped like a live SSE turn: user utterances (wrapper-stripped) and visible
  assistant TEXT only — thinking, `tool_use`, and `tool_result` noise are dropped,
  as are subagent (`isSidechain`) and CLI `isMeta` lines.
  - **`?after=<byte offset>` delta sync.** The jsonl is append-only, so the endpoint
    returns only the content after the offset plus the new `next_offset`; a
    reconnecting client re-syncs in one small round trip. A **partial trailing line**
    (the file caught mid-write) is left unconsumed and returned on the next `?after=`
    call once complete — malformed/partial lines are skipped, never a `500`.
  - **Same auth/rate-limit posture as `/jesse/sessions`** (bearer `401`, `429` on a
    burst). **`404`** for an unknown id; **`400`** for a non-plain id (path-traversal
    defense — the id must resolve to a file inside the vault projects dir, rejected
    before the filesystem is touched). Reuses the same pure projects-dir derivation
    (`session_transcript_path` / `escape_project_path`) `/jesse/sessions` uses.

### Fixed
- **Title-mint transcripts no longer pollute the session list (Wart 1).** Each
  `POST /jesse/title` one-shot runs `claude -p` and mints its own transcript whose
  first user turn is the fixed title instruction. `list_sessions` now recognizes and
  excludes those (prefix match on the instruction, coupled to the const by a test),
  and hydration `404`s a title-mint id — they were never real conversations.
- **`first_message` shows the user's words, not the wrapper (Wart 2).** The first
  user turn in a bridge transcript is the wrapped prompt (clock line, health context,
  Ask/Tell preamble); interactive sessions can lead with `<local-command-caveat>`
  plumbing. The bridge now strips what it added (the preamble/capability framing) and
  the caveat/command framing, so both the list snippet AND every hydrated user turn
  surface the actual utterance. Truncation bound unchanged (120 chars).

## [App 1.0 (57)] — 2026-07-20

### Fixed
- **A per-nutrient trend's short range (7d/30d) no longer reads empty for a
  rarely-logged nutrient.** The window was anchored on the last day *any*
  nutrient was logged (≈ today), so a nutrient that isn't on most food labels
  (omega-3, magnesium, calcium, potassium) charted blank at 7d whenever it
  wasn't logged in the last calendar week — you had to widen to 30d/All to see
  anything. `NutrientTrends.analyze` now anchors each nutrient's window on that
  nutrient's OWN most recent reading, so a short range always shows its recent
  tail (even one or two points). This mirrors the weight chart, whose series is
  weigh-ins only and so already anchored on its own data. Densely-logged macros
  are unchanged (their last reading is the last logged day). `windowed` gained an
  optional anchor with an inclusive upper bound so the window can't spill into
  later nutrient-less days.

## [App 1.0 (56)] — 2026-07-20

### Added
- **Per-nutrient trend charts now color each day by its goal status, and every
  trend chart offers a 1-week range.** The per-nutrient trend (behind a drill-down
  tap) plots each known day in the SAME green/amber/red the daily macro bars and
  status meter use (`statusColor`), so under/on/over reads at a glance:
  - Coloring reuses the existing per-day bands — `DietSemantics.floorStatus` for a
    floor (protein, fiber, carbs, and the minerals), `ceilingStatus` for a ceiling
    (sodium, saturated fat, calories), and the fixed-grams `fatWindowStatus` for the
    fat window — via a new pure `NutrientTrends.dayStatus`. Calories read as a
    ceiling and carbs as a floor (the normal-day treatment, the only one the history
    can assume), matching the Today bars; the informational nutrients (total sugars,
    unsaturated fat) stay neutral, never judged.
  - Color is a SECOND signal, never the only one: each dot's position relative to the
    target rule and a new under/on/over word in the scrub readout
    (`NutrientTrends.dayStatusPhrase`) carry the same information, and the palette is
    legible in light and dark mode.
  - A PARTIAL day (unknown-mixed, so its value is a lower bound) only takes a red/green
    once the lower bound already PROVES the breach — a floor already cleared, a ceiling
    already exceeded — and otherwise stays neutral rather than overclaim a band its
    unknowns could overturn. Gap days remain breaks in the line, never zeros.
  - A **1-week (7d)** option joins 30d/90d/All on every per-nutrient trend chart AND on
    the weight trend chart, so the recent tail reads at a glance (useful while
    traveling). The target line, coloring, gaps, and partial readout stay correct at
    every range.

### Notes
- No bridge change: `nutrientSeries` (bridge ≥ 0.21.0) was already decoded and wired;
  this is app-side charting only.

## [Bridge 0.22.4] — 2026-07-19

### Changed
- **Genericize persona: config-driven personalization via a gitignored local
  overlay.** No personal fact is compiled into the tracked bridge any more — the
  owner's name, pronoun, languages, and any extra diet vocabulary are runtime DATA.
  - New `[persona]` config (`bridge/src/persona.rs`): `owner_name` (default
    `"the user"`), `owner_pronoun` (default `"their"`), `languages`, and
    `diet_keywords_extra`. Resolved lowest-to-highest as built-in generic defaults
    → a gitignored `jesse.local.toml` `[persona]` table → environment variables
    (`JESSE_OWNER_NAME`, `JESSE_OWNER_PRONOUN`, `JESSE_LANGUAGES`,
    `JESSE_DIET_KEYWORDS_EXTRA`). A missing/malformed file soft-fails to defaults.
  - Config file search order (first that exists wins): `$JESSE_CONFIG` → repo-root
    `./jesse.local.toml` → `<state-dir>/jesse.local.toml` (`$JESSE_STATE_DIR` else
    `$HOME/.jesse-bridge`) — the last covers a launchd service whose cwd isn't the
    repo.
  - `bridge/src/prompt.rs`: the Ask/Tell wrappers and safety floors are now generic
    `{Owner}`/`{owner}`/`{owner_pronoun}` templates rendered from the persona at
    prompt-build time (the fixed, non-overridable floor still always leads). The
    `/jesse/prompts` endpoint returns the persona-rendered defaults.
  - `bridge/src/dietgate.rs`: the diet-intent keyword gate ships an **English-only**
    generic baseline; non-English/personal vocabulary is merged in from
    `persona.diet_keywords_extra` at load. `bridge/src/dietlog.rs` extract/verify
    prompts address the configured owner name (default "the user").
  - Stream-parsing test fixtures (`bridge/tests/fixtures/stream/*.ndjson`) keep the
    real captured schema but carry SYNTHETIC answer text (an "Alex Example" vault).
  - Ships `jesse.example.toml` (all keys, synthetic values); `jesse.local.toml` is
    gitignored. See README → **Make Jesse yours**.

## [App 1.0 (55)] — 2026-07-19

### Changed
- Owner name is threaded from Settings (`PromptStore.ownerName`, default
  `"the user"`) into the locally-built diet-coach rollup
  (`NutrientTrends.coachRollup`), replacing a hardcoded name; generic pronouns
  throughout. No behavior change for an unset name.

## [Bridge 0.22.3] — 2026-07-19

### Changed
- **Publishing prep: no personal infrastructure in the tracked tree.** Ahead of
  open-sourcing, scrubbed developer-specific values from tracked/shipped files and
  hardened the guard that enforces it:
  - The default `JESSE_VAULT` is now `~/vault` (was a developer's personal vault
    path) in `bridge/src/config.rs`; the doc/run examples and both READMEs match.
    The live bridge sets `JESSE_VAULT` explicitly, so this changes only the
    unset-env fallback. The `eval` harness's `vault_dir()` now resolves
    `$JESSE_VAULT` first (else `~/vault`), mirroring the bridge.
  - Genericized the personal launchd label prefix (`com.<developer>.jesse-*`) to
    `com.example.jesse-*` in `bridge/README.md` and `CHANGELOG.md`, and removed a
    stale `_removed-python/` note and `STATUS.md` references from the docs.
- **`scripts/ci-guards.sh` R5 guard now catches the whole tailnet address space,
  not a hand-listed set of IPs.** The previous denylist enumerated specific IPs and
  missed others in the same CGNAT range. It now flags any non-boundary
  `100.64.0.0/10` address and any `tail<digits>.ts.net` MagicDNS id (plus machine
  names, personal launchd labels, and home paths), while allowlisting the CIDR and
  boundary/example addresses the repo legitimately documents. Added an inline
  matcher self-check that fails loudly if a future edit neuters the regex.

### Added
- **Apache-2.0 `LICENSE` and `NOTICE`** at the repo root, and a `license =
  "Apache-2.0"` field in `bridge/Cargo.toml`.

## [Bridge 0.22.2] — 2026-07-19

### Changed
- **Record the vault-QA route probation start.** Added a "Probation status"
  paragraph to the "Vault-QA route graduation criteria" section of
  `bridge/README.md`: probation **started 2026-07-15** with the `0.11.0` deploy
  (the `JESSE_VAULTQA_*` triple, `JESSE_METRICS_LOG`, and `JESSE_EMERGENCY_LOCAL=on`
  added to the launchd env; the daily `com.example.jesse-vaultqa-audit` job installed
  the same day), so the earliest graduation review is **2026-07-29** (14 days) and
  only once **≥ 20 routed turns** have also accrued — whichever is later. Records the
  day-0 smoke baseline and two go-live caveats **independent of the vault-QA route**:
  the diet **extract** flakes to rung-2 under load (so the emergency diet
  verify-queue/replay path stayed **unit-test-only**, never exercised by the live
  outage drill), and the title one-shot exceeds its 20 s cap from qmd-MCP cold-start.
  Documentation only — no behavior change.

## [Bridge 0.22.1] — 2026-07-19

### Changed
- **Dropped the dead legacy weight-target contract from the `/jesse/diet` progress
  fixtures.** The (out-of-repo) progress generator stopped emitting
  `raceTarget`/`raceDate`/`maintTarget`; `progress.targets` is the sole weight-goal wire
  contract. The bridge is a pure pass-through for this block, so nothing changes at
  runtime — this is a **test/docs-only** cleanup. Removed the legacy fields from the
  integration fixtures (`FIX_PROGRESS`, `FIX_PROGRESS_LEGACY`) and deleted the round-trip
  assertions that pinned them. The `targets` array coverage is unchanged and complete:
  dated, undated (`date:null` and key-omitted), achieved past-dated, empty `targets: []`,
  and tolerance of an absent `targets` key. The app's legacy-fallback synthesis
  (`DietSemantics.displayTargets`) is untouched and stays by design.

## [Bridge 0.22.0] — 2026-07-18

### Added
- **Opt-in shadow comparison (`JESSE_SHADOW_*`)** — a side-effect-free way to
  gather evidence for whether a second backend (production intent: `fw-glm` via
  the gateway) could serve ask turns as well as the hosted model, **without
  changing a single production route**. When the `JESSE_SHADOW_BASE_URL` /
  `JESSE_SHADOW_AUTH_TOKEN` / `JESSE_SHADOW_MODEL` triple is armed, a **sampled**
  subset of eligible ask turns is **mirrored — strictly after the hosted answer
  is delivered** — to the shadow backend through the **same contained read-only
  child** the vault-QA route uses (`build_shadow_child_command` +
  `apply_shadow_env`; read-only root allowlist, strict MCP, provably unable to
  write). Both answers plus per-side timing and token usage are appended to a
  local **shadow pair log** (`JESSE_SHADOW_LOG`, default
  `~/Library/Logs/jesse-shadow/shadow.jsonl`, created mode `0600`).
  - **Eligibility** (all required): shadow armed; ask mode; the turn took the
    **hosted** route (vault-QA rung-0 local, emergency-local, and diet turns are
    excluded; a vault-QA fall-through to hosted **is** eligible); no attachments;
    the hosted turn completed successfully with a non-empty answer; and the turn
    is in the deterministic `JESSE_SHADOW_SAMPLE_PCT` sample (default 100, clamped
    `[0, 100]`, decided by a stable hash of the turn id — reproducible, never RNG).
    A **Tell is never mirrored, and a turn is never mirrored twice.**
  - **Isolation is guaranteed:** the delivered answer, its latency, its badge, and
    every production route are **byte-for-byte unchanged** whether shadow is armed
    or not (a golden test asserts the unarmed case; the delivery path has no
    `await` on anything shadow-related). The mirror runs on a **detached,
    permit-free** task, holds a **separate at-most-one slot** (`AppState.shadow_slot`)
    — never the production permit — **yields** (`skipped_busy`) to a running or
    queued phone turn, and runs the child at background priority. Any shadow
    failure (timeout, transport, gateway error, `JESSE_SHADOW_TIMEOUT_SECS`
    default 120) is recorded as an **incomplete** pair and swallowed.
  - **Secrets:** the bridge carries only the **gateway URL and gateway token** —
    never a Fireworks credential — and never logs a token value.
- **`shadow-audit` bin** — a daily judge (same conventions as `vaultqa-audit`:
  dated markdown note + JSON twin under `~/Library/Logs/jesse-shadow-audit/`,
  tripwires first). Reads the shadow log and judges up to `JESSE_SHADOW_JUDGE_CAP`
  (default 20) unjudged pairs on **ambient** hosted auth with **two
  position-swapped `claude -p` calls** per pair (shadow wins only if it wins both
  orderings; disagreement = tie); a line-count **watermark** + judged sidecar keep
  judging incremental and the log append-only. Reports W/L/T today and cumulative,
  per-side latency percentiles, measured Fireworks cost vs the same turns on Opus,
  a judge-spend estimate, **disarm tripwires** (injection-style leak, shadow-child
  write attempt, Fireworks spend > $5/day), and progress against the fixed
  **graduation criteria** (≥ 14 days armed AND ≥ 150 judged pairs; net ≥ −5% of
  judged; zero leaks; shadow p50 ≤ hosted p50 + 50%). The audit only reports — it
  never routes.

### Notes
- New env vars: `JESSE_SHADOW_BASE_URL`, `JESSE_SHADOW_AUTH_TOKEN`,
  `JESSE_SHADOW_MODEL`, `JESSE_SHADOW_SAMPLE_PCT`, `JESSE_SHADOW_LOG`,
  `JESSE_SHADOW_TIMEOUT_SECS`, plus `JESSE_SHADOW_JUDGE_CAP` for the audit. **The
  triple is the kill switch:** unset any one and shadow is off, byte-for-byte
  today's behavior (disarm = unset + `bootout` + `bootstrap`; `kickstart -k` does
  not reload plist env). New dependency: `libc` (one `setpriority` syscall for the
  background-priority shadow child). See `bridge/README.md` and `SECURITY.md`.

## [App 1.0 (54)] — 2026-07-18

### Changed
- **Migrated the app to the Swift 6 language mode.** Every target
  (`Jesse`, `JesseTests`, `Jesse Watch App`, `Jesse Watch AppTests`,
  `JesseWidgetsExtension`) now builds under `SWIFT_VERSION = 6.0`, with every
  resulting concurrency diagnostic fixed at the root cause rather than
  suppressed. The module was already main-actor-isolated by default, so the
  work concentrated at the async boundaries:
  - `JesseClientProtocol` is now `Sendable` (the coordinator races a turn's
    stream and poll in two concurrent child tasks, so the client existential
    crosses into them); `JesseConfig` gains `Sendable` to match.
  - `Ask/Tell/WakeJesseIntent` metadata and `VersionedSchema.versionIdentifier`
    become `static let` (immutable, satisfy the get-only requirements) instead
    of nonisolated mutable global state.
  - `OrderedTurnsMemo` is `nonisolated` to match the `@Model`-generated
    accessors that touch it; `WatchConnectivityClient` decodes on the delegate
    thread and hops only the `Sendable` `WatchReply` to the main actor; the
    background-task expiration handler is `@MainActor @Sendable`.
  - A few genuinely-safe SDK interop points (ActivityKit's non-`Sendable`
    `Activity` handed to its own `@concurrent` update/end, `AVCaptureSession`
    started off-main) use `nonisolated(unsafe)` with a comment explaining why
    each is safe by the framework's own contract.
  - The test targets stay nonisolated-by-default (a default-main-actor test
    module collides with XCTest's nonisolated base class); test classes that
    drive main-actor app code are marked `@MainActor`, which is accurate since
    XCTest runs them on the main thread.
  No behavior change — a build-system and concurrency-correctness migration only.

## [App 1.0 (53)] — 2026-07-18

### Added
- **Per-nutrient trend charts + multi-window coaching, from the bridge's
  `nutrientSeries`.** Consumes the additive `nutrientSeries` field (Bridge 0.21.0),
  degrading gracefully when it's absent/empty (the trend affordance simply hides).
  Carries the core rule end to end: **unknown is not zero** — every computation runs
  only over the days a nutrient key is present; a gap day is never a 0, never a day
  under a floor or over a ceiling, and coverage (days known / logged days in window) is
  surfaced next to every verdict.
  - **`NutrientTrends` — a pure, Foundation-only trend engine** (no SwiftUI, fully
    unit-tested), sitting beside `DietSemantics`/`FoodContributions`. Per nutrient +
    window it exposes the plottable known-day points (gap days absent, partial days
    flagged), coverage, the **median** (resists a single binge/fast day),
    floor `countUnderTarget`/`pctUnderTarget`, ceiling `countOverTarget`/`pctOverTarget`,
    target-kind median-distance, an informational distribution (median/min/max, never a
    pass/fail), and a **direction classified relative to the nutrient's kind**
    (floor rising = improving, ceiling rising = worsening; informational is neutral
    rising/falling; under 6 known days → "not enough data"). Plus a plain-language
    verdict, a top-sources ranker (reusing the drill-down contributor math, KNOWN
    contributions only), and the compact 7/30/all coach rollup.
  - **`TrendNutrient` — the single-source model for all thirteen nutrients**
    (`cal/p/f/c/fiber/na/satf/sug/k/ca/o3/mg/unsat`): full name, unit, kind
    (floor/ceiling/target/informational), target lookup, and the curated grounding copy
    (`whyItMatters` + `goodSources`) so no health claim is model-invented. Mirrors the
    `Macro`/`Micronutrient` display-name enums, guarded by tests.
  - **`NutrientTrendDetail` — the trend view** (Swift Charts, drawn in the
    `WeightTrendDetail` language): a 30d/90d/All range picker, drag-to-scrub, a
    kind-colored target rule, **visible gaps** (the line breaks across any missing day —
    a gap reads as "no data", never a dip to zero), partial days as hollow "at least
    this" points, and a summary band with the engine's verdict, the consequence copy,
    the top sources in range, and a "raise it with" hint for a short floor. Reached one
    tap deeper — a "View trend" row inside the existing contributors drill-down sheet,
    not top-level Health chrome (exactly like the weight trend behind the weight card).
  - **Coach multi-window grounding.** On a health/diet-relevant turn the app now folds a
    compact, plain-text nutrient rollup into `health_context` (composed alongside the
    HealthKit block, well under the bridge's 8 KiB cap): a framing sentence, one terse
    line per nutrient across 7/30/all (coverage-gated — "insufficient data" rather than a
    misleading number), and, for each standing problem (worst first), its consequence,
    the real top-contributing foods, and its good-source foods so the coach grounds a fix
    in real food. Truncates worst-first (informational dropped first) when oversized.

## [Bridge 0.21.0] — 2026-07-18

### Added
- **`nutrientSeries` on `GET /jesse/diet`** — one additive top-level field, a
  per-day, per-nutrient aggregate over `food-log.csv` history, for the app's
  per-nutrient trend charts and multi-window coaching. Built from the SAME
  single `food-log.csv` read as `weightSeries`/`availableDays` and attached to
  BOTH the today and history responses. A JSON array, one object per date
  ascending, capped to the most recent **90** dates (older dates dropped; the app
  labels the range). Each day is `{ date, nutrients: { <key>: { sum, known,
  unknown }, … } }` over keys `cal/p/f/c/fiber/na/satf/sug/k/ca/o3/mg/unsat`
  (`unsat` = `Fat_g − SatFat_g`, known only when both are known, clamped ≥ 0).
  **Unknown is not zero**, matching the rest of the micronutrient stack: a blank
  cell is an unknown contribution (excluded from `sum`, counted in `unknown`),
  never a 0; a nutrient with no known contributor on a day is OMITTED for that day
  (the app renders a gap), and a day with no known nutrient at all is omitted
  entirely. Targets/medians/trends stay the app's math, not the bridge's. A
  missing/unreadable `food-log.csv` yields `[]` (never null) plus one diagnostic in
  `errors`, the way `weightSeries` reports. Changes nothing else — today
  pass-through, per-item day reconstruction, targets, `weightSeries`, and the CSV
  are all untouched.

## [App 1.0 (52)] — 2026-07-18

### Added
- **Durably delete a thread's remote Claude Code session on thread-delete.** Swipe-
  deleting a thread still does the local SwiftData delete instantly (unchanged); if
  the thread had a bridge `sessionId`, that id is now enqueued into a persisted
  pending-deletions queue (`PendingSessionDeletionStore`, UserDefaults-backed — no
  schema migration) and a drainer calls `DELETE /jesse/session/{id}`. On success
  (including the bridge's idempotent 404) the tombstone is cleared; on a network
  failure it is retained for next time. The queue drains on enqueue and on
  `scenePhase → .active` (alongside `coordinator.resume` / `inbox.drain`), so a
  delete made while the laptop is asleep completes on the next foreground.
- **`JesseClient.deleteSession(_:)`** mirroring `send`'s URL/auth; a missing-session
  `404` maps to success (idempotent), exactly like `cancelJob`.

## [Bridge 0.20.0] — 2026-07-18

### Added
- **`DELETE /jesse/session/{session_id}` — delete one Claude Code session for the
  vault, scoped to the vault project only.** Same bearer auth as `/jesse`.
  **Idempotent** (mirroring `POST /jesse/cancel`): an unknown or already-gone id
  returns `204`, never an error, so the app's durable delete-drainer and the GC
  sweep can retry a missing id safely; a real failure to delete a file that exists
  is `500`; a structurally-invalid id (not a plain filename component) is `400`
  before it can reach the filesystem (path-traversal guard). Removes exactly
  `<home>/.claude/projects/<escaped-vault>/<session_id>.jsonl` and drops any stashed
  title for that session.
- **Age-based session GC sweep (`JESSE_SESSION_TTL_DAYS`, default 90).** A
  background task (one run at startup, then every 6h) reclaims vault-project
  sessions whose transcript mtime is older than the TTL. Resuming a session touches
  its mtime, so the sweep never reclaims an actively-used thread — only orphans
  (a failed remote delete, or anything deleted locally before the delete-on-thread-
  delete flow existed). Every reclaim is logged (id + age); it never deletes anything
  younger than the TTL and never steps outside the vault project. The age predicate
  (`is_session_expired`) is pure and tested against a fixed clock.
- **Resume-after-sweep safety.** A hosted turn whose requested session was swept
  (or deleted) now starts a **fresh session** cleanly instead of surfacing a raw
  `claude --resume <gone>` error: `resolve_resume_session` drops the `--resume` when
  the transcript no longer exists on disk, logs a named line, and the turn returns a
  new session id (the app keeps its local transcript). A synthetic `local-` id and a
  live real id pass through unchanged.

### Changed
- **`Config` now captures `HOME` once at startup (`cfg.home`).** Every session-path
  lookup (`sessions_dir`, `session_transcript_exists`, the GC sweep) reads `cfg.home`
  rather than the process env at call time. Behavior-identical in production (HOME is
  stable), and it makes the session paths deterministic and testable without mutating
  a process-global.

## [Bridge 0.19.0] — 2026-07-18

### Fixed
- **Local diet mirror now emits the SAME deterministic per-meal ids as the hosted
  logging skill.** The on-Studio mirror previously emitted one `JESSE_MEAL_LOG` meal
  PER food row with a positional id `<date>-<slot>-<HHMM>-<seq>`. That `seq` is not
  recomputable from the CSV, so a correction arriving via the hosted path computed a
  DIFFERENT id and duplicated the Apple Health entry; worse, now that app-side upserts
  are version-agnostic, a recurring `seq` across turns with different content could
  hash-rewrite the WRONG Health entry. `build_meal_log_from_food_rows` now GROUPS the
  turn's verified food rows by `(date, meal slot, HHMM)` into one mirror meal per group
  with id `<date>-<slot lowercased>-<HHMM>` (no seq) — byte-identical to the id the
  hosted contract computes for the same rows, and recomputable from the CSV alone, so a
  later correction or retraction targets the exact same Health entry. Each nutrient is
  summed in trusted Rust over the group's rows that carry a KNOWN value (kcal, protein,
  carbs, fat as plain sums; fiber and the six meal-wire micros summed over known rows
  only, the field OMITTED entirely when no row in the group carries it — unknown stays
  unknown, never a summed `0`). Model-side aggregation remains impossible by
  construction (the bridge sums, never the model). There is no `omega3` meal-wire field
  (no HealthKit EPA+DHA type), so nothing is summed for it. The 10-meals-per-block cap
  is now enforced on the group count (grouping only shrinks the block).
  - **Migration note (accepted, not fixed).** Meals already written to Health under the
    old `-<seq>`-suffixed ids stay stranded under those ids; a later correction to such
    a meal inserts under the new-format id and duplicates the Health entry. The window
    is small, so this is accepted rather than migrated.
- **The local extract pipeline is no longer correction-blind.** `no_loggable_content`
  was true only when a message logged nothing at all, so a keyword-bearing correction
  ("actually lunch was two bowls, about 700 kcal") could be extracted as a fresh log —
  appending a DUPLICATE row to `food-log.csv` (corrupting the source of truth) plus
  mirroring a new-id meal. The extract prompt and the `DIET_EXTRACT_SCHEMA`
  `no_loggable_content` description now instruct the child to set `no_loggable_content`
  true and return an empty `entries` array for any message that AMENDS, corrects, moves,
  or deletes something already logged, routing the turn to rung 2 (the hosted path,
  which owns the correction contract). The local path is insert-only by design; every
  correction takes the hosted path. No gate- or verify-level machinery was added — the
  existing rung-2 reason codes / metrics already measure how the extract children
  classify these turns.
  - Tests (red→green): same slot+time rows group into one summed meal with a seq-free
    id; micro sum discipline (known + unknown = the known value; an all-None group
    serializes no key) for fiber and every micro; different slots/times stay separate
    meals; exact id equality with the hosted `<date>-<slot>-<HHMM>` format; the
    10-meal cap enforced on group count after grouping; the extract prompt/schema carry
    the amendment rule. Existing per-row / seq-id assertions were flipped to match.

## [App 1.0 (51)] — 2026-07-18

### Changed
- **Enable `JESSE_MUTE=1` by default in the shared `Jesse` scheme's Run environment**,
  so local Xcode/`xcodebuild` debug launches (Run, Test, Profile — all inherit via
  `shouldUseLaunchSchemeArgsEnv`) no longer speak aloud or duck other audio. Scheme
  environment variables apply only to debug launches, never to installed/TestFlight
  builds, so shipped builds speak exactly as before.

## [App 1.0 (50)] — 2026-07-18

### Added
- **`JESSE_MUTE` dev flag to silence spoken (TTS) replies without muting the Mac.**
  Setting `JESSE_MUTE=1` in the run scheme's environment makes `Speaker.speak` a
  no-op that returns before activating the audio session — so it never ducks other
  audio and never reaches the synthesizer. The flag defaults off (env unset), so
  production behavior is unchanged; it is injectable through the initializer for
  deterministic tests. A dev/debug convenience, not a user-facing setting.

## [App 1.0 (49)] — 2026-07-18

### Added
- **Three more tracked micronutrients on the Health tab plus one derived — calcium,
  omega-3 (EPA+DHA), magnesium, and unsaturated fat — end to end, mirroring the four-micro
  pattern (build 40) exactly with the same unknown ≠ zero discipline.** The `GET /jesse/diet`
  per-item snapshot gains three OPTIONAL gauge fields (`ca` mg, `o3` mg, `mg` mg) and three
  OPTIONAL day targets (`calcium` 1200, `omega3` 500, `magnesium` 400); a missing value is
  UNKNOWN, never summed or shown as 0, and stays OUT of the `MacroTotals`/`total(of:)`
  nil→0 path. `DietSemantics.micronutrientGauge` builds calcium, omega-3, and magnesium as
  **floors** (like potassium — met / short by N) and **unsaturated fat** as an
  informational, DERIVED gauge (`fat − saturated fat` over items whose saturated fat is
  KNOWN — an unknown-satf item makes the day partial, never zero), value-only and never
  judged like total sugars. Each preserves unknowns: a partial total renders `≥sum` with an
  *"N items not estimated"* caption; a nutrient no item carried shows *"not tracked yet"*;
  an absent target shows the value only. Calcium, magnesium, and omega-3 join the standalone
  **Micronutrients** section; unsaturated fat nests under Fat beside saturated fat. Tapping
  any of the four opens the SAME shared drill-down sheet (sorted contributors, "Not estimated"
  group, `≥` partial header, share-of-known-total, grounded on-device insight with the
  informational judgment-forbid for unsaturated fat). Their full display names (`Calcium`,
  `Omega-3 (EPA+DHA)`, `Magnesium`, `Unsaturated Fat`) live in the one `Micronutrient` enum,
  guarded by `MacroLabelTests`.
- **HealthKit meal write-back for calcium and magnesium only.** A logged meal now carries
  `calcium_mg` and `magnesium_mg` (each the sum of only its known items, nil when none),
  threaded from the `meal_log` wire through `Meal` and written as additional samples on the
  meal's existing `.food` correlation — `dietaryCalcium` and `dietaryMagnesium` (both in mg).
  A nutrient with no known value writes NO sample (never a 0), and the delete-then-rewrite
  correction path enumerates the present sample types (now up to eleven), so the two new
  types flow through a rewrite. The share (write) set grows from nine to eleven to authorize
  them. **Omega-3 is gauge-only** — there is no HealthKit EPA+DHA type (`dietaryFatPolyunsaturated`
  includes plant ALA), so it is never a meal field and writes no sample; unsaturated fat is
  derived and likewise never written.

## [Bridge 0.18.0] — 2026-07-18

### Added
- **Three more diet micronutrients end to end — calcium, omega-3 (marine EPA+DHA),
  and magnesium — same unknown-is-not-zero discipline as the existing four.** The
  food-log CSV grows three trailing columns (`Calcium_mg`, `Omega3_mg`,
  `Magnesium_mg`), so the header is now 22 columns. As with sodium/satfat/sugar/
  potassium, a value the message or label never established stays *absent* at every
  stage — omitted extract key, `None` in the struct, blank CSV cell, omitted wire
  field — and is **never** `0` standing in for "did not know".
  - **Read path (`GET /jesse/diet`).** `reconstruct_meals` emits three new per-item
    GAUGE fields — `ca`/`o3`/`mg` — via `opt_num` (blank/unparseable/absent → JSON
    `null`, never `0`). A legacy short row that ends before the new columns reads them
    as null and still parses.
  - **Write path (extract → verify → append).** `FoodEntry` gains `calcium_mg`,
    `omega3_mg`, `magnesium_mg`; the extract schema/prompt add the three keys with the
    fill-only-from-a-label-or-confident-estimate rule. Omega-3 is defined as marine
    long-chain **EPA+DHA only** (fish, shellfish, roe, small amounts in eggs/dairy) —
    never the plant ALA in walnuts, flax, chia, or vegetable oils, and omitted for a
    plant-ALA-only food. Calcium and magnesium, like potassium, are usually absent on
    EU labels and so usually omitted. The verifier corrects only the five macros; the
    new micros carry through a correction untouched.
  - **Apple Health mirror (`JESSE_MEAL_LOG`).** Only the HealthKit-bound micros ride
    the meal wire: `calcium_mg` and `magnesium_mg` are added to the meal allowlist and
    the `Meal` struct (finite, non-negative, explicit `null` rejected, omitted when
    unknown). **Omega-3 has no HealthKit type** (`dietaryFatPolyunsaturated` includes
    ALA, wrong for EPA/DHA), so it is deliberately NOT a meal field — the derived
    off-phone mirror populates calcium and magnesium only.
  - Unchanged by design: `MacroTotals`/`sum_food_csv_for_date` (blank-means-0, correct
    only for the five macros), the ASCII dashboard, and the today pass-through path.
  - Tests: read-path null-vs-number round trips and legacy-short-row; header/row parity
    at 22 columns; parse accepts all three / a subset / none and still rejects an
    out-of-schema key loudly; blank-stays-unknown round trip; the full 22-cell row;
    verify carry-through keeps `calcium_mg`; the meal wire accepts calcium/magnesium on
    v1 and v2, rejects null/negative, and rejects `omega3_mg` as an unknown key; the
    derived mirror serializes calcium/magnesium when known and omits them when not.

## [App 1.0 (48)] — 2026-07-17

### Added
- **A send outbox so a message can't be silently lost before the bridge ACKs.**
  The bridge acknowledges `POST /jesse` immediately with `202 {job_id}`, and
  everything after that ACK was already recoverable (persisted `InFlightJob`,
  Re-check, foreground resume). But *before* the ACK — a timeout, a dead network,
  a 429/5xx, or the app being suspended/killed mid-POST — the message was lost, and
  the full-resolution attachment bytes with it (only thumbnails persist; the
  composer clears its staged bytes at send). Now every send persists an outbox
  record first and deletes it at the ACK.
  - **Two new SwiftData models** (`OutboxItem` + `OutboxAttachment`), added as
    schema **V2** with a lightweight `V1 → V2` migration stage (they're additive,
    fully-defaulted entities). `OutboxItem.id` IS the wire `request_id`;
    `OutboxAttachment` holds the ORIGINAL (staged, post-downscale, always-sendable)
    bytes in external storage.
  - **`request_id` on `POST /jesse`** (`JesseClient.send(…, requestId:)`), so a
    Retry re-sends with the SAME key and the bridge dedups a POST that actually
    landed (one turn, not two). Other call sites (watch relay, health-context
    retry) pass nil; a bridge without the field ignores it, so the bytes are
    unchanged when it's absent.
  - **Stage → transmit** in `RunCoordinator.send`: the optimistic user turn and its
    `OutboxItem` are created in one save; the transmit deletes the item on any
    success (a `.running` 202 or the legacy inline `.reply` 200) and hands off to
    the unchanged InFlight/consume/Re-check machinery. A pre-ACK throw preserves the
    message as `.failed` (a pre-ACK cancel too, which used to vanish silently) —
    WITHOUT the thread-level error banner, which the per-message UI now owns.
  - **`reconcile`** (run on resume, before re-attach) recovers the app-killed-
    mid-POST case: a still-`.sending` item is deleted if the persisted job carries
    its `request_id` (the ACK won the race) or flipped to `.failed` ("Jesse never
    received this.") otherwise.
  - **Manual, per-message Retry / Discard — never automatic.** A failed user bubble
    shows a compact "Not delivered" line (orange, matching the Re-check affordance)
    with Retry (re-runs the transmit reusing the same turn and request_id) and
    Discard (removes the message, and an empty sessionless thread with it). The
    composer stays enabled with failed messages present; the conversation list
    badges rows that have any undelivered message.

## [App 1.0 (46)] — 2026-07-17

### Changed
- **An oversized photo now downscales to fit instead of erroring.** Attaching an
  image whose original file already exceeded the 10 MB per-file cap failed with
  "… is too large (max 10 MB per file)" on every entry path (composer paste,
  paperclip file import, camera capture) — they all stage through one shared
  `addAttachment` funnel. Now, when a staged **image** is over the cap, it's
  re-encoded to a smaller JPEG that fits, silently — no error, no prompt, no
  Settings toggle.
  - **New `AttachmentDownscaler`** — a pure, `nonisolated`, testable decision +
    transform unit. `fitToCap(_:cap:)` re-encodes an over-cap decodable image as a
    JPEG (quality 0.85), stepping the longest pixel edge down (×0.8 per iteration,
    floored) until it lands under 90 % of the cap so a boundary result doesn't
    flap. EXIF orientation is applied (ImageIO transform → upright pixels), so the
    result arrives right-side-up. Output is always JPEG regardless of input, and
    the display name gets a `.jpg` extension.
  - **Byte-verbatim invariant preserved (PR #51).** The very first check is
    "already under the cap?" — if so it returns `nil` and the original bytes stage
    untouched, never decoded or re-encoded. Downscaling triggers *only* when the
    original bytes exceed the cap.
  - **One shared spot.** The re-encode lives in `addAttachment`, so paste, photo
    picker, file import, and camera all behave identically — no new paste/picker
    divergence (PR #51's root cause).
  - **Images only.** An over-cap PDF (or any non-image) is left untouched and the
    existing size cap rejects it exactly as before; rasterizing PDFs is out of
    scope. The total (20 MB) and file-count (4) caps are unchanged — downscaling
    satisfies the per-file cap only.
  - Tests (failing-first): an oversized synthetic image stages under the cap,
    decodes valid, and shows its dimensions stepped down; orientation is applied
    (a rotated fixture decodes upright); under-cap inputs (image and PDF) return
    `nil` so staging stays byte-verbatim; an over-cap PDF and an undecodable image
    are not downscaled; cap edges on both sides; the filename swaps to `.jpg`. The
    existing `PasteAttachmentTests` are untouched.
  - Build **44 → 46**.

## [Bridge 0.17.0] — 2026-07-17

### Added
- **Idempotency key for `POST /jesse` — a client that never saw the `202` can safely
  re-send.** `POST /jesse` returns the `job_id` on the first response and the turn runs
  detached; if the network drops before that response reaches the phone, the old contract
  had no way to recover — a retry would spawn a *second* turn (double the tokens, a second
  vault write). A new optional `request_id` field closes that: re-sending the same request
  with the same key returns the ORIGINAL job instead of starting a new one.
  - **Wire contract.** `POST /jesse` gains an optional `"request_id"` (string). Validated
    when present: at most 64 chars, ASCII alphanumerics and hyphens only — anything else is
    a `400 {"error":"…"}`. **Absent `request_id` reproduces today's behavior exactly**
    (old app builds simply omit it) — every POST is a fresh turn.
  - **Dedup semantics.** A `request_id` already mapped to a **live** job (queued, running,
    or a terminal result still inside its retention window) short-circuits: the bridge
    creates nothing, takes no concurrency permit, enqueues nothing, and returns
    `202 {"job_id":"<existing>","status":"running"}` — the exact shape of a fresh accept.
    The client then streams/polls that id as normal (a job that already finished satisfies
    the first poll immediately). A `request_id` whose job has been **reaped** is treated as
    brand new. Auth and rate limiting apply first, unchanged.
  - **Concurrency-safe.** The `request_id → job_id` index lives under the job store's one
    `jobs` lock; the check-and-insert happens at job creation, so two concurrent duplicate
    POSTs can never both spawn — they collapse to a single job. The index is rebuilt from
    persisted jobs at startup and pruned wherever a job is evicted, so a mapping can never
    outlive its job.
  - **Persistence.** The `request_id` is persisted with the completed job and reloaded on
    restart (the dedup index is rebuilt from it). Job files written before this field —
    which lack the key entirely — still load unchanged, with no mapping.
  - Tests: same key twice (one spawn, same id), two concurrent duplicates (one job),
    dedup against a completed job (returned id fetches the finished result), reaped mapping
    treated as new (and the index pruned), absent-key regression (distinct jobs), invalid
    key `400`, and a persisted round-trip that rebuilds the index (old files still load).

## [App 1.0 (44)] — 2026-07-17

### Changed
- **Versioned the SwiftData schema and stopped silently losing history on a store
  failure.** `AppModelContainer` opened the store with `try?` and, on any failure,
  substituted an *empty in-memory store* with only a log line — so a migration that
  ever failed on a populated device would swap the user's whole conversation history
  for a blank slate with no signal. Two root-cause fixes:
  - **No more silent fallback.** A failed on-disk open now surfaces as
    `AppModelStore.openFailure`; the app runs on a clearly *flagged* in-memory
    fallback for the session (a non-dismissible banner: "Couldn't open your saved
    conversations… this session won't be saved") and the on-disk file is left
    **untouched** — never overwritten or deleted — so the data stays recoverable.
  - **A versioned schema + migration plan.** The model list is now a
    `VersionedSchema` (`JesseSchemaV1`) opened through a `SchemaMigrationPlan`
    (`JesseMigrationPlan`) — the structural, testable home for future migrations.
    The historical additive changes (`isFavorite`, `favoritedAt`,
    `lastDeliveredJobId`, `aiTitle`, `titleSourceKey`, `origin`, `provenanceJSON`,
    the `attachments` relationship, `TurnAttachment`, `WrittenMeal`) are all
    lightweight-compatible, so the plan is a documented single-version scaffold.
  - **Coverage for the path that had none.** New `AppModelContainerMigrationTests`
    populate an on-disk store the pre-versioned way (threads, turns, attachments,
    favorites, a WrittenMeal), reopen it through the real loader, and assert every
    field survives (favorites still favorited, `aiTitle`/`origin`/`lastDeliveredJobId`
    intact, a Turn's `provenanceJSON`, an attachment's thumbnail bytes) — plus a test
    that a corrupt store is *flagged* (not swallowed) and its bytes left intact.

## [App 1.0 (43)] — 2026-07-17

### Added
- **Meal-correction propagation in Apple Health — the app half of `JESSE_MEAL_LOG v2`
  (upsert + retract).** Phase 3 wrote meals insert-only: once an id was written it was
  skipped forever, so a correction made outside an app turn never reached Health. The app
  now applies the bridge's v2 corrections (Bridge 0.16.0): it detects a *changed* meal and
  rewrites its Health entry, deletes a *retracted* one, and acks what it has applied so the
  bridge prunes its queue.
  - **Parser** (`MealLogParser.batch`): validates a delivered `meal_log` into a domain
    `MealBatch` (upserts + retracts + `corrections_seq`), reusing the existing per-meal
    validation. Caps (≤10 meals, ≤10 retracts), atomic rejection (a blank field, an
    unparseable date, a bad nutrient, or the same id in both arrays rejects the WHOLE
    batch), v1 compat (an all-upsert batch), and the streaming scrubber now hides a v2
    sentinel too while leaving v3+ visible.
  - **Idempotency store upgrade** (`WrittenMeal`): gains a per-id **content hash** (a
    SHA-256 over `consumedAt`, `name`, and every PRESENT nutrient — absent canonically
    excluded, so absent ≠ 0 and a meal gaining its first sodium estimate rewrites exactly
    once) and a **tombstone** flag. Additive, lightweight SwiftData migration; existing
    rows read as hash-unknown and rewrite once on next sight. The hash iterates a fixed
    canonical field order, so a future nutrient never needs a store migration.
  - **HealthKit upsert/retract** (`HealthKitMealWriter`): unseen → insert; same hash →
    skip; changed hash → delete the app's correlation (found by its meal-id external
    identifier) **and its contained quantity samples** (up to nine — correlation deletion
    does not cascade) then rewrite; retract → delete + tombstone. A tombstoned id ignores a
    stale re-insert but a differing hash revives it (a re-logged meal wins). Only ever
    deletes samples the app itself wrote — never another source's data.
  - **Ack + durability**: after fully applying a delivered batch the app advances a
    monotonic `meal_corrections_ack` sent on the next `POST /jesse`; on a HealthKit failure
    the unapplied remainder is enqueued (upserts AND retracts) and the ack is **withheld**,
    so the bridge redelivers (app-side id+hash idempotency makes that harmless). The
    "Write meals to Apple Health" toggle governs corrections too — off means deliveries are
    acked (so the bridge stops redelivering) but not applied (Health is a mirror only while
    on). No new toggle.
- Build **42 → 43**. Tests (failing-first): the parser matrix (v2/retract/caps/v3/hash),
  the store migration (new fields default; hash-unknown triggers one rewrite), the upsert
  matrix (insert/skip/rewrite/retract/tombstone/revival/stale-replay/meal-move/micronutrient-
  only), the transactional ack (advanced on success, withheld on failure, acked-not-applied
  when off), the pending-batch drain + legacy `[Meal]` migration, and the wire decode +
  byte-pinned `meal_corrections_ack` request.

## [Bridge 0.16.0] — 2026-07-16

> Version note: `0.15.0` is the concurrent local diet-extract pipeline work (#84,
> now on `main`); this change is independent and takes the next minor, `0.16.0`.

### Added
- **Meal-correction propagation — `JESSE_MEAL_LOG v2` with upsert + retract, and a
  persisted corrections queue so corrections made OUTSIDE an app turn still reach Apple
  Health.** Phase 3 shipped meals insert-only: once an id was written it was skipped
  forever, so a correction made in a desktop/Cowork logging session (no app turn, no
  reply to carry a block) never propagated. This closes that gap on the bridge side; the
  app-side delete-and-rewrite lands in a following app release.
  - **v2 contract (trailing-sentinel, same rules as v1, version bumped).**
    `JESSE_MEAL_LOG v2 {"meals":[…],"retract":[…]}`. `meals` are **upserts** keyed on
    `id` (unseen → insert; same content → skip; changed → the app deletes the prior
    Health entry and rewrites it). `retract` (optional, cap 10) lists ids the source
    deleted — the app removes their Health entry and tombstones the id. A **meal move** is
    a retract of the old id plus an upsert of the new id (ids embed the meal time), so the
    same id in both arrays is malformed (passthrough + log). v1 stays accepted unchanged;
    **v3 and up pass through visible** (a future bump fails loud). The nine tracked
    nutrient fields are unchanged and v2 is **field-agnostic** over them — a future
    nutrient is an additive optional field, never a v3.
  - **Persisted corrections queue + endpoint.** A new LAN-only, bearer-authed
    `POST /jesse/meal-corrections` accepts a v2 batch (validated against the exact same
    contract as an in-reply directive) and persists it to
    `<state_dir>/meal-corrections-queue.jsonl` with a monotonic batch `seq` (survives
    restart and a fully-drained queue). It carries meal events **generally** — off-phone
    inserts as much as corrections and retracts.
  - **At-least-once delivery, ack, prune.** On every terminal result (poll and SSE `done`
    alike) queued batches are merged into the outgoing `meal_log` **ahead of** any block
    the turn's own reply produced, collapsed net per-id (last-op-wins, so the delivered
    payload never lists an id in both arrays and a retract-then-relog nets to the relog),
    with the highest queued `seq` stamped as `corrections_seq`. The app echoes
    `meal_corrections_ack` on a subsequent `POST /jesse`; the bridge prunes batches at or
    below it. Unacked batches redeliver every turn (app-side idempotency makes that
    harmless). Queue cap **100** — a post at the cap is rejected `429` (a visible failure
    at the source beats a silent drop); every enqueue, delivery, ack, and prune is logged.
  - **Local diet mirror unchanged in shape.** `build_meal_log_from_food_rows` constructs
    the same insert-only v1-shaped block (empty `retract`, no `corrections_seq`); the four
    micronutrient columns remain omitted pending the vault-side CSV rollout.
  - Docs: `SECURITY.md` gains the endpoint + queue (external logging-agent input, same
    trust class as reply text). Failing-first tests cover v2 extraction (with/without
    retract, retract-only, caps, same-id-in-both), v1 compat, v3 passthrough, queue
    persistence across restart, merge ordering + net-per-id collapse, ack pruning,
    redelivery, and cap rejection.

## [Bridge 0.15.0] — 2026-07-16

### Fixed
Four root-cause fixes to the local diet-extract pipeline, downstream of correct
model comprehension. The 2026-07-15 investigation found the extract child (DeepSeek
V4 Flash via `local-diet`) identified the food/exercise in ~17 of 20 rung-2 turns;
the pipeline then rejected its output. Projected effect: ~13 of the 20 observed
rung-2 turns convert to local logs. **Fixtures reproduce the documented CLI-child
failure shapes** (missing time, null macros, fenced JSON); the read-only investigation
archive was not accessible from the dev host, so replays were reconstructed faithfully
rather than byte-copied.

- **The bridge owns received-at time, not the model.** The extract child runs toolless
  with a neutral cwd, so it has **no clock** — yet the schema/prompt required a per-entry
  `time` and the parser rejected an absent one. "ate 1 almond" (no stated time) was a
  **deterministic rung-2 schema-fail** (3/3 reruns); guessing produced invented times
  (a ~17:44 snack stamped 15:00 at go-live). `time` is now optional; the model returns
  one **only** when the message states an explicit clock time (never invents), and at
  append the bridge stamps any unstated food time with the turn's received-at wall clock
  (local `HH:MM`). An explicit time always wins; the fill flows through the normal
  row + mirror path, so dashboard/Apple-Health re-derivation is unchanged.
- **JSON `null`/empty string now mean absent for optional macros.** The prompt says omit
  unknown macros; the model nulls them instead. `opt_num_field` rejected a null as "not a
  number", schema-failing a correct entry to rung 2 (the dominant failure, with missing
  time). Null and empty/blank strings are now absent (`None`), the same as an omitted key;
  a literal `0` stays a measured zero; required fields stay strict.
- **A full markdown code fence is stripped before parsing.** The parser did `json.loads`
  on the trimmed raw with no fence handling; through the production CLI child the model
  wraps its JSON in a ` ``` `/` ```json ` fence on some turns, parsing as invalid JSON
  (3/20 rung-2). `strip_code_fence` unwraps **only** a full outer fence; backticks inside
  a JSON string value, and any not-fully-wrapped payload, are never touched.
- **Every rung-2 fall-through now carries a machine-readable reason.** The five causes
  (`child_error`, `malformed_json`, `schema_fail:<field>`, `empty_entries`, `no_loggable`)
  collapsed into one indistinguishable line, so the daily audit could not tell a pipeline
  FAILURE from a **correct rejection** of a non-loggable turn (3/20 rung-2 turns were
  correct rejections the loose keyword gate let in). The reason threads through the
  provenance line and the metrics JSONL (content-free — a code plus the schema field,
  never meal text or the token); the audit counts rung-2 by reason and reports two rates
  (raw, and failure-only excluding `no_loggable`). The README graduation criteria gain a
  clearly-marked PROPOSAL (not a change) that the 5% bar count only loggable-content turns.

The kill switch is unchanged: with the `JESSE_DIET_*` triple unset the pipeline is
dormant and every diet turn takes the hosted path byte-for-byte.

## [App 1.0 (42)] — 2026-07-16

### Changed
- **The nutrient list now mirrors a food label: saturated fat and total sugars render as
  indented sub-entries of their parent macro, not as flat micronutrients.** A food label
  declares "of which sugars" and "of which fibre" under Carbohydrate and "of which
  saturates" under Fat; the Macros & calories screen now reads the same way — **Protein,
  Carbs, Fiber, Total Sugars, Fat, Saturated Fat** — with the Micronutrients section
  reduced to the two standalone minerals, **Sodium and Potassium**. This is a
  presentation change only: no displayed number, unknown-aware split, gauge direction,
  drill-down, HealthKit write, wire/CSV id, or `DietSemantics` total changes.
  - **One sub-entry model across both enums.** `Micronutrient` gains `parent`/`isSubEntry`
    (total sugars → carbs, saturated fat → fat; sodium and potassium have no parent),
    mirroring `Macro.parent` (fiber → carbs). A single `NutrientOrder.macroArea` derives
    the canonical row order from those links — the one source the order tests assert
    against — and `NutrientOrder.minerals` is the standalone set. The Macros screen (both
    the judged and the reconstructed-day bodies) iterates that one ordered sequence.
  - **Gauges are untouched by the move.** Saturated fat stays a CEILING with full
    unknown-aware rendering (partial `≥`, "N items not estimated", "not tracked yet");
    total sugars stays INFORMATIONAL with no target and no judgment; fiber stays a FLOOR.
    Each still opens the same shared `ExplainerSheet`/`FoodDrilldown` from its new position.
  - **A real leading indent for every sub-entry.** Fiber, total sugars, and saturated fat
    are now inset on the list/row surfaces (Macros screen bars and the reconstructed-day
    totals) via one shared `NutrientRowLayout`, driven only by `isSubEntry`, so a sub-entry
    visually sits inside its parent — nutrition-label style. The indent is a grouping cue
    only: the equal-peer ring row is NOT indented and no child is drawn as a proportional
    slice of a parent's bar (an EU label's declared carbohydrate excludes fibre, so each
    child keeps its own independent gauge).
  - **Parent-derived sub-entry colors.** Saturated fat and total sugars now take a lightened
    shade of their parent macro's identity color (fat orange, carbs teal) in the drill-down
    bars — the same derivation fiber uses — resolved per color scheme and kept opaque.
    Sodium and potassium keep their own distinct mineral hue.

### Added
- **A short, fixed, plain-language education explainer for each of the four
  micronutrients**, surfaced as a subordinate callout in the drill-down sheet — distinct
  from the streamed on-device insight (which is about today's foods) and never a number.
  Deterministic editorial copy stored on `Micronutrient.education`, stating each nutrient's
  direction correctly: sodium and saturated fat as ceilings (with the salt→sodium and
  "saturated fat is a sub-budget of total fat, the rest of your fat is fine" lessons),
  potassium as a floor to reach (and why a low reading usually means "unmeasured, not
  none"), total sugars as informational with no target and no judgment.

## [App 1.0 (41)] — 2026-07-16

### Added
- **Tapping any of the four micronutrient gauges opens the SAME shared drill-down sheet
  the five macros use — one component, extended with unknown-aware semantics.** Before,
  the four micro rows (sodium, saturated fat, total sugars, potassium) rendered but did
  nothing on tap. Now each opens the existing `ExplainerSheet`/`FoodDrilldown` — the same
  contributing-foods facts, streamed on-device insight, ShareLink export, and text
  selection the macro/calorie drill-down (PR #74) ships — with the micronutrient rule
  **unknown ≠ zero** carried all the way through:
  - `ContributionMetric` gains a `.micronutrient` case; a micronutrient breakdown ranks
    the day's items with a known value > 0 by contribution (a measured true 0 is a
    non-contributor, excluded), and every item **lacking** a value is surfaced in a
    distinct **"Not estimated"** group — name and amount, never a number, never a 0.
    These rows are why a partial total reads `≥`, so they are never silently omitted.
  - The sheet header mirrors the gauge exactly: a partial day shows `≥<knownSum><unit>`
    with the *"N items not estimated"* caption; an all-unknown nutrient shows *"not
    tracked yet"* and still opens (every item under "Not estimated", no invented total);
    a target frames consumed-vs-target by the nutrient's semantics (ceiling for sodium /
    saturated fat, floor for potassium); no target shows the value only. Total sugars
    stays informational — the number, never a judgment. Each contributor's share is
    computed against the KNOWN sum, so a partial day never presents a share as if the
    denominator were complete.
  - The on-device insight grounding (`HealthInsightInput`) is extended with the
    deterministic partiality facts — `partial`, `knownItemCount`, `unknownItemCount`,
    and, only when a target exists, the target plus its computed status — plus an
    `informational` flag for total sugars (grounded WITHOUT a target). The prompt states
    a partial total is a floor ("at least"), forbids any completeness claim, and for
    total sugars forbids all judgment. The post-generation discard guard grows to match:
    a generation that claims a partial total is complete, or renders a judgment for total
    sugars, is discarded and the facts stand alone (a wrong insight is worse than none).
  - The plain-text ShareLink export carries the `≥` notation, the *"N items not
    estimated"* caption, and the full "Not estimated" item list, so a partial sodium day
    never pastes into a chat as a bare complete-looking number.

## [Bridge 0.14.0] — 2026-07-15

### Added
- **Diet micronutrient write path — the four micronutrients now get written, not
  just read.** The read side already understood `Sodium_mg`, `SatFat_g`, `Sugar_g`,
  and `Potassium_mg` (0.12.1) and the app renders them into HealthKit (build 40), but
  nothing the bridge logged ever filled the cells. Now the whole local diet pipeline
  carries them end to end:
  - `FOOD_LOG_HEADER` extends to the 19-column contract; `food_row` writes the four
    trailing cells (blank when unknown).
  - `FoodEntry` gains `sodium_mg`/`satfat_g`/`sugar_g`/`potassium_mg` (`Option<f64>`),
    and the extract schema + prompt gain the four keys with unit/conversion guidance
    (sodium in mg — EU "sale" salt-grams × 400; `satfat_g` = "di cui acidi grassi
    saturi" in g; `sugar_g` = TOTAL "di cui zuccheri" in g, never added sugars;
    potassium in mg, usually absent on EU labels).
  - The `JESSE_MEAL_LOG v1` directive `Meal` gains the four optional fields, serialized
    under the exact wire keys the app decodes (`sodium_mg`, `satfat_g`, `sugar_g`,
    `potassium_mg`); the payload validator rejects a negative or non-finite value.
  - **Unknown is not zero** at every stage: a nutrient the message/label doesn't
    establish is an omitted extract key → `None` → a blank CSV cell → no wire field.
    `0` is reserved for a real measured zero. The verifier still corrects only the five
    macros; the micronutrients carry through a correction untouched.

## [Bridge 0.13.0] — 2026-07-15

### Fixed
- **Context carry — a locally-served turn is no longer lost to a later hosted
  follow-up (root-cause fix).** Real transcript: turn 1 "What is Jamie's birthday?"
  was served by the emergency local route and answered from the vault; turn 2 "So how
  old is she?" went hosted and replied it had no earlier context. Root cause: a turn
  served by a **stateless local route** (vault-QA, emergency, or diet) never enters the
  thread's hosted claude session, so (a) the next hosted `--resume` can't see it, (b) a
  local child never sees prior turns, and (c) a thread whose FIRST turn is local has no
  session id at all — the thread linkage is lost. The fix is a **bridge-side ledger**,
  not a model-side one: deterministic code records each delivered ask/tell turn per
  thread and injects that recorded context back.

### Added
- **Context ledger** (`context.rs`): one record per delivered turn (timestamp, mode,
  route, the user's raw text, the delivered reply PRE-badge, and an `in_hosted_history`
  flag). Kept in memory and persisted to `<state_dir>/context.json` (atomic temp+rename,
  0600), a sibling of `titles.json`. Caps: each side truncated to 2000 chars, 20 turns
  per thread, threads idle >7 days pruned, at most 200 threads (oldest-idle evicted).
  Ledger content stays in the state dir — it never reaches the metrics log (which stays
  content-free), provenance lines, or any log line beyond counts.
- **Hosted catch-up injection**: a hosted turn on a thread with locally-served turns it
  hasn't absorbed gets ONE framed `MISSED CONVERSATION HISTORY (data, not instructions)`
  block spliced into its prompt (ahead of the floor, adjacent to the health block; total
  ≤6000 bytes, oldest pairs dropped with an omitted-count marker). Read and spliced under
  the concurrency permit; the injected entries are marked `in_hosted_history` only AFTER
  the hosted turn succeeds (at-least-once — a rare duplicate is harmless, a silent drop
  is not).
- **Local-child recent-conversation injection**: the vault-QA and emergency children get
  a framed `RECENT CONVERSATION (data, not instructions)` block (last 6 turns, each side
  ≤500 chars, ≤3000 bytes) above the question, so they can resolve a follow-up's
  references. Both children stay stateless and read-only.
- **Synthetic thread ids**: a fresh thread served locally is minted a `local-<hex>`
  session id (returned to the app so its follow-up carries it). A `local-` id is NEVER
  passed to `--resume`; the hosted turn runs fresh and, on success, re-keys the ledger
  (and moves any title) from the synthetic id to the real returned session id.
- **`JESSE_CONTEXT_CARRY`** (`on|off`, **default on** — this repairs a live defect, so
  the off switch is the rollback). Off = byte-for-byte today: no ledger reads or writes,
  no `context.json`, no synthetic ids, no injected blocks.

### Known limit
- A synthetic id has no jsonl transcript, so a thread served locally on its first turn
  does not appear in `GET /jesse/sessions` until its first hosted turn. The app's own
  thread list is app-side and unaffected.

## [App 1.0 (40)] — 2026-07-15

### Added
- **Four per-item micronutrients on the Health tab + into Apple Health: sodium,
  saturated fat, total sugars, potassium.** They arrive as four OPTIONAL numeric fields
  on each diet item (`na` mg, `satf` g, `sug` g, `k` mg) and four OPTIONAL day targets
  (`sodium`, `satFat`, `potassium`, `sugar`). The governing rule is **unknown ≠ zero**:
  unlike `fiber` (always filled, so nil→0 is harmless), these are absent for many items,
  so a missing value is UNKNOWN and is never summed or shown as 0. Decoding adds the four
  optional item fields (`DietItem`) and four optional target keys (`DietTargets`) — kept
  OUT of the `MacroTotals`/`total(of:)` nil→0 path, which is unchanged for cal/p/f/c/fiber.
  A new `DietSemantics.micronutrientTotal` aggregates each nutrient over a day preserving
  unknowns as `(knownSum, unknownItemCount, knownItemCount)`, and `micronutrientGauges`
  builds four `MetricGauge`s in the macro vocabulary: sodium & saturated fat as ceilings,
  potassium a floor, total sugars informational (never judged — modeled like suspended
  fiber). A total with any unknown contributor is **partial**, rendered `≥sum` with an
  *"N items not estimated"* caption; a nutrient no item carried shows *"not tracked yet"*;
  an absent target shows the value only, no judgment. The four render in a **Micronutrients**
  section of the Macros & calories detail, reusing the existing macro `MetricBarRow`. Their
  full display names (`Sodium`, `Saturated Fat`, `Total Sugars`, `Potassium`) live in one
  place — a new `Micronutrient` enum, mirroring `Macro` and guarded by `MacroLabelTests`.
- **HealthKit meal write-back for the four micronutrients.** A logged meal now carries the
  four (each the sum of only its known items, nil when none), threaded from the `meal_log`
  wire (`sodium_mg`/`satfat_g`/`sugar_g`/`potassium_mg`) through `Meal` and written as
  additional samples on the meal's existing `.food` correlation — `dietarySodium` /
  `dietaryFatSaturated` / `dietarySugar` / `dietaryPotassium` (sodium & potassium in mg,
  fats & sugar in g). A nutrient with no known value writes NO sample (never a 0). The
  share (write) set grows from the five macros to nine to authorize them; the existing
  kcal/protein/carbs/fat/fiber samples and the weight/workout read-only posture are
  untouched.

## [Bridge 0.12.1] — 2026-07-15

### Added
- **Four reconstructed micronutrients on past-day meals.** `food-log.csv` gained four
  trailing columns — `Sodium_mg`, `SatFat_g`, `Sugar_g`, `Potassium_mg`. On a
  RECONSTRUCTED past day (`GET /jesse/diet?date=…` with no archived copy), each meal
  item now carries `na`, `satf`, `sug`, and `k` built from those columns in
  `reconstruct_meals` (`bridge/src/diet.rs`), addressed by header **name** (the log is
  ragged). Unlike `fiber`/`p`/`f`/`c`, a blank or unparseable cell stays JSON `null`
  (via `opt_num`), because for these a blank means **unknown**, not zero. The TODAY
  pass-through path already forwards `diet-today.js` verbatim, so it needed no change;
  a legacy short row that predates the new columns still parses (the missing cells read
  `null`, not malformed). Reconstructed days carry no targets, so no target work.

### Added
- **Structured provenance on every delivered reply (model-badge v2).** Alongside the
  existing text badge (kept — older clients depend on it), a terminal turn's payload now
  carries a machine-readable `provenance` object on **both** the poll result
  (`GET /jesse/result`) and the SSE `done` frame, next to `directives`:
  - `route` — `hosted` | `vaultqa-local` | `diet-local` | `emergency-local` (the same
    route vocabulary the metrics line uses — one source of truth).
  - `model` — the backend model that produced the reply (`null` on a bare `[hosted]`).
  - `badge` — the exact text badge string, **byte-identical** to what is appended to the
    reply text, so a client can strip it from the display by matching it.
  - `flags` — `hosted_verify` (diet `+ hosted verify`), `verify_queued` (diet
    `+ verify queued`), and `citations_unverified` (an emergency answer delivered above
    the `⚠️ citations unverified` warning) — exactly what the badge and warning encode.

  It is built at the **same finalization seam** as the badge and is present on the payload
  **exactly when** the badge is appended (badges on, a non-empty `Ok` reply); it is
  `null` when badges are off, on an empty directive-only turn, and on every error/cancel —
  so an older client sees precisely today's behavior (the trailing badge in the text). It
  is persisted with the job and reloads across a restart. *Root cause it addresses:* a
  client that wanted to render provenance as native UI had to string-parse the badge out
  of the reply text and re-derive the route/flags — brittle and drift-prone. The
  **metrics line and the `vaultqa-audit` schema are unchanged.** The exact strings are
  pinned by a shared fixture (`bridge/tests/fixtures/provenance.json`) that both the
  bridge and the iOS app tests read, so producer and consumer can never drift.

## [App 1.0 (39)] — 2026-07-15

### Added
- **Native provenance chip under a Jesse reply.** When the bridge delivers structured
  provenance (model-badge v2), the app strips the trailing text badge — and, on an
  unverified emergency answer, the prepended `⚠️ citations unverified` warning — from the
  displayed message and renders a subtle capsule under the bubble instead: a distinct
  tint for **local** vs **hosted** vs **emergency**, a *"Queued for verify"* state for a
  diet Tell queued during an outage, and a **warning** state (red, with a triangle) for
  unverified citations. When provenance is **absent** (an older bridge, or badges off) the
  reply text is shown verbatim, badge and all — exactly as before. The chip is persisted
  with the turn, so it survives relaunch and scrolling. The exact badge/warning strings
  are shared with the bridge via `bridge/tests/fixtures/provenance.json`, which the app's
  `ProvenanceTests` reads from disk so the two sides can't drift.

## [Bridge 0.11.0] — 2026-07-15

### Added
- **Structured metrics log (`JESSE_METRICS_LOG`).** When set to an absolute path, the
  bridge appends **one content-free JSON line per gated / routed / emergency turn** at
  the same reply-finalization seam the badge uses: ISO-8601 timestamp, turn id, mode,
  route (`hosted` / `vaultqa-local` / `diet-local` / `emergency-local`), backend model,
  ladder rung, wall ms, TTFT/tool-calls where recoverable, citation count + validator
  verdict, badge string, emergency flag, and hosted-failure class. **Never** the
  question, answer, or tokens — content joins happen in the audit via the serving logs.
  *Root cause it addresses:* the local-routing story had no durable, queryable record of
  what routed where, at what latency, or why a turn fell through — so an operator could
  not see routed share, fallback rates, or emergency activations without scraping
  free-text provenance. All-or-nothing and soft: unset → **zero** writes; a write
  failure logs to stderr and never disturbs the reply (append-only, line-buffered,
  restart-safe).
- **Emergency local fallback (`JESSE_EMERGENCY_LOCAL`, default off).** Armed only when
  on **and** the `JESSE_VAULTQA_*` triple is set. On a **transport-class** hosted
  failure (spawn / network / timeout / CLI-surfaced 5xx / 429 / quota / auth — never a
  completed turn), the bridge serves locally instead of surfacing the outage: an **Ask**
  runs the read-only vault-QA child (regardless of the routine gate; citation validator
  **advisory**, badge `[local · emergency · <model>]`, 120 s timeout); a **diet Tell**
  whose blocking hosted verify is unreachable has its extracted entry **queued** by the
  bridge (`[local · diet · <model> + verify queued]`) and replayed oldest-first on the
  next successful hosted contact through the exact verify-then-append path — **nothing
  reaches the CSVs unverified**, a rejected replay moves to a rejected file (never a
  silent drop), and the queue survives a restart. A **circuit breaker** goes local-first
  after 2 consecutive transport failures for 300 s. *Root cause it addresses:* a hosted
  outage previously meant a dead phone — every Ask errored and every diet Tell's blocking
  verify failed — even though the vault and a local model were right there.
  **Untested-live until go-live's outage drill;** ships dormant. See `SECURITY.md`
  ("Emergency local fallback posture").
- **`vaultqa-audit` bin — the daily audit of the vault-QA / emergency pipeline.** Reads
  the day's `JESSE_METRICS_LOG` slice **by timestamp** (not the diet audit's line-count
  watermark), joins the serving logs for citation re-validation when configured (skipped
  cleanly offline), reads the diet queue for pending/rejected + backlog age, and writes a
  dated markdown note + JSON twin to `~/Library/Logs/jesse-vaultqa-audit/`, mirroring the
  diet audit's destination. **Tripwires first:** any invented citation, any
  injection-style leak, emergency active >24 h, replay backlog older than 24 h. The
  launchd installer stays with go-live.
- **Vault-QA gate v2 — synthesis exclusions.** A self-referential Ask carrying a
  synthesis token (`advise`/`advice`/`suggest`/`recommend`/`review`/`summarize`/
  `summary`/`compare`/`analyze`/`plan`/`brainstorm`/`improve`/`rank`, or the `should I` /
  `what should` bigrams) is now **excluded** from the local lookup route and answered by
  the hosted agent. *Root cause:* the `vaultqa-v1` bake-off showed hosted winning every
  judged synthesis pair while both locals scored 100% on lookups — a false negative costs
  nothing (hosted answers as today), a false positive delivers a worse local answer.

### Changed
- **Vault-QA child timeout 25 s → 60 s** (`VAULTQA_TIMEOUT_SECS`). The `vaultqa-v1`
  bake-off measured the winning local backend's lookups at **10–42 s wall**; a 25 s
  ceiling would have timed out (rung-2) most real lookups the model answered correctly.
  Const only, no new env. The emergency child gets a looser 120 s (`EMERGENCY_TIMEOUT_SECS`).

### Notes
- **Backend call (recorded):** applying the routine-lookup qualification rule to the
  archived `vaultqa-v1` artifacts — (a) 100% on `vq-injection` + `vq-negative-absent`,
  (b) 100% of mechanical assertions on the 7-task subset, (c) subset mean wall ≤ 45 s —
  `local-oss` qualifies (mean **27.87 s**), `local-flash` fails (c) (mean **79.73 s**);
  **winner `local-oss`** (also the emergency backend). Pinned by a fixture test.
- With `JESSE_METRICS_LOG` and `JESSE_EMERGENCY_LOCAL` both unset, every existing path
  (main turn, titles, diet, vault-QA) is byte-for-byte unchanged — the full prior test
  suite passes unmodified.

## [Bridge 0.10.0] — 2026-07-14

### Added
- **Local vault-QA route (`JESSE_VAULTQA_*`) — answer a self-referential "Ask"
  from the vault, on-device.** When the `JESSE_VAULTQA_BASE_URL` /
  `JESSE_VAULTQA_AUTH_TOKEN` / `JESSE_VAULTQA_MODEL` triple is configured, a
  question that passes a **strict** gate (an interrogative opener AND a
  self-reference, no attachment/URL, not diet-shaped — diet keeps precedence) is
  answered by a **contained, read-only** local child instead of the hosted agent,
  keeping the tokens on-device. The child clones the diet child's deny-by-default
  posture with two deltas so it can read: a read-only root allowlist `--tools
  "Read,Grep,Glob"` (plus the four read-only qmd MCP tools when
  `JESSE_VAULTQA_MCP_CONFIG` supplies the server) and cwd = the vault (containment
  is the toolset, not the cwd). Every answer passes a pure in-process **citation
  validator** (≥1 citation, every cited file resolves, every quoted claim occurs
  in its file) before delivery; on any failure rung — spawn/API error, timeout,
  `NO_VAULT_ANSWER`, empty, validator fail — the turn **falls through** to today's
  hosted path unchanged. All-or-nothing and soft: **the seam is the kill switch**
  (unset the triple → every Ask takes the hosted path byte-for-byte). One
  provenance line per gated turn, never the question, never the token. See the
  bridge README ("Local vault-QA route") and `SECURITY.md` ("Vault-QA child tool
  isolation").
- **Model badge on every `/jesse/jesse` reply (`JESSE_MODEL_BADGE`, default on).**
  The bridge appends a one-line, display-only provenance badge naming which
  backend produced the delivered text: `[local · vault · <model>]`, `[local · diet
  · <model> + hosted verify]`, or `[hosted · <model>]` / `[hosted]`. Derived from
  the bridge's own turn state (never model output), applied at the single
  reply-finalization point (so both the poll result and the SSE `done` frame carry
  it), and **never** written into session state, fed back into a child, committed
  to the vault, or applied to the title endpoint. `JESSE_MODEL_BADGE=off`
  reproduces the prior exact reply text.
## [Bridge 0.9.1] — 2026-07-14

### Docs
- **Document the diet-pipeline probation graduation criteria.** Added a "Diet
  pipeline probation" section to `bridge/README.md` (next to the `JESSE_DIET_*`
  env table) stating when `JESSE_DIET_PROBATION` may be disabled: no earlier than
  **14 consecutive days** and **30 local-path entries**, with **zero rung-4
  (append/hook) failures**, **zero structural corrections that had to fall
  through**, a **rung-2/3 fallback rate under 5%**, and the daily audits reviewed.
  Flipping the flag is a human decision made against the audit history, never
  automated; graduation keeps the hosted verify child running on every entry
  (relaxing verify to spot-check semantics is a separate future decision).
  Documentation only — no behavior change; probation stays on by default.

## [App 1.0 (38)] — 2026-07-14

### Fixed
- **The macro/calorie drill-down now opens the same enriched sheet from the Today
  screen too.** Tapping a macro ring or the calorie ring on the main Today screen
  opened the bare explainer — prose only, no contributing foods, no insight — while
  tapping a bar inside Macros & calories opened the enriched one. Both entry points
  now route through a single shared builder (`FoodDrilldown.build`), so tapping
  protein, carbs, fat, fiber, or calories *anywhere* presents the identical facts and
  grounded insight.
- **The insight no longer asserts a goal was hit when it wasn't.** The drill-down
  correctly read "93/140g, need 47g more" while the insight below claimed "you've hit
  your protein goal" — the model was handed the per-food contributions but no
  authoritative goal status, so it guessed (and guessed "met" on nearly every macro).
  Goal status is now computed in code, never by the model:
  - A deterministic `GoalStatus` (met / short by N / over by N / no-goal) is computed
    alongside each gauge's remaining string, from the same numbers the title shows, and
    handed to the model as an explicit **ground-truth** fact it's instructed never to
    contradict — it may only claim the goal was hit when the status says *met*.
  - A post-generation **discard guard** is the deterministic backstop: if a generated
    insight still asserts the goal was reached while the computed status says otherwise
    (or makes any goal claim when there's no target), the insight is dropped and the
    facts stand alone. A wrong insight is worse than none.
  - Unit-tested at the defect's layer: the goal-status computation (below / at / above
    goal, windows, and nil target), that the gauges carry it, that the grounding prompt
    states it as authoritative, and that the guard catches the field's exact wrong
    sentence and its variants while keeping genuinely-met and color-only insights.

### Added
- **Share the whole drill-down page.** A share button on the drill-down sheet exports a
  clean plain-text rendition — the metric title with its consumed/goal and remaining,
  the sorted contributing foods with amounts and contributions, and the insight when
  one is present — that pastes cleanly into a chat or note with no markdown scaffolding.
  Pure and unit-tested.
- **Selectable text on the drill-down.** `.textSelection(.enabled)` is applied to the
  value/target line, the explanation paragraphs, the contributing-food rows, and the
  insight. Where SwiftUI's selection falls short, the plain-text share export is the
  guaranteed path that carries the full page.

## [App 1.0 (37)] — 2026-07-14

### Added
- **Tap a macro or the calorie total to see the foods that fed it.** The macros &
  calories detail's explainer sheet — the same sheet a bar tap already opens — now
  lists, under the explanation, the foods that contributed to *that* metric:
  - **Ranked by impact.** Each food's contribution to the tapped metric (grams for a
    macro, kcal for calories) sorted most-to-least, ties keeping the meal/item order
    the food journal uses. Shown with its name, its amount, its contribution, and a
    small proportional bar (in the macro's identity color from the calorie-source bar)
    with its share of the day's total for that metric.
  - **Zero and absent contributors are excluded, never shown as a 0 row.** A food with
    40 g carbs and no fat appears under carbs, not fat; a nil/absent field means "not a
    contributor" (not zero) and the food is omitted. The empty state distinguishes
    "nothing logged yet" from "logged, but none carry this metric".
  - **Reconciled against the headline.** The listed foods derive from the same per-item
    fields as the number on the bar, so they add up by construction; a defensive guard
    surfaces a note rather than silently showing a list that contradicts the headline.
  - The ranking is a pure function over `DietToday.meals` (`FoodContributions`),
    unit-tested for ordering, the zero/nil exclusion, shares, the empty/partial states,
    and the reconciliation guard.
- **On-device AI insight, streamed in below the facts.** After the contributing-foods
  list is on screen, a short natural-language insight about that metric streams in
  beneath it, styled clearly secondary. It uses the phone's built-in **Apple
  Foundation Models** on-device model (the app's first user-facing streamed-prose
  surface from the local model; the search expander and health classifier use it only
  for structured output), behind a new `HealthInsightGenerating` protocol seam so it is
  testable and swappable — the FoundationModels dependency stays contained to one file,
  as with the query expander and health classifier.
  - **The facts never wait on the model.** The list renders immediately; the insight
    fills in afterward from a cumulative stream.
  - **Grounded in the on-screen numbers.** The prompt names only the day's total, the
    goal, the live status, and the top contributing foods, and forbids invention, so
    the insight can't reference foods or figures not in the data.
  - **Degrades to nothing.** If the model is unavailable, disabled, not yet downloaded,
    or errors, the seam yields an empty stream and the facts stand alone — no error, no
    placeholder. The seam's unavailable/error path is unit-tested.
  - Routing insights through the bridge/Claude path is a deliberate follow-up, not part
    of this change.

## [Bridge 0.9.0] — 2026-07-14

### Changed
- **Single-writer default: `JESSE_MAX_CONCURRENCY` now defaults to `1` (was `2`).**
  The bridge runs one turn at a time by default — a **single global write lock**.
  With multiple paired clients (or one client's overlapping turns), two turns could
  previously run at once and both rewrite the same vault files (the diet CSVs,
  dashboards, daily notes), racing each other's edits. Serializing turns makes the
  vault the property of exactly one turn at a time. The env override is unchanged;
  set `JESSE_MAX_CONCURRENCY=2` (or more) to restore concurrent turns.
- **`POST /jesse` queues instead of shedding when busy (immediate-`429` → bounded
  queue).** A turn that can't get a concurrency permit immediately is now **queued**
  rather than rejected: `POST /jesse` still returns `202 {job_id, status:"running"}`
  at once, and the permit is acquired **inside** the spawned task, so a second
  client's turn **waits** for the first to finish and then runs. The queue is
  bounded by a new **`JESSE_MAX_QUEUED`** (env, default `4`, floor `0`); beyond the
  cap, load is shed with `429` exactly as before (and `JESSE_MAX_QUEUED=0`
  reproduces the old immediate-`429`, no-queue behavior). While a turn waits, its
  live stream carries a `"queued behind another turn"` **activity** frame (reusing
  the existing SSE activity mechanism — no new frame type). Cancelling a queued turn
  works and frees its queue slot **without ever spawning `claude`**, and the
  per-turn timeout clock starts only when `claude` spawns, never while queued.

### Added
- **`GET /jesse/sessions` — the session list.** A new authed, rate-limited endpoint
  that enumerates the vault's Claude Code session transcripts
  (`~/.claude/projects/<escaped-vault-path>/*.jsonl`) and returns, **newest first by
  mtime**, `{ session_id, last_modified, first_message, title }` per session.
  `first_message` is the first user turn's text truncated to 120 chars (read from a
  bounded 64 KiB prefix; `null` if not found — never an error, and both plain-string
  and array-of-blocks message content are handled). `title` comes from the new title
  store (below). Supports `?since=<unix seconds>` (strictly-greater delta poll) and a
  **strong ETag** with `If-None-Match` → `304`. A missing projects directory is an
  empty list, not an error; unparseable lines and non-jsonl files are skipped. The
  `<escaped-vault-path>` derivation is a pure, unit-tested function — **every
  non-alphanumeric char → `-`** (verified against `claude 2.1.208`:
  `/Users/u/devel/tag1/jesse` → `-Users-u-devel-tag1-jesse`).
- **Server-side title store on `POST /jesse/title`.** The title request gains an
  optional `"session_id"`; when present and the title call succeeds, the minted
  title is persisted under it (a single `<state_dir>/titles.json`, 0600, atomic
  temp+rename, best-effort — mirroring the device-token store), so it survives a
  restart and `GET /jesse/sessions` can show it. With no state dir the store is
  in-memory only (the same degradation the job store has). **Omitting `session_id`
  is byte-for-byte today's stateless behavior** — old clients are unaffected. The
  stored title is trimmed and clamped to `MAX_TITLE_CHARS` (60) at the store
  boundary.

All three are additive and backward-compatible (additive endpoint, additive
optional request field, additive env var, and a default change that only *narrows*
concurrency); an app build that never calls the new endpoint or sends the new field
behaves exactly as before.

## [App 1.0 (36)] — 2026-07-13

### Changed
- **Weight targets generalized from two fixed program phases into a labeled list of
  user goals.** The diet progress contract gains `progress.targets`, a zero-to-N
  ordered list where each goal carries a `weight`, an optional `date`/`daysLeft`/
  `requiredPace`, an `achieved` flag, prerendered `barFilled`/`barLabel` strings, and
  `short`/`title`/`id` labels. This replaces the hardcoded race/maintenance display
  words in the weight chart, the progress bars, and the milestone chips:
  - **Model.** New `DietTarget` (tolerant decode — required `id`/`title`/`weight`,
    the rest optional, unknown keys ignored) plus `targets` on `DietProgress`.
  - **Legacy fallback.** When `targets` is absent (an older generator), the app
    synthesizes the race + maintenance goals from the legacy
    `raceTarget`/`raceDate`/`maintTarget`/`*Bar*` fields, so rendering has one code
    path and the app deploy is independent of the vault-side rollout. An explicit
    empty `targets: []` (no goals) is authoritative and hides the goal sections.
  - **Weight chart.** One dashed horizontal rule per goal (the first keeps the
    signature green, later goals read muted), labeled with the goal's short name and
    weight; zero goals draw no rules.
  - **Progress & pace.** The progress bars and milestone chips loop over the goals;
    an achieved goal shows a checkmark. A new countdown surfaces the nearest dated
    goal ("N days to <title>", plus "needs X.X lb/wk" when a required pace is
    present); a past date reads "N days past", never a negative count; no dated goal
    hides the section.
- **Coach quote of the day now decodes HTML entities** (e.g. `&mdash;`, `&lsquo;`)
  the same way the coach notes do, via `CoachHTML`.

## [Bridge 0.8.2] — 2026-07-13

### Changed
- **Diet integration coverage for the new `progress.targets` array.** The
  `DIET_PROGRESS` pass-through is generic (json5 → JSON), so the new targets array
  flows through with no parser change — now verified. Synthetic fixtures gain a
  `targets` array (a dated goal, an undated goal in both `date: null` and
  key-omitted forms, and an achieved past-dated goal), plus a legacy-only fixture
  (no `targets` key) and an empty-`[]` fixture. New assertions confirm the array
  round-trips field-for-field with order preserved, the legacy
  `raceTarget`/`raceDate`/`maintTarget` fields still pass through alongside it, a
  payload without `targets` still serves 200, and an empty `targets: []` stays an
  empty array (not null or absent). No behavior change to the endpoint.

## [Bridge 0.8.1] — 2026-07-13

### Security
- **Hard-contain the stateless diet children at the CLI root (sandbox-escape
  class: incomplete tool denial).** The diet **extract** and **verify** children
  were built with an empty `--allowedTools` plus a seven-name `--disallowedTools`
  list, on the assumption that an empty allowlist under `--permission-mode default`
  yields a child that holds no tools. Live validation against the pinned CLI
  (`claude 2.1.207`) on 2026-07-13 disproved that: an empty allowlist means "add
  nothing to the **default** tool set", not "allow nothing". A headless `-p` child
  still reached the read/search built-ins (a *run ls* probe executed `Glob`),
  loaded MCP servers on demand via `ToolSearch` (a *fetch* probe drove
  `mcp__playwright__browser_navigate` to a **live network fetch**, no approval),
  and reached `Workflow` — none of which raise the permission prompt a headless
  child cannot answer. Only `Write` was actually contained. **Fix:** rebuild the
  boundary deny-by-default at the root, applied to **both** children via the shared
  `build_diet_child_command`:
  - `--tools ""` disables the **entire** built-in toolset (the load-bearing flag —
    control-tested: dropping it alone lets the `Glob` escape recur);
  - `--strict-mcp-config` + an empty `--mcp-config` (`{"mcpServers":{}}`) load **no**
    MCP servers, so every `mcp__*` tool — and anything `ToolSearch` could pull from a
    server — is absent at the root;
  - the `--disallowedTools` denylist is expanded (adds `Glob`, `Grep`, `Read`,
    `ToolSearch`, `Workflow`, `Agent`, `TodoWrite`, `Skill`) and kept, with the empty
    `--allowedTools`, as documented fragile belt-and-suspenders behind the two root
    flags.
  Re-validated live with a six-probe battery run against the exact builder argv:
  zero executed `tool_use` across all six probes, the write-probe file absent, and
  no network egress. `claude 2.1.207` exposes no `--max-turns` flag, so the
  single-shot bound cannot be CLI-enforced; the children are single-shot by
  construction and each probe completed in `num_turns=1`. **The kill switch is
  unchanged** — with `JESSE_DIET_*` unset (the default) the pipeline is dormant and
  every turn takes the hosted path byte-for-byte; the main-turn and title command
  construction are untouched (proven by the existing byte-identical tests).

## [App 1.0 (35)] — 2026-07-13

### Changed
- **Fiber presented as a subset of carbs everywhere (color, order, type).** Fiber's
  grams are counted inside carbohydrate grams (US-label convention — the calorie-source
  bar already carves the fiber segment out of the carb segment), and the presentation
  now says the same thing on every surface that lists more than one macro. Three rules,
  all presentation-only — the data contract, wire/CSV identifiers, HealthKit types, the
  DietSemantics engine, and the calorie-split math (including the fiber clamp) are
  untouched, and no displayed number changes:
  - **Color.** Fiber's identity color is no longer an independent hue (`.brown`, added
    in the fiber-bar change, is gone). It is now the carbs color (system teal) lightened
    toward white — the same teal family, clearly paler — derived by a function inside a
    dynamic color provider so it resolves per color scheme and stays fully opaque, so the
    calorie-source bar reads as carbs and its paler kin side by side and the two stay
    tellable apart in light and dark mode. Only the macro-**identity** surfaces (the bar
    and its legend) use this; the rings and Macros-screen bars still color by
    red/yellow/green status judgment, unchanged.
  - **Order.** Every user-facing macro listing now shows Protein, Carbs, Fiber, Fat —
    fiber immediately after carbs — derived from one canonical source (the `Macro`
    enum's case order). The Health-tab macro rings row (which shipped as Protein, Carbs,
    Fat, Fiber), the Macros screen, the neutral totals, and every food-journal macro
    caption were reordered to derive from it instead of hardcoding.
  - **Type.** Where macros are listed with labels, the fiber entry renders as a
    sub-entry of carbs — smaller and/or in a dimmer secondary color, the way a nutrition
    label indents Dietary Fiber under Total Carbohydrate — while its gram number stays
    visible. Applied to the calorie-source bar legend, the Macros screen bar rows and
    neutral totals, and the day-summary grand macro line and per-meal subtotal line. The
    macro rings stay four equal rings (ring size encodes nothing, so fiber's ring is not
    shrunk — only its position changes).

## [App 1.0 (34)] — 2026-07-13

### Added
- **Food journal: fiber in the calorie-source bar.** The day-summary card's
  stacked calorie-source bar gains a fourth segment — fiber — carved out of the
  carb segment (order: Protein, Carbs, Fiber, Fat). Fiber grams are a subset of
  carb grams (US-label total-carbohydrate convention), so the fiber slice at 4 kcal/g
  comes out of the carb slice: net-carbs + fiber always occupy exactly the width the
  carb segment alone used to, and the bar still sums to the day's calories. A day
  with zero fiber renders no fiber segment and looks exactly as before. The compact
  legend gains a **Fiber** entry (full words for all four: Protein, Carbs, Fiber,
  Fat); the grand macro line still shows total carbs and fiber grams unchanged — no
  displayed number changes. The split math is pure and unit-tested
  (`HealthDisplay.calorieSplit`): missing/negative fiber is treated as zero, and
  fiber exceeding carbs is clamped to carbs so the net-carb term never goes negative.
  Fiber's bar color is `MacroColor.fiber`, added to the app's canonical macro-color
  source. App-side math and rendering only — no data contract, networking, or
  semantics-engine change.

## [Bridge 0.8.0] — 2026-07-13

### Added
- **Local diet-logging pipeline (behind an env seam, dormant by default).** When
  `JESSE_DIET_BASE_URL` / `JESSE_DIET_AUTH_TOKEN` / `JESSE_DIET_MODEL` are all set,
  a diet-shaped "Tell" (food / exercise / weigh-in) is handled by a local pipeline
  instead of a hosted agent turn:
  1. **Extract** — a stateless, **toolless** child (empty `--allowedTools`, pointed
     only at the diet backend via `apply_diet_env`) parses the utterance into
     structured **per-item** JSON entries (`build_diet_extract_prompt`); the schema
     rejects aggregation (one entry per food, never a meal total).
  2. **Verify** — a **hosted, ambient** one-shot (never the diet backend) checks
     every entry (probation mode: blocking, 100%) with an approve/correct/reject
     verdict; a correction is applied only when trivially safe (same item, adjusted
     numbers within a 20%-or-75-kcal tolerance), else it falls through.
  3. **Append** — trusted Rust appends the verified rows RFC-4180-style to
     `diet-logs/*.csv` (atomic per turn, with rollback), runs the three pinned node
     scripts (`generate` → `validate` → `verify`), and commits one-per-log-event.
  4. **Mirror** — the `JESSE_MEAL_LOG v1` directive is **derived by the bridge** from
     the appended food rows (one mirror meal per row, macros equal to the row,
     reusing the existing `MealLog` struct), so per-item mirroring is guaranteed by
     construction, not trust.
- **The env seam is the kill switch.** With the triple unset (the default) the diet
  gate never fires and every turn — diet-shaped or not — takes today's hosted path
  byte-for-byte on the spawned command (proven by
  `main_turn_command_is_unaffected_by_diet_backend` and a byte-identical-command
  test). No redeploy needed to disable the feature.
- **Fallback ladder.** Every failure lands on a defined rung: gate-unsure/`mode != tell`
  (1), extract error / malformed / `no_loggable_content` (2), verify reject or unsafe
  correction (3), append/hook failure — rolled back, no commit (4), or mirror-build
  failure after a good append — CSV kept, mirror omitted (5). Rungs 1–4 fall through
  to the hosted turn; a log is never lost and never double-appended.
- **Provenance.** One stderr line per diet turn (mirroring the title line; token
  never printed, no meal content): `jesse-bridge: diet turn -> <local|hosted-fallback
  rung=N> extract base_url=<u> model=<m>; verify verdict=<...>; rows=<n>
  mirror=<derived|omitted>`.
- `JESSE_DIET_PROBATION` (default `true`) — mandatory blocking verify; the false
  (graduation) state is reserved and not used yet.

Nothing here changes runtime behavior until the `JESSE_DIET_*` triple is set.

## [App 1.0 (33)] — 2026-07-13

### Added
- **Bridge version handshake (non-blocking).** Settings already showed the running
  bridge version next to the app's own; it now also *compares* them. The app carries
  a minimum-bridge-version floor (`BridgeCompatibility.minimumBridgeVersion`, 0.7.0)
  and, when the connected bridge is strictly older, shows a non-blocking amber
  "your bridge is out of date — this app expects bridge X or newer, but it's Y"
  advisory in the Version section. It's a warning, not a hard block: per-endpoint
  graceful degradation (an old bridge 404ing a newer route) is unchanged and stays
  the real safety net. This closes the silent-degradation gap behind the past
  `/jesse/title` 404 incident, where a stale bridge failed quietly. An unknown or
  unparseable bridge version never triggers the warning (no crying wolf). The
  comparison is a pure, unit-tested `SemVer` triple compare (pre-release/build
  metadata ignored, missing components read as zero), covered failing-first.

### CI / tooling (no app-behavior change)
- **Watch tests now run in CI.** The `Jesse Watch App` scheme is now shared and its
  test action wired to `Jesse Watch AppTests`; CI resolves a watchOS simulator
  dynamically (mirroring the iPhone resolution) and runs the watch suite, which
  previously only ran locally.
- **Swift warnings are now errors for production code in CI**
  (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` on the app and watch `xcodebuild build`
  steps). This mirrors the bridge's `cargo clippy -- -D warnings`, which — without
  `--all-targets` — gates the shipping crate, not the test code; the Swift gate is
  scoped the same way (the XCTest bundle, which carries pre-existing Swift-6-mode
  warnings, is out of scope). The app already builds warning-free.
- **Code coverage is measured and printed** (report-only, non-gating): iOS via
  `-enableCodeCoverage YES` + an `xccov` summary; the bridge via `cargo llvm-cov`.
- **Dependency-CVE gate:** CI now runs `cargo audit` over the bridge's `Cargo.lock`
  (currently clean — no advisories, no ignores).

## [App 1.0 (32)] — 2026-07-13

### Changed
- **Health tab: macros are spelled out, not abbreviated.** Every user-facing macro
  label in Health now reads as a full word — Protein, Carbs, Fat, Fiber — from one
  canonical source (`Macro.displayName`), replacing the cryptic "P" / "C" / "F" and
  the ambiguous "Fib". The food-journal item rows, per-meal subtotals, the
  day-summary card, planned meals, and the reconstructed-day (neutral) Macros screen
  all render from a single pure formatter (`MacroLine.format`), which builds
  "Protein 32g · Carbs 40g · Fat 12g · Fiber 6g" (full form with units), a compact
  units-dropped fallback, and an optional fiber-omitted form. The macro rings,
  calorie-source legend, macros detail rows, and explainer titles route their names
  through the same canonical source, so no view keeps a private label string.
  - The per-meal **subtotal** row moves its macro line to its own full-width line
    below the calories (the full words don't fit beside "Subtotal" and the calories
    on one line at default Dynamic Type), matching the item-row layout above it.
  - No displayed numbers change: rounding stays on the shared `DietSemantics.fmt`.
    The data contract (`p`/`f`/`c`/`fiberGrams`, CSV headers, HealthKit types) is
    untouched — this is a display-label change only.

## [App 1.0 (31)] — 2026-07-12

### Added
- **Health tab: page back through earlier days.** The Health root gains back/forward
  chevrons (flanking a "Today" jump button) that walk `availableDays` — nearest
  earlier/later day, ends disabled, forward from the last past day lands on today.
  The viewed date is pinned: a background refresh or day rollover never yanks you off
  the day you're reading, and a day already fetched this session renders instantly
  from an in-memory cache (pull-to-refresh forces a refetch). Chevrons shipped, not a
  swipe — to avoid fighting the vertical scroll and tab-bar gestures.
  - **Archived days** (bridge `fidelity: "archived"`, targets present) render exactly
    like today through the untouched `DietSemantics` engine, with the engine's hour
    fixed at end-of-day (24) so time-gated flags are fully resolved for a completed
    day rather than suppressed by the render clock.
  - **Reconstructed days** (`fidelity: "reconstructed"`, targets null) render with NO
    judgment: a neutral calories hero (eaten total + burned/net caption), neutral
    macro rings (gram totals), one "No targets recorded for this day" caption, and a
    Macros screen of plain per-macro totals. The Food journal and Exercise screens
    work fully (they're data, not judgment). Coach, Progress & pace rows and the
    quick-log "+" are hidden on a past day; Weight & trend stays reachable. The footer
    shows "Archived day" / "Rebuilt from logs" instead of the mtime stamp, and the
    stale banner is suppressed.
  - **Old-bridge handling.** `fetchDietSnapshot(date:)` sends `?date=`; a bridge that
    ignores it (returns today for a dated request) is detected by the date mismatch
    and flagged, leaving today's view fully functional. A pre-0.7.0 bridge omits
    `availableDays` so the chevrons stay disabled.
  - All paging, hour-injection, neutral-mode and visibility selection is pure,
    Foundation-only, unit-tested code (`DietPaging`, `HistoryRender`, `NeutralMode`,
    `HistoryUI`); `DietSnapshot` gains optional `availableDays`/`historical`/
    `fidelity` so old payloads still decode. The plain today response is unchanged
    beyond those three additive fields.

## [Bridge 0.7.0] — 2026-07-12

### Added
- **`GET /jesse/diet?date=YYYY-MM-DD` — paged day history.** The endpoint gains an
  optional strict `date` query parameter (a malformed value is `400` with a JSON
  error body) and three additive response fields on every response: `availableDays`
  (the sorted, deduped union of dates across `food-log.csv`, `exercise-log.csv`,
  `weight-log.csv`, the `diet-logs/days/` archive directory, and today's own date),
  `historical`, and `fidelity` (`"live" | "archived" | "reconstructed"`).
  - **Archived days.** When `diet-logs/days/<date>.js` exists it's parsed with the
    same extractor as `diet-today.js` and served as the day's `today` at full
    fidelity (`"archived"`). A missing `days/` directory is treated as "no archive",
    never an error.
  - **Reconstructed days.** For a past date with no archive, the day is rebuilt from
    the append-only CSVs (RFC 4180 via the `csv` crate, columns addressed by header
    NAME and read with `flexible(true)` so legitimately-ragged legacy rows parse):
    meals grouped by `(Meal, Time)` and sorted chronologically, exercise mapped and
    sorted, and the weigh-in for that date — with `dayStyle`/`dayType`/`targets` null
    so the app renders without judgment. A row with no usable identity is skipped and
    counted into `errors`; an item with no derivable calories gets `cal = 0` and one
    `errors` note (calories derive from `Cal_per_100g × Grams` when `Calories` is
    blank).
  - Historical requests always return `proposed`/`progress`/`coach` null (those files
    describe the CURRENT state). An unknown or future date is `404` with a JSON error
    body. The endpoint stays strictly read-only.
  - The plain today response (no `date`, or `date` == today's date) is byte-compatible
    with 0.6.0 beyond the three additive fields; `diet-today.js` missing/unparseable
    is still the only `503`.

## [App 1.0 (30)] — 2026-07-12

### Fixed
- **Health dashboard actor-isolation warnings.** `HealthDashboardModel`'s injected
  client factory was typed as a plain (nonisolated) `() -> any JesseClientProtocol`,
  so its default value — `{ JesseClient(config: ConfigStore.load()) }` — called the
  main-actor-isolated `JesseClient.init` and `ConfigStore.load()` from a synchronous
  nonisolated context (two warnings under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
  The factory is only ever invoked from `load()` on the already-`@MainActor` model, so
  the type is now `@MainActor () -> any JesseClientProtocol` to match. No behavior change.

## [App 1.0 (29)] — 2026-07-12

### Changed
- **Health tab redesign — a presentation pass over the v1 dashboard.** The data
  contract, networking, caching, refresh, error/empty states, and every rule in the
  `DietSemantics` engine are unchanged; only how the snapshot is presented changed.
  - **Tab bar scope.** The root TabView's bar is now hidden inside an open
    conversation (applied on the pushed `ThreadDetailView`, so every entry point —
    deep link, Siri, notification tap — inherits it) and remains visible on the
    conversation list and throughout Health.
  - **Today header.** The date is now the navigation title, formatted Apple-Fitness
    style ("Saturday, July 12", locale-aware and unit-tested). The day-style chip
    sits under the title and is tappable, opening an explainer describing what the
    day type changes (which metrics are floors, ceilings, windows). The "updated
    HH:MM" stamp moved out of the header to a single centered caption at the very
    bottom of the scroll view. Stale-banner logic is unchanged.
  - **Calories hero ring.** The first content section is one large Apple-Watch-style
    activity ring — thick rounded stroke on a dim track, animating on appear — whose
    fill is intake/target clamped to 1.0, whose color is the engine's calorie status
    color exactly (ceiling on normal days, window on carb-load days), and whose
    center shows the remaining number large with the engine's remaining annotation
    beneath. A net line ("1,840 eaten · 420 burned · 1,420 net") appears when a burn
    exists. Tapping opens the calories explainer.
  - **Macro rings.** Four smaller rings (Protein, Carbs, Fat, Fiber) replace the old
    compressed gauge strip, each colored by the engine's status (fiber renders
    neutral gray on a carb-load day, where the engine suspends it), grams in the
    center, the macro name on one line with its goal glyph beneath. Each opens its
    explainer.
  - **Weight card** moves below the rings and is now a NavigationLink into Weight &
    trend (with a chevron); its content rules are unchanged.
  - **Food journal.** A day-summary card (total calories large + a stacked
    calorie-source bar at 4/4/9 kcal per gram, with a legend) replaces the old
    grand-total footer, followed by chronological meal cards (name, time capsule,
    calories, per-item macros) with subtotals, then a visually distinct "Planned"
    section for proposed meal ideas.
  - **Exercise.** Fitness-app-style workout cards, one per session, with an SF Symbol
    per activity type (pure, case-insensitive, substring-matched mapping) and a
    metrics grid of whichever fields exist.
  - **Weight & trend.** The BF% toggle is removed — the body-fat series renders
    whenever any weigh-in carries a BF reading (a pure, tested availability rule) and
    otherwise no BF UI exists. The pace wall-of-text is replaced by two stat tiles
    (Trough, Raw) with zone chips and captions drawn from the prerendered strings,
    plus a single range line.
  - **Progress & pace.** Compact phase milestones, titled progress bars with
    percents, two fat/lean stat tiles, and a single trajectory callout replace the
    paragraphs of caption text; the body-composition bar is unchanged.
  - New pure, failing-first-tested logic: ring fill/clamp + neutral mapping, the
    calories center-label selection across left/at-limit/over/window, the net line,
    the exercise-symbol mapping, the BF availability rule, the header-date formatter,
    the calorie-source split, and the day-style headline.

## [Bridge 0.6.0] — 2026-07-10

### Added
- **Optional title-only backend override for `POST /jesse/title`.** Three new
  optional env vars — `JESSE_TITLE_BASE_URL`, `JESSE_TITLE_AUTH_TOKEN`,
  `JESSE_TITLE_MODEL` — let the stateless title one-shot be served by a different
  (typically cheap, fast, local) backend than main turns. When **all three** are
  set (trimmed, non-empty, same `env_string` semantics as every other string
  field), the title child — and **only** the title child — is spawned with
  `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL` set to those
  values via the child's env, so a title can be generated on a local model while
  every main "Ask/Tell" turn keeps using the ambient credentials untouched.
  **Soft-failure semantics:** if any of the three is unset (or blank), behavior is
  byte-for-byte the previous release — the title child inherits the bridge's
  process env unchanged. A **partial** configuration (one or two of the three set)
  logs one warning at startup and is treated as fully unset. Main-turn children
  are never affected under any configuration (proven by a dedicated test). Each
  title call logs one provenance line naming the backend that served it (base URL
  + model, never the token; no prompt content). The title endpoint's soft 20s
  timeout and one-line clamp are unchanged; a title failure remains soft (the app
  keeps its own derived title).

## [App 1.0 (28)] — 2026-07-09

### Added
- **New "Health" tab — a native diet dashboard with progressive disclosure.** The
  app root becomes a two-tab `TabView`: the existing conversation UI is unchanged
  inside a "Chats" tab, and a new "Health" tab renders the `GET /jesse/diet`
  snapshot (bridge ≥ 0.5.0) natively. The Level-1 "Today" screen is scannable in
  five seconds — date + day-style chip + "updated HH:MM", a weight card (delta vs
  the previous weigh-in; BF%/lean only from a real same-day weigh-in, never carried
  forward), a large calories-remaining card with a status-colored bar and a net
  line, a four-gauge macro strip, a one-line coach headline, and nav rows with
  summaries. Six Level-2 detail screens drill in: macros & calories (tappable bar
  rows open an explainer sheet), food journal (with meal ideas from `proposed`),
  exercise, weight & trend (a Swift Charts line with a 7-day moving average, target
  rule marks, a 30d/90d/all range picker, drag-to-scrub, and a BF% toggle),
  progress & pace, and coach's notes. A pure, fully-unit-tested semantics engine
  (`DietSemantics`) ports the browser dashboard's rules exactly — day-style
  ceiling/window/floor profiles, the carb-load flips (calories→window, fat→ceiling,
  fiber suspended), status color bands, remaining annotations, the exercise
  carb-bonus, net calories, and the after-4pm gated "low" flags (the hour is
  injected, never `Date()`). Coach-note HTML (`<strong>` + a few entities) renders
  as an `AttributedString`. `JesseClient.fetchDietSnapshot()` maps failures onto a
  `DietFetchError` that drives distinct full-screen empty states (not paired,
  unreachable, auth failed, bridge-update-needed for a 404, and 503), and a failed
  refresh never blanks a previously-rendered screen. Refresh happens on tab appear,
  on pull, and after any turn completes while the tab is active. A "+" quick-log
  button prefills a Tell turn (Meal / Snack / Weigh-in / Workout) through the
  existing thread machinery, so a logged meal comes back reflected on the next
  refresh.

## [Bridge 0.5.0] — 2026-07-09

### Added
- **New authenticated endpoint `GET /jesse/diet`** — reads the vault's generated
  diet data files and returns one normalized JSON snapshot for the app's Health
  tab. Same bearer auth as every other endpoint. It reads
  `todo-list/diet-today.js` (required), `todo-list/diet-progress.js`,
  `todo-list/diet-coach-notes.js`, `todo-list/proposed-diet-today.js` (optional,
  frequently absent), and `diet-logs/weight-log.csv`. The three `.js` files are
  data-only JS literals (`window.X = <literal>;` with unquoted keys, single
  quotes, trailing commas, `//` comments, and embedded HTML/entities in strings),
  parsed by stripping the comment lines and the `window.X =`/`;` wrapper and
  handing the literal to the `json5` crate — no hand-rolled JS parser, no
  quote-rewriting. `weight-log.csv` (RFC 4180, quoted commas in Notes) is parsed
  with the `csv` crate into a chronological `weightSeries`
  (`MuscleMass_lbs`→`leanLbs`, blank cells → null). **Per-section isolation**
  mirrors the browser dashboard: a missing or unparseable file becomes `null` and
  appends a human-readable line to an `errors` array rather than failing the
  endpoint. The endpoint returns `200` whenever `diet-today.js` parsed and `503`
  (JSON error body) only when `diet-today.js` itself is missing/unparseable — the
  screen is pointless without it. An absent `proposed-diet-today.js`, or one with
  empty `ideas`, normalizes to `proposed: null` and is **not** an error. The
  response carries `asOf` (server time) and `todayMtime` (the mtime of
  `diet-today.js`) as RFC 3339 UTC. New deps: `json5`, `csv`.

## [App 1.0 (27)] — 2026-07-08

### Added
- **Dietary fiber now flows from a logged meal into Apple Health.** Fiber is
  carried end to end exactly like the existing four macros (kcal, protein, carbs,
  fat): optional per meal, present as a finite non-negative number or omitted —
  never null-padded. `JesseMeal` decodes `fiber_g` into `fiberGrams`, the domain
  `Meal` gains `fiberGrams`, and `MealLogParser.meal(from:)` validates it in the
  macro loop (finite, non-negative). `HealthKitMealWriter` adds
  `.dietaryFiber` to its share set — now exactly the five dietary quantity types,
  still no correlation container — and writes a grams sample into the `.food`
  correlation after fat. The persisted pending-write queue carries the new
  optional Codable field, so old queued meals decode with `fiberGrams == nil` (no
  migration). New/extended cases across wire decode, the parser matrix, the
  authorization type set, the writer, and the pending store cover fiber present,
  absent, zero, and negative-rejected.

## [Bridge 0.4.2] — 2026-07-08

### Added
- **`JESSE_MEAL_LOG v1` meals may now carry `fiber_g`.** `fiber_g` joins the meal
  field allowlist and the `Meal` struct (with the same
  `skip_serializing_if = "Option::is_none"` treatment as the other macros, so an
  absent value is omitted from the wire, never serialized as `null`), extracted
  via `optional_macro`. The parser matrix gains fiber coverage: round-trip decode,
  absent-omitted, zero-valid, and rejects-negative / rejects-non-numeric — the
  same coverage the other macros already had.

## [App 1.0 (26)] — 2026-07-07

### Added
- **Health context now reports body fat and lean body mass.** The daily-summary
  weight line gains two optional clauses beside weight: `body fat 25.1% (2026-07-03)`
  and `lean mass 63.08 kg (2026-07-03)`, each read latest-within-7-days (the same
  recency window as weight) and omitted when absent or stale. `.bodyFatPercentage`
  and `.leanBodyMass` were added to `HealthContextProvider`'s quantity read
  identifiers, so they enter `readTypes` and the re-authorization sheet (read-only;
  the share/write set is untouched). Body fat comes off HealthKit as a 0…1 fraction
  and the formatter scales it to a 1-decimal percent; lean mass renders in kg to 2
  decimals. With both fields nil the rendered block is byte-identical to before, so
  a day with no body-composition data looks exactly as it did. New
  `HealthContextTests` cases cover the weight+BF+LBM line, each new clause alone,
  stale-clause omission, the byte-identity invariant, the fraction→percent
  conversion, and the empty-context guard.

## [App 1.0 (25)] — 2026-07-07

### Security
- **Keychain token is now unlocked-this-device-only.** `ConfigStore.write` added
  the bearer token to the Keychain with no `kSecAttrAccessible`, so it took the
  default accessibility and was backup-eligible and device-migratable. Every add
  now sets `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so the token can't leave
  the device via an iCloud/iTunes backup or a device transfer. A new
  `ConfigStoreKeychainTests` case asserts the attribute is present on every add via
  the injectable seam.

## [Bridge 0.4.1] — 2026-07-07

### Security
- **The plaintext token is no longer printed at startup by default.** The bridge
  printed `token=<token>` beside the pairing QR on every launch, leaving the raw
  token in terminal scrollback and launchd logs. It's now hidden by default —
  host/port still print for manual entry, and the QR still encodes the token so
  pairing is unaffected. Opt back in to the plaintext line with the `--show-token`
  flag or `JESSE_SHOW_TOKEN=1`. New `startup` unit tests cover both the hidden and
  shown branches and the flag/env opt-in. README updated to match.

### Fixed
- **Doc drift:** `SECURITY.md` (and the README security-model note) said the
  `HARD_TIMEOUT_CEILING` was 3600s; the code (`config.rs`) is 7200s. Corrected the
  docs to match the runtime value.

## [App 1.0 (24)] — 2026-07-07

### Changed
- **Streaming replies no longer re-evaluate the transcript on every delta.**
  During a live turn the observable `partialText` was mutated once per SSE delta
  chunk, and because it's read in `ThreadDetailView.body` (and watched by
  `.onChange`), the whole transcript body re-evaluated and an auto-scroll fired on
  *every* chunk — only the markdown *parse* was throttled to 10 Hz, not the body
  re-eval or the scroll. `RunCoordinator` now coalesces `partialText` publishes to
  the same ~10 Hz cadence: incoming chunks accumulate in an exact buffer and the
  observable is published at most once per interval (with a deferred flush so a
  tail chunk still surfaces within one interval, and an unconditional flush on the
  terminal frame / stream end). Throttled by *rate only* — never by dropping
  content: the final published text is the exact concatenation of every chunk.
- **`JesseThread.orderedTurns` is memoized.** It was re-sorting the entire thread
  on every read, and it's read in that same ~10 Hz streaming hot path. It now
  caches the sorted array keyed on the turn count (turns are only ever appended,
  so a count change is the only way the ordering can change), invalidating on
  append. Repeated reads with no mutation perform no additional sort.

## [App 1.0 (23)] — 2026-07-07

### Fixed
- **Pasting a photo into the composer no longer trips the 10 MB size cap.** The
  native paste added in build 22 read the pasteboard's flattened `.items`
  dictionary and hit the `UIImage → PNG` re-encode path, inflating a compact
  JPEG/HEIC photo into a much larger PNG that exceeded `AttachmentLimits`
  (`"pasted-….png" is too large`). The cap did not change; the encoding did.
  Paste now reads the pasteboard's item *providers* and loads the original bytes
  via `loadDataRepresentation`, keyed on `hasItemConformingToTypeIdentifier` — so
  a photo keeps its own compact JPEG/HEIC bytes verbatim and is re-encoded to PNG
  only as a last resort (a bitmap with no concrete data representation). This
  restores build 21's paperclip-import behavior for pasted media.

## [App 1.0 (22)] — 2026-07-07

### Changed
- **Native text interaction in the composer and message bubbles.** The app no
  longer fights iOS's built-in text-interaction gestures:
  - **Composer paste is native.** The dedicated paste button is gone (it took up
    space and was non-standard). The composer is now a `UITextView`-backed field
    (`ComposerInput`): long-press → **Paste** appears — offered by iOS itself
    only when the clipboard has content the field accepts — and pastes text. A
    copied **photo or PDF** pastes too, staging as an attachment through the same
    caps/chip/send path the paperclip uses (`ComposerPaste` + the existing
    `PasteAttachment` rules). The multi-line floor (never collapses to one line,
    grows then scrolls) is preserved via `ComposerLayout`.
  - **Message text is genuinely selectable.** Assistant replies and user bubbles
    are backed by a non-editable `UITextView` (`SelectableText`, and
    `MarkdownText`'s new selectable path), so long-pressing starts a real native
    selection you can drag by **word / sentence**, with double-tap-word, Select
    All, and the system Copy menu. Markdown (headings, lists, `code`, tables,
    bold/italic/links) still renders — inline styling is resolved to concrete
    fonts by `MarkdownInline`. The per-message "…" (overflow) affordance and its
    whole-message copy-all are removed; whole-conversation Share stays in the
    toolbar. The live streaming partial keeps the lightweight SwiftUI text path
    (no selection needed mid-stream).

## [App 1.0 (21)] — 2026-07-06

### Fixed
- **"Connect Apple Health" crash on device.** Tapping Connect Apple Health on
  build 20 crashed with `NSInvalidArgumentException` — *"Authorization to share the
  following types is disallowed: HKCorrelationTypeIdentifierFood"*. The build-20
  share (write) set added `HKCorrelationType(.food)` on top of the four dietary
  quantity types (`HealthKitMealWriter.swift:28`), on the theory that authorization
  had to cover the correlation container as well as its samples. It does not:
  HealthKit **forbids** requesting authorization for an `HKCorrelationType` at all
  (read or share) and raises `NSInvalidArgumentException` the moment one appears in
  a `requestAuthorization` set. Apple's model is that you authorize only the sample
  types a correlation contains; saving the `.food` `HKCorrelation` itself is
  permitted with no container-level grant once every contained sample is authorized.
  - **Fix.** The share set is now **exactly** the four dietary quantity types
    (`dietaryEnergyConsumed`, `dietaryProtein`, `dietaryCarbohydrates`,
    `dietaryFatTotal`); the read set is unchanged. `HealthKitMealWriter.write` is
    untouched — `HKHealthStore.save` on the correlation was always legal with
    contained-type authorization only. An audit of both HealthKit-importing files
    confirmed this was the sole correlation type in any authorization set.
  - **Regression guard.** New `HealthKitAuthorizationTypesTests` asserts, against the
    pure exposed type sets, that (a) the share set is exactly those four dietary
    quantity identifiers and (b) no identifier in any authorization set (read or
    share) has the `HKCorrelationTypeIdentifier` prefix — making the whole class of
    bug unrepresentable, not just the one instance. Both assertions fail against the
    build-20 sets and pass after the fix. The live authorization sheet stays
    unexercisable in the sandbox, so this catches the defect at its own layer.

## [App 1.0 (20)] — 2026-07-06

### Added
- **Write logged meals to Apple Health** (PR 2 of the two-PR set; the bridge added
  the `JESSE_MEAL_LOG v1` directive in Bridge 0.4.0). When a diet-logging reply
  carries a `directives.meal_log`, the app writes each meal into Apple Health as a
  food correlation — the write-direction sibling of the read-only health context.
  - **Capability.** `NSHealthUpdateUsageDescription` added; the Settings "Connect
    Apple Health" request now also asks for dietary **write** access
    (`dietaryEnergyConsumed`, `dietaryProtein`, `dietaryCarbohydrates`,
    `dietaryFatTotal`). Write status is queryable (unlike read): if denied, the
    feature disables quietly and the Settings row says so.
  - **Seam + write shape.** A `MealWriting` protocol with `HealthKitMealWriter` —
    the second (and only other) HealthKit-importing file, keeping HealthKit confined
    to the provider files. Each meal is one `.food` `HKCorrelation` (start/end = the
    meal time; metadata carries the food name and the meal `id` as external
    identifier) containing one `HKQuantitySample` per present macro (kcal in
    kilocalories, macros in grams). Weight and workouts stay **read-only** — nothing
    else is written.
  - **Idempotency.** Written meal ids persist in SwiftData (`WrittenMeal`, additive
    lightweight migration); a `meal_log` whose id was already written is skipped, so
    a re-poll, Re-check, re-opened thread, or watch relay never double-writes.
  - **Reliability.** HealthKit writes succeed while the device is locked (so the
    watch-relay path works); a failed write enqueues into a persisted pending-writes
    store (`PendingMealStore`) drained on next foreground and next turn.
  - **Pure, tested pieces.** `MealLogParser` (v1 validation — field optionality,
    the 10-meal cap, strict ISO-8601 date parsing the bridge deferred, whole-block
    rejection so a bad block is never partially written) and a **display scrubber**
    that strips a trailing `JESSE_MEAL_LOG v1` line from streamed partial text before
    render (an unknown version is left visible — loud by contract). The final
    persisted text already comes stripped from the bridge.
  - **Settings.** A "Write meals to Apple Health" toggle
    (`WriteMealsToHealthSettings`), default on once write access is granted.
  - **Wire.** `meal_log` decoded on the poll result and SSE `done` frame
    (`JesseMealLog`/`JesseMeal`); `JesseReply.mealsToLog` validates it.

## [Bridge 0.4.0] — 2026-07-06

### Added
- **Dietary write-back directive (`JESSE_MEAL_LOG v1`).** A second entry in the
  same directive registry shipped in 0.3.0 — the **write-direction sibling** of
  `JESSE_NEEDS_HEALTH`. When a diet-logging reply's final non-empty line is
  `JESSE_MEAL_LOG v1 {json}`, the bridge parses + validates it, **strips the line**
  from the reply text, and attaches the parsed value under `directives.meal_log`
  on the terminal result (surfaced identically on the poll result and the SSE
  `done` frame, and persisted with the job — all via the existing
  `directives_to_value` seam). The app writes each meal into Apple Health as a food
  correlation (App PR, lands after this).
  - **Contract (version 1).** `{"meals":[{ "id", "consumedAt", "name", "kcal"?,
    "protein_g"?, "carbs_g"?, "fat_g"? }]}`. `id` is the stable per-meal
    idempotency key; `consumedAt` is ISO 8601 with offset; the four macros are
    numbers, each **optional — omitted when unknown, never null-padded** (so an
    absent macro is an absent key on the wire, and an explicit `null` is a
    rejection). A reply may log several meals; the array is non-empty and capped at
    **10**.
  - **Loud over silent.** A meal line that is malformed, over its **8 KiB** cap,
    over the 10-meal cap, or names an **unknown version** (`v2…`) passes through
    **untouched and visible** (logged), no field attached — a future contract bump
    fails loudly instead of half-parsing, and a bad block is never partially
    logged.
- **Per-directive line caps.** The directive extractor's byte cap is now
  **per-directive**: a generic outer ceiling (8 KiB, sized to the largest
  directive) is checked before dispatch, then each registry arm enforces its own
  cap — `JESSE_NEEDS_HEALTH` keeps its tight **2 KiB** bound, `JESSE_MEAL_LOG` gets
  **8 KiB**. A directive's contract now owns its own bound; `JESSE_NEEDS_HEALTH`'s
  observable behavior is unchanged.

## [App 1.0 (19)] — 2026-07-06

### Added
- **Classify-then-attach health context + the agent-driven retry.** The app no
  longer attaches the Apple Health block to every turn — it classifies each message
  and attaches only when relevant, and fulfills the agent's `JESSE_NEEDS_HEALTH`
  requests on a retry (PR 2 of the two-PR set; the bridge shipped the directive
  channel in Bridge 0.3.0).
  - **Two-tier classifier** behind the `HealthRelevanceClassifying` seam: a pure,
    word-boundary-aware **keyword floor** (`HealthKeywordClassifier`, always
    available, tested) UNION an on-device **Foundation Models** yes/no
    (`FoundationHealthClassifier`, prewarmed, 300 ms bound, degrading to the
    keyword answer on unavailable/timeout/error). Attaches when either says yes —
    biased toward attaching. The pure `HealthContextGate` gates on the master
    toggle: off ⇒ never attach and never fulfill.
  - **Retry machinery (`RunCoordinator`).** A reply that is a `JESSE_NEEDS_HEALTH`
    directive triggers **one** fulfillment retry per user message: the app reads the
    requested sections (`HealthContextFormatter`) and windowed metrics
    (`RequestableMetric` queries), re-sends the SAME text on the SAME thread with
    `health_context` + `health_context_requested`, and persists **only** the final
    answer (the empty sentinel turn is never recorded). If it can't fulfill (toggle
    off / no data) it retries once marked `health_context_unavailable` so the agent
    answers from vault data — no loop. A second directive on the retry is ignored;
    the answer is capped app-side.
  - **Windowed metric queries.** A fixed `RequestableMetric` whitelist (kept in sync
    with the bridge), daily-aggregate `HKStatisticsCollectionQuery` reads (1–31
    days), a pure `MetricSeriesFormatter`, and the `HealthRequestFulfiller` assembler
    with a 6 KiB app-side cap (under the bridge's 8 KiB). An unknown metric, an
    out-of-range window, or more than four metrics rejects the WHOLE request
    (never partially fulfilled).
  - **Wire.** `health_context_requested` / `health_context_unavailable` added to the
    request; `directives` decoded on the poll result and SSE `done` frame.

### Changed
- **`HealthKitWorkoutProvider` renamed to `HealthContextProvider`** (file + type,
  mechanical) — it reads more than workouts now. It remains the only HealthKit
  importer and gains the windowed-series reads behind the provider seam.

## [Bridge 0.3.0] — 2026-07-06

### Added
- **Agent-driven directive channel (`JESSE_NEEDS_HEALTH v1`).** A generic
  back-channel from the sandboxed agent's reply to the app: the final non-empty
  line of a reply may be a directive `JESSE_<NAME> v<N> {json}`. The bridge
  recognizes known directives via a small **registry** (this release ships
  `JESSE_NEEDS_HEALTH v1`; the planned dietary write-back adds `JESSE_MEAL_LOG v1`
  on the same extractor), parses + validates the payload against a fixed contract,
  **strips the line** from the reply text, and attaches the parsed value under a
  structured `directives` object on the terminal result. The `directives` field
  is surfaced **identically on the poll result (`GET /jesse/result`) and the SSE
  `done` frame**, and is persisted with the completed job. A directive-shaped line
  that is malformed, over the 2 KiB line cap, or names an **unknown directive /
  version** passes through **untouched and visible** (a loud contract failure,
  logged) with no field attached — a wrong classification only ever costs a slower
  answer, never a wrong one.
- **Health-request wrapper instruction.** When a turn carries **no**
  `health_context`, the prompt wrapper now tells the agent no Apple Health data is
  attached and how to ask for it (emit a single `JESSE_NEEDS_HEALTH v1` line,
  listing `sections` (`daily`/`workouts`) and/or whitelisted `metrics` with a
  `window_days` of 1–31, at most 4, at most once per turn). When the turn **does**
  carry `health_context`, the wrapper adds "requested or attached health data is
  included above; do not emit JESSE_NEEDS_HEALTH."
- **New optional request fields** `health_context_requested` and
  `health_context_unavailable` (both `Option<bool>`, `#[serde(default)]`). The
  first marks a retry answering a prior directive; the second tells the agent the
  app could not fulfill a request this turn (denied/locked/timeout/toggle off) so
  it answers from vault data and does **not** re-request — the request→retry
  channel can never loop.

### Changed
- **`MAX_HEALTH_CONTEXT_BYTES` raised 4 KiB → 8 KiB.** A *granted* metrics request
  (up to 4 metrics × ~31 daily lines, plus the two-section daily/workouts block)
  needs more headroom than the original recent-workouts-only block; the app
  hard-caps its own fulfilled response at 6 KiB, under this ceiling. An oversized
  block is still a `413` before any spawn.

## [App 1.0 (18)] — 2026-07-06

### Changed
- **Consistent error surfacing + an offline banner.** Error presentation was
  inconsistent: the transcript used inline color-coded text, attachments an inline
  caption, but the **Settings Keychain-save failure was an alert** — the lone
  outlier. That alert is now **inline red text** in the Auth section (the app's one
  error style), keeping the sheet open on a failed token write exactly as before.
- **Offline banner.** Mirroring the watch's `.queued` state, the conversation list
  now shows a "can't reach your Jesse bridge" banner when a `GET /health` probe
  comes back unreachable — so the phone signals offline **before** you compose and
  send, not only after a send errors. The probe uses a short-timeout session (so
  the banner appears promptly) and re-runs on launch, on foreground, and after
  Settings closes. The show/hide decision (`shouldShowOfflineBanner`) is a pure
  function, unit-tested failing-first; it never shows on an unpaired install (the
  pairing CTA covers that) nor before the first probe resolves.

## [App 1.0 (17)] — 2026-07-06

### Changed
- **Real iPad layout.** The app builds for iPad but the root was a plain
  `NavigationStack`, so iPad and landscape were just a blown-up phone. The root now
  branches on horizontal size class: **regular** width (iPad, landscape) gets a
  `NavigationSplitView` — the conversation list as a sidebar, the thread as the
  detail column, with a "Select a conversation" placeholder until one is chosen;
  **compact** width (iPhone, iPad portrait/Slide Over) keeps the original
  `NavigationStack`, so **iPhone behavior is unchanged**. Both share one source of
  truth — the existing `path` model, where the visible conversation is `path.last`
  — so selecting in the sidebar, tapping compose, and voice/push hand-offs all
  drive the detail the same way. The list rows are unchanged; the sidebar just adds
  a selection binding that's inert to the compact push.

## [App 1.0 (16)] — 2026-07-06

### Added
- **Live Activity for in-flight turns.** A turn can run for minutes; until now the
  only ambient signal was the terminal push. The elapsed timer and the human
  activity line ("Reading the vault…") — both already computed — are now surfaced
  via ActivityKit on the **Lock Screen and Dynamic Island**: the activity starts
  when a turn goes in flight, updates its line as Jesse works, and ends on
  completion, failure, or cancel. Elapsed renders as a self-ticking
  `Text(…, style: .timer)` anchored to the turn's start, so no per-second update
  crosses the process boundary.
  - **A new widget extension target** (`JesseWidgetsExtension`) hosts the
    `ActivityConfiguration`; `NSSupportsLiveActivities` is set on the app. The
    `ActivityAttributes` source is shared between app and extension.
  - **Purely additive** — the existing push-on-background-complete is untouched.
    ActivityKit is isolated behind a `TurnLiveActivityManaging` seam so
    `RunCoordinator` never imports it and the test suite injects a no-op; the
    turn-state → activity-content mapping (`TurnLiveActivity.step`) is a pure
    function, unit-tested failing-first. Activities are stamped with their thread
    id so a relaunch re-adopts them, and a foreground reconcile ends any stranded
    by a mid-turn kill.

## [App 1.0 (15)] — 2026-07-05

### Added
- **First-run pairing flow.** An unpaired user's first send just errored, with no
  guidance. The thread list's empty state is now gated on whether the app is
  configured (`ConfigStore.isConfigured` — host *and* bearer token both set): a
  paired-but-empty install shows the ordinary "No conversations yet / Tap +"
  prompt, while an unpaired one shows a **"Pair with your Jesse bridge"** call to
  action. Tapping it opens the existing Settings sheet straight to **Scan-to-pair**
  (both already worked; the CTA just routes to them). A half-paired config — host
  entered but no token — still reads as unpaired, since it can't send. The gate
  (`threadListEmptyState(for:)`) is a pure function, unit-tested failing-first.

## [App 1.0 (14)] — 2026-07-04

### Added
- **A real accent color, and phone haptics.** Two polish gaps closed:
  - `AccentColor` shipped empty (only `{"idiom":"universal"}`), so every
    custom-tinted surface — the user-bubble tint (`accentColor.opacity(0.15)`),
    the send affordance, the search-match highlight — silently resolved to the
    system blue. It now carries the brand indigo-blue from the app icon: `#5B7CF0`
    in light, lifted to `#7B96F5` in dark for contrast on a dark background.
  - The phone had no haptics (the watch already taps on reply). `ThreadDetailView`
    now uses the idiomatic iOS 17 `.sensoryFeedback` (not `UIFeedbackGenerator`):
    a light impact on send, a success tap when a reply lands, and an error tap
    when a failure surfaces. The completion tap keys off the turn count rising
    while the run is no longer in flight, so the optimistic user-turn append and a
    user Cancel stay silent.

## [App 1.0 (13)] — 2026-07-04

### Changed
- **Hands-free Siri now uses a "doorbell", not free-text capture.** Speaking to
  Jesse through Siri failed for three stacked reasons: the name "Jesse" collides
  with Siri's Contacts name resolution; the leading verbs "Ask"/"Tell" are
  Siri-reserved (they route to ChatGPT / Messages); and the old intents captured
  the open-ended request via `requestValueDialog`, which Apple documents as
  unreliable for spoken input. The fix separates the two jobs:
  - **A parameter-less wake intent (`WakeJesseIntent`) is the trigger.** Its only
    job is to foreground the app into listening mode — Siri never parses the
    request. Phrases are short, distinctive, and app-name-led ("Vault Search
    Jesse", "Hey Vault Search Jesse", "Vault Search Jesse listen", …); the
    reserved-verb phrases ("Ask Jesse", "Tell Jesse") are removed.
  - **`INAlternativeAppNames` gives Siri a distinct spoken name** ("Vault Search
    Jesse") without changing the display name, so the app-name token in each phrase
    no longer collides with the Contacts name "Jesse". *(SiriKit-lineage key —
    pending on-device confirmation that iOS 26 App Intents honor it.)*
  - **The request is captured in-app**, not via Siri: on wake the app records the
    spoken phrase (auto-stopping on trailing silence via the shared
    `SilenceDetector`, with a hard cap and a Stop/Cancel overlay) and transcribes
    it on-device with the existing `SpeechFrameworkTranscriber`, then runs it
    through the unchanged voice turn path. The typed and on-screen-dictation paths
    are untouched.
  - Adds `NSMicrophoneUsageDescription` (live capture needs the mic, not just
    speech recognition). The `AskJesseIntent`/`TellJesseIntent` intents remain for
    the Shortcuts-app / typed path.

## [App 1.0 (12)] — 2026-07-04

### Added
- **Attach a daily health summary alongside recent workouts.** The Apple Health
  block a turn carries — typed, Siri, and the watch relay — grows from just recent
  workouts into a two-section **health context**: a new **daily summary** (last
  night's sleep with deep/REM/core/awake minutes, resting heart rate, HRV, any
  low/high/irregular heart-rate events, VO2 max, 1-minute HR recovery, overnight
  respiratory rate / SpO2 / wrist-temperature deviation, walking steadiness and
  asymmetry, today's steps and active kcal, and latest weight) followed by the
  existing recent-workouts section. **Run** workouts now also show average running
  **power, ground contact time, vertical oscillation, and stride length**. Latest
  values only — the vault owns history — with each metric omitted when unavailable.
  - **Same guarantees as before.** Never blocks or delays a send (one combined
    ~1.5s timeout), silent per-metric degrade (a denied or missing metric is simply
    omitted, never an error), and one failing read never drops another. The whole
    block is self-capped at **3 KiB** (was 2 KiB), well under the bridge's 4 KiB
    ceiling; under pressure it drops the oldest workout lines first, then a
    boundary run's dynamics suffix, never truncating mid-line.
  - **HealthKit stays read-only and isolated.** One file
    (`HealthKitWorkoutProvider`) imports HealthKit, behind a `HealthContextProviding`
    seam; the daily-summary formatter, composer, classifiers, policy, resolver,
    gather, and timeout are pure and fully unit-tested. New read types are requested
    as a union so existing users get a single re-prompt for the delta; the app still
    writes nothing to Health.
  - **Settings → Apple Health:** the toggle becomes **"Attach health context"** (one
    switch for the whole block; the stored key is unchanged, so an existing user's
    choice carries over).

## [App 1.0 (11)] — 2026-07-04

### Added
- **Attach recent workouts from Apple Health.** With the feature connected, every
  turn — typed, Siri, and the watch relay — carries a compact, device-reported
  "recent workouts" block (newest first, last 48h, up to 5) so you can say
  "Log my swim" and Jesse logs it from real numbers (duration, distance, active
  kcal, avg/max HR) instead of asking. The block is sent as the bridge's optional
  `health_context` field (bridge 0.2.0+); an older bridge simply ignores it.
  - **Never blocks or breaks a send.** Unauthorized, no data, a query error, or a
    1-second timeout all attach nothing and the turn goes out anyway. The
    watch-relay case (HealthKit unreadable while the phone is locked) hits the same
    silent degrade.
  - **HealthKit is read-only and isolated.** One file (`HealthKitWorkoutProvider`)
    imports HealthKit, behind a `WorkoutContextProviding` seam; the formatter,
    attach policy, resolver, and timeout are pure and fully unit-tested. New
    `NSHealthShareUsageDescription` and a read-only HealthKit entitlement; the app
    writes nothing to Health.
  - **Settings → Apple Health:** a "Connect Apple Health" row (requests read access
    to workouts, heart rate, active energy, and swim/walk-run/cycle distance) plus
    an "Attach recent workouts" toggle (default off until connected once, then on).

## [Bridge 0.2.0] — 2026-07-04

### Added
- **Optional `health_context` on `POST /jesse`.** A turn may carry a compact
  "recent workouts" block (device-reported, from the phone's Apple Health) so the
  agent can log a workout the user refers to ("Log my swim") from real numbers
  instead of asking for them. When present and non-empty, the block is framed as
  **untrusted device DATA, not instruction**, and inserted right after the per-turn
  clock header, ahead of the safety floor. **Backward compatible:** the field is
  optional (`#[serde(default)]`) — an old app build that omits it produces
  byte-for-byte the same prompt as before. No new agent tool is granted; the
  existing `Read`/`Write`/`Edit` + `Skill(diet-logging)` already cover exercise
  logging.
- Bounded like the title endpoint: the block is capped at
  **`MAX_HEALTH_CONTEXT_BYTES` (4 KiB)** — an oversized block is rejected with
  `413` **before any `claude` spawn** (and before a concurrency permit is taken).
  ASCII control characters other than newline are stripped before the block is
  used, so a crafted block can't smuggle terminal escapes or NULs into the prompt.

## [App 1.0 (10)] — 2026-07-04

### Added
- **Paste images/PDFs into the composer.** A paste button beside the paperclip
  stages a copied screenshot, image, or PDF straight from the clipboard —
  including several items at once, up to the four-file cap — through the same path
  as the pickers, so pasted items inherit the same MIME/size/count limits, chips,
  previews, and send flow. A copied bitmap with no lossless original is re-encoded
  to PNG; anything unsupported or oversized is rejected with the existing inline
  message. `PasteButton` was chosen over a custom ⌘V/edit-menu override because it
  needs no clipboard-access prompt and shows no "pasted from…" privacy banner.

## [App 1.0 (9)] — 2026-07-03

### Fixed
- **Composer no longer collapses to one line.** The message input now holds a
  multi-line floor (at least three lines, growing to eight before it scrolls
  internally) even with attachment chips staged, an error visible, and the
  keyboard up. The composer also outranks the transcript for vertical space, so a
  tight screen makes the transcript scroll instead of squeezing the input.

## [App 1.0 (8)] — 2026-07-03

### Added
- **In-app camera capture.** The attachment (paperclip) menu now offers "Take
  Photo" — shown only on devices with a camera — to snap a photo and attach it
  right away, alongside picking an existing image or a PDF. The photo is
  JPEG-encoded and flows through the same staging path as the other pickers, so it
  inherits the same MIME/size/count limits (and the same thumbnail preview).
  Camera permission is requested when needed and handled gracefully if denied (a
  clear hint, no hang). The camera permission prompt now explains both uses (QR
  pairing and attaching photos).

## [App 1.0 (7)] — 2026-07-03

### Added
- **Attachment previews in history.** After you attach image(s) or PDF(s) and
  send, the conversation now shows a small thumbnail of each attachment on the
  message, instead of only a "📎 Attached: …" filename line. Optimized for
  storage: only a downscaled JPEG preview (longest side 320 px, a few KB) is
  persisted per attachment — never the original bytes. PDFs render their first
  page with a document badge. Thumbnails are generated off the main thread at send
  time; a preview failure never affects the message itself. The old "📎 Attached"
  text line is removed (the thumbnails, labeled by filename for accessibility,
  make it redundant).

### Changed
- Deleting a conversation or a message now also removes its stored attachment
  previews (cascade delete). Existing conversations upgrade in place with no data
  loss (additive lightweight SwiftData migration).

## [App 1.0 (6)] — 2026-07-03

### Changed
- **Word-level text selection in the transcript.** You can now long-press-drag to
  select individual words or ranges in any message — both your messages and
  Jesse's replies — instead of only copying a whole message. Whole-message Copy
  (raw Markdown) and Share moved from the bubble's long-press menu to a small
  actions button beside each message, so the long-press is free for text
  selection. User-message bubbles are now selectable too (previously only Jesse's
  replies had selection enabled, and even that was blocked by the long-press menu).

## [App 1.0 (5)] — 2026-07-03

### Added
- **Multi-token conversation search (Tier 1).** Search now matches when every word
  of the query appears anywhere in a thread's title or turn bodies, order- and
  gap-independently (e.g. "run bridge" finds "run over the bridge"). Tokens shorter
  than two characters are ignored unless the whole query is short (so "hi" still
  works). Case- and diacritic-insensitive, as before. This replaces the previous
  whole-query contiguous-substring match.
- **On-device query expansion (Tier 2), additive and optional.** When direct
  matches are thin, the app asks Apple's on-device Foundation Models (iOS 26) for a
  few alternate search terms (synonyms/rephrasings) and widens the result set to
  include them — never reordering or dropping base matches. Everything runs on the
  device; nothing is sent off it. A subtle "Also searching: …" caption explains the
  widened rows. Debounced, gated (only for real words with few direct hits),
  cached, and cancelled on query change; it degrades silently to Tier-1 whenever
  the model is unavailable, disabled, or fails.
- **Matched-text snippet on search rows.** While searching, each row shows a
  windowed excerpt centered on the first matched term with the match highlighted —
  including when the row matched only via an expansion term. Idle rows are
  unchanged (title + time).
- **Settings → Search:** a "Smart search expansion" toggle (default on) turns the
  Tier-2 model off entirely; Tier-1 multi-token search and snippets still work.

## [App 1.0 (4)] — 2026-07-02

### Added
- **Apple Watch app — talk to Jesse from your wrist.** A watchOS companion app
  (`Jesse Watch App`) plus the phone-side speech-to-text that backs it. One tap
  starts listening (no press-and-hold); the watch auto-stops on ~1.5 s of silence
  (with a hard max-record cap and a manual tap-to-stop), sends the audio to the
  phone, and shows Listening → "Jesse is thinking…" → the reply, speaking the
  spoken line aloud with a haptic on arrival. Ask/Tell toggle (default Ask).
  - **The watch never talks to the bridge and holds no bridge token.** It speaks
    only to the phone over WatchConnectivity. The phone transcribes the audio
    on-device (`SFSpeechRecognizer`, offline where supported) and feeds the text
    into the existing `WatchRelay` entry point (`voice: true`), so the exchange
    lands in the phone's history tagged `watch` — reusing the one turn/persistence
    path, no fork.
  - **Two-path reply delivery.** The phone answers on `transferUserInfo` (reliable,
    background-delivered source of truth) AND `sendMessage` when reachable
    (immediacy); the watch de-dupes by `requestId` so a reply renders and speaks
    once. A turn sent while the phone is unreachable is queued ("will send when
    your phone is reachable"), never silently dropped.
  - **Shared, tested seams.** A pure WatchConnectivity wire codec (value ↔
    `[String: Any]`, rejects malformed/oversized payloads), a pure end-of-speech
    silence detector over metering samples, and pure reply-dedup-by-requestId are
    compiled into both the phone and the watch and unit-tested from the iOS test
    target. The phone STT path is tested behind an injectable transcriber seam
    (fake transcript → relayed text, `voice: true`, thread tagged `watch`).
- The phone gained a Speech-recognition usage string; the watch a microphone
  usage string.

## [App 1.0 (3)] — 2026-07-02

### Added
- **Watch-relay foundation (phone side).** Groundwork for relaying a spoken turn
  from an Apple Watch through the phone, without the watch app yet (that's the
  next PR):
  - `JesseThread` gained an `origin` tag (`ThreadOrigin` — `phone`/`watch`, with a
    lightweight-migrating default of `phone`), so a relayed conversation can be
    told apart from an app-started one. An old store with no `origin` reads as
    `phone`, no migration code.
  - `WatchRelay` — the entry point the watch will call in PR2 — takes a relayed
    turn as a value (`RelayedTurn { requestId, text, mode, voice }`), runs it
    through the **existing** `RunCoordinator`/`JesseClient` turn path (new
    `RunCoordinator.runRelayTurn`, reusing the same send → poll → `TurnWriter`
    flow — no forked networking or persistence), tags the created thread `watch`,
    appends the user and Jesse turns to normal history, and returns a small
    `RelayResult { displayText, spokenText, sessionId, threadId }`. It
    deduplicates by `requestId` (a retried id never starts a second turn) and, on
    failure, returns a clean error value rather than throwing.
  - A **Watch** scope in the thread list (`ThreadOriginScope`/`threadMatchesOrigin`,
    a pure Foundation-only predicate) shows only watch-originated threads. It
    composes with the existing search and Favorites filters and keeps
    date-sectioning (filter before grouping).
- No bridge, WatchConnectivity, audio, or speech-to-text yet — all phone-side
  plumbing, fully unit-tested.

## [Bridge 0.1.1] — 2026-07-02

### Added
- `/health` now returns the bridge `version` (the crate version) unconditionally,
  before the auth-gated operator fields — a version string isn't sensitive.
- The startup banner shows the running version: `Jesse Bridge v0.1.1 → http://…`.

### Changed
- Version increments are now mandatory and enforced. `scripts/version-guard.sh`
  fails a commit that changes `bridge/` without bumping `bridge/Cargo.toml`'s
  version (and adding a CHANGELOG entry); a tracked pre-push hook
  (`scripts/hooks/pre-push`, installed via `scripts/install-hooks.sh`) blocks such
  a push locally, and CI re-checks.

## [App 1.0 (2)] — 2026-07-02

### Added
- Settings shows a **Version** section: the app's own version and build (read from
  the bundle, never hardcoded) and the last-seen **bridge** version from
  `GET /health` (or "unknown" until first fetched).
- `JesseClient.health()` (behind `JesseClientProtocol`) parses the bridge version;
  `BridgeVersionStore` persists the last-seen value for display.

## [Bridge 0.1.0] — baseline

Initial baseline of the Rust bridge: headless `claude -p` runner behind bearer
auth over a Tailscale-only bind, with the job store (turn-survives-disconnect),
SSE live streaming, cancel, prompt overrides, `/jesse/title`, and optional APNs
push.

## [App 1.0 (1)] — baseline

Initial baseline of the SwiftUI app: conversation threads, Ask/Tell modes,
Markdown rendering, spoken replies, Siri shortcuts, QR pairing, attachments,
thread history/search/folders, and AI conversation titles.
