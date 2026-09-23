//! `GET /jesse/things` — the vault's `Things/` status notes as a structured,
//! audited snapshot, plus the nightly file that says whether they are still true.
//!
//! **This module reads the vault; it writes exactly one file, once a day, and
//! never a Things note.** That file is `Inbox/YYYY-MM-DD-things-audit.md`, a
//! rendering of the same findings this endpoint serves. There is one audit
//! implementation and two outputs, deliberately: a nightly report that could
//! disagree with the screen would be a second source of truth about the same
//! documents, and the failure it exists to catch (a note that quietly stopped
//! being true) is exactly the kind a second opinion hides.
//!
//! ## Why a parser and not a search
//!
//! Work state had no machine readable home. A thing's status lived in prose,
//! spread over a series index, a handful of drafts and whatever the last turn
//! remembered, so nothing could check it: a prompt could be launched and never
//! come back, a queue line could point at a file that had already been archived,
//! and a note could go a fortnight without an edit, and all three were invisible
//! until somebody re-read everything by hand. The format is now fixed (see
//! [`parse_thing`]), which is what makes a check possible at all.
//!
//! ## Same posture as [`crate::today`]
//!
//! Bearer auth, the shared rate limiter, ids-and-values-only JSON, a strong
//! ETag so the phone's poll costs a `304`, and a **line oriented, tolerant
//! parser**: no error path, every malformed thing degrades to a finding rather
//! than a failure. A note with no frontmatter still parses, still sorts and
//! still appears; it simply carries a `PARSE` finding saying so. The one thing
//! this parser does NOT share with `today.rs` is byte ranges, because nothing
//! here writes back into a note.

use crate::*;
use chrono::{Datelike, NaiveDate, Timelike};

// ---- The format's fixed vocabulary -----------------------------------------

/// The directory under the notes root that holds the status notes.
pub const THINGS_DIR: &str = "Things";

/// The path segment that marks a note, a draft or a research file as retired.
/// A Things note under it is not parsed at all, and a link INTO it from a live
/// queue line is [`QUEUE_ARCHIVED`] (the item was launched and never moved).
pub const ARCHIVE_SEGMENT: &str = "archive";

/// The five groups a note may declare. Anything else is [`GROUP`].
pub const THING_GROUPS: [&str; 5] = ["tag1", "personal", "network", "via-con-me", "perseido"];

/// The four states a note may declare. Anything else is [`STATE`].
pub const THING_STATES: [&str; 4] = ["active", "waiting", "dormant", "done"];

/// The two directories whose live files are expected to be owned by a thing.
/// Their `archive/` subdirectories are NOT walked: a retired draft owes nothing
/// to anybody, and walking them would make every completed piece of work a
/// standing finding.
const OWNED_DIRS: [&str; 2] = ["Projects/drafts", "Projects/Research"];

/// A Running item goes silent after this many days without an outcome. Three is
/// not arbitrary: a prompt launched on Friday and reported on Monday is normal,
/// and anything past that has stopped being "in flight" and started being
/// forgotten.
const RUNNING_SILENT_DAYS: i64 = 3;

/// An active note that has not been edited in this many days is stale.
const STALE_DAYS: i64 = 14;

/// An active note that has not been edited in this many days is not active.
const DORMANT_DAYS: i64 = 90;

/// More active things than a person can hold. Past this the board is a list,
/// not a plan.
const MAX_ACTIVE: usize = 20;

// ---- Finding codes ---------------------------------------------------------
//
// Every code is a `&'static str` const rather than a bare literal at the site
// that raises it, so the set is enumerable in one place, the nightly file and
// the JSON can never spell one differently, and a test can assert coverage by
// name.

pub const PARSE: &str = "PARSE";
pub const GROUP: &str = "GROUP";
pub const STATE: &str = "STATE";
pub const UPDATED_INVALID: &str = "UPDATED-INVALID";
pub const UPDATED_BEHIND: &str = "UPDATED-BEHIND";
pub const UPDATED_STALE: &str = "UPDATED-STALE";
pub const DORMANT_CANDIDATE: &str = "DORMANT-CANDIDATE";
pub const LINK_DEAD: &str = "LINK-DEAD";
pub const QUEUE_ARCHIVED: &str = "QUEUE-ARCHIVED";
pub const RUNNING_SILENT: &str = "RUNNING-SILENT";
pub const CHECKED_NOT_MOVED: &str = "CHECKED-NOT-MOVED";
pub const NO_NEXT: &str = "NO-NEXT";
pub const DUP_ID: &str = "DUP-ID";
pub const ORPHAN_DRAFT: &str = "ORPHAN-DRAFT";
pub const UNOWNED_PROMPT: &str = "UNOWNED-PROMPT";
pub const TOO_MANY: &str = "TOO-MANY";
pub const DONE_NOT_ARCHIVED: &str = "DONE-NOT-ARCHIVED";

/// Every code this module can raise, in the order the module documents them.
/// Used by the test that asserts each one has a fixture and a name.
pub const FINDING_CODES: [&str; 17] = [
    PARSE,
    GROUP,
    STATE,
    UPDATED_INVALID,
    UPDATED_BEHIND,
    UPDATED_STALE,
    DORMANT_CANDIDATE,
    LINK_DEAD,
    QUEUE_ARCHIVED,
    RUNNING_SILENT,
    CHECKED_NOT_MOVED,
    NO_NEXT,
    DUP_ID,
    ORPHAN_DRAFT,
    UNOWNED_PROMPT,
    TOO_MANY,
    DONE_NOT_ARCHIVED,
];

// ---- Wire types ------------------------------------------------------------

/// One thing the audit found wrong. `line` is the 1-based line in the note it
/// was found on, and is absent on a global finding (which is about a file that
/// is not a note at all).
#[derive(serde::Serialize, PartialEq, Eq, Debug, Clone)]
pub struct Finding {
    pub code: &'static str,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<usize>,
}

impl Finding {
    fn at(code: &'static str, line: usize, message: impl Into<String>) -> Self {
        Finding {
            code,
            message: message.into(),
            line: Some(line),
        }
    }
    fn global(code: &'static str, message: impl Into<String>) -> Self {
        Finding {
            code,
            message: message.into(),
            line: None,
        }
    }
}

/// The `**Waiting on:**` line. `jeremy` is the one bit the phone actually
/// renders differently: a gate on the operator is a thing he can clear right
/// now, and a gate on a provider or a dependency is not.
#[derive(serde::Serialize, PartialEq, Eq, Debug, Clone)]
pub struct ThingWaiting {
    pub text: String,
    pub jeremy: bool,
}

/// The next step: the first unchecked Queue item above `### Later`.
#[derive(serde::Serialize, PartialEq, Eq, Debug, Clone)]
pub struct ThingNext {
    pub id: String,
    pub text: String,
    pub link: Option<String>,
    pub waits_on: Option<String>,
}

#[derive(serde::Serialize, PartialEq, Eq, Debug, Clone, Default)]
pub struct ThingCounts {
    pub queue: usize,
    pub later: usize,
    pub running: usize,
    pub done: usize,
}

/// The four sections whose lines are items. `## Decisions` and `## Links` carry
/// bullets too, but never checkboxes, so nothing in them is an item.
#[derive(PartialEq, Eq, Debug, Clone, Copy)]
pub enum ThingSection {
    Queue,
    Later,
    Running,
    Done,
}

/// One `- [ ]` / `- [x]` line.
#[derive(PartialEq, Eq, Debug, Clone)]
pub struct ThingItem {
    pub section: ThingSection,
    /// The first bold span on the line, or empty when the line has none (which
    /// is itself a [`PARSE`] finding).
    pub id: String,
    /// The line after the checkbox, the optional date and the id, with the wiki
    /// links and the trailing `(waits on: …)` removed.
    pub text: String,
    /// The first wiki link on the line, alias and heading dropped.
    pub link: Option<String>,
    pub waits_on: Option<String>,
    /// The date after the FIRST `Launched`, for a Running item.
    pub launched: Option<String>,
    /// The `YYYY-MM-DD` between the checkbox and the id, which Done lines carry.
    pub date: Option<String>,
    pub checked: bool,
    pub line: usize,
}

