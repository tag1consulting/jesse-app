//! **Emergency diet verify-queue + replay** (Piece 4) — the availability half of the
//! diet route. When a diet "Tell" runs the local pipeline but its BLOCKING hosted
//! verify fails TRANSPORT-class (hosted is unreachable — never a rejection verdict),
//! and the emergency fallback is armed, the BRIDGE (never a model) queues the already-
//! extracted entry to a pending file in the bridge's state directory and tells the
//! user it is queued for verification. On the next SUCCESSFUL hosted contact the queue
//! is replayed oldest-first through the EXACT existing verify-then-append path, so:
//!
//!   * **Nothing ever reaches the canonical CSVs unverified** — an entry is appended
//!     only after a real hosted `approve`/`correct` verdict, exactly as a live entry;
//!     the 100%-verify probation invariant holds through the outage.
//!   * **A rejected replay is never silently dropped** — it moves to a rejected file
//!     and surfaces in provenance.
//!   * **No double append** — an entry is atomically DEQUEUED (temp-write + rename)
//!     before it is verified/appended, so a second replay pass can never re-append it.
//!
//! CRASH DURABILITY (documented tradeoff): dequeue-first means a crash in the tiny
//! window between removing an entry from the pending file and committing its CSV rows
//! could drop that one entry. The alternative — append-first, remove-after — risks a
//! DOUBLE CSV append, which violates the stronger "nothing unverified / no double
//! append" invariant. We choose the weaker (single-entry loss on crash) over the
//! stronger violation. The daily audit's replay-backlog tripwire surfaces a stuck
//! queue either way.
//!
//! Safety invariant: the queue is authored entirely by deterministic bridge code. No
//! local model ever gains a write path here; the only model involved is the SAME
//! hosted verify child the live pipeline uses, and only its verdict admits an entry.

use crate::*;

/// The pending-verify queue file name under the bridge state dir.
pub const DIET_QUEUE_FILE: &str = "diet-verify-queue.jsonl";
/// The rejected-on-replay file name under the bridge state dir.
pub const DIET_REJECTED_FILE: &str = "diet-verify-rejected.jsonl";

/// One queued diet entry, awaiting a hosted verify. Persisted as one JSON line. Holds
/// the FULL-fidelity entries (via the diet types' serde derives) plus everything the
/// existing verify-then-append path needs: the utterance (for the verify prompt), the
/// local date the entry was logged (the CSV row date — preserved across an overnight
/// replay), and the tz offset (for the mirror).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct QueuedEntry {
    pub id: String,
    pub queued_ts: String,
    pub date: String,
    pub offset: String,
    pub utterance: String,
    pub entries: Vec<DietEntry>,
}

/// The file-backed queue. `None` paths mean no state dir is configured (persistence
/// off) → the queue is unavailable and the emergency diet path degrades to today's
/// hosted fall-through, exactly as without emergency.
pub struct DietQueue {
    pending: Option<PathBuf>,
    rejected: Option<PathBuf>,
}

impl DietQueue {
    /// Build the queue from config: files under `<state_dir>/`, or unavailable when no
    /// state dir is set.
    pub fn from_cfg(cfg: &Config) -> Self {
        match cfg.state_dir.as_deref() {
            Some(d) => DietQueue::from_dir(Path::new(d)),
            None => DietQueue {
                pending: None,
                rejected: None,
            },
        }
    }

    /// Build the queue rooted at an explicit directory (used by tests).
    pub fn from_dir(dir: &Path) -> Self {
        DietQueue {
            pending: Some(dir.join(DIET_QUEUE_FILE)),
            rejected: Some(dir.join(DIET_REJECTED_FILE)),
        }
    }

    /// Whether the queue can persist (a state dir is configured).
    pub fn is_available(&self) -> bool {
        self.pending.is_some()
    }

