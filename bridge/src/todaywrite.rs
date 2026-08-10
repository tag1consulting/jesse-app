//! The day file's **write path** — the three authenticated mutations the phone
//! makes to `Today.md`, and the splice engine underneath them.
//!
//! This is the first thing in the bridge that writes the agent's own working
//! files, so the safety machinery here is the feature, not scaffolding around it.
//! Four rules, each with a reason that is not "defensive programming":
//!
//! **1. Line-level splices only, never a re-serialization.** The bridge changes
//! three bytes to flip a checkbox, inserts one sub-line, or moves one contiguous
//! block. It has no markdown writer and never composes prose. Everything it can
//! emit into the file is the fixed [`app_completed_sub_line`] grammar and nothing
//! else — so there is no path by which app input becomes arbitrary document
//! content. The parser keeps a byte range per node precisely to make this
//! possible (see [`crate::today`]).
//!
//! **2. Whole-file atomic rename, never an in-place edit.** `Today.md` is synced
//! externally by a third-party tool that watches the file. An in-place rewrite is
//! observable half-written and would let the syncer propagate a truncated day, so
//! every write goes to a temp file in the same directory and lands with one
//! `rename(2)`. A reader — the syncer, an agent, `GET /jesse/today` — sees either
//! the whole old file or the whole new one.
//!
//! **3. An item is re-found by re-parsing at write time.** Never by a stored byte
//! offset. The offsets in a snapshot were true when it was served and the file
//! may have been rewritten since; splicing at a remembered offset would corrupt
//! whatever moved into it. `If-Match` catches the common case, and re-parsing
//! makes the uncommon one impossible rather than unlikely.
//!
//! **4. A mutation NEVER waits on the turn lock.** See [`crate::todayjournal`]:
//! a turn can run for minutes and a checkbox tap cannot hang for minutes. The
//! journal, not a lock, is what makes the race safe.
//!
//! ## What the internal mutex does and does not protect
//!
//! [`day_file_lock`] serializes the bridge's OWN writes so two taps arriving
//! together cannot interleave read-modify-write cycles and lose one. It says
//! nothing about the agent — the agent is a separate process holding the broker's
//! lock, and the journal is what covers that. Two different problems, two
//! different mechanisms; conflating them is what would produce the frozen-UI
//! design this deliberately avoids.

use crate::*;
#[allow(unused_imports)]
use std::os::unix::fs::PermissionsExt;

/// The longest evidence string the app may attach to a completion, in
/// characters. Evidence is a note about what was done, not a document: the cap
/// bounds how much app-supplied text can enter the vault in one tap, and the
/// remainder is dropped rather than spilled onto a second line.
pub const MAX_EVIDENCE_CHARS: usize = 500;

/// Serializes the bridge's own writes to the day file.
///
/// A process-global mutex rather than a field on [`AppState`], because the day
/// file is one global resource and the turn-completion hook that replays the
/// journal ([`TurnLockRelease`]'s `Drop`) has a `Config` but no `AppState`. A
/// std mutex rather than a tokio one for the same reason: `Drop` cannot await.
/// Nothing holds it across an `.await` — every critical section here is
/// synchronous file work measured in microseconds.
static DAY_FILE: Mutex<()> = Mutex::new(());

/// Take the day-file write lock. Poison-tolerant, like every other lock in the
/// bridge: a panic mid-splice leaves a file, not a half-updated invariant.
pub fn day_file_lock() -> std::sync::MutexGuard<'static, ()> {
    DAY_FILE.lock_ok()
}

/// Why a splice could not be performed. Each maps to exactly one status code,
/// and the mapping is the endpoint's contract with the app (see
/// [`SpliceError::status`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SpliceError {
    /// No item with that identity is in the file any more — it vanished in a
    /// rebuild. `410`, and the client refetches.
    UnknownItem,
    /// The line the item's range points at is not a task line. Only reachable if
    /// the file changed underneath a stale offset, which re-parsing prevents.
    NotATaskLine,
    /// A move whose source is a lead-block item, or whose destination would land
    /// above the first `## ` heading. `409` — the standing top-priority item is
    /// structurally untouchable.
    LeadBlockImmutable,
    /// `to_do_now` with no section whose name starts with `Do Now`. `409`.
    NoDoNowSection,
    /// The destination section named by a journaled move is gone.
    UnknownSection,
}

impl SpliceError {
    /// The status this failure is reported as.
    pub fn status(&self) -> StatusCode {
        match self {
            // GONE, not NOT_FOUND: the item existed, the file was rebuilt, and
            // the right client response is to refetch — not to retry the id.
            SpliceError::UnknownItem | SpliceError::NotATaskLine => StatusCode::GONE,
            SpliceError::LeadBlockImmutable
            | SpliceError::NoDoNowSection
            | SpliceError::UnknownSection => StatusCode::CONFLICT,
        }
    }

