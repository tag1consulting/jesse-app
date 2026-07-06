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