    /// Atomically append one queued entry to the pending file (create dirs as needed).
    /// A single `writeln!` under `O_APPEND` — one line, never interleaved.
    pub fn enqueue(&self, e: &QueuedEntry) -> std::io::Result<()> {
        let Some(path) = self.pending.as_ref() else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Unsupported,
                "diet queue unavailable (no state dir)",
            ));
        };
        append_json_line(path, e)
    }

    /// All pending entries, oldest-first (file order).
    pub fn pending(&self) -> Vec<QueuedEntry> {
        self.pending
            .as_deref()
            .map(read_json_lines)
            .unwrap_or_default()
    }

    /// All rejected entries (audit/test helper).
    pub fn rejected(&self) -> Vec<QueuedEntry> {
        self.rejected
            .as_deref()
            .map(read_json_lines)
            .unwrap_or_default()
    }

    /// Atomically remove and return the OLDEST pending entry, or `None` if empty.
    /// Rewrites the pending file without the popped entry via a temp file + rename, so
    /// the removal is crash-atomic (either the entry is still fully present, or fully
    /// gone — never a torn line).
    pub fn dequeue_oldest(&self) -> Option<QueuedEntry> {
        let path = self.pending.as_ref()?;
        let mut all = read_json_lines::<QueuedEntry>(path);
        if all.is_empty() {
            return None;
        }
        let first = all.remove(0);
        // Rewrite the remainder atomically (temp + rename). On any I/O error, do NOT
        // claim the entry (return None) — better to leave it queued than to drop it.
        if rewrite_json_lines(path, &all).is_err() {
            return None;
        }
        Some(first)
    }

    /// Append an entry to the rejected file (never a silent drop).
    pub fn record_rejected(&self, e: &QueuedEntry) -> std::io::Result<()> {
        let Some(path) = self.rejected.as_ref() else {
            return Ok(()); // no state dir → nothing to record (unavailable path)
        };
        append_json_line(path, e)
    }
}

/// The disposition of one replayed queue entry, decided PURELY from the verify result
/// and the queued entries — the exact same verdict logic as the live pipeline's Stage
/// 2 (`parse_verify_verdicts` + `resolve_verdict`). Pure and unit-tested.
#[derive(Debug, Clone, PartialEq)]
pub enum ReplayDisposition {
    /// Every entry passed verify (approved, or a trivially-safe correction) — append
    /// the (possibly corrected) entries.
    Approved {
        entries: Vec<DietEntry>,
        corrected: bool,
    },
    /// A verify verdict rejected an entry (or a correction wasn't trivially safe) —
    /// move the whole queued item to the rejected file. Never appended.
    Rejected,
    /// Verify itself failed (transport-class error) or returned unparseable verdicts —
    /// hosted is still not usable, so re-queue and stop the pass (retry next contact).
    Requeue,
}

/// Decide the disposition of a replayed entry from the verify child's raw result.
/// Mirrors the live pipeline's verify handling exactly, so a queued entry is admitted
/// on precisely the same evidence a live one is.
pub fn classify_replay(item: &QueuedEntry, verify: &Result<String, ApiError>) -> ReplayDisposition {
    let raw = match verify {
        Ok(s) => s,
        // Transport-class (hosted still down) → retry on the next successful contact.
        Err(_) => return ReplayDisposition::Requeue,
    };
    let verdicts = match parse_verify_verdicts(raw, item.entries.len()) {
        Ok(v) => v,
        // Unparseable verdicts: don't guess — re-queue for a cleaner replay later.
        Err(_) => return ReplayDisposition::Requeue,
    };
    let mut verified = Vec::with_capacity(item.entries.len());
    let mut corrected = false;
    for (entry, v) in item.entries.iter().zip(verdicts.iter()) {
        match resolve_verdict(entry, v) {
            Some(e) => {
                if e != *entry {
                    corrected = true;
                }
                verified.push(e);
            }
            None => return ReplayDisposition::Rejected,
        }
    }
    ReplayDisposition::Approved {
        entries: verified,
        corrected,
    }
}

/// Append verified entries to the vault's diet CSVs through the EXACT live path:
/// atomic append → pinned node hooks → git commit, with rollback on any failure. Used
/// only by replay; the live pipeline keeps its own inline copy so its behavior is
/// byte-for-byte unchanged. Returns the row count on success.
pub async fn append_verified_entries(
    cfg: &Config,
    entries: &[DietEntry],
    date: &str,
) -> Result<usize, String> {
    let (food, exercise, weight) = split_entries(entries);
    let food_rows: Vec<String> = food.iter().map(|f| food_row(f, date)).collect();
    let ex_rows: Vec<String> = exercise.iter().map(|x| exercise_row(x, date)).collect();
    let wt_rows: Vec<String> = weight.iter().map(|w| weight_row(w, date)).collect();
    let logs_dir = Path::new(&cfg.vault).join("diet-logs");
    let vault = Path::new(&cfg.vault);
    let snapshot =
        append_rows_atomic(&logs_dir, &food_rows, &ex_rows, &wt_rows).map_err(|e| e.to_string())?;
    if let Err(e) = run_diet_hooks(vault).await {
        snapshot.rollback();
        return Err(e);
    }
    if let Err(e) = commit_diet_logs(vault, date, &local_hhmm()).await {
        snapshot.rollback();
        return Err(e);
    }
    Ok(entries.len())
}

