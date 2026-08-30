//! **A scripted provider** — a [`Provider`] that speaks no HTTP and plays a fixed script.
//!
//! GATED OUT OF A RELEASE BUILD. The module is compiled only under `cfg(test)` or the
//! `scripted` feature (which the eval driver turns on). A fake provider that shipped in the
//! library would be a `Provider` implementation a caller could reach by accident — and one
//! whose whole purpose is to return answers nobody generated.
//!
//! ---- WHY IT EXISTS ALONGSIDE THE LOOPBACK MOCKS -----------------------------
//!
//! The conformance suite's loopback mock proves the ADAPTERS: it speaks HTTP, so it
//! exercises framing, chunk boundaries, status handling and connection close. This proves
//! the LOOP, and it is a different question. A loop test driven through a socket has to
//! express "the model now asks for a second tool call" as a hand-written SSE script in a
//! wire's own dialect — which means the loop's tests are written twice, once per wire, and
//! a change to the loop's behaviour is a change to two piles of JSON that assert nothing
//! about the loop.
//!
//! Here a case is a list of [`Event`]s: exactly the vocabulary the loop consumes. The
//! script is the same on both wires because the loop cannot tell them apart, which is the
//! property D1 built and this is the test that uses it.
//!
//! It also records every [`Request`] it was handed, which is how the boundary tests assert
//! on what the model was actually SHOWN — "a tool at a higher level than granted is absent
//! from the manifest the provider received" is a claim about a request body, and this is
//! where the request body is.

use std::collections::VecDeque;
use std::sync::Mutex;

use tokio_util::sync::CancellationToken;

use super::http::{CallAudit, EventStream};
use super::{
    BoxFuture, Capabilities, Event, Provider, ProviderError, Request, StopReason, Usage, Wire,
};

/// One scripted response.
#[derive(Debug, Clone)]
pub enum Step {
    /// The call succeeds and streams these events, in order.
    Events(Vec<Event>),
    /// The call fails BEFORE the stream exists — the shape a retryable/fatal error takes
    /// when `Provider::stream`'s own future resolves to an error (see `http::start_call`).
    Fails(ProviderError),
}

impl Step {
    /// A plain text answer that ends the turn.
    pub fn text(answer: impl Into<String>, usage: Usage) -> Step {
        Step::Events(vec![
            Event::TextDelta(answer.into()),
            Event::Usage(usage),
            Event::Done {
                stop_reason: StopReason::EndTurn,
            },
        ])
    }

    /// An answer that asks for one tool call.
    ///
    /// The argument JSON is delivered as ONE fragment. Splitting it is the adapters'
    /// problem and the conformance suite already proves they reassemble it; a loop test
    /// that split it here would be re-testing D1 through D2.
    pub fn tool_call(
        id: impl Into<String>,
        name: impl Into<String>,
        arguments: serde_json::Value,
        usage: Usage,
    ) -> Step {
        let id = id.into();
        Step::Events(vec![
            Event::ToolUseStart {
                id: id.clone(),
                name: name.into(),
            },
            Event::ToolUseArgsDelta {
                id: id.clone(),
                json_fragment: arguments.to_string(),
            },
            Event::ToolUseEnd { id },
            Event::Usage(usage),
            Event::Done {
                stop_reason: StopReason::ToolUse,
            },
        ])
    }
}

/// A provider that plays [`Step`]s in order and records what it was asked.
pub struct ScriptedProvider {
    wire: Wire,
    model: String,
    steps: Mutex<VecDeque<Step>>,
    seen: Mutex<Vec<Request>>,
    /// Played when the script runs out.
    ///
    /// AN ERROR, not a repeat of the last step and not a hang. A loop that made one more
    /// call than its test expected is a bug the test must fail on, and the two obvious
    /// alternatives both hide it: repeating the last step turns an infinite loop into an
    /// infinite test, and blocking turns it into a timeout nobody can read.
    exhausted: ProviderError,
    capabilities: Capabilities,
}

impl ScriptedProvider {
    pub fn new(wire: Wire, model: impl Into<String>, steps: Vec<Step>) -> Self {
        ScriptedProvider {
            wire,
            model: model.into(),
            steps: Mutex::new(steps.into()),
            seen: Mutex::new(Vec::new()),
            exhausted: ProviderError::Protocol("the script ran out of steps".into()),
            capabilities: Capabilities {
                tool_use: true,
                streaming: true,
                vision: true,
                prompt_caching: true,
                thinking: true,
                parallel_tool_calls: true,
                max_context_tokens: None,
            },
        }
    }

    /// Every request this provider was handed, in order.
    pub fn requests(&self) -> Vec<Request> {
        self.seen.lock().expect("scripted seen poisoned").clone()
    }

