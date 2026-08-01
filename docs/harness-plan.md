# Second CLI harness — working draft

**Status:** draft, Phase 0 in progress
**Started:** 2026-07-27
**Goal:** run Jesse main turns on a second agent harness (Codex CLI) alongside Claude Code,
so neither the provider nor the harness is a single point of failure.

This is a working document. Open questions are marked **[OPEN]**; answered ones move to the
Decision log at the bottom with the evidence that settled them.

---

## Motivation

The bridge is **not** locked to Anthropic-the-provider — GLM 5.2 and Kimi K3 both run in
production today on Fireworks with Anthropic nowhere in the inference path. The Anthropic
Messages API acts here as an interchange format that third parties implement.

The real coupling is to **Claude Code the harness**:

- CLI surface: `--strict-mcp-config`, `--tools`, `--mcp-config`, `--permission-mode`,
  `--resume`, `--output-format stream-json`, `--include-partial-messages`
- Transcript adoption reads `~/.claude/projects/*.jsonl` (`config.rs`, `sessions.rs`, `state.rs`)
- Conversation identity is `Uuid::new_v5(JESSE_CONVERSATION_NS, session_id)`
  (`conversations.rs:85`) — i.e. **defined in terms of Claude Code session ids**

An adapter/translation layer would buy provider independence but **not** harness
independence. This plan buys harness independence, and accepts its cost: two
implementations of the main turn, permanently.

### Explicitly considered and rejected (for now)

| Option | Why not |
|---|---|
| Anthropic↔OpenAI adapter in the bridge | Buys provider independence we mostly have; doesn't address harness lock-in |
| Third-party translating proxy (LiteLLM et al.) | Same limitation, plus an external dependency and another daemon |
| Own agent loop in the bridge | Total independence, but we'd own tool execution, MCP, permissions, transcripts forever |

---

## Scope: main turn only

Five roles spawn a CLI. Four of them do **not** need a second harness:

| Role | Backend today | Needs Codex? |
|---|---|---|
| **Main turn** | hosted model (opus / glm-5.2 / kimi-k3) | **yes** |
| Title | `JESSE_TITLE_BASE_URL` → ds4 `127.0.0.1:9100` | no |
| Diet extract/verify | `JESSE_DIET_BASE_URL` → ds4 | no |
| VaultQA | `JESSE_VAULTQA_BASE_URL` → ds4 | no |
| Shadow | mirrors the main turn | later, optional |

Keeping Codex off the four local-model roles preserves the diet/vaultqa containment work
already validated, and cuts the job by roughly two-thirds.

**Non-goals for this effort:**

- Codex transcript adoption (no `~/.codex` equivalent of the `~/.claude/projects` reader)
- Codex on title/diet/vaultqa
- Changing `default_writes: false` for any non-ambient model

---

## Phase 0 — Spike (timeboxed 1 day) — **GATE**

No design work until these are answered with evidence. Codex is not installed on this
machine, so this is genuinely first.

| # | Question | Why it gates | Status |
|---|---|---|---|
| Q1 | Stream contract: incremental text deltas **and** tool-call boundaries? | `sse.rs` and the live-stream path depend on both | **PARTIAL** |
| Q2 | Stable session id + resume-by-id? | Decides whether `conversations.rs:85` generalizes | **PASS** |
| Q3 | Tool containment — the `--tools ""` + `--strict-mcp-config` equivalent | Security-relevant; **assume nothing carries over** | **DIFFERENT MODEL** |
| Q4 | MCP: can it load qmd, in what config format? | Read-only turns are tool-driven; no qmd = no product | **MIXED** |
| Q5 | How `default_writes: false` maps to its sandbox/approval model | Hard constraint | **PASS (mechanically)** |

### Phase 0 findings — 2026-07-28, codex-cli 0.145.0

Run against Fireworks (`wire_api = "responses"`, GLM 5.2) using the existing Fireworks
token — no OpenAI credential exists on this machine.