/// Provenance for a queued entry (never content).
pub fn format_queued_provenance(id: &str) -> String {
    format!("jesse-bridge: diet verify queued id={id}")
}

/// Provenance for a replayed entry (never content).
pub fn format_replayed_provenance(id: &str, verdict: &str) -> String {
    format!("jesse-bridge: diet verify replayed id={id} verdict={verdict}")
}

/// The user-facing reply for a queued diet Tell. Content-free about the outage cause;
/// it just tells the user the entry is captured and will be verified.
pub fn queued_reply_text() -> String {
    "Logged locally and queued for verification — the hosted check is unavailable right \
     now, so Jesse saved your entry and will confirm and record it as soon as the hosted \
     model is reachable again."
        .to_string()
}

/// Replay the whole pending queue oldest-first on a successful hosted contact. Each
/// entry is dequeued atomically, verified through the live verify child, and either
/// appended (approve/correct), moved to rejected, or re-queued (hosted still down /
/// unparseable → stop the pass). Emits one provenance line per terminal disposition.
/// Best-effort: any append failure re-queues the entry and stops. A no-op when the
/// queue is unavailable or empty.
pub async fn replay_diet_queue(cfg: &Config, queue: &DietQueue) {
    if !queue.is_available() {
        return;
    }
    while let Some(item) = queue.dequeue_oldest() {
        let verify = run_diet_verify(
            cfg,
            &build_diet_verify_prompt(&item.utterance, &entries_to_json(&item.entries)),
            DIET_VERIFY_TIMEOUT_SECS,
        )
        .await;
        match classify_replay(&item, &verify) {
            ReplayDisposition::Approved { entries, .. } => {
                match append_verified_entries(cfg, &entries, &item.date).await {
                    Ok(_) => {
                        eprintln!("{}", format_replayed_provenance(&item.id, "approved"));
                    }
                    Err(e) => {
                        // Append/hook/commit failed — put it back and stop; retry later.
                        eprintln!(
                            "jesse-bridge: diet replay append failed id={} — re-queued: {e}",
                            item.id
                        );
                        let _ = queue.enqueue(&item);
                        break;
                    }
                }
            }
            ReplayDisposition::Rejected => {
                let _ = queue.record_rejected(&item);
                eprintln!("{}", format_replayed_provenance(&item.id, "rejected"));
            }
            ReplayDisposition::Requeue => {
                // Hosted verify still unusable — re-queue and stop the whole pass so we
                // don't hot-loop; the next successful contact retries from the top.
                let _ = queue.enqueue(&item);
                break;
            }
        }
    }
}

// ---- file helpers ----------------------------------------------------------

fn append_json_line<T: serde::Serialize>(path: &Path, value: &T) -> std::io::Result<()> {
    use std::io::Write as _;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let line = serde_json::to_string(value)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;
    writeln!(f, "{line}")
}

