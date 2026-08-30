//! **Per-turn tracing** — what a turn had produced when it died, and where its hour went.
//!
//! Two problems, one observation point. A turn killed at [`Config::timeout_secs`] used to
//! surface as a bare `504` naming the env var: everything the agent had already written to
//! disk was invisible to the client, and nothing anywhere recorded how the time was spent,
//! so diagnosing a slow turn meant reading git commit timestamps by hand.
//!
//! [`TurnTrace`] rides along with the driver ([`run_claude_streaming`]) and observes the
//! same [`StreamEvent`]s it already reads:
//!
//!   * **A bounded ring of assistant text blocks** — the last [`Config::partial_blocks`]
//!     blocks, capped at [`Config::partial_bytes`] bytes. When the run limit kills the
//!     turn, that text rides out on the job as a [`PartialTurn`] ("the turn was cut off,
//!     here is how far it got") rather than being thrown away. A BLOCK here is a run of
//!     text deltas uninterrupted by a tool call — the harness reports no block boundary of
//!     its own, and a tool call is exactly where the visible answer pauses.
//!   * **A tool-call timeline** — one entry per call, with the name and how long it held
//!     the turn, written out as a [`TurnTiming`] line per turn ([`TurnTimingLog`]).
//!
//! **The timing record is content-free.** Tool names, counts and durations only — never
//! the question, the answer, or the retained partial text. The partial text is content and
//! lives ONLY on the job (in memory + the job's own result file, both of which already
//! hold the reply), never in the timing log. A test asserts this.
//!
//! Both are best-effort and infallible from the caller's view: a poisoned lock, a full
//! disk or an unwritable state dir logs to stderr and never disturbs the reply.

use crate::*;
use std::collections::VecDeque;

/// How many assistant text blocks the partial-answer ring retains (env
/// `JESSE_PARTIAL_BLOCKS`). Eight is enough to carry the shape of a long turn's visible
/// work — the narration around its last several tool calls — without holding a transcript.
pub const DEFAULT_PARTIAL_BLOCKS: usize = 8;

/// Byte cap on the retained partial text (env `JESSE_PARTIAL_BYTES`). 16 KB is roughly
/// four screens of prose: enough to see what the turn got done, small enough that a
/// timed-out turn's failure body stays a failure body.
pub const DEFAULT_PARTIAL_BYTES: usize = 16 * 1024;

/// The append-only per-turn timing log under the bridge state dir, one JSON line per turn.
pub const TURN_TIMING_FILE: &str = "turn-timings.jsonl";

/// Records older than this are pruned from the log at startup. A week covers "what
/// happened to that turn on Friday" and keeps the file small enough to load whole.
pub const TIMING_RETENTION_DAYS: u64 = 7;

/// Cap on the timing records held in memory for [`TurnTimingLog::get`]. The startup prune
/// bounds the FILE; this bounds a long-lived process that never restarts. The newest
/// records win — an old job id is long past retrieval by the time it is evicted.
pub const MAX_TIMING_RECORDS_IN_MEMORY: usize = 1000;

// ---- What a cut-off turn hands back ---------------------------------------

/// How far a turn got before its run limit killed it: the retained tail of the visible
/// answer, the seconds it ran, and the tool calls observed.
///
/// Carried on [`JobState::Failed`] and surfaced as the `partial` field of
/// `GET /jesse/result/{id}`, alongside — never instead of — the error. The client renders
/// it as "the turn was cut off, here is how far it got"; the error string and its status
/// are untouched, so failure CLASSIFICATION (retry behavior) is exactly what it was.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct PartialTurn {
    /// The retained assistant text, oldest retained block first, blocks joined by a blank
    /// line. Empty when the turn was killed before it said anything visible.
    pub text: String,
    /// Wall seconds from the start of the turn (after the queue wait) to the kill.
    pub elapsed_secs: u64,
    /// Tool calls observed on the stream. Counts EVERY call, including ones whose text
    /// blocks the ring has since dropped.
    pub tool_calls: usize,
    /// Whether the ring dropped or trimmed anything — i.e. `text` is not the whole of
    /// what the turn said. Lets the client show an ellipsis honestly.
    pub truncated: bool,
}

