//! **Persisted meal-corrections queue** — the durability half of correction
//! propagation (`JESSE_MEAL_LOG v2`).
//!
//! Phase 3's write-back only ever reached Apple Health when an app turn's *reply*
//! carried a `JESSE_MEAL_LOG` block. But most logging — and ALL corrections — happen
//! in non-app sessions (desktop Cowork logging on the Studio) with no app turn, so
//! there is no reply to carry the block. This queue is where those off-app meal events
//! land: an authenticated `POST /jesse/meal-corrections` writes a v2 batch here, and on
//! every terminal result the bridge MERGES the queued batches into the outgoing
//! `meal_log` payload (ahead of any block the turn itself produced) so they ride the
//! next app turn's poll/SSE result. Delivery is **at-least-once**: unacked batches
//! redeliver every turn; the app's id+content-hash idempotency makes redelivery
//! harmless, and its `corrections_seq` ack lets the bridge prune what it has applied.
//!
//! It carries meal events **generally** — inserts from off-phone logging as much as
//! corrections and retracts — hence the name. Nothing here ever writes to Apple Health
//! or the vault CSVs; the bridge only persists and relays. The app is the sole writer.
//!
//! **Durability model** (mirrors [`crate::dietqueue`]): one JSON line per batch under an
//! `O_APPEND` write (never interleaved), a monotonic batch `seq` from a separate counter
//! file (survives a fully-drained queue and a restart), and a temp-write + rename for the
//! prune rewrite (crash-atomic — a batch is either wholly present or wholly gone). When no
//! state dir is configured the queue is *unavailable*: enqueue errors loudly (a visible
//! failure at the source beats a silent drop) and delivery is a no-op.

use crate::*;
use std::collections::HashMap;

/// The persisted batch queue file under the bridge state dir (one JSON line per batch).
pub const MEAL_CORRECTIONS_QUEUE_FILE: &str = "meal-corrections-queue.jsonl";
/// The monotonic batch-seq counter file. Held separately from the queue so the seq keeps
/// increasing across a fully-pruned queue and a bridge restart (a reused seq could let a
/// stale ack prune a fresh batch).
pub const MEAL_CORRECTIONS_SEQ_FILE: &str = "meal-corrections.seq";

/// Max batches the queue may hold. At the cap a new `POST /jesse/meal-corrections` is
/// REJECTED (see [`EnqueueError::Full`]) rather than silently dropped — a visible failure
/// at the logging source beats losing a correction. Bounds unacked backlog and the merged
/// payload size.
pub const MAX_MEAL_CORRECTION_BATCHES: usize = 100;

/// One queued meal-events batch: a monotonic `seq` (the ack/prune key), when it was
/// enqueued (provenance only), and the v2 payload — `meals` upserts and `retract` ids.
/// Exactly the shape [`parse_meal_batch_v2`] produces, persisted verbatim.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct QueuedMealBatch {
    pub seq: u64,
    pub enqueued_ts: String,
    #[serde(default)]
    pub meals: Vec<Meal>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub retract: Vec<String>,
}

/// Why an [`enqueue`](MealCorrectionsQueue::enqueue) could not persist a batch. The
/// endpoint maps `Full` to a 429 (back off, the queue is saturated) and the rest to a
/// 503 — either way the source hears about it rather than losing the correction.
#[derive(Debug)]
pub enum EnqueueError {
    /// The queue is at [`MAX_MEAL_CORRECTION_BATCHES`]; the app must ack + drain first.
    Full,
    /// No state dir is configured, so the queue cannot persist (persistence off).
    Unavailable,
    /// The counter/queue file could not be read or written.
    Io(std::io::Error),
}

impl std::fmt::Display for EnqueueError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EnqueueError::Full => write!(
                f,
                "meal-corrections queue is full (cap {MAX_MEAL_CORRECTION_BATCHES}) — ack and drain first"
            ),
            EnqueueError::Unavailable => write!(f, "meal-corrections queue unavailable (no state dir)"),
            EnqueueError::Io(e) => write!(f, "meal-corrections queue I/O error: {e}"),
        }
    }
}

/// The file-backed meal-corrections queue. `None` paths mean no state dir is configured
/// (persistence off) → the queue is unavailable, exactly as [`crate::dietqueue`] degrades.
pub struct MealCorrectionsQueue {
    queue: Option<PathBuf>,
    seq: Option<PathBuf>,
}

