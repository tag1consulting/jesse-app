//! The day file's **intent journal** — the durable record that makes an app
//! mutation survive a crash, a race with a running agent turn, and a morning
//! rebuild that lands between the two.
//!
//! ## The race this exists for
//!
//! The bridge is not the only writer of `Today.md`. An agent turn edits it too,
//! and a turn is a child process the bridge cannot reach into: it reads the file
//! at some point, thinks for minutes, and writes back a whole file composed from
//! the copy it read. If the phone checks a box in that window, the child's write
//! lands afterwards and **silently reverts it** — the checkbox pops back open and
//! nothing anywhere records that it was ever ticked.
//!
//! The obvious fix — make a checkbox tap wait for the write lock — is the wrong
//! one. A turn may legitimately run for minutes, and a UI that freezes for
//! minutes on a tap is broken. So the bridge does the opposite: **it never blocks
//! a mutation on the turn lock.** It writes the intent down first, applies it
//! immediately when no turn is mid-write, parks it when one is, and **replays
//! every unapplied intent at turn completion**. The clobber still happens; it is
//! simply repaired within milliseconds of the turn ending, by re-applying the
//! intent against whatever the agent actually wrote.
//!
//! That ordering — **journal, then edit** — is what makes it crash-safe as well.
//! An intent on disk with its effect not yet in the file is exactly the state
//! replay is built to resolve, so a bridge killed between the two recovers on the
//! next replay rather than losing the tap.
//!
//! ## Why an intent is recorded by IDENTITY, not by id or by byte offset
//!
//! A byte offset is dead on arrival: the file is rewritten in full every morning
//! and edited by hand in between. An id is better but still not enough —
//! [`today_id`] hashes the **section name** along with the lead, so an item moved
//! between sections legitimately gets a NEW id, and a `-2` duplicate suffix can
//! shift when a twin appears or disappears.
//!
//! So an intent stores the three inputs the identity contract is actually built
//! from — section, lead, `(Added …)` date — and re-finds its item by re-parsing
//! the file at replay time. The recorded `id` is carried too, but only for the
//! client's correlation and the log line; nothing resolves by it.
//!
//! ## Every journaled effect is IDEMPOTENT
//!
//! Replay re-applies anything whose effect is absent, so an effect that is not
//! idempotent would double-apply. `check` is naturally idempotent. `up` and
//! `down` are NOT — applying `up` twice moves an item two rows — so a move is
//! never journaled as a relative op. It is resolved at request time into an
//! absolute [`Landing`]: *immediately above item X*, or *last in section S*.
//! That form can be both verified ("is it already there?") and re-applied any
//! number of times with the same result.

use crate::*;

/// The most intents the journal will hold. Older entries are dropped first.
///
/// This is a **safety valve, not a budget**. In normal operation the journal is
/// empty: an intent lives only for the span of one file write, or for the
/// remainder of one agent turn. It grows only when something is wrong — a wedged
/// turn holding the lock, or a bridge that keeps crashing before replay — and in
/// that state an unbounded file is a second failure on top of the first.
pub const JOURNAL_CAP: usize = 200;

/// Where an item should come to rest, in a form that survives a rebuild and can
/// be applied repeatedly without moving twice.
///
/// Both variants are **section-relative and anchored to content**, never to a
/// line number: `Above` names its anchor by the same identity triple an intent
/// uses for its own item, so the anchor is re-found by re-parsing rather than
/// remembered as a position.
#[derive(serde::Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "where", rename_all = "camelCase")]
pub enum Landing {
    /// Immediately above the item with this identity, inside the target section.
    /// If that anchor is gone at replay time, the move degrades to [`Landing::Last`]
    /// rather than failing — the item still lands in the right section.
    Above {
        lead: String,
        #[serde(default)]
        added_date: String,
    },
    /// Last item of the target section — which is also what "top of section"
    /// resolves to when the section has no other items.
    Last,
}

/// What an intent does to the file.
#[derive(serde::Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "effect", rename_all = "camelCase")]
pub enum Effect {
    /// Flip the checkbox, and (when checking with evidence) carry the
    /// `app-completed` sub-line with it. `stamp` is the already-normalized
    /// `YYYY-MM-DD HH:MM` the sub-line is written with, so a replay writes the
    /// time the tap happened rather than the time the replay ran.
    Check {
        checked: bool,
        #[serde(default)]
        evidence: Option<String>,
        stamp: String,
    },
    /// Splice the item to `landing` inside `to_section`.
    Move {
        to_section: String,
        landing: Landing,
    },
}

