//! Parser for `claude -p --output-format stream-json` NDJSON.
//!
//! The stream is newline-delimited JSON objects. We care about three shapes,
//! confirmed against a live capture:
//!   * `{"type":"stream_event","event":{"type":"content_block_delta",
//!      "delta":{"type":"text_delta","text":"…"}}}` — a streamed text chunk;
//!      the first one marks time-to-first-text.
//!   * `{"type":"assistant","message":{"content":[{"type":"tool_use",…}]}}` —
//!      an assistant turn; `tool_use` blocks here are the authoritative tool
//!      calls (the streamed deltas would double-count).
//!   * `{"type":"result","subtype":"success","result":"…","usage":{…},
//!      "ttft_ms":…}` — the terminal line: final answer, token usage, and the
//!      model-reported time-to-first-token.

use serde::Serialize;

/// Token usage pulled from the terminal `result` line.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read_input_tokens: u64,
    pub cache_creation_input_tokens: u64,
}

/// Everything the harness extracts from one task's transcript.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Transcript {
    /// `.result` from the terminal line; `None` if no result line arrived.
    pub final_answer: Option<String>,
    /// True iff a terminal `result` line arrived at all (the `completed` signal).
    pub completed: bool,
    /// Count of `tool_use` blocks across all `assistant` messages.
    pub tool_calls: u32,
    /// Token usage from the result line, if present.
    pub usage: Option<Usage>,
    /// Model-reported time-to-first-token (`ttft_ms`) from the result line.
    pub result_ttft_ms: Option<u64>,
    /// Whether the result line reported an error (`is_error`).
    pub is_error: bool,
}

/// Is this NDJSON line a streamed text delta? (Marks time-to-first-text.)
pub fn is_text_delta(line: &str) -> bool {
    let v: serde_json::Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return false,
    };
    v.get("type").and_then(|t| t.as_str()) == Some("stream_event")
        && v.pointer("/event/type").and_then(|t| t.as_str()) == Some("content_block_delta")
        && v.pointer("/event/delta/type").and_then(|t| t.as_str()) == Some("text_delta")
}

/// Parse the full set of transcript lines into a [`Transcript`].
pub fn parse(lines: &[String]) -> Transcript {
    let mut t = Transcript::default();
    for line in lines {
        let v: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue, // tolerate any non-JSON noise on the stream
        };
        match v.get("type").and_then(|t| t.as_str()) {
            Some("assistant") => {
                if let Some(content) = v.pointer("/message/content").and_then(|c| c.as_array()) {
                    for block in content {
                        if block.get("type").and_then(|t| t.as_str()) == Some("tool_use") {
                            t.tool_calls += 1;
                        }
                    }
                }
            }
            Some("result") => {
                t.completed = true;
                t.is_error = v.get("is_error").and_then(|e| e.as_bool()).unwrap_or(false);
                if let Some(r) = v.get("result").and_then(|r| r.as_str()) {
                    t.final_answer = Some(r.to_string());
                }
                t.result_ttft_ms = v.get("ttft_ms").and_then(|x| x.as_u64());
                if let Some(u) = v.get("usage") {
                    t.usage = Some(Usage {
                        input_tokens: u.get("input_tokens").and_then(|x| x.as_u64()).unwrap_or(0),
                        output_tokens: u.get("output_tokens").and_then(|x| x.as_u64()).unwrap_or(0),
                        cache_read_input_tokens: u
                            .get("cache_read_input_tokens")
                            .and_then(|x| x.as_u64())
                            .unwrap_or(0),
                        cache_creation_input_tokens: u
                            .get("cache_creation_input_tokens")
                            .and_then(|x| x.as_u64())
                            .unwrap_or(0),
                    });
                }
            }
            _ => {}
        }
    }
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text_delta(text: &str) -> String {
        format!(
            r#"{{"type":"stream_event","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"{text}"}}}}}}"#
        )
    }

    #[test]
    fn detects_text_delta() {
        assert!(is_text_delta(&text_delta("hi")));
        assert!(!is_text_delta(r#"{"type":"system","subtype":"init"}"#));
        assert!(!is_text_delta("not json at all"));
    }

    #[test]
    fn parses_answer_usage_and_completed() {
        let lines = vec![
            r#"{"type":"system","subtype":"init"}"#.to_string(),
            text_delta("READ"),
            text_delta("Y"),
            r#"{"type":"result","subtype":"success","is_error":false,"ttft_ms":1783,"result":"READY","usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}"#.to_string(),
        ];
        let t = parse(&lines);
        assert!(t.completed);
        assert!(!t.is_error);
        assert_eq!(t.final_answer.as_deref(), Some("READY"));
        assert_eq!(t.result_ttft_ms, Some(1783));
        assert_eq!(t.tool_calls, 0);
        let u = t.usage.unwrap();
        assert_eq!(u.input_tokens, 10);
        assert_eq!(u.output_tokens, 4);
        assert_eq!(u.cache_read_input_tokens, 5);
    }

    #[test]
    fn counts_tool_use_blocks_from_assistant_messages() {
        let lines = vec![
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"searching"},{"type":"tool_use","name":"Grep"}]}}"#.to_string(),
            r#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#.to_string(),
            r#"{"type":"result","subtype":"success","result":"done","usage":{}}"#.to_string(),
        ];
        let t = parse(&lines);
        assert_eq!(t.tool_calls, 2);
        assert!(t.completed);
    }

    #[test]
    fn no_result_line_means_not_completed() {
        let lines = vec![text_delta("partial")];
        let t = parse(&lines);
        assert!(!t.completed);
        assert_eq!(t.final_answer, None);
    }
}
