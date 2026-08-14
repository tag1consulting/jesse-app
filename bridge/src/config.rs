use crate::*;

// ---- Config (env-driven) --------------------------------------------------

// Hard upper bound on any single turn, regardless of JESSE_TIMEOUT. A request
// cannot pin a `claude` child (and a concurrency permit) for longer than this.
// Raised to 2h so a long agent turn (a big refactor, a deep vault sweep) can run
// to completion; the per-request JESSE_TIMEOUT (default 90m) still applies under it.
pub const HARD_TIMEOUT_CEILING: u64 = 7200;

// Default per-turn run limit (env `JESSE_TIMEOUT`), clamped to
// [1, HARD_TIMEOUT_CEILING] by `clamp_timeout_secs`.
//
// Raised 3600 → 5400 after a real turn was killed at the hour mark with ~60 minutes of
// finished work already on disk: an hour is under, not over, what a deep refactor or a
// full vault sweep takes, and the ceiling above still bounds the worst case. A turn that
// DOES hit the limit no longer dies silently — it returns what it had (see
// [`crate::turntrace`]).
pub const DEFAULT_TIMEOUT_SECS: u64 = 5400;

// How long a finished-but-unretrieved reply is held before TTL eviction. Raised
// to 24h so a reply that completes while the phone is away (suspended, off the
// tailnet) is still there when it re-checks. The clock for a completed job only
// starts at FIRST successful retrieval (see `DEFAULT_RETRIEVAL_GRACE_SECS`); an
// unfetched reply gets the full window.
pub const DEFAULT_JOB_TTL_SECS: u64 = 86_400;

// Once a completed reply has been fetched at least once, it's kept only this much
// longer (a short grace so an immediate re-poll still succeeds) rather than for
// the full TTL — a fetched reply shouldn't linger for a day. This is the old
// pre-24h window, repurposed as the post-fetch grace.
pub const DEFAULT_RETRIEVAL_GRACE_SECS: u64 = 600;

// Default depth of the turn wait queue in front of the concurrency semaphore
// (env `JESSE_MAX_QUEUED`). When a permit isn't free, up to this many turns may
// WAIT for one; beyond it, load is shed with 429. Floor 0 (0 → no queue: an
// unavailable permit sheds immediately, the pre-queue behavior).
pub const DEFAULT_MAX_QUEUED: usize = 4;

// Age, in days, past which the session GC sweep reclaims a vault-project Claude
// Code session (env `JESSE_SESSION_TTL_DAYS`). Resuming a session touches its
// jsonl mtime, so the sweep never reclaims an actively-used thread — only the
// orphans (a swipe-delete whose remote delete never reached the bridge, and
// everything deleted locally before the delete-on-thread-delete flow existed).
// 90 days is a generous floor well past any realistic active-thread gap.
pub const DEFAULT_SESSION_TTL_DAYS: u64 = 90;

// Hard timeout (seconds) for the contained read-only vault-QA child. Tighter
// than a turn: the child reads a handful of vault files (Read/Grep/Glob, and the
// qmd MCP search when configured) and answers from them — a bounded lookup, not
// an agent turn. On overrun the ladder degrades to the hosted turn (rung 2). A
// const, not env-tunable: it bounds a latency-sensitive local answer, not an
// operator-managed workload, mirroring `TITLE_TIMEOUT_SECS`.
//
// Raised 25 → 60 after the vaultqa-v1 bake-off (2026-07-14) measured the winning
// oss backend's lookups at 10–42 s WALL: a 25 s ceiling would have timed out most
// real lookups (rung-2 fall-throughs) despite the model answering correctly. 60 s
// clears the measured 42 s max with headroom while still bounding the child well
// under a full turn.
pub const VAULTQA_TIMEOUT_SECS: u64 = 60;

// The notes subdirectory inside the vault repo (`$JESSE_VAULT/<VAULT_SUBDIR>`). It was
// `todo-list` until the 2026-08-06 relocation renamed it to `vault` (repo moved to
// `~/jesse`, so the Obsidian vault is `~/jesse/vault`). Anything that composes a path
// under the notes root uses THIS, never a bare literal, so the next rename is one edit.
//
// NOTE on citations: model-authored citations still arrive `todo-list/`-prefixed — that
// prefix is QMD's collection NAME (unchanged) and the vault's wiki-link convention, not a
// real directory. `citations::normalize_candidates` therefore accepts BOTH spellings and
// resolves them against this subdir. Do not "clean up" that tolerance.
pub const VAULT_SUBDIR: &str = "vault";

// Hard timeout (seconds) for the EMERGENCY vault-QA child (Piece 4). Looser than
// the routine `VAULTQA_TIMEOUT_SECS` because there is no ladder rung below it: when
// hosted is unavailable the emergency answer is the only answer, so it is worth
// waiting longer for a best-effort local reply than to fail fast. A const, not
// env-tunable, for the same reason the routine timeout is.
pub const EMERGENCY_TIMEOUT_SECS: u64 = 120;

// Short, fixed timeout for the stateless title endpoint (`POST /jesse/title`).
// Much tighter than a turn's JESSE_TIMEOUT (default 5400s) because a title is
// interactive UI latency, not a full agent turn: on overrun the app just
// degrades to its own derived title. Deliberately a const, not env-tunable — it
// bounds a UX nicety, not an operator-managed workload.
pub const TITLE_TIMEOUT_SECS: u64 = 20;

// Captured agent stdout is truncated to this many bytes before parsing so one
// pathological run can't balloon the bridge's memory. The JSON envelope the
// bridge cares about is kilobytes; multiple MB is already pathological.
pub const MAX_OUTPUT_BYTES: usize = 4 * 1024 * 1024;

// ---- Attachment caps (env-overridable defaults) ---------------------------
//
// Attachments are decoded from base64 in the request body, validated by
// magic-byte sniff against a MIME whitelist, written to a per-request scratch
// dir the headless agent reads, then deleted when the turn ends. These cap the
// new file-input attack surface; keep them in sync with SECURITY.md.

// Max attachments accepted on a single turn.
pub const DEFAULT_MAX_ATTACHMENTS: usize = 4;
// Max decoded size of any one attachment.
pub const DEFAULT_MAX_ATTACHMENT_BYTES: usize = 10 * 1024 * 1024;
// Max decoded size of all attachments on a turn combined.
pub const DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES: usize = 20 * 1024 * 1024;

