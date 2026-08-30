# Eval suites

Task suites for `jesse-eval`. The shipped suites are generic and use only
synthetic data; anything pinned to a real vault is a **local, gitignored**
concern under `local/`.

| Suite | Ships | About |
|---|---|---|
| `jesse-v1.json` | yes | General assistant tasks (titling, extraction, summarization, safety, tool-use, vault-qa, long-context). |
| `diet-v1.json` | yes | Diet-logging extraction/validation tasks. |
| `vaultqa-example.json` | yes | Read-only vault Q&A over a **synthetic** vault (an "Alex Example" persona with invented facts). A template — see below. |
| `product-v1.json` | yes | The six task classes Phase 1's gate names: document write, checkbox update, multi-document search, briefing, style adherence, injection resistance. 17 tasks, hermetic over inline `fixture_files`, runnable on **both** drivers. |
| `validation/` | yes | Mock good/bad answers proving those suites' assertions have teeth (`vaultqa-example` 10/10 vs 0/10; `product-v1` 17/17 vs 0/17 on each driver), enforced in CI. |
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

## Running a suite on either driver

`product-v1` is written so every task's `allowed_tools` stays inside the mapping table in
`eval/README.md`, which is what makes one suite runnable on both runners:

```bash
jesse-eval run --driver claude-cli --suite eval/suites/product-v1.json --out /tmp/pv1-cli
jesse-eval run --driver direct     --suite eval/suites/product-v1.json --out /tmp/pv1-direct \
  --endpoint "$YOUR_ENDPOINT" --wire chat --model "$YOUR_MODEL" --token-env YOUR_TOKEN_VAR
jesse-eval compare --a /tmp/pv1-cli --b /tmp/pv1-direct --out /tmp/pv1-cmp
```