    /// How many steps are still unplayed. A test asserting the loop stopped early asserts
    /// on this, which is stronger than asserting on the outcome alone: it proves the loop
    /// did not make the call, rather than that it discarded the answer.
    pub fn remaining(&self) -> usize {
        self.steps.lock().expect("scripted steps poisoned").len()
    }

    pub fn model(&self) -> &str {
        &self.model
    }
}

impl Provider for ScriptedProvider {
    fn wire(&self) -> Wire {
        self.wire
    }

    fn capabilities(&self) -> Capabilities {
        self.capabilities.clone()
    }

    fn stream<'a>(
        &'a self,
        req: &'a Request,
        cancel: CancellationToken,
    ) -> BoxFuture<'a, Result<EventStream, ProviderError>> {
        Box::pin(async move {
            self.seen
                .lock()
                .expect("scripted seen poisoned")
                .push(req.clone());

            // Cancellation is honoured at the same boundary a real call honours it: before
            // the stream exists, `stream` resolves to `Cancelled` (see `http::start_call`).
            if cancel.is_cancelled() {
                return Err(ProviderError::Cancelled);
            }

            let step = self
                .steps
                .lock()
                .expect("scripted steps poisoned")
                .pop_front();
            let events = match step {
                Some(Step::Events(e)) => e,
                Some(Step::Fails(e)) => return Err(e),
                None => return Err(self.exhausted.clone()),
            };

            let usage = events.iter().find_map(|e| match e {
                Event::Usage(u) => Some(u.clone()),
                _ => None,
            });
            let stop_reason = events.iter().find_map(|e| match e {
                Event::Done { stop_reason } => Some(stop_reason.clone()),
                _ => None,
            });
            let audit = CallAudit {
                wire: self.wire,
                model: self.model.clone(),
                request_tag: req.request_tag.clone(),
                // Zero rather than a measured value: a scripted call takes no time, and a
                // test asserting on a latency this produced would be asserting on the
                // scheduler.
                latency_ms: 0,
                attempt: 1,
                stop_reason,
                error_class: None,
                usage,
            };
            Ok(EventStream::scripted(events, audit, cancel))
        })
    }
}

// ===========================================================================
// The fixture format
// ===========================================================================

/// A scripted fixture: a task id, and the steps that task's turn plays.
///
/// **THIS IS THE FORMAT, AND IT LIVES HERE RATHER THAN IN THE EVAL HARNESS.** The eval's
/// direct driver replays these files to run a whole suite with no network, and a fixture
/// format that lived in the harness would be a second description of what a
/// [`ScriptedProvider`] plays — one that could drift from the `Step` it is supposed to
/// build. The provider owns its own script's spelling; the harness owns which script goes
/// with which task.
///
/// ```json
/// {
///   "responses": {
///     "write-a-note": [
///       {"type": "tool_calls", "calls": [
///         {"name": "vault_write", "arguments": {"id": "notes/new.md", "body": "# New\n"}}
///       ]},
///       {"type": "text", "text": "Written."}
///     ]
///   }
/// }
/// ```
///
/// The steps of one task are played IN ORDER, one per provider call: a `tool_calls` step
/// makes the loop dispatch those tools for real and come back for the next step, and a
/// `text` step ends the turn. Running out of steps is the provider's own
/// script-exhausted error, which is a loud failure rather than a hang — see
/// [`ScriptedProvider`].
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ScriptFixture {
    /// Task id → the steps that task plays.
    pub responses: std::collections::BTreeMap<String, Vec<ScriptStep>>,
}

impl ScriptFixture {
    /// Parse a fixture from JSON bytes.
    pub fn from_json(bytes: &[u8]) -> Result<ScriptFixture, String> {
        serde_json::from_slice(bytes).map_err(|e| format!("invalid scripted fixture: {e}"))
    }

    /// The [`Step`]s for one task, or `None` when the fixture does not script it.
    ///
    /// `None` rather than an empty script: a task the fixture forgot and a task the fixture
    /// deliberately gives nothing to are different mistakes, and only the caller knows which
    /// of them is fatal.
    pub fn steps_for(&self, task_id: &str) -> Option<Vec<Step>> {
        self.responses
            .get(task_id)
            .map(|steps| steps.iter().map(ScriptStep::to_step).collect())
    }
}

/// One scripted provider call.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ScriptStep {
    /// A plain answer that ends the turn.
    Text {
        text: String,
        #[serde(default)]
        usage: ScriptUsage,
    },
    /// One or more tool calls. The loop dispatches them against the REAL tool set and comes
    /// back for the next step with their real results.
    ToolCalls {
        calls: Vec<ScriptToolCall>,
        #[serde(default)]
        usage: ScriptUsage,
    },
    /// The call fails before the stream exists — the shape [`Step::Fails`] carries.
    Fails { message: String },
}