// Least-privilege default tool allowlist for the headless agent. Scoped to what
// the vault's Ask/Tell workflows actually need: file read/write/search, the
// read-only QMD vault-search MCP tools, and a few scoped shell verbs (git for
// vault history, mv/ls/cat/find for file wrangling). Bare `Bash` is deliberately
// absent — only the `Bash(<verb>:*)` scopes below are allowed. Override with
// JESSE_ALLOWED_TOOLS. Keep in sync with the table in SECURITY.md.
//
// The `Bash(date:*)` / `Bash(cal:*)` scopes back up the per-turn clock header
// (see `prompt::clock_line`) for on-demand relative date math and alternate
// formats — both are pure computation with no side effect reachable as a
// non-privileged user (`date -s` needs root and simply fails; `cal` only prints).
// The `Bash(head:*)` / `Bash(tail:*)` / `Bash(wc:*)` scopes are strictly
// read-only, no writes and no network — they round out the existing read set
// (`cat`, `ls`, `find`, plus `Grep`/`Glob`) so the agent can inspect the large
// diet CSVs and logs without slurping a whole file. None of the five can write,
// send, or reach the network, so the action surface is unchanged.
//
// The three `Bash(node vault/<script>.js:*)` scopes let a food/exercise/
// weigh-in log REGENERATE the dashboard cache (`diet-today.js`) from the CSV
// source of truth and re-run its two guards — the per-item-log step the vault's
// Diet-Logging-Flow prescribes. Without them the agent could append the CSV row
// but not rebuild the cache, leaving `diet-today.js` stale (the 2026-06-27
// phantom-banana bug). They are pinned to the THREE exact script paths, NOT
// `Bash(node:*)` — a bare `node` scope would allow `node -e "<arbitrary JS>"`,
// i.e. arbitrary code execution from a phone request. cwd is the vault (see
// `run_claude`), so the relative paths resolve there.
//
// `Skill(diet-logging)` lets the agent auto-invoke the vault's `diet-logging`
// skill (`.claude/skills/diet-logging/SKILL.md`) on a food/exercise/weigh-in
// mention. The Skill tool only LOADS instruction text — it executes nothing
// itself; every real action the skill prescribes still flows through the
// already-scoped `Read`/`Write`/`Edit` and the three `Bash(node vault/*.js:*)`
// scripts above, so the action surface is unchanged. It is pinned to the SINGLE
// named skill, NOT a bare `Skill` (which would let any future vault skill run
// from a phone request) — the narrowest scope the CLI accepts
// (verified against claude 2.1.195). cwd is the vault, so the skill is discovered
// from `.claude/skills/` there.
// ---- The 0.82.0 morning-run batch, and what each line really costs -----------
//
// Added so the bridge's SCHEDULED jobs can finish their own work. These are the
// headless morning/overnight chain's grants, not a desktop convenience: a desktop
// `settings.local.json` grant does NOTHING here, because this allowlist is the
// child's whole world and the two do not union.
//
// EVERY CLAIM BELOW WAS MEASURED ON 2026-08-14 against claude 2.1.231 and the
// binaries this host actually runs, not read off a manual.
//
// THE MATCHER, FIRST, BECAUSE THREE OF THESE GRANTS DEPEND ON ITS SHAPE. A
// `Bash(<prefix>:*)` rule matches at ARGUMENT-TOKEN granularity with a free tail:
//   * `gh api repos/O/R/pulls:*` ALLOWS `gh api repos/O/R/pulls --method GET`
//     (positive control: it ran and returned a 404 from a nonexistent repo)...
//   * ...and REFUSES `gh api repos/O/R/pulls/1/merge --method PUT`, because
//     `pulls/1/merge` is a different token than `pulls`. A raw string prefix would
//     have matched it; this does not.
//   * A MID-STRING GLOB DOES NOT MATCH: a rule `.../pulls/*/reviews:*` refused
//     `.../pulls/7/reviews`, and `.../pulls/*:*` refused it too — `*` does not
//     cross `/`. So an endpoint can be pinned exactly or not at all.
//   * SHELL CHAINING IS CAUGHT: under `Bash(node --check:*)`, the command
//     `node --check ok.js && node ./mod.js` was split and the second half refused.
// The tail being free is the load-bearing half. Read every grant below as
// "this prefix, plus ANY further arguments".
//
// THE INTERPRETERS WERE GRANTED, MEASURED, AND WITHDRAWN THE SAME DAY. This is the
// load-bearing history, because the obvious next edit to this file is to add them
// back. On 2026-08-14 the batch first carried `Bash(node --check:*)`,
// `Bash(node -c:*)`, `Bash(python3:*)`, `Bash(/usr/bin/python3:*)`,
// `Bash(duckdb:*)`, `Bash(uniq:*)`, `Bash(cp:*)` and `Bash(mkdir:*)`. The live
// containment battery answered them in one run:
//
//   * `write_escape_parent`, `write_escape_symlink` and `write_escape_state_dir` —
//     all three HARD GATES — went from denied to ALLOWED. Real files landed outside
//     the vault, including inside the bridge's own state directory.
//   * Every read baseline opened with them: `read_escape_parent`,
//     `read_escape_symlink`, `read_state_dir`, `read_agent_credential`,
//     `read_session_transcript`, `read_env_token`.
//
// THE REASON IS STRUCTURAL AND WORTH UNDERSTANDING BEFORE TOUCHING THIS LIST. The
// vault write boundary is enforced by ONE thing: the path scope on `Edit(./**)`
// (`Write(./**)` matches nothing — see the CLI's own warning). Every grant above
// writes through BASH, which that scope never touches. So a Bash verb that takes a
// destination path is not "a small widening"; it is the boundary, gone.
//
// Each was verified individually rather than blamed as a group:
//   * `cp` / `mkdir` — take a destination path. Obvious in hindsight.
//   * `uniq` — POSIX `uniq [input [output]]`. `uniq in ../out` writes outside, and
//     it reads as the most harmless line in the batch.
//   * `duckdb` — THE CLI IS A SHELL. `.shell`/`.system` run arbitrary commands
//     (measured: `.shell echo` printed), `COPY … TO` wrote `../escaped.csv`, and
//     `INSTALL`/`LOAD` pull code. Granting it was granting `bash`, which makes every
//     deliberate omission at the bottom of this comment decorative.
//   * `python3` — arbitrary code, stated plainly rather than dressed up.
//   * `node --check` — NOT a syntax check. `--check` refuses to execute only the file
//     it is GIVEN; the free tail supplies a flag that loads another. Measured on both
//     node v22.20.0 (the bridge's) and v26.4.0: `--check --require ./m.js`,
//     `--check -r ./m.js` and `--check --import ./m.mjs` all EXECUTED, and a live
//     matcher probe confirmed the rule permits the `--require` form. Only
//     `--check --eval` is refused, and node refuses it, not us.
//
// WHAT REPLACED THEM: three PINNED WRAPPERS in the vault, each accepting DATA and
// never code, so the jobs keep their arithmetic and the child holds no interpreter.
//   * `run-week-query.sh` runs the committed `week.sql` and nothing else. It takes at
//     most two dates, shape-checked and then ROUND-TRIPPED through the parser —
//     BSD `date -j -f` normalises 2026-02-31 into 2026-03-03 and exits 0, so a bare
//     parse accepts impossible dates. It validates `week.sql` before running it, and
//     passes `-no-init` because duckdb otherwise reads `~/.duckdbrc` at startup.
//   * `currency-stats.py` computes the percentile and moving averages the currency
//     reports quote, from a series on stdin. No `eval`, no file-path argument, and
//     unknown arguments are refused rather than ignored.
//   * `create-pending-review.sh` — see the `gh` section below for why this one has to
//     be a wrapper rather than a rule.
//
// THE TWO PINNED SKILL SCRIPTS —
// `Bash(./.claude/skills/archive-processing/find-checked-archive-boxes.sh:*)` and
// `Bash(./.claude/skills/draft-lint/lint-draft.sh:*)` — are what let the
// `archive-box` and `overnight-vault-lint` jobs find their own work; without them
// each job can read its skill's instructions and cannot act on them. Both filenames
// were confirmed on disk on 2026-08-14 rather than copied from the prompt.
//
// `Bash(node vault/rotate-currency-summary.js:*)` — the currency jobs' size ceiling.
// Without it the running summaries grow unbounded and eventually cost more context
// than the analysis they feed.
//
// KNOWN OPEN, STATED PLAINLY AND NOT CLOSED HERE: every pinned-script grant is a
// WRITE-THEN-EXECUTE PATH TO ARBITRARY CODE, not a grant to run today's file
// contents. The child holds a scoped write grant over the same tree, so it can
// rewrite the script and then invoke it under its own pinned rule. That is true of
// the four `node vault/*.js` scopes, the two skill scripts, and the three wrappers
// above. The mitigation is that the tree is version-controlled and committed — NOT
// that the path is pinned. The wrappers narrow it further by validating their own
// inputs and, for `week.sql`, the query file itself; they do not close it.
//
// AND BE HONEST ABOUT WHAT THAT MEANS FOR THE GATES: a `denied` verdict in this
// battery is a live model attempt that did not find a route, never a proof that none
// exists. The write-then-execute route above predates this batch — the three
// `node vault/*.js` scopes have carried it since 0.60.0 — and the hard gates passed
// anyway, because no probe went looking for it. Adding interpreters did not create a
// new class so much as make an existing one trivially reachable. Read a passing gate
// as "no probe found a way", not "there is no way".
//
// `Bash(shasum:*)` — fingerprinting. It reads and prints; there is no destination
// path to point outside the vault.
//
// §9's READ VERBS WERE MEASURED AND ALL BUT ONE DROPPED, which is the honest outcome
// rather than the tidy one. With an EMPTY allowlist, `grep`, `stat`, `du`, `file`,
// `diff`, `sort` and `which` all RAN — the harness auto-approves them, so granting
// them would have added seven lines that change nothing and make this record read as
// broader than it is. `uniq` was the only one actually refused, and it is not granted
// either, for the output-file reason above.
//
// THE `gh` GRANTS split into readers and two authoring verbs, and the split is
// deliberate. The readers (`pr list/view/checks`, `issue list/view`,
// `run list/view`, `release list/view`, `repo view`) are what
// `overnight-tag1-status` reports from; `gh run list`'s head-SHA field is what
// lets a CI check tell a run on THIS commit from a run on an older one.
// `gh issue create` and `gh pr create` are token-bounded — only flags follow — and
// were decided deliberately on 2026-08-14. The third authoring verb, a pending
// review, is a WRAPPER rather than a rule; the next paragraph but one says why.
//
// NOTHING UNDER `gh` IS READ-ONLY BY CONSTRUCTION, which is the half a reader will
// miss. `gh` authenticates from its own stored credential, not from a scope this
// project narrowed, so — exactly as with the GitHub MCP server's classic PAT — this
// list is the ONLY boundary. What holds the line is that the verbs are enumerated:
// no publishing, merging, closing, deleting or editing verb appears here.
//
// A BLANKET `Bash(gh api:*)` IS NOT GRANTED and must not be: `--method` turns it
// into a general write client for the whole API, and a prefix match cannot stop
// that. What IS granted is the single repo-pinned
// `Bash(gh api repos/tag1consulting/jesse-app/pulls:*)`, on the operator's
// explicit decision. BE CLEAR ABOUT WHAT IT BUYS AND WHAT IT DOES NOT: the free
// tail means `--method POST` on that exact endpoint, i.e. create-a-PR by API, and
// `--method PATCH`/`DELETE` on it too. It does NOT reach `/pulls/<N>/anything`,
// so it cannot merge, cannot comment, and — the reason it was asked for — CANNOT
// create a pending review.
//
// THE PENDING REVIEW IS A WRAPPER BECAUSE IT CANNOT BE A RULE, and that was
// measured rather than assumed. `gh pr review` on 2.95.0 offers only `--approve`,
// `--request-changes` and `--comment`, all of which PUBLISH on creation, so there
// is no draft mode to grant. The REST route is
// `POST repos/O/R/pulls/<N>/reviews` with `event` OMITTED — but the PR number sits
// in the path, and the matcher works at path-token granularity with no mid-string
// glob, so `…/pulls:*`, `…/pulls/*/reviews:*` and `…/pulls/*:*` were each probed
// and each REFUSED `…/pulls/7/reviews`. No rule both reaches this endpoint and
// stops short of the rest of the API.
//
// So `Bash(./.claude/skills/gh-review/create-pending-review.sh:*)` is granted
// instead. It fixes the method, the repository and the path; the caller supplies a
// digits-only PR number and prose. It never sends `event`, and it READS THE STATE
// BACK and fails unless it is `PENDING` — if a future API change ever made these
// publish on creation, it stops rather than speaking on Jeremy's behalf.
// Publishing is deliberately not in it: a human submits the review. Verified live
// on 2026-08-14 — the created review read back `state=PENDING`, `submitted_at=null`
// with zero visible comments, and became visible only after a hand publish.
//
// THE FIVE `Skill(<name>)` GRANTS are by name, never a bare `Skill`, each
// confirmed against `~/jesse/.claude/skills/` on 2026-08-14. Like
// `Skill(diet-logging)` above they only LOAD instruction text; every action they
// prescribe still flows through the scopes already granted here.
//
// GITHUB MCP GREW BY NINE, AND THE SERVER'S ARGV CHANGED WITH IT. The missing
// issue and PR tools were never a registration bug: this bridge pins the server
// to `--toolsets repos,actions`, so the rest were never built. Enumerated live on
// 2026-08-14 against github-mcp-server 1.8.0, `--read-only` in both runs:
// `repos,actions` registers exactly the 16 already granted above, and adding
// `issues,pull_requests` registers 25. The nine new ones are granted; every one
// carries `readOnlyHint:true`, and `--read-only` means the server never builds a
// mutating tool to withhold. The authoring verbs therefore come from `gh`, not
// from here.
//
// STILL DELIBERATELY ABSENT, re-confirmed against this batch: any bare
// interpreter or shell (`bash`, `sh`, `zsh`, unversioned `python`, and `node`
// without a check flag or a pinned script — the two `--check` scopes are the
// argued exception above); `curl` and `wget` (a SEND channel, not a read one);
// every publishing, merging, closing, deleting or editing `gh` verb and a blanket
// `gh api`; `rm`, `chmod`, `chown`, `kill`, `sudo`; `ssh`, `scp`, `rsync`;
// `launchctl`, `cargo`; `sed -i` and `awk`; `osascript`, `screencapture`.
//
// ---- Why the five file/search grants carry `(./**)` --------------------------
//
// PATH SCOPE, added 2026-07-29 after the live battery recorded three unmet hard
// gates at `write/qmd`: a writes-on turn could write outside the vault through
// `../`, through a symlink's resolved target, and into the bridge's own state
// directory, and could read anything the bridge user could read. The tools were
// granted by NAME, and a name carries no path — so the vault was where the child
// worked, not a boundary it could not leave.
//
// `(./**)` is CWD-RELATIVE on purpose, not the absolute `(//<vault>/**)` form.
// Every site that grants these tools runs the child in the vault (`main_turn_request`,
// `vaultqa_child_request`), so the two forms are the same boundary — and both were
// hand-checked against the pinned CLI (2.1.220, 2026-07-29): an outside read/write
// is refused at the PERMISSION layer, which a headless `-p` child cannot answer,
// while an in-vault read/write/search still lands. The relative form is chosen
// because it names no host path: the containment record commits the exact argv it
// probed, and an absolute vault path there would be both a personal-infra leak
// (`scripts/ci-guards.sh`) and a record no other deployment could match.
//
// GREP AND GLOB ARE SCOPED TOO, and that is not over-reach. `Grep` reads file
// CONTENT and takes a path argument, so an unscoped `Grep` walks straight out of
// the vault — hand-checked: with `Read`/`Write`/`Edit` scoped and `Grep` bare, a
// child still read a file outside the working directory. Scoping all five closed
// every read and write escape while the four positive controls (vault read, vault
// search, qmd search, vault write) kept passing, which is what says the scope is
// tight rather than merely narrow.
//
// The `Bash(...)` grants below are deliberately NOT narrowed here. The network
// route and the process that outlives a turn both come from `Bash(git:*)` with
// unrestricted arguments — a separate decision with its own cost to the vault
// workflows, and both stay recorded as known-open baselines in
// `bridge/containment.toml` rather than being quietly closed as a side effect.
//
// ---- The MCP grants, and why they are the ONE source of truth ----------------
//
// EVERY `mcp__<server>__<tool>` entry below is read twice, and that is the point.
// Claude Code gets them verbatim as `--allowedTools`. Codex has no tool-allowlist
// flag at all, so `codex_mcp_args` DERIVES its per-server `enabled_tools` from
// this same const (see `granted_mcp_tools`). A tool granted here is granted on
// both harnesses; a tool omitted here is absent on both. There is no second list
// to keep in step, because a second list would drift.
//
// The names were enumerated LIVE against the pinned servers on 2026-08-07
// (`initialize` + `tools/list`), never from a README — the Slack server's README
// was wrong in both directions, listing scopes that do not exist and omitting
// mutating tools that do.
//
// SLACK: six of fifteen. Granted are the six read-only ones above. The nine
// omitted, by name and reason: `conversations_join`, `conversations_leave`,
// `conversations_mark` (all mutate; `conversations_mark` registers by default
// despite the README saying otherwise), `usergroups_create` / `usergroups_update`
// / `usergroups_users_update` (mutate), `usergroups_me` (multiplexes read and
// write behind an `action` argument, so its read half cannot be granted alone),
// `usergroups_list` (read-only, no use case) and `conversations_unreads`
// (read-only, outside the agreed set). The TOKEN cannot post either way — it holds
// no `chat:write` scope of any kind, verified live: `chat.postMessage` returns
// `missing_scope`. The allowlist and the token are two independent boundaries and
// both are shut.
//
// BROWSER: twenty of twenty-four. The four omitted are the ones that would turn a
// page fetch into something else, and they split into exactly two classes:
//   * ARBITRARY CODE — `browser_evaluate` (runs JS in the page) and
//     `browser_run_code_unsafe` (runs JS in the Playwright SERVER process, which
//     is not inside either harness's sandbox — the server's own description calls
//     it unsafe). These are the reason a browser server is not simply granted
//     whole.
//   * LOCAL FILES INTO A PAGE — `browser_file_upload` and `browser_drop` read
//     local files into a web page, which is an exfiltration route out of the vault
//     that no network policy would see.
// Everything else — navigate, read, screenshot, and the interaction verbs (click,
// type, fill_form, press_key, hover, select_option, drag, handle_dialog, tabs,
// resize, close) — is granted, because a read-only browser that cannot dismiss a
// cookie wall or page through results cannot reach the sites this capability
// exists for.
//
// `browser_take_screenshot` IS granted, and it is not a write escape: the PNG goes
// to the server's `--output-dir` under `/tmp`, never the vault. It earns its place
// because the image genuinely REACHES THE MODEL — verified 2026-08-07 on BOTH
// harnesses by rendering a page whose colours appear nowhere in its accessibility
// tree and asking for them back: Claude Code returned #7B2D8B/#F2C41E and Codex
// #812C90/#F9C719 against an actual #7B2D8E/#F2C31A. Only pixels produce that. It
// is what reads a chart, a canvas, or a rendered layout that `browser_snapshot`'s
// text tree cannot express. NOTE the limit, because it is not obvious: the image
// reaches the MODEL, never the USER — the bridge's mid-turn contract carries
// `ToolActivity { name, refused }` and deliberately excludes tool RESULTS, so a
// phone gets the model's DESCRIPTION of a screenshot and never the picture.
//
// `browser_wait_for` is NOT filler: the bot walls that block `WebFetch` clear only
// after a delay, and without it the browser returns a 403 interstitial on exactly
// the pages it was added to read (measured on stackoverflow.com, 2026-08-07).
//
// HOME ASSISTANT: twenty-three of twenty-three — the ENTIRE advertised surface, and
// the only server here granted whole. That is an explicit operator decision, not an
// oversight and not a default: full house control was asked for knowingly, against
// the stated risk that the browser above makes a prompt-injected page a route to
// physical actuation. Nothing is omitted because nothing on this server is both
// dangerous and unused — the three read intents (`GetLiveContext`, `GetDateTime`,
// `todo_get_items`) and the twenty control intents are the capability.
//
// IT WAS TWENTY-ONE IN 0.67.0. The live enumeration on 2026-08-08 returned two more
// that the running server had not advertised the day before: `HassBroadcast` (speaks
// a message through Assist satellites) and `HassListRemoveItem` (removes a to-do
// item). Both were granted on the same "full control" decision rather than defaulted
// in. THE LESSON IS THE COUNT, NOT THE TWO NAMES: a server's surface grows underneath
// a fixed allowlist without any signal here, so re-enumerate live before every battery
// and never carry a tool list forward on the assumption it is still complete.
//
// WHAT "FULL CONTROL" ACTUALLY REACHES IS DECIDED IN HOME ASSISTANT, NOT HERE, and
// that is the load-bearing half a reader will miss. These intents act only on
// entities HA EXPOSES to its Assist API (Settings → Voice Assistants → Expose);
// an unexposed entity is invisible to every tool below. Enumerated live on
// 2026-08-07: 388 of the installation's 1199 entities are exposed — 282 lights, 36
// switches, 23 climate, 18 media_player, 16 binary_sensor, 8 sensor, 4 cover, 1
// todo. There is NO `lock` and NO `alarm_control_panel` entity in the whole
// installation, so "locks and alarm" are not granted by this list and cannot be:
// they do not exist. The entrance gate DOES, as `switch.cancello_ingresso`, and it
// is exposed — so `HassTurnOn`/`HassTurnOff` move it. Changing that reach is an HA
// Expose edit, not a bridge change.
//
// Note `HassTurnOn`/`HassTurnOff` are multiplexers over every exposed domain (their
// own descriptions say they lock/unlock a lock and open/close a cover), which is
// why granting them IS granting the gate. There is no narrower intent to prefer.
//
// ROON: six of six, also whole, for a different and much duller reason — the server
// advertises exactly six tools and all six are music. `hifi_zones`,
// `hifi_now_playing`, `hifi_search` and `hifi_status` are `readOnlyHint`; the two
// that act (`hifi_control`, `hifi_play`) start, stop and queue playback. The
// `hifi_hqplayer_*` tools the upstream README documents are NOT advertised by the
// running server and so are not omitted here — HQPlayer is not connected, and
// tools/list returns six, not more. If HQPlayer is ever connected the surface grows
// upstream and this list must be revisited against a fresh enumeration.
//
// NEITHER SERVER ANNOTATES ANY TOOL `destructive`, which is worth stating because it
// is the opposite of what one would assume from a list that can open a gate: HA
// ships no annotations at all, Roon ships only `readOnlyHint`. So nothing downstream
// may infer "safe" from a missing `destructiveHint` — the bridge sets
// `default_tools_approval_mode="approve"` per server unconditionally (see
// `codex_mcp_args`), and this allowlist, not an annotation, is the boundary.
//
// ---- The two message servers: the allowlist IS the whole boundary ------------
//
// WHATSAPP AND IMESSAGE HAVE NO CREDENTIAL TO SCOPE. Every other read-only server
// here is read-only twice over — a token carrying no write scope AND a list naming
// read tools only. These two read LOCAL DATA (a SQLite store the WhatsApp Go
// bridge syncs; `~/Library/Messages/chat.db`, reached for us by the iMCP app), so
// there is no scope to withhold. The omitted tools below are not a second layer
// behind the first; they ARE the first, and the only. WhatsApp was enumerated live
// on 2026-08-10 and iMCP on 2026-08-11, each against the running server, never a
// README.
//
// WHATSAPP: eight of twelve. Granted are the eight read tools above. The four
// omitted, by name and reason:
//   * `send_message`, `send_file`, `send_audio_message` — outbound messages under
//     Jeremy's own number. Sending is the standing rule's bright line: it is the
//     one action whose consequence lands on somebody else, cannot be undone, and
//     is indistinguishable to the recipient from Jeremy having written it.
//   * `download_media` — it WRITES A FILE. It is the only non-send omission and it
//     is easy to mistake for a read: the name says download, and the surrounding
//     tools all read. It fetches attachment bytes through the Go bridge's REST API
//     and puts them on disk, so it belongs with the writers.
// Note what the allowlist CANNOT reach: that Go bridge serves an UNAUTHENTICATED
// send API of its own, and it is below this layer entirely — omitting the tools
// stops this child, not anything else on the host. See SECURITY.md.
//
// IMESSAGE (`imcp`): ONE of SIX. The server is iMCP, not `mac-messages-mcp`, and
// the shape of its surface is different enough that the old reasoning does not
// carry over — re-decided against a live enumeration of the running 1.4.1 server
// on 2026-08-11, not translated from the list it replaces.
//
// Granted: `messages_fetch` — the ONLY tool the Messages service advertises. It
// takes a date range, a participant list, a substring query and a limit, and
// returns message bodies. That single tool is the entire iMessage read surface.
//
// THERE IS NO SEND OR COMPOSE TOOL TO OMIT, and that is a genuine narrowing rather
// than a gap in this list: `mac-messages-mcp` advertised `tool_send_message` and
// the allowlist was the only thing holding it back. iMCP advertises no sending tool
// at all, so on this path sending is ABSENT AT THE ROOT rather than merely
// ungranted. Do not restate the old "its one send tool is not granted" line; it
// describes a server this project no longer runs.
//
// THE FIVE OMITTED TOOLS ARE MAPS, AND THEY ARE OMITTED ON PURPOSE:
// `maps_search`, `maps_directions`, `maps_explore`, `maps_eta`, `maps_generate`.
// They are not a message surface and the morning routine does not want them.
//
// NAME THEM CAREFULLY, BECAUSE THE OPERATOR'S MENTAL MODEL AND THE WIRE DISAGREE.
// iMCP is configured with only its Messages service switched on, and its stored
// preferences carry `messagesEnabled = 1` and no key for any other service — so
// the intent is "Messages only". The running server nevertheless ADVERTISES all
// five Maps tools, and a live call to `maps_search` on 2026-08-11 RETURNED REAL
// MAPKIT RESULTS. Maps needs no per-service grant because it touches no local
// user data, so the app's service toggle does not gate it. The advertised surface
// is therefore NOT the enabled surface, and this allowlist is the only thing
// keeping Maps out of the child. Anyone tempted to trim this note because "only
// Messages is enabled" should re-run the enumeration first.
//
// What they would cost is small but not nothing: all five are `openWorldHint:true`
// — they leave the machine for Apple's map services, carrying an attacker-
// influenceable query string out of a child that reads attacker-authored message
// bodies. That is a low-bandwidth egress channel this set does not need.
//
// NO ADDRESSBOOK AND NO ATTACHMENT TOOLS EXIST HERE. The four Contacts readers and
// the two attachment tools that `mac-messages-mcp` advertised have no iMCP
// counterpart while only Messages is enabled, so the second protected macOS path
// that grant reached is gone from this set entirely.
//
// EVERY ONE OF THE SIX IS ANNOTATED `readOnlyHint:true`, INCLUDING THE FIVE THAT
// ARE NOT GRANTED — which is the standing reason annotations are not the boundary.
// A tool that reaches Apple over the network and one that reads a local database
// carry the identical hint; only this list tells them apart.
//
// GOOGLE-PERSEIDO: sixteen of eighteen — the SAME sixteen granted on the tag1
// `google` server, chosen by mirroring rather than re-deciding, because the two
// servers are the same binary at the same version against a different account and
// a divergence between them would be an accident rather than a policy. The two
// omitted are the same two: `get_gmail_attachment_content` (writes attachment
// bytes to local disk — `--read-only` bounds writes to GOOGLE, not to the host)
// and `start_google_auth` (an interactive consent flow, which a headless turn
// cannot complete and must not begin). Read-only holds at BOTH layers here, the
// same as tag1: the OAuth scopes are `calendar.readonly` / `gmail.readonly` /
// `drive.readonly`, and this list names read tools only.
//
// THE SERVER NAME CARRIES A HYPHEN, which no server before it did, and both
// harnesses were checked rather than assumed: Claude Code matched
// `mcp__google-perseido__list_calendars` from this allowlist and called it, and
// codex 0.146.0 accepted `mcp_servers.google-perseido.*` under `--strict-config`
// (a deliberately bad value still errored, so the key was really being read).
// `granted_mcp_tools` splits on the `mcp__<server>__` prefix, so `google` and
// `google-perseido` cannot bleed into one another in either direction.
pub const DEFAULT_ALLOWED_TOOLS: &str = "Read(./**),Write(./**),Edit(./**),Grep(./**),Glob(./**),\
mcp__qmd__query,mcp__qmd__get,mcp__qmd__multi_get,mcp__qmd__status,\
Skill(diet-logging),\
Bash(git:*),Bash(mv:*),Bash(ls:*),Bash(cat:*),Bash(find:*),\
Bash(date:*),Bash(cal:*),Bash(head:*),Bash(tail:*),Bash(wc:*),\
Bash(node vault/generate-diet-today.js:*),\
Bash(node vault/validate-diet-today.js:*),\
Bash(node vault/verify-diet-consistency.js:*),\
Bash(node vault/rotate-currency-summary.js:*),\
Bash(./.claude/skills/archive-processing/find-checked-archive-boxes.sh:*),\
Bash(./.claude/skills/draft-lint/lint-draft.sh:*),\
Bash(./.claude/skills/diet-query/run-week-query.sh:*),\
Bash(./.claude/skills/currency-stats/currency-stats.py:*),\
Bash(./.claude/skills/gh-review/create-pending-review.sh:*),\
Bash(shasum:*),\
Bash(gh pr list:*),Bash(gh pr view:*),Bash(gh pr checks:*),\
Bash(gh issue list:*),Bash(gh issue view:*),\
Bash(gh run list:*),Bash(gh run view:*),\
Bash(gh release list:*),Bash(gh release view:*),Bash(gh repo view:*),\
Bash(gh issue create:*),Bash(gh pr create:*),\
Bash(gh api repos/tag1consulting/jesse-app/pulls:*),\
Skill(health-new-day),Skill(dashboard-regen),Skill(archive-processing),\
Skill(draft-lint),Skill(health-export-import),\
WebSearch,WebFetch,\
mcp__slack__conversations_history,mcp__slack__conversations_replies,\
mcp__slack__conversations_search_messages,mcp__slack__channels_list,\
mcp__slack__channels_me,mcp__slack__users_search,\
mcp__browser__browser_navigate,mcp__browser__browser_navigate_back,\
mcp__browser__browser_snapshot,mcp__browser__browser_find,\
mcp__browser__browser_wait_for,mcp__browser__browser_console_messages,\
mcp__browser__browser_network_requests,mcp__browser__browser_network_request,\
mcp__browser__browser_click,mcp__browser__browser_type,\
mcp__browser__browser_fill_form,mcp__browser__browser_press_key,\
mcp__browser__browser_hover,mcp__browser__browser_select_option,\
mcp__browser__browser_drag,mcp__browser__browser_handle_dialog,\
mcp__browser__browser_tabs,mcp__browser__browser_resize,\
mcp__browser__browser_close,mcp__browser__browser_take_screenshot,\
mcp__homeassistant__GetLiveContext,mcp__homeassistant__GetDateTime,\
mcp__homeassistant__todo_get_items,\
mcp__homeassistant__HassTurnOn,mcp__homeassistant__HassTurnOff,\
mcp__homeassistant__HassSetPosition,mcp__homeassistant__HassStopMoving,\
mcp__homeassistant__HassCancelAllTimers,mcp__homeassistant__HassLightSet,\
mcp__homeassistant__HassClimateSetTemperature,\
mcp__homeassistant__HassMediaUnpause,mcp__homeassistant__HassMediaPause,\
mcp__homeassistant__HassMediaNext,mcp__homeassistant__HassMediaPrevious,\
mcp__homeassistant__HassSetVolume,mcp__homeassistant__HassSetVolumeRelative,\
mcp__homeassistant__HassMediaPlayerMute,mcp__homeassistant__HassMediaPlayerUnmute,\
mcp__homeassistant__HassMediaSearchAndPlay,\
mcp__homeassistant__HassListAddItem,mcp__homeassistant__HassListCompleteItem,\
mcp__homeassistant__HassListRemoveItem,mcp__homeassistant__HassBroadcast,\
mcp__roon__hifi_zones,mcp__roon__hifi_now_playing,mcp__roon__hifi_control,\
mcp__roon__hifi_search,mcp__roon__hifi_play,mcp__roon__hifi_status,\
mcp__google__list_calendars,mcp__google__get_events,mcp__google__query_freebusy,\
mcp__google__search_gmail_messages,mcp__google__get_gmail_message_content,\
mcp__google__get_gmail_messages_content_batch,mcp__google__get_gmail_thread_content,\
mcp__google__get_gmail_threads_content_batch,mcp__google__list_gmail_labels,\
mcp__google__search_drive_files,mcp__google__get_drive_file_content,\
mcp__google__get_drive_file_download_url,mcp__google__list_drive_items,\
mcp__google__get_drive_file_permissions,mcp__google__check_drive_file_public_access,\
mcp__google__get_drive_shareable_link,\
mcp__github__actions_get,mcp__github__actions_list,mcp__github__get_commit,\
mcp__github__get_file_contents,mcp__github__get_job_logs,mcp__github__get_latest_release,\
mcp__github__get_release_by_tag,mcp__github__get_tag,mcp__github__list_branches,\
mcp__github__list_commits,mcp__github__list_releases,\
mcp__github__list_repository_collaborators,mcp__github__list_tags,mcp__github__search_code,\
mcp__github__search_commits,mcp__github__search_repositories,\
mcp__github__issue_read,mcp__github__list_issues,mcp__github__search_issues,\
mcp__github__list_issue_fields,mcp__github__list_issue_types,mcp__github__get_label,\
mcp__github__pull_request_read,mcp__github__list_pull_requests,\
mcp__github__search_pull_requests,\
mcp__fastmail__get_mailboxes,mcp__fastmail__search_emails,mcp__fastmail__get_email_content,\
mcp__unifi__unifi_tool_index,mcp__unifi__unifi_execute,mcp__unifi__unifi_batch,\
mcp__unifi__unifi_batch_status,mcp__unifi__unifi_load_tools,\
mcp__routeros__list_devices,mcp__routeros__system_info,mcp__routeros__interfaces,\
mcp__routeros__ip_addresses,mcp__routeros__ip_routes,mcp__routeros__bridges,\
mcp__routeros__neighbors,mcp__routeros__logs,mcp__routeros__config,mcp__routeros__ping,\
mcp__proxmox__proxmox_get_nodes,mcp__proxmox__proxmox_get_node_status,\
mcp__proxmox__proxmox_get_vms,mcp__proxmox__proxmox_get_vm_status,\
mcp__proxmox__proxmox_execute_vm_command,mcp__proxmox__proxmox_get_storage,\
mcp__proxmox__proxmox_get_cluster_status,mcp__proxmox__proxmox_list_templates,\
mcp__proxmox__proxmox_create_lxc,mcp__proxmox__proxmox_create_vm,\
mcp__proxmox__proxmox_get_next_vmid,mcp__proxmox__proxmox_start_lxc,\
mcp__proxmox__proxmox_start_vm,mcp__proxmox__proxmox_stop_lxc,mcp__proxmox__proxmox_stop_vm,\
mcp__proxmox__proxmox_delete_lxc,mcp__proxmox__proxmox_delete_vm,\
mcp__proxmox__proxmox_reboot_lxc,mcp__proxmox__proxmox_reboot_vm,\
mcp__proxmox__proxmox_shutdown_lxc,mcp__proxmox__proxmox_shutdown_vm,\
mcp__proxmox__proxmox_pause_vm,mcp__proxmox__proxmox_resume_vm,\
mcp__proxmox__proxmox_clone_lxc,mcp__proxmox__proxmox_clone_vm,\
mcp__proxmox__proxmox_resize_lxc,mcp__proxmox__proxmox_resize_vm,\
mcp__proxmox__proxmox_create_snapshot_lxc,mcp__proxmox__proxmox_create_snapshot_vm,\
mcp__proxmox__proxmox_list_snapshots_lxc,mcp__proxmox__proxmox_list_snapshots_vm,\
mcp__proxmox__proxmox_rollback_snapshot_lxc,mcp__proxmox__proxmox_rollback_snapshot_vm,\
mcp__proxmox__proxmox_delete_snapshot_lxc,mcp__proxmox__proxmox_delete_snapshot_vm,\
mcp__proxmox__proxmox_create_backup_lxc,mcp__proxmox__proxmox_create_backup_vm,\
mcp__proxmox__proxmox_list_backups,mcp__proxmox__proxmox_restore_backup_lxc,\
mcp__proxmox__proxmox_restore_backup_vm,mcp__proxmox__proxmox_delete_backup,\
mcp__proxmox__proxmox_add_disk_vm,mcp__proxmox__proxmox_add_mountpoint_lxc,\
mcp__proxmox__proxmox_resize_disk_vm,mcp__proxmox__proxmox_resize_disk_lxc,\
mcp__proxmox__proxmox_remove_disk_vm,mcp__proxmox__proxmox_remove_mountpoint_lxc,\
mcp__proxmox__proxmox_move_disk_vm,mcp__proxmox__proxmox_move_disk_lxc,\
mcp__proxmox__proxmox_add_network_vm,mcp__proxmox__proxmox_add_network_lxc,\
mcp__proxmox__proxmox_update_network_vm,mcp__proxmox__proxmox_update_network_lxc,\
mcp__proxmox__proxmox_remove_network_vm,mcp__proxmox__proxmox_remove_network_lxc,\
mcp__proxmox__proxmox_generate_terraform,mcp__proxmox__proxmox_get_task_status,\
mcp__proxmox__proxmox_get_vm_config,mcp__proxmox__proxmox_whoami,\
mcp__proxmox__proxmox_migrate_vm,mcp__proxmox__proxmox_get_guest_ips,\
mcp__proxmox__proxmox_convert_to_template,mcp__proxmox__proxmox_set_cloudinit,\
mcp__proxmox__proxmox_get_rrd_data,mcp__proxmox__proxmox_get_pools,\
mcp__proxmox__proxmox_get_ha_resources,mcp__proxmox__proxmox_get_firewall_rules,\
mcp__whatsapp__search_contacts,mcp__whatsapp__list_messages,mcp__whatsapp__list_chats,\
mcp__whatsapp__get_chat,mcp__whatsapp__get_direct_chat_by_contact,\
mcp__whatsapp__get_contact_chats,mcp__whatsapp__get_last_interaction,\
mcp__whatsapp__get_message_context,\
mcp__imcp__messages_fetch,\
mcp__google-perseido__list_calendars,mcp__google-perseido__get_events,\
mcp__google-perseido__query_freebusy,mcp__google-perseido__search_gmail_messages,\
mcp__google-perseido__get_gmail_message_content,\
mcp__google-perseido__get_gmail_messages_content_batch,\
mcp__google-perseido__get_gmail_thread_content,\
mcp__google-perseido__get_gmail_threads_content_batch,\
mcp__google-perseido__list_gmail_labels,mcp__google-perseido__search_drive_files,\
mcp__google-perseido__get_drive_file_content,mcp__google-perseido__get_drive_file_download_url,\
mcp__google-perseido__list_drive_items,mcp__google-perseido__get_drive_file_permissions,\
mcp__google-perseido__check_drive_file_public_access,\
mcp__google-perseido__get_drive_shareable_link";