// ---- The timing record ----------------------------------------------------

/// One tool call: which tool, and how long it held the turn.
///
/// The duration is measured from the call's `tool_use` block start to the NEXT event the
/// stream produced (more text, the next tool call, or the terminal result). The harness
/// emits no tool-completion event, so this is the honest measurement available: the gap
/// during which that call was the only thing happening.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ToolCallTiming {
    pub tool: String,
    pub ms: u64,
}

/// The per-turn timing record: one line of `turn-timings.jsonl`, keyed by job id.
///
/// This is the data that makes the next slow turn diagnosable in one command
/// (`grep <job_id> ~/.jesse-bridge/turn-timings.jsonl | jq`) instead of an hour of
/// forensics. Content-free by construction — see the module docs.
// `Eq` is gone with the arrival of `cost_usd`: a dollar amount is an `f64` and `f64` is not
// `Eq`. Nothing compared two timing records for equality outside the tests, which use
// `assert_eq!` on `PartialEq` and are unaffected.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct TurnTiming {
    /// Schema version, so a later shape change can be told apart on sight.
    pub v: u8,
    pub job_id: String,
    /// RFC3339 UTC, fixed width — which makes the retention prune a STRING comparison
    /// against `rfc3339_utc(now - 7d)` rather than a date parse.
    pub started_at: String,
    pub ended_at: String,
    pub elapsed_ms: u64,
    /// `done` / `failed` / `cancelled`, plus `aborted` (the task's teardown ran while the
    /// job was still Running — killed from outside) and `unknown` (the job was evicted out
    /// from under the turn).
    pub status: String,
    /// Total tool calls observed on the agent's stream.
    pub tool_calls: usize,
    /// One entry per tool call, in order. Empty for a turn served entirely by a LOCAL
    /// route (vault-QA, emergency, the diet extractor): those are contained one-shot
    /// children rather than traced agent turns, so the record still carries the turn's
    /// wall time and status but has no tool timeline to report.
    pub tools: Vec<ToolCallTiming>,
    /// The turn's token counts, when the harness reported them.
    ///
    /// OMITTED rather than zeroed when absent, and absent is the common case: a claude-code
    /// or codex turn reports usage on its terminal event and the badge consumes it, but the
    /// counts were never carried onto this record — so an existing record has no `usage` key
    /// and parses unchanged, and a client sees the field only where it means something.
    /// The `direct` harness fills it on every turn, which is what makes
    /// `GET /jesse/result/{id}` able to answer "what did this turn cost" for the harness
    /// whose per-call ledger the bridge itself writes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub usage: Option<ShadowUsage>,
    /// The turn's dollar cost on its model's deck. Present exactly when `usage` is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
}

// ---- The trace ------------------------------------------------------------

/// The caps the partial ring enforces, resolved from config once per turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PartialLimits {
    pub blocks: usize,
    pub bytes: usize,
}

impl PartialLimits {
    pub fn from_cfg(cfg: &Config) -> Self {
        PartialLimits {
            blocks: cfg.partial_blocks,
            bytes: cfg.partial_bytes,
        }
    }
}

#[derive(Default)]
struct TraceInner {
    /// The retained text blocks, oldest first. The back one is still open — a delta
    /// appends to it; a tool call closes it so the next delta starts a new block.
    blocks: VecDeque<String>,
    /// Whether the back block is still accepting deltas.
    open: bool,
    /// Completed tool calls, in order.
    tools: Vec<ToolCallTiming>,
    /// The call in flight: its name and when it started. Closed by the next event.
    pending: Option<(String, Instant)>,
    /// The turn's aggregate token usage and dollar cost, once the driver knows them.
    usage: Option<(ShadowUsage, f64)>,
    /// Every tool call seen, including any beyond what `tools` retains.
    tool_calls: usize,
    /// Anything the ring dropped or trimmed.
    truncated: bool,
    /// The run limit fired — this turn was cut off rather than finishing.
    cutoff: bool,
    /// The style checker's verdict, once the harness has one. `None` on every turn that ran
    /// no check, which is what makes the provenance field absent rather than zero.
    style: Option<StyleVerdict>,
}

