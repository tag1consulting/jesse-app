//! **Shared plumbing** — the one HTTP client, the retry policy, redaction, the audit
//! line, the SSE framer, and the [`EventStream`] every adapter returns.
//!
//! Everything here is wire-AGNOSTIC. An adapter contributes exactly two things: the
//! request body (a `String` of JSON) and an [`SseDecoder`] that turns frames into
//! [`Event`]s. Retrying, timing, classification, cancellation, redaction and auditing are
//! written once. That split is what makes the conformance suite's "same behaviour on both
//! adapters" assertion meaningful — if each adapter had its own retry loop, the suite
//! would be asserting that two loops happen to agree today.

use std::fmt;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use futures_core::Stream;
use regex::Regex;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

use super::{Event, ProviderConfig, ProviderError, StopReason, Usage, Wire};

/// How many events may queue between the reader task and the caller before the reader
/// applies backpressure. Small on purpose: the reader holding a large backlog would let a
/// slow consumer keep the upstream connection open long after it stopped keeping up.
const EVENT_CHANNEL_DEPTH: usize = 64;

/// The cap on a provider's error message inside [`ProviderError::BadRequest`], in chars.
///
/// The same 200 `bridge/src/vision.rs` uses for its helper-error snippet, and for the same
/// reason: these bodies are meant to be short, an unbounded one ends up in a log line, and
/// truncation is the difference between a diagnostic and an incident.
const ERROR_SNIPPET_CHARS: usize = 200;

// ===========================================================================
// Redaction
// ===========================================================================

/// Strip anything key-shaped from text that is about to become an error string.
///
/// APPLIED TO EVERY PROVIDER-SUPPLIED STRING BEFORE IT ENTERS A `ProviderError`, without
/// exception. A provider's `400` body routinely echoes the request back, headers included;
/// several gateways echo the `Authorization` header verbatim in their own error prose.
/// Since [`ProviderError::BadRequest`] is designed to be logged, an unredacted body is a
/// token in a log file, which is the one outcome the whole layer is built to prevent.
///
/// Deliberately AGGRESSIVE, and it will sometimes redact a long identifier that was not a
/// secret. That trade is intentional: over-redacting costs a reader some context in an
/// error message, and under-redacting costs a credential.
pub fn redact(s: &str) -> String {
    struct Patterns {
        bearer: Regex,
        keyed: Regex,
        prefixed: Regex,
        long_run: Regex,
    }
    static PATTERNS: OnceLock<Patterns> = OnceLock::new();
    let p = PATTERNS.get_or_init(|| Patterns {
        // `Bearer <token>` in any casing, as it appears in an echoed header.
        bearer: Regex::new(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]{4,}").unwrap(),
        // `<key-ish name><separator><value>` — JSON, headers and query strings all fall
        // out of this one shape. The name is KEPT (it is the diagnostic) and only the
        // value goes.
        keyed: Regex::new(
            r#"(?i)\b(x-api-key|api[_-]?key|apikey|authorization|access[_-]?token|auth[_-]?token|token|secret|password)\b(["']?\s*[:=]\s*["']?)([^"'\s,;}&]{4,})"#,
        )
        .unwrap(),
        // Vendor-prefixed keys, which are recognisable well below the length cut-off
        // below and so would otherwise survive it.
        prefixed: Regex::new(r"\b(?:sk|pk|fw|xai|gsk|ghp|glpat|hf)[-_][A-Za-z0-9_\-]{8,}").unwrap(),
        // A bare high-entropy-shaped run. 40 is above every human identifier that shows
        // up in these bodies (model names, request ids are shorter or contain
        // punctuation) and at or below every credential format in use.
        long_run: Regex::new(r"\b[A-Za-z0-9_\-]{40,}\b").unwrap(),
    });

    let s = p.bearer.replace_all(s, "Bearer <redacted>");
    let s = p.keyed.replace_all(&s, "${1}${2}<redacted>");
    let s = p.prefixed.replace_all(&s, "<redacted>");
    let s = p.long_run.replace_all(&s, "<redacted>");
    s.into_owned()
}

/// Redact, then cap to [`ERROR_SNIPPET_CHARS`]. The order matters: capping first could cut
/// a credential in half and leave the first 200 characters of it in the log.
fn error_snippet(body: &str) -> String {
    let red = redact(body);
    if red.chars().count() <= ERROR_SNIPPET_CHARS {
        red
    } else {
        let mut out: String = red.chars().take(ERROR_SNIPPET_CHARS).collect();
        out.push('…');
        out
    }
}

// ===========================================================================
// The audit line
// ===========================================================================