/// One journaled intent: what to do, and enough identity to re-find the item it
/// applies to after an arbitrary rebuild of the file.
#[derive(serde::Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Intent {
    /// Monotonic within a journal file; replay applies in this order.
    pub seq: u64,
    /// The id the client used. Correlation and logging ONLY — never resolution
    /// (see the module docs on why an id is not a stable handle).
    pub id: String,
    /// The section the item was in when the intent was made.
    pub section: String,
    /// The item's lead, as the identity contract normalizes it.
    pub lead: String,
    /// The `(Added …)` date, or empty.
    #[serde(default)]
    pub added_date: String,
    /// The day file's own date when the intent was made. Replay refuses anything
    /// older than the file it is replaying into, so yesterday's tap can never
    /// re-apply itself to today's rebuilt day.
    #[serde(default)]
    pub date: String,
    /// The client's ISO8601 instant, carried verbatim for the audit trail.
    #[serde(default)]
    pub at: String,
    pub effect: Effect,
}

impl Intent {
    /// Whether `item` is the item this intent is about, by the identity contract's
    /// three inputs rather than by the derived id.
    fn matches(&self, item: &TodayItem, section: &str) -> bool {
        section == self.section
            && normalize_lead(&item.lead) == normalize_lead(&self.lead)
            && item.added_date.as_deref().unwrap_or_default() == self.added_date
    }

    /// The section this intent's item should end up in — the destination for a
    /// move, the current section for a check.
    pub fn target_section(&self) -> &str {
        match &self.effect {
            Effect::Move { to_section, .. } => to_section,
            Effect::Check { .. } => &self.section,
        }
    }
}

/// Whether an item currently satisfies a landing inside `section`.
fn landing_satisfied(section: &TodaySection, item_index: usize, landing: &Landing) -> bool {
    match landing {
        Landing::Last => item_index + 1 == section.items.len(),
        Landing::Above { lead, added_date } => match section.items.get(item_index + 1) {
            Some(next) => {
                normalize_lead(&next.lead) == normalize_lead(lead)
                    && next.added_date.as_deref().unwrap_or_default() == added_date
            }
            None => false,
        },
    }
}

/// Has this intent's effect already landed in the parsed file?
///
/// `None` means the ITEM ITSELF is gone — the rebuild dropped it — which is the
/// one case replay must not repair: re-adding a line the morning routine
/// deliberately removed would resurrect content the agent retired.
pub fn effect_present(snapshot: &TodaySnapshot, intent: &Intent) -> Option<bool> {
    // A move is judged in its DESTINATION section: once applied, that is where
    // the item lives, and its id has legitimately changed with it.
    let target = intent.target_section();
    if let Effect::Move { landing, .. } = &intent.effect {
        if let Some(section) = snapshot.sections.iter().find(|s| s.name == target) {
            if let Some(i) = section
                .items
                .iter()
                .position(|it| intent.matches(it, &section.name))
            {
                return Some(landing_satisfied(section, i, landing));
            }
        }
        // Not in the destination yet — but is it still in the file at all?
        return find_item(snapshot, intent).map(|_| false);
    }
    let item = find_item(snapshot, intent)?;
    match &intent.effect {
        Effect::Check {
            checked: true,
            evidence,
            stamp,
        } => {
            let sub_line_needed = evidence
                .as_deref()
                .map(str::trim)
                .is_some_and(|e| !e.is_empty());
            let sub_line_present = item.text.contains(&format!("app-completed {stamp}"));
            Some(item.checked && (!sub_line_needed || sub_line_present))
        }
        Effect::Check { checked: false, .. } => {
            Some(!item.checked && !item.text.contains("app-completed"))
        }
        Effect::Move { .. } => unreachable!("handled above"),
    }
}

