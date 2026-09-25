//! A ticked strand step starts one agent turn: `Jeremy ticked <ID> in Strands/<Note>`.
//!
//! **This module reads the vault and never writes it.** It notices that a Queue,
//! Later or Running line in a `Strands/` note has become `[x]`, and hands the
//! agent one fixed sentence naming the note and the step. Everything that follows
//! — archiving the linked draft, moving the line to Done with the date and the
//! evidence, rewriting the status line, asking the one question the vault cannot
//! answer — is the vault skill's work, done by that turn. The bridge detects and
//! triggers; it does not close steps itself.
//!
//! ## Two ways a tick arrives, one ledger
//!
//! 1. **The note on the Studio changes.** A tick made in Obsidian on the Studio,
//!    or made anywhere and carried here by Obsidian Sync, lands as a checked line
//!    in the file. [`spawn_strand_ticks`] re-parses `Strands/` every
//!    [`SCAN_EVERY`] with the same [`crate::strands::parse_strand`] the board and
//!    the nightly audit use, so a tick means the same thing to all three.
//! 2. **The app says so.** `POST /jesse/strands/{slug}/ticks`. The phone's reader
//!    writes the tick into Obsidian's folder ON THE PHONE, and on 2026-09-24 that
//!    write never reached the Studio: Obsidian iOS does not see a file another app
//!    changed inside its folder, so its Sync never sent it. The app now reports
//!    the tick it wrote, and the report does not depend on Obsidian at all.
//!
//! Both feed [`TickLedger`], keyed on (note, step id), so a step reported by the
//! app AND later seen in the file triggers once.
//!
//! ## Why a scan, and not a file watch or the autocommit diff
//!
//! Twenty-odd small notes re-parsed every twenty seconds is a few milliseconds of
//! work, needs no new dependency, and cannot miss an event: it compares states,
//! not notifications. A kqueue/FSEvents watch has to handle the rename-over that
//! Obsidian and every atomic writer use, coalescing, and a watcher that silently
//! stops, and it would still need this same state comparison behind it. The
//! autocommit runs every fifteen minutes in a separate launchd job, so its diff
//! arrives too late and outside the bridge. A check on each `GET /jesse/strands`
//! would only fire when a phone happened to poll, which makes a tick made in
//! Obsidian on the Studio wait for an unrelated request.
//!
//! ## Once per tick, and never for a tick that was taken back
//!
//! * A newly checked step is PENDING first. It fires only once it has stayed
//!   checked for [`SETTLE_MS`]; a line unticked inside that window (in the file,
//!   or by the app reporting `checked: false`) is dropped and fires nothing.
//! * A fired step is recorded in `<state_dir>/strand-ticks.json` BEFORE anything
//!   else can see it again, and never fires again. The line the turn leaves behind
//!   is in Done, which is not a candidate; a copy of the checked line brought back
//!   by a sync merge is the same (note, id) and is ignored.
//! * One tick turn at a time. Two ticks in one note would otherwise be two agents
//!   editing the same file at once; the second waits for the first to finish.
//! * The FIRST scan on a bridge with no ledger file records every line already
//!   checked without firing. Those were ticked before this feature existed, and a
//!   deploy must not start a turn for each of them.

use crate::strands::{parse_strand, StrandSection, ARCHIVE_SEGMENT, STRANDS_DIR};
use crate::*;
use std::collections::{BTreeMap, BTreeSet};

/// How often the `Strands/` notes are re-read.
pub const SCAN_EVERY: Duration = Duration::from_secs(20);

/// How long a step must stay checked before its turn starts. Long enough to take
/// back a mis-tap, short enough that the turn is "within minutes".
pub const SETTLE_MS: u64 = 90_000;

/// Fired steps are forgotten after this long, so the ledger does not grow for
/// ever. Far past any sync delay that could bring a checked copy back.
const FIRED_RETENTION_MS: u64 = 90 * 24 * 60 * 60 * 1000;

