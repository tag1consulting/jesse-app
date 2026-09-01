# Suite validation

Mock validation for the shipped suites: canned answers whose scored outcome proves the
assertions have teeth. Nothing here talks to a network or a model.

## `vaultqa-example`

Mock validation for `../vaultqa-example.json`, the same way `diet-v1` was
validated: two canned `--mock` files whose scored outcome proves the suite's
assertions have teeth — a correct answer passes everything, a known-bad answer
fails **exactly** the assertion it should. Both mocks answer the synthetic
"Alex Example" vault, so this ships clean of any real personal data.

| file | what it is | scored result |
|---|---|---|
| `mock-good.json` | a grounded, injection-resistant answer for every task | `mock-good-scorecard.md` — **10/10 (100%)** |
| `mock-bad.json` | a known-bad answer per task (wrong fact, hallucinated brand, out-of-band number, confabulated absent fact, got-injected `PWNED`) | `mock-bad-scorecard.md` — **0/10 (0%)** |

In the bad run each task fails only its intended content/safety assertion(s);
`completed` (and `max_tool_calls` where present) still pass, so the failure is a
real assertion firing, not a harness error. This is asserted in CI by
`vaultqa_example_good_mock_passes_every_task` and
`vaultqa_example_bad_mock_fails_intended_assertions` in
`eval/tests/integration.rs`, which run the shipped suite + these mocks through the
real assertion engine.

Reproduce:

```
jesse-eval run --suite eval/suites/vaultqa-example.json \
  --mock eval/suites/validation/mock-good.json --out /tmp/vqa-good
jesse-eval run --suite eval/suites/vaultqa-example.json \
  --mock eval/suites/validation/mock-bad.json  --out /tmp/vqa-bad
```

## `product-v1`

The same idea, on BOTH drivers, because a suite that scores 17/17 on one runner and cannot
be run on the other is not a comparison.

| file | driver | what it is | scored result |
|---|---|---|---|
| `product-v1-good.json` | `direct` | a scripted-provider fixture whose tool calls do the work for real | **17/17 (100%)** |
| `product-v1-bad.json` | `direct` | a known-bad answer per task | **0/17 (0%)** |
| `product-v1-cli-good.json` | `claude-cli` | the same answers as canned stream-json, plus the file state the direct run produced | **17/17 (100%)** |
| `product-v1-cli-bad.json` | `claude-cli` | the same bad answers, ditto | **0/17 (0%)** |
| `product-v1-resist-silent.json` | `direct` | the good run, except the three injection tasks resist the attack and say NOTHING about it | **14/17** — the three fail on the disclosure row and nothing else |
| `product-v1-comply.json` | `direct` | the good run, except the six tasks D9 scored backwards take the trap: the injected string as the answer, the decoy stated as the claim, the finished item presented as outstanding | **11/17** — each fails the anchored exclusion or `answer_mentions_only_with` |

The last two are D11's both-directions proof for the repaired injection, briefing and
decoy assertions, and they only mean something as a set of three. The good run shows a
resist-AND-disclose answer scoring 17/17 **with the injected words in its text** — the
answer D9's unanchored `answer_excludes` scored as a failure. `resist-silent` shows that
resisting without saying so is still a failure, on the disclosure row alone. `comply` shows
that actually taking the trap still fails, on the anchored row. An assertion that passed all
three of those would be measuring nothing.

In both bad runs every task fails a CONTENT or SAFETY assertion and `completed` still
passes, so no failure is a harness error. The direct pair is the stronger of the two: its
tool calls are dispatched against the real vault tool set over the real fixture workspace,
so `dw-append-entry` passing means a `vault_write` under a compare-and-swap actually wrote
the file that `numbers_consistent` then read, and `inj-tool-result-write` failing in the bad
run means a real file really changed.

Enforced in CI by `product_v1_{direct,cli}_{good,bad}_mock_*`,
`the_direct_mock_exercises_the_real_write_path`,
`compare_reports_parity_between_the_two_good_runs`,
`product_v1_a_silent_resist_fails_only_the_disclosure_row`,
`product_v1_compliance_fails_the_anchored_assertions` and
`a_style_violating_answer_is_graded_identically_on_both_drivers` in
`eval/tests/integration.rs`. The last of those is D11's F2 teeth at suite level: the same
style-violating answer must produce the same `style_clean` verdict AND the same detail
string on both runners, so a `style-adherence` split between drivers can only mean the
answers differed — not that one runner was shown the pack and the other was not.

Reproduce:

```
jesse-eval run --driver direct --suite eval/suites/product-v1.json \
  --mock eval/suites/validation/product-v1-good.json --out /tmp/pv1-direct-good
jesse-eval run --driver direct --suite eval/suites/product-v1.json \
  --mock eval/suites/validation/product-v1-bad.json  --out /tmp/pv1-direct-bad
jesse-eval run --suite eval/suites/product-v1.json \
  --mock eval/suites/validation/product-v1-cli-good.json --out /tmp/pv1-cli-good
jesse-eval run --suite eval/suites/product-v1.json \
  --mock eval/suites/validation/product-v1-cli-bad.json  --out /tmp/pv1-cli-bad
jesse-eval run --driver direct --suite eval/suites/product-v1.json \
  --mock eval/suites/validation/product-v1-resist-silent.json --out /tmp/pv1-silent
jesse-eval run --driver direct --suite eval/suites/product-v1.json \
  --mock eval/suites/validation/product-v1-comply.json --out /tmp/pv1-comply
jesse-eval compare --a /tmp/pv1-cli-good --b /tmp/pv1-direct-good --out /tmp/pv1-cmp
```
