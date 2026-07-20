# `stream-json` fixtures

Structurally captured from real `claude --output-format stream-json --verbose
--include-partial-messages` runs (`claude` 2.1.195): the event shapes, envelope
fields, `session_id`/`uuid` format, and usage/cost blocks are the real captured
schema. The **answer text** (the `text_delta`s and the `result` string) has been
replaced with a SYNTHETIC equivalent of similar length/shape describing a fake
persona's vault ("This vault is Alex Example's personal TODO…"), so no real vault
content ships — the stream-parsing tests still exercise the same code paths.
Replayed by the streaming run-outcome regression tests in `src/claude.rs` through
the real `parse_stream_line` + `resolve_stream_outcome`. See
`bridge/README.md` → *Captured result schema and the empty-reply fix*.

| File | Provenance | Asserts |
|---|---|---|
| `success.ndjson` | Real captured stream schema with synthetic answer text: `text_delta`s + a `success` `result` line. (The `system/init` line is dropped — the parser ignores it and it carried an absolute home path the R5 source guard rejects.) | Full ~685-char `result` delivered; `session_id` preserved. |
| `error_max_turns.ndjson` | Real captured error shape (forced with `--max-turns 1` mid-tool-use): deltas + `{"subtype":"error_max_turns","is_error":true,"result":null}`. | Error envelope stays `Fatal` even though narration streamed. |
| `empty_result_success.ndjson` | **Derived** from `success.ndjson` — identical stream lines, with only the `result` field of the `success` line blanked to `""`. | Empty `result` falls back to the streamed text. |
| `missing_result.ndjson` | **Derived** from `success.ndjson` — the same stream lines with the terminal `result` line removed (claude streamed an answer, then exited without a `result`). | Missing `result` line falls back to the streamed text. |