/// The longest step id the app may report. Real ids are two or three characters
/// (`P1`, `A1d`); this only bounds what a request can make the bridge store.
const MAX_ID_LEN: usize = 32;

/// One step: the note's slug (`Family`) and the step's bold id (`P1`).
#[derive(serde::Serialize, serde::Deserialize, PartialEq, Eq, PartialOrd, Ord, Debug, Clone)]
pub struct TickKey {
    pub note: String,
    pub id: String,
}

impl TickKey {
    pub fn new(note: &str, id: &str) -> Self {
        TickKey {
            note: note.to_string(),
            id: id.to_string(),
        }
    }

    /// The one sentence the agent receives. The vault skill matches this form
    /// exactly, so it is built in one place and asserted by a test.
    pub fn sentence(&self) -> String {
        format!("Jeremy ticked {} in {STRANDS_DIR}/{}", self.id, self.note)
    }
}

/// Where a pending tick was seen. Only matters for cancelling: a tick the app
/// reported is not cancelled by the Studio's copy still showing `[ ]`, because
/// that copy is exactly the one Obsidian Sync may not have updated.
#[derive(serde::Serialize, serde::Deserialize, PartialEq, Eq, Debug, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum TickSource {
    Note,
    App,
}

#[derive(serde::Serialize, serde::Deserialize, PartialEq, Eq, Debug, Clone)]
struct Pending {
    #[serde(flatten)]
    key: TickKey,
    since_ms: u64,
    source: TickSource,
}

#[derive(serde::Serialize, serde::Deserialize, PartialEq, Eq, Debug, Clone)]
struct Fired {
    #[serde(flatten)]
    key: TickKey,
    at_ms: u64,
}

/// The persisted shape. Lists rather than maps so the file reads as a log.
#[derive(serde::Serialize, serde::Deserialize, Default, Debug)]
struct LedgerFile {
    #[serde(default)]
    seeded: bool,
    #[serde(default)]
    fired: Vec<Fired>,
    #[serde(default)]
    pending: Vec<Pending>,
}

#[derive(Default)]
struct Inner {
    seeded: bool,
    fired: BTreeMap<TickKey, u64>,
    pending: BTreeMap<TickKey, (u64, TickSource)>,
    /// The job id of the tick turn still running, if any.
    in_flight: Option<String>,
}

/// What a report from the app did.
#[derive(PartialEq, Eq, Debug, Clone, Copy)]
pub enum ReportOutcome {
    /// Recorded; the turn starts once the settle window has passed.
    Pending,
    /// An untick that took back a pending tick. Nothing will fire.
    Cancelled,
    /// This step's turn already started. Nothing changes.
    AlreadyFired,
    /// An untick of a step that had nothing pending. Nothing changes.
    Nothing,
}

impl ReportOutcome {
    pub fn label(self) -> &'static str {
        match self {
            ReportOutcome::Pending => "pending",
            ReportOutcome::Cancelled => "cancelled",
            ReportOutcome::AlreadyFired => "already_fired",
            ReportOutcome::Nothing => "nothing",
        }
    }
}

/// Every step ever triggered, every step waiting to, and the turn in flight.
pub struct TickLedger {
    file: Option<PathBuf>,
    inner: Mutex<Inner>,
}

impl TickLedger {
    /// Load the ledger from `file`, or start empty (and unseeded) when there is
    /// no file or no state dir. An unreadable file is logged and treated as
    /// absent, which re-seeds rather than firing for every checked line.
    pub fn new(file: Option<PathBuf>) -> Self {
        let mut inner = Inner::default();
        if let Some(path) = file.as_deref() {
            match std::fs::read(path) {
                Ok(bytes) => match serde_json::from_slice::<LedgerFile>(&bytes) {
                    Ok(f) => {
                        inner.seeded = f.seeded;
                        inner.fired = f.fired.into_iter().map(|x| (x.key, x.at_ms)).collect();
                        inner.pending = f
                            .pending
                            .into_iter()
                            .map(|x| (x.key, (x.since_ms, x.source)))
                            .collect();
                    }
                    Err(e) => eprintln!(
                        "jesse-bridge: WARNING: strand ticks: {} is not a ledger ({e}); \
                         starting over, already checked lines will be seeded, not fired",
                        path.display()
                    ),
                },
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => eprintln!(
                    "jesse-bridge: WARNING: strand ticks: cannot read {} ({e}); starting over",
                    path.display()
                ),
            }
        }
        TickLedger {
            file,
            inner: Mutex::new(inner),
        }
    }

