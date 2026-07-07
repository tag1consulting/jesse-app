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
