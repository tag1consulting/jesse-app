//! **The usage sink** — one record per provider call, and the rule that keeps it honest.
//!
//! ---- THE RULE ---------------------------------------------------------------
//!
//! **No code path that spends money exists without a record here.** Every provider call
//! the loop makes produces exactly one [`UsageRecord`] — including calls that failed, and
//! including calls the provider layer retried internally (a retried call is ONE call: the
//! attempt count rides in the record, and the latency is what the caller actually waited).
//!
//! That is a stronger statement than "usage is logged", and it is the one worth making,
//! because the failure it prevents is specific. A record emitted only on success means a
//! turn that fails after buying 300 k input tokens leaves no trace of having spent
//! anything, and the bill arrives with no local counterpart. Anthropic's own wire bills a
//! request that streamed and then errored; so does every gateway in front of it.
//!
//! ---- WHY THIS IS A SEAM AND NOT A LOGGER ------------------------------------
//!
//! This trait is where the product's **per-user ledger and its budget enforcement grow
//! from**. Today [`JsonlUsageSink`] appends a line to a file and nothing reads it. What it
//! is FOR is the moment a tenant has a monthly allowance: the same record, written to a
//! store that can be summed per [`crate::scope::Scope`], is both the invoice line and the
//! input to the check that refuses the next turn. Designing it as a trait now — rather
//! than an `eprintln!` to be replaced later — means that change is an implementation of an
//! existing interface instead of a new call at every site that spends.
//!
//! The record carries the scope ids for exactly that reason: a ledger keyed on turn id is
//! an audit trail, and a ledger keyed on tenant is a bill.
//!
//! ---- CONTENT-FREE -----------------------------------------------------------
//!
//! Counts, ids, a model name, a latency, a stop reason. **No prompt, no answer, no tool
//! arguments, no tool results, and no tool NAMES.** The same discipline as
//! `bridge/src/turntrace.rs`'s timing log, which states it and has a test for it, and for
//! the same reason: this file is the one an operator greps, tails, and pastes into a
//! ticket, and any of those is a place vault content must never turn up. `request_tag` is
//! the single caller-controlled string, and its doc says the caller owns not putting
//! content in it.

use std::fmt;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::provider::Wire;
use crate::scope::Scope;
use crate::timestamp::rfc3339_utc;

/// Schema version of a usage record.
pub const USAGE_SCHEMA_VERSION: u8 = 1;

/// Which call in a turn this was.
///
/// TWO ARMS, NOT AN ITERATION NUMBER, because the question this answers is a cost question:
/// "how much of the bill is the work the user asked for, and how much is the tool loop it
/// took to get there". An iteration index answers it only after somebody writes the
/// grouping query; the label answers it in a `grep`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    /// The turn's FIRST provider call — the user's question, answered from the thread.
    Main,
    /// Any call after tool results were spliced in.
    ToolFollowup,
}

impl fmt::Display for Phase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Phase::Main => "main",
            Phase::ToolFollowup => "tool_followup",
        })
    }
}

/// One provider call, priced.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsageRecord {
    pub v: u8,
    /// RFC-3339 UTC, fixed width.
    pub ts: String,
    pub turn_id: String,
    pub conversation_id: String,
    pub tenant: String,
    pub user: String,
    pub workspace: String,
    pub wire: Wire,
    pub model: String,
    /// The provider's own id for the request, when the wire exposed one. For correlating
    /// with a provider-side dashboard; never a token, never a URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_request_id: Option<String>,

    // The counts, `None` where the wire did not report one. `None` and `0` are
    // DIFFERENT and are kept different: a zero is a measurement, an absence is not, and a
    // sink that folded them together would make "this host reports no cache writes"
    // indistinguishable from "this call wrote nothing to cache".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_tokens: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_write_tokens: Option<u64>,
    /// Output tokens spent thinking, where the wire reports a breakdown.
    ///
    /// **INSIDE `output_tokens`, not beside it** — see [`crate::provider::Usage`]. It has
    /// no effect on `cost_usd`; it is here because "how much of this bill was thinking" is
    /// a question about a turn, and a count that reaches no durable record is a count
    /// nobody can answer it with.
    ///
    /// Omitted when absent, like every other optional count, so `v` stays `1`: a reader
    /// written against the older shape sees exactly what it saw before on the two wires
    /// that report no breakdown, and an unknown key on the one that does.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_tokens: Option<u64>,

    /// Dollars, from the turn's [`crate::budget::PriceDeck`].
    pub cost_usd: f64,
    /// What the caller waited, INCLUDING any retries inside the provider layer.
    pub latency_ms: u64,
    /// The call's stop reason as a short string (`end_turn`, `tool_use`, `max_tokens`, or
    /// an error class such as `rate-limited`). A string rather than an enum because the
    /// wire's `StopReason::Other` and the error classes share this field, and inventing a
    /// union type for a log column would be a type nobody reads.
    pub stop_reason: String,
    /// Which attempt produced the outcome. `1` means it worked first time.
    pub attempt: u32,
    pub phase: Phase,
}