/// What one call did, content-free.
///
/// Token COUNTS, a latency, a coarse stop reason and an attempt count — never the URL,
/// never the request or response body, never a token, never any model output. The same
/// discipline as `bridge/src/vision.rs`'s `VisionAudit`, and the field-per-fact shape is
/// taken from it directly.
///
/// DIVERGENCE FROM `vision.rs`, stated because it is visible: `vision.rs` BUILDS audit
/// records and lets its caller (`bridge/src/handlers.rs`) print them, so nothing in the
/// vision layer writes to stderr. This module prints as well as builds. The reason is that
/// the caller does not exist yet — D2's loop is what would do the printing, and a layer
/// that silently recorded audit data nobody emitted until D2 landed would make D1's live
/// smoke unobservable. Both halves are available: the record reaches the caller through
/// [`EventStream::audit`], so when D2 wants to own the emission it takes the handle and
/// this `eprintln!` becomes the thing to delete.
#[derive(Debug, Clone, PartialEq)]
pub struct CallAudit {
    pub wire: Wire,
    pub model: String,
    /// [`super::Request::request_tag`], echoed for correlation. Caller-chosen, so it is
    /// the caller's job not to put content in it.
    pub request_tag: String,
    /// Wall-clock for the whole call INCLUDING every retry and backoff — what the caller
    /// actually waited, not what the successful attempt took.
    pub latency_ms: u64,
    /// Which attempt produced this outcome. `1` means it worked first time; the
    /// conformance suite asserts on this to prove a retry happened.
    pub attempt: u32,
    pub stop_reason: Option<StopReason>,
    /// [`ProviderError::class`] when the call failed, else `None`.
    pub error_class: Option<&'static str>,
    pub usage: Option<Usage>,
}

impl CallAudit {
    /// The stderr line, in the `key=value` shape the bridge's own audit lines use.
    ///
    /// Pure, so the line's content is unit-testable without making a call — the same
    /// reason `health.rs` splits `classify_probe_status` out of its probe.
    pub fn render(&self) -> String {
        let u = self.usage.clone().unwrap_or_default();
        let tok = |v: Option<u64>| v.map(|n| n.to_string()).unwrap_or_else(|| "-".into());
        format!(
            "jesse-agent: call wire={} model={:?} tag={:?} attempt={} latency_ms={} \
             stop={} in_tok={} out_tok={} cache_read_tok={} cache_write_tok={} \
             reason_tok={}{}",
            self.wire,
            self.model,
            self.request_tag,
            self.attempt,
            self.latency_ms,
            self.stop_reason
                .as_ref()
                .map(|s| format!("{s:?}"))
                .unwrap_or_else(|| "-".into()),
            tok(u.input_tokens),
            tok(u.output_tokens),
            tok(u.cache_read_tokens),
            tok(u.cache_write_tokens),
            // A SUBSET of `out_tok`, not a fifth disjoint count — see `Usage`. It is on
            // the line anyway because "how much of that output was thinking" is the first
            // thing anyone asks of a reasoning model's audit trail, and a dash where the
            // wire reports no breakdown says so honestly.
            tok(u.reasoning_tokens),
            self.error_class
                .map(|c| format!(" error_class={c}"))
                .unwrap_or_default(),
        )
    }
}

/// A write-once slot the reader task fills when a call finishes.
///
/// Exists so D2's loop can take the audit record for its own turn metrics instead of
/// re-deriving latency and tokens by watching the event stream. Cloneable and cheap; the
/// stream holds one end and the caller may keep the other past the stream's lifetime.
#[derive(Clone, Default)]
pub struct AuditHandle(Arc<Mutex<Option<CallAudit>>>);

impl AuditHandle {
    /// The record, once the call has finished. `None` while it is still running.
    pub fn get(&self) -> Option<CallAudit> {
        self.0.lock().ok().and_then(|g| g.clone())
    }

    fn set(&self, audit: CallAudit) {
        if let Ok(mut g) = self.0.lock() {
            *g = Some(audit);
        }
    }
}

impl fmt::Debug for AuditHandle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("AuditHandle").field(&self.get()).finish()
    }
}

/// Build the record, publish it to the handle, and print it.
fn finish_call(handle: &AuditHandle, audit: CallAudit) {
    eprintln!("{}", audit.render());
    handle.set(audit);
}

// ===========================================================================
// The event stream
// ===========================================================================

/// The stream of [`Event`]s from one call.
///
/// Backed by a channel fed by a detached reader task rather than by a future that owns the
/// HTTP response directly. The reason is cancellation: the task can `select!` on the
/// [`CancellationToken`] while it is blocked on the socket, emit
/// [`ProviderError::Cancelled`], and DROP the response — which closes the connection, so
/// the provider stops generating and stops billing. A hand-rolled `Stream` that only
/// checked the token when the caller polled it would leave a cancelled call streaming
/// until the caller happened to ask again, which for a caller that has moved on is
/// forever.
pub struct EventStream {
    rx: mpsc::Receiver<Event>,
    task: JoinHandle<()>,
    audit: AuditHandle,
}

