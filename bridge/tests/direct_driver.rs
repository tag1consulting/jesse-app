//! **THE IN-PROCESS ARM IS THE SAME TURN.**
//!
//! D4 split the driver so that a harness answering in this process takes a different arm of
//! one branch. D5 puts a harness on that arm. What this file proves is the property both
//! steps were built around: a turn's TEXT reaches the rest of the bridge in exactly the same
//! shape whichever arm produced it, so every stage after the driver — the directive parser,
//! the `SPOKEN:` handling, the badge, the artifact sweep, the transcript — is one code path
//! rather than two that agree by luck.
//!
//! It is written against a DOUBLE rather than the real `direct` harness on purpose. The real
//! one calls a provider over HTTP, and a test that needed a live model would prove the
//! provider works, not that the driver is neutral. The double returns a fixed string, which
//! is the only way to assert that the string comes back unchanged.

mod common;

use jesse_bridge::*;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use tokio_util::sync::CancellationToken;

/// An in-process harness that answers with whatever it was constructed with.
///
/// Everything else about it is the least interesting legal answer: it streams (so the
/// driver's streamed-text safety net applies, which is the harder case), expresses every
/// level, keeps no transcripts and takes no write lock.
struct Echo {
    text: &'static str,
    /// Emitted through the sink before the outcome, so the test can tell "the driver
    /// forwarded the deltas" from "the driver used the terminal text".
    deltas: &'static [&'static str],
}

impl Harness for Echo {
    fn id(&self) -> &'static str {
        "echo"
    }
    fn streams_text(&self) -> bool {
        true
    }
    fn expresses(&self, _c: Capability) -> bool {
        true
    }
    fn supports_wire(&self, w: Wire) -> bool {
        matches!(w, Wire::Messages)
    }
    fn capability_args(&self, _c: &Config, _cap: Capability) -> Vec<String> {
        Vec::new()
    }
    fn shipped_rows(&self) -> &'static [ContainmentRow] {
        &[]
    }
    fn transcript_dir(&self, _c: &Config) -> Option<std::path::PathBuf> {
        None
    }
    fn attachment_support(&self) -> &'static AttachmentSupport {
        &CLAUDE_CODE_ATTACHMENTS
    }
    fn runner(&self) -> Runner<'_> {
        Runner::InProcess(self)
    }
}

impl InProcessHarness for Echo {
    fn run_turn<'a>(
        &'a self,
        _cfg: &'a Config,
        _req: &'a TurnRequest<'a>,
        sink: &'a dyn TurnSink,
        _cancel: CancellationToken,
    ) -> Pin<Box<dyn Future<Output = Result<TurnOutcome, TurnFailure>> + Send + 'a>> {
        Box::pin(async move {
            for d in self.deltas {
                sink.text_delta(d);
            }
            sink.tool_activity(ToolActivity::used("vault_read"));
            Ok(TurnOutcome {
                text: self.text.to_string(),
                session_id: Some("direct-11111111-1111-4111-8111-111111111111".to_string()),
                usage: ShadowUsage {
                    input_tokens: Some(10),
                    output_tokens: Some(5),
                    ..Default::default()
                },
                tool_calls: 1,
            })
        })
    }
}

/// Drive one turn through the real driver on the in-process arm and hand back what it
/// returned, plus the live stream the client would have seen.
async fn drive(h: &dyn Harness) -> (String, Option<String>, ShadowUsage, String) {
    let mut cfg = common::test_config();
    cfg.timeout_secs = 30;
    let jobs = Arc::new(JobStore::new(
        std::time::Duration::from_secs(600),
        std::time::Duration::from_secs(600),
        None,
    ));
    let job_id = jobs.create();
    let job_id = job_id.as_str();
    // The handler registers the live stream when it creates the job; a delta pushed at an
    // unregistered id is a documented no-op, so a test that skipped this would assert the
    // accumulator was empty and learn nothing.
    jobs.stream_register(job_id);
    let active = ActiveModel::ambient();
    let spawned = SpawnedSessions::new();
    let trace = TurnTrace::from_cfg(&cfg);
    let (text, sid, usage) = run_claude_streaming(
        &cfg, "PROMPT", None, &jobs, job_id, &active, h, &spawned, None, None, None, &trace,
    )
    .await
    .expect("the echo harness answers");
    let streamed = jobs.stream_snapshot(job_id).unwrap_or_default();
    (text, sid, usage, streamed)
}