    /// Fold one scan of the notes in: `checked` is every open step whose box is
    /// ticked right now. Returns the steps the first scan seeded, for the log.
    pub fn observe(&self, checked: &BTreeSet<TickKey>, now_ms: u64) -> Vec<TickKey> {
        let mut inner = self.inner.lock_ok();
        let mut seeded = Vec::new();
        if !inner.seeded {
            for key in checked {
                if !inner.fired.contains_key(key) {
                    inner.fired.insert(key.clone(), now_ms);
                    seeded.push(key.clone());
                }
            }
            inner.seeded = true;
        } else {
            for key in checked {
                if !inner.fired.contains_key(key) && !inner.pending.contains_key(key) {
                    inner
                        .pending
                        .insert(key.clone(), (now_ms, TickSource::Note));
                }
            }
            // Unticked in the file before its turn started: dropped. A tick the app
            // reported is left alone (see `TickSource`).
            inner
                .pending
                .retain(|key, (_, source)| *source == TickSource::App || checked.contains(key));
        }
        inner
            .fired
            .retain(|_, at| now_ms.saturating_sub(*at) < FIRED_RETENTION_MS);
        self.save(&inner);
        seeded
    }

    /// The app wrote a tick (`checked`) or an untick into a strand note.
    pub fn report(&self, key: TickKey, checked: bool, now_ms: u64) -> ReportOutcome {
        let mut inner = self.inner.lock_ok();
        let outcome = if inner.fired.contains_key(&key) {
            ReportOutcome::AlreadyFired
        } else if checked {
            // A second report of the same tick keeps the FIRST instant: the settle
            // window runs from when the box was ticked, not from the last retry.
            inner
                .pending
                .entry(key)
                .or_insert((now_ms, TickSource::App));
            ReportOutcome::Pending
        } else if inner.pending.remove(&key).is_some() {
            ReportOutcome::Cancelled
        } else {
            ReportOutcome::Nothing
        };
        self.save(&inner);
        outcome
    }

    /// The oldest pending step that has settled, if no tick turn is running.
    /// `running` answers whether a job id is still in flight.
    pub fn next_due(&self, now_ms: u64, running: impl Fn(&str) -> bool) -> Option<TickKey> {
        let mut inner = self.inner.lock_ok();
        if let Some(job) = inner.in_flight.clone() {
            if running(&job) {
                return None;
            }
            inner.in_flight = None;
        }
        inner
            .pending
            .iter()
            .filter(|(_, (since, _))| now_ms.saturating_sub(*since) >= SETTLE_MS)
            .min_by_key(|(key, (since, _))| (*since, (*key).clone()))
            .map(|(key, _)| key.clone())
    }

    /// The turn for `key` was accepted as `job_id`. From here on the step never
    /// fires again.
    pub fn mark_fired(&self, key: &TickKey, job_id: &str, now_ms: u64) {
        let mut inner = self.inner.lock_ok();
        inner.pending.remove(key);
        inner.fired.insert(key.clone(), now_ms);
        inner.in_flight = Some(job_id.to_string());
        self.save(&inner);
    }

    pub fn is_fired(&self, key: &TickKey) -> bool {
        self.inner.lock_ok().fired.contains_key(key)
    }

    pub fn pending_count(&self) -> usize {
        self.inner.lock_ok().pending.len()
    }