impl MealCorrectionsQueue {
    /// Build from config: files under `<state_dir>/`, or unavailable when no state dir.
    pub fn from_cfg(cfg: &Config) -> Self {
        match cfg.state_dir.as_deref() {
            Some(d) => MealCorrectionsQueue::from_dir(Path::new(d)),
            None => MealCorrectionsQueue {
                queue: None,
                seq: None,
            },
        }
    }

    /// Build rooted at an explicit directory (used by tests).
    pub fn from_dir(dir: &Path) -> Self {
        MealCorrectionsQueue {
            queue: Some(dir.join(MEAL_CORRECTIONS_QUEUE_FILE)),
            seq: Some(dir.join(MEAL_CORRECTIONS_SEQ_FILE)),
        }
    }

    /// Whether the queue can persist (a state dir is configured).
    pub fn is_available(&self) -> bool {
        self.queue.is_some()
    }

    /// All pending batches, oldest-first by `seq` (file append order IS seq order, but we
    /// sort defensively so a hand-edited or reordered file still delivers in seq order).
    pub fn pending(&self) -> Vec<QueuedMealBatch> {
        let mut all: Vec<QueuedMealBatch> = self
            .queue
            .as_deref()
            .map(read_json_lines)
            .unwrap_or_default();
        all.sort_by_key(|b| b.seq);
        all
    }

    /// Number of pending batches.
    pub fn len(&self) -> usize {
        self.pending().len()
    }

    /// Whether the queue has no pending batches (or is unavailable).
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The highest pending batch seq, or `None` when empty. This is the value stamped as
    /// `corrections_seq` on a delivered `meal_log` and the seq the app acks.
    pub fn highest_seq(&self) -> Option<u64> {
        self.pending().iter().map(|b| b.seq).max()
    }

    /// Persist a batch of meal events and return its assigned monotonic `seq`. Rejects at
    /// the cap ([`EnqueueError::Full`]) and when persistence is off
    /// ([`EnqueueError::Unavailable`]). The seq is bumped and committed to the counter file
    /// BEFORE the batch line is appended, so a crash in the gap skips a seq (harmless —
    /// monotonicity, not density, is what the ack relies on) rather than reusing one.
    pub fn enqueue(&self, meals: Vec<Meal>, retract: Vec<String>) -> Result<u64, EnqueueError> {
        let (Some(queue_path), Some(seq_path)) = (self.queue.as_ref(), self.seq.as_ref()) else {
            return Err(EnqueueError::Unavailable);
        };
        if self.len() >= MAX_MEAL_CORRECTION_BATCHES {
            return Err(EnqueueError::Full);
        }
        // Next seq = one past the max of the persisted counter AND any seq still in the
        // queue, so a lost/rewound counter file can never re-issue a live seq.
        let counter = read_seq(seq_path);
        let queue_max = self.pending().iter().map(|b| b.seq).max().unwrap_or(0);
        let seq = counter.max(queue_max) + 1;
        write_seq_atomic(seq_path, seq).map_err(EnqueueError::Io)?;
        let batch = QueuedMealBatch {
            seq,
            enqueued_ts: rfc3339_utc(SystemTime::now()),
            meals,
            retract,
        };
        append_json_line(queue_path, &batch).map_err(EnqueueError::Io)?;
        eprintln!(
            "meal-corrections: enqueued seq={seq} ({} upserts, {} retracts)",
            batch.meals.len(),
            batch.retract.len()
        );
        Ok(seq)
    }

    /// Prune every batch with `seq <= acked_seq` (the app has applied them). Rewrites the
    /// queue file atomically (temp + rename). Returns the number of batches pruned. A no-op
    /// (returns 0) when unavailable or nothing is at/below the ack.
    pub fn prune_through(&self, acked_seq: u64) -> usize {
        let Some(path) = self.queue.as_ref() else {
            return 0;
        };
        let all: Vec<QueuedMealBatch> = read_json_lines(path);
        let keep: Vec<QueuedMealBatch> =
            all.iter().filter(|b| b.seq > acked_seq).cloned().collect();
        let pruned = all.len() - keep.len();
        if pruned == 0 {
            return 0;
        }
        // On rewrite failure, leave the file as-is (redeliver rather than risk a torn file).
        if rewrite_json_lines(path, &keep).is_err() {
            eprintln!(
                "meal-corrections: prune rewrite failed for ack seq={acked_seq} — left intact"
            );
            return 0;
        }
        eprintln!("meal-corrections: pruned {pruned} batch(es) at/below acked seq={acked_seq}");
        pruned
    }
}