/// The per-turn observation point. Cheap, lock-per-event, and shared by the turn task and
/// the driver (`Arc<TurnTrace>`); every method is infallible from the caller's view.
pub struct TurnTrace {
    started: Instant,
    started_at: SystemTime,
    limits: PartialLimits,
    inner: Mutex<TraceInner>,
}

impl TurnTrace {
    pub fn new(limits: PartialLimits) -> Self {
        TurnTrace {
            started: Instant::now(),
            started_at: SystemTime::now(),
            limits,
            inner: Mutex::new(TraceInner::default()),
        }
    }

    pub fn from_cfg(cfg: &Config) -> Self {
        TurnTrace::new(PartialLimits::from_cfg(cfg))
    }

    /// A chunk of visible answer text. Appends to the open block (opening one if the last
    /// event was a tool call) and re-trims the ring.
    pub fn note_delta(&self, text: &str) {
        if text.is_empty() {
            return;
        }
        let mut g = self.inner.lock_ok();
        self.close_pending_tool(&mut g);
        if !g.open || g.blocks.is_empty() {
            g.blocks.push_back(String::new());
            g.open = true;
        }
        if let Some(last) = g.blocks.back_mut() {
            last.push_str(text);
        }
        let limits = self.limits;
        trim(&mut g, limits);
    }

    /// A tool call started. Closes the open text block (so the next delta starts a fresh
    /// one) and starts this call's clock.
    pub fn note_tool(&self, name: &str) {
        let mut g = self.inner.lock_ok();
        self.close_pending_tool(&mut g);
        g.open = false;
        g.tool_calls += 1;
        g.pending = Some((name.to_string(), Instant::now()));
    }

    /// Record the style checker's verdict for this turn (D6). Two integers; see
    /// [`StyleVerdict`], which is content free by construction. Last write wins, which is the
    /// right rule for a value reported once after the answer is final.
    pub fn note_style(&self, verdict: StyleVerdict) {
        self.inner.lock_ok().style = Some(verdict);
    }

    /// The style checker's verdict, or `None` when this turn ran no check.
    pub fn style(&self) -> Option<StyleVerdict> {
        self.inner.lock_ok().style
    }

    /// Record the turn's aggregate usage and its cost on the active model's deck.
    ///
    /// Called once, by the driver, when the turn resolves — so a turn that failed before any
    /// provider call records nothing rather than a row of zeroes. The COST is computed here
    /// rather than at read time because it depends on the model's price deck, which the
    /// timing log does not carry and should not have to look up later.
    pub fn note_usage(&self, usage: ShadowUsage, cost_usd: f64) {
        let mut g = self.inner.lock_ok();
        g.usage = Some((usage, cost_usd));
    }

    /// Reconcile the running tool count with a harness that reports its OWN authoritative
    /// total for the turn — [`TurnOutcome::tool_calls`].
    ///
    /// The count here is normally derived: every [`TurnTrace::note_tool`] the driver makes
    /// while reading mid-turn activity bumps it by one. That is exact for a harness whose
    /// every tool call is narrated, and the spawned harnesses' are. It is NOT exact in
    /// general: the mid-turn contract makes activity a garnish on a streaming harness ("a
    /// missed activity event costs nothing"), so an in-process harness may legitimately
    /// finish having made more calls than it narrated.
    ///
    /// `max`, never assignment, and that is the whole of the rule: a harness that reports a
    /// SMALLER number than the driver actually watched has not un-made those calls, and
    /// letting it lower the count would make "43 tool calls and nothing said" — the one
    /// diagnosis [`TurnTrace::partial`] exists to deliver — quietly wrong. Per-call TIMINGS
    /// are untouched: the extra calls have no clock of their own, and inventing one would be
    /// a measurement nobody took.
    pub fn note_tool_calls(&self, reported: usize) {
        let mut g = self.inner.lock_ok();
        g.tool_calls = g.tool_calls.max(reported);
    }