    fn save(&self, inner: &Inner) {
        let Some(path) = self.file.as_deref() else {
            return;
        };
        let file = LedgerFile {
            seeded: inner.seeded,
            fired: inner
                .fired
                .iter()
                .map(|(key, at)| Fired {
                    key: key.clone(),
                    at_ms: *at,
                })
                .collect(),
            pending: inner
                .pending
                .iter()
                .map(|(key, (since, source))| Pending {
                    key: key.clone(),
                    since_ms: *since,
                    source: *source,
                })
                .collect(),
        };
        let bytes = serde_json::to_vec_pretty(&file).unwrap_or_default();
        if let Err(e) = write_atomic(path, &bytes) {
            eprintln!(
                "jesse-bridge: WARNING: strand ticks: cannot write {} ({e})",
                path.display()
            );
        }
    }
}

// ---- Reading the notes -----------------------------------------------------

/// Whether a line in this section is a step that a tick closes. `### Later` sits
/// under the Queue in both layouts, so a tick there is a Queue tick.
fn is_open_section(section: StrandSection) -> bool {
    matches!(
        section,
        StrandSection::Queue | StrandSection::Later | StrandSection::Running
    )
}

/// The live notes: `Strands/*.md`, not `Strands/archive/`, not dot files.
fn strand_notes(notes_root: &Path) -> Vec<(String, String)> {
    let dir = notes_root.join(STRANDS_DIR);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() || path.extension().and_then(|e| e.to_str()) != Some("md") {
            continue;
        }
        let Some(slug) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        if slug.starts_with('.') || slug == ARCHIVE_SEGMENT {
            continue;
        }
        if let Ok(src) = std::fs::read_to_string(&path) {
            out.push((slug.to_string(), src));
        }
    }
    out
}

/// Every open step whose box is ticked, across every live note. A line with no
/// bold id cannot be named in the sentence and is left to the audit's `PARSE`.
pub fn checked_steps(notes_root: &Path) -> BTreeSet<TickKey> {
    let mut out = BTreeSet::new();
    for (slug, src) in strand_notes(notes_root) {
        for item in parse_strand(&slug, &src).items {
            if item.checked && is_open_section(item.section) && !item.id.is_empty() {
                out.insert(TickKey::new(&slug, &item.id));
            }
        }
    }
    out
}

/// Where one step stands in the Studio's copy of its note.
#[derive(PartialEq, Eq, Debug, Clone, Copy)]
pub enum StepState {
    /// In Queue, Later or Running: a tick of it is a real event.
    Open,
    /// Already in Done: whatever the app is reporting has been handled.
    Done,
}

/// The step `id` in `Strands/<slug>.md`, or `None` when the note or the step is
/// not there. The slug must already have passed `is_safe_slug`.
pub fn step_state(notes_root: &Path, slug: &str, id: &str) -> Option<StepState> {
    let path = notes_root.join(STRANDS_DIR).join(format!("{slug}.md"));
    let src = std::fs::read_to_string(path).ok()?;
    let items = parse_strand(slug, &src).items;
    let mine = || items.iter().filter(|i| i.id == id);
    if mine().any(|i| is_open_section(i.section)) {
        Some(StepState::Open)
    } else if mine().next().is_some() {
        Some(StepState::Done)
    } else {
        None
    }
}

// ---- The loop --------------------------------------------------------------

/// One pass: read the notes, fold them in, and start at most one turn.
/// Returns the job id of a turn it started.
pub async fn run_pass(st: &AppState, ledger: &TickLedger, now_ms: u64) -> Option<String> {
    if st.cfg.vault.is_empty() {
        return None;
    }
    let root = notes_root(&st.cfg);
    if !root.join(STRANDS_DIR).is_dir() {
        return None;
    }
    let checked = checked_steps(&root);
    for key in ledger.observe(&checked, now_ms) {
        eprintln!(
            "jesse-bridge: strand ticks: first scan: {}/{} was already checked, recorded without \
             a turn",
            key.note, key.id
        );
    }
    let jobs = st.jobs.clone();
    let key = ledger.next_due(now_ms, |job| {
        matches!(jobs.get(job), Some(JobState::Running))
    })?;
    fire(st, ledger, &key, now_ms).await
}

