# Eval suites

Task suites for `jesse-eval`. The shipped suites are generic and use only
synthetic data; anything pinned to a real vault is a **local, gitignored**
concern under `local/`.

| Suite | Ships | About |
|---|---|---|
| `jesse-v1.json` | yes | General assistant tasks (titling, extraction, summarization, safety, tool-use, vault-qa, long-context). |
| `diet-v1.json` | yes | Diet-logging extraction/validation tasks. |
| `vaultqa-example.json` | yes | Read-only vault Q&A over a **synthetic** vault (an "Alex Example" persona with invented facts). A template — see below. |
| `validation/` | yes | Mock good/bad answers proving `vaultqa-example`'s assertions have teeth (good → 10/10, bad → 0/10), enforced in CI. |
| `local/*.json` | **no** (gitignored) | Your own vault-QA suites, pinned to real facts in *your* vault. |

## Writing a vault-QA suite against your own vault

`vaultqa-example.json` answers questions about a made-up vault, so it can't score
against yours. To evaluate against your real vault, copy it into `local/` and
replace the questions, assertion patterns, and rubrics with your own facts:

```bash
cp eval/suites/vaultqa-example.json eval/suites/local/vaultqa-mine.json
# edit the prompts/assertions to match facts that actually live in your vault,
# then run it read-only against $JESSE_VAULT:
JESSE_VAULT=~/vault jesse-eval run \
  --suite eval/suites/local/vaultqa-mine.json --out /tmp/vqa-mine \
  --endpoint "$YOUR_ENDPOINT" --model "$YOUR_MODEL"
```

Everything under `eval/suites/local/` is gitignored **by design** — a suite pinned
to your personal vault holds real facts (names, numbers, filenames) that must
never be pushed. Keep the generic `vaultqa-example.json` as your starting
template and never edit real facts into it.

`vault-readonly` tasks run with cwd `$JESSE_VAULT` (else `~/vault`) and may use
**only** read tools (`Read`, `Grep`, `Glob`, `mcp__qmd__*`); the harness refuses
any write tool before the suite runs, so an eval can never modify your vault.