// Defense-in-depth: tools that must never run from the bridge even if they slip
// into the allowlist. Override with JESSE_DISALLOWED_TOOLS.
//
// WebFetch was the sole entry until 0.57.0, as "the SSRF / data-exfiltration
// surface the Ask/Tell workflows don't need". That rationale is SUPERSEDED, not
// refuted: read-only web access became a wanted capability, so the premise
// "don't need" stopped holding. The surface it named is real and still present,
// and is accepted rather than mitigated — see SECURITY.md "Web access".
//
// THIS LIST MUST NEVER BE EMPTY, and NotebookEdit is here to keep it non-empty.
// `env_string` trims and treats blank as unset, and the field falls back with
// `unwrap_or_else(|| DEFAULT_DISALLOWED_TOOLS)` — so a deployment setting
// JESSE_DISALLOWED_TOOLS="" would silently RESTORE this default and re-arm the
// WebFetch deny with no error anywhere. The same trap applies to emptying the
// const itself. NotebookEdit is a safe placeholder: nothing in the allowlist
// grants it, so denying it shadows no grant (unlike bare `Bash`, below).
//
// Bare `Bash` is deliberately NOT here. Listing it removes the entire Bash tool
// class — which shadows EVERY scoped `Bash(<verb>:*)` grant in the allowlist
// above (git for code review, the three node diet-cache scripts, date/cal for the
// clock header, the read-only inspection verbs). Verified on the Studio
// (claude 2.1.199, 2026-07-04): with `Bash` denied, even `Bash(date:*)` reports
// "no Bash tool" — the scoped grants become dead. Unscoped Bash is still blocked
// WITHOUT this entry: under `--permission-mode default` a Bash command matching
// no scoped allow entry raises a permission prompt, which a headless (`-p`) phone
// turn cannot answer, so it is denied. Default-deny + the scoped allowlist is the
// real least-privilege boundary; denying the tool class only breaks the scoped
// grants (and silently broke diet-logging + the clock verbs until this fix).
pub const DEFAULT_DISALLOWED_TOOLS: &str = "NotebookEdit";

#[derive(Clone)]
pub struct Config {
    pub token: String,
    pub vault: String,
    // The bridge user's HOME, resolved ONCE at startup. Claude Code's session
    // transcripts live under `<home>/.claude/projects/…`, so every session-path
    // lookup (`sessions_dir`, `session_transcript_exists`, the GC sweep) reads THIS
    // rather than the process env at call time. HOME never changes during a run, so
    // this is behavior-identical in production; capturing it makes the session paths
    // deterministic and testable without mutating a process-global.
    pub home: String,
    pub bind: String,
    pub port: u16,
    pub claude_bin: String,
    /// The `codex` binary, for models whose harness is [`CODEX_ID`]. One variable per
    /// harness, mirroring `claude_bin` — see [`harness_bin_env`]. Only consulted for a
    /// harness some configured model actually references, so a Codex-free config never
    /// demands it be present.
    pub codex_bin: String,
    /// The ordered candidate list for work the user did NOT choose a model for
    /// (`offload_order` in the config file). Empty by default, which routes every such job
    /// to ambient — byte-for-byte the behavior before this key existed.
    ///
    /// It governs ONLY routed jobs. A main turn runs on the model the chip selected or it
    /// fails; see [`crate::routing`] for why that boundary matters and what erodes it.
    pub offload_order: Vec<String>,
    /// The per-turn run limit in seconds (`JESSE_TIMEOUT`, default
    /// [`DEFAULT_TIMEOUT_SECS`], clamped to `[1, HARD_TIMEOUT_CEILING]`).
    pub timeout_secs: u64,
    /// How many assistant text blocks the cut-off turn's partial-answer ring retains
    /// (`JESSE_PARTIAL_BLOCKS`, default [`DEFAULT_PARTIAL_BLOCKS`], floored at 1).
    /// See [`crate::turntrace`].
    pub partial_blocks: usize,
    /// Byte cap on that retained text (`JESSE_PARTIAL_BYTES`, default
    /// [`DEFAULT_PARTIAL_BYTES`]). Zero is honoured — it retains the counts and drops the
    /// text, which is a legitimate posture for a deployment that wants no answer text on a
    /// failure body.
    pub partial_bytes: usize,
    // Comma-separated tool allowlist passed to `claude --allowedTools`.
    pub allowed_tools: String,
    // Comma-separated tool denylist passed to `claude --disallowedTools`.
    pub disallowed_tools: String,
    /// Per-model concurrency slots and the global ceiling — see [`crate::slots`].
    ///
    /// Replaces the single `max_concurrency` semaphore this field used to be. That key's
    /// comment said what it was really doing: "a single global write lock, so at most one
    /// turn runs (and can rewrite vault files) at a time". It was standing in for a vault
    /// write lock the bridge did not have; now it has one ([`crate::writelock`]).
    pub concurrency: ConcurrencySettings,
    // Depth of the wait queue in front of the concurrency semaphore. When no
    // permit is free, up to this many turns may wait for one; beyond it, load is
    // shed with 429 (the pre-queue behavior). Floor 0 → no queue.
    pub max_queued: usize,
    // Per-service rate ceiling (requests accepted per rolling minute). Bursts
    // beyond this are rejected with 429.
    pub rate_per_min: u32,
    // How long a completed/failed job stays retrievable before TTL eviction when
    // it has NEVER been fetched. The clock starts at first retrieval, not at
    // completion, so an unfetched reply survives the full window.
    pub job_ttl_secs: u64,
    // Once a completed job has been fetched once, how much longer it's kept (a
    // short grace so a re-poll still works) instead of the full TTL.
    pub retrieval_grace_secs: u64,
    // Age, in DAYS, past which the background session GC sweep reclaims a
    // vault-project Claude Code session jsonl (env `JESSE_SESSION_TTL_DAYS`,
    // default `DEFAULT_SESSION_TTL_DAYS` = 90). The sweep keys on file mtime, and
    // resuming a session touches its mtime, so a session younger than this is
    // NEVER deleted — only orphaned transcripts older than the TTL are reclaimed.
    pub session_ttl_days: u64,
    // Directory under which completed job results are persisted (one JSON file
    // per job, under `<state_dir>/jobs`) so a bridge restart / laptop reboot
    // doesn't lose a finished-but-unretrieved reply. None disables persistence
    // (in-memory only). Defaults to `$HOME/.jesse-bridge`. Only the finished
    // result + metadata is written — never the bearer token or any secret.
    pub state_dir: Option<String>,
    // Attachment caps (see the DEFAULT_MAX_ATTACHMENT* consts). Decoded sizes.
    pub max_attachments: usize,
    pub max_attachment_bytes: usize,
    pub max_attachments_total_bytes: usize,
    // Base directory for per-request attachment scratch dirs. None → the system
    // temp dir. Set JESSE_SCRATCH_DIR to point this at a sandbox-mounted path if
    // the bridge is ever confined so it can't read the system temp dir.
    pub scratch_dir: Option<String>,
    // Whether the hosted MICRONUTRIENT COMPLETION pass runs on the local diet route
    // (env `JESSE_DIET_MICRO_COMPLETE`, default TRUE — off is the old, broken
    // behavior in which a locally-logged row kept three or more knowable nutrient
    // columns blank). When on, the same hosted verify call that judges macros also
    // returns food-composition values for the EXPECTED nutrient columns an extracted
    // row left BLANK, and the bridge merges them blank-only (see
    // `dietlog::complete_food_micros`).
    //
    // WHICH FLAG OWNS WHAT — this one owns the OUTPUT SHAPE, not model selection, which
    // is why it survives the removal of the role backends:
    //   * the verify GATE's posture is the EXTRACTING MODEL'S LEVEL (see
    //     `routing::skips_verification`): at `Write` the extraction is taken as-is,
    //     below it the hosted verdict is mandatory and blocking before anything is
    //     appended. That replaced the `JESSE_DIET_PROBATION` flag, which asked where
    //     the extraction ran rather than what the model was trusted with.
    //   * `diet_micro_complete` owns NUTRIENT COMPLETION: whether blank expected
    //     nutrient columns get filled from the hosted call.
    // So a `Write` extractor that skips verification still gets completion on every
    // local-route food row.
    pub diet_micro_complete: bool,
    // Optional path to an MCP config JSON declaring exactly the qmd vault-search
    // server, layered onto the vault-QA child via `--mcp-config` (env
    // `JESSE_VAULTQA_MCP_CONFIG`). When unset the child loads NO MCP servers (the
    // empty-servers const) and runs on the three read-only built-ins alone — qmd is
    // simply absent, never an error. Only the vault-QA child ever reads this.
    pub vaultqa_mcp_config: Option<String>,
    // Optional MCP config for the MAIN turn — a file path or inline JSON, the same two
    // forms `--mcp-config` accepts and the same resolution as `vaultqa_mcp_config` (env
    // `JESSE_MAIN_MCP_CONFIG`). Unlike the vault-QA child, unset does NOT mean "no
    // servers": the main path REQUIRES qmd, so unset falls back to
    // `claude::MAIN_CHILD_MCP_CONFIG` (qmd only). Either way the main turn carries
    // `--strict-mcp-config`, so the ambient user/project scopes — the account-level
    // cloud connectors and playwright — never load. Set this when `qmd` is not on
    // the bridge's PATH (launchd's PATH is narrower than a login shell's).
    pub main_mcp_config: Option<String>,
    // Whether the bridge appends a one-line provenance BADGE to each delivered
    // `POST /jesse/jesse` reply (env `JESSE_MODEL_BADGE`, default TRUE). Display
    // only: it names which backend produced the delivered text (`[local · vault · …]`,
    // `[local · diet · … + hosted verify]`, `[hosted · …]`) and is derived from the
    // bridge's own turn state, never from model output. `off` reproduces today's
    // exact reply text. Never applies to the title endpoint.
    pub model_badge: bool,
    // Optional absolute path to a structured-metrics JSONL file (env
    // `JESSE_METRICS_LOG`; see [`metrics`]). `None` (unset, the default) → ZERO metrics
    // writes: the metrics path is dormant, same soft-failure semantics as the other
    // envs. When `Some`, the bridge appends one JSON line per gated/routed/emergency
    // turn at the reply-finalization point the badge uses. Content-free (never the
    // question, answer, or tokens). A write failure logs to stderr and never disturbs
    // the reply.
    pub metrics_log: Option<String>,
    // Whether the EMERGENCY local fallback is armed (env `JESSE_EMERGENCY_LOCAL` =
    // `on|off`, default OFF). When on AND the vault-QA triple is also set (which
    // supplies the backend + read-only child), a hosted turn that fails TRANSPORT-class
    // (spawn/network/timeout/5xx/429/quota/auth — never a completed turn) is answered
    // best-effort by the local read-only child (Ask) or queued for later verify (diet
    // Tell) instead of surfacing the outage. Inert unless BOTH this flag and the
    // vault-QA backend are set; unset → every path is byte-for-byte today's behavior.
    pub emergency_local: bool,
    // Whether the bridge-side CONTEXT LEDGER is active (env `JESSE_CONTEXT_CARRY` =
    // `on|off`, DEFAULT ON). It fixes a live defect: a locally served turn never
    // entered the thread's hosted session, so the next hosted follow-up lost the
    // earlier turn. On → the ledger records each delivered ask/tell turn, injects a
    // catch-up block into the next hosted turn and a recent-conversation block into
    // the local children, and mints a synthetic thread id for a fresh locally-served
    // turn. Off is the ROLLBACK: byte-for-byte today's behavior — no ledger reads or
    // writes, no `context.json`, no synthetic ids, no injected blocks. Default ON
    // follows the badge's default-on precedent because this repairs a live bug.
    pub context_carry: bool,
    // Opt-in SHADOW-comparison backend override (env `JESSE_SHADOW_*`, same
    // all-or-nothing `Option<(base_url, auth_token, model)>` triple as the vault-QA
    // backend). When `Some`, a SAMPLED subset of eligible ask turns is mirrored —
    // AFTER the hosted answer is delivered — to this backend through a contained
    // read-only child, and both answers plus timing/usage are appended to the local
    // shadow log for offline judging. Nothing about the delivered answer, its
    // latency, its badge, or any production route changes. THE TRIPLE IS THE KILL
    // SWITCH: unset any one var → `None` → not a single turn is mirrored,
    // byte-for-byte today's behavior. The production intent is the gateway URL, the
    // gateway token, and the `fw-glm` model alias (the bridge never carries a
    // Fireworks credential — only the gateway URL + token). See [`shadow`].
    pub shadow_backend: Option<(String, String, String)>,
    // Percentage of ELIGIBLE ask turns mirrored to the shadow backend (env
    // `JESSE_SHADOW_SAMPLE_PCT`, default 100, clamped to `[0, 100]`). The decision is
    // per turn via a DETERMINISTIC hash of the turn id (`shadow_sampled`), so it is
    // reproducible and never an RNG. 0 → nothing is mirrored even when armed; 100 →
    // every eligible turn. Inert unless `shadow_backend` is set.
    pub shadow_sample_pct: u8,
    // Absolute path to the shadow pair log (env `JESSE_SHADOW_LOG`, default
    // `~/Library/Logs/jesse-shadow/shadow.jsonl`, `~` expanded, parent created on
    // first write). One JSON line per mirrored pair; created mode 0600 (it holds
    // vault-derived answer text — it stays local and the bridge never sends it
    // anywhere). Inert unless `shadow_backend` is set.
    pub shadow_log: String,
    // Wall-clock budget for one shadow child (env `JESSE_SHADOW_TIMEOUT_SECS`,
    // default 120). A timeout records an INCOMPLETE pair and never retries. Inert
    // unless `shadow_backend` is set.
    pub shadow_timeout_secs: u64,
    // The resolved personalization: owner name/pronoun, languages, and extra diet
    // vocabulary. Loaded from generic built-in defaults → `jesse.local.toml`
    // `[persona]` → environment (see [`Persona::load`]). A fresh clone with no
    // local file resolves to the generic default ("the user"), so no personal fact
    // is ever compiled in — personalization is pure runtime DATA.
    pub persona: Persona,
    // The built-in scheduler's validated `[[schedule]]` jobs, read from the SAME overlay
    // file the persona and the model registry come from. An `Arc` because the scheduler
    // task holds it for the life of the process and every turn's config clone must not
    // copy it. Empty for a deploy that declares no jobs, which is exactly the pre-0.79.0
    // bridge: no tick task is started at all. See [`crate::schedule`].
    pub schedule: Arc<Schedule>,
    // The set of models the CONVERSATION (main turn + its subagents) can be switched
    // onto, built once from `JESSE_MODEL_*` env at startup (see [`ModelRegistry`]).
    // Always holds the ambient `opus` default; `glm-5.2` / `kimi-k3` / `local` are
    // present-but-unavailable until their triples resolve. Distinct from the cheap-role
    // offload backends above, which the switch never touches. Holds no persisted secret
    // — the ACTIVE selection lives in the `ModelStore` (ids + booleans only).
    pub model_registry: ModelRegistry,
    // Global knobs for the vision-helper layer (PDF page cap / DPI, helper output-token
    // cap, per-call timeout). Env-tunable, bounded (see [`resolve_vision_config`]).
    // Entirely inert unless a text model is paired with a helper and a turn carries an
    // attachment; every non-vision path ignores it.
    pub vision: VisionConfig,
    // The agent programs the bridge knows how to spawn, built ONCE at startup and read-only
    // afterwards — the same lifecycle as `model_registry`, and for the same reason (a
    // registry of implementations, not a setting). Exactly one is registered today,
    // `claude-code`, and no env or wire field selects another. It lives here rather than in
    // `AppState` so every path that already carries a `&Config` — the turn driver, the
    // resume check, the GC sweep — can ask which harness serves it without a new argument.
    pub harnesses: Arc<HarnessRegistry>,
}

impl Config {
    /// Resolve the base directory under which per-request scratch dirs are
    /// created: `JESSE_SCRATCH_DIR` if set, else the system temp dir.
    pub fn scratch_base(&self) -> PathBuf {
        self.scratch_dir
            .as_deref()
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
    }

    /// The directory under which per-job result files are written, or `None`
    /// when persistence is disabled. `<state_dir>/jobs` keeps the job store's
    /// files in their own subdir so the state dir can hold other things later.
    pub fn jobs_dir(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("jobs"))
    }

    /// The file the registered APNs device token is persisted to (sibling of the
    /// `jobs/` dir), or `None` when persistence is disabled. One file, one token.
    pub fn device_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("device.json"))
    }

    /// The append-only per-turn timing log (a sibling of `device.json`), or `None` when
    /// persistence is disabled — then timing records are in-memory only for the life of
    /// the process, the same degradation the job/title/device stores have. One JSON line
    /// per turn; pruned to [`TIMING_RETENTION_DAYS`] at startup. See [`crate::turntrace`].
    pub fn turn_timing_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join(TURN_TIMING_FILE))
    }

    /// The file the server-side session titles are persisted to (sibling of the
    /// `jobs/` dir and `device.json`), or `None` when persistence is disabled —
    /// then titles are in-memory only, the same degradation the job store has.
    pub fn titles_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("titles.json"))
    }

    /// The file the scheduler's per-job record is persisted to (a sibling of
    /// `flags.json`), or `None` when persistence is disabled — in which case a restart
    /// loses every last-run time, so a missed fire cannot be caught up and the first
    /// occurrence after a restart is resolved forward from boot. Holds ids, timestamps,
    /// outcomes and reasons; never a prompt, a reply, or a secret.
    pub fn schedule_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("schedule.json"))
    }

    /// The file the per-session favorite / archived flags are persisted to (a
    /// sibling of `titles.json`), or `None` when persistence is disabled (then the
    /// flags are in-memory only), the same degradation the job/title/device stores
    /// have. Holds only the two booleans and their change timestamps, never a secret.
    pub fn flags_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("flags.json"))
    }

    /// The file the global model selection is persisted to (a sibling of `flags.json`),
    /// or `None` when persistence is disabled (then the selection is in-memory only and
    /// resets to `opus` on restart), the same degradation the job / title / device / flag
    /// stores have. Holds only the active id and per-model write booleans, never a secret.
    pub fn model_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("model.json"))
    }

    /// The file the per-session deletion tombstones are persisted to (a sibling of
    /// `flags.json`), or `None` when persistence is disabled (then tombstones are
    /// in-memory only), the same degradation the job / title / device / flag stores
    /// have. Holds only a session_id and the unix-millis delete time, never a secret.
    pub fn deletions_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("deletions.json"))
    }

    /// The file the conversation registry is persisted to (a sibling of `titles.json`),
    /// or `None` when persistence is disabled (then the registry is in-memory only and
    /// every transcript is re-adopted on restart), the same degradation the job / title /
    /// device / flag stores have. Holds conversation ids, the Claude session ids bound to
    /// them, and timestamps: never conversation content and never a secret.
    pub fn conversations_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("conversations.json"))
    }

    /// The file the context ledger is persisted to (a sibling of `titles.json`),
    /// or `None` when persistence is disabled — then the ledger is in-memory only,
    /// the same degradation the job/title/device stores have. Holds conversation
    /// content (the ledger's whole point), so it stays in the state dir and never
    /// reaches the metrics log, provenance, or any other log line.
    pub fn context_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("context.json"))
    }

    /// The file the day-file intent journal is persisted to (a sibling of
    /// `flags.json`), or `None` when persistence is disabled.
    ///
    /// With no state dir there is NO journal, and the write path degrades to
    /// apply-immediately: a mutation still lands, but a tap that races a running
    /// turn can still be clobbered and nothing replays it. That is the same
    /// degradation every other store has, and it is the reason a real deploy
    /// configures a state dir — see `SECURITY.md`.
    ///
    /// Holds item identity (section, lead, `(Added …)` date) and the app's own
    /// evidence text: vault CONTENT, so it stays in the state dir and never
    /// reaches a log line, the metrics log, or provenance.
    pub fn today_intents_file(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("today-intents.json"))
    }

    /// The vault write lock's broker socket.
    ///
    /// Under the STATE DIR, which is what makes it reachable by BOTH harnesses' hooks — a
    /// Codex child's own sandbox cannot write here, but its hook subprocess is not sandboxed
    /// and can (measured on codex-cli 0.146.0). Never in the vault: that would put lock state
    /// in the tree git and the autocommit timer watch. See [`crate::writelock`].
    pub fn writelock_socket(&self) -> Option<PathBuf> {
        self.state_dir
            .as_deref()
            .map(|d| PathBuf::from(d).join("writelock.sock"))
    }

    /// Resolve the per-model slot plan, or every problem with it.
    ///
    /// Called twice on purpose: once by the startup gate in `main`, which turns the errors
    /// into a refusal to start, and once by [`AppState::new`], where it is guaranteed to
    /// succeed because the gate already ran.
    pub fn slot_plan(&self) -> Result<SlotPlan, Vec<String>> {
        resolve_slot_plan(
            &self.model_registry,
            &HarnessRegistry::for_models(
                self.model_registry
                    .models
                    .iter()
                    .map(|m| m.harness.as_str()),
            ),
            &self.concurrency,
            &|var| std::env::var(var).ok(),
        )
    }
}

/// Clamp a requested per-turn timeout into a sane, bounded range. `0` is treated
/// as "use the ceiling" rather than "unlimited" so no request can pin a child
/// forever; any value is capped at `HARD_TIMEOUT_CEILING` and floored at 1s.
/// The only "unlimited" affordance lives in `run_claude` behind
/// `#[cfg(debug_assertions)]` and is never reachable in a release build.
pub fn clamp_timeout_secs(raw: u64) -> u64 {
    if raw == 0 {
        return HARD_TIMEOUT_CEILING;
    }
    raw.clamp(1, HARD_TIMEOUT_CEILING)
}

/// Read an env var as a trimmed, non-empty string, or `None`. This is the single
/// definition of "a string env var is set" — trimmed and empty-filtered — so all
/// string-valued config fields treat a blank/whitespace value identically (fall
/// back to their default). It removes the old inconsistency where some fields
/// (`JESSE_ALLOWED_TOOLS`, `JESSE_STATE_DIR`, …) filtered empty and others
/// (`JESSE_VAULT`, `JESSE_BIND`, …) accepted a blank value verbatim.
pub fn env_string(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Parse an env var into `T`, falling back to `default` when it's unset or
/// doesn't parse. Replaces the dozen hand-rolled
/// `env::var(..).ok().and_then(parse).unwrap_or(default)` chains. (The two
/// `>= 1`-floored fields keep their explicit predicate below — `env_parse` has
/// no notion of a validity floor, and folding a parsed `0` to `1` instead of the
/// default would change behavior.)
pub fn env_parse<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name)
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(default)
}