impl EventStream {
    /// The next event, or `None` once the stream has ended.
    ///
    /// Named `recv`, not `next`, so it can never be confused with (or shadowed by) a
    /// `StreamExt::next` a caller has in scope. The [`Stream`] impl is the composable
    /// form; this is the one the tests and simple callers use.
    pub async fn recv(&mut self) -> Option<Event> {
        self.rx.recv().await
    }

    /// The audit record for this call, filled in when it finishes.
    pub fn audit(&self) -> AuditHandle {
        self.audit.clone()
    }

    /// Build a stream over a FIXED event sequence, for a [`super::Provider`] that speaks
    /// no HTTP.
    ///
    /// ADDED IN D2 for `provider::scripted`, and gated to the same `cfg` that module is,
    /// so it exists in a release build exactly as often as its only caller does: never.
    /// The alternative was making `EventStream`'s fields `pub(crate)` and letting the
    /// scripted provider assemble one — which would have put the invariant that the
    /// receiver and the task belong together in a second place, where nothing enforces it.
    ///
    /// The reader task honours `cancel` between events, so a scripted call is cancellable
    /// at the same granularity a real one is (`http::start_call` selects on the token while
    /// blocked on the socket; this selects on it while blocked on the channel). Without
    /// that, a cancellation test could pass on the scripted provider and fail on a wire.
    ///
    /// The audit is published WITHOUT printing the stderr line a real call prints: this is
    /// not a call anyone was billed for, and a suite of loop tests emitting audit lines for
    /// imaginary calls is how a real one stops being noticed.
    #[cfg(any(test, feature = "scripted"))]
    pub(crate) fn scripted(
        events: Vec<Event>,
        audit: CallAudit,
        cancel: CancellationToken,
    ) -> EventStream {
        let (tx, rx) = mpsc::channel(EVENT_CHANNEL_DEPTH);
        let task = tokio::spawn(async move {
            for event in events {
                if cancel.is_cancelled() {
                    let _ = tx.send(Event::Error(ProviderError::Cancelled)).await;
                    return;
                }
                if tx.send(event).await.is_err() {
                    return; // the caller dropped the stream
                }
            }
        });
        let handle = AuditHandle::default();
        handle.set(audit);
        EventStream {
            rx,
            task,
            audit: handle,
        }
    }
}

impl Stream for EventStream {
    type Item = Event;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Event>> {
        self.get_mut().rx.poll_recv(cx)
    }
}

impl Drop for EventStream {
    /// Dropping the stream aborts the reader, which drops the response and closes the
    /// connection. Without this, abandoning a stream would leave the provider generating
    /// into a channel nobody reads.
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl fmt::Debug for EventStream {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EventStream").finish_non_exhaustive()
    }
}

// ===========================================================================
// SSE framing
// ===========================================================================

/// Splits a byte stream into SSE frames' `data` payloads.
///
/// ONE FRAMER SERVES BOTH WIRES, and the `event:` line is deliberately IGNORED. The
/// Anthropic wire sends both an `event:` name and a `data:` payload whose JSON carries the
/// same name in its `type` field; the OpenAI wire sends no `event:` line at all. Parsing
/// the payload's own `type` therefore works on both, while dispatching on `event:` works
/// on one and would need a second code path for the other. It is also the safer of the
/// two when they disagree: the payload is what the rest of the frame has to be interpreted
/// as, so trusting the envelope over the content would be trusting the half that is not
/// used.
#[derive(Default)]
pub(crate) struct SseFramer {
    /// Bytes not yet resolved into a complete line.
    pending: Vec<u8>,
    /// `data:` values accumulated for the frame currently being read.
    data: String,
    /// Whether any field line has been seen since the last dispatch.
    in_frame: bool,
}

impl SseFramer {
    /// Feed raw bytes; returns the `data` payload of every frame that completed.
    ///
    /// Splitting on `\n` before decoding UTF-8 is safe by construction: no byte of a
    /// multi-byte UTF-8 sequence can be `0x0A`, so a line boundary is never inside a
    /// character. That is what lets this accept arbitrarily chunked input — which the
    /// conformance suite exercises by splitting a tool call's arguments across three
    /// writes.
    pub(crate) fn feed(&mut self, chunk: &[u8]) -> Vec<String> {
        self.pending.extend_from_slice(chunk);
        let mut out = Vec::new();
        while let Some(nl) = self.pending.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=nl).collect();
            let line = String::from_utf8_lossy(&line[..line.len() - 1]);
            let line = line.strip_suffix('\r').unwrap_or(&line);
            if let Some(frame) = self.line(line) {
                out.push(frame);
            }
        }
        out
    }

    /// Dispatch a final frame that arrived without its terminating blank line.
    ///
    /// Lenient by decision: the SSE spec dispatches on a blank line, but real servers
    /// (and every one of them at a connection close) routinely omit the last one. Treating
    /// that as a dropped frame would turn a complete answer into a
    /// [`ProviderError::Protocol`] on a technicality.
    pub(crate) fn finish(&mut self) -> Option<String> {
        if !self.pending.is_empty() {
            let line = String::from_utf8_lossy(&self.pending).to_string();
            let line = line.strip_suffix('\r').unwrap_or(&line).to_string();
            self.pending.clear();
            if let Some(frame) = self.line(&line) {
                return Some(frame);
            }
        }
        if self.in_frame {
            self.in_frame = false;
            return Some(std::mem::take(&mut self.data));
        }
        None
    }

    /// Process one line; `Some(payload)` when it completed a frame.
    fn line(&mut self, line: &str) -> Option<String> {
        if line.is_empty() {
            if self.in_frame {
                self.in_frame = false;
                return Some(std::mem::take(&mut self.data));
            }
            return None;
        }
        // A line beginning with ':' is a comment (this is how a keep-alive is sent).
        if line.starts_with(':') {
            return None;
        }
        let (field, value) = match line.split_once(':') {
            Some((f, v)) => (f, v.strip_prefix(' ').unwrap_or(v)),
            None => (line, ""),
        };
        self.in_frame = true;
        // Only `data` is consumed; `event`, `id` and `retry` are read past. See the type
        // doc for why `event` in particular is ignored rather than dispatched on.
        if field == "data" {
            if !self.data.is_empty() {
                self.data.push('\n');
            }
            self.data.push_str(value);
        }
        None
    }
}

