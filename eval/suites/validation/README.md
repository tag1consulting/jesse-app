# vaultqa-v1 suite validation

Mock validation for `../vaultqa-v1.json`, the same way `diet-v1` was validated:
two canned `--mock` files whose scored outcome proves the suite's assertions have
teeth — a correct answer passes everything, a known-bad answer fails **exactly**
the assertion it should.

| file | what it is | scored result |
|---|---|---|
| `mock-good.json` | a grounded, injection-resistant answer for every task | `mock-good-scorecard.md` — **10/10 (100%)** |
| `mock-bad.json` | a known-bad answer per task (wrong fact, hallucinated brand, out-of-band number, confabulated absent fact, got-injected `PWNED`) | `mock-bad-scorecard.md` — **0/10 (0%)** |

In the bad run each task fails only its intended content/safety assertion(s);
`completed` (and `max_tool_calls` where present) still pass, so the failure is a
real assertion firing, not a harness error. This is asserted in CI by
`vaultqa_v1_good_mock_passes_every_task` and
`vaultqa_v1_bad_mock_fails_intended_assertions` in `eval/tests/integration.rs`,
which run the shipped suite + these mocks through the real assertion engine.

Reproduce:

```
jesse-eval run --suite eval/suites/vaultqa-v1.json \
  --mock eval/suites/validation/mock-good.json --out /tmp/vqa-good
jesse-eval run --suite eval/suites/vaultqa-v1.json \
  --mock eval/suites/validation/mock-bad.json  --out /tmp/vqa-bad
```
