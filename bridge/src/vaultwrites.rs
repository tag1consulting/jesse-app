//! `POST /jesse/vault/writes` — every change the app makes to a note, told to the Studio.
//!
//! ## Why
//!
//! The app writes notes into the device's Obsidian folder, and Obsidian on iOS does not sync
//! a file another app changed there (2026-09-24: a tick of Family P1 never reached the
//! Studio). Only strand ticks were also reported here, through `/jesse/strands/{slug}/ticks`.
//! An edit from the editor, a CriticMarkup comment, a checkbox in any other note, and an
//! Inbox capture made offline could exist only on the phone. Now every one of them is also a
//! RECORD in the app's write outbox, sent here in order, and applied against the Studio's
//! CURRENT file rather than trusted to a sync that never runs.
//!
//! ## One record, one answer
//!
//! A record names a client `id` (a UUID, the idempotency key), a vault relative `path`, a
//! `kind` (`edit`, `tick`, `untick`, `capture`), the `base_sha256` of the file the device
//! changed (null for a capture, and for a file that did not exist), and what changed:
//! `text` is the whole new note for an edit, the appended entry for a capture, and the
//! checkbox line AS THE DEVICE SAW IT for a tick; `line` is the tick's 1-based line. An edit
//! may carry `base_text`, the device's copy of the base, which is what makes a merge
//! possible; a capture may carry `prologue`, the heading a new Inbox file starts with.
//!
//! Each answer is `applied`, `conflict` (with the Studio's `current_text` and
//! `current_sha256`, so the device can show both), or `refused` (with a `reason`), and
//! carries the file's `sha256` after the record. See [`plan`] for the rules, which are pure
//! and tested without a router.
//!
//! ## What this route never does
//!
//! It writes only `.md` files under the notes root, by the same rules the read route
//! serves by ([`crate::vaultnotes::safe_rel`]), never `Today.md` (the bridge owns it and has
//! its own write routes), never anything outside `Inbox/` for a capture, and it never runs
//! git: the Studio's own autocommit carries every write. It does not fight a turn for a
//! file either: while a running turn holds a write lock that covers the file, the whole
//! request answers `503` and the device sends it again later; records already applied
//! answer `applied` again by id.

use crate::vaultnotes::{resolve_note, safe_rel};
use crate::*;
use std::collections::BTreeMap;

/// How long an applied id is remembered. Far past any outbox that could still hold it.
pub const APPLIED_RETENTION_MS: u64 = 30 * 24 * 60 * 60 * 1000;

/// The most records one request may carry, and the largest text one may carry. Bounds on
/// what a request can make the bridge do, not on anything a real outbox reaches.
pub const MAX_RECORDS: usize = 500;
pub const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;

/// How far back a capture looks for its own entry before appending it again.
pub const CAPTURE_DEDUP_LINES: usize = 50;

/// The one folder a capture may write into.
pub const INBOX_DIR: &str = "Inbox";

/// One record, as the app sends it. Every field but `id`, `path` and `kind` is optional
/// on the wire; which ones a kind needs is [`plan`]'s business.
#[derive(serde::Deserialize, Debug, Clone, Default)]
pub struct WriteRecord {
    pub id: String,
    pub path: String,
    pub kind: String,
    #[serde(default)]
    pub base_sha256: Option<String>,
    #[serde(default)]
    pub base_text: Option<String>,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub line: Option<usize>,
    #[serde(default)]
    pub checked: Option<bool>,
    #[serde(default)]
    pub made_at: Option<String>,
    #[serde(default)]
    pub force: bool,
    #[serde(default)]
    pub prologue: Option<String>,
}

#[derive(PartialEq, Eq, Debug, Clone, Copy)]
pub enum Kind {
    Edit,
    Tick,
    Untick,
    Capture,
}

impl Kind {
    pub fn parse(s: &str) -> Option<Kind> {
        match s {
            "edit" => Some(Kind::Edit),
            "tick" => Some(Kind::Tick),
            "untick" => Some(Kind::Untick),
            "capture" => Some(Kind::Capture),
            _ => None,
        }
    }
}

/// What one record does to the file, decided from the record and the file as it is now.
#[derive(PartialEq, Eq, Debug, Clone)]
pub enum Plan {
    /// Write this text. For a tick, `line` is the checkbox line as written.
    Write {
        text: String,
        line: Option<String>,
    },
    /// The file already says what the record asks for. Applied, nothing written.
    Unchanged {
        line: Option<String>,
    },
    /// The device's change cannot be placed on the current file without guessing.
    Conflict,
    Refused(String),
}