/// Merge the persisted correction batches into the `meal_log` delivered on a terminal
/// result. Queued events are placed **ahead of** any block the turn's own reply produced
/// (off-app corrections predate this turn's fresh action), and the highest queued seq is
/// stamped as `corrections_seq` so the app knows what to ack.
///
/// The batches (in seq order) and then the turn's own block are collapsed to a **net
/// per-id operation, last-op-wins**: a repeated correction keeps only the newest values,
/// a retract-then-relog of the same id nets to the relog, and — critically — the delivered
/// payload therefore **never lists an id in both `meals` and `retract`** (which the app
/// rejects as malformed, dropping the whole delivery). A meal *move* (retract old id +
/// upsert a DIFFERENT new id) is preserved as one retract and one upsert. A no-op
/// (returns `turn` unchanged) when the queue is empty.
pub fn merge_meal_corrections(
    turn: Option<Directives>,
    queue: &MealCorrectionsQueue,
) -> Option<Directives> {
    let batches = queue.pending();
    if batches.is_empty() {
        return turn;
    }
    let highest = batches.iter().map(|b| b.seq).max();

    // The net operation for one id. `Upsert` carries the winning meal object (boxed — a
    // `Meal` dwarfs the unit `Retract`); `Retract` deletes + tombstones. Last write wins.
    enum Op {
        Upsert(Box<Meal>),
        Retract,
    }
    let mut order: Vec<String> = Vec::new();
    let mut ops: HashMap<String, Op> = HashMap::new();
    fn record(order: &mut Vec<String>, ops: &mut HashMap<String, Op>, id: String, op: Op) {
        if !ops.contains_key(&id) {
            order.push(id.clone());
        }
        ops.insert(id, op);
    }

    for b in &batches {
        for m in &b.meals {
            record(
                &mut order,
                &mut ops,
                m.id.clone(),
                Op::Upsert(Box::new(m.clone())),
            );
        }
        for r in &b.retract {
            record(&mut order, &mut ops, r.clone(), Op::Retract);
        }
    }

    // The turn's own extracted block applies LAST (a fresh action supersedes a stale queued
    // one for the same id). Detach its meal_log; keep any other directive fields intact.
    let (mut directives, turn_ml) = match turn {
        Some(mut d) => {
            let ml = d.meal_log.take();
            (d, ml)
        }
        None => (
            Directives {
                needs_health: None,
                meal_log: None,
            },
            None,
        ),
    };
    if let Some(ml) = turn_ml {
        for m in ml.meals {
            record(&mut order, &mut ops, m.id.clone(), Op::Upsert(Box::new(m)));
        }
        for r in ml.retract {
            record(&mut order, &mut ops, r.clone(), Op::Retract);
        }
    }

    let mut meals = Vec::new();
    let mut retract = Vec::new();
    for id in order {
        match ops.remove(&id).expect("every ordered id has an op") {
            Op::Upsert(m) => meals.push(*m),
            Op::Retract => retract.push(id),
        }
    }

    directives.meal_log = Some(MealLog {
        meals,
        retract,
        corrections_seq: highest,
    });
    Some(directives)
}

// ---- file helpers (mirrors dietqueue's, kept module-local so each queue owns its I/O) --

fn read_seq(path: &Path) -> u64 {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0)
}