/// Resolve the optional SHADOW-comparison backend override from its three
/// env-derived parts. All-or-nothing: returns `Some((base_url, auth_token, model))` ONLY when all three are present;
/// any partial combination resolves to `None` (shadow mode stays disarmed and no
/// ask turn is ever mirrored). A partial config logs one startup warning so a
/// half-configured deploy is visible rather than silently half-active. Pure except
/// for that warning. THE TRIPLE IS THE KILL SWITCH: unset any one var and shadow is
/// off, byte-for-byte today's behavior (unset all three → silent). The production
/// intent is the gateway URL, the gateway token, and the `fw-glm` model alias.
pub fn resolve_shadow_backend(
    base_url: Option<String>,
    auth_token: Option<String>,
    model: Option<String>,
) -> Option<(String, String, String)> {
    match (base_url, auth_token, model) {
        (Some(b), Some(t), Some(m)) => Some((b, t, m)),
        (b, t, m) => {
            let set = b.is_some() as u8 + t.is_some() as u8 + m.is_some() as u8;
            if set > 0 {
                eprintln!(
                    "jesse-bridge: WARNING partial JESSE_SHADOW_* config ({set}/3 set) — shadow \
                     comparison needs ALL of JESSE_SHADOW_BASE_URL, JESSE_SHADOW_AUTH_TOKEN, \
                     JESSE_SHADOW_MODEL; treating as unset (no turn is mirrored)."
                );
            }
            None
        }
    }
}

/// Clamp a shadow sample percentage into `[0, 100]`. Unset/unparseable falls back
/// to the caller's default (100 = mirror every eligible turn); an out-of-range value
/// saturates to the nearest bound rather than disabling sampling.
pub fn clamp_sample_pct(raw: u64) -> u8 {
    raw.min(100) as u8
}

/// Expand a leading `~` / `~/` in a path to `home` (the crate keeps `HOME` in
/// `Config.home`, captured once at startup — there is no other tilde expansion in
/// the crate, so this is the single definition). A bare `~` becomes `home`; `~/x`
/// becomes `home/x`. Any other shape (absolute path, `~user`, empty home) is
/// returned unchanged, so an already-absolute `JESSE_SHADOW_LOG` is untouched.
pub fn expand_tilde(raw: &str, home: &str) -> String {
    if home.is_empty() {
        return raw.to_string();
    }
    if raw == "~" {
        return home.to_string();
    }
    match raw.strip_prefix("~/") {
        Some(rest) => format!("{home}/{rest}"),
        None => raw.to_string(),
    }
}

/// Parse `JESSE_MODEL_BADGE` into the `model_badge` flag. Default TRUE: only an
/// explicit `off` / `0` / `false` / `no` disables the badge; anything else
/// (including unset or a bare `on`) keeps it on. Mirrors the `JESSE_DIET_PROBATION`
/// truthiness rule so operators reason about one convention.
pub fn resolve_model_badge() -> bool {
    std::env::var("JESSE_MODEL_BADGE")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            !(v == "0" || v == "false" || v == "no" || v == "off")
        })
        .unwrap_or(true)
}

/// Parse `JESSE_DIET_MICRO_COMPLETE` into the `diet_micro_complete` flag. Default
/// TRUE: only an explicit `off`/`0`/`false`/`no` disables the hosted micronutrient
/// completion pass; unset keeps it ON, because OFF is the old behavior that left
/// knowable nutrient columns blank. Same truthiness rule as `JESSE_DIET_PROBATION`,
/// and deliberately INDEPENDENT of it: probation owns the verify gate's posture,
/// this flag owns nutrient completion.
pub fn resolve_diet_micro_complete() -> bool {
    std::env::var("JESSE_DIET_MICRO_COMPLETE")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            !(v == "0" || v == "false" || v == "no" || v == "off")
        })
        .unwrap_or(true)
}

/// Parse `JESSE_EMERGENCY_LOCAL` into the `emergency_local` flag. Default FALSE
/// (the opposite of `JESSE_MODEL_BADGE`/`JESSE_DIET_PROBATION`): the emergency
/// fallback is an availability lever that changes what a hosted OUTAGE does, so it
/// stays OFF unless an operator EXPLICITLY opts in with a truthy value. Only
/// `on`/`1`/`true`/`yes` enable it; unset, blank, `off`, or an unrecognized value
/// all leave it off, so a fat-fingered value can never silently arm it.
pub fn resolve_emergency_local() -> bool {
    std::env::var("JESSE_EMERGENCY_LOCAL")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            v == "on" || v == "1" || v == "true" || v == "yes"
        })
        .unwrap_or(false)
}

/// Parse `JESSE_CONTEXT_CARRY` into the `context_carry` flag. Default TRUE (mirrors
/// [`resolve_model_badge`]): only an explicit `off`/`0`/`false`/`no` disables it. This
/// repairs a live defect, so the off switch is the ROLLBACK, not the default — the same
/// default-on precedent the badge follows, and the opposite of `resolve_emergency_local`
/// (which defaults OFF because it changes what a hosted outage does).
pub fn resolve_context_carry() -> bool {
    std::env::var("JESSE_CONTEXT_CARRY")
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            !(v == "0" || v == "false" || v == "no" || v == "off")
        })
        .unwrap_or(true)
}

// ---- Model registry (the global model switch) -----------------------------
//
// The registry is the set of MODELS the conversation itself (the main turn and the
// subagents it spawns) can be switched onto, chosen from the phone or the Mac. It is
// entirely distinct from the cheap-role offload backends (`JESSE_TITLE_*`,
// `JESSE_DIET_*`, `JESSE_VAULTQA_*`, `JESSE_SHADOW_*`) above: those keep serving their
// own roles regardless of which model the conversation is switched to. Like every
// backend triple in this file, a registry entry's credentials come ONLY from the
// launch env (`JESSE_MODEL_*`) — no secret is compiled in, and nothing here is ever
// persisted (the `ModelStore` holds only ids and booleans).

/// A per-1,000,000-token price deck: input / cache-read / output dollars per million
/// tokens. The per-turn cost badge multiplies a turn's `usage` vector by the ACTIVE
/// model's deck (the same arithmetic the shadow audit uses — see [`ShadowUsage`]).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PriceDeck {
    pub in_per_m: f64,
    pub cached_per_m: f64,
    pub out_per_m: f64,
}

impl PriceDeck {
    /// A free model (the `local` entry): every turn costs `$0.00`.
    pub const ZERO: PriceDeck = PriceDeck {
        in_per_m: 0.0,
        cached_per_m: 0.0,
        out_per_m: 0.0,
    };

    /// Dollar cost of a simple `(input, output)` token vector on this deck — the vision
    /// helper path has no cache reads, so this is the input+output shorthand the compare
    /// harness and per-turn audit use. (The cache-aware form lives on `ShadowUsage`.)
    pub fn cost(&self, input_tokens: u64, output_tokens: u64) -> f64 {
        (input_tokens as f64 * self.in_per_m + output_tokens as f64 * self.out_per_m) / 1_000_000.0
    }
}

// ---- Vision pairing (the vision-helper layer) -----------------------------
//
// A TEXT model gains the ability to "see" image/PDF attachments ONLY by being
// PAIRED with one or more registered VISION HELPERS. The pairing is a property of
// the text model (its `vision` list) — never a global switch: a model with an empty
// list handles attachments exactly as before (the scratch-file + Read-tool path,
// byte-for-byte), and that unpaired state is what `GET /jesse/models` reports as
// no-vision. Helpers are themselves ordinary registry entries (a hosted/local
// backend triple); the bridge calls a helper directly on the Anthropic
// `/v1/messages` surface (see `vision.rs`), so "register a helper" == add a model
// entry whose `base_url` points at the provider or the local Anthropic-surface gateway.

/// The routing role a paired helper plays. `Doc` is the document/PDF specialist,
/// `General` handles images/charts/screenshots/photos, and `Any` is a single helper
/// that takes every attachment type (role routing is skipped when the sole partner
/// is `Any`). Serializes lowercase for the `GET /jesse/models` capability view.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum VisionRole {
    Doc,
    General,
    Any,
}

impl VisionRole {
    /// Parse a role token (`doc` | `general` | `any`), case-insensitive. An empty or
    /// unrecognized token defaults to `Any` — the safest single-helper behavior — so a
    /// typo widens coverage rather than silently dropping an attachment type.
    pub fn parse(s: &str) -> VisionRole {
        match s.trim().to_ascii_lowercase().as_str() {
            "doc" | "document" => VisionRole::Doc,
            "general" | "image" => VisionRole::General,
            _ => VisionRole::Any,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            VisionRole::Doc => "doc",
            VisionRole::General => "general",
            VisionRole::Any => "any",
        }
    }
}

/// One paired vision helper: the id of a registered model plus the role it plays in
/// routing. List order is preserved (the config order) so fallback is deterministic.
#[derive(Debug, Clone, PartialEq)]
pub struct VisionPartner {
    pub id: String,
    pub role: VisionRole,
}

/// Parse the `JESSE_MODEL_<X>_VISION` env form: a comma-separated list of `id[:role]`
/// items (e.g. `paddleocr-vl:doc,qwen3-vl:general`, or a single `qwen3-vl:any`). A
/// missing role defaults to `Any`. Blank items are skipped; an empty/blank spec yields
/// no partners (vision off for that model — byte-for-byte today's behavior).
pub fn parse_vision_partners(spec: &str) -> Vec<VisionPartner> {
    spec.split(',')
        .filter_map(|item| {
            let item = item.trim();
            if item.is_empty() {
                return None;
            }
            let (id, role) = match item.split_once(':') {
                Some((id, role)) => (id.trim(), VisionRole::parse(role)),
                None => (item, VisionRole::Any),
            };
            (!id.is_empty()).then(|| VisionPartner {
                id: id.to_string(),
                role,
            })
        })
        .collect()
}

/// Parse a truthy env flag (`on`/`1`/`true`/`yes`), default false — the per-model
/// complementary toggle and any other opt-in switch in this layer.
fn env_flag_true(name: &str) -> bool {
    std::env::var(name)
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            v == "on" || v == "1" || v == "true" || v == "yes"
        })
        .unwrap_or(false)
}

/// Global knobs for the vision-helper layer, all env-tunable (no rebuild). Entirely
/// inert unless a text model is paired with a helper AND a turn carries an attachment.
#[derive(Debug, Clone, PartialEq)]
pub struct VisionConfig {
    /// Max PDF pages rasterized + sent per attachment (`JESSE_VISION_PDF_PAGE_CAP`,
    /// default 10, floored at 1). Extra pages are dropped with a truncation note in the
    /// spliced block, never silently.
    pub pdf_page_cap: usize,
    /// Rasterization DPI for PDF pages (`JESSE_VISION_PDF_DPI`, default 200, clamped
    /// [36, 600]).
    pub pdf_dpi: u32,
    /// Output-token cap requested from each helper (`JESSE_VISION_MAX_TOKENS`, default
    /// 4096, floored at 16) — bounds a transcription's length and cost.
    pub max_tokens: u32,
    /// Per-helper-call wall-clock budget in seconds (`JESSE_VISION_TIMEOUT_SECS`,
    /// default 60, floored at 1).
    pub timeout_secs: u64,
}

impl Default for VisionConfig {
    fn default() -> Self {
        VisionConfig {
            pdf_page_cap: 10,
            pdf_dpi: 200,
            max_tokens: 4096,
            timeout_secs: 60,
        }
    }
}

/// Resolve the [`VisionConfig`] from env, each field bounded so a fat-fingered value
/// can never produce a zero page cap, a degenerate DPI, or an unbounded call.
pub fn resolve_vision_config() -> VisionConfig {
    let d = VisionConfig::default();
    VisionConfig {
        pdf_page_cap: env_parse("JESSE_VISION_PDF_PAGE_CAP", d.pdf_page_cap).max(1),
        pdf_dpi: env_parse("JESSE_VISION_PDF_DPI", d.pdf_dpi).clamp(36, 600),
        max_tokens: env_parse("JESSE_VISION_MAX_TOKENS", d.max_tokens).max(16),
        timeout_secs: env_parse("JESSE_VISION_TIMEOUT_SECS", d.timeout_secs).max(1),
    }
}

/// How a selectable model's backend is applied to the MAIN turn.
///
/// **This names an API SURFACE, not a hosting arrangement**, which is what the fourth variant
/// added and what a reader skimming the first three would otherwise get wrong: `Hosted` and
/// `Local` differ only in where the endpoint lives, and both speak Anthropic's
/// `/v1/messages`. `OpenAi` is the first variant that changes the CONTRACT, and every place
/// that assumed "a configured backend is an Anthropic backend" has to ask.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelKind {
    /// The default (`opus`): NO `ANTHROPIC_*` overrides — the main turn inherits the
    /// ambient process env, byte-for-byte today's behavior (the isolation property).
    Ambient,
    /// A hosted backend reached over the Anthropic `/v1/messages` surface (GLM, Kimi).
    Hosted,
    /// An Anthropic-compatible LOCAL endpoint.
    Local,
    /// A backend reached over an **OpenAI-style** surface — `/v1/responses`, not
    /// `/v1/messages` — driven by a harness that speaks it.
    ///
    /// The variant exists because the backend triple means something DIFFERENT here, and the
    /// difference is not expressible as a flag on `Hosted`. For an Anthropic-surface model the
    /// triple becomes `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_MODEL` on a
    /// Claude Code child. For this one it becomes a **provider definition** the OpenAI-style
    /// harness is pointed at (see [`codex_provider_args`]): the same three fields, consumed by
    /// a different transport.
    ///
    /// **A model declaring this kind must run under a harness that speaks it**, and
    /// [`validate_model_config`] refuses the pairing at startup rather than letting a Claude
    /// Code child be handed an `ANTHROPIC_BASE_URL` that answers only `/v1/responses` — which
    /// would fail every turn with a 404 from a model the picker showed as healthy.
    #[serde(rename = "openai")]
    OpenAi,
}

/// One selectable model in the registry. Built from the built-in ambient default, the
/// `JESSE_MODEL_*` env triples, and the declarative `[[models]]` config; holds no secret
/// beyond what the env supplied (the token lives ONLY inside `backend`, resolved from a
/// named env var, and is never serialized to a client or to `model.json`).
#[derive(Debug, Clone)]
pub struct RegistryModel {
    /// The stable id the store + endpoints key on (`opus`, `glm-5.2`, `kimi-k3`, `local`,
    /// or any declarative id).
    pub id: String,
    /// The human label shown in the app's switcher.
    pub label: String,
    pub kind: ModelKind,
    /// `(base_url, auth_token, model_id)` — the same all-or-nothing triple shape as the
    /// role backends. `None` for the ambient entry (it applies nothing) AND for a
    /// hosted/local entry whose triple did not fully resolve (then `configured` is false).
    pub backend: Option<(String, String, String)>,
    /// The subagent model id the switch propagates via `CLAUDE_CODE_SUBAGENT_MODEL` (default
    /// = the backend's `model_id`; a declarative entry may override it). `None` for the
    /// ambient entry and any unconfigured entry.
    pub subagent_model: Option<String>,
    /// Whether this entry's backend/token RESOLVED (a selectable model must also be HEALTHY —
    /// see [`model_health`]). Ambient is always configured; a hosted/local entry is
    /// configured IFF its triple resolved (its token env var was set).
    pub configured: bool,
    /// The MOST this model may be granted — a CEILING, not a grant. `Write` means it may
    /// change the vault; `Read` that it may read and search; `Basic` that it may have no
    /// tools at all. Absent from config it is [`Capability::Read`], the safe direction: a
    /// newly declared model can be asked questions but cannot change anything.
    ///
    /// It is a ceiling because the JOB sets the actual grant beneath it — see
    /// [`turn_capability`] and [`RoutedJob::required`]. A `Write` model serving a title runs
    /// at `Basic`; a `Read` model backing a conversation runs read-only.
    ///
    /// Config-only, deliberately: it is not settable from a client. The per-model writes
    /// toggle this replaced was (`POST /jesse/model/{id}/writes`, removed), which put a
    /// containment decision on the phone.
    pub level: Capability,
    /// The harness that runs this model's child, by [`Harness::id`]. `claude-code` when the
    /// entry declares none. The registry instantiates only the harnesses some configured
    /// model actually names.
    pub harness: String,
    /// The price deck for the per-turn cost badge.
    pub price: PriceDeck,
    /// The health-probe cadence + endpoint for this model (unused for the ambient entry,
    /// which is healthy by construction and never probed).
    pub health: HealthConfig,
    /// The ordered vision helpers this (text) model is PAIRED with. Empty for the
    /// common case and for every helper entry itself: an empty list means this model
    /// cannot see attachments (handled the old way). A non-empty list confers vision,
    /// routed by [`VisionRole`]. Partner ids that don't resolve to a configured entry
    /// are inert (warned once at startup — see [`validate_vision_pairings`]).
    pub vision: Vec<VisionPartner>,
    /// Complementary mode: for a SINGLE attachment, call BOTH paired helpers and
    /// concatenate their outputs under labeled sections (default off). Only meaningful
    /// with a doc+general pair; ignored for a lone `Any` helper.
    pub vision_complementary: bool,
}

/// The set of models the conversation can be switched onto. Ordered as presented to the
/// app (default first). Built once at startup from env; read-only thereafter.
#[derive(Debug, Clone)]
pub struct ModelRegistry {
    pub models: Vec<RegistryModel>,
}

/// The id of the default, always-available model. Selecting it reproduces today's
/// behavior byte-for-byte (no overrides, normal allowlist, writes-on).
pub const DEFAULT_MODEL_ID: &str = "opus";

/// The level a model gets when its config declares none: [`Capability::Read`].
///
/// The safe direction, and the reason the default is not `Write`: a model that appears in
/// the config without anyone deciding what it may touch can be asked questions and cannot
/// change anything. Raising it is an explicit `level = "write"`.
pub const DEFAULT_MODEL_LEVEL: Capability = Capability::Read;

impl ModelRegistry {
    /// Look up an entry by id.
    pub fn get(&self, id: &str) -> Option<&RegistryModel> {
        self.models.iter().find(|m| m.id == id)
    }

    /// The default (ambient) entry — always present, so this never panics in practice;
    /// falls back to a synthesized ambient opus if somehow absent.
    pub fn default_model(&self) -> &RegistryModel {
        self.get(DEFAULT_MODEL_ID)
            .unwrap_or_else(|| &self.models[0])
    }

    /// Whether `id` names an entry that exists AND is CONFIGURED (its backend/token
    /// resolved). Selectability additionally requires the model to be HEALTHY at the moment
    /// of selection — the endpoint layer combines this with the live [`HealthStore`] (see
    /// [`model_health`]); this alone cannot know the dynamic health state.
    pub fn is_configured(&self, id: &str) -> bool {
        self.get(id).map(|m| m.configured).unwrap_or(false)
    }

    /// The opus-only registry: the single always-available ambient default and nothing
    /// else. The test fixture and any deploy with no `JESSE_MODEL_*` env resolve to
    /// exactly this, so an unconfigured bridge behaves byte-for-byte as before.
    pub fn opus_only() -> Self {
        ModelRegistry {
            models: vec![opus_entry()],
        }
    }

    /// Build the registry by MERGING three sources, later overriding earlier BY ID:
    ///   1. the built-in ambient `opus` (always present, never configurable — a declarative
    ///      or env entry that tries to redefine it is refused);
    ///   2. the `JESSE_MODEL_GLM_*` / `JESSE_MODEL_KIMI_*` / `JESSE_MODEL_LOCAL_*` env triples,
    ///      preserved with the SAME ids, defaults, and prices as before so nothing deployed
    ///      breaks;
    ///   3. the declarative `[[models]]` array from the bridge config file (the same TOML the
    ///      persona loads from — see [`load_local_models`]).
    ///
    /// With NO model config (no `JESSE_MODEL_*`, no `[[models]]`) this is exactly the
    /// opus-only registry, so an unconfigured bridge is byte-for-byte today's behavior.
    /// `home` is the captured `Config.home`, used to locate the config file.
    pub fn from_env(home: &str) -> Self {
        // Source 1: the built-in ambient default, first (the app presents default-first).
        let mut models: Vec<RegistryModel> = vec![opus_entry()];

        // The global default probe-interval override (`JESSE_HEALTH_INTERVAL_SECS`), resolved
        // ONCE here so a bad value warns a single time. An explicit per-model interval still
        // wins; env-triple models (which carry no explicit interval) pick up this default.
        let global_health_interval = health_interval_override();
        let default_health_interval =
            global_health_interval.unwrap_or(DEFAULT_HEALTH_INTERVAL_SECS);
        // Likewise the global per-probe-timeout override (`JESSE_HEALTH_TIMEOUT_SECS`). Unlike
        // the interval this is NOT collapsed to a single default here: each env entry carries
        // its own built-in budget (a reasoning model needs a wider one), and the override wins
        // over that only when actually set.
        let global_health_timeout = health_timeout_override();

        // Source 2: the preserved env triples (same ids/defaults/prices as before).
        upsert_model(
            &mut models,
            glm_env_entry(default_health_interval, global_health_timeout),
        );
        upsert_model(
            &mut models,
            kimi_env_entry(default_health_interval, global_health_timeout),
        );
        // Kimi's OTHER surface, registered right beside it: one model, two transports, each
        // selectable on its own id. See [`kimi_codex_env_entry`] for why they are not
        // interchangeable.
        upsert_model(
            &mut models,
            kimi_codex_env_entry(default_health_interval, global_health_timeout),
        );
        upsert_model(
            &mut models,
            local_env_entry(default_health_interval, global_health_timeout),
        );

        // Source 3: the declarative `[[models]]` entries (later overrides earlier by id).
        for decl in load_local_models(home) {
            if let Some(m) =
                registry_model_from_toml(&decl, global_health_interval, global_health_timeout)
            {
                upsert_model(&mut models, m);
            }
        }

        // A paired vision helper that doesn't resolve is a config error worth shouting
        // about — never a silent no-op. Log once per broken pairing at startup.
        validate_vision_pairings(&models);

        ModelRegistry { models }
    }

    /// Resolve a vision partner id to its registered entry, but ONLY when that entry is
    /// configured (its backend/token resolved) — an unconfigured partner is treated as
    /// absent so it can never be called. This is the single gate both the capability
    /// view (`GET /jesse/models`) and the live preprocessor consult.
    pub fn vision_partner(&self, id: &str) -> Option<&RegistryModel> {
        self.get(id).filter(|m| m.configured)
    }

    /// Whether a model actually HAS working vision: it is paired AND at least one partner
    /// resolves to a configured registered model. A paired-but-all-broken model reports
    /// `false` here (and `GET /jesse/models` shows no-vision), never a silent half-state.
    pub fn vision_enabled(&self, m: &RegistryModel) -> bool {
        m.vision
            .iter()
            .any(|p| self.vision_partner(&p.id).is_some())
    }
}

