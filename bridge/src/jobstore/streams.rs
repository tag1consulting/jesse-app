//! Per-job live-stream (SSE) state, isolated behind `StreamRegistry`.
//!
//! The job store must **never hold the `streams`, `jobs`, and `aborts` locks
//! simultaneously** — that is the deadlock-avoidance invariant the whole store
//! depends on. Here that invariant is made *structural* rather than a prose
//! comment: the broadcast map lives in a **private** `Mutex` inside
//! `StreamRegistry`, and every method takes that one lock, mutates, and releases
//! it before returning (no `MutexGuard` ever escapes). `JobStore` owns a
//! `StreamRegistry` and can only reach the streams through these one-lock-at-a-
//! time methods — it has no access to the raw map or its guard, so it *cannot*
//! hold the streams lock across the `jobs`/`aborts` locks even by mistake.

use crate::*;

/// A live SSE frame, broadcast to every subscriber of a running job's stream.
/// Cheap to clone (the broadcast channel hands each subscriber its own copy).
/// The terminal arms (`Done`/`Error`/`Cancelled`) mirror the three terminal
/// `JobState`s a poll of `GET /jesse/result` would report.
#[derive(Clone, Debug)]
pub enum StreamFrame {
    /// Incremental answer text — append to what the client has so far.
    Delta(String),
    /// A coarse "Jesse is using the <name> tool" activity hint.
    Activity(ToolActivity),
    /// Terminal: the turn finished. Carries the authoritative final text,
    /// session id, any extracted directives, and the structured provenance (same
    /// values `complete` persisted), not the accumulated deltas.
    Done {
        response: String,
        session_id: Option<String>,
        directives: Option<Box<Directives>>,
        // Boxed to match `JobState::Done` — keeps this large terminal frame small.
        provenance: Option<Box<Provenance>>,
        // The metadata for any files this turn returned — never the bytes. Mirrors
        // `JobState::Done`'s field so a streamed terminal frame and a polled result
        // carry the identical value; empty on nearly every turn.
        artifacts: Vec<Artifact>,
    },
    /// Terminal: the turn failed. Carries the human-readable cause.
    Error(String),
    /// Terminal: the turn was cancelled (`POST /jesse/cancel`). Surfaced cleanly
    /// so the phone renders "Cancelled", never an error.
    Cancelled,
}

/// One coarse tool-activity hint: WHICH tool, and whether the containment boundary
/// REFUSED the call.
///
/// `refused` is a separate field rather than a suffix on `name` because `name` is a
/// VOCABULARY — the same one both harnesses emit and `RunCoordinator.activityLabel`
/// switches on — and folding a display word into it would make every client parse a
/// string grammar to get one bit back out. A refused `Write` is still a `Write`.
///
/// It carries a bit rather than the child's own error text ON PURPOSE: that text names
/// the path or the command the model tried, and this value reaches a phone screen.
///
/// COUPLED WITH `JesseStreamEvent.activity` in `JesseKit/Sources/JesseNetworking/
/// WireTypes.swift`, which is the same pair on the client side, and with `frame_to_event`,
/// which omits `refused` from the wire when false so an older client decoding only `name`
/// is unaffected.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolActivity {
    pub name: String,
    pub refused: bool,
}

impl ToolActivity {
    /// A tool call the child made and the harness observed succeeding, or at least
    /// starting — the ordinary case, and every activity Claude Code emits.
    pub fn used(name: impl Into<String>) -> Self {
        ToolActivity {
            name: name.into(),
            refused: false,
        }
    }

    /// A tool call the containment boundary refused. Not a turn failure: the boundary
    /// working is the system working, and the model routinely tries something, is
    /// refused, and answers anyway. What it must not be is invisible.
    pub fn refused(name: impl Into<String>) -> Self {
        ToolActivity {
            name: name.into(),
            refused: true,
        }
    }
}

/// Per-job live-stream state: the broadcast sender plus the text accumulated so
/// far (so a phone that opens the stream a beat late, or reconnects after a
/// blip, can be replayed the beginning) and the most recent tool-activity hint.
/// In-memory only and never persisted — only the terminal result persists, via
/// `complete`. An entry exists for the life of a running job and is removed on
/// the terminal transition (mirroring `aborts`). Private to this module: only
/// `StreamRegistry` ever touches a handle.
struct StreamHandle {
    tx: broadcast::Sender<StreamFrame>,
    text: String,
    activity: Option<ToolActivity>,
}