impl ScriptStep {
    /// The [`Step`] this fixture entry plays.
    fn to_step(&self) -> Step {
        match self {
            ScriptStep::Text { text, usage } => Step::text(text.clone(), usage.to_usage()),
            ScriptStep::ToolCalls { calls, usage } => {
                let mut events = Vec::with_capacity(calls.len() * 3 + 2);
                for (i, call) in calls.iter().enumerate() {
                    let id = call.id.clone().unwrap_or_else(|| format!("call-{i}"));
                    events.push(Event::ToolUseStart {
                        id: id.clone(),
                        name: call.name.clone(),
                    });
                    events.push(Event::ToolUseArgsDelta {
                        id: id.clone(),
                        json_fragment: call.arguments.to_string(),
                    });
                    events.push(Event::ToolUseEnd { id });
                }
                events.push(Event::Usage(usage.to_usage()));
                events.push(Event::Done {
                    stop_reason: StopReason::ToolUse,
                });
                Step::Events(events)
            }
            ScriptStep::Fails { message } => Step::Fails(ProviderError::Protocol(message.clone())),
        }
    }
}

/// One tool call in a [`ScriptStep::ToolCalls`] step.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ScriptToolCall {
    /// The call id the model would have generated. Defaulted from the call's position when
    /// the fixture leaves it out, because the id matters only for pairing the result back
    /// and a fixture author has nothing to say about it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// The MANIFEST name. Exact — dispatch does no matching of any kind.
    pub name: String,
    /// The arguments, as the model would have streamed them.
    #[serde(default)]
    pub arguments: serde_json::Value,
}

/// The token vector a scripted step reports.
///
/// Four plain numbers rather than the provider's four `Option`s: a fixture that omits a
/// count means zero of them, and an absent-versus-zero distinction is a property of a real
/// wire's reporting, not of a file somebody wrote.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct ScriptUsage {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

impl ScriptUsage {
    fn to_usage(self) -> Usage {
        Usage {
            input_tokens: Some(self.input),
            output_tokens: Some(self.output),
            cache_read_tokens: Some(self.cache_read),
            cache_write_tokens: Some(self.cache_write),
            provider_request_id: None,
        }
    }
}

#[cfg(test)]
mod fixture_tests {
    use super::*;

    #[test]
    fn a_fixture_parses_into_the_steps_it_describes() {
        let raw = br#"{
          "responses": {
            "t1": [
              {"type": "tool_calls", "calls": [
                 {"name": "vault_read", "arguments": {"id": "a.md"}},
                 {"name": "vault_read", "arguments": {"id": "b.md"}}
              ], "usage": {"input": 10, "output": 2}},
              {"type": "text", "text": "done", "usage": {"output": 3}}
            ]
          }
        }"#;
        let fixture = ScriptFixture::from_json(raw).expect("parses");
        let steps = fixture.steps_for("t1").expect("t1 is scripted");
        assert_eq!(steps.len(), 2);

        // The first step asks for BOTH reads in one call, with its arguments intact.
        let Step::Events(events) = &steps[0] else {
            panic!("first step streams events");
        };
        let names: Vec<&str> = events
            .iter()
            .filter_map(|e| match e {
                Event::ToolUseStart { name, .. } => Some(name.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(names, ["vault_read", "vault_read"]);
        let args: Vec<&str> = events
            .iter()
            .filter_map(|e| match e {
                Event::ToolUseArgsDelta { json_fragment, .. } => Some(json_fragment.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(args, [r#"{"id":"a.md"}"#, r#"{"id":"b.md"}"#]);
        assert!(matches!(
            events.last(),
            Some(Event::Done {
                stop_reason: StopReason::ToolUse
            })
        ));

        // The second ends the turn.
        let Step::Events(events) = &steps[1] else {
            panic!("second step streams events");
        };
        assert!(matches!(
            events.last(),
            Some(Event::Done {
                stop_reason: StopReason::EndTurn
            })
        ));
    }

    #[test]
    fn an_unscripted_task_is_none_rather_than_an_empty_script() {
        let fixture = ScriptFixture::from_json(br#"{"responses": {}}"#).expect("parses");
        assert!(fixture.steps_for("missing").is_none());
    }

    #[test]
    fn a_failing_step_carries_its_message() {
        let fixture = ScriptFixture::from_json(
            br#"{"responses": {"t": [{"type": "fails", "message": "boom"}]}}"#,
        )
        .expect("parses");
        let steps = fixture.steps_for("t").expect("scripted");
        assert!(matches!(&steps[0], Step::Fails(ProviderError::Protocol(m)) if m == "boom"));
    }
}
