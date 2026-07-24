# Vision eval set

A fixed set of representative uploads for vetting vision helpers, plus the harnesses that
run them. Used to answer two questions before a helper earns a pairing slot: *is its
transcription faithful?* and *what does it cost?*

## Files

- `manifest.json` — the eval set: each fixture's file, kind, ground-truth strings, and a
  question answerable only by reading the attachment. All content is fictional.
- `fixtures/` — the committed fixtures:
  - `statement.pdf` — text-heavy PDF (an invoice). **Real text**, so its ground truth is a
    meaningful faithfulness check.
  - `table.pdf` — a values table PDF. **Real text.**
  - `chart.png`, `screenshot.png`, `photo.png` — **synthetic placeholders** (shapes/colors,
    little text). They exercise the image path end to end; swap in representative
    real-world images before the definitive fidelity call.

Regenerate deterministically:

```
cargo run --bin vision-fixtures -- eval/vision/fixtures
```

## Harnesses (from `bridge/`)

Both read the model registry from the bridge's env (the same `[[models]]` / `JESSE_MODEL_*`
the running server reads), so what you measure is what production produces. The PDF path
needs pdfium: set `JESSE_PDFIUM_LIB=/path/to/libpdfium.{so,dylib}`.

**Compare** one attachment across several helpers (side-by-side transcription + latency +
cost):

```
FIREWORKS_API_KEY=… vision-compare eval/vision/fixtures/statement.pdf paddleocr-vl,qwen3-vl
```

**Eval** the whole set through one helper (faithfulness = ground-truth substrings present,
+ latency/cost, + aggregate score):

```
FIREWORKS_API_KEY=… vision-eval eval/vision/manifest.json paddleocr-vl
```

## Status

The harnesses and fixtures are complete and CI-green. The **measured** live pass (real
transcriptions, per-helper faithfulness/latency/cost) is pending a vision-capable endpoint:
the Fireworks account tested during development exposed **no** vision models (all candidate
VL slugs 404'd). Once a helper is registered and resolves, run the two commands above to
fill in the numbers. See the repo-root `REPORT.md` for details.