**Q1 — PARTIAL, needs a decision.** `codex exec --json` emits JSONL:
`thread.started` → `turn.started` → (`item.started`/`item.completed`)* → `turn.completed`.
Tool-call **boundaries are available** (`item.started`/`item.completed` carrying
`command_execution` and `mcp_tool_call`). Incremental **text deltas are not** — an
`agent_message` arrives whole on `item.completed`. There is no `--include-partial-messages`
equivalent and no stable feature flag (`codex features list` shows only
`apply_patch_streaming_events`, under development).
*Impact:* a Codex turn loses token-by-token streaming on the phone. The SSE path can emit
coarse progress (tool started/finished) plus a final message, but not live text.

**Q2 — PASS.** `thread.started` carries `thread_id`, a UUID (v7, e.g.
`019fa6f6-ebde-7bb3-884e-321650bce3c7`), and `codex exec resume <SESSION_ID>` accepts a UUID
or thread name. `Uuid::new_v5(NS, session_id)` at `conversations.rs:85` generalizes unchanged
— it hashes any string. No second identity path needed.

**Q3 — DIFFERENT SECURITY MODEL. The most important finding.**
Codex is **shell-first, not named-tool-first**. To read a file it ran
`/bin/zsh -lc 'cat todo-list/Dashboard.md'`. There is **no named-tool allowlist** equivalent
to Jesse's `--tools mcp__qmd__query,mcp__qmd__get,…`. Containment is
`--sandbox {read-only|workspace-write|danger-full-access}` plus execpolicy `.rules` files.

So `default_writes: false` maps to `--sandbox read-only`, but the *guarantee changes shape*:

| | Claude Code (today) | Codex |
|---|---|---|
| Model may invoke | only the named allowlist | **any shell command** |
| Writes prevented by | tool allowlist + permission mode | OS sandbox only |

This is not a fail, but it is a materially different posture and it is the thing most
deserving of an explicit decision. It must get the same probe-battery treatment the diet
child got — assume nothing.

**Q4 — MIXED.** The qmd MCP server loaded and was reachable (`mcp_tool_call` with
`server: "qmd"`). But the model **never invoked qmd's search tools** — it shelled out to the
`qmd` CLI instead, which hit the known node-version/better-sqlite3 `dlopen` failure because
the sandbox shell's PATH resolved a different node. Unresolved: whether qmd's tools were
surfaced to the model at all, or merely not preferred. Needs one focused follow-up.

**Q5 — PASS mechanically.** `--sandbox read-only` exists and ran clean. Its *sufficiency* is
Q3's question, not this one.

**Incidental findings**

- **Codex dropped `wire_api = "chat"` in 0.145.0**; only `responses` is supported. That
  narrows compatible providers considerably — Fireworks happens to serve `/v1/responses`
  (verified HTTP 200), so the non-Anthropic path is real, but this is a live constraint on
  which providers Codex can reach.
- **Usage reporting is clean**, and notably better than the broken K3 path:
  `{"input_tokens":6572,"cached_input_tokens":9,"cache_write_input_tokens":0,"output_tokens":28,"reasoning_output_tokens":0}`.
  Cost badging on a Codex turn would work today, including reasoning tokens.
- `Model metadata for <slug> not found. Defaulting to fallback metadata` — the **same class
  of problem** as the K3 200k context-window default. There may be a model-metadata config
  knob worth finding; relevant to the deferred context-cap question.
- **Performance:** the 3-step tool turn did not finish inside 7 minutes, partly from shell
  exploration overhead (it ran `qmd --help` to orient itself). Needs a fair benchmark before
  any conclusion, but flagged.
- The sequential same-tool chain **passed** — two different files read in separate turns,
  both correct, no loop. (The K3 collision bug was Claude-Code-specific.)

**Also run:** the K3 battery from 2026-07-27 — a sequential same-tool chain (catches tool-id
collisions that a single-turn parallel call hides) and streaming usage fidelity.

**Gate:** if Q1 or Q3 come back bad, STOP and reconsider. A harness that cannot stream
incrementally, or cannot be contained, is unusable for Jesse regardless of provider value.

**Deliverable:** findings appended to this doc + one working tool-using turn with qmd wired.

### Auth note

Codex normally wants an OpenAI credential. If none exists on this machine, the spike can
still run end-to-end against **Fireworks' OpenAI-compatible `/v1/chat/completions`** using
the existing Fireworks token — which also exercises the exact non-Anthropic path this whole
effort is about.