/// Find the item an intent is about, anywhere in the document, by identity.
///
/// Searched in the intent's own section first and then everywhere else, because a
/// move's item may legitimately have been re-parented already. Lead items are
/// searched too so a vanished-vs-moved distinction is never made wrongly.
pub fn find_item<'a>(snapshot: &'a TodaySnapshot, intent: &Intent) -> Option<&'a TodayItem> {
    for section in &snapshot.sections {
        if let Some(it) = section
            .items
            .iter()
            .find(|it| intent.matches(it, &section.name))
        {
            return Some(it);
        }
    }
    snapshot
        .lead_items
        .iter()
        .find(|it| intent.matches(it, ""))
        .or_else(|| {
            // Last resort: the same lead + Added date in ANY section. A move's
            // item is legitimately re-parented, so its section no longer matches
            // either the recorded source or (before the move) the destination.
            snapshot
                .sections
                .iter()
                .flat_map(|s| s.items.iter())
                .find(|it| {
                    normalize_lead(&it.lead) == normalize_lead(&intent.lead)
                        && it.added_date.as_deref().unwrap_or_default() == intent.added_date
                })
        })
}

// ---- The journal file ------------------------------------------------------

/// Load the journal, tolerating every kind of damage by returning what parses.
///
/// An absent, unreadable or malformed journal is an EMPTY journal, never an
/// error: the day screen and the agent must both keep working when the bridge's
/// own bookkeeping is broken, and an unreadable journal costs at worst the
/// repair of a tap that was already written to the file or already lost.
pub fn load_intents(path: &Path) -> Vec<Intent> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return Vec::new();
    };
    let mut out: Vec<Intent> = value
        .get("intents")
        .and_then(|v| v.as_array())
        .map(|rows| {
            rows.iter()
                .filter_map(|r| serde_json::from_value::<Intent>(r.clone()).ok())
                .collect()
        })
        .unwrap_or_default();
    out.sort_by_key(|i| i.seq);
    out
}

