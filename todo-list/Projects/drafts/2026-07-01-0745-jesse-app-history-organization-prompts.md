# Jesse App — History Organization Prompts (Claude Code)

Goal: make the conversation list better at *finding old prompts* — the four asks were (1) group after 3 days not 7, (2) an AI summary explaining what a group contains, (3) better per-prompt descriptions than "first few words", (4) native iOS search. Constraint: **favorites must stay useful for jumping back to older prompts with key info.**

## Recommendation before you run anything

Run **Prompt 1 only first, live with it a few days, then decide on 2–3.** Prompt 1 delivers three of the four asks (3-day grouping, native search, richer descriptions) plus favorites hardening — all app-only, no network, no cost, no staleness, fully gated by `xcodebuild test`. It very likely covers most of the "track down a conversation" need on its own.

Prompts 2–3 add the **AI group summary** (ask #2). That one costs a bridge round-trip per group, real money/battery, and goes stale as threads move between buckets — see the devil's-advocate notes at the bottom. Don't build it until Prompt 1 has shown you what's still missing. If you decide to, 2 (bridge) must merge and deploy before 3 (app).

Each ``` block is self-contained — paste one into a fresh Claude Code session opened in `~/devel/tag1/jesse-app` (GitHub `tag1consulting/jesse-app`). Each is its own PR. Line numbers are hints against the code as last read on 2026-07-01; the agent must confirm them, not trust them.

---

## Standing rules (embedded in every prompt below — repeated so each session is self-contained)

- **Work on a branch, open a PR against `main`. Never commit to `main`.**
- **No Claude/AI attribution** anywhere — commit messages, PR text, code comments, docs.
- **No personal infra in tracked files** — keep `STATUS.md` gitignored; use the existing placeholder host/IP convention, never the real tailnet name/IP.
- **Every behavior change ships with a regression test you first prove FAILS against the current code** (run it, paste the failure), then make pass. A fix/feature without a failing-first test is not done.
- **Root-cause work only — no kludges, stop-gaps, or half-fixes.** If something's blocked, stop and say what's blocking it; do not route around it.
- **App PRs:** done = green local `xcodebuild test -scheme Jesse -destination 'platform=iOS Simulator,name=iPhone 17'` (swap for an installed sim — `xcrun simctl list devices`) with the **test count reported**, plus `bash scripts/ci-guards.sh` passing from the repo root. The Swift app is NOT in GitHub CI, so local `xcodebuild test` is the real gate; the bridge CI job must stay green (app PRs don't touch `bridge/`).
- **Bridge PRs:** done = green PR CI (`cargo build --release`, `cargo test`, `cargo clippy -- -D warnings`, `scripts/ci-guards.sh`). Update `bridge/README.md` / `SECURITY.md` / `STATUS.md` where contracts or behavior change.
- Read `README.md`, `SECURITY.md`, `bridge/README.md`, and `STATUS.md` first for the bridge↔app contract.

---

# Prompt 1 — iOS app: 3-day grouping, native search, richer descriptions, favorites intact (app-only, no network)

```
You are working in the jesse-app repo (GitHub tag1consulting/jesse-app, default branch main). It has a Rust bridge (bridge/) and a SwiftUI iOS app (Jesse/Jesse, tests in Jesse/JesseTests). This task touches the iOS app ONLY — no bridge, no network, no new server contract. The GitHub CI builds/tests the BRIDGE only and runs scripts/ci-guards.sh over the whole tree; the Swift app is NOT in CI, so your local `xcodebuild test` is the gate and ci-guards must still pass. Read README.md and STATUS.md first.

STANDING RULES (follow all): branch feature/app-history-organization, PR against main, never commit to main. No Claude/AI attribution anywhere. No personal infra in tracked files (STATUS.md stays gitignored). Test with `xcodebuild test -scheme Jesse -destination 'platform=iOS Simulator,name=iPhone 17'` (installed simulator). Every behavior change ships with a regression test you first prove FAILS against current code (paste the failure), then make pass. Root-cause only, no kludges. Done = green xcodebuild test with the test count reported + ci-guards passing. Update STATUS.md with a dated entry per change.

Context you can rely on (confirm the line numbers, don't trust them):
- Date bucketing lives in ThreadSectioning.swift — a pure Foundation function threadSection(for:now:calendar:). Today the day-granular window is the last 7 days: today, yesterday, weekday(2...6 days ago), month(7+ days ago). See the switch at ~line 68-78 (the `case 2...6` arm) and the file header comment at ~line 6-13.
- ThreadListView.swift renders the list: a segmented All/Favorites picker (favoritesOnly @AppStorage, ~line 17-36), `visible` = favoritesOnly ? threads.filter(\.isFavorite) : threads (~line 21-23), groupedSections buckets `visible` via threadSection (~line 114-122), and ThreadRow (~line 164-193) shows title + `.relative` last-activity time + a running dot.
- Thread titles are derived ONCE from the first user message (JesseThread.deriveTitle, Models.swift ~line 81-90: first line, 60-char prefix + ellipsis) at RunCoordinator.swift ~line 211, and never updated after. A Turn has role/text/createdAt; JesseThread.orderedTurns is chronological.
- Favorites = JesseThread.isFavorite/favoritedAt (Models.swift ~line 26-60); existing coverage in FavoritesTests.swift; sectioning coverage in ThreadSectioningTests.swift.

Implement the following, each with tests. Keep the pure/testable split this codebase already uses (ThreadSectioning is Foundation-only for exactly this reason) — put new logic in pure functions unit-tested without a view host, not buried in `body`.

1. GROUP AFTER 3 DAYS, NOT 7. In threadSection, shrink the day-granular window so only the last 3 days get individual day headers and everything older rolls up by month: today (0 days ago), yesterday (1), one weekday section (2 days ago), and month for 3+ days ago. Concretely the weekday arm becomes `case 2` and the `default` (month) arm covers 3+. Update the ThreadSection file-header comment to describe the 3-day window accurately. Test: extend ThreadSectioningTests so a thread exactly 3 days ago lands in its MONTH section (this must fail against the current 7-day code — paste the failure), a thread 2 days ago is a weekday section, boundaries at 2/3 days are asserted with a fixed `now`+calendar. (Note to the implementer: I chose days 0/1/2 shown individually and 3+ grouped as the meaning of "after 3 days." If that off-by-one is wrong, flag it in the PR rather than guessing differently.)

2. NATIVE iOS SEARCH over titles AND conversation content. Add SwiftUI `.searchable` to the thread list so typing filters conversations. Requirements:
   - Factor the match into a PURE, testable predicate, e.g. `func threadMatches(_ thread: JesseThread, query: String) -> Bool` (or a filter over a lightweight value type) in its own Foundation-only file, mirroring ThreadSectioning. It must match against the thread title AND the text of its turns, case- and diacritic-insensitive (use localizedStandardContains / localizedCaseInsensitiveContains). A whitespace-only/empty query matches everything (search inactive).
   - Apply the filter to `visible` BEFORE grouping, so results stay date-sectioned, and so it composes with the All/Favorites picker (searching inside the Favorites tab searches only favorites).
   - No matches → ContentUnavailableView.search(text:) empty state; clearing the query restores the full list.
   - Tests: unit-test the predicate directly over hand-built threads/turns — matches title, matches a word that appears only in a turn body (not the title), case/diacritic-insensitive, empty query returns all, no-match returns none. Prove at least one case (turn-body match) fails if the predicate only looked at the title.

3. RICHER PER-ROW DESCRIPTION (no AI, no network). The row today shows only the derived title (first ~60 chars of the FIRST user message). Add a secondary preview line so a row conveys where the conversation actually went — e.g. a single-line, whitespace-collapsed snippet of the LATEST turn (Jesse's most recent reply, or the last user turn if none), distinct from the title, `.lineLimit(1-2)`, `.secondary`/`.caption`. Factor the snippet into a pure `func rowPreview(for: JesseThread) -> String` (Foundation-only, testable). HARD CONSTRAINT: the literal derived title stays as line 1 unchanged — do NOT replace or paraphrase it. Favorites are remembered by their literal first words; the preview augments, never supplants. An empty thread (no turns) shows no preview line, not a crash. Test the pure function: latest-turn snippet, newline collapsing, empty-thread returns "".

4. FAVORITES STAY FIRST-CLASS (verify, don't regress). After the above: the Favorites tab must still list starred threads of ANY age (a favorite from 3 months ago appears under its month section in the Favorites tab); search must find favorites (both tabs); the star swipe-action and star glyph still work. Add/extend a test asserting an old favorited thread is still surfaced by both the Favorites filter and a content search that matches one of its turns. Do NOT reorder or pin — just prove nothing here got hidden by the grouping/search changes. (If you think a pinned Favorites section at the top of the All view is warranted, DON'T build it — note it in the PR as a proposed follow-up.)

Before finishing: run the full suite, report the test count and that it's green, run ci-guards, push the branch, open the PR, confirm the bridge CI job stays green.
```

---

# Prompt 2 — Rust bridge: one-shot summarize endpoint (bridge PR; required only for the AI group summary in Prompt 3)

```
You are working in the jesse-app repo (GitHub tag1consulting/jesse-app, default branch main), in bridge/ (single file bridge/src/main.rs; unit tests are the #[cfg(test)] mod at the bottom; the Axum router is app() at ~line 2826 with routes /health, /jesse, /jesse/prompts, /jesse/result/:id, /jesse/stream/:id, /jesse/cancel/:id, /jesse/device, /jesse/notify/:id). The GitHub CI runs cargo build --release, cargo test, cargo clippy -- -D warnings, and scripts/ci-guards.sh — green CI on the PR is the gate. Read bridge/README.md and SECURITY.md first: bearer-auth (constant-time ct_eq — ci-guards greps for it), the rate limiter, per-attempt timeouts, the tool allowlist/denylist, the 0.0.0.0-bind guard, and the lock-discipline invariant all apply and must be preserved.

STANDING RULES (follow all): branch feature/bridge-summarize, PR against main, never commit to main. No Claude/AI attribution anywhere. No personal infra in tracked files. Test locally with `cargo build --release && cargo test && cargo clippy -- -D warnings && bash scripts/ci-guards.sh` (guards from repo root). Every behavior ships with a test you first prove FAILS against current code, then make pass. Root-cause only, no kludges. Done = green PR CI. Update bridge/README.md / SECURITY.md / STATUS.md.

Goal: add a lightweight, stateless endpoint the app calls to get a SHORT natural-language summary of a set of conversation descriptions. This backs the app's "AI summary of a date group" feature. It is NOT a turn: no job is created, nothing is persisted, no session, no streaming, no push.

First, verify current behavior and paste into the PR: how a turn is actually invoked end to end — build_claude_args (~line 1398), the streaming runner, ClaudeOutcome, the per-attempt timeout, the auth check, and the rate limiter. Reuse those primitives; do not fork a second claude-invocation path with weaker discipline.

Implement:

1. POST /jesse/summarize:
   - Same bearer auth as /jesse (constant-time compare; 401 without/with-wrong bearer). Same rate limiter. Reuse the existing bind/allowlist posture unchanged.
   - Request body (Codable, match the existing struct style — no stringly-typed JSONSerialization): { "items": [String], "kind": "group" } where items are short thread titles/descriptions to synthesize (also accept a single "text" field, your call — keep it minimal and documented). Enforce a strict input cap: max item count and max total input bytes (pick sane bounds, name them as consts, document them); over the cap → 413/400, not a giant claude call.
   - Runs claude -p ONCE with a fixed instruction to produce ONE short sentence (roughly 10–20 words) naming the themes the items share — useful but skimmable, never a wall of text. No session id, no persistence, no stream, no job entry, no eviction interaction.
   - Bound it with a SHORT timeout (tighter than a normal turn — this is interactive UI latency); on timeout/failure return a clean non-2xx the app can degrade from (the app must treat "no summary" as normal, never an error to the user). Never fatal to the bridge.
   - Response: { "summary": String }.
   - Keep the lock-discipline invariant — this path should touch none of the jobs/streams/aborts mutexes.

2. Tests (each failing-first where it asserts new behavior): auth required (401 no/bad bearer, 200 with); oversized input rejected before any claude spawn; happy path returns a summary using the repo's fake-claude test harness (the pattern the cancel/stream tests use); the timeout bound is enforced with a fake-claude that stalls; malformed body → 400. Add the route to the app() router tests.

3. Docs: add the endpoint to bridge/README.md (contract, caps, that it's stateless/non-persisting) and to the SECURITY.md tool/endpoint table. Confirm ci-guards still passes (the constant-time-auth grep, bind guard, etc. must still fire).

Run cargo build/test/clippy + ci-guards, push, open the PR, confirm CI green before declaring done. NOTE: merging does not update the running bridge — after merge, on the Studio: pull main, cargo build --release, restart the launchd job. State in the PR that the live restart is a separate deploy step (the app feature in the next prompt won't work until the bridge is redeployed).
```

---

# Prompt 3 — iOS app: AI summary per date group, cached and staleness-aware (app PR; run after Prompt 2 merged AND the live bridge redeployed)

```
You are working in the jesse-app repo (GitHub tag1consulting/jesse-app, default branch main), iOS app in Jesse/Jesse, tests in Jesse/JesseTests. This touches the app only. It depends on the POST /jesse/summarize endpoint added in the feature/bridge-summarize PR being merged AND the live bridge redeployed — if that endpoint isn't present, the feature must degrade to showing no summary, never an error. The Swift app is NOT in GitHub CI; local `xcodebuild test` is the gate and ci-guards must still pass. Read README.md, STATUS.md, and JesseClient.swift (the app's HTTP client — extend it, match its Codable request/response and auth pattern) first.

STANDING RULES (follow all): branch feature/app-group-summaries, PR against main, never commit to main. No Claude/AI attribution anywhere. No personal infra in tracked files. Test with `xcodebuild test -scheme Jesse -destination 'platform=iOS Simulator,name=iPhone 17'`. Every behavior ships with a failing-first regression test (URLProtocol stub for the HTTP call, like JesseIntegrationTests). Root-cause only, no kludges. Done = green xcodebuild test with count reported + ci-guards passing. Update STATUS.md.

Goal (ask #2): each ROLLED-UP date group (the month sections — NOT Today/Yesterday/the single weekday, which are short and self-evident) shows a one-line AI summary of what it contains, big enough to be useful but small enough to skim (one short sentence). It must be cached, regenerate only when the group's contents change, and degrade silently when the bridge is unreachable.

Implement:

1. Client call: add a summarize(items:) method to JesseClient that POSTs to /jesse/summarize with the same bearer/host config as other calls, decoding { "summary": String }. Match the app's existing Codable request/response style. Treat any failure (offline, endpoint missing/404, timeout, non-2xx) as "no summary available" — return nil, never throw to the UI.

2. Caching + invalidation (this is the hard part — get it right, no re-summarizing on every render):
   - Compute a STABLE content hash for a group from its member threads (their ids + updatedAt), in a pure, testable function. The hash changes iff the set of threads in the group or their last-activity changes.
   - Cache summaries keyed by (group identity + content hash) — a small dedicated store (a SwiftData cache model or a keyed UserDefaults blob; justify the choice). A cache hit with a matching hash renders instantly and makes NO network call. A miss (new group, or hash changed because a thread moved in/out or got a new turn) triggers exactly one generation.
   - Generation is lazy and per-visible-group: kick it off when a rolled-up section appears without a fresh cached summary; show a subtle "Summarizing…" affordance meanwhile; write the result to cache. Never block the list, never re-fire while one is in flight for the same group, never fire for Today/Yesterday/the weekday section.

3. Render: show the summary as section header/footer subtext under the month title, .secondary/.caption, lineLimit small. If summary is nil (not yet generated, or bridge unreachable) show nothing extra — no error UI, no spinner that never resolves.

4. Favorites stay useful (HARD): summaries are additive context on the section, never a replacement for rows. Every thread row stays individually visible and tappable inside its group; favorites (star glyph, Favorites tab, search from Prompt 1) are untouched; a favorited thread is never collapsed away behind a summary. Add a test asserting rows remain present and favorites remain individually reachable when a group summary is shown.

5. Tests (failing-first where asserting new behavior): the pure content-hash function (same members → same hash; add a turn / move a thread → different hash); cache hit makes zero network calls (assert via the URLProtocol stub / an injected client seam); a hash change triggers exactly one regeneration; a stubbed 404/timeout yields nil and the list renders with no error and all rows intact; Today/Yesterday/weekday sections never call summarize.

Run the full suite, report the test count and that it's green, run ci-guards, push, open the PR, confirm the bridge CI job stays green. State in the PR that this only works against a bridge that has the /jesse/summarize endpoint deployed.
```

---

## Devil's advocate — read before committing to Prompts 2–3

- **The AI group summary is the expensive, uncertain 25% of this.** Prompt 1's three wins (3-day grouping, content search, richer previews) are what actually let you *find* a conversation, and they're free, instant, offline, and never stale. Ship 1, then ask yourself what's still hard to find. If the answer is "nothing," skip 2–3.
- **Group summaries go stale by construction.** A "June 2026" bucket changes every time a thread gets a new turn or a favorite is added — the cache-invalidation logic in Prompt 3 exists precisely because the thing being summarized won't hold still. That's inherent complexity you're buying, plus a bridge round-trip and `claude -p` cost per (re)generation.
- **Redundancy risk.** Once every row has a good preview line (Prompt 1 #3) and search matches turn content (#4), a one-sentence "this month was mostly Tag1 ops and marathon training" may add little over just scanning the rows. Judge that against a real, populated list before building it.
- **Privacy/cost.** Summarize sends conversation titles/descriptions back through `claude -p`. Low, but non-zero, and it's per-group.
- **Favorites verdict:** the 3-day change does NOT hurt favorites — the Favorites tab shows starred threads of any age regardless of grouping, and Prompt 1 explicitly keeps literal titles + adds content search so an old favorite stays findable. If after living with it favorites still feel buried, the cheap fix is a pinned Favorites section at the top of the All view (flagged as a follow-up in Prompt 1, not built).

---

- [ ] Archive (extract knowledge, then archive)
- [ ] Deep extract (comprehensive knowledge extraction, then archive)
- [ ] Archive only (skip extraction, archive as-is)