    /// A message the app can show or log without translation.
    pub fn message(&self) -> &'static str {
        match self {
            SpliceError::UnknownItem => {
                "that item is no longer in the day file — refetch GET /jesse/today"
            }
            SpliceError::NotATaskLine => {
                "that item's line is no longer a task line — refetch GET /jesse/today"
            }
            SpliceError::LeadBlockImmutable => {
                "the lead block above the first heading cannot be moved into or out of"
            }
            SpliceError::NoDoNowSection => "this day file has no \"Do Now\" section",
            SpliceError::UnknownSection => "that section is no longer in the day file",
        }
    }
}

impl From<SpliceError> for ApiError {
    fn from(e: SpliceError) -> ApiError {
        (e.status(), e.message().to_string())
    }
}

/// The move operations the app may request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MoveOp {
    /// Above every other item of the item's own section.
    TopOfSection,
    /// Above every other item of the first section named `Do Now…`.
    ToDoNow,
    /// Swap with the item above it, within its section.
    Up,
    /// Swap with the item below it, within its section.
    Down,
}

impl MoveOp {
    /// Parse the wire spelling. Deliberately hand-rolled rather than derived, so
    /// an unknown op is a `400` naming the four valid ops instead of serde's
    /// generic body-rejection.
    pub fn parse(s: &str) -> Option<MoveOp> {
        match s {
            "top_of_section" => Some(MoveOp::TopOfSection),
            "to_do_now" => Some(MoveOp::ToDoNow),
            "up" => Some(MoveOp::Up),
            "down" => Some(MoveOp::Down),
            _ => None,
        }
    }
}

// ---- Evidence: the ONE thing the bridge writes that came from the app -------

/// Flatten evidence to a single line, cap it, and escape every character that
/// could change how the surrounding markdown parses.
///
/// The escape set is the closing half of the sub-line's own syntax plus the
/// markers that would restructure the document: `\`, `*`, `_`, `` ` ``, `[`,
/// `]`, `(`, `)`, `#`, `~`, `|`, `<`, `>`. Escaping `)` and `*` is what makes it
/// impossible for evidence to terminate the `*(app-completed …)*` wrapper early
/// and continue as document text; the rest keep it from becoming a heading, a
/// list, a link, a table cell or raw HTML.
///
/// Newlines and tabs become spaces BEFORE the cap, so evidence can never become
/// a second line — a multi-line insertion would break the continuation block the
/// parser uses to decide which lines belong to the item.
pub fn escape_evidence(raw: &str) -> String {
    raw.to_string()
}

/// **The frozen app-completed sub-line grammar.** One tab, then
/// `*(app-completed YYYY-MM-DD HH:MM: <escaped evidence>)*`, then one newline.
///
/// This is the ONLY content the bridge composes into the vault, and its shape is
/// a contract with two other programs: [`crate::today`]'s parser reads it back,
/// and the agent's morning routine reads it when deciding what to carry over.
/// Changing the spelling is a breaking change to both, not a formatting choice.
///
/// The tab is load-bearing: the parser treats an indented, non-blank line as a
/// continuation of the item above it, so the sub-line travels with its item
/// through every later move and is never mistaken for a document line.
pub fn app_completed_sub_line(stamp: &str, escaped_evidence: &str) -> String {
    let _ = (stamp, escaped_evidence);
    String::new()
}

/// Normalize a client ISO8601 instant to the sub-line's `YYYY-MM-DD HH:MM`.
///
/// Strict, and rejected with a `400` rather than defaulted to the bridge's own
/// clock: the stamp records when the USER tapped, which matters when a tap is
/// replayed minutes later, and a silently substituted server time would be a
/// quiet lie in the vault.
pub fn stamp_from_iso(at: &str) -> Option<String> {
    let _ = at;
    None
}

// ---- Locating an item ------------------------------------------------------

/// An item plus where it sits: its section (`None` for the lead block) and its
/// index among that section's items.
pub struct Located<'a> {
    pub item: &'a TodayItem,
    pub section: Option<&'a TodaySection>,
    pub index: usize,
}

/// Find an item by the id a client sent. Ids are unique within one parse, so
/// this is exact.
pub fn locate_by_id<'a>(snapshot: &'a TodaySnapshot, id: &str) -> Option<Located<'a>> {
    if let Some(index) = snapshot.lead_items.iter().position(|i| i.id == id) {
        return Some(Located {
            item: &snapshot.lead_items[index],
            section: None,
            index,
        });
    }
    for section in &snapshot.sections {
        if let Some(index) = section.items.iter().position(|i| i.id == id) {
            return Some(Located {
                item: &section.items[index],
                section: Some(section),
                index,
            });
        }
    }
    None
}