/// Persist the journal atomically (temp + rename), mode 0600 — the same
/// discipline [`persist_flags`] uses, for the same reason: a half-written journal
/// read after a crash would be worse than no journal at all.
///
/// Best-effort. A failure is logged and never fatal: the alternative is failing
/// a checkbox tap because a bookkeeping file could not be written, and the tap
/// matters more than the record of it.
pub fn persist_intents(path: &Path, intents: &[Intent]) {
    let value = json!({ "v": 1, "intents": intents });
    let tmp = path.with_extension("json.tmp");
    let write = || -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(value.to_string().as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    if let Err(e) = write() {
        eprintln!("warning: could not persist the day-file intent journal: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

/// Append one intent, assigning it the next sequence number and enforcing
/// [`JOURNAL_CAP`] by dropping the OLDEST entries. Returns the assigned `seq`.
///
/// Dropping the oldest is the right end to drop from: the newest intents are the
/// ones the user just made and is still looking at, and an intent old enough to
/// be pushed out by 200 newer ones has almost certainly been overtaken anyway.
pub fn append_intent(path: &Path, mut intent: Intent) -> u64 {
    let mut intents = load_intents(path);
    let seq = intents.last().map_or(1, |i| i.seq + 1);
    intent.seq = seq;
    intents.push(intent);
    let overflow = intents.len().saturating_sub(JOURNAL_CAP);
    if overflow > 0 {
        eprintln!(
            "jesse-bridge: day-file intent journal is at its {JOURNAL_CAP}-entry cap; \
             dropping the {overflow} oldest"
        );
        intents.drain(..overflow);
    }
    persist_intents(path, &intents);
    seq
}

/// Drop one intent by `seq` — the "verified" prune, called once its effect is in
/// the file.
pub fn prune_intent(path: &Path, seq: u64) {
    let mut intents = load_intents(path);
    let before = intents.len();
    intents.retain(|i| i.seq != seq);
    if intents.len() != before {
        persist_intents(path, &intents);
    }
}

/// The intents currently pending, oldest first. Empty when no state dir is
/// configured — the journal, like every other bridge store, degrades to
/// in-memory-only (which for a journal means "no journal"), and the write path
/// then simply applies immediately.
pub fn pending_intents(cfg: &Config) -> Vec<Intent> {
    cfg.today_intents_file()
        .map(|p| load_intents(&p))
        .unwrap_or_default()
}

// ---- Applying and replaying ------------------------------------------------

/// Apply one intent to a source document, returning the new document.
///
/// The single place an intent becomes bytes: used by the immediate-apply path,
/// by replay, and by the read-your-writes merge, so all three can never disagree
/// about what an intent means.
pub fn apply_intent(src: &str, intent: &Intent) -> Result<String, SpliceError> {
    match &intent.effect {
        Effect::Check {
            checked,
            evidence,
            stamp,
        } => apply_check(src, intent, *checked, evidence.as_deref(), stamp),
        Effect::Move {
            to_section,
            landing,
        } => apply_landing(src, intent, to_section, landing),
    }
}

/// Merge the pending intents into a source document for READING.
///
/// This is what makes the app read its own writes instantly: a tap parked behind
/// a running turn is not in the file yet, but `GET /jesse/today` must still show
/// the box ticked, or the UI would visibly bounce back and the user would tap
/// again. An intent that cannot be applied to the current text is skipped
/// silently — this is a rendering path, and a snapshot is never worth failing.
pub fn merge_pending(src: &str, intents: &[Intent]) -> String {
    let mut out = src.to_string();
    for intent in intents {
        if let Ok(next) = apply_intent(&out, intent) {
            out = next;
        }
    }
    out
}

/// Replay the journal against the day file. **The turn-completion hook.**
///
/// Called from [`TurnLockRelease`]'s `Drop`, which runs when a turn ends however
/// it ended — success, error, timeout, panic, or the task abort a cancel
/// performs — and runs it AFTER the turn's locks are released, so the file is
/// nobody's mid-write by then.
///
/// Every intent leaves the journal on this pass: applied, verified as already
/// present, or dropped with a log line. That is deliberate — an intent that
/// survived a replay would be re-applied on every subsequent turn forever, and
/// an intent the file no longer has room for is a fact to record, not a task to
/// retry.
pub fn replay_after_turn(cfg: &Config, turns_still_in_flight: bool) {
    let Some(journal) = cfg.today_intents_file() else {
        return;
    };
    // Cheap pre-check OUTSIDE the file mutex: the journal is empty on the
    // overwhelming majority of turns, and a turn ending must not queue behind an
    // unrelated checkbox tap to learn that.
    if load_intents(&journal).is_empty() {
        return;
    }
    let _guard = day_file_lock();
    // PRUNE ONLY WHEN NOTHING ELSE IS RUNNING. Another turn still in flight may be
    // holding its own stale copy of the file, and dropping a verified intent while
    // it runs would leave that turn's write unrepairable — the exact hole this
    // machinery exists to close. Retention is bounded by JOURNAL_CAP either way.
    replay_locked(cfg, &journal, !turns_still_in_flight);
}

/// The replay body, with the day-file mutex ALREADY HELD.
///
/// Separated from [`replay_after_turn`] so the write path can run it inside its own
/// critical section without re-entering a non-reentrant mutex — which is also the
/// crash-recovery path: intents left unapplied by a killed bridge are repaired by
/// the next mutation rather than waiting for a turn that may not come.
///
/// `prune` splits the two jobs this does. REPAIR — re-applying effects that are
/// absent — is always safe and always runs. PRUNING is not: an intent may only be
/// forgotten once nothing is left that could still clobber it, which means no turn
/// in flight. Calling with `prune = false` repairs and keeps, so an already-applied
/// intent stays available to repair a write that has not happened yet.
pub fn replay_locked(cfg: &Config, journal: &Path, prune: bool) {
    let intents = load_intents(journal);
    if intents.is_empty() {
        return;
    }
    let day = day_file_path(cfg);
    let Ok(mut src) = std::fs::read_to_string(&day) else {
        // No day file to replay into. The intents are kept: the morning routine
        // may yet write one, and a tap is not lost because a file was briefly
        // absent.
        return;
    };
    let file_date = parse_today(&src).date.unwrap_or_default();
    let mut changed = false;
    for intent in intents {
        // DATE SCOPING. ISO dates compare correctly as strings, so this is
        // exactly "older than the file being replayed into". An intent from
        // yesterday must never re-apply itself to today's rebuilt day: the
        // morning routine's decision about what carries over is the agent's,
        // not a stale tap's.
        if !file_date.is_empty() && !intent.date.is_empty() && intent.date < file_date {
            eprintln!(
                "jesse-bridge: day-file intent {} ({}) is dated {} against a {} file; dropped",
                intent.seq, intent.id, intent.date, file_date
            );
            continue;
        }
        let snapshot = parse_today(&src);
        match effect_present(&snapshot, &intent) {
            None => eprintln!(
                "jesse-bridge: day-file intent {} ({}) refers to an item that is no longer in \
                 the file; dropped",
                intent.seq, intent.id
            ),
            Some(true) => {}
            Some(false) => match apply_intent(&src, &intent) {
                Ok(next) => {
                    src = next;
                    changed = true;
                    eprintln!(
                        "jesse-bridge: day-file intent {} ({}) was clobbered by a turn; re-applied",
                        intent.seq, intent.id
                    );
                }
                Err(e) => eprintln!(
                    "jesse-bridge: day-file intent {} ({}) could not be re-applied ({e:?}); dropped",
                    intent.seq, intent.id
                ),
            },
        }
    }
    if changed {
        if let Err(e) = write_day_file(&day, &src) {
            // The journal is NOT drained when the write failed — the intents are
            // still unapplied, and the next replay should try again.
            eprintln!("warning: could not write the day file during intent replay: {e}");
            return;
        }
    }
    if prune {
        persist_intents(journal, &[]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;

    const FULL: &str = include_str!("../tests/fixtures/today/full.md");

    fn tmp_journal() -> PathBuf {
        let d = std::env::temp_dir().join(format!("jesse-journal-{}", random_hex()));
        std::fs::create_dir_all(&d).unwrap();
        d.join("today-intents.json")
    }

    fn check_intent(lead: &str, section: &str, added: &str, checked: bool) -> Intent {
        Intent {
            seq: 0,
            id: today_id(section, lead, added),
            section: section.to_string(),
            lead: lead.to_string(),
            added_date: added.to_string(),
            date: "2026-03-03".to_string(),
            at: "2026-03-03T09:00:00Z".to_string(),
            effect: Effect::Check {
                checked,
                evidence: None,
                stamp: "2026-03-03 09:00".to_string(),
            },
        }
    }

    #[test]
    fn a_journal_round_trips_through_the_file() {
        let p = tmp_journal();
        let seq = append_intent(
            &p,
            check_intent("Reply to Ada", "Do Now", "2026-02-27", true),
        );
        assert_eq!(seq, 1);
        let back = load_intents(&p);
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].seq, 1);
        assert_eq!(back[0].section, "Do Now");
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn an_absent_or_corrupt_journal_loads_empty_rather_than_failing() {
        assert!(load_intents(Path::new("/nonexistent/jesse/today-intents.json")).is_empty());
        let p = tmp_journal();
        std::fs::write(&p, "{ this is not json").unwrap();
        assert!(load_intents(&p).is_empty(), "a corrupt journal reads empty");
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn the_journal_is_capped_at_200_dropping_the_oldest() {
        let p = tmp_journal();
        for n in 0..(JOURNAL_CAP + 25) {
            append_intent(
                &p,
                check_intent(&format!("Item number {n}"), "Do Now", "2026-03-03", true),
            );
        }
        let back = load_intents(&p);
        assert_eq!(back.len(), JOURNAL_CAP, "capped");
        assert_eq!(
            back[0].seq,
            (JOURNAL_CAP + 25) as u64 - JOURNAL_CAP as u64 + 1,
            "the OLDEST entries were the ones dropped"
        );
        assert_eq!(back.last().unwrap().seq, (JOURNAL_CAP + 25) as u64);
        let _ = std::fs::remove_file(&p);
    }

    #[test]
    fn effect_present_sees_an_applied_check_and_an_unapplied_one() {
        let snap = parse_today(FULL);
        // "Collect the glaze order" is already `[x]` in the fixture.
        let applied = check_intent("Collect the glaze order.", "Errands", "2026-03-02", true);
        assert_eq!(effect_present(&snap, &applied), Some(true));
        // "Reply to Ada…" is still `[ ]`.
        let absent = check_intent(
            "Reply to Ada about the firing schedule.",
            "Do Now",
            "2026-02-27",
            true,
        );
        assert_eq!(effect_present(&snap, &absent), Some(false));
    }

    #[test]
    fn effect_present_reports_a_vanished_item_as_none() {
        let snap = parse_today(FULL);
        let gone = check_intent("An item the rebuild deleted", "Do Now", "2026-03-01", true);
        assert_eq!(
            effect_present(&snap, &gone),
            None,
            "a vanished id must be distinguishable from an unapplied effect"
        );
    }

    #[test]
    fn replay_reapplies_an_intent_a_turn_clobbered() {
        let (cfg, vault, journal) = replay_fixture(FULL);
        let intent = check_intent(
            "Reply to Ada about the firing schedule.",
            "Do Now",
            "2026-02-27",
            true,
        );
        append_intent(&journal, intent);
        replay_after_turn(&cfg, false);

        let after = std::fs::read_to_string(vault.join("vault/Today.md")).unwrap();
        let snap = parse_today(&after);
        let it = snap
            .sections
            .iter()
            .flat_map(|s| s.items.iter())
            .find(|i| i.lead.starts_with("Reply to Ada"))
            .unwrap();
        assert!(it.checked, "the clobbered check was re-applied");
        assert!(
            load_intents(&journal).is_empty(),
            "and the intent was pruned"
        );
        let _ = std::fs::remove_dir_all(&vault);
    }

    #[test]
    fn replay_prunes_an_intent_whose_effect_is_already_there() {
        let (cfg, vault, journal) = replay_fixture(FULL);
        // Already `[x]` in the fixture — nothing to do.
        append_intent(
            &journal,
            check_intent("Collect the glaze order.", "Errands", "2026-03-02", true),
        );
        let before = std::fs::read_to_string(vault.join("vault/Today.md")).unwrap();
        replay_after_turn(&cfg, false);
        let after = std::fs::read_to_string(vault.join("vault/Today.md")).unwrap();
        assert_eq!(before, after, "a verified intent rewrites nothing");
        assert!(load_intents(&journal).is_empty(), "…and is pruned");
        let _ = std::fs::remove_dir_all(&vault);
    }

    #[test]
    fn replay_drops_an_intent_whose_item_vanished() {
        let (cfg, vault, journal) = replay_fixture(FULL);
        append_intent(
            &journal,
            check_intent("An item the rebuild deleted", "Do Now", "2026-03-01", true),
        );
        let before = std::fs::read_to_string(vault.join("vault/Today.md")).unwrap();
        replay_after_turn(&cfg, false);
        assert_eq!(
            std::fs::read_to_string(vault.join("vault/Today.md")).unwrap(),
            before,
            "a vanished item is never re-added"
        );
        assert!(
            load_intents(&journal).is_empty(),
            "and the intent is dropped"
        );
        let _ = std::fs::remove_dir_all(&vault);
    }

    #[test]
    fn replay_refuses_an_intent_older_than_the_file() {
        let (cfg, vault, journal) = replay_fixture(FULL);
        let mut stale = check_intent(
            "Reply to Ada about the firing schedule.",
            "Do Now",
            "2026-02-27",
            true,
        );
        // The fixture's day is 2026-03-03; this tap is from the day before.
        stale.date = "2026-03-02".to_string();
        append_intent(&journal, stale);
        let before = std::fs::read_to_string(vault.join("vault/Today.md")).unwrap();
        replay_after_turn(&cfg, false);
        assert_eq!(
            std::fs::read_to_string(vault.join("vault/Today.md")).unwrap(),
            before,
            "yesterday's tap must not re-apply to today's rebuilt day"
        );
        assert!(load_intents(&journal).is_empty());
        let _ = std::fs::remove_dir_all(&vault);
    }

    #[test]
    fn a_move_intent_is_verified_by_its_landing_not_by_its_op() {
        let snap = parse_today(FULL);
        let mut intent = check_intent(
            "Reply to Ada about the firing schedule.",
            "Do Now",
            "2026-02-27",
            true,
        );
        // Already directly above "Plain unbolded item…" in the fixture.
        intent.effect = Effect::Move {
            to_section: "Do Now".to_string(),
            landing: Landing::Above {
                lead: "Plain unbolded item with no trailer at all.".to_string(),
                added_date: String::new(),
            },
        };
        assert_eq!(
            effect_present(&snap, &intent),
            Some(true),
            "a landing already satisfied is not re-applied — this is what stops `up` \
             from moving an item twice"
        );
        intent.effect = Effect::Move {
            to_section: "Do Now".to_string(),
            landing: Landing::Last,
        };
        assert_eq!(effect_present(&snap, &intent), Some(false));
    }

    /// A config + vault + journal wired together for a replay test.
    fn replay_fixture(day: &str) -> (Config, PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!("jesse-replay-{}", random_hex()));
        std::fs::create_dir_all(root.join("vault")).unwrap();
        std::fs::write(root.join("vault/Today.md"), day).unwrap();
        let state = root.join("state");
        std::fs::create_dir_all(&state).unwrap();
        let cfg = Config {
            vault: root.to_string_lossy().into_owned(),
            state_dir: Some(state.to_string_lossy().into_owned()),
            ..test_config()
        };
        let journal = cfg.today_intents_file().unwrap();
        (cfg, root, journal)
    }
}