fn write_seq_atomic(path: &Path, seq: u64) -> std::io::Result<()> {
    use std::io::Write as _;
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let tmp = parent.join(format!(".meal-corrections-seq-{}.tmp", random_hex()));
    {
        let mut f = std::fs::File::create(&tmp)?;
        writeln!(f, "{seq}")?;
        f.sync_all().ok();
    }
    std::fs::rename(&tmp, path)
}

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
    let tmp = parent.join(format!(".meal-corrections-{}.tmp", random_hex()));
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
        let d = std::env::temp_dir().join(format!("jesse-mealq-{}", random_hex()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn meal(id: &str, sodium: Option<f64>) -> Meal {
        Meal {
            id: id.to_string(),
            consumed_at: "2026-07-04T12:30:00+02:00".to_string(),
            name: format!("Meal {id}"),
            kcal: Some(410.0),
            protein_g: None,
            carbs_g: None,
            fat_g: None,
            fiber_g: None,
            sodium_mg: sodium,
            satfat_g: None,
            sugar_g: None,
            potassium_mg: None,
            calcium_mg: None,
            magnesium_mg: None,
        }
    }

    #[test]
    fn enqueue_assigns_monotonic_seq_and_reads_back_full_fidelity() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        assert!(q.is_available());
        let s1 = q.enqueue(vec![meal("a", Some(620.0))], vec![]).unwrap();
        let s2 = q.enqueue(vec![], vec!["b".into()]).unwrap();
        assert_eq!((s1, s2), (1, 2), "seq starts at 1 and increases");
        let pending = q.pending();
        assert_eq!(pending.len(), 2);
        assert_eq!(pending[0].seq, 1);
        assert_eq!(pending[0].meals[0].sodium_mg, Some(620.0));
        assert_eq!(pending[1].retract, vec!["b"]);
        assert_eq!(q.highest_seq(), Some(2));
    }

    #[test]
    fn queue_survives_a_bridge_restart() {
        let dir = tmp_dir();
        let seq;
        {
            let q = MealCorrectionsQueue::from_dir(&dir);
            seq = q.enqueue(vec![meal("a", Some(900.0))], vec![]).unwrap();
        } // handle dropped — simulate a restart
        let q2 = MealCorrectionsQueue::from_dir(&dir); // fresh handle, same dir
        let pending = q2.pending();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].seq, seq);
        assert_eq!(pending[0].meals[0].sodium_mg, Some(900.0));
    }

    #[test]
    fn seq_keeps_increasing_across_a_fully_drained_queue_and_restart() {
        let dir = tmp_dir();
        {
            let q = MealCorrectionsQueue::from_dir(&dir);
            let s = q.enqueue(vec![meal("a", None)], vec![]).unwrap();
            q.prune_through(s); // fully drained — queue file now empty
            assert!(q.is_empty());
        }
        // A restart with an empty queue must NOT reissue seq 1 (a stale ack of 1 would
        // then prune the fresh batch). The counter file carries the high-water mark.
        let q2 = MealCorrectionsQueue::from_dir(&dir);
        let s2 = q2.enqueue(vec![meal("b", None)], vec![]).unwrap();
        assert_eq!(s2, 2, "seq resumes past the drained batch, never reused");
    }

    #[test]
    fn prune_removes_at_and_below_the_ack_and_keeps_the_rest() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        q.enqueue(vec![meal("a", None)], vec![]).unwrap(); // seq 1
        q.enqueue(vec![meal("b", None)], vec![]).unwrap(); // seq 2
        q.enqueue(vec![meal("c", None)], vec![]).unwrap(); // seq 3
        let pruned = q.prune_through(2);
        assert_eq!(pruned, 2);
        let pending = q.pending();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].seq, 3, "only the unacked batch remains");
        // A repeat ack of an already-pruned seq is a no-op.
        assert_eq!(q.prune_through(2), 0);
    }

    #[test]
    fn cap_rejects_new_posts_but_never_silently_drops() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        for i in 0..MAX_MEAL_CORRECTION_BATCHES {
            q.enqueue(vec![meal(&format!("m{i}"), None)], vec![])
                .unwrap();
        }
        assert_eq!(q.len(), MAX_MEAL_CORRECTION_BATCHES);
        match q.enqueue(vec![meal("over", None)], vec![]) {
            Err(EnqueueError::Full) => {}
            other => panic!("expected Full at cap, got {other:?}"),
        }
        // Draining one makes room again.
        let lowest = q.pending()[0].seq;
        q.prune_through(lowest);
        assert!(q.enqueue(vec![meal("now-fits", None)], vec![]).is_ok());
    }

    #[test]
    fn no_state_dir_makes_the_queue_unavailable() {
        let mut cfg = crate::testutil::test_config();
        cfg.state_dir = None;
        let q = MealCorrectionsQueue::from_cfg(&cfg);
        assert!(!q.is_available());
        assert!(matches!(
            q.enqueue(vec![meal("x", None)], vec![]),
            Err(EnqueueError::Unavailable)
        ));
        assert!(q.pending().is_empty());
        assert_eq!(q.prune_through(5), 0);
    }

    // ---- merge --------------------------------------------------------------

    fn directives_with_meal_log(ml: MealLog) -> Option<Directives> {
        Some(Directives {
            needs_health: None,
            meal_log: Some(ml),
        })
    }

    #[test]
    fn merge_is_a_noop_when_queue_empty() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        // No directives → still None.
        assert!(merge_meal_corrections(None, &q).is_none());
        // A turn block passes through untouched.
        let turn = directives_with_meal_log(MealLog {
            meals: vec![meal("turn", None)],
            retract: vec![],
            corrections_seq: None,
        });
        let out = merge_meal_corrections(turn.clone(), &q).unwrap();
        assert_eq!(out.meal_log.unwrap().meals[0].id, "turn");
    }

    #[test]
    fn merge_delivers_queued_even_with_no_turn_block_and_stamps_seq() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        q.enqueue(vec![meal("q1", Some(900.0))], vec!["gone".into()])
            .unwrap();
        let out = merge_meal_corrections(None, &q).expect("queued corrections delivered");
        let ml = out.meal_log.unwrap();
        assert_eq!(ml.meals.len(), 1);
        assert_eq!(ml.meals[0].id, "q1");
        assert_eq!(ml.retract, vec!["gone"]);
        assert_eq!(
            ml.corrections_seq,
            Some(1),
            "highest queued seq stamped for ack"
        );
    }

    #[test]
    fn merge_places_queued_ahead_of_the_turn_block() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        q.enqueue(vec![meal("queued", None)], vec![]).unwrap();
        let turn = directives_with_meal_log(MealLog {
            meals: vec![meal("fresh", None)],
            retract: vec![],
            corrections_seq: None,
        });
        let ml = merge_meal_corrections(turn, &q).unwrap().meal_log.unwrap();
        assert_eq!(
            ml.meals.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["queued", "fresh"],
            "queued corrections come before this turn's own block"
        );
    }

    #[test]
    fn merge_collapses_repeated_correction_last_wins() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        q.enqueue(vec![meal("x", Some(600.0))], vec![]).unwrap(); // seq 1
        q.enqueue(vec![meal("x", Some(900.0))], vec![]).unwrap(); // seq 2 (corrected)
        let ml = merge_meal_corrections(None, &q).unwrap().meal_log.unwrap();
        assert_eq!(ml.meals.len(), 1, "the same id collapses to one upsert");
        assert_eq!(ml.meals[0].sodium_mg, Some(900.0), "newest values win");
        assert_eq!(ml.corrections_seq, Some(2));
    }

    #[test]
    fn merge_retract_then_relog_same_id_nets_to_relog_never_both_arrays() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        q.enqueue(vec![], vec!["x".into()]).unwrap(); // seq 1: deleted
        q.enqueue(vec![meal("x", Some(120.0))], vec![]).unwrap(); // seq 2: re-logged
        let ml = merge_meal_corrections(None, &q).unwrap().meal_log.unwrap();
        // The delivered payload must NOT list x in both arrays (the app would reject that).
        assert!(
            ml.retract.is_empty(),
            "relog supersedes the earlier retract"
        );
        assert_eq!(ml.meals.len(), 1);
        assert_eq!(ml.meals[0].id, "x");
        assert_eq!(ml.meals[0].sodium_mg, Some(120.0));
    }

    #[test]
    fn merge_preserves_a_meal_move_as_retract_old_plus_upsert_new() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        // Different ids (ids embed meal time): a move is retract-old + upsert-new.
        q.enqueue(vec![meal("snack-1630", None)], vec!["snack-1500".into()])
            .unwrap();
        let ml = merge_meal_corrections(None, &q).unwrap().meal_log.unwrap();
        assert_eq!(ml.meals.len(), 1);
        assert_eq!(ml.meals[0].id, "snack-1630");
        assert_eq!(ml.retract, vec!["snack-1500"]);
    }

    #[test]
    fn merge_turn_block_supersedes_a_stale_queued_correction_for_the_same_id() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        q.enqueue(vec![meal("x", Some(600.0))], vec![]).unwrap();
        let turn = directives_with_meal_log(MealLog {
            meals: vec![meal("x", Some(950.0))],
            retract: vec![],
            corrections_seq: None,
        });
        let ml = merge_meal_corrections(turn, &q).unwrap().meal_log.unwrap();
        assert_eq!(ml.meals.len(), 1);
        assert_eq!(
            ml.meals[0].sodium_mg,
            Some(950.0),
            "the turn's fresh action wins over the queued one"
        );
    }

    #[test]
    fn merge_keeps_a_needs_health_directive_alongside_the_merged_meal_log() {
        let dir = tmp_dir();
        let q = MealCorrectionsQueue::from_dir(&dir);
        q.enqueue(vec![meal("q", None)], vec![]).unwrap();
        let turn = Some(Directives {
            needs_health: Some(NeedsHealth {
                sections: vec!["daily".into()],
                metrics: vec![],
            }),
            meal_log: None,
        });
        let out = merge_meal_corrections(turn, &q).unwrap();
        assert!(out.needs_health.is_some(), "other directives are preserved");
        assert_eq!(out.meal_log.unwrap().meals[0].id, "q");
    }
}