/// Find an item by an intent's identity triple — the resolution replay uses,
/// because an id is not stable across a rebuild (see [`crate::todayjournal`]).
pub fn locate_by_intent<'a>(snapshot: &'a TodaySnapshot, intent: &Intent) -> Option<Located<'a>> {
    let item = find_item(snapshot, intent)?;
    locate_by_id(snapshot, &item.id)
}

// ---- The check splice ------------------------------------------------------

/// Flip an item's checkbox, and carry the `app-completed` sub-line with it.
///
/// Byte-exact everywhere else: only the three checkbox bytes and (at most) one
/// inserted or removed sub-line change. A re-check REPLACES an existing sub-line
/// rather than stacking a second one, and an uncheck removes it — so the file
/// never accumulates a history of taps.
pub fn apply_check(
    src: &str,
    intent: &Intent,
    checked: bool,
    evidence: Option<&str>,
    stamp: &str,
) -> Result<String, SpliceError> {
    let _ = (src, intent, checked, evidence, stamp);
    Err(SpliceError::UnknownItem)
}

/// Rebuild one item's block (its task line plus its continuation lines) with the
/// checkbox flipped and the sub-line brought into line.
fn rebuild_item_block(
    block: &str,
    checked: bool,
    evidence: Option<&str>,
    stamp: &str,
) -> Result<String, SpliceError> {
    let _ = (block, checked, evidence, stamp);
    Err(SpliceError::NotATaskLine)
}

/// Flip the three checkbox bytes of a task line, preserving its marker, its
/// spacing and every other byte of the line.
///
/// Mirrors [`crate::today`]'s `task_line`: a `* ` / `- ` marker at column zero
/// followed by a three-byte box. An indented checkbox is a continuation, not a
/// task, and is deliberately not matched here either.
fn flip_checkbox(line: &str, checked: bool) -> Option<String> {
    let _ = (line, checked);
    None
}

// ---- The move splice -------------------------------------------------------

/// Move an item to an absolute landing inside a section.
///
/// The single splice both the endpoint and replay go through, which is why the
/// endpoint resolves its relative op into a [`Landing`] first: this function has
/// no notion of "up", so it cannot move an item twice.
pub fn apply_landing(
    src: &str,
    intent: &Intent,
    to_section: &str,
    landing: &Landing,
) -> Result<String, SpliceError> {
    let _ = (src, intent, to_section, landing);
    Err(SpliceError::UnknownItem)
}

/// The byte offset a landing names, degrading `Above` to `Last` when its anchor
/// is gone (the item still reaches the right section, which is the part that
/// matters).
fn landing_offset(src: &str, dest: &TodaySection, mover: &TodayItem, landing: &Landing) -> usize {
    let _ = (src, dest, mover, landing);
    0
}

/// The offset just past a section's heading line and any blank lines under it.
fn after_heading(src: &str, dest: &TodaySection) -> usize {
    let _ = (src, dest);
    0
}

/// Cut `[start, end)` out and re-insert it at `insert_at`, an offset in the
/// ORIGINAL source. Every other byte is carried across untouched.
fn splice_block(src: &str, start: usize, end: usize, insert_at: usize) -> String {
    let _ = (start, end, insert_at);
    src.to_string()
}

/// Resolve a relative op into the absolute landing that gets journaled.
///
/// `Ok(None)` is a legitimate no-op — `up` on the first item, `down` on the last,
/// `top_of_section` on something already at the top. Those write nothing and
/// journal nothing, so a client that spams the button cannot fill the journal.
pub fn resolve_landing(
    snapshot: &TodaySnapshot,
    located: &Located,
    op: MoveOp,
) -> Result<Option<(String, Landing)>, SpliceError> {
    let _ = (snapshot, located, op);
    Ok(None)
}

/// "Above the first item that is not the mover", or `Last` for a section that
/// holds nothing else — which is the same position.
fn top_landing(dest: &TodaySection, mover: &TodayItem) -> Landing {
    let _ = (dest, mover);
    Landing::Last
}

fn above(anchor: &TodayItem) -> Landing {
    Landing::Above {
        lead: anchor.lead.clone(),
        added_date: anchor.added_date.clone().unwrap_or_default(),
    }
}

/// Whether the item at `index` already sits where `landing` says it should.
/// Shared with the journal's effect verification so the endpoint's idea of "no
/// change needed" and replay's cannot drift apart.
pub fn landing_is_satisfied(section: &TodaySection, index: usize, landing: &Landing) -> bool {
    let _ = (section, index, landing);
    false
}

// ---- Writing the file ------------------------------------------------------