    /// The turn's stream ended (terminal result, EOF, or the kill). Closes any tool call
    /// still in flight so its duration is recorded rather than lost.
    pub fn note_end(&self) {
        let mut g = self.inner.lock_ok();
        self.close_pending_tool(&mut g);
    }

    /// A retry re-runs the WHOLE prompt, so the previous attempt's text and tool calls no
    /// longer describe what the client will be shown. Mirrors `JobStore::stream_reset`.
    pub fn reset(&self) {
        let mut g = self.inner.lock_ok();
        *g = TraceInner::default();
    }

    /// The run limit fired: this turn was CUT OFF. Only after this does [`partial`] hand
    /// anything back — a turn that failed for any other reason has a cause, not a cutoff.
    ///
    /// [`partial`]: TurnTrace::partial
    pub fn mark_cutoff(&self) {
        let mut g = self.inner.lock_ok();
        self.close_pending_tool(&mut g);
        g.cutoff = true;
    }

    /// Wall time since the turn started.
    pub fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }

    /// How far the turn got — `None` unless [`mark_cutoff`](TurnTrace::mark_cutoff) fired.
    /// Present even with empty text: "43 tool calls in 90 minutes and nothing said" is
    /// itself the diagnosis.
    pub fn partial(&self) -> Option<PartialTurn> {
        let g = self.inner.lock_ok();
        if !g.cutoff {
            return None;
        }
        Some(PartialTurn {
            text: join_blocks(&g.blocks),
            elapsed_secs: self.started.elapsed().as_secs(),
            tool_calls: g.tool_calls,
            truncated: g.truncated,
        })
    }

    /// The turn's timing record, stamped with the status it ended in.
    pub fn timing(&self, job_id: &str, status: &str) -> TurnTiming {
        let mut g = self.inner.lock_ok();
        self.close_pending_tool(&mut g);
        let elapsed = self.started.elapsed();
        TurnTiming {
            v: 1,
            job_id: job_id.to_string(),
            started_at: rfc3339_utc(self.started_at),
            ended_at: rfc3339_utc(self.started_at + elapsed),
            elapsed_ms: elapsed.as_millis() as u64,
            status: status.to_string(),
            tool_calls: g.tool_calls,
            tools: g.tools.clone(),
            usage: g.usage.as_ref().map(|(u, _)| u.clone()),
            cost_usd: g.usage.as_ref().map(|(_, c)| *c),
        }
    }

    /// Close the tool call in flight, recording how long it held the turn. Idempotent —
    /// every event calls it, and only the first after a `note_tool` does anything.
    fn close_pending_tool(&self, g: &mut TraceInner) {
        if let Some((name, at)) = g.pending.take() {
            g.tools.push(ToolCallTiming {
                tool: name,
                ms: at.elapsed().as_millis() as u64,
            });
        }
    }
}

/// Enforce the ring's caps: at most `blocks` blocks, at most `bytes` bytes in total.
/// Oldest blocks go first; if the single remaining block is still over budget, its TAIL is
/// kept — a cut-off turn's most recent words are the ones worth showing.
fn trim(g: &mut TraceInner, limits: PartialLimits) {
    while g.blocks.len() > limits.blocks.max(1) {
        g.blocks.pop_front();
        g.truncated = true;
    }
    let total = |b: &VecDeque<String>| b.iter().map(|s| s.len()).sum::<usize>();
    while total(&g.blocks) > limits.bytes && g.blocks.len() > 1 {
        g.blocks.pop_front();
        g.truncated = true;
    }
    if let Some(last) = g.blocks.back_mut() {
        if last.len() > limits.bytes {
            let tail = tail_bytes_on_char_boundary(last, limits.bytes).to_string();
            *last = tail;
            g.truncated = true;
        }
    }
}