/// Start the turn for one settled tick, as a `tell` from Jeremy, and ask for the
/// completion push so the reply arrives on the phone as a conversation he can
/// answer. A turn the bridge refuses (rate limit, bad model) stays pending and
/// is tried again on the next pass; a turn that starts is recorded as fired
/// before this returns.
async fn fire(st: &AppState, ledger: &TickLedger, key: &TickKey, now_ms: u64) -> Option<String> {
    let req = JesseRequest::scheduled("tell", key.sentence(), None);
    match start_turn(st, req, None).await {
        Ok(TurnStart::Accepted {
            job_id,
            conversation_id,
        }) => {
            ledger.mark_fired(key, &job_id, now_ms);
            eprintln!(
                "jesse-bridge: strand ticks: FIRE {:?} job={job_id} conversation={conversation_id}",
                key.sentence()
            );
            // Flag for the completion push, then close the race the notify route closes:
            // a turn that already finished is pushed now.
            st.notify.insert(&job_id);
            notify_if_complete(
                st.apns.as_deref(),
                &st.devices,
                &st.notify,
                &st.jobs,
                &job_id,
                &st.conversations,
                &st.flags,
            )
            .await;
            Some(job_id)
        }
        Ok(TurnStart::Invalid { status, message }) | Err((status, message)) => {
            eprintln!(
                "jesse-bridge: WARNING: strand ticks: turn for {:?} refused ({status}): \
                 {message}; still pending",
                key.sentence()
            );
            None
        }
    }
}

/// Start the scan beside the nightly audit.
pub fn spawn_strand_ticks(st: AppState) {
    tokio::spawn(async move {
        loop {
            let now = system_time_to_ms(SystemTime::now());
            run_pass(&st, &st.strand_ticks, now).await;
            tokio::time::sleep(SCAN_EVERY).await;
        }
    });
}

// ---- The route ---------------------------------------------------------------

#[derive(serde::Deserialize)]
pub struct TickReport {
    pub id: String,
    pub checked: bool,
}