/// Log a loud warning for every paired vision partner that does NOT resolve to a
/// configured registered model — a paired-but-broken helper must be visible, never a
/// silent no-op. Does not mutate the registry: resolution happens again at call time,
/// and the capability view reports vision as enabled only when a partner actually resolves.
fn validate_vision_pairings(models: &[RegistryModel]) {
    let configured: std::collections::HashSet<&str> = models
        .iter()
        .filter(|m| m.configured)
        .map(|m| m.id.as_str())
        .collect();
    for m in models {
        for p in &m.vision {
            if !configured.contains(p.id.as_str()) {
                eprintln!(
                    "jesse-bridge: WARNING model '{}' is paired with vision helper '{}' \
                     (role {}) which is not a configured registered model — that partner \
                     is INERT (an attachment routed to it is dropped with a note in the \
                     spliced block). Register '{}' (a [[models]] entry or JESSE_MODEL_* \
                     triple whose token env var is set) to arm it.",
                    m.id,
                    p.id,
                    p.role.as_str(),
                    p.id
                );
            }
        }
    }
}

/// Insert `m` into the list, REPLACING any existing entry with the same id IN PLACE (stable
/// order, default-first preserved) or appending it when new. The ambient `opus` default is
/// protected: an entry that tries to take its id is refused with a warning, so `opus` stays
/// byte-for-byte the built-in. This is what makes the three-source merge "later overrides
/// earlier by id" while keeping the always-present ambient default untouchable.
fn upsert_model(models: &mut Vec<RegistryModel>, m: RegistryModel) {
    if m.id == DEFAULT_MODEL_ID || matches!(m.kind, ModelKind::Ambient) {
        eprintln!(
            "jesse-bridge: WARNING model '{}' would redefine the built-in ambient default \
             ('{DEFAULT_MODEL_ID}'); ignoring it — the ambient default is never configurable.",
            m.id
        );
        return;
    }
    if let Some(existing) = models.iter_mut().find(|e| e.id == m.id) {
        *existing = m;
    } else {
        models.push(m);
    }
}

/// The `glm-5.2` env-triple entry (hosted on Fireworks' Anthropic surface). base + model
/// DEFAULT; only the token must be supplied, so an operator arms GLM with a single secret
/// env var.
fn glm_env_entry(default_interval_secs: u64, global_timeout_secs: Option<u64>) -> RegistryModel {
    let backend = resolve_model_backend(
        "glm-5.2",
        env_string("JESSE_MODEL_GLM_BASE_URL"),
        env_string("JESSE_MODEL_GLM_AUTH_TOKEN"),
        env_string("JESSE_MODEL_GLM_MODEL"),
        Some("https://api.fireworks.ai/inference"),
        Some("accounts/fireworks/models/glm-5p2"),
    );
    RegistryModel {
        id: "glm-5.2".to_string(),
        label: "GLM 5.2".to_string(),
        kind: ModelKind::Hosted,
        subagent_model: backend.as_ref().map(|(_, _, m)| m.clone()),
        configured: backend.is_some(),
        backend,
        // No declarative entry, so no `level` key: the default applies. A deploy that wants
        // one of these at Write says so in the `[[models]]` array.
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        price: PriceDeck {
            in_per_m: FW_GLM_IN_PER_M,
            cached_per_m: FW_GLM_CACHED_PER_M,
            out_per_m: FW_GLM_OUT_PER_M,
        },
        health: HealthConfig {
            interval_secs: default_interval_secs,
            // GLM answers the 1-token probe in well under a second; the 3 s default stands.
            timeout_secs: resolve_health_timeout(
                None,
                global_timeout_secs,
                DEFAULT_HEALTH_TIMEOUT_SECS,
            ),
            ..HealthConfig::default()
        },
        // Pair GLM with vision helpers via `JESSE_MODEL_GLM_VISION` (id[:role],…) and
        // `JESSE_MODEL_GLM_VISION_COMPLEMENTARY`. Unset → no vision (today's behavior).
        vision: parse_vision_partners(&env_string("JESSE_MODEL_GLM_VISION").unwrap_or_default()),
        vision_complementary: env_flag_true("JESSE_MODEL_GLM_VISION_COMPLEMENTARY"),
    }
}

/// The `kimi-k3` env-triple entry, ARMED — Fireworks serves Kimi K3 on the Anthropic
/// `/v1/messages` surface (verified 2026-07-27), so this mirrors [`glm_env_entry`]: the
/// base_url and slug default to the live Fireworks values and only
/// `JESSE_MODEL_KIMI_AUTH_TOKEN` must be exported to arm it. Absent that token the entry
/// still ships UNCONFIGURED and a selection attempt is rejected.
///
/// NO vision pairing by default, and that is deliberate rather than an omission: K3 is
/// natively multimodal, so an UNPAIRED entry sends attachments down the scratch-file +
/// Read-tool path where the CLI child hands K3 the actual image. Pairing it with a helper
/// would instead transcribe the image to text and hide the pixels from a model that can
/// see them (see [`crate::vision`]). `JESSE_MODEL_KIMI_VISION` remains available for an
/// operator who wants a helper anyway.
fn kimi_env_entry(default_interval_secs: u64, global_timeout_secs: Option<u64>) -> RegistryModel {
    let backend = resolve_model_backend(
        "kimi-k3",
        env_string("JESSE_MODEL_KIMI_BASE_URL"),
        env_string("JESSE_MODEL_KIMI_AUTH_TOKEN"),
        env_string("JESSE_MODEL_KIMI_MODEL"),
        Some("https://api.fireworks.ai/inference"),
        Some("accounts/fireworks/models/kimi-k3"),
    );
    RegistryModel {
        id: "kimi-k3".to_string(),
        // The SURFACE is in the label because there are now two Kimi entries and they are
        // not interchangeable — see [`kimi_codex_env_entry`]. The id is untouched: it is
        // what the switch persists and what every stored selection already names.
        label: "Kimi K3 (Anthropic)".to_string(),
        kind: ModelKind::Hosted,
        subagent_model: backend.as_ref().map(|(_, _, m)| m.clone()),
        configured: backend.is_some(),
        backend,
        // No declarative entry, so no `level` key: the default applies. A deploy that wants
        // one of these at Write says so in the `[[models]]` array.
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        // Fireworks' published K3 deck (3.00 / 0.30 / 15.00), still overridable from env
        // via `JESSE_MODEL_KIMI_PRICE_{IN,CACHED,OUT}` if Fireworks reprices.
        price: model_price_from_env(
            "JESSE_MODEL_KIMI",
            PriceDeck {
                in_per_m: FW_KIMI_K3_IN_PER_M,
                cached_per_m: FW_KIMI_K3_CACHED_PER_M,
                out_per_m: FW_KIMI_K3_OUT_PER_M,
            },
        ),
        health: HealthConfig {
            interval_secs: default_interval_secs,
            // K3 THINKS before it answers, so even the `max_tokens: 1` probe runs 3–7 s and
            // the 3 s default would mark a perfectly reachable model unhealthy — i.e. keep it
            // out of the picker entirely. See [`REASONING_HEALTH_TIMEOUT_SECS`].
            timeout_secs: resolve_health_timeout(
                None,
                global_timeout_secs,
                REASONING_HEALTH_TIMEOUT_SECS,
            ),
            ..HealthConfig::default()
        },
        vision: parse_vision_partners(&env_string("JESSE_MODEL_KIMI_VISION").unwrap_or_default()),
        vision_complementary: env_flag_true("JESSE_MODEL_KIMI_VISION_COMPLEMENTARY"),
    }
}

/// The `kimi-k3-codex` env-triple entry: the SAME Kimi K3, reached over the surface it
/// natively speaks.
///
/// **Not the same model in two costumes, and the picker must not present it as one.** This
/// entry runs a real `codex exec` child against Fireworks' OpenAI-style Responses API and is
/// governed by `bridge/containment-codex.toml` — an OS sandbox, reaching the vault through
/// the shell. Its sibling [`kimi_env_entry`] runs a Claude Code child against the Anthropic
/// `/v1/messages` surface and is governed by `bridge/containment.toml` — a tool allowlist
/// plus strict MCP. Same weights, different transport, different containment record, and
/// different failure modes. Hence the surface in both labels.
///
/// ARMED BY THE SAME SECRET AS ITS SIBLING (`JESSE_MODEL_KIMI_AUTH_TOKEN`, one Fireworks
/// key), because making an operator paste the same key under a second name to get the
/// RECOMMENDED surface would be a papercut, not a safeguard.
/// `JESSE_MODEL_KIMI_CODEX_AUTH_TOKEN` overrides it for a deploy that wants them on separate
/// keys. Note the consequence, which is deliberate: a deploy that already exports the Kimi
/// key gains this entry the moment it runs a bridge carrying this change.
///
/// The `base_url` default differs from the sibling's by a `/v1` suffix and that is not a
/// typo: an OpenAI-style `base_url` is the API ROOT the harness appends `/responses` to,
/// while the Anthropic-surface one is the host Claude Code appends `/v1/messages` to.
fn kimi_codex_env_entry(
    default_interval_secs: u64,
    global_timeout_secs: Option<u64>,
) -> RegistryModel {
    let backend = resolve_model_backend(
        "kimi-k3-codex",
        env_string("JESSE_MODEL_KIMI_CODEX_BASE_URL"),
        env_string("JESSE_MODEL_KIMI_CODEX_AUTH_TOKEN")
            .or_else(|| env_string("JESSE_MODEL_KIMI_AUTH_TOKEN")),
        env_string("JESSE_MODEL_KIMI_CODEX_MODEL"),
        Some("https://api.fireworks.ai/inference/v1"),
        Some("accounts/fireworks/models/kimi-k3"),
    );
    RegistryModel {
        id: "kimi-k3-codex".to_string(),
        label: "Kimi K3 (Codex)".to_string(),
        kind: ModelKind::OpenAi,
        // NO `CLAUDE_CODE_SUBAGENT_MODEL` analogue on this harness: the codex child is not
        // handed a subagent model, and claiming one here would describe a switch that does
        // not exist.
        subagent_model: None,
        configured: backend.is_some(),
        backend,
        level: Capability::Read,
        harness: CODEX_ID.to_string(),
        // The same weights on the same provider, so the same deck as the sibling — shared
        // `JESSE_MODEL_KIMI_PRICE_*` overrides included, since a reprice moves both.
        price: model_price_from_env(
            "JESSE_MODEL_KIMI",
            PriceDeck {
                in_per_m: FW_KIMI_K3_IN_PER_M,
                cached_per_m: FW_KIMI_K3_CACHED_PER_M,
                out_per_m: FW_KIMI_K3_OUT_PER_M,
            },
        ),
        health: HealthConfig {
            interval_secs: default_interval_secs,
            // Probed at `/chat/completions` on the API root, NOT `/responses` — see
            // [`DEFAULT_OPENAI_HEALTH_PATH`].
            path: default_health_path(ModelKind::OpenAi).to_string(),
            // K3 thinks before it answers on this surface too; the 3 s default would keep a
            // perfectly reachable model out of the picker.
            timeout_secs: resolve_health_timeout(
                None,
                global_timeout_secs,
                REASONING_HEALTH_TIMEOUT_SECS,
            ),
        },
        // Unpaired for the same reason as the sibling: K3 sees images itself, and a helper
        // would transcribe them to text and hide the pixels from a model that can read them.
        vision: parse_vision_partners(
            &env_string("JESSE_MODEL_KIMI_CODEX_VISION").unwrap_or_default(),
        ),
        vision_complementary: env_flag_true("JESSE_MODEL_KIMI_CODEX_VISION_COMPLEMENTARY"),
    }
}

/// The `local` env-triple entry: an Anthropic-compatible local endpoint. NO defaults — all
/// three vars required. Free (price deck 0/0/0), so every local turn badges `$0.00`.
fn local_env_entry(default_interval_secs: u64, global_timeout_secs: Option<u64>) -> RegistryModel {
    let backend = resolve_model_backend(
        "local",
        env_string("JESSE_MODEL_LOCAL_BASE_URL"),
        env_string("JESSE_MODEL_LOCAL_AUTH_TOKEN"),
        env_string("JESSE_MODEL_LOCAL_MODEL"),
        None,
        None,
    );
    RegistryModel {
        id: "local".to_string(),
        label: "Local".to_string(),
        kind: ModelKind::Local,
        subagent_model: backend.as_ref().map(|(_, _, m)| m.clone()),
        configured: backend.is_some(),
        backend,
        // No declarative entry, so no `level` key: the default applies. A deploy that wants
        // one of these at Write says so in the `[[models]]` array.
        level: Capability::Read,
        harness: CLAUDE_CODE_ID.to_string(),
        price: PriceDeck::ZERO,
        health: HealthConfig {
            interval_secs: default_interval_secs,
            timeout_secs: resolve_health_timeout(
                None,
                global_timeout_secs,
                DEFAULT_HEALTH_TIMEOUT_SECS,
            ),
            ..HealthConfig::default()
        },
        vision: parse_vision_partners(&env_string("JESSE_MODEL_LOCAL_VISION").unwrap_or_default()),
        vision_complementary: env_flag_true("JESSE_MODEL_LOCAL_VISION_COMPLEMENTARY"),
    }
}

/// The registry model resolved for ONE turn, plus its effective write permission — the
/// exact inputs the main-turn command builder ([`build_claude_command`]) needs. Built by
/// the handler from the registry + the [`ModelStore`] (see `AppState::resolve_active_model`).
#[derive(Debug, Clone, PartialEq)]
pub struct ActiveModel {
    /// The active model id (`opus`, `glm-5.2`, `local`, …). Names the badge.
    pub id: String,
    pub kind: ModelKind,
    /// The `ANTHROPIC_*` triple to apply to the MAIN turn, or `None` for the ambient
    /// default (apply nothing — the isolation property). NEVER a per-ROLE backend.
    pub env: Option<(String, String, String)>,
    /// The subagent model id (== the triple's model) so the subagents the main turn
    /// spawns follow the switch via `CLAUDE_CODE_SUBAGENT_MODEL`. `None` for ambient.
    pub subagent_model: Option<String>,
    /// This model's LEVEL — the ceiling it may be granted, carried onto the turn so
    /// [`turn_capability`] can take the minimum of it and `Write`. Never the grant itself.
    pub level: Capability,
    /// The harness that runs this model's child, by [`Harness::id`].
    pub harness: String,
    /// The price deck for the per-turn cost badge.
    pub price: PriceDeck,
    /// The vision helpers this model is paired with (copied from its registry entry) plus
    /// the complementary toggle — the exact inputs the vision preprocessor needs. Empty
    /// for ambient opus and any unpaired model: an empty list is the vision-off state on
    /// the hot path, so those turns handle attachments the old way (byte-for-byte).
    pub vision: Vec<VisionPartner>,
    pub vision_complementary: bool,
}

impl ActiveModel {
    /// Whether this model may change the vault: its level is `Write`.
    ///
    /// Derived from the level rather than stored, so there is exactly one source of truth
    /// for what a model may touch. The per-model boolean this replaced was settable from the
    /// phone; a level is config-only and is validated at startup against the containment
    /// record.
    pub fn writes_allowed(&self) -> bool {
        self.level >= Capability::Write
    }

    /// The ambient default (`opus`): no env overrides, writes-on. A turn built with this
    /// is byte-for-byte today's behavior — the value the title one-shot and any
    /// no-switch caller pass so nothing about their command changes.
    pub fn ambient() -> Self {
        ActiveModel {
            id: DEFAULT_MODEL_ID.to_string(),
            kind: ModelKind::Ambient,
            env: None,
            subagent_model: None,
            level: Capability::Write,
            harness: CLAUDE_CODE_ID.to_string(),
            price: PriceDeck {
                in_per_m: OPUS_IN_PER_M,
                cached_per_m: OPUS_CACHED_PER_M,
                out_per_m: OPUS_OUT_PER_M,
            },
            // Ambient opus sees images natively (CLI Read tool); never uses the helper layer.
            vision: Vec::new(),
            vision_complementary: false,
        }
    }

    /// Build the `ActiveModel` for a resolved registry entry — the pure half of the
    /// mapping, with no app state behind it.
    ///
    /// Extracted from `State::active_model_for` (which now delegates here) so the
    /// CONTAINMENT BATTERY can build the same value. The battery probes through the harness
    /// the bridge actually ships; a battery that assembled its own `ActiveModel` would be
    /// recording a posture nothing spawns, which is the same failure mode the harness-built
    /// argv exists to avoid. One mapping, both callers.
    ///
    /// Health is deliberately NOT consulted: that is the caller's gate (the endpoint layer
    /// rejects an unhealthy per-turn selection; the probe binary demands `configured`).
    pub fn from_registry(m: &RegistryModel) -> Self {
        ActiveModel {
            id: m.id.clone(),
            kind: m.kind,
            env: m.backend.clone(),
            subagent_model: m.subagent_model.clone(),
            level: m.level,
            harness: m.harness.clone(),
            price: m.price,
            vision: m.vision.clone(),
            vision_complementary: m.vision_complementary,
        }
    }

    /// Whether this active model applies `ANTHROPIC_*` overrides to the main turn (i.e.
    /// it is a hosted/local backend, not the ambient default).
    pub fn is_non_ambient(&self) -> bool {
        self.env.is_some()
    }
}

/// The always-present ambient default entry.
fn opus_entry() -> RegistryModel {
    RegistryModel {
        id: DEFAULT_MODEL_ID.to_string(),
        label: "Claude Opus".to_string(),
        kind: ModelKind::Ambient,
        backend: None,
        subagent_model: None,
        configured: true,
        // The ambient default is the out-of-box conversation backend and the routing rule's
        // final fallback, so it is the one built-in `Write` entry. Not settable: there is no
        // `[[models]]` entry for opus (a declarative entry that tries to redefine it is
        // refused), which is what keeps the ambient contract out of config's reach.
        level: Capability::Write,
        harness: CLAUDE_CODE_ID.to_string(),
        price: PriceDeck {
            in_per_m: OPUS_IN_PER_M,
            cached_per_m: OPUS_CACHED_PER_M,
            out_per_m: OPUS_OUT_PER_M,
        },
        health: HealthConfig::default(),
        // Ambient opus already sees images through the CLI's native Read tool, so it is
        // never paired — vision helpers exist for the text backends that cannot.
        vision: Vec::new(),
        vision_complementary: false,
    }
}

// ---- Declarative `[[models]]` config (source 3) ---------------------------
//
// A `[[models]]` array in the bridge config file (the same TOML the persona loads from)
// declares a model with a pure config edit plus one env var for its token — no Rust change.
// Every field is optional at the parse layer so a partial/typo'd entry is SKIPPED with a
// warning rather than failing the whole file (which would also drop the persona); the
// required fields (`id`, `kind`, `base_url`, `model`) are validated in code.

/// The optional `price = { in_per_m, cached_per_m, out_per_m }` sub-table (each field
/// defaults to 0.0 → a free model unless priced).
#[derive(Deserialize, Debug, Default, Clone)]
pub struct PriceToml {
    pub in_per_m: Option<f64>,
    pub cached_per_m: Option<f64>,
    pub out_per_m: Option<f64>,
}

/// The optional `health = { path, interval_secs, timeout_secs }` sub-table (each field
/// defaults independently — see [`HealthConfig`]).
#[derive(Deserialize, Debug, Default, Clone)]
pub struct HealthToml {
    pub path: Option<String>,
    pub interval_secs: Option<u64>,
    pub timeout_secs: Option<u64>,
}

/// One `[[models]]` entry. `auth_token_env` is the NAME of the env var holding the token —
/// NEVER the token itself; it is resolved from the process env at startup and a missing/
/// unset var yields a configured-but-unarmed (present, not selectable) model.
#[derive(Deserialize, Debug, Default, Clone)]
pub struct ModelToml {
    pub id: Option<String>,
    pub label: Option<String>,
    /// `hosted` | `local` (`ambient` is reserved for the built-in opus and refused).
    pub kind: Option<String>,
    pub base_url: Option<String>,
    pub model: Option<String>,
    pub subagent_model: Option<String>,
    pub auth_token_env: Option<String>,
    /// The harness that runs this model's child (`claude-code`, `codex`, …). Absent means
    /// `claude-code`. An id no harness is registered under is a startup ERROR, never a
    /// silent fallback — see [`validate_model_config`].
    pub harness: Option<String>,
    /// The CEILING this model may be granted: `basic` | `read` | `write`. Absent means
    /// `read`. See [`RegistryModel::level`].
    pub level: Option<String>,
    /// REMOVED, and parsed only so its presence can be REFUSED at startup.
    ///
    /// The models deserializer ignores unknown keys (so a forward-looking example file
    /// parses), which means a key that silently stops being read is a silent security
    /// downgrade: a deploy that wrote `default_writes = true` would quietly become a
    /// read-only model. Keeping the field here turns that into a loud startup error naming
    /// `level` as its replacement.
    pub default_writes: Option<bool>,
    pub price: Option<PriceToml>,
    pub health: Option<HealthToml>,
    /// Vision pairing: an ordered list of `{ id, role }` partner entries. Absent/empty
    /// → this model has no vision (today's behavior). See [`VisionPartnerToml`].
    pub vision: Option<Vec<VisionPartnerToml>>,
    /// Complementary mode toggle (default false). See [`RegistryModel::vision_complementary`].
    pub vision_complementary: Option<bool>,
}

/// One `vision = [{ id = "...", role = "doc|general|any" }]` partner entry. `id` is
/// required (a blank one is skipped); `role` defaults to `any` when absent or unknown.
#[derive(Deserialize, Debug, Default, Clone)]
pub struct VisionPartnerToml {
    pub id: Option<String>,
    pub role: Option<String>,
}

/// Parse a declarative `kind` string into a [`ModelKind`]. Only `hosted` / `local` /
/// `openai` are valid; `ambient` (and anything else) is refused so a declarative entry can
/// never claim the ambient contract.
fn parse_declared_kind(kind: &str) -> Option<ModelKind> {
    match kind.trim().to_ascii_lowercase().as_str() {
        "hosted" => Some(ModelKind::Hosted),
        "local" => Some(ModelKind::Local),
        "openai" => Some(ModelKind::OpenAi),
        _ => None,
    }
}

/// Resolve a declared model's token from its `auth_token_env` var NAME. `Some(token)` only
/// when the field is present AND that env var is set to a non-blank value; otherwise `None`
/// (the model is configured-but-unarmed — present in the list, not selectable). The token
/// value is NEVER logged.
fn resolve_declared_token(auth_token_env: Option<&str>) -> Option<String> {
    auth_token_env
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .and_then(env_string)
}