/// The LAST `max_bytes` bytes of `s`, starting on a valid UTF-8 boundary. The mirror of
/// [`truncate_bytes_on_char_boundary`], which keeps the head.
pub fn tail_bytes_on_char_boundary(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut start = s.len() - max_bytes;
    while start < s.len() && !s.is_char_boundary(start) {
        start += 1;
    }
    &s[start..]
}

/// Retained blocks as one string: blank line between blocks (where a tool call ran),
/// nothing added at the ends.
fn join_blocks(blocks: &VecDeque<String>) -> String {
    blocks
        .iter()
        .filter(|b| !b.is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join("\n\n")
}

// ---- The log --------------------------------------------------------------

/// The append-only timing log: one JSON line per turn under `<state_dir>/`, plus an
/// in-memory index so `GET /jesse/result/{id}` can serve a record without re-reading the
/// file on every poll.
///
/// Degrades exactly as the job/title/flag stores do: with no state dir it is in-memory
/// only (records still reach the result endpoint for the life of the process, nothing is
/// persisted).
pub struct TurnTimingLog {
    path: Option<PathBuf>,
    index: Mutex<TimingIndex>,
}

#[derive(Default)]
struct TimingIndex {
    by_job: HashMap<String, TurnTiming>,
    /// Insertion order, so the in-memory cap evicts the oldest.
    order: VecDeque<String>,
}

impl TurnTimingLog {
    /// Build from config and LOAD + PRUNE the file: records whose `ended_at` is older than
    /// [`TIMING_RETENTION_DAYS`] are dropped and the file is rewritten (temp + rename, so
    /// a crash mid-prune leaves either the old file or the new one). Called once at
    /// startup, from `AppState::new`.
    pub fn from_cfg(cfg: &Config) -> Self {
        match cfg.turn_timing_file() {
            Some(p) => TurnTimingLog::load(&p, SystemTime::now()),
            None => TurnTimingLog {
                path: None,
                index: Mutex::new(TimingIndex::default()),
            },
        }
    }

    /// Load + prune at an explicit path and clock (the testable half of `from_cfg`).
    pub fn load(path: &Path, now: SystemTime) -> Self {
        let cutoff = rfc3339_utc(now - Duration::from_secs(TIMING_RETENTION_DAYS * 86_400));
        let all: Vec<TurnTiming> = read_timing_lines(path);
        let kept: Vec<TurnTiming> = all
            .into_iter()
            // Fixed-width RFC3339 UTC → lexicographic order IS chronological order.
            .filter(|r| r.ended_at >= cutoff)
            .collect();
        // Only rewrite when the file exists; a fresh deploy shouldn't create an empty one.
        if path.exists() {
            if let Err(e) = rewrite_timing_lines(path, &kept) {
                eprintln!(
                    "jesse-bridge: turn-timing prune of {} failed: {e} — continuing",
                    path.display()
                );
            }
        }
        let mut index = TimingIndex::default();
        // Newest last, and the cap drops from the front, so the newest survive.
        for rec in kept
            .into_iter()
            .rev()
            .take(MAX_TIMING_RECORDS_IN_MEMORY)
            .rev()
        {
            index.order.push_back(rec.job_id.clone());
            index.by_job.insert(rec.job_id.clone(), rec);
        }
        TurnTimingLog {
            path: Some(path.to_path_buf()),
            index: Mutex::new(index),
        }
    }

    /// Record one finished turn: into the in-memory index, and appended as one line to the
    /// log. Best-effort — a write failure is logged and swallowed, never surfaced to the
    /// turn (the reply is already stored by the time this runs).
    pub fn record(&self, rec: TurnTiming) {
        {
            let mut g = self.index.lock_ok();
            if g.by_job.insert(rec.job_id.clone(), rec.clone()).is_none() {
                g.order.push_back(rec.job_id.clone());
            }
            while g.order.len() > MAX_TIMING_RECORDS_IN_MEMORY {
                if let Some(old) = g.order.pop_front() {
                    g.by_job.remove(&old);
                }
            }
        }
        let Some(path) = self.path.as_deref() else {
            return;
        };
        if let Err(e) = append_timing_line(path, &rec) {
            eprintln!(
                "jesse-bridge: turn-timing write to {} failed: {e} — reply unaffected",
                path.display()
            );
        }
    }

    /// This job's timing record, if it finished under this process (or was loaded from the
    /// pruned file at startup).
    pub fn get(&self, job_id: &str) -> Option<TurnTiming> {
        self.index.lock_ok().by_job.get(job_id).cloned()
    }

    /// Records currently indexed — for tests and the startup log line.
    pub fn len(&self) -> usize {
        self.index.lock_ok().by_job.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

fn read_timing_lines(path: &Path) -> Vec<TurnTiming> {
    let Ok(body) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    body.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

/// One `O_APPEND` `writeln!` per record — no shared handle, so two turns finishing at once
/// can never interleave a partial line, and the trail survives a restart.
fn append_timing_line(path: &Path, rec: &TurnTiming) -> std::io::Result<()> {
    use std::io::Write as _;
    let line = serde_json::to_string(rec)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(f, "{line}")
}

/// Crash-atomic prune rewrite: temp file + rename, so the log is either wholly the old
/// set or wholly the pruned one.
fn rewrite_timing_lines(path: &Path, recs: &[TurnTiming]) -> std::io::Result<()> {
    use std::io::Write as _;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(".turn-timings-{}.tmp", random_hex()));
    {
        let mut f = std::fs::File::create(&tmp)?;
        for r in recs {
            let line = serde_json::to_string(r)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            writeln!(f, "{line}")?;
        }
        f.sync_all().ok();
    }
    std::fs::rename(&tmp, path)
}

// ---- Writing the record when the turn ends, however it ends ---------------

/// Writes the turn's [`TurnTiming`] on Drop, reading the status off the job the turn just
/// landed. A GUARD rather than a line of code after `complete` because a cancel ABORTS the
/// turn task: anything after `complete` would never run for a cancelled turn, and a turn
/// the operator killed is exactly the kind worth having a record of. Drop runs on success,
/// error, timeout, panic and abort alike — the same contract `TurnLockRelease` relies on.
///
/// The disk write is a single small append and runs inline in Drop, next to the metrics
/// append the same task already does.
pub struct TurnTimingRecorder {
    pub trace: Arc<TurnTrace>,
    pub timings: Arc<TurnTimingLog>,
    pub jobs: Arc<JobStore>,
    pub job_id: String,
}

impl Drop for TurnTimingRecorder {
    fn drop(&mut self) {
        let status = match self.jobs.get(&self.job_id) {
            Some(JobState::Done { .. }) => "done",
            Some(JobState::Failed { .. }) => "failed",
            Some(JobState::Cancelled) => "cancelled",
            // The task's Drop ran while the job was still Running: it was killed from
            // outside (a cancel that beat the state write, or a panic).
            Some(JobState::Running) => "aborted",
            // The job was evicted out from under the turn — vanishingly rare, but the
            // record still says what the turn did.
            None => "unknown",
        };
        self.timings.record(self.trace.timing(&self.job_id, status));
    }
}

/// The `timing` object for `GET /jesse/result/{id}`, or `Value::Null` when this job has no
/// record (evicted, pre-dating the feature, or still running).
pub fn timing_to_value(rec: Option<&TurnTiming>) -> Value {
    match rec {
        Some(r) => serde_json::to_value(r).unwrap_or(Value::Null),
        None => Value::Null,
    }
}

/// The `usage` object for `GET /jesse/result/{id}` — token counts and cost only — or
/// `Value::Null` when this turn's harness reported none.
///
/// CONTENT-FREE by construction: four integers and a dollar amount. It carries no prompt, no
/// answer, no model id (that is already on `provenance`) and no endpoint.
pub fn usage_to_value(rec: Option<&TurnTiming>) -> Value {
    match rec.and_then(|r| r.usage.as_ref().map(|u| (u, r.cost_usd))) {
        Some((u, cost)) => {
            let mut v = serde_json::to_value(u).unwrap_or(Value::Null);
            if let (Some(obj), Some(c)) = (v.as_object_mut(), cost) {
                obj.insert("cost_usd".to_string(), json!(c));
            }
            v
        }
        None => Value::Null,
    }
}

/// The `partial` object for `GET /jesse/result/{id}`, or `Value::Null` when the turn was
/// not cut off.
pub fn partial_to_value(p: Option<&PartialTurn>) -> Value {
    match p {
        Some(v) => serde_json::to_value(v).unwrap_or(Value::Null),
        None => Value::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits(blocks: usize, bytes: usize) -> PartialLimits {
        PartialLimits { blocks, bytes }
    }

    #[test]
    fn a_tool_call_starts_a_new_text_block() {
        let t = TurnTrace::new(limits(8, 16 * 1024));
        t.note_delta("first ");
        t.note_delta("block");
        t.note_tool("Read");
        t.note_delta("second block");
        t.mark_cutoff();
        let p = t.partial().expect("cut off → a partial");
        assert_eq!(p.text, "first block\n\nsecond block");
        assert_eq!(p.tool_calls, 1);
        assert!(!p.truncated);
    }

    #[test]
    fn the_ring_keeps_the_last_n_blocks() {
        let t = TurnTrace::new(limits(2, 16 * 1024));
        for i in 0..5 {
            t.note_delta(&format!("block{i}"));
            t.note_tool("Read");
        }
        t.mark_cutoff();
        let p = t.partial().unwrap();
        assert_eq!(p.text, "block3\n\nblock4", "only the last 2 blocks");
        assert_eq!(p.tool_calls, 5, "every call still counted");
        assert!(p.truncated);
    }

    #[test]
    fn the_byte_cap_keeps_the_most_recent_text() {
        let t = TurnTrace::new(limits(8, 16));
        t.note_delta(&"a".repeat(40));
        t.mark_cutoff();
        let p = t.partial().unwrap();
        assert_eq!(p.text.len(), 16, "capped at the byte budget");
        assert!(p.truncated);
    }

    #[test]
    fn the_byte_cap_never_splits_a_multibyte_char() {
        let t = TurnTrace::new(limits(8, 10));
        // 3-byte chars: a naive slice at 10 would land mid-character.
        t.note_delta(&"日".repeat(8));
        t.mark_cutoff();
        let text = t.partial().unwrap().text;
        assert!(text.len() <= 10);
        assert_eq!(text, "日日日", "whole chars only, from the tail");
    }

    #[test]
    fn no_partial_until_the_run_limit_fires() {
        let t = TurnTrace::new(limits(8, 1024));
        t.note_delta("some text");
        assert!(t.partial().is_none(), "an ordinary failure is not a cutoff");
        t.mark_cutoff();
        assert!(t.partial().is_some());
    }

    #[test]
    fn a_retry_clears_the_previous_attempt() {
        let t = TurnTrace::new(limits(8, 1024));
        t.note_delta("attempt one");
        t.note_tool("Read");
        t.reset();
        t.note_delta("attempt two");
        t.mark_cutoff();
        let p = t.partial().unwrap();
        assert_eq!(p.text, "attempt two");
        assert_eq!(p.tool_calls, 0, "the dropped attempt's calls go with it");
    }

    #[test]
    fn tool_timings_land_on_the_record_in_order() {
        let t = TurnTrace::new(limits(8, 1024));
        t.note_tool("Read");
        t.note_delta("thinking out loud");
        t.note_tool("Bash");
        t.note_end();
        let rec = t.timing("job-1", "failed");
        assert_eq!(rec.tool_calls, 2);
        assert_eq!(
            rec.tools
                .iter()
                .map(|x| x.tool.as_str())
                .collect::<Vec<_>>(),
            vec!["Read", "Bash"]
        );
        assert_eq!(rec.status, "failed");
        assert_eq!(rec.job_id, "job-1");
        assert!(rec.ended_at >= rec.started_at);
    }

    #[test]
    fn the_timing_record_is_one_content_free_line() {
        let t = TurnTrace::new(limits(8, 1024));
        t.note_delta("the secret answer text");
        t.note_tool("Read");
        let line = serde_json::to_string(&t.timing("job-1", "done")).unwrap();
        assert!(!line.contains('\n'), "one line: {line}");
        // The partial text is CONTENT and must never reach the timing log.
        for forbidden in ["secret", "answer text", "question", "prompt", "response"] {
            assert!(
                !line.contains(forbidden),
                "must not carry {forbidden}: {line}"
            );
        }
        let back: TurnTiming = serde_json::from_str(&line).unwrap();
        assert_eq!(back.tool_calls, 1);
    }

    #[test]
    fn records_round_trip_through_the_log() {
        let dir = std::env::temp_dir().join(format!("jesse-timing-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(TURN_TIMING_FILE);
        let log = TurnTimingLog::load(&path, SystemTime::now());
        let t = TurnTrace::new(limits(8, 1024));
        t.note_tool("Read");
        log.record(t.timing("job-abc", "done"));

        assert_eq!(log.get("job-abc").map(|r| r.status), Some("done".into()));
        assert!(log.get("nope").is_none());
        // Reloading the file sees it.
        let reloaded = TurnTimingLog::load(&path, SystemTime::now());
        assert_eq!(reloaded.get("job-abc").map(|r| r.tool_calls), Some(1));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn startup_prunes_records_older_than_the_retention_window() {
        let dir = std::env::temp_dir().join(format!("jesse-timing-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(TURN_TIMING_FILE);
        let now = SystemTime::now();
        let stamp = |ago: Duration| rfc3339_utc(now - ago);
        let rec = |id: &str, ago: Duration| TurnTiming {
            v: 1,
            job_id: id.to_string(),
            started_at: stamp(ago),
            ended_at: stamp(ago),
            elapsed_ms: 1,
            status: "done".to_string(),
            tool_calls: 0,
            tools: vec![],
            usage: None,
            cost_usd: None,
        };
        rewrite_timing_lines(
            &path,
            &[
                rec("old", Duration::from_secs(8 * 86_400)),
                rec("fresh", Duration::from_secs(3_600)),
            ],
        )
        .unwrap();

        let log = TurnTimingLog::load(&path, now);
        assert!(log.get("old").is_none(), "8 days old → pruned");
        assert!(log.get("fresh").is_some(), "an hour old → kept");
        // The FILE was rewritten, not just the index.
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert!(
            !on_disk.contains("\"old\""),
            "pruned on disk too: {on_disk}"
        );
        assert!(on_disk.contains("\"fresh\""));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn the_log_degrades_to_memory_with_no_state_dir() {
        let log = TurnTimingLog {
            path: None,
            index: Mutex::new(TimingIndex::default()),
        };
        let t = TurnTrace::new(limits(8, 1024));
        log.record(t.timing("job-x", "done"));
        assert!(log.get("job-x").is_some(), "still served in-process");
    }

    #[test]
    fn the_in_memory_index_is_capped() {
        let log = TurnTimingLog {
            path: None,
            index: Mutex::new(TimingIndex::default()),
        };
        let t = TurnTrace::new(limits(8, 1024));
        for i in 0..(MAX_TIMING_RECORDS_IN_MEMORY + 5) {
            log.record(t.timing(&format!("job-{i}"), "done"));
        }
        assert_eq!(log.len(), MAX_TIMING_RECORDS_IN_MEMORY);
        assert!(log.get("job-0").is_none(), "oldest evicted");
        assert!(log
            .get(&format!("job-{}", MAX_TIMING_RECORDS_IN_MEMORY + 4))
            .is_some());
    }

    #[test]
    fn tail_helper_matches_its_head_twin_on_short_input() {
        assert_eq!(tail_bytes_on_char_boundary("abc", 10), "abc");
        assert_eq!(tail_bytes_on_char_boundary("abcdef", 3), "def");
        assert_eq!(tail_bytes_on_char_boundary("", 3), "");
    }
}