pub fn sha256(text: &str) -> String {
    crate::artifacts::sha256_hex(text.as_bytes())
}

// ---- Checkbox lines ---------------------------------------------------------------

/// The byte index of the box's state character on `line`, and whether it is ticked.
///
/// The app's grammar (`VaultCheckboxEdit.box`), restated: leading whitespace, a list marker
/// (`-`, `*`, `+`, or digits then `.` or `)`), at least one space, `[`, one of ` `, `x`,
/// `X`, `]`. A `[-]` or `[/]` is somebody else's convention and not a box here.
pub fn box_at(line: &str) -> Option<(usize, bool)> {
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') {
        i += 1;
    }
    match bytes.get(i) {
        Some(b'-' | b'*' | b'+') => i += 1,
        Some(b'0'..=b'9') => {
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            match bytes.get(i) {
                Some(b'.' | b')') => i += 1,
                _ => return None,
            }
        }
        _ => return None,
    }
    let spaces = i;
    while i < bytes.len() && bytes[i] == b' ' {
        i += 1;
    }
    if i == spaces || bytes.get(i) != Some(&b'[') || bytes.get(i + 2) != Some(&b']') {
        return None;
    }
    match bytes[i + 1] {
        b' ' => Some((i + 1, false)),
        b'x' | b'X' => Some((i + 1, true)),
        _ => None,
    }
}

/// A checkbox line with its state removed, and its line ending: what "the same line"
/// means once the file has shifted. `None` for a line with no box.
pub fn box_key(line: &str) -> Option<String> {
    let (at, _) = box_at(line)?;
    let line = line.trim_end_matches('\r');
    Some(format!("{}{}", &line[..at], &line[at + 1..]))
}

/// `line` with its box set to `checked`: one byte changed, nothing else.
fn set_box(line: &str, checked: bool) -> Option<String> {
    let (at, _) = box_at(line)?;
    let mut out = String::with_capacity(line.len());
    out.push_str(&line[..at]);
    out.push(if checked { 'x' } else { ' ' });
    out.push_str(&line[at + 1..]);
    Some(out)
}

// ---- The rules ----------------------------------------------------------------

/// What `record` does to a file whose current text is `current` (`None`: no such file).
pub fn plan(record: &WriteRecord, kind: Kind, current: Option<&str>) -> Plan {
    let current_sha = current.map(sha256);
    let base_matches = match (&record.base_sha256, &current_sha) {
        (Some(base), Some(cur)) => base.eq_ignore_ascii_case(cur),
        (None, None) => true,
        _ => false,
    };
    match kind {
        Kind::Edit => plan_edit(record, current, base_matches),
        Kind::Tick | Kind::Untick => plan_tick(record, kind == Kind::Tick, current, base_matches),
        Kind::Capture => plan_capture(record, current),
    }
}

fn plan_edit(record: &WriteRecord, current: Option<&str>, base_matches: bool) -> Plan {
    let Some(text) = record.text.as_deref() else {
        return Plan::Refused("an edit carries the new text".to_string());
    };
    if current == Some(text) {
        return Plan::Unchanged { line: None };
    }
    // "Keep mine": the person has seen both versions and chose the device's.
    if record.force || base_matches {
        return Plan::Write {
            text: text.to_string(),
            line: None,
        };
    }
    let (Some(current), Some(base_sha)) = (current, record.base_sha256.as_deref()) else {
        // The device edited a file the Studio no longer has, or created one the Studio
        // already has. Neither is a thing to settle without asking.
        return Plan::Conflict;
    };
    // A merge needs the base, and a base whose hash is not the one the record names is not
    // the base: merging against it would invent a history.
    let Some(base) = record
        .base_text
        .as_deref()
        .filter(|b| sha256(b).eq_ignore_ascii_case(base_sha))
    else {
        return Plan::Conflict;
    };
    match diffy::merge(base, text, current) {
        Ok(merged) if merged == current => Plan::Unchanged { line: None },
        Ok(merged) => Plan::Write {
            text: merged,
            line: None,
        },
        Err(_) => Plan::Conflict,
    }
}