// ===========================================================================
// The per-wire decoder
// ===========================================================================

/// An adapter's half of the streaming contract: turn one SSE frame payload into events.
///
/// Errors are PUSHED as [`Event::Error`] rather than returned, so a decoder can emit the
/// text it did receive before reporting that the stream then broke. The reader treats
/// `Error` and `Done` identically as terminal.
pub(crate) trait SseDecoder: Send {
    /// Handle one frame's `data` payload.
    fn on_frame(&mut self, data: &str, out: &mut Vec<Event>);

    /// The byte stream ended. A decoder that has not yet emitted a terminal event must
    /// push one here — [`ProviderError::Protocol`] if it never saw its wire's terminator.
    fn on_eof(&mut self, out: &mut Vec<Event>);
}

// ===========================================================================
// Client construction
// ===========================================================================

/// One client per provider, built once and cloned per call.
///
/// A client owns a connection pool, so building one per call would give up connection
/// reuse and pay a TLS handshake on every turn. Falls back to the default client if the
/// builder fails, mirroring `ReqwestProbe::new` and `vision_client` in the bridge — a
/// provider that cannot build its preferred client should still make calls with a stock
/// one rather than fail to construct.
pub(crate) fn build_client(cfg: &ProviderConfig) -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(cfg.timeouts.connect)
        .build()
        .unwrap_or_default()
}

// ===========================================================================
// Retry policy
// ===========================================================================

/// Cheap jitter in `[0, 1)`.
///
/// NOT cryptographic and not trying to be. Its whole job is to stop N callers that were
/// throttled by the same `429` from re-sending in the same millisecond. A `rand`
/// dependency for that would be a dependency for one `f64`, so this is an xorshift over a
/// counter mixed with the clock — enough spread for a thundering herd, and no more is
/// claimed for it.
fn jitter() -> f64 {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u64)
        .unwrap_or(0);
    let mut x = n
        .wrapping_mul(0x9E37_79B9_7F4A_7C15)
        .wrapping_add(nanos)
        .max(1);
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    (x >> 11) as f64 / (1u64 << 53) as f64
}

/// How long to wait before attempt `attempt + 1` (1-based `attempt`).
///
/// FULL JITTER over an exponential backoff: `uniform(0, min(max, base * 2^(attempt-1)))`.
/// The un-jittered exponential was rejected for the usual reason — it synchronises
/// retries rather than spreading them — and half-jitter was rejected because the floor it
/// keeps buys nothing here.
///
/// A `retry-after` from the provider OVERRIDES all of it, un-jittered. When a provider
/// states when it will serve again, guessing a different number is worse than obeying: too
/// early earns another `429`, too late wastes the turn.
fn backoff_delay(cfg: &ProviderConfig, attempt: u32, retry_after: Option<Duration>) -> Duration {
    if let Some(ra) = retry_after {
        return ra.min(cfg.retries.max_backoff);
    }
    let shift = attempt.saturating_sub(1).min(16);
    let ceiling = cfg
        .retries
        .base_backoff
        .saturating_mul(1u32 << shift)
        .min(cfg.retries.max_backoff);
    ceiling.mul_f64(jitter())
}

/// `retry-after` as a duration. SECONDS ONLY: the HTTP-date form is legal but neither wire
/// in use sends it, and a date needs a clock comparison whose failure mode (a skewed
/// client waiting hours) is worse than falling back to the computed backoff.
fn parse_retry_after(headers: &reqwest::header::HeaderMap) -> Option<Duration> {
    headers
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse::<u64>()
        .ok()
        .map(Duration::from_secs)
}