/// **A DIRECTIVE SURVIVES THE IN-PROCESS ARM INTACT**, and is then stripped by the same
/// function that strips a spawned turn's.
///
/// The directive line is the sharpest case available: it is machine-parsed, it is stripped
/// from the delivered text, and the app binds a delivered turn to its hydrated twin by EXACT
/// TEXT EQUALITY — so an arm that trimmed, re-wrapped or re-ordered the answer by one
/// character would show the user their reply twice, permanently.
#[tokio::test]
async fn a_directive_from_an_in_process_turn_parses_exactly_as_a_spawned_one_does() {
    let raw = "Here is the answer.\n\nJESSE_NEEDS_HEALTH v1 {\"sections\":[\"workouts\"]}";
    let h = Echo {
        text: raw,
        deltas: &["Here is ", "the answer."],
    };
    let (text, sid, usage, _) = drive(&h).await;

    // The driver returned the harness's text UNTOUCHED — no trim, no re-wrap, no badge (the
    // badge is appended later, by the handler, on both arms alike).
    assert_eq!(text, raw, "the driver must not edit a turn's text");
    assert_eq!(
        sid.as_deref(),
        Some("direct-11111111-1111-4111-8111-111111111111")
    );
    assert_eq!(usage.input_tokens, Some(10));

    // And the shared parser sees the same thing it would see from a spawned turn: one
    // directive, and a delivered text with the directive line gone.
    let (stripped, _sid, directives) = apply_directives(Ok((text.clone(), sid.clone())))
        .expect("a directive-bearing reply still parses");
    assert!(
        directives.is_some(),
        "the parser must see the directive an in-process turn emitted"
    );
    assert!(
        !stripped.contains("JESSE_NEEDS_HEALTH"),
        "the directive line is stripped from the delivered text: {stripped:?}"
    );
    assert!(stripped.contains("Here is the answer."));

    // The hydration invariant: what a client is shown after delivery equals what it is shown
    // after hydration. Same function, same input, on this arm as on the other.
    assert_eq!(delivered_text(&text), stripped);
}

/// **THE DELTAS REACH THE SAME STREAM.** A client watching an in-process turn sees the answer
/// build exactly as it does for claude-code — same frames, same order, same accumulator.
#[tokio::test]
async fn an_in_process_turn_pushes_its_deltas_onto_the_jobs_live_stream() {
    let h = Echo {
        text: "Here is the answer.",
        deltas: &["Here is ", "the answer."],
    };
    let (_, _, _, streamed) = drive(&h).await;
    assert_eq!(
        streamed, "Here is the answer.",
        "the sink's deltas must land in the job's stream accumulator"
    );
}

/// **A `SPOKEN:` LINE IS HANDLED BY THE SAME CODE.** A voice turn's reply carries a spoken
/// variant that delivery and hydration both strip; a second arm that handled it differently
/// would make a voice turn render twice in the app.
#[tokio::test]
async fn a_spoken_line_from_an_in_process_turn_is_handled_by_the_shared_path() {
    let raw = "The full written answer.\n\nSPOKEN: The short one.";
    let h = Echo {
        text: raw,
        deltas: &["The full written answer."],
    };
    let (text, _, _, _) = drive(&h).await;
    assert_eq!(text, raw, "the driver must not edit a voice turn's text");
    // The shared function, not a second copy: whatever it does to a spawned turn's SPOKEN
    // line it does to this one.
    let delivered = delivered_text(&text);
    assert_eq!(
        delivered,
        delivered_text(raw),
        "one function, one answer, whichever arm produced the text"
    );
}