/// Build a [`RegistryModel`] from one declarative `[[models]]` entry, or `None` (with a
/// warning) when a required field is missing or `kind` is invalid. The backend resolves to
/// `Some(triple)` — and `configured` to true — ONLY when the named token env var is set;
/// otherwise the entry is present-but-unarmed (`configured = false`), the same treatment an
/// unresolved env triple gets. No token is ever written back into the entry the endpoints
/// serialize — it lives solely inside `backend`. `global_interval` is the resolved
/// `JESSE_HEALTH_INTERVAL_SECS` override (or `None`), applied to this model's probe interval
/// unless it declares its own `health.interval_secs` (see [`resolve_health_interval`]).
pub fn registry_model_from_toml(
    t: &ModelToml,
    global_interval: Option<u64>,
    global_timeout: Option<u64>,
) -> Option<RegistryModel> {
    let id = t.id.as_deref().map(str::trim).filter(|s| !s.is_empty());
    let (id, kind_str, base_url, model) = match (
        id,
        t.kind.as_deref().map(str::trim).filter(|s| !s.is_empty()),
        t.base_url
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty()),
        t.model.as_deref().map(str::trim).filter(|s| !s.is_empty()),
    ) {
        (Some(id), Some(k), Some(b), Some(m)) => (id, k, b, m),
        _ => {
            eprintln!(
                "jesse-bridge: WARNING a declarative [[models]] entry (id {:?}) is missing a \
                 required field (id, kind, base_url, model are all required); ignoring it.",
                t.id
            );
            return None;
        }
    };
    let Some(kind) = parse_declared_kind(kind_str) else {
        eprintln!(
            "jesse-bridge: WARNING declarative model '{id}' has invalid kind '{kind_str}' \
             (must be 'hosted' or 'local'; 'ambient' is reserved); ignoring it."
        );
        return None;
    };
    let token = resolve_declared_token(t.auth_token_env.as_deref());
    if token.is_none() {
        // Present-but-unarmed: log ONCE so a half-configured model is visible, then ship it
        // unconfigured (in the list, not selectable) — never the token, only the var name.
        match t
            .auth_token_env
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            Some(var) => eprintln!(
                "jesse-bridge: model '{id}' is configured-but-unarmed — its auth_token_env \
                 '{var}' is unset; it appears in the list but is not selectable until armed."
            ),
            None => eprintln!(
                "jesse-bridge: model '{id}' has no auth_token_env — it appears in the list but \
                 is not selectable until an auth_token_env naming a set var is supplied."
            ),
        }
    }
    let configured = token.is_some();
    let backend = token.map(|tok| (base_url.to_string(), tok, model.to_string()));
    let subagent_model = t
        .subagent_model
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        // Default the subagent model to the main model — but only when configured, so an
        // unarmed entry carries no backend-derived value (mirrors the env triples).
        .or_else(|| configured.then(|| model.to_string()));
    let price = t
        .price
        .as_ref()
        .map(|p| PriceDeck {
            in_per_m: p.in_per_m.unwrap_or(0.0),
            cached_per_m: p.cached_per_m.unwrap_or(0.0),
            out_per_m: p.out_per_m.unwrap_or(0.0),
        })
        .unwrap_or(PriceDeck::ZERO);
    let health = t
        .health
        .as_ref()
        .map(|h| HealthConfig {
            path: h
                .path
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                // The default is KIND-AWARE: an OpenAI-surface model's base_url answers
                // `/chat/completions`, not `/v1/messages`. See [`default_health_path`].
                .unwrap_or_else(|| default_health_path(kind))
                .to_string(),
            // Explicit per-model interval wins; else the global override; else the default.
            interval_secs: resolve_health_interval(h.interval_secs, global_interval),
            // Same precedence for the timeout. A declarative entry has no way to say "I am a
            // reasoning model", so its fallback stays the ordinary 3 s default — an operator
            // who declares a slow model sets `health.timeout_secs` (or the global override).
            timeout_secs: resolve_health_timeout(
                h.timeout_secs,
                global_timeout,
                DEFAULT_HEALTH_TIMEOUT_SECS,
            ),
        })
        // No `health` block at all: still honor the global overrides, and still take the
        // kind-aware default path.
        .unwrap_or_else(|| HealthConfig {
            path: default_health_path(kind).to_string(),
            interval_secs: resolve_health_interval(None, global_interval),
            timeout_secs: resolve_health_timeout(None, global_timeout, DEFAULT_HEALTH_TIMEOUT_SECS),
        });
    Some(RegistryModel {
        id: id.to_string(),
        label: t
            .label
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(id)
            .to_string(),
        kind,
        backend,
        subagent_model,
        configured,
        // A bad/absent `level` resolves to the safe default here; `validate_model_config`
        // is what REFUSES an unparseable one at startup, so a typo is never a silent
        // downgrade to Read.
        level: t
            .level
            .as_deref()
            .map(str::trim)
            .and_then(parse_capability)
            .unwrap_or(DEFAULT_MODEL_LEVEL),
        harness: t
            .harness
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or(CLAUDE_CODE_ID)
            .to_string(),
        price,
        health,
        vision: t
            .vision
            .as_deref()
            .unwrap_or(&[])
            .iter()
            .filter_map(|p| {
                let id = p.id.as_deref().map(str::trim).filter(|s| !s.is_empty())?;
                Some(VisionPartner {
                    id: id.to_string(),
                    role: VisionRole::parse(p.role.as_deref().unwrap_or("any")),
                })
            })
            .collect(),
        vision_complementary: t.vision_complementary.unwrap_or(false),
    })
}

/// Resolve a registry model's `(base_url, auth_token, model)` triple from its env parts,
/// layering the optional defaults for base/model UNDER the env values. All-or-nothing,
/// mirroring [`resolve_vaultqa_backend`]: returns `Some` only when all three resolve
/// (env or default), else `None` (the model is UNAVAILABLE — never a partial config). A
/// partial ENV config (some `JESSE_MODEL_<X>_*` set but the triple still incomplete)
/// logs one startup warning; a model left entirely unset resolves to `None` silently.
pub fn resolve_model_backend(
    id: &str,
    env_base: Option<String>,
    env_token: Option<String>,
    env_model: Option<String>,
    default_base: Option<&str>,
    default_model: Option<&str>,
) -> Option<(String, String, String)> {
    let env_count =
        env_base.is_some() as u8 + env_token.is_some() as u8 + env_model.is_some() as u8;
    let base = env_base.or_else(|| default_base.map(str::to_string));
    let model = env_model.or_else(|| default_model.map(str::to_string));
    match (base, env_token, model) {
        (Some(b), Some(t), Some(m)) => Some((b, t, m)),
        _ => {
            if env_count > 0 {
                eprintln!(
                    "jesse-bridge: WARNING partial JESSE_MODEL_* config for '{id}' \
                     ({env_count} env var(s) set) — a selectable model needs base_url + \
                     auth_token + model_id (base/model may default); treating '{id}' as \
                     UNAVAILABLE."
                );
            }
            None
        }
    }
}

/// Read an optional per-model price deck from `<prefix>_PRICE_IN` / `_PRICE_CACHED` /
/// `_PRICE_OUT` (dollars per 1M tokens). Any missing/unparseable field falls back to the
/// same field of `default`, so a fully-unset prefix yields `default` unchanged.
pub fn model_price_from_env(prefix: &str, default: PriceDeck) -> PriceDeck {
    PriceDeck {
        in_per_m: env_parse(&format!("{prefix}_PRICE_IN"), default.in_per_m),
        cached_per_m: env_parse(&format!("{prefix}_PRICE_CACHED"), default.cached_per_m),
        out_per_m: env_parse(&format!("{prefix}_PRICE_OUT"), default.out_per_m),
    }
}

impl Config {
    pub fn from_env() -> Self {
        let home = std::env::var("HOME").unwrap_or_default();
        // Built BEFORE the struct literal so the harness registry below can be built from
        // the harnesses this config actually names. Nothing else about it changed.
        let model_registry = ModelRegistry::from_env(&home);
        Config {
            token: env_string("JESSE_TOKEN").unwrap_or_default(),
            // Capture HOME once — session-path lookups read `cfg.home`, not the env.
            home: home.clone(),
            vault: env_string("JESSE_VAULT").unwrap_or_else(|| format!("{home}/vault")),
            bind: env_string("JESSE_BIND").unwrap_or_else(|| "127.0.0.1".to_string()),
            port: env_parse("JESSE_PORT", 8765),
            claude_bin: env_string("JESSE_CLAUDE_BIN").unwrap_or_else(|| "claude".to_string()),
            codex_bin: env_string("JESSE_CODEX_BIN").unwrap_or_else(|| "codex".to_string()),
            offload_order: load_offload_order(&home),
            // 90m default; clamped to [1, HARD_TIMEOUT_CEILING].
            timeout_secs: clamp_timeout_secs(env_parse("JESSE_TIMEOUT", DEFAULT_TIMEOUT_SECS)),
            // The cut-off turn's partial-answer ring. Blocks are floored at 1 (a
            // zero-block ring could retain nothing at all, which is what `partial_bytes: 0`
            // is for and says more clearly).
            partial_blocks: env_parse("JESSE_PARTIAL_BLOCKS", DEFAULT_PARTIAL_BLOCKS).max(1),
            partial_bytes: env_parse("JESSE_PARTIAL_BYTES", DEFAULT_PARTIAL_BYTES),
            allowed_tools: env_string("JESSE_ALLOWED_TOOLS")
                .unwrap_or_else(|| DEFAULT_ALLOWED_TOOLS.to_string()),
            disallowed_tools: env_string("JESSE_DISALLOWED_TOOLS")
                .unwrap_or_else(|| DEFAULT_DISALLOWED_TOOLS.to_string()),
            // THE DEPRECATED KEY IS REMAPPED, NOT IGNORED AND NOT FATAL.
            //
            // `JESSE_MAX_CONCURRENCY` used to be the one global limit. An operator who set it
            // to 1 on purpose must not silently end up with six turns in flight after an
            // upgrade, so it becomes the GLOBAL CEILING — which for a value of 1 reproduces
            // today's behavior exactly. Erroring instead would break a running deploy on its
            // next restart, and ignoring it would be the silent widening. Announced at
            // startup; see `warn_deprecated_concurrency`.
            concurrency: {
                let mut c = load_concurrency(&home);
                c.legacy_max_concurrency = std::env::var("JESSE_MAX_CONCURRENCY")
                    .ok()
                    .and_then(|s| s.parse::<usize>().ok())
                    .filter(|n| *n >= 1);
                c
            },
            // Wait-queue depth; floor 0 (0 → no queue). A parsed value is honored
            // as-is; unset/unparseable → DEFAULT_MAX_QUEUED.
            max_queued: env_parse("JESSE_MAX_QUEUED", DEFAULT_MAX_QUEUED),
            rate_per_min: std::env::var("JESSE_RATE_PER_MIN")
                .ok()
                .and_then(|s| s.parse().ok())
                .filter(|n| *n >= 1)
                .unwrap_or(30),
            job_ttl_secs: env_parse("JESSE_JOB_TTL_SECS", DEFAULT_JOB_TTL_SECS),
            retrieval_grace_secs: env_parse(
                "JESSE_RETRIEVAL_GRACE_SECS",
                DEFAULT_RETRIEVAL_GRACE_SECS,
            ),
            session_ttl_days: env_parse("JESSE_SESSION_TTL_DAYS", DEFAULT_SESSION_TTL_DAYS),
            state_dir: env_string("JESSE_STATE_DIR").or_else(|| {
                // Default: a dotdir under HOME. Empty HOME → no default
                // (persistence off) rather than writing to a bare "/.jesse-bridge".
                (!home.is_empty()).then(|| format!("{home}/.jesse-bridge"))
            }),
            max_attachments: env_parse("JESSE_MAX_ATTACHMENTS", DEFAULT_MAX_ATTACHMENTS),
            max_attachment_bytes: env_parse(
                "JESSE_MAX_ATTACHMENT_BYTES",
                DEFAULT_MAX_ATTACHMENT_BYTES,
            ),
            max_attachments_total_bytes: env_parse(
                "JESSE_MAX_ATTACHMENTS_TOTAL_BYTES",
                DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES,
            ),
            scratch_dir: env_string("JESSE_SCRATCH_DIR"),
            // Micronutrient completion defaults to TRUE (same truthiness convention as
            // probation/badge): OFF is the old behavior that left knowable nutrient
            // columns blank, so an operator must opt OUT explicitly. Independent of
            // model selection by design — see the field docs.
            diet_micro_complete: resolve_diet_micro_complete(),
            // Optional MCP config path for the vault-QA child (the qmd server). Unset →
            // None → the child runs the read-only built-ins only, qmd absent.
            vaultqa_mcp_config: env_string("JESSE_VAULTQA_MCP_CONFIG"),
            // Optional MCP config for the MAIN turn. Unset → None → the qmd-only inline
            // const (`claude::MAIN_CHILD_MCP_CONFIG`), never the empty set.
            main_mcp_config: env_string("JESSE_MAIN_MCP_CONFIG"),
            // Provenance badge on delivered replies; default on (see `resolve_model_badge`).
            model_badge: resolve_model_badge(),
            // Structured-metrics log path. Same `env_string` (trimmed, empty-filtered)
            // semantics — a blank value counts as unset → None → zero metrics writes.
            metrics_log: env_string("JESSE_METRICS_LOG"),
            // Emergency local fallback arm; default OFF (see `resolve_emergency_local`).
            emergency_local: resolve_emergency_local(),
            // Context ledger (context carry); default ON (see `resolve_context_carry`).
            context_carry: resolve_context_carry(),
            // All-or-nothing SHADOW-comparison backend override, same `env_string`
            // (trimmed, empty-filtered) semantics as every other string field. Partial
            // config logs one warning and resolves to None (see `resolve_shadow_backend`).
            // Unset (the default) → None → shadow mode is disarmed and not a single ask
            // turn is mirrored (the kill switch).
            shadow_backend: resolve_shadow_backend(
                env_string("JESSE_SHADOW_BASE_URL"),
                env_string("JESSE_SHADOW_AUTH_TOKEN"),
                env_string("JESSE_SHADOW_MODEL"),
            ),
            // Sample percentage of eligible ask turns to mirror; default 100, clamped
            // to [0, 100]. An unset/unparseable value keeps the 100 default.
            shadow_sample_pct: clamp_sample_pct(env_parse("JESSE_SHADOW_SAMPLE_PCT", 100)),
            // Shadow pair log; `~` expanded against the captured HOME, default under
            // `~/Library/Logs/jesse-shadow/`. Only ever written when shadow is armed.
            shadow_log: expand_tilde(
                &env_string("JESSE_SHADOW_LOG")
                    .unwrap_or_else(|| "~/Library/Logs/jesse-shadow/shadow.jsonl".to_string()),
                &home,
            ),
            // Shadow child wall-clock budget; default 120s. A timeout logs an
            // incomplete pair and never retries.
            shadow_timeout_secs: env_parse("JESSE_SHADOW_TIMEOUT_SECS", 120),
            // Personalization overlay: generic defaults → jesse.local.toml → env.
            // Resolved once at startup against the captured HOME (used to find the
            // state-dir config location for a launchd service outside the repo).
            persona: Persona::load(&home),
            // The built-in scheduler's jobs, read from the SAME overlay file and validated
            // here. Validation NEVER fails this constructor: a bad entry is disabled
            // individually (`Schedule::invalid`) and a duplicate id or `after` cycle is
            // collected in `Schedule::fatal` for `main` to refuse the boot on — the same
            // shape as the model gate, so config problems are decided in one place and
            // reported before the socket opens.
            schedule: Arc::new(validate_schedule(&load_schedule(&home))),
            // The selectable-model registry, MERGED from the built-in ambient opus, the
            // JESSE_MODEL_* env triples, and the declarative `[[models]]` config file (see
            // ModelRegistry::from_env). Always includes the ambient opus default; the other
            // entries are unconfigured (present, not selectable) until their token resolves.
            // Vision-layer knobs; bounded so a bad env value can't degrade the pipeline.
            vision: resolve_vision_config(),
            // The harness registry, built from the harnesses the CONFIG names — not a
            // hardcoded singleton. No env configures this: a model's `harness` key is what
            // asks for one, and `for_models` constructs only the ids it knows (always
            // registering Claude Code first, so the ambient contract holds regardless).
            //
            // This is deliberately built from EVERY declared model, not just the configured
            // ones, because the startup gate validates unarmed entries too: a model that is
            // present-but-unarmed must still be refused for a level its harness cannot
            // express, rather than for the unrelated reason that its harness was missing.
            //
            // While this was `claude_code_only()` a `harness = "codex"` model could not
            // start at all — the gate refused it as an "unknown harness", so registering
            // Codex in `KNOWN_HARNESS_IDS` and `for_models` bought nothing on the startup
            // path and every Codex test had to hand-patch this field to pass.
            harnesses: Arc::new(HarnessRegistry::for_models(
                model_registry
                    .models
                    .iter()
                    .map(|m| m.harness.as_str())
                    .collect::<Vec<_>>(),
            )),
            model_registry,
        }
    }
}