fn plan_tick(
    record: &WriteRecord,
    checked: bool,
    current: Option<&str>,
    base_matches: bool,
) -> Plan {
    let Some(current) = current else {
        return Plan::Conflict;
    };
    let mut lines: Vec<&str> = current.split('\n').collect();
    // The line by NUMBER, when the file is the file the device ticked.
    let by_number = record
        .line
        .filter(|n| base_matches && *n >= 1 && *n <= lines.len())
        .map(|n| n - 1)
        .filter(|i| box_at(lines[*i]).is_some());
    // Otherwise by CONTENT: the device's line without its box state, found exactly once.
    let at = by_number.or_else(|| {
        let key = record.text.as_deref().and_then(box_key).or_else(|| {
            let base = record.base_text.as_deref()?;
            let n = record.line?;
            base.split('\n').nth(n.checked_sub(1)?).and_then(box_key)
        })?;
        let mut found = lines
            .iter()
            .enumerate()
            .filter(|(_, l)| box_key(l).as_deref() == Some(key.as_str()))
            .map(|(i, _)| i);
        let first = found.next()?;
        found.next().is_none().then_some(first)
    });
    let Some(at) = at else {
        return Plan::Conflict;
    };
    let (_, is_checked) = box_at(lines[at]).expect("found as a box");
    if is_checked == checked {
        return Plan::Unchanged {
            line: Some(lines[at].to_string()),
        };
    }
    let edited = set_box(lines[at], checked).expect("found as a box");
    lines[at] = &edited;
    let text = lines.join("\n");
    Plan::Write {
        text,
        line: Some(edited.clone()),
    }
}

fn plan_capture(record: &WriteRecord, current: Option<&str>) -> Plan {
    let Some(entry) = record.text.as_deref().filter(|t| !t.trim().is_empty()) else {
        return Plan::Refused("a capture carries its entry".to_string());
    };
    let Some(current) = current else {
        let prologue = record.prologue.as_deref().unwrap_or("");
        return Plan::Write {
            text: format!("{prologue}{entry}"),
            line: None,
        };
    };
    // The same entry already there — Obsidian did sync it after all, or this is a resend —
    // is applied without a second copy.
    let wanted = entry.trim_end_matches(['\n', '\r']);
    let tail: Vec<&str> = current.split('\n').collect();
    let tail = tail[tail.len().saturating_sub(CAPTURE_DEDUP_LINES)..].join("\n");
    if !wanted.is_empty() && tail.contains(wanted) {
        return Plan::Unchanged { line: None };
    }
    let separator = if current.is_empty() || current.ends_with('\n') {
        ""
    } else {
        "\n"
    };
    Plan::Write {
        text: format!("{current}{separator}{entry}"),
        line: None,
    }
}