---

## Phase 1 — Extract the seam (no behavior change, ships alone)

Refactor `claude.rs` (2423 lines, 3 spawn sites) behind a trait, with Claude Code as the
only implementation. Pure refactor: same behavior, full suite green, separately mergeable.

```rust
trait Harness {
    fn build_main_command(&self, cfg: &Config, active: &ActiveModel, prompt: &str, opts: &TurnOpts) -> Command;
    fn parse_stream_line(&self, line: &str) -> StreamEvent;
    fn interpret_output(&self, stdout: &str, stderr: &str, ok: bool) -> ClaudeOutcome;
    fn session_id_from(&self, v: &Value) -> Option<String>;
    fn resume_args(&self, session_id: &str) -> Vec<String>;
    fn capabilities(&self) -> HarnessCaps;
}
```

Existing functions that become trait methods: `build_claude_args`, `build_claude_command`,
`parse_stream_line`, `classify_result_value`, `interpret_claude_output`,
`resolve_stream_outcome`, `apply_main_env`.

Two structural changes it forces:

- `ActiveModel::env` is `Option<(String, String, String)>` documented as "the `ANTHROPIC_*`
  triple". Becomes harness-owned — the adapter decides what a backend triple turns into.
- `cfg.claude_bin` (single path, `JESSE_CLAUDE_BIN`) becomes per-harness binary resolution.

**Design the trait AFTER Phase 0**, shaped by two real contracts rather than one imagined
one. This phase wants its own PR and a real soak — `claude.rs` is the hottest file in the
bridge.

---

## Phase 2 — Codex adapter (main turn only)

Implement `Harness` for Codex. New registry field `harness` per model, defaulting to
`ClaudeCode` so every existing entry is unchanged.

Hard parts, in risk order:

1. **Stream translation** into the existing `StreamEvent` enum, so `sse.rs` needs no changes.
2. **Session/resume mapping.** If Codex ids are stable strings, `Uuid::new_v5` generalizes
   as-is (any string hashes). If not, Codex conversations are tracked from the
   client-minted `conversation_id` only.
3. **Transcript adoption stays Claude-Code-only** — explicit non-goal, not a silent gap.

---

## Phase 3 — Surface it

- Registry entries for OpenAI models; `GET /jesse/models` gains a `harness` field; picker shows them.
- **Health probing needs care:** the probe is an Anthropic `/v1/messages` call, so a
  Codex-harness model needs a probe on *its own* surface. Reuse the
  `JESSE_HEALTH_TIMEOUT_SECS` / `REASONING_HEALTH_TIMEOUT_SECS` work from bridge 0.37.0.

---

## Phase 4 — Hardening

- **Containment probe battery** re-run live against Codex, the way the diet child was
  validated. Treat any containment claim as unproven until a probe battery says otherwise.
- **Capability matrix** in `HarnessCaps` — vision, attachments, resume, MCP. Anything
  unsupported returns an explicit error, never silent degradation.

---

## Risks

1. **Combinatorial test burden** — the permanent cost. Every main-turn feature now has two
   implementations. Mitigated by the capability matrix and by keeping Codex off local roles.
2. **Containment is not portable.** Prior finding: empty `--allowedTools` ≠ toolless.
3. **Two harnesses drift.** Both ship frequently; budget ongoing breakage on both.
4. **Phase 1 touches the main path.** Pure refactor, but it's the hottest file.

---

## Decision log

| Date | Decision | Evidence |
|---|---|---|
| 2026-07-27 | Pursue harness independence, not just provider independence | GLM + K3 already run non-Anthropic; coupling is to the CLI surface, transcripts, and `conversations.rs:85` |
| 2026-07-27 | Scope to main turn only | Title/diet/vaultqa point at ds4 `127.0.0.1:9100`, not hosted models |

## Open questions beyond Phase 0

- Does shadow comparison need to run cross-harness (Claude Code vs Codex on the same turn)?
  That would be a strong correctness signal, but doubles shadow's surface.
- Do we want per-conversation harness pinning, or is per-model enough? (A conversation that
  switches harness mid-thread has no shared session to resume.)
