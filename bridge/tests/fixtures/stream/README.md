# `stream-json` fixtures

Captured from real `claude --output-format stream-json --verbose
--include-partial-messages` runs in the vault on 2026-06-27 (`claude` 2.1.195).
Replayed by the streaming run-outcome regression tests in `src/main.rs` through
the real `parse_stream_line` + `resolve_stream_outcome`. See
`bridge/README.md` → *Captured result schema and the empty-reply fix*.

| File | Provenance | Asserts |
|---|---|---|
| `success.ndjson` | **Verbatim** real capture (`"explain what this vault is for"`): real `text_delta`s + the real `success` `result` line. (The `system/init` line is dropped — the parser ignores it and it carried an absolute home path the R5 source guard rejects.) | Full ~693-char `result` delivered; `session_id` preserved. |
| `error_max_turns.ndjson` | **Verbatim** real capture (forced with `--max-turns 1` mid-tool-use): real deltas + real `{"subtype":"error_max_turns","is_error":true,"result":null}`. | Error envelope stays `Fatal` even though narration streamed. |
| `empty_result_success.ndjson` | **Derived** from `success.ndjson` — identical real stream lines, with only the `result` field of the real `success` line blanked to `""`. The intermittent live empty-`result` success could not be reproduced on demand, so the failing field is set by hand; the stream and envelope are otherwise verbatim. | Empty `result` falls back to the streamed text. |
| `missing_result.ndjson` | **Derived** from `success.ndjson` — the same real stream lines with the terminal `result` line removed (claude streamed an answer, then exited without a `result`). | Missing `result` line falls back to the streamed text. |