impl UsageRecord {
    /// Fill in the scope's three ids. A helper rather than a `Scope` field on the record so
    /// that the record stays a flat, greppable, serialisable row.
    pub fn with_scope(mut self, scope: &Scope) -> Self {
        self.tenant = scope.tenant.to_string();
        self.user = scope.user.to_string();
        self.workspace = scope.workspace.to_string();
        self
    }

    /// A record with the schema version and timestamp filled in and everything else empty.
    pub fn at(now: SystemTime) -> Self {
        UsageRecord {
            v: USAGE_SCHEMA_VERSION,
            ts: rfc3339_utc(now),
            turn_id: String::new(),
            conversation_id: String::new(),
            tenant: String::new(),
            user: String::new(),
            workspace: String::new(),
            wire: Wire::Messages,
            model: String::new(),
            provider_request_id: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            cache_write_tokens: None,
            reasoning_tokens: None,
            cost_usd: 0.0,
            latency_ms: 0,
            stop_reason: String::new(),
            attempt: 1,
            phase: Phase::Main,
        }
    }
}

/// Where usage records go.
///
/// `record` RETURNS NOTHING AND CANNOT FAIL, by design. A sink is on the path of every
/// provider call, and a sink that could fail the call would mean a full disk turns into a
/// broken product. Implementations absorb their own failures and say so once — see
/// [`JsonlUsageSink`].
pub trait UsageSink: Send + Sync {
    fn record(&self, record: UsageRecord);
}

/// A sink that drops everything.
///
/// Exists so "no sink" is a deliberate object rather than an `Option<&dyn UsageSink>`
/// threaded through the loop. An `Option` would put a `if let Some(sink)` at every spend
/// site, and the one somebody forgets is a spend with no record — the exact thing this
/// module's rule forbids.
#[derive(Debug, Default)]
pub struct NullUsageSink;

impl UsageSink for NullUsageSink {
    fn record(&self, _record: UsageRecord) {}
}

/// A sink that keeps records in memory. For tests, and for a caller that wants a turn's
/// records without a file.
#[derive(Debug, Default)]
pub struct MemoryUsageSink {
    records: Mutex<Vec<UsageRecord>>,
}

impl MemoryUsageSink {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn records(&self) -> Vec<UsageRecord> {
        self.records.lock().map(|g| g.clone()).unwrap_or_default()
    }