/// Republish the LaunchAgent's `JESSE_*` credentials under the names the MCP servers
/// actually read, and supply the non-secret settings they need, in the BRIDGE's own
/// environment — before any child is spawned.
///
/// # Why this exists at all
///
/// The plist stores `JESSE_UNIFI_USERNAME`, `JESSE_GITHUB_PAT`, and so on: prefixed, so the
/// bridge's environment stays legible and a stray `UNIFI_PASSWORD` in some other tool's
/// scope cannot be mistaken for ours. Every server, though, reads the name its own vendor
/// chose. Something has to bridge the two, and it has to be THIS process rather than either
/// harness:
///
/// * Claude Code's MCP subprocesses inherit the bridge's environment wholesale, so a name
///   published here is simply present.
/// * Codex scrubs the subprocess environment down to a handful of variables and forwards
///   only what [`crate::CODEX_MCP_ENV_PASSTHROUGH`] names — BY NAME, with no ability to
///   rename in flight. It can only forward a variable that already exists here.
///
/// So one function serves both harnesses, and the passthrough table must name exactly what
/// this publishes. A name in that table with no publisher here means the server starts and
/// registers ZERO tools — the failure is silent, and it looks like a broken server rather
/// than a missing variable.
///
/// # Never overwrite
///
/// Every write is conditional on the target being unset, so a deployment that already
/// exports a vendor name wins. That keeps this from being a hidden second source of truth
/// for a value an operator set deliberately.
///
/// # Paths are built at RUNTIME, never written as literals
///
/// `WORKSPACE_MCP_CREDENTIALS_DIR` and `ROUTEROS_DEVICES_CONFIG` are under `$HOME`. Writing
/// them as literals would hard-code one home directory into a tracked file and trip
/// `scripts/ci-guards.sh` (R5, personal infrastructure). Composing them from `HOME` at
/// startup keeps the source machine-independent, which is the same property the bare-command
/// MCP entries in [`crate::MAIN_CHILD_MCP_CONFIG`] preserve.
///
/// # Proxmox is absent on purpose
///
/// It reads `__dirname/../.env` relative to its own file, so it needs nothing from here and
/// is not in the passthrough table either.
pub fn export_mcp_server_env() {
    fn set_if_unset(key: &str, value: &str) {
        if std::env::var_os(key).is_none() && !value.is_empty() {
            std::env::set_var(key, value);
        }
    }
    fn map(from: &str, to: &str) {
        if let Ok(v) = std::env::var(from) {
            set_if_unset(to, &v);
        }
    }

    // Credentials: plist name -> the name the server reads.
    map("JESSE_GOOGLE_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_ID");
    map("JESSE_GOOGLE_SECRET", "GOOGLE_OAUTH_CLIENT_SECRET");
    map("JESSE_GITHUB_PAT", "GITHUB_PERSONAL_ACCESS_TOKEN");
    map("JESSE_JMAP_TOKEN", "JMAP_TOKEN");
    map("JESSE_UNIFI_USERNAME", "UNIFI_USERNAME");
    map("JESSE_UNIFI_PASSWORD", "UNIFI_PASSWORD");

    // Non-secret settings the servers need. UniFi's controller is a UDM-PRO-SE speaking the
    // UniFi OS proxy API, which is why `CONTROLLER_TYPE` is `proxy` and TLS verification is
    // off (it serves a self-signed certificate on the LAN).
    set_if_unset("UNIFI_HOST", "10.20.0.2");
    set_if_unset("UNIFI_PORT", "443");
    set_if_unset("UNIFI_CONTROLLER_TYPE", "proxy");
    set_if_unset("UNIFI_VERIFY_SSL", "false");
    set_if_unset("UNIFI_SITE", "default");
    set_if_unset("JMAP_SESSION_URL", "https://api.fastmail.com/jmap/session");
    // RouterOS SSH listens on 2324, not 22. The server tries `api` (8728) first, so this
    // only matters for the fallback path — but a wrong port there turns a clean failure
    // into a hang.
    set_if_unset("ROUTEROS_SSH_PORT", "2324");

    if let Some(home) = std::env::var_os("HOME") {
        let home = std::path::PathBuf::from(home);
        // The Google OAuth token cache MUST be persistent. A `/tmp` path survives until the
        // next reboot and then forces an interactive re-consent, which a headless bridge
        // turn cannot perform — the servers would simply stop answering one morning.
        set_if_unset(
            "WORKSPACE_MCP_CREDENTIALS_DIR",
            &home.join(".config/jesse-google/creds").to_string_lossy(),
        );
        // Where the Google server writes attachments and downloaded Drive files. Pointed
        // OUT of the working tree deliberately: MCP servers run outside the child's sandbox
        // and default to writing into the cwd, which is the vault.
        set_if_unset(
            "WORKSPACE_ATTACHMENT_DIR",
            &home
                .join(".config/jesse-google/attachments")
                .to_string_lossy(),
        );
        // RouterOS reads its device list from a FILE rather than the environment, so what
        // gets forwarded is the path, not a credential.
        set_if_unset(
            "ROUTEROS_DEVICES_CONFIG",
            &home
                .join(".config/routeros-mcp/devices.yaml")
                .to_string_lossy(),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    #[test]
    fn env_string_trims_and_filters_empty() {
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_TEST_ENV_STRING", "  hi  ");
        assert_eq!(env_string("JESSE_TEST_ENV_STRING").as_deref(), Some("hi"));
        // A blank/whitespace value is treated as unset — the consistency the fix
        // establishes across every string field.
        std::env::set_var("JESSE_TEST_ENV_STRING", "   ");
        assert_eq!(env_string("JESSE_TEST_ENV_STRING"), None);
        std::env::remove_var("JESSE_TEST_ENV_STRING");
        assert_eq!(env_string("JESSE_TEST_ENV_STRING"), None);
    }

    #[test]
    fn env_parse_falls_back_on_unset_or_unparseable() {
        let _g = ENV_LOCK.lock_ok();
        std::env::remove_var("JESSE_TEST_ENV_PARSE");
        assert_eq!(env_parse::<u64>("JESSE_TEST_ENV_PARSE", 7), 7);
        std::env::set_var("JESSE_TEST_ENV_PARSE", "42");
        assert_eq!(env_parse::<u64>("JESSE_TEST_ENV_PARSE", 7), 42);
        std::env::set_var("JESSE_TEST_ENV_PARSE", "not-a-number");
        assert_eq!(env_parse::<u64>("JESSE_TEST_ENV_PARSE", 7), 7);
        std::env::remove_var("JESSE_TEST_ENV_PARSE");
    }

    #[test]
    fn resolve_model_backend_all_or_nothing_with_defaults() {
        // GLM-shape: base + model DEFAULT, only the token supplied → available.
        let glm = resolve_model_backend(
            "glm-5.2",
            None,
            Some("tok".into()),
            None,
            Some("https://api.fireworks.ai/inference"),
            Some("accounts/fireworks/models/glm-5p2"),
        );
        assert_eq!(
            glm,
            Some((
                "https://api.fireworks.ai/inference".into(),
                "tok".into(),
                "accounts/fireworks/models/glm-5p2".into()
            )),
            "token-only arms a defaulted hosted model"
        );
        // No token → unavailable, even though base/model default.
        assert_eq!(
            resolve_model_backend(
                "glm-5.2",
                None,
                None,
                None,
                Some("https://api.fireworks.ai/inference"),
                Some("accounts/fireworks/models/glm-5p2"),
            ),
            None,
            "no token → unavailable"
        );
        // No defaults (e.g. `local`): all three required.
        assert_eq!(
            resolve_model_backend(
                "local",
                Some("http://l".into()),
                Some("t".into()),
                None,
                None,
                None
            ),
            None,
            "a partial no-default triple is unavailable, never partial"
        );
        assert_eq!(
            resolve_model_backend(
                "local",
                Some("http://l".into()),
                Some("t".into()),
                Some("m".into()),
                None,
                None
            ),
            Some(("http://l".into(), "t".into(), "m".into())),
        );
    }

    #[test]
    fn opus_only_registry_is_just_the_ambient_default() {
        let r = ModelRegistry::opus_only();
        assert_eq!(r.models.len(), 1);
        let opus = r.default_model();
        assert_eq!(opus.id, "opus");
        assert!(matches!(opus.kind, ModelKind::Ambient));
        assert!(opus.configured && opus.level == Capability::Write);
        assert!(
            !r.is_configured("glm-5.2"),
            "an absent model is not configured"
        );
    }

    #[test]
    fn config_from_env_defaults() {
        let _guard = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = [
            "JESSE_TOKEN",
            "JESSE_VAULT",
            "JESSE_BIND",
            "JESSE_PORT",
            "JESSE_CLAUDE_BIN",
            "JESSE_TIMEOUT",
            "JESSE_PARTIAL_BLOCKS",
            "JESSE_PARTIAL_BYTES",
            "JESSE_MAX_CONCURRENCY",
            "JESSE_MAX_QUEUED",
            "JESSE_JOB_TTL_SECS",
            "JESSE_RETRIEVAL_GRACE_SECS",
            "JESSE_STATE_DIR",
            "JESSE_MAX_ATTACHMENTS",
            "JESSE_MAX_ATTACHMENT_BYTES",
            "JESSE_MAX_ATTACHMENTS_TOTAL_BYTES",
            "JESSE_SCRATCH_DIR",
        ]
        .iter()
        .map(|k| (*k, std::env::var(k).ok()))
        .collect();
        for (k, _) in &saved {
            std::env::remove_var(k);
        }

        let cfg = Config::from_env();
        assert_eq!(cfg.token, "");
        assert_eq!(cfg.bind, "127.0.0.1");
        assert_eq!(cfg.port, 8765);
        assert_eq!(cfg.claude_bin, "claude");
        assert_eq!(cfg.timeout_secs, DEFAULT_TIMEOUT_SECS);
        assert_eq!(cfg.timeout_secs, 5400, "90m, raised from the old 1h");
        // The cut-off turn's partial-answer ring: 8 blocks / 16 KB unless overridden.
        assert_eq!(cfg.partial_blocks, DEFAULT_PARTIAL_BLOCKS);
        assert_eq!(cfg.partial_bytes, DEFAULT_PARTIAL_BYTES);
        // Single-writer default: one turn runs at a time; a burst of up to
        // DEFAULT_MAX_QUEUED waits behind it rather than being rejected.
        assert_eq!(cfg.concurrency.legacy_max_concurrency, None);
        assert_eq!(cfg.max_queued, DEFAULT_MAX_QUEUED);
        // Eviction defaults: 24h hold for an unfetched reply, short post-fetch grace.
        assert_eq!(cfg.job_ttl_secs, DEFAULT_JOB_TTL_SECS);
        assert_eq!(cfg.retrieval_grace_secs, DEFAULT_RETRIEVAL_GRACE_SECS);
        // No JESSE_STATE_DIR → persistence defaults to a dotdir under HOME (when
        // HOME is set), with job files under `<state_dir>/jobs`.
        match std::env::var("HOME").ok().filter(|h| !h.is_empty()) {
            Some(home) => {
                assert_eq!(
                    cfg.state_dir.as_deref(),
                    Some(format!("{home}/.jesse-bridge").as_str())
                );
                assert_eq!(
                    cfg.jobs_dir(),
                    Some(PathBuf::from(format!("{home}/.jesse-bridge/jobs")))
                );
            }
            None => {
                assert_eq!(cfg.state_dir, None);
                assert_eq!(cfg.jobs_dir(), None);
            }
        }
        assert_eq!(cfg.max_attachments, DEFAULT_MAX_ATTACHMENTS);
        assert_eq!(cfg.max_attachment_bytes, DEFAULT_MAX_ATTACHMENT_BYTES);
        assert_eq!(
            cfg.max_attachments_total_bytes,
            DEFAULT_MAX_ATTACHMENTS_TOTAL_BYTES
        );
        // No JESSE_SCRATCH_DIR → scratch base falls back to the system temp dir.
        assert_eq!(cfg.scratch_dir, None);
        assert_eq!(cfg.scratch_base(), std::env::temp_dir());

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }
    #[test]
    fn timeout_clamp_treats_zero_as_ceiling() {
        // 0 means "ceiling", never unlimited.
        assert_eq!(clamp_timeout_secs(0), HARD_TIMEOUT_CEILING);
        // Over-ceiling is capped; in-range is unchanged; 1 is the floor.
        assert_eq!(
            clamp_timeout_secs(HARD_TIMEOUT_CEILING + 10),
            HARD_TIMEOUT_CEILING
        );
        assert_eq!(clamp_timeout_secs(1800), 1800);
        assert_eq!(clamp_timeout_secs(1), 1);
        // The raised DEFAULT still sits UNDER the unchanged ceiling and passes through.
        const _: () = assert!(DEFAULT_TIMEOUT_SECS < HARD_TIMEOUT_CEILING);
        assert_eq!(clamp_timeout_secs(DEFAULT_TIMEOUT_SECS), 5400);
        assert_eq!(HARD_TIMEOUT_CEILING, 7200, "the ceiling is unchanged");
    }
    #[test]
    fn timeout_env_override_still_clamps_at_the_ceiling() {
        let _guard = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_TIMEOUT").ok();
        // An operator asking for more than the ceiling gets the ceiling, not the ask.
        std::env::set_var("JESSE_TIMEOUT", "99999");
        assert_eq!(Config::from_env().timeout_secs, HARD_TIMEOUT_CEILING);
        // An explicit in-range value still wins over the raised default.
        std::env::set_var("JESSE_TIMEOUT", "600");
        assert_eq!(Config::from_env().timeout_secs, 600);
        match saved {
            Some(v) => std::env::set_var("JESSE_TIMEOUT", v),
            None => std::env::remove_var("JESSE_TIMEOUT"),
        }
    }
    #[test]
    fn partial_ring_caps_come_from_env() {
        let _guard = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = ["JESSE_PARTIAL_BLOCKS", "JESSE_PARTIAL_BYTES"]
            .iter()
            .map(|k| (*k, std::env::var(k).ok()))
            .collect();
        std::env::set_var("JESSE_PARTIAL_BLOCKS", "3");
        std::env::set_var("JESSE_PARTIAL_BYTES", "512");
        let cfg = Config::from_env();
        assert_eq!(cfg.partial_blocks, 3);
        assert_eq!(cfg.partial_bytes, 512);
        // Blocks are floored at 1 — a zero-block ring is not a posture, `bytes: 0` is.
        std::env::set_var("JESSE_PARTIAL_BLOCKS", "0");
        std::env::set_var("JESSE_PARTIAL_BYTES", "0");
        let cfg = Config::from_env();
        assert_eq!(cfg.partial_blocks, 1);
        assert_eq!(cfg.partial_bytes, 0);
        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }
    #[test]
    fn config_zero_timeout_clamps_to_ceiling() {
        let _guard = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_TIMEOUT").ok();
        std::env::set_var("JESSE_TIMEOUT", "0");
        let cfg = Config::from_env();
        assert_eq!(cfg.timeout_secs, HARD_TIMEOUT_CEILING);
        match saved {
            Some(v) => std::env::set_var("JESSE_TIMEOUT", v),
            None => std::env::remove_var("JESSE_TIMEOUT"),
        }
    }

    #[test]
    fn shadow_backend_resolves_only_when_all_three_present() {
        let full = resolve_shadow_backend(
            Some("https://gw.example".into()),
            Some("gw-tok".into()),
            Some("fw-glm".into()),
        );
        assert_eq!(
            full,
            Some((
                "https://gw.example".to_string(),
                "gw-tok".to_string(),
                "fw-glm".to_string(),
            ))
        );
        // Every partial combination (1 or 2 of 3 set) resolves to None — the kill
        // switch: unset any one var and not a single turn is mirrored.
        let s = || Some("x".to_string());
        let partials = [
            (s(), s(), None),
            (s(), None, s()),
            (None, s(), s()),
            (s(), None, None),
            (None, s(), None),
            (None, None, s()),
            (None, None, None),
        ];
        for (b, t, m) in partials {
            assert_eq!(
                resolve_shadow_backend(b, t, m),
                None,
                "partial shadow config must resolve to None (treated as unset)"
            );
        }
    }

    #[test]
    fn shadow_sample_pct_clamps_to_0_100() {
        assert_eq!(clamp_sample_pct(0), 0);
        assert_eq!(clamp_sample_pct(50), 50);
        assert_eq!(clamp_sample_pct(100), 100);
        // Over-range saturates to 100 rather than disabling sampling.
        assert_eq!(clamp_sample_pct(101), 100);
        assert_eq!(clamp_sample_pct(1_000_000), 100);
    }

    #[test]
    fn expand_tilde_expands_leading_home_only() {
        assert_eq!(expand_tilde("~", "/Users/j"), "/Users/j");
        assert_eq!(
            expand_tilde("~/Library/Logs/x.jsonl", "/Users/j"),
            "/Users/j/Library/Logs/x.jsonl"
        );
        // An already-absolute path is untouched, as is a `~user` form.
        assert_eq!(expand_tilde("/var/log/x", "/Users/j"), "/var/log/x");
        assert_eq!(expand_tilde("~bob/x", "/Users/j"), "~bob/x");
        // Empty HOME leaves the value verbatim (no bare-"/…" default).
        assert_eq!(expand_tilde("~/x", ""), "~/x");
    }

    #[test]
    fn config_from_env_shadow_all_or_nothing_and_knobs() {
        let _g = ENV_LOCK.lock_ok();
        let keys = [
            "JESSE_SHADOW_BASE_URL",
            "JESSE_SHADOW_AUTH_TOKEN",
            "JESSE_SHADOW_MODEL",
            "JESSE_SHADOW_SAMPLE_PCT",
            "JESSE_SHADOW_LOG",
            "JESSE_SHADOW_TIMEOUT_SECS",
        ];
        let saved: Vec<(&str, Option<String>)> =
            keys.iter().map(|k| (*k, std::env::var(k).ok())).collect();
        for k in &keys {
            std::env::remove_var(k);
        }

        // Unset by default → disarmed; knobs take their defaults.
        let cfg = Config::from_env();
        assert_eq!(cfg.shadow_backend, None);
        assert_eq!(cfg.shadow_sample_pct, 100);
        assert_eq!(cfg.shadow_timeout_secs, 120);
        assert!(
            cfg.shadow_log
                .ends_with("/Library/Logs/jesse-shadow/shadow.jsonl"),
            "default shadow log path expanded under HOME: {}",
            cfg.shadow_log
        );
        assert!(!cfg.shadow_log.starts_with('~'), "the ~ must be expanded");

        // All three set → armed triple; knobs honored + clamped.
        std::env::set_var("JESSE_SHADOW_BASE_URL", "https://gw.example");
        std::env::set_var("JESSE_SHADOW_AUTH_TOKEN", "gw-tok");
        std::env::set_var("JESSE_SHADOW_MODEL", "fw-glm");
        std::env::set_var("JESSE_SHADOW_SAMPLE_PCT", "250"); // clamps to 100
        std::env::set_var("JESSE_SHADOW_TIMEOUT_SECS", "45");
        std::env::set_var("JESSE_SHADOW_LOG", "/tmp/jesse-shadow-test/shadow.jsonl");
        let cfg = Config::from_env();
        assert_eq!(
            cfg.shadow_backend,
            Some((
                "https://gw.example".to_string(),
                "gw-tok".to_string(),
                "fw-glm".to_string(),
            ))
        );
        assert_eq!(cfg.shadow_sample_pct, 100);
        assert_eq!(cfg.shadow_timeout_secs, 45);
        assert_eq!(cfg.shadow_log, "/tmp/jesse-shadow-test/shadow.jsonl");

        // Drop one → partial → None (treated as unset); a blank counts as unset.
        std::env::remove_var("JESSE_SHADOW_MODEL");
        assert_eq!(Config::from_env().shadow_backend, None);
        std::env::set_var("JESSE_SHADOW_MODEL", "   ");
        assert_eq!(Config::from_env().shadow_backend, None);

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn session_ttl_days_defaults_to_90_and_honors_env() {
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_SESSION_TTL_DAYS").ok();
        std::env::remove_var("JESSE_SESSION_TTL_DAYS");
        assert_eq!(
            Config::from_env().session_ttl_days,
            DEFAULT_SESSION_TTL_DAYS
        );
        assert_eq!(DEFAULT_SESSION_TTL_DAYS, 90);
        std::env::set_var("JESSE_SESSION_TTL_DAYS", "30");
        assert_eq!(Config::from_env().session_ttl_days, 30);
        // Unparseable falls back to the default.
        std::env::set_var("JESSE_SESSION_TTL_DAYS", "nope");
        assert_eq!(
            Config::from_env().session_ttl_days,
            DEFAULT_SESSION_TTL_DAYS
        );
        match saved {
            Some(v) => std::env::set_var("JESSE_SESSION_TTL_DAYS", v),
            None => std::env::remove_var("JESSE_SESSION_TTL_DAYS"),
        }
    }

    #[test]
    fn max_queued_honors_env_including_explicit_zero() {
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_MAX_QUEUED").ok();
        // Explicit 0 is honored (floor 0 → no queue), not folded to the default.
        std::env::set_var("JESSE_MAX_QUEUED", "0");
        assert_eq!(Config::from_env().max_queued, 0);
        std::env::set_var("JESSE_MAX_QUEUED", "9");
        assert_eq!(Config::from_env().max_queued, 9);
        // Unparseable falls back to the default.
        std::env::set_var("JESSE_MAX_QUEUED", "nope");
        assert_eq!(Config::from_env().max_queued, DEFAULT_MAX_QUEUED);
        match saved {
            Some(v) => std::env::set_var("JESSE_MAX_QUEUED", v),
            None => std::env::remove_var("JESSE_MAX_QUEUED"),
        }
    }

    #[test]
    fn scratch_base_defaults_to_temp_and_honors_override() {
        let mut cfg = test_config();
        cfg.scratch_dir = None;
        assert_eq!(cfg.scratch_base(), std::env::temp_dir());
        cfg.scratch_dir = Some("/var/jesse-scratch".to_string());
        assert_eq!(cfg.scratch_base(), PathBuf::from("/var/jesse-scratch"));
    }

    #[test]
    fn vaultqa_timeout_raised_to_cover_the_measured_oss_lookup_range() {
        // Piece 2: 25 → 60. The vaultqa-v1 bake-off measured oss lookups at 10–42 s
        // wall; a 25 s ceiling would have starved most real lookups (rung-2 timeouts).
        // 60 s clears the measured 42 s max with headroom. Emergency's best-effort rung
        // gets a looser 120 s (no ladder below it).
        assert_eq!(VAULTQA_TIMEOUT_SECS, 60);
        // Must clear the measured 42 s oss lookup max (a `let` binding keeps clippy from
        // folding the const comparison to a trivially-true assert).
        let measured_oss_max_secs = 42u64;
        assert!(
            VAULTQA_TIMEOUT_SECS >= measured_oss_max_secs,
            "must clear the measured oss max"
        );
        assert_eq!(EMERGENCY_TIMEOUT_SECS, 120);
    }

    #[test]
    fn metrics_log_resolves_from_env_and_is_none_when_unset() {
        // Piece 3: JESSE_METRICS_LOG = an absolute file path; unset → None (dormant,
        // zero metrics writes), same soft-failure semantics as the other envs. A blank
        // value counts as unset via the shared `env_string` rule.
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_METRICS_LOG").ok();
        std::env::remove_var("JESSE_METRICS_LOG");
        assert_eq!(Config::from_env().metrics_log, None);
        std::env::set_var("JESSE_METRICS_LOG", "/var/log/jesse/metrics.jsonl");
        assert_eq!(
            Config::from_env().metrics_log.as_deref(),
            Some("/var/log/jesse/metrics.jsonl")
        );
        std::env::set_var("JESSE_METRICS_LOG", "   ");
        assert_eq!(
            Config::from_env().metrics_log,
            None,
            "blank counts as unset"
        );
        match saved {
            Some(v) => std::env::set_var("JESSE_METRICS_LOG", v),
            None => std::env::remove_var("JESSE_METRICS_LOG"),
        }
    }

    #[test]
    fn emergency_local_defaults_off_and_only_on_enables() {
        // Piece 4: JESSE_EMERGENCY_LOCAL = on|off, default OFF. Unlike the badge/
        // probation truthiness rule (default on), this defaults OFF — only an explicit
        // truthy value enables it, so a half-configured deploy stays inert.
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_EMERGENCY_LOCAL").ok();
        std::env::remove_var("JESSE_EMERGENCY_LOCAL");
        assert!(!Config::from_env().emergency_local, "default off");
        for truthy in ["on", "1", "true", "yes", "ON", " On "] {
            std::env::set_var("JESSE_EMERGENCY_LOCAL", truthy);
            assert!(
                Config::from_env().emergency_local,
                "explicit {truthy:?} enables"
            );
        }
        for falsey in ["off", "0", "false", "no", "", "  ", "garbage"] {
            std::env::set_var("JESSE_EMERGENCY_LOCAL", falsey);
            assert!(
                !Config::from_env().emergency_local,
                "{falsey:?} leaves emergency off"
            );
        }
        match saved {
            Some(v) => std::env::set_var("JESSE_EMERGENCY_LOCAL", v),
            None => std::env::remove_var("JESSE_EMERGENCY_LOCAL"),
        }
    }

    #[test]
    fn context_carry_defaults_on_and_only_explicit_falsey_disables() {
        // Context carry fixes a live defect, so it defaults ON (the badge/probation
        // truthiness rule): only an explicit off/0/false/no flips it off — the
        // rollback switch. Unset or any other value keeps it on.
        let _g = ENV_LOCK.lock_ok();
        let saved = std::env::var("JESSE_CONTEXT_CARRY").ok();
        std::env::remove_var("JESSE_CONTEXT_CARRY");
        assert!(Config::from_env().context_carry, "default on");
        for falsey in ["0", "false", "no", "off", "OFF", " Off "] {
            std::env::set_var("JESSE_CONTEXT_CARRY", falsey);
            assert!(
                !Config::from_env().context_carry,
                "explicit {falsey:?} disables (rollback)"
            );
        }
        for truthy in ["1", "true", "yes", "on", "anything-else"] {
            std::env::set_var("JESSE_CONTEXT_CARRY", truthy);
            assert!(
                Config::from_env().context_carry,
                "{truthy:?} keeps carry on"
            );
        }
        // The persistence path is a sibling of titles.json, and None with no state dir.
        let mut cfg = Config::from_env();
        cfg.state_dir = Some("/var/jesse".to_string());
        assert_eq!(
            cfg.context_file(),
            Some(PathBuf::from("/var/jesse/context.json"))
        );
        cfg.state_dir = None;
        assert_eq!(cfg.context_file(), None);
        match saved {
            Some(v) => std::env::set_var("JESSE_CONTEXT_CARRY", v),
            None => std::env::remove_var("JESSE_CONTEXT_CARRY"),
        }
    }

    // ---- Declarative `[[models]]` config + the three-source merge (Part B) -------

    /// A minimal declarative model entry with the four required fields; `token_env` names the
    /// (optional) auth-token env var. Every other field defaults.
    fn model_toml(id: &str, kind: &str, token_env: Option<&str>) -> ModelToml {
        ModelToml {
            id: Some(id.into()),
            kind: Some(kind.into()),
            base_url: Some("https://gw.example/inference".into()),
            model: Some("provider/model".into()),
            auth_token_env: token_env.map(str::to_string),
            ..Default::default()
        }
    }

    /// The nine `JESSE_MODEL_*` env-triple vars, cleared so a test's registry is deterministic.
    const MODEL_ENV_VARS: [&str; 12] = [
        "JESSE_MODEL_GLM_BASE_URL",
        "JESSE_MODEL_GLM_AUTH_TOKEN",
        "JESSE_MODEL_GLM_MODEL",
        "JESSE_MODEL_KIMI_BASE_URL",
        "JESSE_MODEL_KIMI_AUTH_TOKEN",
        "JESSE_MODEL_KIMI_MODEL",
        // The Codex-surface sibling FALLS BACK to the shared Kimi token, so a test that
        // clears the env to reach the unconfigured baseline must clear these too.
        "JESSE_MODEL_KIMI_CODEX_BASE_URL",
        "JESSE_MODEL_KIMI_CODEX_AUTH_TOKEN",
        "JESSE_MODEL_KIMI_CODEX_MODEL",
        "JESSE_MODEL_LOCAL_BASE_URL",
        "JESSE_MODEL_LOCAL_AUTH_TOKEN",
        "JESSE_MODEL_LOCAL_MODEL",
    ];

    #[test]
    fn declarative_model_arms_only_when_its_token_env_is_set() {
        // auth_token_env is the NAME of a var; the token is resolved from the process env at
        // build time. A set var arms the model (configured, backend resolved, subagent model
        // defaulting to the main model). An unset var (or none at all) yields a
        // configured-but-unarmed entry — present in the list, not selectable.
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_TEST_DECL_TOKEN", "sk-abc");
        let armed = registry_model_from_toml(
            &model_toml("fireworks", "hosted", Some("JESSE_TEST_DECL_TOKEN")),
            None,
            None,
        )
        .expect("a full entry parses");
        assert!(armed.configured, "a set token env arms the model");
        assert_eq!(
            armed.backend,
            Some((
                "https://gw.example/inference".into(),
                "sk-abc".into(),
                "provider/model".into()
            ))
        );
        assert_eq!(armed.subagent_model.as_deref(), Some("provider/model"));
        assert!(matches!(armed.kind, ModelKind::Hosted));
        assert_eq!(
            armed.level, DEFAULT_MODEL_LEVEL,
            "non-ambient defaults to Read"
        );

        std::env::remove_var("JESSE_TEST_DECL_TOKEN");
        let unarmed = registry_model_from_toml(
            &model_toml("fireworks", "hosted", Some("JESSE_TEST_DECL_TOKEN")),
            None,
            None,
        )
        .expect("still parses, just unarmed");
        assert!(!unarmed.configured, "an unset token env → unarmed");
        assert!(unarmed.backend.is_none(), "no backend without a token");
        assert!(
            unarmed.subagent_model.is_none(),
            "no backend-derived subagent model"
        );

        let no_env =
            registry_model_from_toml(&model_toml("fireworks", "hosted", None), None, None).unwrap();
        assert!(!no_env.configured, "no auth_token_env at all → unarmed");
    }

    #[test]
    fn parse_vision_partners_reads_the_env_form() {
        // id[:role] items, comma-separated; missing role defaults to Any; blanks skipped.
        let ps = parse_vision_partners("paddleocr:doc, qwen3-vl:general ,, solo");
        assert_eq!(ps.len(), 3);
        assert_eq!(ps[0].id, "paddleocr");
        assert_eq!(ps[0].role, VisionRole::Doc);
        assert_eq!(ps[1].id, "qwen3-vl");
        assert_eq!(ps[1].role, VisionRole::General);
        assert_eq!(ps[2].id, "solo");
        assert_eq!(ps[2].role, VisionRole::Any, "no role → any");
        // An empty/blank spec is no partners (vision off).
        assert!(parse_vision_partners("").is_empty());
        assert!(parse_vision_partners("  , ").is_empty());
        // An unknown role token widens to Any rather than dropping.
        assert_eq!(parse_vision_partners("x:bogus")[0].role, VisionRole::Any);
    }

    #[test]
    fn declarative_model_parses_vision_pairing() {
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_TEST_VIS_TOKEN", "tok");
        let t = ModelToml {
            harness: None,
            default_writes: None,
            id: Some("glm".into()),
            kind: Some("hosted".into()),
            base_url: Some("http://b".into()),
            model: Some("m".into()),
            auth_token_env: Some("JESSE_TEST_VIS_TOKEN".into()),
            vision: Some(vec![
                VisionPartnerToml {
                    id: Some("paddle".into()),
                    role: Some("doc".into()),
                },
                VisionPartnerToml {
                    id: Some("qwen".into()),
                    role: None,
                },
                VisionPartnerToml {
                    id: Some("  ".into()),
                    role: Some("general".into()),
                },
            ]),
            vision_complementary: Some(true),
            ..Default::default()
        };
        let m = registry_model_from_toml(&t, None, None).unwrap();
        assert_eq!(m.vision.len(), 2, "the blank-id partner is skipped");
        assert_eq!(m.vision[0].id, "paddle");
        assert_eq!(m.vision[0].role, VisionRole::Doc);
        assert_eq!(m.vision[1].role, VisionRole::Any, "missing role → any");
        assert!(m.vision_complementary);
        std::env::remove_var("JESSE_TEST_VIS_TOKEN");
    }

    #[test]
    fn vision_enabled_requires_a_configured_partner() {
        // A text model paired to an unconfigured helper reports no vision; configuring the
        // helper flips it on.
        let helper_unarmed = RegistryModel {
            id: "vl".into(),
            label: "VL".into(),
            kind: ModelKind::Hosted,
            backend: None,
            subagent_model: None,
            configured: false,
            level: Capability::Read,
            harness: CLAUDE_CODE_ID.to_string(),
            price: PriceDeck::ZERO,
            health: HealthConfig::default(),
            vision: Vec::new(),
            vision_complementary: false,
        };
        let text = RegistryModel {
            id: "glm".into(),
            label: "GLM".into(),
            kind: ModelKind::Hosted,
            backend: Some(("http://b".into(), "t".into(), "m".into())),
            subagent_model: Some("m".into()),
            configured: true,
            level: Capability::Read,
            harness: CLAUDE_CODE_ID.to_string(),
            price: PriceDeck::ZERO,
            health: HealthConfig::default(),
            vision: vec![VisionPartner {
                id: "vl".into(),
                role: VisionRole::Any,
            }],
            vision_complementary: false,
        };
        let reg = ModelRegistry {
            models: vec![helper_unarmed.clone(), text.clone()],
        };
        assert!(
            !reg.vision_enabled(reg.get("glm").unwrap()),
            "partner unconfigured → no vision"
        );
        let helper_armed = RegistryModel {
            backend: Some(("http://b".into(), "t".into(), "m".into())),
            configured: true,
            ..helper_unarmed
        };
        let reg2 = ModelRegistry {
            models: vec![helper_armed, text],
        };
        assert!(
            reg2.vision_enabled(reg2.get("glm").unwrap()),
            "partner configured → vision on"
        );
        assert!(reg2.vision_partner("vl").is_some());
    }

    #[test]
    fn declarative_model_parses_price_subagent_and_health_overrides() {
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_TEST_DECL_TOKEN2", "tok");
        let t = ModelToml {
            harness: None,
            default_writes: None,
            id: Some("codex".into()),
            label: Some("Codex".into()),
            kind: Some("local".into()),
            base_url: Some("http://127.0.0.1:8900".into()),
            model: Some("gpt-5-codex".into()),
            subagent_model: Some("gpt-5-mini".into()),
            auth_token_env: Some("JESSE_TEST_DECL_TOKEN2".into()),
            level: Some("write".to_string()),
            price: Some(PriceToml {
                in_per_m: Some(2.0),
                cached_per_m: Some(0.2),
                out_per_m: Some(8.0),
            }),
            health: Some(HealthToml {
                path: Some("/v1/messages".into()),
                interval_secs: Some(30),
                timeout_secs: Some(2),
            }),
            vision: None,
            vision_complementary: None,
        };
        let m = registry_model_from_toml(&t, None, None).unwrap();
        assert!(matches!(m.kind, ModelKind::Local));
        assert_eq!(m.label, "Codex");
        assert_eq!(
            m.subagent_model.as_deref(),
            Some("gpt-5-mini"),
            "explicit subagent override"
        );
        assert_eq!(m.level, Capability::Write, "declarative level honored");
        assert_eq!(m.price.out_per_m, 8.0);
        assert_eq!(m.health.interval_secs, 30);
        assert_eq!(m.health.timeout_secs, 2);
        std::env::remove_var("JESSE_TEST_DECL_TOKEN2");
    }

    /// AN OPENAI-KIND ENTRY NEEDS NO `health` BLOCK TO BE PROBEABLE.
    ///
    /// The default probe path follows the KIND, because the default is a statement about
    /// which API the `base_url` serves and that is exactly what the kind names. Without this,
    /// an operator who declares an OpenAI-surface model and omits the health block gets
    /// `/v1/messages` posted at an OpenAI root, a 404, `unknown-model`, and a model that is
    /// configured, armed, correct — and permanently unselectable for a reason nothing in
    /// their config file mentions.
    #[test]
    fn an_openai_kind_model_defaults_its_probe_to_the_openai_path() {
        let _g = ENV_LOCK.lock_ok();
        std::env::set_var("JESSE_TEST_OPENAI_TOKEN", "tok");
        let mut t = model_toml("kimi-k3-codex", "openai", Some("JESSE_TEST_OPENAI_TOKEN"));
        t.harness = Some("codex".into());

        let m = registry_model_from_toml(&t, None, None).expect("openai is a valid kind");
        assert!(matches!(m.kind, ModelKind::OpenAi));
        assert_eq!(m.harness, "codex");
        assert_eq!(m.health.path, "/chat/completions");

        // An explicit path still wins — the kind supplies a DEFAULT, not a policy.
        t.health = Some(HealthToml {
            path: Some("/responses".into()),
            interval_secs: None,
            timeout_secs: None,
        });
        let explicit = registry_model_from_toml(&t, None, None).expect("a model");
        assert_eq!(explicit.health.path, "/responses");

        // And an Anthropic-surface kind is untouched by any of it.
        let hosted = registry_model_from_toml(
            &model_toml("h", "hosted", Some("JESSE_TEST_OPENAI_TOKEN")),
            None,
            None,
        )
        .expect("a model");
        assert_eq!(hosted.health.path, "/v1/messages");
        std::env::remove_var("JESSE_TEST_OPENAI_TOKEN");
    }

    #[test]
    fn declarative_model_rejects_missing_fields_and_reserved_kind() {
        // A missing required field → the entry is skipped (None), never a partial model.
        let mut missing_model = model_toml("x", "hosted", Some("V"));
        missing_model.model = None;
        assert!(registry_model_from_toml(&missing_model, None, None).is_none());
        // `ambient` is reserved for the built-in opus; an unknown kind is invalid too.
        assert!(
            registry_model_from_toml(&model_toml("x", "ambient", Some("V")), None, None).is_none()
        );
        assert!(
            registry_model_from_toml(&model_toml("x", "banana", Some("V")), None, None).is_none()
        );
    }

    #[test]
    fn upsert_replaces_by_id_in_place_and_protects_the_ambient_default() {
        // The merge primitive: later overrides earlier BY ID (in place, stable order), a new
        // id appends, and the ambient `opus` is never replaceable.
        let mut models = vec![
            opus_entry(),
            glm_env_entry(DEFAULT_HEALTH_INTERVAL_SECS, None),
        ]; // glm unconfigured (no env)
        let mut decl_glm = model_toml("glm-5.2", "hosted", None);
        decl_glm.label = Some("Declared GLM".into());
        upsert_model(
            &mut models,
            registry_model_from_toml(&decl_glm, None, None).unwrap(),
        );
        assert_eq!(models.len(), 2, "same id replaces in place, not appends");
        assert_eq!(models[1].id, "glm-5.2");
        assert_eq!(models[1].label, "Declared GLM", "later source wins by id");

        upsert_model(
            &mut models,
            registry_model_from_toml(&model_toml("fw", "hosted", None), None, None).unwrap(),
        );
        assert_eq!(models.len(), 3, "a new id appends");

        // An entry that tries to redefine opus is refused; opus stays the built-in ambient.
        let fake_opus =
            registry_model_from_toml(&model_toml("opus", "hosted", None), None, None).unwrap();
        upsert_model(&mut models, fake_opus);
        assert_eq!(models.iter().filter(|m| m.id == "opus").count(), 1);
        assert!(
            matches!(models[0].kind, ModelKind::Ambient),
            "opus stays ambient"
        );
    }

    #[test]
    fn from_env_with_no_model_config_is_todays_behavior_opus_only_selectable() {
        // With no JESSE_MODEL_* and no [[models]], the ONLY selectable (configured) model is
        // opus — byte-for-byte today: opus present + configured, and the preserved env-triple
        // placeholders (glm/kimi/local) present but UNCONFIGURED (not selectable). No
        // declarative entry appears.
        let _g = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = MODEL_ENV_VARS
            .iter()
            .chain(["JESSE_CONFIG", "JESSE_STATE_DIR"].iter())
            .map(|k| (*k, std::env::var(k).ok()))
            .collect();
        for k in MODEL_ENV_VARS {
            std::env::remove_var(k);
        }
        std::env::remove_var("JESSE_STATE_DIR");
        std::env::set_var("JESSE_CONFIG", "/nonexistent/jesse.local.toml");

        let r = ModelRegistry::from_env("");
        assert_eq!(r.models[0].id, "opus");
        assert!(matches!(r.models[0].kind, ModelKind::Ambient));
        assert!(r.is_configured("opus"), "opus is the only configured model");
        for id in ["glm-5.2", "kimi-k3", "kimi-k3-codex", "local"] {
            let m = r
                .get(id)
                .unwrap_or_else(|| panic!("{id} preserved as a placeholder"));
            assert!(
                !m.configured,
                "{id} is present but not configured with no env"
            );
        }
        assert_eq!(
            r.models.len(),
            5,
            "no declarative entries appear with no config"
        );

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn both_kimi_entries_are_registered_and_are_not_the_same_model_twice() {
        // The operator ruling this implements: route each model to the surface whose native
        // contract it speaks, and make BOTH first-class rather than picking a global default.
        // So the registry must carry two Kimi entries that a person can tell apart and that
        // the machinery treats as genuinely different postures.
        let _g = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = MODEL_ENV_VARS
            .iter()
            .chain(["JESSE_CONFIG", "JESSE_STATE_DIR"].iter())
            .map(|k| (*k, std::env::var(k).ok()))
            .collect();
        for k in MODEL_ENV_VARS {
            std::env::remove_var(k);
        }
        std::env::remove_var("JESSE_STATE_DIR");
        std::env::set_var("JESSE_CONFIG", "/nonexistent/jesse.local.toml");
        // ONE secret arms BOTH: the Codex entry falls back to the shared Fireworks key.
        std::env::set_var("JESSE_MODEL_KIMI_AUTH_TOKEN", "fw-test");

        let r = ModelRegistry::from_env("");
        let anthropic = r.get("kimi-k3").expect("the Anthropic-surface entry");
        let codex = r.get("kimi-k3-codex").expect("the Codex-surface entry");

        assert!(
            anthropic.configured && codex.configured,
            "one key arms both"
        );

        // Different SURFACE — the whole point of the step.
        assert!(matches!(anthropic.kind, ModelKind::Hosted));
        assert!(matches!(codex.kind, ModelKind::OpenAi));
        assert_eq!(anthropic.harness, CLAUDE_CODE_ID);
        assert_eq!(codex.harness, CODEX_ID);

        // Different CONTAINMENT RECORD follows from the harness, which is why these are not
        // one model listed twice: `containment.toml` governs one and `containment-codex.toml`
        // the other.
        assert_ne!(anthropic.harness, codex.harness);

        // Labels a person can distinguish in the picker.
        assert_ne!(anthropic.label, codex.label);
        assert!(anthropic.label.contains("Anthropic"), "{}", anthropic.label);
        assert!(codex.label.contains("Codex"), "{}", codex.label);

        // The base_url differs by the `/v1` suffix, and that is load-bearing rather than
        // cosmetic: one is a host Claude Code appends `/v1/messages` to, the other an API
        // ROOT the codex harness appends `/responses` to. Swapping them yields a model that
        // is armed, correct-looking and permanently broken.
        let base = |m: &RegistryModel| m.backend.as_ref().unwrap().0.clone();
        assert_eq!(base(anthropic), "https://api.fireworks.ai/inference");
        assert_eq!(base(codex), "https://api.fireworks.ai/inference/v1");

        // …and the health probe follows the kind, not the sibling.
        assert_eq!(anthropic.health.path, "/v1/messages");
        assert_eq!(codex.health.path, "/chat/completions");
        // Both are reasoning models: the 3 s default would keep them out of the picker.
        assert_eq!(codex.health.timeout_secs, REASONING_HEALTH_TIMEOUT_SECS);

        // Same weights on the same provider → the same deck; a reprice moves both.
        assert_eq!(anthropic.price.in_per_m, codex.price.in_per_m);

        // GLM is untouched by any of this.
        let glm = r.get("glm-5.2").expect("glm still registered");
        assert_eq!(glm.harness, CLAUDE_CODE_ID);
        assert!(matches!(glm.kind, ModelKind::Hosted));

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn the_codex_kimi_entry_can_take_its_own_key_when_a_deploy_wants_them_separate() {
        let _g = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = MODEL_ENV_VARS
            .iter()
            .map(|k| (*k, std::env::var(k).ok()))
            .collect();
        for k in MODEL_ENV_VARS {
            std::env::remove_var(k);
        }
        // Its OWN var set and the shared one NOT: the entry arms, its sibling does not.
        std::env::set_var("JESSE_MODEL_KIMI_CODEX_AUTH_TOKEN", "fw-codex-only");
        let codex = kimi_codex_env_entry(DEFAULT_HEALTH_INTERVAL_SECS, None);
        let anthropic = kimi_env_entry(DEFAULT_HEALTH_INTERVAL_SECS, None);
        assert!(codex.configured, "its own key arms it");
        assert!(!anthropic.configured, "and does not arm the sibling");

        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn kimi_probe_budget_is_wider_than_glms_and_yields_to_the_global_override() {
        // K3 thinks before it answers, so its probe budget must exceed the 3 s default that
        // GLM is fine with — otherwise a reachable K3 probes as unhealthy and never appears
        // in the picker. `JESSE_HEALTH_TIMEOUT_SECS` overrides both.
        assert_eq!(
            kimi_env_entry(DEFAULT_HEALTH_INTERVAL_SECS, None)
                .health
                .timeout_secs,
            REASONING_HEALTH_TIMEOUT_SECS
        );
        assert_eq!(
            glm_env_entry(DEFAULT_HEALTH_INTERVAL_SECS, None)
                .health
                .timeout_secs,
            DEFAULT_HEALTH_TIMEOUT_SECS
        );
        // (That REASONING_HEALTH_TIMEOUT_SECS exceeds the default is an invariant of the two
        // constants, not of this wiring — it is asserted at compile time where they are
        // defined, in health.rs.)
        for entry in [
            kimi_env_entry(DEFAULT_HEALTH_INTERVAL_SECS, Some(25)),
            glm_env_entry(DEFAULT_HEALTH_INTERVAL_SECS, Some(25)),
            local_env_entry(DEFAULT_HEALTH_INTERVAL_SECS, Some(25)),
        ] {
            assert_eq!(
                entry.health.timeout_secs, 25,
                "{} honors the override",
                entry.id
            );
        }
    }

    #[test]
    fn global_health_interval_override_applies_unless_a_model_sets_its_own() {
        // `JESSE_HEALTH_INTERVAL_SECS` lengthens the DEFAULT probe interval: env-triple models
        // (no explicit interval) and a declarative model with no `health.interval_secs` pick it
        // up, while a declarative model that sets its own interval still wins.
        let _g = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = MODEL_ENV_VARS
            .iter()
            .chain(
                [
                    "JESSE_CONFIG",
                    "JESSE_STATE_DIR",
                    "JESSE_HEALTH_INTERVAL_SECS",
                ]
                .iter(),
            )
            .map(|k| (*k, std::env::var(k).ok()))
            .collect();
        for k in MODEL_ENV_VARS {
            std::env::remove_var(k);
        }
        std::env::remove_var("JESSE_STATE_DIR");
        std::env::set_var("JESSE_HEALTH_INTERVAL_SECS", "600");
        std::env::set_var("JESSE_TEST_HI_TOKEN", "sk-fw");

        let dir = std::env::temp_dir().join(format!("jesse-hi-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            r#"
[[models]]
id = "fireworks"
kind = "hosted"
base_url = "https://gw.example/inference"
model = "m"
auth_token_env = "JESSE_TEST_HI_TOKEN"
health = { interval_secs = 30 }

[[models]]
id = "codex"
kind = "hosted"
base_url = "http://127.0.0.1:8900"
model = "m"
auth_token_env = "JESSE_TEST_HI_TOKEN"
"#,
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let r = ModelRegistry::from_env("");
        // Env-triple models carry no explicit interval → they pick up the global override.
        for id in ["glm-5.2", "kimi-k3", "kimi-k3-codex", "local"] {
            assert_eq!(
                r.get(id).unwrap().health.interval_secs,
                600,
                "{id} (no explicit interval) uses the global override"
            );
        }
        // A declarative model with no health.interval_secs also uses the global override.
        assert_eq!(r.get("codex").unwrap().health.interval_secs, 600);
        // A declarative model that sets its own interval still wins over the global override.
        assert_eq!(r.get("fireworks").unwrap().health.interval_secs, 30);

        std::fs::remove_dir_all(&dir).ok();
        std::env::remove_var("JESSE_TEST_HI_TOKEN");
        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }

    #[test]
    fn from_env_merges_a_declarative_models_file_and_overrides_env_by_id() {
        // Source 3: a [[models]] file. An armed declarative entry becomes configured; an
        // unarmed one (missing token var) is present-but-unconfigured; and a declarative entry
        // with an env-triple's id OVERRIDES it (later source wins).
        let _g = ENV_LOCK.lock_ok();
        let saved: Vec<(&str, Option<String>)> = MODEL_ENV_VARS
            .iter()
            .chain(["JESSE_CONFIG", "JESSE_STATE_DIR"].iter())
            .map(|k| (*k, std::env::var(k).ok()))
            .collect();
        for k in MODEL_ENV_VARS {
            std::env::remove_var(k);
        }
        std::env::remove_var("JESSE_STATE_DIR");
        // Arm the env glm so we can prove the declarative override REPLACES it.
        std::env::set_var("JESSE_MODEL_GLM_AUTH_TOKEN", "env-glm-tok");
        std::env::set_var("JESSE_TEST_FW_TOKEN", "sk-fw");

        let dir = std::env::temp_dir().join(format!("jesse-decl-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("jesse.local.toml");
        std::fs::write(
            &file,
            r#"
[[models]]
id = "fireworks"
label = "Fireworks GLM"
kind = "hosted"
base_url = "https://gw.example/inference"
model = "accounts/fireworks/models/glm"
auth_token_env = "JESSE_TEST_FW_TOKEN"
price = { in_per_m = 1.4, cached_per_m = 0.14, out_per_m = 4.4 }
health = { interval_secs = 30, timeout_secs = 2 }

[[models]]
id = "codex"
kind = "hosted"
base_url = "http://127.0.0.1:8900"
model = "gpt-5-codex"
auth_token_env = "JESSE_TEST_MISSING_TOKEN"

[[models]]
id = "glm-5.2"
label = "Override GLM"
kind = "hosted"
base_url = "http://override"
model = "override-model"
auth_token_env = "JESSE_TEST_FW_TOKEN"
"#,
        )
        .unwrap();
        std::env::set_var("JESSE_CONFIG", &file);

        let r = ModelRegistry::from_env("");
        assert_eq!(r.models[0].id, "opus", "opus stays first");

        // Armed declarative model → configured, price + health parsed, token held only in backend.
        let fw = r.get("fireworks").expect("fireworks appears");
        assert!(fw.configured);
        assert_eq!(fw.backend.as_ref().unwrap().1, "sk-fw");
        assert_eq!(fw.price.out_per_m, 4.4);
        assert_eq!(fw.health.interval_secs, 30);
        assert_eq!(fw.health.timeout_secs, 2);

        // Unarmed declarative model (missing token var) → present but not configured.
        let codex = r.get("codex").expect("codex appears");
        assert!(!codex.configured);
        assert!(codex.backend.is_none());

        // Declarative glm-5.2 OVERRODE the env glm (later source wins), exactly one entry.
        let glm = r.get("glm-5.2").unwrap();
        assert_eq!(glm.label, "Override GLM");
        assert_eq!(glm.backend.as_ref().unwrap().0, "http://override");
        assert_eq!(r.models.iter().filter(|m| m.id == "glm-5.2").count(), 1);

        std::env::remove_var("JESSE_TEST_FW_TOKEN");
        let _ = std::fs::remove_dir_all(&dir);
        for (k, v) in saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
    }
}