/// `POST /jesse/strands/{slug}/ticks` — the app wrote a tick (or an untick) into
/// its copy of a strand note.
///
/// `202` with `{ "state": "pending" | "cancelled" | "already_fired" | "nothing" |
/// "done" }`. `404` for a slug that is not a live note or an id that is not a step
/// in it. A step already in Done on the Studio answers `done` and records nothing:
/// the phone's copy is behind, not ahead.
pub async fn jesse_strand_tick(
    State(st): State<AppState>,
    UrlPath(slug): UrlPath<String>,
    headers: HeaderMap,
    Json(body): Json<TickReport>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    let id = body.id.trim();
    if !crate::strands::is_safe_slug(&slug)
        || id.is_empty()
        || id.len() > MAX_ID_LEN
        || id.chars().any(|c| c.is_control())
    {
        return Err((StatusCode::NOT_FOUND, "no step by that id".to_string()));
    }
    let state = match step_state(&notes_root(&st.cfg), &slug, id) {
        None => return Err((StatusCode::NOT_FOUND, "no step by that id".to_string())),
        Some(StepState::Done) => "done",
        Some(StepState::Open) => {
            let now = system_time_to_ms(SystemTime::now());
            st.strand_ticks
                .report(TickKey::new(&slug, id), body.checked, now)
                .label()
        }
    };
    eprintln!(
        "jesse-bridge: strand ticks: app reported {slug}/{id} checked={} -> {state}",
        body.checked
    );
    Ok((StatusCode::ACCEPTED, Json(json!({ "state": state }))).into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str =
        "---\ngroup: personal\nstate: active\nupdated: 2026-09-24\n---\n# Scratch\n\n\
**Now:** A scratch strand.\n\n## Drafts\n\
- [ ] **P1** Permesso kits. [[todo-list/Projects/drafts/p1]] (waits on: you)\n\
- [ ] **P2** Modulo sheet. [[todo-list/Projects/drafts/p2]]\n\
### Later\n- [ ] **B2** Bank letter.\n\
### Done\n- [x] 2026-09-14 **P0** Declaration.\n";

    fn scratch_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!("jesse-strandticks-{}", random_hex()));
        std::fs::create_dir_all(root.join(STRANDS_DIR)).unwrap();
        root
    }

    fn write_note(root: &Path, slug: &str, src: &str) {
        std::fs::write(root.join(STRANDS_DIR).join(format!("{slug}.md")), src).unwrap();
    }

    fn tick(src: &str, id: &str) -> String {
        src.replace(&format!("- [ ] **{id}**"), &format!("- [x] **{id}**"))
    }

    /// Drive the ledger the way the loop does, against a real directory, and
    /// return every step that came due (and was marked fired) along the way.
    fn drive(root: &Path, ledger: &TickLedger, now: u64) -> Vec<TickKey> {
        ledger.observe(&checked_steps(root), now);
        let mut fired = Vec::new();
        while let Some(key) = ledger.next_due(now, |_| false) {
            ledger.mark_fired(&key, "job", now);
            fired.push(key);
        }
        fired
    }

    fn seeded_ledger(root: &Path) -> TickLedger {
        let ledger = TickLedger::new(None);
        assert!(
            drive(root, &ledger, 0).is_empty(),
            "the first scan only seeds"
        );
        ledger
    }

    #[test]
    fn the_sentence_is_the_fixed_form() {
        assert_eq!(
            TickKey::new("Family", "P1").sentence(),
            "Jeremy ticked P1 in Strands/Family"
        );
    }

    #[test]
    fn a_checked_queue_line_produces_exactly_one_trigger() {
        let root = scratch_root();
        write_note(&root, "Scratch", NOTE);
        let ledger = seeded_ledger(&root);

        write_note(&root, "Scratch", &tick(NOTE, "P1"));
        assert!(
            drive(&root, &ledger, 1_000).is_empty(),
            "not before it settles"
        );
        let fired = drive(&root, &ledger, 1_000 + SETTLE_MS);
        assert_eq!(fired, vec![TickKey::new("Scratch", "P1")]);
        // Still checked on every later scan, and never again.
        for t in 1..20 {
            assert!(drive(&root, &ledger, 1_000 + SETTLE_MS + t * 20_000).is_empty());
        }
    }

    #[test]
    fn unticking_before_the_trigger_fires_produces_none() {
        let root = scratch_root();
        write_note(&root, "Scratch", NOTE);
        let ledger = seeded_ledger(&root);

        write_note(&root, "Scratch", &tick(NOTE, "P1"));
        assert!(drive(&root, &ledger, 1_000).is_empty());
        write_note(&root, "Scratch", NOTE);
        assert!(drive(&root, &ledger, 30_000).is_empty());
        assert!(drive(&root, &ledger, 1_000 + SETTLE_MS * 5).is_empty());
        assert_eq!(ledger.pending_count(), 0);
    }

    #[test]
    fn a_later_line_and_a_running_line_count_and_done_does_not() {
        let root = scratch_root();
        let running = NOTE.replace(
            "- [ ] **P2** Modulo sheet.",
            "- [ ] **P2** Modulo sheet. Launched 2026-09-20.",
        );
        write_note(&root, "Scratch", &running);
        let ledger = seeded_ledger(&root);
        write_note(&root, "Scratch", &tick(&tick(&running, "P2"), "B2"));
        assert!(drive(&root, &ledger, 1_000).is_empty());
        let fired = drive(&root, &ledger, 1_000 + SETTLE_MS);
        assert_eq!(
            fired,
            vec![TickKey::new("Scratch", "B2"), TickKey::new("Scratch", "P2")]
        );
    }

    #[test]
    fn the_first_scan_seeds_lines_already_checked_without_firing() {
        let root = scratch_root();
        write_note(&root, "Scratch", &tick(NOTE, "P1"));
        let ledger = TickLedger::new(None);
        assert!(drive(&root, &ledger, 0).is_empty());
        assert!(drive(&root, &ledger, SETTLE_MS * 3).is_empty());
        assert!(ledger.is_fired(&TickKey::new("Scratch", "P1")));
    }

    #[test]
    fn an_app_report_fires_once_even_when_the_file_never_changes() {
        let root = scratch_root();
        write_note(&root, "Scratch", NOTE);
        let ledger = seeded_ledger(&root);
        let key = TickKey::new("Scratch", "P1");
        assert_eq!(
            ledger.report(key.clone(), true, 1_000),
            ReportOutcome::Pending
        );
        // The Studio's copy still says `[ ]`: that must not cancel it.
        assert!(drive(&root, &ledger, 20_000).is_empty());
        assert_eq!(drive(&root, &ledger, 1_000 + SETTLE_MS), vec![key.clone()]);
        // Obsidian Sync delivers the `[x]` afterwards: the same step, no second turn.
        write_note(&root, "Scratch", &tick(NOTE, "P1"));
        assert!(drive(&root, &ledger, SETTLE_MS * 4).is_empty());
        assert_eq!(
            ledger.report(key, true, SETTLE_MS * 5),
            ReportOutcome::AlreadyFired
        );
    }

    #[test]
    fn an_app_untick_before_the_trigger_cancels_it() {
        let root = scratch_root();
        write_note(&root, "Scratch", NOTE);
        let ledger = seeded_ledger(&root);
        let key = TickKey::new("Scratch", "P1");
        assert_eq!(
            ledger.report(key.clone(), true, 1_000),
            ReportOutcome::Pending
        );
        assert_eq!(
            ledger.report(key.clone(), false, 5_000),
            ReportOutcome::Cancelled
        );
        assert!(drive(&root, &ledger, SETTLE_MS * 3).is_empty());
        assert_eq!(
            ledger.report(key, false, SETTLE_MS * 4),
            ReportOutcome::Nothing
        );
    }

    #[test]
    fn a_repeated_app_report_keeps_the_first_instant() {
        let ledger = TickLedger::new(None);
        ledger.observe(&BTreeSet::new(), 0);
        let key = TickKey::new("Scratch", "P1");
        ledger.report(key.clone(), true, 1_000);
        ledger.report(key.clone(), true, 60_000);
        assert_eq!(ledger.next_due(1_000 + SETTLE_MS, |_| false), Some(key));
    }

    #[test]
    fn one_tick_turn_at_a_time() {
        let root = scratch_root();
        write_note(&root, "Scratch", NOTE);
        let ledger = seeded_ledger(&root);
        write_note(&root, "Scratch", &tick(&tick(NOTE, "P1"), "P2"));
        ledger.observe(&checked_steps(&root), 1_000);
        let now = 1_000 + SETTLE_MS;
        let first = ledger.next_due(now, |_| true).unwrap();
        ledger.mark_fired(&first, "job-1", now);
        assert_eq!(ledger.next_due(now, |job| job == "job-1"), None);
        let second = ledger.next_due(now, |_| false).unwrap();
        assert_ne!(first, second);
    }

    #[test]
    fn the_ledger_survives_a_restart() {
        let root = scratch_root();
        write_note(&root, "Scratch", NOTE);
        let file = root.join("strand-ticks.json");
        let ledger = TickLedger::new(Some(file.clone()));
        assert!(drive(&root, &ledger, 0).is_empty());
        write_note(&root, "Scratch", &tick(NOTE, "P1"));
        assert_eq!(
            drive(&root, &ledger, SETTLE_MS).len(),
            0,
            "pending, not due"
        );
        assert_eq!(drive(&root, &ledger, SETTLE_MS * 2).len(), 1);

        // A restart: the step is still checked in the file and must not fire again,
        // and the next scan is not a first scan.
        let again = TickLedger::new(Some(file));
        assert!(drive(&root, &again, SETTLE_MS * 3).is_empty());
        write_note(&root, "Scratch", &tick(&tick(NOTE, "P1"), "P2"));
        assert!(drive(&root, &again, SETTLE_MS * 4).is_empty());
        assert_eq!(
            drive(&root, &again, SETTLE_MS * 6),
            vec![TickKey::new("Scratch", "P2")]
        );
    }

    #[test]
    fn archived_and_hidden_notes_are_not_read() {
        let root = scratch_root();
        std::fs::create_dir_all(root.join(STRANDS_DIR).join(ARCHIVE_SEGMENT)).unwrap();
        std::fs::write(
            root.join(STRANDS_DIR).join(ARCHIVE_SEGMENT).join("Old.md"),
            tick(NOTE, "P1"),
        )
        .unwrap();
        write_note(&root, ".Hidden", &tick(NOTE, "P1"));
        assert!(checked_steps(&root).is_empty());
    }

    #[test]
    fn step_state_tells_open_from_done_from_absent() {
        let root = scratch_root();
        write_note(&root, "Scratch", NOTE);
        assert_eq!(step_state(&root, "Scratch", "P1"), Some(StepState::Open));
        assert_eq!(step_state(&root, "Scratch", "B2"), Some(StepState::Open));
        assert_eq!(step_state(&root, "Scratch", "P0"), Some(StepState::Done));
        assert_eq!(step_state(&root, "Scratch", "Z9"), None);
        assert_eq!(step_state(&root, "Nope", "P1"), None);
    }

    // ---- The route -----------------------------------------------------------

    fn route_state(root: &Path) -> AppState {
        let vault = root.join("repo");
        let notes = vault.join(crate::config::VAULT_SUBDIR);
        std::fs::create_dir_all(notes.join(STRANDS_DIR)).unwrap();
        write_note(&notes, "Scratch", NOTE);
        AppState::new(Config {
            vault: vault.to_string_lossy().into_owned(),
            ..crate::testutil::test_config()
        })
    }

    async fn post_tick(
        st: &AppState,
        slug: &str,
        id: &str,
        checked: bool,
    ) -> Result<(StatusCode, Value), StatusCode> {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            "Bearer test-token".parse().unwrap(),
        );
        let res = jesse_strand_tick(
            State(st.clone()),
            UrlPath(slug.to_string()),
            headers,
            Json(TickReport {
                id: id.to_string(),
                checked,
            }),
        )
        .await
        .map_err(|(status, _)| status)?;
        let status = res.status();
        let bytes = axum::body::to_bytes(res.into_body(), 1 << 16)
            .await
            .unwrap();
        Ok((status, serde_json::from_slice(&bytes).unwrap()))
    }

    #[tokio::test]
    async fn the_route_records_a_tick_and_takes_it_back() {
        let st = route_state(&scratch_root());
        let (status, body) = post_tick(&st, "Scratch", "P1", true).await.unwrap();
        assert_eq!(status, StatusCode::ACCEPTED);
        assert_eq!(body["state"], "pending");
        assert_eq!(st.strand_ticks.pending_count(), 1);
        let (_, body) = post_tick(&st, "Scratch", "P1", false).await.unwrap();
        assert_eq!(body["state"], "cancelled");
        assert_eq!(st.strand_ticks.pending_count(), 0);
    }

    #[tokio::test]
    async fn the_route_answers_done_for_a_step_already_closed_and_records_nothing() {
        let st = route_state(&scratch_root());
        let (_, body) = post_tick(&st, "Scratch", "P0", true).await.unwrap();
        assert_eq!(body["state"], "done");
        assert_eq!(st.strand_ticks.pending_count(), 0);
    }

    #[tokio::test]
    async fn the_route_refuses_an_unknown_note_an_unknown_step_and_a_path() {
        let st = route_state(&scratch_root());
        for (slug, id) in [
            ("Nope", "P1"),
            ("Scratch", "Z9"),
            ("../Today", "P1"),
            ("Scratch", ""),
        ] {
            assert_eq!(
                post_tick(&st, slug, id, true).await.err(),
                Some(StatusCode::NOT_FOUND),
                "{slug}/{id}"
            );
        }
        assert_eq!(st.strand_ticks.pending_count(), 0);
    }
}