    pub fn len(&self) -> usize {
        self.records.lock().map(|g| g.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl UsageSink for MemoryUsageSink {
    fn record(&self, record: UsageRecord) {
        if let Ok(mut g) = self.records.lock() {
            g.push(record);
        }
    }
}

/// One JSON object per line, appended to a file, mode `0600`.
///
/// **BEST-EFFORT AND NEVER FATAL.** A write failure is reported to stderr ONCE per sink and
/// then swallowed. Once, rather than per record, because the failure that actually happens
/// is a full disk or a read-only mount, which fails on every subsequent call — and a sink
/// that printed a line per failure would turn one problem into a log flood that hides it.
///
/// The rejected alternative was buffering in memory and retrying. It converts a disk
/// problem into a memory problem on a long-running process, and it means the records most
/// likely to be lost are the ones from the turn that mattered.
pub struct JsonlUsageSink {
    path: PathBuf,
    /// Serialises writes within the process, so two concurrent turns cannot interleave
    /// halves of two lines. (`O_APPEND` makes a single `write` atomic for small records on
    /// the platforms here; the lock makes that not something to rely on.)
    lock: Mutex<()>,
    complained: AtomicBool,
}

impl JsonlUsageSink {
    /// Append records to `path`, creating it and its parent directory if needed.
    ///
    /// Construction reports a failure to CREATE the file, because a caller that named a
    /// path it cannot write should hear about it at startup rather than discovering an
    /// empty ledger a month later. Failures after that are the best-effort ones above.
    pub fn open(path: impl Into<PathBuf>) -> std::io::Result<Self> {
        let path = path.into();
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        // Create it now, with the right mode, so the mode is ours rather than the umask's.
        drop(open_private_append(&path)?);
        Ok(JsonlUsageSink {
            path,
            lock: Mutex::new(()),
            complained: AtomicBool::new(false),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn complain_once(&self, e: &std::io::Error) {
        if !self.complained.swap(true, Ordering::Relaxed) {
            eprintln!(
                "jesse-agent: warning usage records are not being written ({e}); \
                 further failures on this sink are silent"
            );
        }
    }
}

impl UsageSink for JsonlUsageSink {
    fn record(&self, record: UsageRecord) {
        let line = match serde_json::to_string(&record) {
            Ok(l) => l,
            Err(e) => {
                self.complain_once(&std::io::Error::other(e));
                return;
            }
        };
        let _guard = self.lock.lock();
        let write = || -> std::io::Result<()> {
            let mut f = open_private_append(&self.path)?;
            f.write_all(line.as_bytes())?;
            f.write_all(b"\n")
            // NO `sync_all` HERE, unlike the thread store's append. The asymmetry is
            // deliberate: losing the last usage line to a crash costs one row of a ledger
            // that the provider's own billing is the authority for, while losing the last
            // thread append costs the conversation. Paying an fsync per provider call to
            // protect the cheaper of the two would be the wrong trade.
        };
        if let Err(e) = write() {
            self.complain_once(&e);
        }
    }
}

fn open_private_append(path: &Path) -> std::io::Result<std::fs::File> {
    let mut opts = OpenOptions::new();
    opts.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    opts.open(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn a_record() -> UsageRecord {
        UsageRecord {
            turn_id: "turn-1".into(),
            conversation_id: "direct-abc".into(),
            wire: Wire::Chat,
            model: "some-model".into(),
            provider_request_id: Some("req_9".into()),
            input_tokens: Some(120),
            output_tokens: Some(30),
            cost_usd: 0.0012,
            latency_ms: 840,
            stop_reason: "tool_use".into(),
            attempt: 2,
            phase: Phase::ToolFollowup,
            ..UsageRecord::at(SystemTime::UNIX_EPOCH + Duration::from_secs(1_788_048_000))
        }
        .with_scope(&Scope::new("acme", "jeremy", "default"))
    }

    #[test]
    fn a_record_serialises_flat_and_carries_the_scope() {
        let json = serde_json::to_string(&a_record()).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["v"], 1);
        assert_eq!(v["ts"], "2026-08-30T00:00:00Z");
        assert_eq!(v["tenant"], "acme");
        assert_eq!(v["user"], "jeremy");
        assert_eq!(v["workspace"], "default");
        assert_eq!(v["wire"], "chat");
        assert_eq!(v["phase"], "tool_followup");
        assert_eq!(v["attempt"], 2);
        // An absent count is ABSENT, not zero.
        assert!(v.get("cache_write_tokens").is_none());
    }

    #[test]
    fn a_record_carries_no_content_fields() {
        // The property `bridge/src/turntrace.rs` asserts for its timing log, asserted here
        // for the same reason: this file is greppable, tailable and pasteable.
        let json = serde_json::to_string(&a_record()).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
        for forbidden in [
            "text",
            "prompt",
            "answer",
            "content",
            "messages",
            "arguments",
            "result",
            "tool",
            "tools",
            "system",
        ] {
            assert!(
                !keys.iter().any(|k| k.as_str() == forbidden),
                "a usage record must not carry a {forbidden:?} field"
            );
        }
    }

    #[test]
    fn the_memory_sink_keeps_records_in_order() {
        let sink = MemoryUsageSink::new();
        assert!(sink.is_empty());
        let mut second = a_record();
        second.turn_id = "turn-2".into();
        sink.record(a_record());
        sink.record(second);
        let got = sink.records();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].turn_id, "turn-1");
        assert_eq!(got[1].turn_id, "turn-2");
    }

    #[test]
    fn the_jsonl_sink_appends_one_line_per_record_and_reopens() {
        let path = std::env::temp_dir().join(format!(
            "jesse-agent-usage-{}-{}.jsonl",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        {
            let sink = JsonlUsageSink::open(&path).unwrap();
            sink.record(a_record());
            sink.record(a_record());
        }
        {
            // A second sink over the same path APPENDS; it does not truncate.
            let sink = JsonlUsageSink::open(&path).unwrap();
            sink.record(a_record());
        }
        let body = std::fs::read_to_string(&path).unwrap();
        assert_eq!(body.lines().count(), 3);
        for line in body.lines() {
            let v: serde_json::Value = serde_json::from_str(line).unwrap();
            assert_eq!(v["turn_id"], "turn-1");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn a_write_failure_is_absorbed_rather_than_propagated() {
        // The sink's contract: `record` cannot fail, so a sink whose file has gone away
        // must keep taking records without panicking or blocking.
        let path = std::env::temp_dir().join(format!(
            "jesse-agent-usage-gone-{}-{}.jsonl",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let sink = JsonlUsageSink::open(&path).unwrap();
        std::fs::remove_file(&path).ok();
        // Point it at a directory that cannot hold a file, so the append genuinely fails.
        let sink = JsonlUsageSink {
            path: path.join("nope").join("nope.jsonl"),
            ..sink
        };
        sink.record(a_record());
        sink.record(a_record());
    }
}