// ---- Applied ids -------------------------------------------------------------------

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct LedgerFile {
    #[serde(default)]
    applied: Vec<AppliedId>,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct AppliedId {
    id: String,
    at_ms: u64,
}

/// Every record id applied in the last thirty days, persisted beside the other state
/// files, and the one lock every write through this route takes.
pub struct VaultWriteLedger {
    file: Option<PathBuf>,
    applied: Mutex<BTreeMap<String, u64>>,
    /// Serialises requests: two outboxes (the phone and the Mac) flushing at once must not
    /// interleave a read and a write of the same file.
    pub gate: tokio::sync::Mutex<()>,
}

impl VaultWriteLedger {
    pub fn new(file: Option<PathBuf>) -> Self {
        let mut applied = BTreeMap::new();
        if let Some(path) = file.as_deref() {
            if let Ok(bytes) = std::fs::read(path) {
                match serde_json::from_slice::<LedgerFile>(&bytes) {
                    Ok(f) => applied = f.applied.into_iter().map(|a| (a.id, a.at_ms)).collect(),
                    Err(e) => eprintln!(
                        "jesse-bridge: WARNING: vault writes: {} is not a ledger ({e}); starting \
                         empty (a resent write is still idempotent by content)",
                        path.display()
                    ),
                }
            }
        }
        VaultWriteLedger {
            file,
            applied: Mutex::new(applied),
            gate: tokio::sync::Mutex::new(()),
        }
    }

    pub fn is_applied(&self, id: &str) -> bool {
        self.applied.lock_ok().contains_key(id)
    }

    pub fn mark_applied(&self, id: &str, now_ms: u64) {
        let mut applied = self.applied.lock_ok();
        applied.insert(id.to_string(), now_ms);
        applied.retain(|_, at| now_ms.saturating_sub(*at) < APPLIED_RETENTION_MS);
        let Some(path) = self.file.as_deref() else {
            return;
        };
        let file = LedgerFile {
            applied: applied
                .iter()
                .map(|(id, at)| AppliedId {
                    id: id.clone(),
                    at_ms: *at,
                })
                .collect(),
        };
        let bytes = serde_json::to_vec_pretty(&file).unwrap_or_default();
        if let Err(e) = write_atomic(path, &bytes) {
            eprintln!(
                "jesse-bridge: WARNING: vault writes: cannot write {} ({e})",
                path.display()
            );
        }
    }
}

// ---- Applying one record -------------------------------------------------------------

/// The answer for one record.
#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct WriteAnswer {
    pub id: String,
    pub status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl WriteAnswer {
    fn applied(id: &str, sha: Option<String>) -> Self {
        WriteAnswer {
            id: id.to_string(),
            status: "applied",
            sha256: sha,
            current_text: None,
            current_sha256: None,
            reason: None,
        }
    }

    fn refused(id: &str, reason: impl Into<String>) -> Self {
        WriteAnswer {
            id: id.to_string(),
            status: "refused",
            sha256: None,
            current_text: None,
            current_sha256: None,
            reason: Some(reason.into()),
        }
    }

    fn conflict(id: &str, current: Option<&str>) -> Self {
        let sha = current.map(sha256);
        WriteAnswer {
            id: id.to_string(),
            status: "conflict",
            sha256: sha.clone(),
            current_text: Some(current.unwrap_or("").to_string()),
            current_sha256: sha,
            reason: None,
        }
    }
}

/// Where a record may write: the absolute file, and its vault relative path. An existing
/// file goes through the read route's own resolver; a new one must sit in an existing,
/// confined folder.
pub fn write_target(root: &Path, rel: &str) -> Result<(PathBuf, String), String> {
    let rel = safe_rel(rel).ok_or("not a note this route writes")?;
    if rel.eq_ignore_ascii_case(crate::today::TODAY_FILE) {
        return Err("Today.md is written by the bridge's own routes".to_string());
    }
    let joined = root.join(&rel);
    if std::fs::symlink_metadata(&joined).is_ok() {
        return resolve_note(root, &rel).ok_or_else(|| "not a note this route writes".to_string());
    }
    let (parent, name) = match rel.rsplit_once('/') {
        Some((parent, name)) => (Some(parent), name),
        None => (None, rel.as_str()),
    };
    let root_canonical = std::fs::canonicalize(root).map_err(|_| "no notes root".to_string())?;
    let dir = match parent {
        Some(parent) => std::fs::canonicalize(root.join(parent))
            .map_err(|_| "that folder does not exist on the Studio".to_string())?,
        None => root_canonical.clone(),
    };
    if !dir.starts_with(&root_canonical) || !dir.is_dir() {
        return Err("not a note this route writes".to_string());
    }
    // The folder, resolved, must itself be one a note may live in.
    let dir_rel = dir
        .strip_prefix(&root_canonical)
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default();
    let canonical_rel = if dir_rel.is_empty() {
        name.to_string()
    } else {
        format!("{dir_rel}/{name}")
    };
    let canonical_rel = safe_rel(&canonical_rel).ok_or("not a note this route writes")?;
    Ok((dir.join(name), canonical_rel))
}

/// The step id a checkbox line names: the first bold span after the box.
fn step_id(line: &str) -> Option<String> {
    let rest = &line[line.find(']')? + 1..];
    let open = rest.find("**")? + 2;
    let close = rest[open..].find("**")? + open;
    let id = rest[open..close].trim();
    (!id.is_empty()).then(|| id.to_string())
}

/// `Family` for `Strands/Family.md`, and nothing deeper.
fn strand_slug(rel: &str) -> Option<&str> {
    let rest = rel.strip_prefix(&format!("{}/", crate::strands::STRANDS_DIR))?;
    let slug = rest.strip_suffix(".md")?;
    (!slug.is_empty() && !slug.contains('/')).then_some(slug)
}

/// Why a whole request stopped: a turn is writing a file it names.
#[derive(Debug, PartialEq)]
pub struct Busy;

/// Apply one record. Pure over the filesystem and the ledger apart from the strand tick
/// hand-off, which is the only thing that needs the whole `AppState`.
pub fn apply(st: &AppState, raw: &Value, now_ms: u64) -> Result<WriteAnswer, Busy> {
    let id = raw
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let record: WriteRecord = match serde_json::from_value(raw.clone()) {
        Ok(r) => r,
        Err(e) => return Ok(WriteAnswer::refused(&id, format!("malformed record: {e}"))),
    };
    if uuid::Uuid::parse_str(&record.id).is_err() {
        return Ok(WriteAnswer::refused(&id, "the id must be a UUID"));
    }
    let root = notes_root(&st.cfg);
    if st.vault_writes.is_applied(&record.id) {
        let sha = write_target(&root, &record.path)
            .ok()
            .and_then(|(abs, _)| std::fs::read_to_string(abs).ok())
            .map(|t| sha256(&t));
        return Ok(WriteAnswer::applied(&record.id, sha));
    }
    let Some(kind) = Kind::parse(&record.kind) else {
        return Ok(WriteAnswer::refused(&id, "unknown kind"));
    };
    let too_long = |s: &Option<String>| s.as_ref().is_some_and(|t| t.len() > MAX_TEXT_BYTES);
    if too_long(&record.text) || too_long(&record.base_text) || too_long(&record.prologue) {
        return Ok(WriteAnswer::refused(&id, "too large"));
    }
    let (abs, rel) = match write_target(&root, &record.path) {
        Ok(t) => t,
        Err(why) => return Ok(WriteAnswer::refused(&id, why)),
    };
    if kind == Kind::Capture && !rel.starts_with(&format!("{INBOX_DIR}/")) {
        return Ok(WriteAnswer::refused(&id, "a capture goes into Inbox/ only"));
    }
    if st.broker.holds_write_on(&abs) {
        return Err(Busy);
    }
    let current = match std::fs::read(&abs) {
        Ok(bytes) => match String::from_utf8(bytes) {
            Ok(text) => Some(text),
            Err(_) => return Ok(WriteAnswer::refused(&id, "the Studio's file is not UTF-8")),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Ok(WriteAnswer::refused(&id, format!("cannot read it: {e}"))),
    };
    let (sha, line) = match plan(&record, kind, current.as_deref()) {
        Plan::Refused(why) => return Ok(WriteAnswer::refused(&id, why)),
        Plan::Conflict => return Ok(WriteAnswer::conflict(&id, current.as_deref())),
        Plan::Unchanged { line } => (current.as_deref().map(sha256), line),
        Plan::Write { text, line } => {
            if let Err(e) = write_atomic(&abs, text.as_bytes()) {
                return Ok(WriteAnswer::refused(&id, format!("cannot write it: {e}")));
            }
            (Some(sha256(&text)), line)
        }
    };
    st.vault_writes.mark_applied(&record.id, now_ms);
    eprintln!(
        "jesse-bridge: vault writes: {} {} {rel} (made {})",
        record.kind,
        record.id,
        record.made_at.as_deref().unwrap_or("?")
    );
    // A strand tick starts the same turn the ticks route starts, through the same ledger.
    if matches!(kind, Kind::Tick | Kind::Untick) {
        if let (Some(slug), Some(id)) = (strand_slug(&rel), line.as_deref().and_then(step_id)) {
            crate::strandticks::report_app_tick(st, slug, &id, kind == Kind::Tick);
        }
    }
    Ok(WriteAnswer::applied(&record.id, sha))
}

fn json_response(status: StatusCode, body: &Value) -> Response {
    (
        status,
        [(
            axum::http::header::CONTENT_TYPE,
            "application/json".to_string(),
        )],
        serde_json::to_string(body).unwrap_or_default(),
    )
        .into_response()
}

/// `POST /jesse/vault/writes` — a JSON array of records, applied in order, answered with a
/// JSON array of one answer per record in the same order.
pub async fn jesse_vault_writes(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(records): Json<Vec<Value>>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    if records.len() > MAX_RECORDS {
        return Err((StatusCode::BAD_REQUEST, "too many records".to_string()));
    }
    let _serial = st.vault_writes.gate.lock().await;
    let now = system_time_to_ms(SystemTime::now());
    let mut answers = Vec::with_capacity(records.len());
    for raw in &records {
        match apply(&st, raw, now) {
            Ok(answer) => answers.push(answer),
            Err(Busy) => {
                return Ok(json_response(
                    StatusCode::SERVICE_UNAVAILABLE,
                    &json!({"error": "busy", "message": "a turn is writing that note; send again later"}),
                ))
            }
        }
    }
    Ok(json_response(StatusCode::OK, &json!(answers)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vaultnotes::tests::Vault;
    use tower::ServiceExt as _;

    fn rec(kind: &str, path: &str) -> WriteRecord {
        WriteRecord {
            id: uuid::Uuid::new_v4().to_string(),
            path: path.to_string(),
            kind: kind.to_string(),
            ..Default::default()
        }
    }

    fn edit(base: &str, text: &str, with_base_text: bool) -> WriteRecord {
        WriteRecord {
            base_sha256: Some(sha256(base)),
            base_text: with_base_text.then(|| base.to_string()),
            text: Some(text.to_string()),
            ..rec("edit", "Projects/A.md")
        }
    }

    fn tick(base: &str, line: usize, checked: bool) -> WriteRecord {
        WriteRecord {
            base_sha256: Some(sha256(base)),
            text: base.split('\n').nth(line - 1).map(str::to_string),
            line: Some(line),
            checked: Some(checked),
            ..rec(if checked { "tick" } else { "untick" }, "Projects/A.md")
        }
    }

    const NOTE: &str = "# A\n\none\ntwo\nthree\n\n- [ ] first\n- [ ] second\n";

    #[test]
    fn each_kind_applies_on_a_matching_base() {
        let r = edit(NOTE, "# A\n\nnew\n", false);
        assert_eq!(
            plan(&r, Kind::Edit, Some(NOTE)),
            Plan::Write {
                text: "# A\n\nnew\n".into(),
                line: None
            }
        );

        let r = tick(NOTE, 7, true);
        let Plan::Write { text, line } = plan(&r, Kind::Tick, Some(NOTE)) else {
            panic!("tick should write")
        };
        assert_eq!(text, NOTE.replace("- [ ] first", "- [x] first"));
        assert_eq!(line.as_deref(), Some("- [x] first"));

        let ticked = NOTE.replace("- [ ] first", "- [x] first");
        let r = tick(&ticked, 7, false);
        assert_eq!(
            plan(&r, Kind::Untick, Some(&ticked)),
            Plan::Write {
                text: NOTE.into(),
                line: Some("- [ ] first".into())
            }
        );

        let r = WriteRecord {
            text: Some("- 09:00 a thought\n".into()),
            ..rec("capture", "Inbox/2026-09-26-phone.md")
        };
        assert_eq!(
            plan(&r, Kind::Capture, Some("# Inbox\n")),
            Plan::Write {
                text: "# Inbox\n- 09:00 a thought\n".into(),
                line: None
            }
        );
        let r = WriteRecord {
            prologue: Some("# Inbox\n\n".into()),
            ..r
        };
        assert_eq!(
            plan(&r, Kind::Capture, None),
            Plan::Write {
                text: "# Inbox\n\n- 09:00 a thought\n".into(),
                line: None
            }
        );
    }

    #[test]
    fn an_edit_on_a_moved_base_merges_cleanly_when_the_hunks_do_not_overlap() {
        let device = NOTE.replace("one\n", "ONE on the phone\n");
        let studio = NOTE.replace("three\n", "three, and more on the Studio\n");
        let r = edit(NOTE, &device, true);
        assert_eq!(
            plan(&r, Kind::Edit, Some(&studio)),
            Plan::Write {
                text: NOTE
                    .replace("one\n", "ONE on the phone\n")
                    .replace("three\n", "three, and more on the Studio\n"),
                line: None
            }
        );
    }

    #[test]
    fn an_edit_with_overlapping_hunks_is_a_conflict_carrying_the_current_text() {
        let device = NOTE.replace("two\n", "two from the phone\n");
        let studio = NOTE.replace("two\n", "two from the Studio\n");
        assert_eq!(
            plan(&edit(NOTE, &device, true), Kind::Edit, Some(&studio)),
            Plan::Conflict
        );
        // Without a base to merge against, a moved base is a conflict too.
        let elsewhere = NOTE.replace("three\n", "3\n");
        assert_eq!(
            plan(&edit(NOTE, &device, false), Kind::Edit, Some(&elsewhere)),
            Plan::Conflict
        );
        // And a base_text that is not the base named is not trusted.
        let mut lying = edit(NOTE, &device, true);
        lying.base_text = Some("something else".into());
        assert_eq!(plan(&lying, Kind::Edit, Some(&elsewhere)), Plan::Conflict);

        let answer = WriteAnswer::conflict("x", Some(&studio));
        assert_eq!(answer.status, "conflict");
        assert_eq!(answer.current_text.as_deref(), Some(studio.as_str()));
        assert_eq!(answer.current_sha256, Some(sha256(&studio)));
    }

    #[test]
    fn force_writes_the_device_text() {
        let device = NOTE.replace("two\n", "two from the phone\n");
        let studio = NOTE.replace("two\n", "two from the Studio\n");
        let mut r = edit(NOTE, &device, true);
        r.base_sha256 = Some(sha256(&studio));
        r.force = true;
        assert_eq!(
            plan(&r, Kind::Edit, Some(&studio)),
            Plan::Write {
                text: device,
                line: None
            }
        );
    }

    #[test]
    fn a_tick_is_found_by_content_after_the_file_shifted() {
        let r = tick(NOTE, 8, true); // "- [ ] second"
        let shifted = NOTE.replace("# A\n", "# A\n\nA paragraph added on the Studio.\n\n");
        let Plan::Write { text, line } = plan(&r, Kind::Tick, Some(&shifted)) else {
            panic!("should find it by content")
        };
        assert_eq!(text, shifted.replace("- [ ] second", "- [x] second"));
        assert_eq!(line.as_deref(), Some("- [x] second"));
        // Already ticked on the Studio: applied, nothing to write.
        let done = shifted.replace("- [ ] second", "- [x] second");
        assert!(matches!(
            plan(&r, Kind::Tick, Some(&done)),
            Plan::Unchanged { .. }
        ));
    }

    #[test]
    fn a_tick_with_two_matching_lines_is_a_conflict() {
        let r = tick(NOTE, 7, true);
        let doubled = format!("{NOTE}- [ ] first\n");
        let shifted = format!("moved\n{doubled}");
        assert_eq!(plan(&r, Kind::Tick, Some(&shifted)), Plan::Conflict);
        // A line that is no longer there at all, likewise.
        let gone = NOTE
            .replace("- [ ] first\n", "")
            .replace("# A", "# A moved");
        assert_eq!(plan(&r, Kind::Tick, Some(&gone)), Plan::Conflict);
    }

    #[test]
    fn a_capture_already_present_is_not_appended_twice() {
        let r = WriteRecord {
            text: Some("- 09:00 a thought\n".into()),
            ..rec("capture", "Inbox/2026-09-26-phone.md")
        };
        let synced = "# Inbox\n- 09:00 a thought\n- 09:05 another\n";
        assert!(matches!(
            plan(&r, Kind::Capture, Some(synced)),
            Plan::Unchanged { .. }
        ));
    }

    #[test]
    fn checkbox_grammar_matches_the_app() {
        assert_eq!(box_at("- [ ] a"), Some((3, false)));
        assert_eq!(box_at("\t* [x] a"), Some((4, true)));
        assert_eq!(box_at("12) [X] a"), Some((5, true)));
        assert_eq!(box_at("-  [ ] two spaces"), Some((4, false)));
        assert_eq!(box_at("- [-] cancelled"), None);
        assert_eq!(box_at("-[ ] no space"), None);
        assert_eq!(box_at("text [ ]"), None);
        assert_eq!(box_key("- [x] a\r"), box_key("- [ ] a"));
        assert_eq!(step_id("- [x] **P1** Kits."), Some("P1".into()));
        assert_eq!(strand_slug("Strands/Family.md"), Some("Family"));
        assert_eq!(strand_slug("Strands/archive/Old.md"), None);
    }

    // ---- Through the route ----

    fn record_json(r: &WriteRecord) -> Value {
        json!({
            "id": r.id, "path": r.path, "kind": r.kind, "base_sha256": r.base_sha256,
            "base_text": r.base_text, "text": r.text, "line": r.line, "checked": r.checked,
            "made_at": "2026-09-26T09:00:00Z", "force": r.force, "prologue": r.prologue,
        })
    }

    async fn post(app: axum::Router, body: Value) -> (StatusCode, Value) {
        let resp = app
            .oneshot(
                axum::http::Request::builder()
                    .method("POST")
                    .uri("/jesse/vault/writes")
                    .header("authorization", "Bearer t0ken")
                    .header("content-type", "application/json")
                    .body(axum::body::Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = resp.status();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        (
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        )
    }

    #[tokio::test]
    async fn records_apply_in_order_and_a_duplicate_id_changes_nothing() {
        let v = Vault::new("writes");
        v.write("Projects/A.md", NOTE);
        v.write("Inbox/.keep.md", "");
        let app = crate::app(AppState::new(v.cfg()));

        let first = edit(NOTE, &NOTE.replace("one\n", "uno\n"), true);
        let edited = NOTE.replace("one\n", "uno\n");
        let second = tick(&edited, 7, true);
        let capture = WriteRecord {
            text: Some("- 09:00 a thought\n".into()),
            prologue: Some("# Inbox\n\n".into()),
            ..rec("capture", "Inbox/2026-09-26-phone.md")
        };
        let (status, body) = post(
            app.clone(),
            json!([
                record_json(&first),
                record_json(&second),
                record_json(&capture)
            ]),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let answers = body.as_array().unwrap();
        assert_eq!(answers.len(), 3);
        for (answer, r) in answers.iter().zip([&first, &second, &capture]) {
            assert_eq!(answer["id"], r.id.as_str());
            assert_eq!(answer["status"], "applied", "{answer}");
        }
        let after = edited.replace("- [ ] first", "- [x] first");
        assert_eq!(v.read("Projects/A.md"), after);
        assert_eq!(answers[1]["sha256"], sha256(&after).as_str());
        assert_eq!(
            v.read("Inbox/2026-09-26-phone.md"),
            "# Inbox\n\n- 09:00 a thought\n"
        );

        // The same first record again: applied, and the file is left exactly as it is.
        let (_, body) = post(app.clone(), json!([record_json(&first)])).await;
        assert_eq!(body[0]["status"], "applied");
        assert_eq!(v.read("Projects/A.md"), after);

        // The same capture under a NEW id: already there, not appended twice.
        let again = WriteRecord {
            id: uuid::Uuid::new_v4().to_string(),
            ..capture.clone()
        };
        let (_, body) = post(app.clone(), json!([record_json(&again)])).await;
        assert_eq!(body[0]["status"], "applied");
        assert_eq!(
            v.read("Inbox/2026-09-26-phone.md"),
            "# Inbox\n\n- 09:00 a thought\n"
        );
    }

    #[tokio::test]
    async fn the_route_refuses_what_it_must_not_write() {
        let v = Vault::new("refusals");
        v.write("Today.md", "# Today\n");
        v.write("Projects/A.md", NOTE);
        let app = crate::app(AppState::new(v.cfg()));

        let today = WriteRecord {
            base_sha256: Some(sha256("# Today\n")),
            text: Some("# Today, rewritten\n".into()),
            ..rec("edit", "Today.md")
        };
        let stray = WriteRecord {
            text: Some("- a thought\n".into()),
            ..rec("capture", "Projects/A.md")
        };
        let outside = WriteRecord {
            text: Some("x".into()),
            ..rec("edit", "../escape.md")
        };
        let not_uuid = WriteRecord {
            id: "not-a-uuid".into(),
            ..edit(NOTE, "x\n", false)
        };
        let (status, body) = post(
            app,
            json!([
                record_json(&today),
                record_json(&stray),
                record_json(&outside),
                record_json(&not_uuid)
            ]),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        for answer in body.as_array().unwrap() {
            assert_eq!(answer["status"], "refused", "{answer}");
            assert!(answer["reason"].as_str().is_some());
        }
        assert_eq!(v.read("Today.md"), "# Today\n");
        assert_eq!(v.read("Projects/A.md"), NOTE);
        assert!(!v.root.join("escape.md").exists());
    }

    #[tokio::test]
    async fn a_conflict_writes_nothing_and_force_then_wins() {
        let v = Vault::new("conflict");
        let studio = NOTE.replace("two\n", "two from the Studio\n");
        v.write("Projects/A.md", &studio);
        let app = crate::app(AppState::new(v.cfg()));

        let device = NOTE.replace("two\n", "two from the phone\n");
        let r = edit(NOTE, &device, true);
        let (_, body) = post(app.clone(), json!([record_json(&r)])).await;
        assert_eq!(body[0]["status"], "conflict");
        assert_eq!(body[0]["current_text"], studio.as_str());
        assert_eq!(v.read("Projects/A.md"), studio);

        // "Keep mine": the same id, the current hash, and force.
        let keep = WriteRecord {
            base_sha256: Some(sha256(&studio)),
            force: true,
            ..r
        };
        let (_, body) = post(app, json!([record_json(&keep)])).await;
        assert_eq!(body[0]["status"], "applied");
        assert_eq!(v.read("Projects/A.md"), device);
    }

    #[tokio::test]
    async fn a_strand_tick_reaches_the_tick_ledger_once() {
        let v = Vault::new("strandtick");
        let note = "# Scratch\n\n## Drafts\n- [ ] **P1** Kits.\n";
        v.write("Strands/Scratch.md", note);
        let st = AppState::new(v.cfg());
        let app = crate::app(st.clone());
        let r = WriteRecord {
            path: "Strands/Scratch.md".into(),
            ..tick(note, 4, true)
        };
        let (_, body) = post(app.clone(), json!([record_json(&r)])).await;
        assert_eq!(body[0]["status"], "applied");
        assert_eq!(st.strand_ticks.pending_count(), 1);
        // The same tick through the old route is the same (note, id): still one.
        assert_eq!(
            crate::strandticks::report_app_tick(&st, "Scratch", "P1", true),
            Some("pending")
        );
        assert_eq!(st.strand_ticks.pending_count(), 1);
    }
}