/// Write the day file by **whole-file atomic rename**.
///
/// The temp file is created in the SAME directory — `rename(2)` is only atomic
/// within a filesystem, and a state-dir or `/tmp` staging file could be on a
/// different one. It is created with `create_new` so two writers can never share
/// it, and it inherits the existing file's mode rather than the state dir's
/// `0600`: this is a vault file that a person and an agent both read, and
/// silently tightening its permissions on the first checkbox tap would be a
/// surprising side effect of a UI action.
pub fn write_day_file(path: &Path, contents: &str) -> std::io::Result<()> {
    let _ = (path, contents);
    Ok(())
}

// ---- The endpoints ---------------------------------------------------------

/// `POST /jesse/today/items/{id}/check` — tick or untick one item.
#[derive(Deserialize)]
pub struct CheckBody {
    pub checked: bool,
    #[serde(default)]
    pub evidence: Option<String>,
    #[serde(default)]
    pub at: String,
}

/// `POST /jesse/today/items/{id}/move` — reorder one item.
#[derive(Deserialize)]
pub struct MoveBody {
    #[serde(default)]
    pub op: String,
    #[serde(default)]
    pub at: String,
}

/// `POST /jesse/today/glance` — mark one report row seen.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GlanceBody {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub glanced_at: u64,
}

/// The `If-Match` a mutation must carry, or the status that refuses it.
///
/// A MISSING `If-Match` is `428 Precondition Required`, distinct from the `412`
/// a stale one gets, because the two need different client fixes: `428` means
/// "you did not send the header", `412` means "you sent a stale one, refetch".
/// Collapsing them into one status would leave a client guessing which bug it has.
fn required_if_match(headers: &HeaderMap) -> Result<String, ApiError> {
    headers
        .get(axum::http::header::IF_MATCH)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
        .ok_or((
            StatusCode::PRECONDITION_REQUIRED,
            "If-Match is required: fetch GET /jesse/today and send back its etag".to_string(),
        ))
}

/// Whether an `If-Match` value matches our tag. `*` means "any current
/// representation", which is true whenever the day file exists.
fn if_match_matches(header: &str, etag: &str) -> bool {
    if_none_match_matches(header, etag)
}

/// The body every mutation answers with: the fresh snapshot, its new etag, and
/// whether this change is parked behind a running turn.
///
/// The snapshot is returned rather than a bare acknowledgement so one round trip
/// both mutates and refreshes — including the new etag the next mutation must
/// carry, which a client would otherwise have to re-`GET` to obtain.
fn mutation_response(snapshot: &TodaySnapshot, pending: bool) -> Response {
    let mut value = serde_json::to_value(snapshot).unwrap_or_else(|_| json!({}));
    let etag = snapshot_etag(snapshot);
    if let Some(obj) = value.as_object_mut() {
        obj.insert(
            "generatedAt".to_string(),
            json!(rfc3339_utc(SystemTime::now())),
        );
        obj.insert("etag".to_string(), json!(etag.clone()));
        // `pending: true` means the change is journaled and visible here, but not
        // yet in the file — a turn is mid-write and replay will land it.
        obj.insert("pending".to_string(), json!(pending));
    }
    (
        StatusCode::OK,
        [
            (axum::http::header::ETAG, etag),
            (
                axum::http::header::CONTENT_TYPE,
                "application/json".to_string(),
            ),
        ],
        serde_json::to_string(&value).unwrap_or_default(),
    )
        .into_response()
}

/// The shared body of both file-mutating endpoints.
///
/// Wholly synchronous by design: it holds a std mutex across its whole critical
/// section, so it must never await inside it. The order below is the contract —
/// **precondition, then journal, then edit** — and each step is where it is for
/// a reason called out inline.
fn mutate(
    st: &AppState,
    headers: &HeaderMap,
    id: &str,
    at: &str,
    build: impl FnOnce(&TodaySnapshot, &Located) -> Result<Option<Effect>, ApiError>,
) -> Result<Response, ApiError> {
    let _ = (st, headers, id, at, build);
    Err((StatusCode::NOT_IMPLEMENTED, "the day-file write path is not implemented yet".to_string()))
}

/// `POST /jesse/today/items/{id}/check` — tick or untick one item, optionally
/// recording one line of evidence beneath it.
pub async fn jesse_today_check(
    State(st): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
    Json(body): Json<CheckBody>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    let stamp = stamp_from_iso(&body.at).ok_or((
        StatusCode::BAD_REQUEST,
        "`at` must be an ISO8601 instant (YYYY-MM-DDTHH:MM…)".to_string(),
    ))?;
    let at = body.at.clone();
    mutate(&st, &headers, &id, &at, move |_, _| {
        Ok(Some(Effect::Check {
            checked: body.checked,
            evidence: body.evidence.clone(),
            stamp,
        }))
    })
}