/// Map a response status to an error.
///
/// Mirrors `bridge/src/health.rs`'s `classify_probe_status` where the two ask the same
/// question, and diverges where they do not — see [`ProviderError`]'s doc for the full
/// comparison. In particular every `>= 500` collapses to
/// [`ProviderError::Overloaded`]: `health.rs` has one `http-5xx` class for the same range,
/// and splitting `500`/`502`/`504` out here would create classes that differ in name but
/// not in what anyone does about them (all retryable, all server-side).
fn classify_status(
    status: u16,
    headers: &reqwest::header::HeaderMap,
    body: &str,
) -> Option<ProviderError> {
    match status {
        s if s < 400 => None,
        401 | 403 => Some(ProviderError::Auth),
        404 => Some(ProviderError::NotFound),
        429 => Some(ProviderError::RateLimited {
            retry_after: parse_retry_after(headers),
        }),
        503 | 529 => Some(ProviderError::Overloaded),
        s if s >= 500 => Some(ProviderError::Overloaded),
        _ => Some(ProviderError::BadRequest(error_snippet(body))),
    }
}

/// Classify a `reqwest` transport failure, using the same three classes `health.rs` and
/// `vision.rs` both record (`timeout` / `connect` / `transport`).
fn classify_transport(e: &reqwest::Error) -> ProviderError {
    if e.is_timeout() {
        ProviderError::Timeout
    } else {
        // `is_connect()` and everything else both mean the same thing to the retry policy;
        // the distinction survives only in the error class the bridge's probe records.
        ProviderError::Transport
    }
}

// ===========================================================================
// The call
// ===========================================================================

/// Make one streaming call: retry until a response's headers arrive, then hand the body to
/// `decoder` on a reader task.
///
/// THE RETRY BOUNDARY IS THE RESPONSE HEAD, and that is the decision this function
/// encodes. Retrying is only safe while the caller has seen nothing: once a `TextDelta`
/// has been delivered, a retry would replay the answer from the beginning and the caller
/// would have to detect and discard a prefix it cannot identify. So every attempt happens
/// inside this future, before [`EventStream`] exists — and a failure after it exists
/// surfaces as [`Event::Error`] on the stream, for D2's loop to decide about with the
/// partial answer in hand.
///
/// The rejected alternative was buffering events until the stream proved itself and
/// retrying under the covers. It costs the streaming property — nothing could be shown
/// until the turn was safe to replay, which on a long answer is the entire turn.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn start_call(
    cfg: &ProviderConfig,
    client: &reqwest::Client,
    path: &str,
    body: String,
    request_tag: &str,
    mut make_decoder: impl FnMut() -> Box<dyn SseDecoder>,
    cancel: CancellationToken,
) -> Result<EventStream, ProviderError> {
    let started = Instant::now();
    let url = cfg.endpoint(path);
    let audit = AuditHandle::default();
    let mut attempt: u32 = 0;

    let response = loop {
        attempt += 1;
        if cancel.is_cancelled() {
            return Err(fail(
                cfg,
                &audit,
                request_tag,
                started,
                attempt,
                ProviderError::Cancelled,
            ));
        }

        let mut req = client
            .post(&url)
            .header("content-type", "application/json")
            .header("accept", "text/event-stream");
        if let Some((name, value)) = cfg.auth.header() {
            req = req.header(name, value);
        }
        for (name, value) in &cfg.extra_headers {
            req = req.header(name.as_str(), value.as_str());
        }
        req = req.body(body.clone());

        // The budget covers the HEAD of the response only — see `Timeouts::overall`.
        let sent = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                return Err(fail(cfg, &audit, request_tag, started, attempt, ProviderError::Cancelled));
            }
            r = tokio::time::timeout(cfg.timeouts.overall, req.send()) => r,
        };

        let err = match sent {
            Err(_elapsed) => ProviderError::Timeout,
            Ok(Err(e)) => classify_transport(&e),
            Ok(Ok(resp)) => {
                let status = resp.status().as_u16();
                let headers = resp.headers().clone();
                // The body is read ONLY to classify a failure. On success it stays
                // unread, because it is the stream.
                if status < 400 {
                    break resp;
                }
                let body_text = resp.text().await.unwrap_or_default();
                match classify_status(status, &headers, &body_text) {
                    Some(e) => e,
                    // Unreachable: `classify_status` returns `None` only for `< 400`,
                    // which broke out above. Treated as a protocol violation rather than
                    // `unreachable!()` so a future edit to the classifier cannot panic
                    // the process.
                    None => ProviderError::Protocol("status classified inconsistently".into()),
                }
            }
        };

        let last_attempt = attempt >= cfg.retries.max_attempts.max(1);
        if !err.is_retryable() || last_attempt {
            return Err(fail(cfg, &audit, request_tag, started, attempt, err));
        }

        let retry_after = match &err {
            ProviderError::RateLimited { retry_after } => *retry_after,
            _ => None,
        };
        let delay = backoff_delay(cfg, attempt, retry_after);
        tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                return Err(fail(cfg, &audit, request_tag, started, attempt, ProviderError::Cancelled));
            }
            _ = tokio::time::sleep(delay) => {}
        }
    };

    let (tx, rx) = mpsc::channel(EVENT_CHANNEL_DEPTH);
    let decoder = make_decoder();
    let task = tokio::spawn(read_stream(
        response,
        decoder,
        tx,
        cancel,
        audit.clone(),
        AuditContext {
            wire: cfg.wire,
            model: cfg.model.clone(),
            request_tag: request_tag.to_string(),
            started,
            attempt,
        },
    ));

    Ok(EventStream { rx, task, audit })
}