/// A wiki link whose target has to resolve: one in `**Now:**`, `**Waiting
/// on:**`, `## Queue` (including `### Later`) or `## Running`. Links in Done,
/// Decisions and Links are not checked, because a finished item's target is
/// allowed to have been archived out from under it.
#[derive(PartialEq, Eq, Debug, Clone)]
struct LinkRef {
    target: String,
    line: usize,
    in_queue: bool,
}

/// One status note, parsed and audited.
#[derive(serde::Serialize, PartialEq, Eq, Debug, Clone, Default)]
pub struct Thing {
    pub slug: String,
    pub title: String,
    pub group: String,
    pub state: String,
    pub updated: String,
    pub repos: Vec<String>,
    pub now: Option<String>,
    pub waiting: Option<ThingWaiting>,
    pub next: Option<ThingNext>,
    pub counts: ThingCounts,
    pub findings: Vec<Finding>,

    /// The note's path relative to the notes root (`Things/Argus.md`). Off the
    /// wire because a client addresses a note by slug and never by path, and in
    /// the struct because the nightly file names the path on every bullet.
    #[serde(skip)]
    pub path: String,
    #[serde(skip)]
    pub items: Vec<ThingItem>,
    /// Every wiki target anywhere in the note, vault relative, `.md` appended.
    /// This is what answers "does this note link that draft".
    #[serde(skip)]
    pub targets: Vec<String>,
    #[serde(skip)]
    link_refs: Vec<LinkRef>,
}

/// Everything `GET /jesse/things` serves, and everything the nightly file
/// renders. `generated_at` is stamped on at response time rather than stored,
/// for the reason `today.rs` keeps it out of the snapshot: it moves on every
/// call, so folding it into the ETag would mean no client ever saw a `304`.
#[derive(serde::Serialize, PartialEq, Eq, Debug, Clone, Default)]
pub struct ThingsSnapshot {
    pub things: Vec<Thing>,
    pub global_findings: Vec<Finding>,
    pub counts: SnapshotCounts,
}

#[derive(serde::Serialize, PartialEq, Eq, Debug, Clone, Default)]
pub struct SnapshotCounts {
    pub active: usize,
    pub waiting: usize,
    pub dormant: usize,
}

impl ThingsSnapshot {
    /// Every finding in the snapshot, note findings first and then the global
    /// ones. The count the nightly file's header reports.
    pub fn finding_count(&self) -> usize {
        self.things.iter().map(|t| t.findings.len()).sum::<usize>() + self.global_findings.len()
    }
}

// ---- The parser ------------------------------------------------------------

/// Parse one note into a [`Thing`], **without touching the filesystem**.
///
/// Raises the findings that are a function of the document alone: [`PARSE`],
/// [`DUP_ID`], [`CHECKED_NOT_MOVED`] and [`QUEUE_ARCHIVED`] (a link target that
/// names `archive/` is archived whether or not the file is there). Everything
/// that needs the vault, a calendar or the other notes is [`audit_thing`].
///
/// The grammar, exactly:
///
/// 1. Frontmatter between two `---` lines: `group`, `state`, `updated`, and an
///    optional `repos` flow list.
/// 2. The first H1 is the title; the file stem is the slug.
/// 3. `**Now:**` and `**Waiting on:**` take the rest of their line. A waiting
///    line is a gate on the operator when its text starts `you:`.
/// 4. `## Queue` opens the queue and `### Later` its later list; `## Running`,
///    `## Done`, `## Decisions` and `## Links` open theirs. Any other H2 or H3
///    closes the current section, and prose is ignored.
/// 5. An item is `- [ ]` or `- [x]` (or `[X]`), an optional `YYYY-MM-DD`, then
///    the id as the first bold span, then text.
/// 6. The next step is the first unchecked Queue item above `### Later`.
pub fn parse_thing(slug: &str, src: &str) -> Thing {
    let lines: Vec<&str> = src.lines().collect();
    let mut thing = Thing {
        slug: slug.to_string(),
        path: format!("{THINGS_DIR}/{slug}.md"),
        ..Thing::default()
    };

    // 1. Frontmatter. A file that does not open with `---` has none at all,
    // which is one finding rather than three missing-key ones.
    let mut body_start = 0usize;
    let fm_end = (lines.first().map(|l| l.trim()) == Some("---"))
        .then(|| lines.iter().skip(1).position(|l| l.trim() == "---"))
        .flatten()
        .map(|p| p + 1);
    match fm_end {
        Some(end) => {
            body_start = end + 1;
            for raw in &lines[1..end] {
                let Some((key, value)) = raw.split_once(':') else {
                    continue;
                };
                let value = value.trim();
                match key.trim() {
                    "group" => thing.group = value.to_string(),
                    "state" => thing.state = value.to_string(),
                    "updated" => thing.updated = value.to_string(),
                    "repos" => thing.repos = parse_flow_list(value),
                    _ => {}
                }
            }
        }
        None => thing
            .findings
            .push(Finding::at(PARSE, 1, "no frontmatter block")),
    }

    // 2 to 5. One pass over the body.
    let mut section: Option<ThingSection> = None;
    let mut saw_queue_heading = false;
    for (idx, raw) in lines.iter().enumerate().skip(body_start) {
        let line_no = idx + 1;
        let text = raw.trim_end();

        if let Some(rest) = heading_level(text, 1) {
            if thing.title.is_empty() {
                thing.title = rest.to_string();
            }
            continue;
        }
        if let Some(rest) = heading_level(text, 2) {
            section = match rest {
                "Queue" => {
                    saw_queue_heading = true;
                    Some(ThingSection::Queue)
                }
                "Running" => Some(ThingSection::Running),
                "Done" => Some(ThingSection::Done),
                _ => None,
            };
            continue;
        }
        if let Some(rest) = heading_level(text, 3) {
            section = match (rest, section) {
                ("Later", Some(ThingSection::Queue)) => Some(ThingSection::Later),
                _ => None,
            };
            continue;
        }

        if let Some(rest) = text.strip_prefix("**Now:**") {
            if thing.now.is_none() {
                thing.now = Some(rest.trim().to_string());
                push_link_refs(&mut thing.link_refs, text, line_no, false);
            }
            continue;
        }
        if let Some(rest) = text.strip_prefix("**Waiting on:**") {
            if thing.waiting.is_none() {
                let text_out = rest.trim().to_string();
                thing.waiting = Some(ThingWaiting {
                    jeremy: text_out.to_lowercase().starts_with("you:"),
                    text: text_out,
                });
                push_link_refs(&mut thing.link_refs, text, line_no, false);
            }
            continue;
        }

        let Some(section) = section else { continue };
        let Some(item) = parse_item(section, text, line_no) else {
            continue;
        };
        if matches!(
            section,
            ThingSection::Queue | ThingSection::Later | ThingSection::Running
        ) {
            push_link_refs(
                &mut thing.link_refs,
                text,
                line_no,
                !matches!(section, ThingSection::Running),
            );
        }
        thing.items.push(item);
    }

    for target in wiki_targets(src) {
        let resolved = resolve_target(&target);
        if !resolved.is_empty() && !thing.targets.contains(&resolved) {
            thing.targets.push(resolved);
        }
    }

    if thing.title.is_empty() {
        thing.findings.push(Finding::at(PARSE, 1, "no H1 title"));
    }
    if !saw_queue_heading {
        thing
            .findings
            .push(Finding::at(PARSE, 1, "no `## Queue` heading"));
    }

    // Counts, the next step, and the per-item findings the document settles.
    let mut seen_ids: Vec<&str> = Vec::new();
    for item in &thing.items {
        match item.section {
            ThingSection::Queue => thing.counts.queue += 1,
            ThingSection::Later => thing.counts.later += 1,
            ThingSection::Running => thing.counts.running += 1,
            ThingSection::Done => thing.counts.done += 1,
        }
        if item.id.is_empty() {
            thing.findings.push(Finding::at(
                PARSE,
                item.line,
                format!("item line has no bold id: {}", clip(&item.text)),
            ));
        } else if seen_ids.contains(&item.id.as_str()) {
            thing.findings.push(Finding::at(
                DUP_ID,
                item.line,
                format!("id {} is used more than once", item.id),
            ));
        } else {
            seen_ids.push(item.id.as_str());
        }
        if item.checked
            && matches!(
                item.section,
                ThingSection::Queue | ThingSection::Later | ThingSection::Running
            )
        {
            thing.findings.push(Finding::at(
                CHECKED_NOT_MOVED,
                item.line,
                format!(
                    "{} is checked but still in Queue or Running",
                    id_or_line(item)
                ),
            ));
        }
    }
    for reference in &thing.link_refs {
        if reference.in_queue && is_archived(&reference.target) {
            thing.findings.push(Finding::at(
                QUEUE_ARCHIVED,
                reference.line,
                format!("queue link points into archive: {}", reference.target),
            ));
        }
    }
    thing.next = thing
        .items
        .iter()
        .find(|i| i.section == ThingSection::Queue && !i.checked && !i.id.is_empty())
        .map(|i| ThingNext {
            id: i.id.clone(),
            text: i.text.clone(),
            link: i.link.clone(),
            waits_on: i.waits_on.clone(),
        });
    thing.findings.sort_by_key(|f| (f.line, f.code));
    thing
}