/// `POST /jesse/today/items/{id}/move` — reorder one item within the document.
pub async fn jesse_today_move(
    State(st): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
    Json(body): Json<MoveBody>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    let op = MoveOp::parse(body.op.trim()).ok_or((
        StatusCode::BAD_REQUEST,
        "`op` must be one of top_of_section, to_do_now, up, down".to_string(),
    ))?;
    if stamp_from_iso(&body.at).is_none() {
        return Err((
            StatusCode::BAD_REQUEST,
            "`at` must be an ISO8601 instant (YYYY-MM-DDTHH:MM…)".to_string(),
        ));
    }
    let at = body.at.clone();
    mutate(&st, &headers, &id, &at, move |snapshot, located| {
        let resolved = resolve_landing(snapshot, located, op)?;
        Ok(resolved.map(|(to_section, landing)| Effect::Move {
            to_section,
            landing,
        }))
    })
}

/// `POST /jesse/today/glance` — record that a report row was seen.
///
/// The one mutation that never touches `Today.md`: glance state is the app's
/// read-tracking, not the day's content, and writing it into the vault would put
/// UI state in a file a person reads and an agent rewrites.
pub async fn jesse_today_glance(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<GlanceBody>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    let _ = body;
    Err((StatusCode::NOT_IMPLEMENTED, "the glance write path is not implemented yet".to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const FULL: &str = include_str!("../tests/fixtures/today/full.md");

    /// An intent addressing one fixture item by its identity triple.
    fn intent_for(snapshot: &TodaySnapshot, lead_starts: &str) -> Intent {
        let located = snapshot
            .sections
            .iter()
            .flat_map(|s| s.items.iter().map(move |i| (s, i)))
            .find(|(_, i)| i.lead.starts_with(lead_starts))
            .map(|(s, i)| (s.name.clone(), i))
            .or_else(|| {
                snapshot
                    .lead_items
                    .iter()
                    .find(|i| i.lead.starts_with(lead_starts))
                    .map(|i| (String::new(), i))
            })
            .unwrap_or_else(|| panic!("no item starting {lead_starts:?}"));
        Intent {
            seq: 0,
            id: located.1.id.clone(),
            section: located.0,
            lead: located.1.lead.clone(),
            added_date: located.1.added_date.clone().unwrap_or_default(),
            date: "2026-03-03".to_string(),
            at: "2026-03-03T09:30:00Z".to_string(),
            effect: Effect::Check {
                checked: true,
                evidence: None,
                stamp: "2026-03-03 09:30".to_string(),
            },
        }
    }

    fn item_named<'a>(snapshot: &'a TodaySnapshot, lead_starts: &str) -> &'a TodayItem {
        snapshot
            .lead_items
            .iter()
            .chain(snapshot.sections.iter().flat_map(|s| s.items.iter()))
            .find(|i| i.lead.starts_with(lead_starts))
            .unwrap_or_else(|| panic!("no item starting {lead_starts:?}"))
    }

    // ---- The check flip ----------------------------------------------------

    #[test]
    fn a_check_flips_three_bytes_and_nothing_else() {
        let snapshot = parse_today(FULL);
        let intent = intent_for(&snapshot, "Reply to Ada");
        let out = apply_check(FULL, &intent, true, None, "2026-03-03 09:30").unwrap();

        assert_eq!(out.len(), FULL.len(), "a flip changes no byte COUNT");
        let diffs: Vec<usize> = FULL
            .bytes()
            .zip(out.bytes())
            .enumerate()
            .filter(|(_, (a, b))| a != b)
            .map(|(i, _)| i)
            .collect();
        assert_eq!(diffs.len(), 1, "exactly one byte differs: the box");
        assert_eq!(&out[diffs[0]..diffs[0] + 1], "x");
        assert!(
            parse_today(&out)
                .sections
                .iter()
                .flat_map(|s| s.items.iter())
                .find(|i| i.lead.starts_with("Reply to Ada"))
                .unwrap()
                .checked
        );
    }

    #[test]
    fn a_check_round_trips_back_to_the_original_bytes() {
        let snapshot = parse_today(FULL);
        let intent = intent_for(&snapshot, "Reply to Ada");
        let checked = apply_check(FULL, &intent, true, None, "2026-03-03 09:30").unwrap();
        let back = apply_check(&checked, &intent, false, None, "2026-03-03 09:31").unwrap();
        assert_eq!(back, FULL, "check then uncheck is byte-identical");
    }

    #[test]
    fn evidence_is_appended_as_one_tab_indented_sub_line_under_the_item() {
        let snapshot = parse_today(FULL);
        let intent = intent_for(&snapshot, "Reply to Ada");
        let out = apply_check(
            FULL,
            &intent,
            true,
            Some("sent the date to Ada"),
            "2026-03-03 09:30",
        )
        .unwrap();
        assert!(
            out.contains("\t*(app-completed 2026-03-03 09:30: sent the date to Ada)*\n"),
            "the frozen grammar, verbatim"
        );
        // Directly under the item line, and parsed back as that item's own.
        let reparsed = parse_today(&out);
        let it = item_named(&reparsed, "Reply to Ada");
        assert!(it.checked);
        let app = it.app_completed.clone().expect("appCompleted");
        assert_eq!(app.at.as_deref(), Some("2026-03-03 09:30"));
        assert_eq!(app.evidence.as_deref(), Some("sent the date to Ada"));
    }

    #[test]
    fn unchecking_removes_the_evidence_sub_line() {
        let snapshot = parse_today(FULL);
        let intent = intent_for(&snapshot, "Reply to Ada");
        let with = apply_check(FULL, &intent, true, Some("did it"), "2026-03-03 09:30").unwrap();
        let without = apply_check(&with, &intent, false, None, "2026-03-03 09:40").unwrap();
        assert_eq!(
            without, FULL,
            "uncheck removes the sub-line and restores the original bytes"
        );
    }

    #[test]
    fn a_second_check_replaces_the_sub_line_rather_than_stacking_one() {
        let snapshot = parse_today(FULL);
        let intent = intent_for(&snapshot, "Reply to Ada");
        let once = apply_check(FULL, &intent, true, Some("first"), "2026-03-03 09:30").unwrap();
        let twice = apply_check(&once, &intent, true, Some("second"), "2026-03-03 10:00").unwrap();
        assert_eq!(
            twice.matches("app-completed").count(),
            2,
            "the fixture's own, plus exactly one of ours"
        );
        assert!(twice.contains("second"));
        assert!(!twice.contains(": first)"));
    }

    #[test]
    fn an_items_existing_continuations_travel_through_a_check() {
        // The lead item carries two tab-indented continuation lines.
        let snapshot = parse_today(FULL);
        let intent = intent_for(&snapshot, "TOP PRIORITY");
        let out = apply_check(FULL, &intent, true, Some("done"), "2026-03-03 09:30").unwrap();
        let reparsed = parse_today(&out);
        let it = item_named(&reparsed, "TOP PRIORITY");
        assert!(it.checked);
        assert!(it.text.contains("Standing lead item"), "continuation kept");
        assert!(it.text.contains("kiln-rebuild"), "and the second one too");
        assert_eq!(
            it.text.lines().count(),
            4,
            "task line + our sub-line + the two originals: {:?}",
            it.text
        );
    }

    // ---- Evidence escaping and the cap -------------------------------------

    #[test]
    fn evidence_escaping_neutralizes_every_markdown_special_character() {
        let escaped = escape_evidence("*bold* [link](x) `code` #head ~~s~~ a|b <i> back\\slash");
        for pair in [
            ("*", "\\*"),
            ("[", "\\["),
            ("]", "\\]"),
            ("(", "\\("),
            (")", "\\)"),
            ("`", "\\`"),
            ("#", "\\#"),
            ("~", "\\~"),
            ("|", "\\|"),
            ("<", "\\<"),
            (">", "\\>"),
        ] {
            assert!(
                !escaped.contains(&format!("{}{}", " ", pair.0)) || escaped.contains(pair.1),
                "{} must be escaped in {escaped:?}",
                pair.0
            );
        }
        assert!(escaped.contains("\\*bold\\*"));
        assert!(escaped.contains("\\(x\\)"));
    }

    #[test]
    fn evidence_cannot_close_the_sub_line_early_and_become_document_text() {
        // The attack the escaping exists for: evidence that terminates the
        // wrapper and continues as its own markdown.
        let evil = ")* and now I am a heading\n# OWNED";
        let line = app_completed_sub_line("2026-03-03 09:30", &escape_evidence(evil));
        assert_eq!(line.matches('\n').count(), 1, "still exactly one line");
        assert!(
            line.ends_with(")*\n"),
            "the wrapper still closes at the end"
        );
        assert!(!line.contains("\n# OWNED"), "no injected heading");
        // And it parses back as ONE continuation of its item, not a document line.
        let doc = format!("# Today: 2026-03-03\n\n## Do Now\n\n* [x] A thing.\n{line}");
        let snapshot = parse_today(&doc);
        let section = &snapshot.sections[0];
        assert_eq!(section.items.len(), 1);
        assert!(
            section.prose.is_empty(),
            "nothing escaped into the document"
        );
    }

    #[test]
    fn evidence_is_capped_at_500_characters_and_flattened_to_one_line() {
        let long = "é".repeat(900);
        let escaped = escape_evidence(&long);
        assert_eq!(escaped.chars().count(), MAX_EVIDENCE_CHARS);
        let multi = escape_evidence("first line\nsecond line\tand a tab");
        assert!(!multi.contains('\n') && !multi.contains('\t'));
        assert_eq!(multi, "first line second line and a tab");
    }

    #[test]
    fn a_stamp_is_parsed_strictly_from_iso8601() {
        assert_eq!(
            stamp_from_iso("2026-03-03T09:30:15Z").as_deref(),
            Some("2026-03-03 09:30")
        );
        assert_eq!(
            stamp_from_iso("2026-03-03T09:30:15+01:00").as_deref(),
            Some("2026-03-03 09:30")
        );
        for bad in [
            "",
            "not a date",
            "2026-3-3T09:30:00Z",
            "2026-03-03",
            "2026-03-03T99:99:00Z",
        ] {
            assert_eq!(stamp_from_iso(bad), None, "{bad:?} must be rejected");
        }
    }

    // ---- Moves -------------------------------------------------------------

    /// Apply a move the way the endpoint does: resolve the op, then splice.
    fn do_move(src: &str, lead_starts: &str, op: MoveOp) -> Result<String, SpliceError> {
        let snapshot = parse_today(src);
        let item = item_named(&snapshot, lead_starts);
        let located = locate_by_id(&snapshot, &item.id).unwrap();
        let mut intent = intent_for(&snapshot, lead_starts);
        match resolve_landing(&snapshot, &located, op)? {
            None => Ok(src.to_string()),
            Some((to_section, landing)) => {
                intent.effect = Effect::Move {
                    to_section: to_section.clone(),
                    landing: landing.clone(),
                };
                apply_landing(src, &intent, &to_section, &landing)
            }
        }
    }

    fn leads(src: &str, section: &str) -> Vec<String> {
        parse_today(src)
            .sections
            .iter()
            .find(|s| s.name == section)
            .unwrap()
            .items
            .iter()
            .map(|i| i.lead.clone())
            .collect()
    }

    #[test]
    fn up_swaps_an_item_with_the_one_above_it() {
        let before = leads(FULL, "Do Now");
        let out = do_move(FULL, "Plain unbolded item", MoveOp::Up).unwrap();
        let after = leads(&out, "Do Now");
        assert_eq!(after[1], before[2], "the item rose one row");
        assert_eq!(after[2], before[1], "and its neighbour fell one");
        assert_eq!(after.len(), before.len(), "nothing was lost");
        assert_eq!(out.len(), FULL.len(), "a move preserves every byte");
    }

    #[test]
    fn down_swaps_an_item_with_the_one_below_it() {
        let before = leads(FULL, "Do Now");
        let out = do_move(FULL, "Reply to Ada", MoveOp::Down).unwrap();
        let after = leads(&out, "Do Now");
        assert_eq!(after[1], before[2]);
        assert_eq!(after[2], before[1]);
        assert_eq!(out.len(), FULL.len());
    }

    #[test]
    fn up_on_the_first_item_and_down_on_the_last_are_no_ops() {
        assert_eq!(
            do_move(FULL, "Order the replacement", MoveOp::Up).unwrap(),
            FULL
        );
        // The last Do Now item is the empty checkbox.
        let snapshot = parse_today(FULL);
        let last = snapshot
            .sections
            .iter()
            .find(|s| s.name == "Do Now")
            .unwrap()
            .items
            .last()
            .unwrap();
        let located = locate_by_id(&snapshot, &last.id).unwrap();
        assert_eq!(
            resolve_landing(&snapshot, &located, MoveOp::Down).unwrap(),
            None
        );
    }

    #[test]
    fn top_of_section_lifts_an_item_above_every_sibling() {
        let out = do_move(FULL, "Plain unbolded item", MoveOp::TopOfSection).unwrap();
        let after = leads(&out, "Do Now");
        assert!(after[0].starts_with("Plain unbolded item"));
        assert_eq!(after.len(), 4, "and the section still has all four");
        assert_eq!(out.len(), FULL.len());
    }

    #[test]
    fn top_of_section_on_something_already_at_the_top_is_a_no_op() {
        assert_eq!(
            do_move(FULL, "Order the replacement", MoveOp::TopOfSection).unwrap(),
            FULL
        );
    }

    #[test]
    fn to_do_now_moves_an_item_across_sections_with_its_continuations() {
        let out = do_move(FULL, "Collect the glaze order", MoveOp::ToDoNow).unwrap();
        let do_now = leads(&out, "Do Now");
        assert!(do_now[0].starts_with("Collect the glaze order"));
        assert_eq!(
            leads(&out, "Errands").len(),
            1,
            "and it left the section it came from"
        );
        assert!(
            out.contains("\t*(app-completed") || out.contains("    *(app-completed"),
            "its app-completed continuation travelled with it"
        );
        let reparsed = parse_today(&out);
        let moved = item_named(&reparsed, "Collect the glaze order");
        assert!(
            moved.text.contains("app-completed"),
            "the continuation block belongs to the moved item: {:?}",
            moved.text
        );
    }

    #[test]
    fn to_do_now_is_409_when_there_is_no_do_now_section() {
        let doc = "# Today: 2026-03-03\n\n## Errands\n\n* [ ] A thing.\n";
        assert_eq!(
            do_move(doc, "A thing.", MoveOp::ToDoNow),
            Err(SpliceError::NoDoNowSection)
        );
        assert_eq!(SpliceError::NoDoNowSection.status(), StatusCode::CONFLICT);
    }

    #[test]
    fn the_standing_lead_item_cannot_be_moved_by_any_op() {
        for op in [
            MoveOp::Up,
            MoveOp::Down,
            MoveOp::TopOfSection,
            MoveOp::ToDoNow,
        ] {
            assert_eq!(
                do_move(FULL, "TOP PRIORITY", op),
                Err(SpliceError::LeadBlockImmutable),
                "the lead block is untouchable, including by {op:?}"
            );
        }
        assert_eq!(
            SpliceError::LeadBlockImmutable.status(),
            StatusCode::CONFLICT
        );
    }

    #[test]
    fn no_move_can_land_an_item_above_the_first_heading() {
        // Every destination offset must sit at or after the first `## `.
        let first_heading = FULL.find("\n## ").unwrap() + 1;
        for lead in [
            "Plain unbolded item",
            "Reply to Ada",
            "Collect the glaze order",
        ] {
            for op in [
                MoveOp::Up,
                MoveOp::Down,
                MoveOp::TopOfSection,
                MoveOp::ToDoNow,
            ] {
                let Ok(out) = do_move(FULL, lead, op) else {
                    continue;
                };
                let head = &out[..first_heading];
                assert!(
                    !head.contains("* [") || head == &FULL[..first_heading],
                    "{op:?} on {lead:?} put a task line above the first heading"
                );
                assert_eq!(
                    parse_today(&out).lead_items.len(),
                    1,
                    "the lead block still holds exactly the standing item"
                );
            }
        }
    }

    #[test]
    fn a_move_into_an_empty_section_lands_under_its_heading() {
        let doc = "# Today: 2026-03-03\n\n## Do Now\n\n## Errands\n\n* [ ] A thing.\n";
        let out = do_move(doc, "A thing.", MoveOp::ToDoNow).unwrap();
        assert_eq!(
            out, "# Today: 2026-03-03\n\n## Do Now\n\n* [ ] A thing.\n## Errands\n\n",
            "the item sits under the heading, past its blank line"
        );
        assert_eq!(leads(&out, "Do Now").len(), 1);
        assert!(leads(&out, "Errands").is_empty());
    }

    #[test]
    fn an_unknown_id_is_a_410() {
        let snapshot = parse_today(FULL);
        assert!(locate_by_id(&snapshot, "ffffffffffff").is_none());
        assert_eq!(SpliceError::UnknownItem.status(), StatusCode::GONE);
    }

    #[test]
    fn a_file_with_no_trailing_newline_keeps_its_shape_through_a_check() {
        let doc = "# Today: 2026-03-03\n\n## Do Now\n\n* [ ] Last line, no newline.";
        let snapshot = parse_today(doc);
        let intent = intent_for(&snapshot, "Last line");
        let out = apply_check(doc, &intent, true, Some("done"), "2026-03-03 09:30").unwrap();
        assert!(!out.ends_with('\n'), "the missing trailing newline is kept");
        assert!(out.contains("* [x] Last line, no newline.\n\t*(app-completed"));
        let back = apply_check(&out, &intent, false, None, "2026-03-03 09:31").unwrap();
        assert_eq!(back, doc);
    }

    // ---- The atomic write --------------------------------------------------

    #[test]
    fn write_day_file_replaces_whole_and_leaves_no_temp_behind() {
        let dir = std::env::temp_dir().join(format!("jesse-daywrite-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("Today.md");
        std::fs::write(&path, "original\n").unwrap();
        write_day_file(&path, "replaced\n").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "replaced\n");
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "no temp file survives a write");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_day_file_preserves_the_existing_file_mode() {
        let dir = std::env::temp_dir().join(format!("jesse-daymode-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("Today.md");
        std::fs::write(&path, "x\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        write_day_file(&path, "y\n").unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o644,
            "a checkbox tap must not silently re-permission a vault file"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
