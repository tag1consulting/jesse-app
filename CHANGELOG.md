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