/// `# Heading` at exactly `level`, or `None`. `##` is not an H1 and `###` is not
/// an H2, so each level is matched on its own prefix and the next character.
fn heading_level(line: &str, level: usize) -> Option<&str> {
    let hashes = "#".repeat(level);
    let rest = line.strip_prefix(&hashes)?;
    if rest.starts_with('#') || !rest.starts_with(' ') {
        return None;
    }
    Some(rest.trim())
}

/// A YAML flow list of bare scalars: `[a/b, c/d]`. Anything else is empty.
fn parse_flow_list(value: &str) -> Vec<String> {
    let Some(inner) = value.strip_prefix('[').and_then(|v| v.strip_suffix(']')) else {
        return Vec::new();
    };
    inner
        .split(',')
        .map(|s| s.trim().trim_matches(['"', '\'']).to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// One item line, or `None` when the line is not one.
fn parse_item(section: ThingSection, line: &str, line_no: usize) -> Option<ThingItem> {
    let body = line.trim_start();
    let (checked, rest) = if let Some(r) = body.strip_prefix("- [ ] ") {
        (false, r)
    } else if let Some(r) = body.strip_prefix("- [x] ") {
        (true, r)
    } else {
        (true, body.strip_prefix("- [X] ")?)
    };

    // An optional leading date, which Done lines carry.
    let (date, rest) = match rest.get(..10) {
        Some(d) if valid_iso_date(d).is_some() && rest.as_bytes().get(10) == Some(&b' ') => {
            (Some(d.to_string()), rest[11..].trim_start())
        }
        _ => (None, rest),
    };

    let (id, after_id) = match bold_span(rest) {
        Some((inner, after)) => (inner.trim().to_string(), after),
        None => (String::new(), rest),
    };

    Some(ThingItem {
        section,
        id,
        text: item_text(after_id),
        link: wiki_targets(rest).into_iter().next(),
        waits_on: waits_on(rest),
        launched: date_after(rest, "Launched "),
        date,
        checked,
        line: line_no,
    })
}

/// The inner text of the first `**bold**` span and the remainder after it.
fn bold_span(s: &str) -> Option<(&str, &str)> {
    let open = s.find("**")? + 2;
    let close = s[open..].find("**")? + open;
    let inner = &s[open..close];
    (!inner.trim().is_empty()).then(|| (inner, &s[close + 2..]))
}

/// An item's display text: the remainder after the id with the wiki links and a
/// trailing `(waits on: …)` removed, whitespace tidied. Both of those are
/// carried as their own fields, and leaving them in the prose would make every
/// client strip them again.
fn item_text(rest: &str) -> String {
    let mut out = String::with_capacity(rest.len());
    let mut i = 0usize;
    while i < rest.len() {
        let tail = &rest[i..];
        if let Some(end) = tail.strip_prefix("[[").and_then(|t| t.find("]]")) {
            i += 2 + end + 2;
            continue;
        }
        if let Some((inner, after)) = parenthetical_at(tail) {
            if is_waits_on(inner) {
                i += after;
                continue;
            }
        }
        let ch = tail.chars().next().unwrap_or('\u{0}');
        out.push(ch);
        i += ch.len_utf8();
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The `(…)` that starts at `s`, as `(inner, byte length)`. Not nested: the
/// format has no nested parentheses in an item line, and treating one as two
/// would only ever drop more text than intended.
fn parenthetical_at(s: &str) -> Option<(&str, usize)> {
    let inner_end = s.strip_prefix('(')?.find(')')?;
    Some((&s[1..1 + inner_end], 1 + inner_end + 1))
}

fn is_waits_on(inner: &str) -> bool {
    inner.trim_start().to_lowercase().starts_with("waits on:")
}

/// The text inside the LAST parenthetical that begins `waits on:`. Last rather
/// than first because a line that names a dependency twice means the one it ends
/// on, and because a mid-sentence aside is not the gate.
fn waits_on(line: &str) -> Option<String> {
    let mut found = None;
    let mut i = 0usize;
    while i < line.len() {
        let tail = &line[i..];
        match parenthetical_at(tail) {
            Some((inner, after)) => {
                if is_waits_on(inner) {
                    let value = inner.trim_start()["waits on:".len()..].trim();
                    if !value.is_empty() {
                        found = Some(value.to_string());
                    }
                }
                i += after;
            }
            None => i += tail.chars().next().map_or(1, char::len_utf8),
        }
    }
    found
}

/// Every wiki link target in `s`, in source order, alias and heading dropped.
/// Line oriented and deliberately narrow: only `[[…]]` matters here, because a
/// URL in a note is not something the audit can resolve.
fn wiki_targets(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < s.len() {
        let tail = &s[i..];
        if let Some(end) = tail.strip_prefix("[[").and_then(|t| t.find("]]")) {
            let inner = &tail[2..2 + end];
            let target = inner.split('|').next().unwrap_or(inner);
            let target = target.split('#').next().unwrap_or(target).trim();
            if !target.is_empty() {
                out.push(target.to_string());
            }
            i += 2 + end + 2;
            continue;
        }
        i += tail.chars().next().map_or(1, char::len_utf8);
    }
    out
}

fn push_link_refs(out: &mut Vec<LinkRef>, line: &str, line_no: usize, in_queue: bool) {
    for target in wiki_targets(line) {
        out.push(LinkRef {
            target,
            line: line_no,
            in_queue,
        });
    }
}

/// A `YYYY-MM-DD` immediately after the first occurrence of `key` that actually
/// parses as a date. One live note repeats `Launched` in its prose, so the first
/// real date wins and the rest of the line is ignored.
fn date_after(hay: &str, key: &str) -> Option<String> {
    let mut from = 0usize;
    while let Some(hit) = hay[from..].find(key) {
        let at = from + hit + key.len();
        if let Some(candidate) = hay.get(at..at + 10) {
            if valid_iso_date(candidate).is_some() {
                return Some(candidate.to_string());
            }
        }
        from = at;
    }
    None
}

/// A wiki target as a notes-root-relative file path: the `todo-list/` name
/// stripped (see [`crate::today::vault_relative`], which this shares so both
/// spellings of the vault prefix stay accepted in one place) and `.md` appended.
pub fn resolve_target(target: &str) -> String {
    let rel = vault_relative(target);
    if rel.is_empty() {
        return String::new();
    }
    match rel.ends_with(".md") {
        true => rel,
        false => format!("{rel}.md"),
    }
}

fn is_archived(target: &str) -> bool {
    resolve_target(target).contains(&format!("/{ARCHIVE_SEGMENT}/"))
}

fn clip(s: &str) -> String {
    match s.chars().count() > 60 {
        true => s.chars().take(60).collect::<String>() + "…",
        false => s.to_string(),
    }
}

fn id_or_line(item: &ThingItem) -> String {
    match item.id.is_empty() {
        true => format!("the item on line {}", item.line),
        false => item.id.clone(),
    }
}

// ---- The audit -------------------------------------------------------------

/// Whole-days between two `YYYY-MM-DD` strings, `later` minus `earlier`.
fn days_between(earlier: &str, later: &str) -> Option<i64> {
    let a = NaiveDate::parse_from_str(earlier, "%Y-%m-%d").ok()?;
    let b = NaiveDate::parse_from_str(later, "%Y-%m-%d").ok()?;
    Some((b - a).num_days())
}

/// The findings that need the vault or a calendar: everything except the ones
/// [`parse_thing`] already raised. `today` is `YYYY-MM-DD` in the scheduler's
/// zone, passed in rather than read, so the whole audit is reproducible.
pub fn audit_thing(thing: &mut Thing, notes_root: &Path, today: &str) {
    if !THING_GROUPS.contains(&thing.group.as_str()) {
        thing.findings.push(Finding::at(
            GROUP,
            1,
            match thing.group.is_empty() {
                true => "no group in the frontmatter".to_string(),
                false => format!("group {} is not one of the five", thing.group),
            },
        ));
    }
    if !THING_STATES.contains(&thing.state.as_str()) {
        thing.findings.push(Finding::at(
            STATE,
            1,
            match thing.state.is_empty() {
                true => "no state in the frontmatter".to_string(),
                false => format!("state {} is not one of the four", thing.state),
            },
        ));
    }

    let updated_age = days_between(&thing.updated, today);
    match updated_age {
        None => thing.findings.push(Finding::at(
            UPDATED_INVALID,
            1,
            match thing.updated.is_empty() {
                true => "no updated date in the frontmatter".to_string(),
                false => format!("updated {} is not a date", thing.updated),
            },
        )),
        Some(age) if age < 0 => thing.findings.push(Finding::at(
            UPDATED_INVALID,
            1,
            format!("updated {} is in the future", thing.updated),
        )),
        Some(age) => {
            // The newest date the note itself carries in Running or Done. If the
            // work moved after the header said it last did, the header is behind.
            let newest = thing
                .items
                .iter()
                .filter(|i| matches!(i.section, ThingSection::Running | ThingSection::Done))
                .filter_map(|i| i.date.clone().or_else(|| i.launched.clone()))
                .max();
            if let Some(newest) = newest {
                if days_between(&thing.updated, &newest).is_some_and(|d| d > 0) {
                    thing.findings.push(Finding::at(
                        UPDATED_BEHIND,
                        1,
                        format!(
                            "updated {} is older than {}, the newest date in Running or Done",
                            thing.updated, newest
                        ),
                    ));
                }
            }
            if thing.state == "active" && age > DORMANT_DAYS {
                thing.findings.push(Finding::at(
                    DORMANT_CANDIDATE,
                    1,
                    format!("active and untouched for {age} days"),
                ));
            } else if thing.state == "active" && age > STALE_DAYS {
                thing.findings.push(Finding::at(
                    UPDATED_STALE,
                    1,
                    format!("active and untouched for {age} days"),
                ));
            }
        }
    }

    for reference in &thing.link_refs {
        let resolved = resolve_target(&reference.target);
        if resolved.is_empty() || notes_root.join(&resolved).is_file() {
            continue;
        }
        thing.findings.push(Finding::at(
            LINK_DEAD,
            reference.line,
            format!(
                "link does not resolve under the vault: {}",
                reference.target
            ),
        ));
    }

    for item in &thing.items {
        if item.section != ThingSection::Running {
            continue;
        }
        match &item.launched {
            None => thing.findings.push(Finding::at(
                RUNNING_SILENT,
                item.line,
                format!("{} is running with no launched date", id_or_line(item)),
            )),
            Some(launched) => {
                if let Some(age) = days_between(launched, today) {
                    if age > RUNNING_SILENT_DAYS {
                        thing.findings.push(Finding::at(
                            RUNNING_SILENT,
                            item.line,
                            format!(
                                "{} launched {launched}, no outcome after {age} days",
                                id_or_line(item)
                            ),
                        ));
                    }
                }
            }
        }
    }

    if thing.state == "active" && thing.next.is_none() {
        thing.findings.push(Finding::at(
            NO_NEXT,
            1,
            "active with no unchecked Queue item above Later",
        ));
    }

    thing.findings.sort_by_key(|f| (f.line, f.code));
}

// ---- The snapshot ----------------------------------------------------------

/// Read, parse, audit and sort every live note under `<notes_root>/Things/`,
/// then scan the owned directories for the two global findings.
///
/// `today` is `YYYY-MM-DD`; every date comparison in the audit is against it, so
/// the whole snapshot is a pure function of the vault plus that one string.
pub fn snapshot(notes_root: &Path, today: &str) -> ThingsSnapshot {
    let dir = notes_root.join(THINGS_DIR);
    let mut parsed: Vec<Thing> = Vec::new();
    let mut entries: Vec<PathBuf> = match std::fs::read_dir(&dir) {
        Ok(rd) => rd
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.is_file() && p.extension().is_some_and(|x| x == "md"))
            .collect(),
        Err(_) => Vec::new(),
    };
    entries.sort();
    for path in entries {
        let Some(slug) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let Ok(src) = std::fs::read_to_string(&path) else {
            continue;
        };
        let mut thing = parse_thing(slug, &src);
        audit_thing(&mut thing, notes_root, today);
        parsed.push(thing);
    }

    // A `done` note is off the board, but a `done` note still sitting beside the
    // live ones is a filing failure and has to be said somewhere. It goes to the
    // global list, which is the only place left once the note itself is excluded.
    let mut global: Vec<Finding> = Vec::new();
    for thing in parsed.iter().filter(|t| t.state == "done") {
        global.push(Finding::global(
            DONE_NOT_ARCHIVED,
            format!(
                "{} is done but is not under {THINGS_DIR}/{ARCHIVE_SEGMENT}/",
                thing.path
            ),
        ));
    }

    let mut things: Vec<Thing> = parsed.into_iter().filter(|t| t.state != "done").collect();
    // Newest first, then by title so the order is total and a redeploy cannot
    // reshuffle two notes edited on the same day.
    things.sort_by(|a, b| {
        b.updated
            .cmp(&a.updated)
            .then_with(|| a.title.cmp(&b.title))
            .then_with(|| a.slug.cmp(&b.slug))
    });

    global.extend(scan_owned_files(notes_root, &things));

    let counts = SnapshotCounts {
        active: things.iter().filter(|t| t.state == "active").count(),
        waiting: things.iter().filter(|t| t.state == "waiting").count(),
        dormant: things.iter().filter(|t| t.state == "dormant").count(),
    };
    if counts.active > MAX_ACTIVE {
        global.push(Finding::global(
            TOO_MANY,
            format!(
                "{} active things, more than the {MAX_ACTIVE} a board can hold",
                counts.active
            ),
        ));
    }

    ThingsSnapshot {
        things,
        global_findings: global,
        counts,
    }
}

/// [`ORPHAN_DRAFT`] and [`UNOWNED_PROMPT`]: the live files under the owned
/// directories, checked against the notes that claim them. Subdirectories are
/// not walked, which is exactly what keeps `archive/` out of scope.
fn scan_owned_files(notes_root: &Path, things: &[Thing]) -> Vec<Finding> {
    let mut out = Vec::new();
    for dir in OWNED_DIRS {
        let mut paths: Vec<PathBuf> = match std::fs::read_dir(notes_root.join(dir)) {
            Ok(rd) => rd
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.is_file() && p.extension().is_some_and(|x| x == "md"))
                .collect(),
            Err(_) => continue,
        };
        paths.sort();
        for path in paths {
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let rel = format!("{dir}/{name}");
            let Ok(src) = std::fs::read_to_string(&path) else {
                continue;
            };
            match frontmatter_value(&src, "thing") {
                None => {
                    if name.to_lowercase().contains("prompt") {
                        out.push(Finding::global(
                            UNOWNED_PROMPT,
                            format!("{rel} has no thing: key"),
                        ));
                    }
                }
                Some(slug) => match things.iter().find(|t| t.slug == slug) {
                    None => out.push(Finding::global(
                        ORPHAN_DRAFT,
                        format!("{rel} names thing: {slug}, which has no note"),
                    )),
                    Some(thing) => {
                        if !thing.targets.iter().any(|t| t == &rel) {
                            out.push(Finding::global(
                                ORPHAN_DRAFT,
                                format!("{rel} names thing: {slug}, which does not link it"),
                            ));
                        }
                    }
                },
            }
        }
    }
    out
}

/// One frontmatter scalar from a file that may or may not have frontmatter.
fn frontmatter_value(src: &str, key: &str) -> Option<String> {
    let lines: Vec<&str> = src.lines().collect();
    if lines.first().map(|l| l.trim()) != Some("---") {
        return None;
    }
    let end = lines.iter().skip(1).position(|l| l.trim() == "---")? + 1;
    for raw in &lines[1..end] {
        if let Some((k, v)) = raw.split_once(':') {
            if k.trim() == key {
                let v = v.trim();
                return (!v.is_empty()).then(|| v.to_string());
            }
        }
    }
    None
}

// ---- The nightly report ----------------------------------------------------

/// The nightly file's body for `date`, byte stable for a given snapshot.
///
/// **No dash of any kind in the prose it writes.** The report is read on a phone
/// and pasted into notes and prompts, where an em dash is a character that has to
/// survive four more programs; a colon or a full stop says the same thing and
/// always arrives. The `- ` bullet marker is a list, not a dash.
pub fn render_report(snapshot: &ThingsSnapshot, date: &str) -> String {
    let mut out = String::new();
    out.push_str(&format!("# Things audit {date}\n\n"));
    out.push_str(&format!(
        "Active {}, waiting {}, dormant {}, findings {}.\n\n",
        snapshot.counts.active,
        snapshot.counts.waiting,
        snapshot.counts.dormant,
        snapshot.finding_count(),
    ));
    if snapshot.finding_count() == 0 {
        out.push_str("No findings.\n");
        return out;
    }
    for thing in &snapshot.things {
        for finding in &thing.findings {
            out.push_str(&format!(
                "- {} · {} · {} ({})\n",
                finding.code, thing.title, finding.message, thing.path
            ));
        }
    }
    for finding in &snapshot.global_findings {
        out.push_str(&format!("- {} · {}\n", finding.code, finding.message));
    }
    out
}

// ---- The nightly writer ----------------------------------------------------

/// How often the writer wakes. The file is due at a minute boundary, so a tick
/// well inside a minute keeps the worst case start delay under the precision
/// anybody declared. It is the same reasoning as [`crate::scheduler::SCHEDULER_TICK`].
const AUDIT_TICK: Duration = Duration::from_secs(30);

/// The hour and minute, in the scheduler's zone, the day's file is due. After
/// the morning routine's own chain, so a note it rewrites is audited as it now
/// stands rather than as it stood last night.
const AUDIT_AT: (u32, u32) = (3, 20);

/// What one pass of the writer did. Every arm is a legitimate outcome; only
/// [`AuditWrite::Wrote`] changed anything.
#[derive(PartialEq, Eq, Debug, Clone)]
pub enum AuditWrite {
    Wrote(PathBuf),
    /// Today's file is already there. **The idempotency guarantee**: a restart
    /// at noon re-reads a file it wrote at 03:20 and leaves it alone, so the
    /// vault's copy is the one that was true when the audit ran.
    AlreadyThere(PathBuf),
    /// Before 03:20 in the scheduler's zone.
    NotYet,
    /// No `Things/` directory under the notes root.
    NoThingsDir,
    /// No vault configured, or the write failed.
    Unavailable(String),
}

/// The day's audit file, written once. Takes the clock rather than reading one,
/// so a test can put the instant past 03:20 and prove both halves of the
/// contract: it creates the file, and a second call does not overwrite it.
pub fn run_things_audit(cfg: &Config, clock: &SchedulerClock) -> AuditWrite {
    if cfg.vault.is_empty() {
        return AuditWrite::Unavailable("no vault configured".to_string());
    }
    let Some(local) = chrono::DateTime::from_timestamp_millis(clock.now_ms() as i64)
        .map(|t| t.with_timezone(clock.tz()))
    else {
        return AuditWrite::Unavailable("the clock is not representable".to_string());
    };
    if (local.hour(), local.minute()) < AUDIT_AT {
        return AuditWrite::NotYet;
    }
    let date = format!(
        "{:04}-{:02}-{:02}",
        local.year(),
        local.month(),
        local.day()
    );

    let notes_root = notes_root(cfg);
    if !notes_root.join(THINGS_DIR).is_dir() {
        return AuditWrite::NoThingsDir;
    }
    let path = notes_root
        .join("Inbox")
        .join(format!("{date}-things-audit.md"));
    if path.exists() {
        return AuditWrite::AlreadyThere(path);
    }
    if let Some(parent) = path.parent() {
        if let Err(e) = std::fs::create_dir_all(parent) {
            return AuditWrite::Unavailable(format!("cannot create {}: {e}", parent.display()));
        }
    }
    let body = render_report(&snapshot(&notes_root, &date), &date);
    match write_atomic(&path, body.as_bytes()) {
        Ok(()) => AuditWrite::Wrote(path),
        Err(e) => AuditWrite::Unavailable(format!("cannot write {}: {e}", path.display())),
    }
}

/// Start the nightly writer beside the scheduler.
///
/// One task, one interval, and the file's own existence decides what is due:
/// the same shape as the scheduler's tick, and the reason the "once at startup
/// if today's file is missing and it is past 03:20" case needs no second code
/// path. It reads the scheduler's clock on every pass, so an away profile's zone
/// moves the audit exactly as it moves every other calendar decision.
pub fn spawn_things_audit(st: AppState) {
    tokio::spawn(async move {
        // Every pass that changes nothing is silent after the first, so a quiet
        // day costs one line rather than 2,880.
        let mut last_quiet = String::new();
        loop {
            let clock = st.scheduler.clock();
            match run_things_audit(&st.cfg, &clock) {
                AuditWrite::Wrote(path) => {
                    last_quiet.clear();
                    eprintln!("jesse-bridge: things audit written to {}", path.display());
                }
                AuditWrite::AlreadyThere(_) | AuditWrite::NotYet => last_quiet.clear(),
                AuditWrite::NoThingsDir => {
                    let msg = "no Things/ directory under the vault".to_string();
                    if last_quiet != msg {
                        eprintln!("jesse-bridge: WARNING: things audit skipped: {msg}");
                        last_quiet = msg;
                    }
                }
                AuditWrite::Unavailable(why) => {
                    if last_quiet != why {
                        eprintln!("jesse-bridge: WARNING: things audit skipped: {why}");
                        last_quiet = why;
                    }
                }
            }
            tokio::time::sleep(AUDIT_TICK).await;
        }
    });
}

// ---- The routes ------------------------------------------------------------

/// `YYYY-MM-DD` and an RFC 3339 instant, both in the scheduler's zone.
///
/// The zone matters for the DATE and only for the date: an audit run at 00:30 in
/// Rome is the new day's, and reading the day off a UTC clock would give it
/// yesterday's findings. The instant carries its offset for the same reason.
fn zoned_now(st: &AppState) -> (String, String) {
    let clock = st.scheduler.clock();
    match chrono::DateTime::from_timestamp_millis(clock.now_ms() as i64)
        .map(|t| t.with_timezone(clock.tz()))
    {
        Some(t) => (
            format!("{:04}-{:02}-{:02}", t.year(), t.month(), t.day()),
            t.to_rfc3339_opts(chrono::SecondsFormat::Secs, false),
        ),
        None => (String::new(), rfc3339_utc(SystemTime::now())),
    }
}

/// Serve a body under a strong ETag, with `generated_at` stamped on AFTER the
/// tag is computed. Same contract as [`crate::today`]'s response helper, and for
/// the same reason: a tag that moved with the clock would never produce a `304`.
fn things_response(headers: &HeaderMap, mut value: Value, generated_at: &str) -> Response {
    let etag = strong_etag(&serde_json::to_string(&value).unwrap_or_default());
    if let Some(inm) = headers
        .get(axum::http::header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
    {
        if if_none_match_matches(inm, &etag) {
            return (StatusCode::NOT_MODIFIED, [(axum::http::header::ETAG, etag)]).into_response();
        }
    }
    if let Some(obj) = value.as_object_mut() {
        obj.insert("generated_at".to_string(), json!(generated_at));
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

/// `GET /jesse/things` — every active thing, sorted newest first, with its next
/// step and its findings. Bearer auth and the shared limiter, strictly read
/// only, and a pure function of the vault plus today's date.
///
/// A missing `Things/` directory is `200` with empty lists rather than a `404`,
/// the same degradation `/jesse/today` gives a missing day file: the phone
/// renders an empty board, not an error.
pub async fn jesse_things(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    let (today, generated_at) = zoned_now(&st);
    let snap = snapshot(&notes_root(&st.cfg), &today);
    let value = serde_json::to_value(&snap).unwrap_or_else(|_| json!({}));
    Ok(things_response(&headers, value, &generated_at))
}

/// `GET /jesse/things/{slug}` — one note's markdown beside its parsed form.
///
/// The slug is the file stem and nothing else. A slug carrying a path separator
/// or a `..` is `404` BEFORE any path is composed: the only thing that reaches
/// the filesystem is `<notes root>/Things/<slug>.md`, and rejecting the shape
/// first is what keeps that a claim about the code rather than about `PathBuf`.
pub async fn jesse_thing(
    State(st): State<AppState>,
    UrlPath(slug): UrlPath<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    if !is_safe_slug(&slug) {
        return Err((StatusCode::NOT_FOUND, "no thing by that slug".to_string()));
    }
    let notes_root = notes_root(&st.cfg);
    let path = notes_root.join(THINGS_DIR).join(format!("{slug}.md"));
    let Ok(markdown) = std::fs::read_to_string(&path) else {
        return Err((StatusCode::NOT_FOUND, "no thing by that slug".to_string()));
    };
    let (today, generated_at) = zoned_now(&st);
    let mut thing = parse_thing(&slug, &markdown);
    audit_thing(&mut thing, &notes_root, &today);
    let value = json!({ "markdown": markdown, "thing": thing });
    Ok(things_response(&headers, value, &generated_at))
}

/// A slug that can only ever name a file directly inside `Things/`: no
/// separator, no traversal, no dot-file, no empty string.
fn is_safe_slug(slug: &str) -> bool {
    !slug.is_empty()
        && !slug.starts_with('.')
        && !slug.contains("..")
        && !slug.contains('/')
        && !slug.contains('\\')
        && !slug.contains('\0')
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    const CLEAN: &str = include_str!("../tests/fixtures/things/vault/Things/Clean-Thing.md");
    const MESSY: &str = include_str!("../tests/fixtures/things/vault/Things/Messy-Thing.md");

    fn fixture_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/things/vault")
    }

    // ---- The grammar -------------------------------------------------------

    #[test]
    fn parses_frontmatter_title_now_and_waiting() {
        let t = parse_thing("Clean-Thing", CLEAN);
        assert_eq!(t.group, "personal");
        assert_eq!(t.state, "active");
        assert_eq!(t.updated, "2026-09-23");
        assert_eq!(t.repos, vec!["jeremyandrews/argus".to_string()]);
        assert_eq!(t.title, "Clean Thing");
        assert_eq!(t.slug, "Clean-Thing");
        assert_eq!(
            t.now.as_deref(),
            Some("One sentence saying where the thing stands today.")
        );
        let waiting = t.waiting.clone().unwrap();
        assert!(waiting.jeremy, "a `you:` gate is the operator's");
        assert!(waiting.text.starts_with("you: create the empty"));
    }

    #[test]
    fn waiting_without_you_is_not_a_jeremy_gate() {
        let t = parse_thing("Messy-Thing", MESSY);
        assert_eq!(t.waiting.map(|w| w.jeremy), Some(false));
    }

    #[test]
    fn item_line_splits_into_id_text_link_and_waits_on() {
        let t = parse_thing("Clean-Thing", CLEAN);
        let next = t.next.clone().unwrap();
        assert_eq!(next.id, "A1d");
        assert_eq!(next.text, "Guest budget probe on the fixed kernel.");
        assert_eq!(
            next.link.as_deref(),
            Some("todo-list/Projects/drafts/2026-09-23-guest-budget")
        );
        assert_eq!(next.waits_on.as_deref(), Some("provider key"));
    }

    #[test]
    fn counts_separate_queue_later_running_and_done() {
        let t = parse_thing("Clean-Thing", CLEAN);
        assert_eq!(
            t.counts,
            ThingCounts {
                queue: 2,
                later: 1,
                running: 1,
                done: 2
            }
        );
    }

    #[test]
    fn next_step_is_the_first_unchecked_queue_item_above_later() {
        // The Later list holds an unchecked item; it must never be the next step.
        let t = parse_thing("Clean-Thing", CLEAN);
        assert_eq!(t.next.map(|n| n.id).as_deref(), Some("A1d"));
        assert!(t.items.iter().any(|i| i.section == ThingSection::Later));
    }

    #[test]
    fn done_line_carries_its_date_and_running_line_its_launched() {
        let t = parse_thing("Clean-Thing", CLEAN);
        let done: Vec<Option<String>> = t
            .items
            .iter()
            .filter(|i| i.section == ThingSection::Done)
            .map(|i| i.date.clone())
            .collect();
        assert_eq!(
            done,
            vec![
                Some("2026-09-23".to_string()),
                Some("2026-09-19".to_string())
            ]
        );
        let running = t
            .items
            .iter()
            .find(|i| i.section == ThingSection::Running)
            .unwrap();
        assert_eq!(running.launched.as_deref(), Some("2026-09-23"));
    }

    #[test]
    fn a_repeated_launched_word_takes_the_first_date() {
        let line = "- [ ] **A6** Forms. Launched 2026-09-18 while A5 was half merged. Launched 2026-09-20.";
        let item = parse_item(ThingSection::Running, line, 1).unwrap();
        assert_eq!(item.launched.as_deref(), Some("2026-09-18"));
    }

    #[test]
    fn an_unknown_h2_closes_the_current_section() {
        let src = "---\ngroup: tag1\nstate: active\nupdated: 2026-09-23\n---\n# T\n\n## Queue\n- [ ] **A1** In.\n\n## Notes\n- [ ] **A2** Out.\n";
        let t = parse_thing("T", src);
        assert_eq!(t.counts.queue, 1);
        assert_eq!(t.items.len(), 1);
    }

    #[test]
    fn a_later_heading_outside_the_queue_opens_nothing() {
        let src = "---\ngroup: tag1\nstate: active\nupdated: 2026-09-23\n---\n# T\n\n## Queue\n- [ ] **A1** In.\n\n## Running\n### Later\n- [ ] **A2** Out.\n";
        let t = parse_thing("T", src);
        assert_eq!(t.counts.later, 0);
        assert_eq!(t.counts.running, 0);
        assert_eq!(t.items.len(), 1);
    }

    // ---- One test per finding code -----------------------------------------

    fn codes(findings: &[Finding]) -> Vec<&str> {
        findings.iter().map(|f| f.code).collect()
    }

    #[test]
    fn finding_parse_covers_frontmatter_h1_queue_and_a_missing_id() {
        let t = parse_thing("None", "just prose\n");
        assert_eq!(codes(&t.findings), vec![PARSE, PARSE, PARSE]);
        let t = parse_thing("Messy-Thing", MESSY);
        assert!(t
            .findings
            .iter()
            .any(|f| f.code == PARSE && f.message.contains("no bold id")));
    }

    #[test]
    fn finding_group_and_state_reject_a_value_outside_the_set() {
        let mut t = parse_thing("Messy-Thing", MESSY);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        assert!(codes(&t.findings).contains(&GROUP));
        assert!(
            !codes(&t.findings).contains(&STATE),
            "active is one of the four"
        );

        let src = "---\ngroup: tag1\nstate: paused\nupdated: 2026-09-23\n---\n# T\n\n## Queue\n- [ ] **A1** In.\n";
        let mut t = parse_thing("T", src);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        assert_eq!(codes(&t.findings), vec![STATE]);
    }

    #[test]
    fn finding_updated_invalid_catches_a_future_date() {
        let src = "---\ngroup: tag1\nstate: active\nupdated: 2027-01-01\n---\n# T\n\n## Queue\n- [ ] **A1** In.\n";
        let mut t = parse_thing("T", src);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        assert!(t
            .findings
            .iter()
            .any(|f| f.code == UPDATED_INVALID && f.message.contains("in the future")));
    }

    #[test]
    fn finding_updated_behind_compares_with_running_and_done() {
        let mut t = parse_thing("Messy-Thing", MESSY);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        assert!(codes(&t.findings).contains(&UPDATED_BEHIND));
    }

    #[test]
    fn finding_updated_stale_and_dormant_candidate_are_exclusive() {
        let src = "---\ngroup: tag1\nstate: active\nupdated: 2026-09-01\n---\n# T\n\n## Queue\n- [ ] **A1** In.\n";
        let mut stale = parse_thing("T", src);
        audit_thing(&mut stale, &fixture_root(), "2026-09-23");
        assert!(codes(&stale.findings).contains(&UPDATED_STALE));
        assert!(!codes(&stale.findings).contains(&DORMANT_CANDIDATE));

        let src = src.replace("2026-09-01", "2026-01-01");
        let mut old = parse_thing("T", &src);
        audit_thing(&mut old, &fixture_root(), "2026-09-23");
        assert!(codes(&old.findings).contains(&DORMANT_CANDIDATE));
        assert!(!codes(&old.findings).contains(&UPDATED_STALE));
    }

    #[test]
    fn finding_link_dead_and_queue_archived() {
        let mut t = parse_thing("Messy-Thing", MESSY);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        assert!(codes(&t.findings).contains(&LINK_DEAD));
        assert!(codes(&t.findings).contains(&QUEUE_ARCHIVED));
    }

    #[test]
    fn finding_running_silent_covers_both_an_old_date_and_no_date() {
        let mut t = parse_thing("Messy-Thing", MESSY);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        let silent: Vec<&str> = t
            .findings
            .iter()
            .filter(|f| f.code == RUNNING_SILENT)
            .map(|f| f.message.as_str())
            .collect();
        assert_eq!(silent.len(), 2, "{silent:?}");
        assert!(silent.iter().any(|m| m.contains("no launched date")));
        assert!(silent.iter().any(|m| m.contains("no outcome after")));
    }

    #[test]
    fn finding_running_silent_spares_a_prompt_launched_three_days_ago() {
        let src = "---\ngroup: tag1\nstate: active\nupdated: 2026-09-23\n---\n# T\n\n## Queue\n- [ ] **A1** In.\n\n## Running\n- [ ] **B1** Out. Launched 2026-09-20.\n";
        let mut t = parse_thing("T", src);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        assert!(!codes(&t.findings).contains(&RUNNING_SILENT));
    }

    #[test]
    fn finding_checked_not_moved() {
        let t = parse_thing("Messy-Thing", MESSY);
        assert!(codes(&t.findings).contains(&CHECKED_NOT_MOVED));
    }

    #[test]
    fn finding_no_next() {
        let mut t = parse_thing("Messy-Thing", MESSY);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        assert!(codes(&t.findings).contains(&NO_NEXT));
    }

    #[test]
    fn finding_dup_id() {
        let t = parse_thing("Messy-Thing", MESSY);
        assert!(codes(&t.findings).contains(&DUP_ID));
    }

    #[test]
    fn finding_orphan_draft_and_unowned_prompt_and_done_not_archived() {
        let snap = snapshot(&fixture_root(), "2026-09-23");
        let global = codes(&snap.global_findings);
        assert!(global.contains(&ORPHAN_DRAFT), "{global:?}");
        assert!(global.contains(&UNOWNED_PROMPT), "{global:?}");
        assert!(global.contains(&DONE_NOT_ARCHIVED), "{global:?}");
    }

    #[test]
    fn finding_orphan_draft_spares_an_archived_draft() {
        let snap = snapshot(&fixture_root(), "2026-09-23");
        assert!(
            !snap
                .global_findings
                .iter()
                .any(|f| f.message.contains("drafts/archive/")),
            "nothing under an archive/ subdirectory is scanned"
        );
    }

    #[test]
    fn finding_too_many() {
        // Twenty-one active notes in one temporary vault: the only finding that
        // is about the board rather than about any note on it.
        let root = std::env::temp_dir().join(format!("things-many-{}", std::process::id()));
        let dir = root.join(THINGS_DIR);
        std::fs::create_dir_all(&dir).unwrap();
        for n in 0..21 {
            std::fs::write(
                dir.join(format!("T{n:02}.md")),
                "---\ngroup: tag1\nstate: active\nupdated: 2026-09-23\n---\n# T\n\n## Queue\n- [ ] **A1** In.\n",
            )
            .unwrap();
        }
        let snap = snapshot(&root, "2026-09-23");
        assert!(codes(&snap.global_findings).contains(&TOO_MANY));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn every_finding_code_is_raised_by_the_fixtures() {
        let snap = snapshot(&fixture_root(), "2026-09-23");
        let mut raised: Vec<&str> = snap
            .things
            .iter()
            .flat_map(|t| t.findings.iter().map(|f| f.code))
            .chain(snap.global_findings.iter().map(|f| f.code))
            .collect();
        // TOO-MANY has its own test: it needs twenty-one notes, and putting
        // twenty-one fixtures on disk to raise it would make every other
        // assertion here read against a board nobody would keep.
        raised.push(TOO_MANY);
        for code in FINDING_CODES {
            assert!(raised.contains(&code), "no fixture raises {code}");
        }
    }

    // ---- The snapshot ------------------------------------------------------

    #[test]
    fn a_clean_note_has_no_findings() {
        let mut t = parse_thing("Clean-Thing", CLEAN);
        audit_thing(&mut t, &fixture_root(), "2026-09-23");
        assert_eq!(t.findings, Vec::new(), "the clean fixture must stay clean");
    }

    #[test]
    fn sort_is_updated_descending_then_title_ascending() {
        let snap = snapshot(&fixture_root(), "2026-09-23");
        let order: Vec<(&str, &str)> = snap
            .things
            .iter()
            .map(|t| (t.updated.as_str(), t.title.as_str()))
            .collect();
        assert_eq!(
            order,
            vec![
                ("2026-09-23", "Alpha Thing"),
                ("2026-09-23", "Clean Thing"),
                ("2026-09-01", "Messy Thing"),
                ("2026-01-01", "Dormant Thing"),
                ("", "Broken Thing"),
            ],
            "newest first, then title; an unparseable date sorts last"
        );
    }

    #[test]
    fn a_done_note_is_off_the_board_but_not_out_of_the_audit() {
        let snap = snapshot(&fixture_root(), "2026-09-23");
        assert!(!snap.things.iter().any(|t| t.state == "done"));
        assert!(snap
            .global_findings
            .iter()
            .any(|f| f.code == DONE_NOT_ARCHIVED));
    }

    #[test]
    fn a_missing_things_directory_is_an_empty_snapshot() {
        let snap = snapshot(Path::new("/nonexistent/notes/root"), "2026-09-23");
        assert_eq!(snap.things, Vec::new());
        assert_eq!(snap.counts, SnapshotCounts::default());
    }

    #[test]
    fn the_wire_shape_is_the_contract() {
        let snap = snapshot(&fixture_root(), "2026-09-23");
        let value = serde_json::to_value(&snap).unwrap();
        let top: Vec<&str> = value
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.as_str())
            .collect();
        assert_eq!(top, vec!["counts", "global_findings", "things"]);
        assert_eq!(
            value["counts"]
                .as_object()
                .unwrap()
                .keys()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            vec!["active", "dormant", "waiting"]
        );

        let clean = value["things"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["slug"] == "Clean-Thing")
            .unwrap();
        assert_eq!(
            clean
                .as_object()
                .unwrap()
                .keys()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            vec![
                "counts", "findings", "group", "next", "now", "repos", "slug", "state", "title",
                "updated", "waiting",
            ]
        );
        assert_eq!(
            clean["waiting"]
                .as_object()
                .unwrap()
                .keys()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            vec!["jeremy", "text"]
        );
        assert_eq!(
            clean["next"]
                .as_object()
                .unwrap()
                .keys()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            vec!["id", "link", "text", "waits_on"]
        );
        assert_eq!(
            clean["counts"]
                .as_object()
                .unwrap()
                .keys()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            vec!["done", "later", "queue", "running"]
        );

        // `waiting` and `next` are null when absent, never missing.
        let broken = value["things"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["slug"] == "Broken-Thing")
            .unwrap();
        assert!(broken["waiting"].is_null());
        assert!(broken["next"].is_null());

        // A note finding carries a line; a global one does not.
        let messy = value["things"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["slug"] == "Messy-Thing")
            .unwrap();
        assert!(messy["findings"][0]["line"].is_number());
        assert_eq!(
            value["global_findings"][0]
                .as_object()
                .unwrap()
                .keys()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            vec!["code", "message"]
        );
    }

    // ---- The report --------------------------------------------------------

    #[test]
    fn report_is_byte_stable_for_a_fixed_date() {
        let snap = snapshot(&fixture_root(), "2026-09-23");
        let a = render_report(&snap, "2026-09-23");
        let b = render_report(&snapshot(&fixture_root(), "2026-09-23"), "2026-09-23");
        assert_eq!(a, b);
        assert!(
            a.starts_with("# Things audit 2026-09-23\n\nActive 3, waiting 1, dormant 0, findings ")
        );
        assert!(a.contains(" · Messy Thing · "));
        assert!(a.contains("(Things/Messy-Thing.md)"));
    }

    #[test]
    fn report_writes_no_dash_of_any_kind() {
        let a = render_report(&snapshot(&fixture_root(), "2026-09-23"), "2026-09-23");
        for line in a.lines() {
            let prose = line.strip_prefix("- ").unwrap_or(line);
            assert!(!prose.contains('—'), "em dash in {line}");
            assert!(!prose.contains('–'), "en dash in {line}");
            assert!(!prose.contains("--"), "double hyphen in {line}");
        }
    }

    #[test]
    fn report_says_so_when_there_is_nothing_to_say() {
        let snap = ThingsSnapshot {
            counts: SnapshotCounts {
                active: 3,
                waiting: 0,
                dormant: 0,
            },
            ..ThingsSnapshot::default()
        };
        assert_eq!(
            render_report(&snap, "2026-09-23"),
            "# Things audit 2026-09-23\n\nActive 3, waiting 0, dormant 0, findings 0.\n\nNo findings.\n"
        );
    }

    // ---- The writer --------------------------------------------------------

    /// A temporary vault repo whose `vault/Things/` is a copy of the fixtures.
    fn temp_vault(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "things-writer-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::remove_dir_all(&root).ok();
        let notes = root.join(crate::config::VAULT_SUBDIR);
        std::fs::create_dir_all(notes.join(THINGS_DIR)).unwrap();
        std::fs::write(notes.join(THINGS_DIR).join("Clean-Thing.md"), CLEAN).unwrap();
        root
    }

    fn cfg_at(root: &Path) -> Config {
        Config {
            vault: root.to_string_lossy().into_owned(),
            ..crate::testutil::test_config()
        }
    }

    /// Unix millis for a local time in a fixed-offset zone.
    fn at(zone: SchedulerZone, y: i32, m: u32, d: u32, hh: u32, mm: u32) -> u64 {
        zone.with_ymd_and_hms(y, m, d, hh, mm, 0)
            .single()
            .unwrap()
            .timestamp_millis() as u64
    }

    #[test]
    fn writer_creates_the_day_file_once_and_never_overwrites_it() {
        let root = temp_vault("once");
        let cfg = cfg_at(&root);
        let zone = SchedulerZone::hours_east(2);
        let clock = SchedulerClock::frozen(zone, at(zone, 2026, 9, 23, 3, 21));

        let first = run_things_audit(&cfg, &clock);
        let AuditWrite::Wrote(path) = first else {
            panic!("expected a write, got {first:?}");
        };
        assert!(path.ends_with("Inbox/2026-09-23-things-audit.md"));
        let written = std::fs::read_to_string(&path).unwrap();
        assert!(written.starts_with("# Things audit 2026-09-23\n"));

        // The idempotency guarantee: a second pass on the same day leaves the
        // file it found exactly as it was.
        std::fs::write(&path, "hand edited\n").unwrap();
        assert_eq!(
            run_things_audit(&cfg, &clock),
            AuditWrite::AlreadyThere(path.clone())
        );
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "hand edited\n");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn writer_waits_until_the_hour_in_the_schedulers_zone() {
        let root = temp_vault("early");
        let cfg = cfg_at(&root);
        let zone = SchedulerZone::hours_east(2);
        assert_eq!(
            run_things_audit(
                &cfg,
                &SchedulerClock::frozen(zone, at(zone, 2026, 9, 23, 3, 19))
            ),
            AuditWrite::NotYet
        );
        // The same instant, read by a scheduler two hours further east, is 05:19 there:
        // the hour is the scheduler's, never the fixture's.
        let east = SchedulerZone::hours_east(4);
        assert!(matches!(
            run_things_audit(
                &cfg,
                &SchedulerClock::frozen(east, at(zone, 2026, 9, 23, 3, 19))
            ),
            AuditWrite::Wrote(_)
        ));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn writer_skips_a_vault_with_no_things_directory() {
        let root = std::env::temp_dir().join(format!("things-nodir-{}", std::process::id()));
        std::fs::create_dir_all(root.join(crate::config::VAULT_SUBDIR)).unwrap();
        let zone = SchedulerZone::hours_east(2);
        assert_eq!(
            run_things_audit(
                &cfg_at(&root),
                &SchedulerClock::frozen(zone, at(zone, 2026, 9, 23, 4, 0))
            ),
            AuditWrite::NoThingsDir
        );
        std::fs::remove_dir_all(&root).ok();
    }

    // ---- The slug guard ----------------------------------------------------

    #[test]
    fn slug_guard_rejects_a_separator_a_traversal_and_a_dot_file() {
        assert!(is_safe_slug("Clean-Thing"));
        assert!(!is_safe_slug(""));
        assert!(!is_safe_slug("a/b"));
        assert!(!is_safe_slug("a\\b"));
        assert!(!is_safe_slug(".."));
        assert!(!is_safe_slug("../Today"));
        assert!(!is_safe_slug(".hidden"));
    }
}