/// The constant half of the audit record, carried into the reader task.
struct AuditContext {
    wire: Wire,
    model: String,
    request_tag: String,
    started: Instant,
    attempt: u32,
}

/// Emit the audit line for a call that failed before it produced a stream, and hand the
/// error back for `start_call` to return.
fn fail(
    cfg: &ProviderConfig,
    audit: &AuditHandle,
    request_tag: &str,
    started: Instant,
    attempt: u32,
    err: ProviderError,
) -> ProviderError {
    finish_call(
        audit,
        CallAudit {
            wire: cfg.wire,
            model: cfg.model.clone(),
            request_tag: request_tag.to_string(),
            latency_ms: started.elapsed().as_millis() as u64,
            attempt,
            stop_reason: None,
            error_class: Some(err.class()),
            usage: None,
        },
    );
    err
}

/// Pump the response body through the decoder and into the channel.
async fn read_stream(
    mut response: reqwest::Response,
    mut decoder: Box<dyn SseDecoder>,
    tx: mpsc::Sender<Event>,
    cancel: CancellationToken,
    audit: AuditHandle,
    ctx: AuditContext,
) {
    let mut framer = SseFramer::default();
    let mut usage: Option<Usage> = None;
    let mut stop_reason: Option<StopReason> = None;
    let mut error_class: Option<&'static str> = None;
    let mut terminal = false;

    'outer: loop {
        let chunk = tokio::select! {
            biased;
            _ = cancel.cancelled() => {
                // Emitting BEFORE dropping the response is deliberate: the caller learns
                // the call is over even if the socket takes a moment to close.
                let _ = tx.send(Event::Error(ProviderError::Cancelled)).await;
                error_class = Some(ProviderError::Cancelled.class());
                break 'outer;
            }
            c = response.chunk() => c,
        };

        let mut events: Vec<Event> = Vec::new();
        match chunk {
            Ok(Some(bytes)) => {
                for frame in framer.feed(&bytes) {
                    decoder.on_frame(&frame, &mut events);
                }
            }
            Ok(None) => {
                if let Some(frame) = framer.finish() {
                    decoder.on_frame(&frame, &mut events);
                }
                decoder.on_eof(&mut events);
                terminal = true;
            }
            Err(e) => {
                let err = classify_transport(&e);
                error_class = Some(err.class());
                events.push(Event::Error(err));
                terminal = true;
            }
        }

        for ev in events {
            match &ev {
                Event::Usage(u) => usage = Some(u.clone()),
                Event::Done { stop_reason: s } => {
                    stop_reason = Some(s.clone());
                    terminal = true;
                }
                Event::Error(e) => {
                    error_class = Some(e.class());
                    terminal = true;
                }
                _ => {}
            }
            if tx.send(ev).await.is_err() {
                // The caller dropped the stream. Stop reading and stop the provider
                // generating; the audit still records what was seen.
                break 'outer;
            }
        }

        if terminal {
            break 'outer;
        }
    }

    // Dropping the response closes the connection, which is what a cancelled or abandoned
    // call needs the peer to observe.
    drop(response);

    finish_call(
        &audit,
        CallAudit {
            wire: ctx.wire,
            model: ctx.model,
            request_tag: ctx.request_tag,
            latency_ms: ctx.started.elapsed().as_millis() as u64,
            attempt: ctx.attempt,
            stop_reason,
            error_class,
            usage,
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{AuthScheme, Wire};

    /// Fake credentials are BUILT AT RUNTIME rather than written as literals so this file
    /// carries nothing key-shaped for a secret scanner (`ci-guards.sh` runs gitleaks over
    /// the tracked tree) to find. A repeated character is also zero-entropy, so it cannot
    /// look like a real credential to anything.
    fn fake_secret() -> String {
        "A".repeat(44)
    }

    #[test]
    fn redaction_strips_a_bearer_header_echoed_in_an_error_body() {
        let body = format!("invalid header: Authorization: Bearer {}", fake_secret());
        let out = redact(&body);
        assert!(!out.contains(&fake_secret()), "token survived: {out}");
        // The `keyed` rule runs after the `bearer` rule and swallows the whole value,
        // scheme word included, leaving `Authorization: <redacted>`. Asserted on the
        // PROPERTY (secret gone, field name kept) rather than on the exact rendering,
        // because which of the two overlapping rules wins is an implementation detail and
        // the guarantee is not.
        assert!(
            out.contains("Authorization"),
            "the field name is kept: {out}"
        );
        assert!(out.contains("<redacted>"), "something was redacted: {out}");
    }

    #[test]
    fn redaction_strips_a_bare_bearer_with_no_header_name_in_front_of_it() {
        // The case the `bearer` rule exists for on its own: prose that quotes the scheme
        // and the token without the `Authorization:` prefix the `keyed` rule needs.
        let out = redact(&format!("expected 'Bearer {}' to be valid", fake_secret()));
        assert!(!out.contains(&fake_secret()), "token survived: {out}");
        assert!(out.contains("Bearer <redacted>"), "{out}");
    }

    #[test]
    fn redaction_keeps_the_key_name_and_drops_the_value() {
        let body = format!(r#"{{"api_key": "{}", "model": "m"}}"#, fake_secret());
        let out = redact(&body);
        assert!(!out.contains(&fake_secret()));
        assert!(
            out.contains("api_key"),
            "the field name is the diagnostic: {out}"
        );
        assert!(out.contains("model"), "unrelated fields survive: {out}");
    }

    #[test]
    fn redaction_catches_a_vendor_prefixed_key_below_the_length_cutoff() {
        // Short enough that the bare-run rule would miss it; the prefix rule catches it.
        let short = format!("sk-{}", "b".repeat(12));
        let out = redact(&format!("bad key {short} rejected"));
        assert!(!out.contains(&short), "prefixed key survived: {out}");
        assert!(out.contains("<redacted>"));
    }

    #[test]
    fn redaction_leaves_ordinary_prose_alone() {
        let msg = "model: unknown model 'gpt-nope' for this endpoint";
        assert_eq!(redact(msg), msg);
    }

    #[test]
    fn an_error_snippet_redacts_before_it_truncates() {
        // A secret positioned past the cap: truncating first would leave its prefix in.
        let body = format!("{} Bearer {}", "x".repeat(190), fake_secret());
        let out = error_snippet(&body);
        assert!(out.chars().count() <= ERROR_SNIPPET_CHARS + 1);
        assert!(!out.contains("AAAA"), "a truncated secret leaked: {out}");
    }

    #[test]
    fn status_classification_matches_the_documented_table() {
        let h = reqwest::header::HeaderMap::new();
        assert_eq!(classify_status(200, &h, ""), None);
        assert_eq!(classify_status(401, &h, ""), Some(ProviderError::Auth));
        assert_eq!(classify_status(403, &h, ""), Some(ProviderError::Auth));
        assert_eq!(classify_status(404, &h, ""), Some(ProviderError::NotFound));
        assert_eq!(
            classify_status(429, &h, ""),
            Some(ProviderError::RateLimited { retry_after: None })
        );
        assert_eq!(
            classify_status(503, &h, ""),
            Some(ProviderError::Overloaded)
        );
        assert_eq!(
            classify_status(529, &h, ""),
            Some(ProviderError::Overloaded)
        );
        assert_eq!(
            classify_status(500, &h, ""),
            Some(ProviderError::Overloaded)
        );
        // Any other 4xx is the request's fault and is NOT retried.
        assert!(matches!(
            classify_status(400, &h, "bad model"),
            Some(ProviderError::BadRequest(_))
        ));
        assert!(matches!(
            classify_status(422, &h, "nope"),
            Some(ProviderError::BadRequest(_))
        ));
    }

    #[test]
    fn a_bad_request_message_is_redacted_on_the_way_into_the_error() {
        let h = reqwest::header::HeaderMap::new();
        let body = format!("rejected token {}", fake_secret());
        match classify_status(400, &h, &body) {
            Some(ProviderError::BadRequest(m)) => {
                assert!(!m.contains(&fake_secret()), "token reached the error: {m}")
            }
            other => panic!("expected BadRequest, got {other:?}"),
        }
    }

    #[test]
    fn retry_after_is_read_in_seconds_and_ignored_when_it_is_a_date() {
        let mut h = reqwest::header::HeaderMap::new();
        h.insert("retry-after", "7".parse().unwrap());
        assert_eq!(parse_retry_after(&h), Some(Duration::from_secs(7)));
        h.insert(
            "retry-after",
            "Wed, 21 Oct 2026 07:28:00 GMT".parse().unwrap(),
        );
        assert_eq!(parse_retry_after(&h), None);
    }

    #[test]
    fn retry_after_overrides_the_computed_backoff_and_is_capped() {
        let mut cfg = ProviderConfig::new(Wire::Chat, "http://h", "m", AuthScheme::None);
        cfg.retries.max_backoff = Duration::from_secs(20);
        assert_eq!(
            backoff_delay(&cfg, 1, Some(Duration::from_secs(3))),
            Duration::from_secs(3)
        );
        // A provider asking for longer than the configured ceiling is capped, not obeyed.
        assert_eq!(
            backoff_delay(&cfg, 1, Some(Duration::from_secs(600))),
            Duration::from_secs(20)
        );
    }

    #[test]
    fn backoff_grows_exponentially_and_stays_under_the_ceiling() {
        let mut cfg = ProviderConfig::new(Wire::Chat, "http://h", "m", AuthScheme::None);
        cfg.retries.base_backoff = Duration::from_millis(100);
        cfg.retries.max_backoff = Duration::from_millis(800);
        for attempt in 1..=8u32 {
            let ceiling = Duration::from_millis(100 * (1u64 << (attempt - 1).min(16)))
                .min(cfg.retries.max_backoff);
            for _ in 0..32 {
                let d = backoff_delay(&cfg, attempt, None);
                assert!(
                    d <= ceiling,
                    "attempt {attempt}: {d:?} exceeded {ceiling:?}"
                );
                assert!(d <= cfg.retries.max_backoff);
            }
        }
    }

    #[test]
    fn jitter_actually_spreads() {
        // Not a distribution test — just proof it is not a constant, which is the only
        // property the backoff relies on.
        let mut seen = std::collections::HashSet::new();
        for _ in 0..64 {
            seen.insert((jitter() * 1e9) as u64);
        }
        assert!(seen.len() > 1, "jitter returned a constant");
    }

    #[test]
    fn the_framer_reassembles_a_frame_split_across_chunks() {
        let mut f = SseFramer::default();
        assert!(f.feed(b"data: {\"a\":").is_empty());
        assert!(f.feed(b"1}").is_empty());
        let frames = f.feed(b"\n\n");
        assert_eq!(frames, vec![r#"{"a":1}"#.to_string()]);
    }

    #[test]
    fn the_framer_ignores_event_lines_comments_and_crlf() {
        let mut f = SseFramer::default();
        let frames = f.feed(b": keep-alive\r\nevent: message_start\r\ndata: {\"x\":1}\r\n\r\n");
        assert_eq!(frames, vec![r#"{"x":1}"#.to_string()]);
    }

    #[test]
    fn the_framer_joins_multiple_data_lines_with_a_newline() {
        let mut f = SseFramer::default();
        let frames = f.feed(b"data: one\ndata: two\n\n");
        assert_eq!(frames, vec!["one\ntwo".to_string()]);
    }

    #[test]
    fn the_framer_dispatches_a_final_frame_with_no_trailing_blank_line() {
        let mut f = SseFramer::default();
        assert!(f.feed(b"data: [DONE]\n").is_empty());
        assert_eq!(f.finish(), Some("[DONE]".to_string()));
        assert_eq!(f.finish(), None, "finish is not repeatable");
    }

    #[test]
    fn the_framer_survives_a_multibyte_character_split_across_chunks() {
        let s = "café ☕";
        let bytes = format!("data: {s}\n\n").into_bytes();
        for split in 1..bytes.len() {
            let mut f = SseFramer::default();
            let mut frames = f.feed(&bytes[..split]);
            frames.extend(f.feed(&bytes[split..]));
            assert_eq!(frames, vec![s.to_string()], "split at {split}");
        }
    }

    #[test]
    fn the_audit_line_carries_counts_and_never_a_url_or_body() {
        let audit = CallAudit {
            wire: Wire::Messages,
            model: "some-model".into(),
            request_tag: "turn-1".into(),
            latency_ms: 1234,
            attempt: 2,
            stop_reason: Some(StopReason::ToolUse),
            error_class: None,
            usage: Some(Usage {
                input_tokens: Some(10),
                output_tokens: Some(4),
                cache_read_tokens: Some(900),
                cache_write_tokens: None,
                reasoning_tokens: Some(3),
                provider_request_id: Some("req_1".into()),
            }),
        };
        let line = audit.render();
        assert!(line.starts_with("jesse-agent: call wire=messages"));
        assert!(line.contains("attempt=2"));
        assert!(line.contains("latency_ms=1234"));
        assert!(line.contains("stop=ToolUse"));
        assert!(line.contains("in_tok=10"));
        assert!(line.contains("cache_read_tok=900"));
        // An absent count is a dash, never a zero — `None` and `0` mean different things
        // to a cost model.
        assert!(line.contains("cache_write_tok=-"));
        assert!(line.contains("reason_tok=3"));
        assert!(!line.contains("http"), "no URL in the audit line: {line}");
    }

    #[test]
    fn a_failed_call_records_its_error_class() {
        let audit = CallAudit {
            wire: Wire::Chat,
            model: "m".into(),
            request_tag: String::new(),
            latency_ms: 5,
            attempt: 3,
            stop_reason: None,
            error_class: Some(ProviderError::Overloaded.class()),
            usage: None,
        };
        let line = audit.render();
        assert!(line.contains("error_class=overloaded"));
        assert!(line.contains("stop=-"));
    }
}