/// Broadcast backlog per job. Generous so a briefly-slow subscriber doesn't lag
/// and force a full re-sync; if it does lag, the SSE handler resends the whole
/// accumulated buffer as a `reset`, so correctness never depends on this size.
const STREAM_CHANNEL_CAP: usize = 1024;

/// The per-job live-stream map, behind one **private** `Mutex`. Every method
/// takes only this lock (and never any other), so a caller can never hold it
/// across the store's `jobs`/`aborts` locks — the invariant is enforced by the
/// module boundary, not by discipline. Mirrors the old `JobStore.streams` field
/// exactly; the `stream_*` methods on `JobStore` are now thin delegators to this.
pub struct StreamRegistry {
    streams: Mutex<HashMap<String, StreamHandle>>,
}

impl StreamRegistry {
    pub fn new() -> Self {
        StreamRegistry {
            streams: Mutex::new(HashMap::new()),
        }
    }

    /// Open a live stream for a job: install a fresh broadcast channel and an
    /// empty accumulator. Called once, right after `create`, before the turn is
    /// spawned, so a subscriber arriving immediately finds the entry.
    pub fn register(&self, id: &str) {
        let (tx, _rx) = broadcast::channel(STREAM_CHANNEL_CAP);
        self.streams.lock_ok().insert(
            id.to_string(),
            StreamHandle {
                tx,
                text: String::new(),
                activity: None,
            },
        );
    }

    /// Append a text delta to the accumulator and broadcast it live. A no-op if
    /// the stream entry is gone (terminal already reached) so a late delta from a
    /// not-yet-reaped child can't resurrect a finished stream. The accumulator is
    /// capped at `MAX_OUTPUT_BYTES` so one pathological turn can't bloat memory;
    /// the authoritative final text comes from the terminal result regardless.
    pub fn push_delta(&self, id: &str, delta: &str) {
        let mut guard = self.streams.lock_ok();
        if let Some(h) = guard.get_mut(id) {
            if h.text.len() < MAX_OUTPUT_BYTES {
                h.text.push_str(delta);
            }
            let _ = h.tx.send(StreamFrame::Delta(delta.to_string()));
        }
    }

    /// Record the latest tool-activity hint and broadcast it. No-op if gone.
    pub fn push_activity(&self, id: &str, activity: ToolActivity) {
        let mut guard = self.streams.lock_ok();
        if let Some(h) = guard.get_mut(id) {
            h.activity = Some(activity.clone());
            let _ = h.tx.send(StreamFrame::Activity(activity));
        }
    }

    /// Clear the accumulated text before a retry re-runs the whole prompt, so a
    /// rerun doesn't double the buffer. (Retryable failures occur at the API
    /// before any tokens, so in practice the buffer is already empty here.)
    pub fn reset(&self, id: &str) {
        if let Some(h) = self.streams.lock_ok().get_mut(id) {
            h.text.clear();
            h.activity = None;
        }
    }

    /// Subscribe to a running job's stream: returns the text accumulated so far,
    /// the latest activity hint, and a receiver for future frames. `None` once
    /// the job is terminal (entry removed) — the caller then reads the terminal
    /// state from `jobs` instead. Taking the snapshot and the receiver under the
    /// one lock means no delta can slip between them (every push also takes it).
    pub fn subscribe(
        &self,
        id: &str,
    ) -> Option<(
        String,
        Option<ToolActivity>,
        broadcast::Receiver<StreamFrame>,
    )> {
        let guard = self.streams.lock_ok();
        let h = guard.get(id)?;
        Some((h.text.clone(), h.activity.clone(), h.tx.subscribe()))
    }

    /// The full accumulated text for a job, if its stream is still live. Used to
    /// re-sync a subscriber that lagged the broadcast backlog.
    pub fn snapshot(&self, id: &str) -> Option<String> {
        Some(self.streams.lock_ok().get(id)?.text.clone())
    }

    /// Close a job's stream with a terminal frame and remove the entry. The frame
    /// reaches every current subscriber (they hold receivers); a subscriber that
    /// arrives afterwards finds no entry and reads the terminal state from `jobs`.
    /// Removing under the lock makes this write-once: whichever of the turn-task
    /// (`Done`/`Error`) and `cancel` (`Cancelled`) calls it first wins and the
    /// other no-ops — mirroring the write-once `jobs` transition.
    pub fn finish(&self, id: &str, frame: StreamFrame) {
        if let Some(h) = self.streams.lock_ok().remove(id) {
            let _ = h.tx.send(frame);
        }
    }
}

impl Default for StreamRegistry {
    fn default() -> Self {
        Self::new()
    }
}
