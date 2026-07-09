# jesse-eval

An offline eval harness for the Jesse assistant. It drives the `claude` CLI as a
child process against a task suite, scores each task against assertions, and can
pit a candidate model against a baseline with an LLM judge.

```
jesse-eval run   --suite eval/suites/jesse-v1.json --out <dir> [--endpoint URL --model ID]
jesse-eval judge --baseline <dirA> --candidate <dirB> --out <dir>
```

## `run`

For each task the harness spawns:

```
claude -p <prompt> --output-format stream-json --verbose --include-partial-messages \
       --permission-mode default --allowedTools <task allowlist>
```

with `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and `ANTHROPIC_MODEL` set **on
the child only** (never the harness's own environment) when `--endpoint`/`--model`
are given. Omit them for a baseline run against this machine's ambient auth and
default model.

Per task it captures: the full NDJSON transcript (`<out>/transcripts/<id>.ndjson`),
wall-clock time, time to first text delta, token usage (from the terminal `result`
line), tool-call count, and the result of every assertion. A task passes when all
of its assertions pass. Judged tasks additionally have their final answer saved to
`<out>/answers/<id>.txt`.

Outputs: `<out>/results.json` (one record per task) and `<out>/scorecard.md`
(per-class pass rate, mean latency, mean tool calls, plus totals).

### Workspaces

- `fixture` — the harness creates a fresh temp dir and populates it from the
  task's inline `fixture_files` before the run. Hermetic and repeatable.
- `vault-readonly` — the task runs with cwd `~/devel/tag1/jesse` (the real vault).
  Its allowlist may contain **only** read tools: `Read`, `Grep`, `Glob`, and the
  four `mcp__qmd__*` tools. Any other tool (`Write`, `Edit`, any `Bash`, …) is
  **refused before the suite runs** so an eval can never modify the vault. This
  check is load-bearing and unit-tested.

### Assertions

| type | fields | passes when |
|---|---|---|
| `answer_matches` | `pattern` | regex matches the final answer |
| `answer_excludes` | `pattern` | regex does **not** match the final answer |
| `file_equals` | `path`, `content` | workspace file has exactly this content |
| `file_matches` | `path`, `pattern` | regex matches the workspace file's content |
| `max_tool_calls` | `max` | tool-call count ≤ `max` |
| `completed` | — | a terminal `result` line arrived |

Regexes use the Rust `regex` crate (no lookaround). Flags like `(?i)` / `(?m)`
are supported inline.

## `judge`

For each judged task present in both result dirs, the harness runs **two** judge
calls via `claude -p` with **no env overrides** (ambient auth + default model):
one presenting the baseline as Answer 1 and the candidate as Answer 2, and one
with the order swapped. The judge prompt includes the task's rubric, presents both
answers verbatim, and asks for `VERDICT: 1 | 2 | TIE` plus one sentence — grading
content accuracy and instruction-following only, explicitly ignoring answer length
and stylistic polish (countering verbosity/self-preference bias; the swap counters
position bias). A candidate wins a task **only if it wins both orderings**;
disagreement records as `TIE`. Outputs `<out>/judgment.json` and `<out>/judgment.md`.

## `--mock`

`run --mock <file>` replays canned stream-json NDJSON instead of spawning
`claude`, so CI exercises the whole pipeline with zero network and zero models
(see `eval/tests/integration.rs`). The mock file maps task id → a response:

```json
{
  "responses": {
    "greet": {
      "ndjson": [
        {"type": "stream_event", "event": {"type": "content_block_delta",
          "delta": {"type": "text_delta", "text": "READY"}}},
        {"type": "result", "subtype": "success", "result": "READY",
          "usage": {"input_tokens": 10, "output_tokens": 4}}
      ],
      "files": {"log.csv": "date,item\n2026-07-09,apple\n"}
    }
  }
}
```

`ndjson` lines are parsed exactly as real `claude` output; `files` (optional) are
written into the workspace before assertions run, standing in for tool side effects.

## Suite schema

A suite is `{ "name": string, "tasks": [ Task, … ] }`. Each `Task`:

| field | required | meaning |
|---|---|---|
| `id` | yes | unique task id |
| `class` | yes | grouping bucket for the scorecard |
| `prompt` | yes | prompt passed to `claude -p` |
| `workspace` | yes | `"fixture"` or `"vault-readonly"` |
| `allowed_tools` | no | tools for `--allowedTools` (comma-joined) |
| `fixture_files` | no | `{path: content}` written into a fixture workspace |
| `judged` | no | if true, the final answer is saved for `judge` (needs `rubric`) |
| `rubric` | judged only | grading text shown to the judge |
| `assertions` | yes | list of assertion objects (table above) |

### One full example task

```json
{
  "id": "extract-csv",
  "class": "extraction",
  "workspace": "fixture",
  "prompt": "The file log.csv uses the schema Date,Meal,Item,Calories. Append EXACTLY ONE new row for the entry below, preserving all existing content unchanged and ending the file with a single trailing newline.\n\nEntry: On 2026-07-09, breakfast was oatmeal with blueberries — about 320 calories.",
  "allowed_tools": ["Read", "Edit", "Write"],
  "judged": false,
  "fixture_files": {
    "log.csv": "Date,Meal,Item,Calories\n2026-07-08,dinner,grilled salmon,540\n"
  },
  "assertions": [
    {"type": "file_matches", "path": "log.csv", "pattern": "(?m)^2026-07-09,breakfast,oatmeal with blueberries,320$"},
    {"type": "file_equals", "path": "log.csv", "content": "Date,Meal,Item,Calories\n2026-07-08,dinner,grilled salmon,540\n2026-07-09,breakfast,oatmeal with blueberries,320\n"},
    {"type": "max_tool_calls", "max": 4},
    {"type": "completed"}
  ]
}
```

## The `jesse-v1` suite

Twelve tasks across eight classes: `titles`, `extraction`, `summarization`,
`safety`, `tool-use`, `vault-qa`, `long-context`. They probe titling (including
ignoring an instruction embedded in the data), structured extraction, faithful
summarization (with an omission canary and a prompt-injection canary), tool
discipline (both using tools when needed and *not* flailing into them when not),
read-only vault Q&A over `qmd`, and long-context conflict-finding. Judged tasks
carry a rubric for the `judge` subcommand.

## Workspace note

`eval/` is its own crate in a root Cargo workspace that **excludes** `bridge/`, so
the bridge continues to build from `working-directory: bridge` with its own
`Cargo.lock` exactly as before.