fn read_json_lines<T: serde::de::DeserializeOwned>(path: &Path) -> Vec<T> {
    let Ok(body) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    body.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

fn rewrite_json_lines<T: serde::Serialize>(path: &Path, values: &[T]) -> std::io::Result<()> {
    use std::io::Write as _;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(".diet-queue-{}.tmp", random_hex()));
    {
        let mut f = std::fs::File::create(&tmp)?;
        for v in values {
            let line = serde_json::to_string(v)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            writeln!(f, "{line}")?;
        }
        f.sync_all().ok();
    }
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("jesse-dietq-{}", random_hex()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn food_item(name: &str) -> QueuedEntry {
        QueuedEntry {
            id: format!("id-{name}"),
            queued_ts: "2026-07-15T09:00:00Z".to_string(),
            date: "2026-07-15".to_string(),
            offset: "+02:00".to_string(),
            utterance: format!("ate a {name}"),
            entries: vec![DietEntry::Food(FoodEntry {
                name: name.to_string(),
                meal: "Snack".to_string(),
                time: "09:00".to_string(),
                amount: Some("1".to_string()),
                unit: Some("piece".to_string()),
                kcal: Some(105.0),
                protein_g: Some(1.3),
                carbs_g: Some(27.0),
                fat_g: Some(0.3),
                fiber_g: Some(3.1),
                sodium_mg: None,
                satfat_g: None,
                sugar_g: None,
                potassium_mg: None,
                notes: Some("queued during outage".to_string()),
            })],
        }
    }

    #[test]
    fn enqueue_writes_a_line_and_pending_reads_it_back_full_fidelity() {
        let dir = tmp_dir();
        let q = DietQueue::from_dir(&dir);
        assert!(q.is_available());
        let item = food_item("banana");
        q.enqueue(&item).unwrap();
        let pending = q.pending();
        assert_eq!(pending.len(), 1);
        // Full fidelity: the lossy verify shape drops unit/notes, but the queue keeps them.
        assert_eq!(pending[0], item);
    }

    #[test]
    fn dequeue_is_oldest_first_and_exactly_once_no_double_take() {
        let dir = tmp_dir();
        let q = DietQueue::from_dir(&dir);
        q.enqueue(&food_item("apple")).unwrap();
        q.enqueue(&food_item("pear")).unwrap();
        // Oldest-first.
        assert_eq!(q.dequeue_oldest().unwrap().id, "id-apple");
        assert_eq!(q.dequeue_oldest().unwrap().id, "id-pear");
        // Exactly-once: nothing left, a second take returns None (no double append).
        assert!(q.dequeue_oldest().is_none());
        assert!(q.pending().is_empty());
    }

    #[test]
    fn queue_survives_a_bridge_restart() {
        let dir = tmp_dir();
        {
            let q = DietQueue::from_dir(&dir);
            q.enqueue(&food_item("oats")).unwrap();
        } // queue handle dropped — simulate a restart
        let q2 = DietQueue::from_dir(&dir); // fresh handle over the same dir
        let pending = q2.pending();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, "id-oats");
    }

    fn approve_verdicts(n: usize) -> String {
        let items: Vec<String> = (0..n)
            .map(|_| "{\"verdict\":\"approve\"}".to_string())
            .collect();
        format!("{{\"verdicts\":[{}]}}", items.join(","))
    }

    fn reject_verdicts(n: usize) -> String {
        let items: Vec<String> = (0..n)
            .map(|_| "{\"verdict\":\"reject\",\"reason\":\"aggregate\"}".to_string())
            .collect();
        format!("{{\"verdicts\":[{}]}}", items.join(","))
    }

    #[test]
    fn classify_replay_approves_on_approve_verdicts() {
        let item = food_item("banana");
        let d = classify_replay(&item, &Ok(approve_verdicts(1)));
        match d {
            ReplayDisposition::Approved { entries, corrected } => {
                assert_eq!(entries, item.entries, "approved entries unchanged");
                assert!(!corrected);
            }
            other => panic!("expected Approved, got {other:?}"),
        }
    }

    #[test]
    fn classify_replay_rejects_on_reject_verdicts() {
        let item = food_item("mystery plate");
        assert_eq!(
            classify_replay(&item, &Ok(reject_verdicts(1))),
            ReplayDisposition::Rejected
        );
    }

    #[test]
    fn classify_replay_requeues_on_transport_failure_or_unparseable() {
        let item = food_item("banana");
        // Transport-class verify failure → re-queue.
        let err: Result<String, ApiError> = Err((
            StatusCode::GATEWAY_TIMEOUT,
            "verify hit the run limit".into(),
        ));
        assert_eq!(classify_replay(&item, &err), ReplayDisposition::Requeue);
        // Unparseable verdicts → re-queue (don't guess).
        assert_eq!(
            classify_replay(&item, &Ok("not json".into())),
            ReplayDisposition::Requeue
        );
    }

    #[test]
    fn rejected_entry_moves_to_the_rejected_file_never_silently_dropped() {
        let dir = tmp_dir();
        let q = DietQueue::from_dir(&dir);
        let item = food_item("aggregate meal");
        q.enqueue(&item).unwrap();
        // Simulate a replay pass that dequeues then rejects.
        let taken = q.dequeue_oldest().unwrap();
        assert_eq!(
            classify_replay(&taken, &Ok(reject_verdicts(1))),
            ReplayDisposition::Rejected
        );
        q.record_rejected(&taken).unwrap();
        assert!(q.pending().is_empty(), "not left pending");
        let rejected = q.rejected();
        assert_eq!(rejected.len(), 1);
        assert_eq!(rejected[0].id, item.id);
    }

    #[test]
    fn no_state_dir_makes_the_queue_unavailable() {
        let mut cfg = crate::testutil::test_config();
        cfg.state_dir = None;
        let q = DietQueue::from_cfg(&cfg);
        assert!(!q.is_available());
        assert!(q.enqueue(&food_item("x")).is_err());
        assert!(q.pending().is_empty());
        assert!(q.dequeue_oldest().is_none());
    }

    #[test]
    fn provenance_lines_carry_only_the_id_and_verdict() {
        assert_eq!(
            format_queued_provenance("id-abc"),
            "jesse-bridge: diet verify queued id=id-abc"
        );
        assert_eq!(
            format_replayed_provenance("id-abc", "approved"),
            "jesse-bridge: diet verify replayed id=id-abc verdict=approved"
        );
    }
}
