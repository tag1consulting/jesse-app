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
