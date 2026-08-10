//! `GET /jesse/today` — a structured snapshot of the vault's `Today.md`, the
//! file the morning routine rewrites in full every day, plus the parser and the
//! item identity contract every other day-file module is built on.
//!
//! **This module reads; it does not write.** The mutations — checking a box,
//! moving an item, marking a glanceable seen — live in [`crate::todaywrite`],
//! and the durability machinery behind them in [`crate::todayjournal`]. The one
//! thing here that writes at all is [`GlanceStore::record`], which touches the
//! state dir and never the vault. Pushing a change over SSE remains follow-on
//! work.
//!
//! Same posture as the other snapshot endpoint, [`jesse_diet`]: bearer auth, the
//! shared rate limiter, ids-and-values-only JSON, and a **pure function of file
//! state** — no clock, no request, no server state enters the parse. On top of
//! that it carries a strong ETag (the shape [`jesse_conversations`] already
//! uses), because the phone polls this screen and an unchanged file should cost
//! one `304` rather than a re-render of the whole day.
//!
//! ## The parser is line-oriented, tolerant and NON-DESTRUCTIVE
//!
//! It never re-serializes the document. Every node keeps the byte range it came
//! from ([`SourceRange`]), so the write path splices a line — check a box,
//! append a sub-line — by replacing exactly those bytes and leaving every other
//! byte of the file untouched. That matters because the file is hand-edited and
//! agent-edited between rebuilds: a round-trip through a markdown serializer
//! would reflow prose, renumber lists and normalize whitespace that a human
//! chose. These ranges are what make [`crate::todaywrite`] possible without a
//! reformat, and a unit test there asserts a check flips three bytes and no
//! others.
//!
//! Tolerance is the other half: the file is prose written by an agent, so the
//! parser has no error path. A missing H1, an unparseable date, a half-written
//! checkbox, an unknown section name — each degrades to a null, a prose line or
//! the default `tasks` kind. The endpoint's only failure modes are auth and the
//! rate limit; a missing file is an empty snapshot with `missing: true`, so the
//! client renders an empty state rather than an error.
//!
//! ## Section kinds are a RENDERING HINT, not a parse mode
//!
//! `kind` (`schedule` / `briefing` / `tasks`) tells the client how to lay a
//! section out. It never changes what is extracted: task lines are parsed
//! wherever they appear, including inside `Health` and the other briefing
//! sections, which regularly carry one. The only thing `kind` gates is
//! glanceable report rows, which are a briefing-section idea by construction.

use crate::*;

/// The vault-relative name of the day file, under `config::VAULT_SUBDIR`. The
/// file is undated by design — it is the CURRENT day's state and is overwritten
/// each morning — so this endpoint takes no `date` parameter (unlike
/// `/jesse/diet`, which has an archive to page through).
pub const TODAY_FILE: &str = "Today.md";

/// The half-open byte range `[start, end)` of the source the node was parsed
/// from, covering whole lines including their trailing newline. `src[start..end]`
/// is exactly that node's source text, so a write path can splice it without
/// touching a byte of anything else.
#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct SourceRange {
    pub start: usize,
    pub end: usize,
}

/// One link found in a node: a `[[wiki-style]]` vault target (`wiki`) or an
/// http(s) URL, whether inline-markdown or bare (`url`).
#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct TodayLink {
    pub target: String,
    pub kind: &'static str,
}

/// The app's completion sub-line, lifted out of an item's continuation block:
/// when the phone checked it off and what it recorded. Both halves are optional
/// — the sub-line is written by another program and is parsed leniently.
#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct AppCompleted {
    pub at: Option<String>,
    pub evidence: Option<String>,
}

/// One task line plus its continuation block.
///
/// `text` is the raw markdown (the line and every continuation, joined by `\n`)
/// — the client renders that, not a reconstruction. `lead` is the one-line
/// display string: the bold segment when the line has one, otherwise the first
/// sentence, with markdown stripped either way.
#[derive(serde::Serialize, PartialEq, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TodayItem {
    pub id: String,
    pub checked: bool,
    pub lead: String,
    pub text: String,
    pub links: Vec<TodayLink>,
    pub added_date: Option<String>,
    pub updated_date: Option<String>,
    pub app_completed: Option<AppCompleted>,
    pub section_name: String,
    /// The item's project slug — one of [`PROJECT_SLUGS`]. A **slug only**: the
    /// colour, label and ordering a client draws from it are a client concern,
    /// and putting any of them on the wire would freeze a rendering decision
    /// into the API. See [`derive_project`] for how it is resolved.
    pub project: &'static str,
    pub range: SourceRange,
}

/// A glanceable row: a briefing-section line that carries a link and is worth
/// surfacing on its own (a bold lead-in, or an `FYI:` line). `seen` / `seenMs`
/// come from the glance store when one exists; with no store every row is
/// unseen, which is the correct cold-start answer.
#[derive(serde::Serialize, PartialEq, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TodayReport {
    pub id: String,
    pub title: String,
    pub links: Vec<TodayLink>,
    pub kind: &'static str,
    pub section_name: String,
    pub seen: bool,
    pub seen_ms: u64,
    pub range: SourceRange,
}

/// A body-text line of a section: every non-task line that did not become a
/// report row, carried raw so the client can render it. Deliberately a superset
/// of "non-bold prose" — a bold line with no link is not glanceable, and
/// dropping it would silently lose content.
#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct TodayProse {
    pub text: String,
    pub range: SourceRange,
}

/// One `## ` section. `kind` is a rendering hint only (see the module docs).
#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct TodaySection {
    pub name: String,
    pub kind: &'static str,
    pub prose: Vec<TodayProse>,
    pub items: Vec<TodayItem>,
    pub reports: Vec<TodayReport>,
    pub range: SourceRange,
}

#[derive(serde::Serialize, PartialEq, Debug, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct TodayCounts {
    pub open: usize,
    pub done: usize,
    pub reports_unseen: usize,
}

/// The whole snapshot. `missing` is the only field that is not a function of the
/// document: it says the day file was not there at all.
#[derive(serde::Serialize, PartialEq, Debug, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct TodaySnapshot {
    pub title: Option<String>,
    pub date: Option<String>,
    pub narrative: Option<String>,
    pub lead_items: Vec<TodayItem>,
    pub sections: Vec<TodaySection>,
    pub counts: TodayCounts,
    pub missing: bool,
}

// ---- Item identity ---------------------------------------------------------

/// The maximum length, in characters, of a normalized lead. Long enough to
/// separate two real items, short enough that an editor's tail-end rewording
/// (a clause appended to a long line) does not mint a new id.
const NORMALIZED_LEAD_CHARS: usize = 120;

/// **The item identity contract.** `id` = the first 12 hex characters of
/// `sha256(section_name + "|" + normalized_lead + "|" + added_date)`, where
/// `added_date` is the `YYYY-MM-DD` from the `(Added …)` trailer or the empty
/// string when there is none.
///
/// **Why a content hash and not a sequence number.** The day file is
/// **overwritten in full every morning**. Nothing in it is stable across that
/// rebuild except the words: line numbers move, ordering changes, whole sections
/// come and go. An item that is re-emitted with the same lead and the same Added
/// date is, by intent, the same item — so it must keep the same id, or every
/// piece of client-side state keyed on that id (seen/unseen, a local check, a
/// snooze) would be orphaned daily and the screen would forget itself overnight.
///
/// The three inputs are exactly the parts that identify the item and nothing
/// that merely describes its current state: the `updated` trailer, the body
/// after the lead, the continuation block and the checkbox are all deliberately
/// **excluded**, so an item can be re-worded, re-dated (`updated`), extended or
/// ticked without changing identity. The `(Added …)` trailer is stripped from
/// the text before the lead is taken, so it cannot leak in through the lead
/// either.
///
/// Truncation to [`NORMALIZED_LEAD_CHARS`] and the section name are the two
/// deliberate collision risks: two items with the same first 120 characters in
/// the same section ARE one identity as far as this contract is concerned, and
/// [`parse_today`] disambiguates them positionally with `-2` / `-3` suffixes in
/// file order.
pub fn today_id(section: &str, lead: &str, added_date: &str) -> String {
    let material = format!("{section}|{}|{added_date}", normalize_lead(lead));
    let digest = ring::digest::digest(&ring::digest::SHA256, material.as_bytes());
    let mut hex = String::with_capacity(12);
    for b in digest.as_ref().iter().take(6) {
        hex.push_str(&format!("{b:02x}"));
    }
    hex
}

/// The lead as the id contract sees it: markdown emphasis and link syntax
/// stripped, lowercased, whitespace collapsed, truncated to
/// [`NORMALIZED_LEAD_CHARS`] characters (characters, not bytes — the vault is
/// full of em-dashes and accents).
///
/// Underscores are left alone on purpose: `_emphasis_` is not a spelling this
/// vault uses, but `snake_case` identifiers are all over it, and stripping `_`
/// would mangle them into a different id every time one appeared.
pub fn normalize_lead(lead: &str) -> String {
    strip_markdown(lead)
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(NORMALIZED_LEAD_CHARS)
        .collect()
}

/// Hands out ids in file order, suffixing a repeat with `-2`, `-3`, … so one
/// parse never emits the same id twice however duplicated the source is.
#[derive(Default)]
struct IdRegistry {
    seen: HashMap<String, usize>,
}

impl IdRegistry {
    fn assign(&mut self, base: String) -> String {
        let n = self.seen.entry(base.clone()).or_insert(0);
        *n += 1;
        if *n == 1 {
            base
        } else {
            format!("{base}-{n}")
        }
    }
}

// ---- The project slug ------------------------------------------------------

/// The slug for an item whose topic home could not be resolved. **Not an error
/// and not a guess** — it is the honest answer for an item that declares no
/// lineage, and on the live day file it is a large minority of items (the
/// morning routine groups by section rather than stamping each item). A client
/// renders it as "no project", never as a sixth project.
pub const PROJECT_UNFILED: &str = "unfiled";

/// The frozen wire set, in Dashboard order. Anything outside it is a bug, and
/// the app's decoder is entitled to treat it as closed.
pub const PROJECT_SLUGS: [&str; 6] = [
    "tag1",
    "personal",
    "network",
    "via-con-me",
    "perseido",
    PROJECT_UNFILED,
];

/// The five Dashboard topic homes: `(file stem under `Dashboard/`, wire slug,
/// the lowercased needle that identifies the topic in a section heading)`.
///
/// The stem is also the display name — `Dashboard/Via-Con-Me.md` — so one table
/// drives the link mapping, the rollup loader and the heading tiebreak.
const TOPICS: [(&str, &str, &str); 5] = [
    ("Tag1", "tag1", "tag1"),
    ("Personal", "personal", "personal"),
    ("Network", "network", "network"),
    ("Via-Con-Me", "via-con-me", "via con me"),
    ("Perseido", "perseido", "perseido"),
];

/// A wiki target reduced to a comparable vault-relative note key: heading
/// dropped, the vault-name prefix stripped, the `.md` suffix dropped, lowercased.
///
/// **`todo-list/` is a NAME, not a directory.** Every wiki link in the vault is
/// written `[[todo-list/…]]` because that is the Obsidian vault's name and QMD's
/// collection name; the notes actually live under [`crate::config::VAULT_SUBDIR`]
/// (`vault/`) since the 2026-08-06 relocation. Both spellings are accepted here
/// for the same reason [`crate::citations::normalize_candidates`] accepts both —
/// do not "clean up" that tolerance.
///
/// The alias half of `[[target|alias]]` is already gone: [`extract_links`] keeps
/// only the target. The heading half of `[[target#heading]]` is not, and is
/// dropped here — a link to a section of a note is a link to that note.
pub fn note_key(target: &str) -> String {
    let rel = vault_relative(target);
    rel.strip_suffix(".md").unwrap_or(&rel).to_lowercase()
}

/// A wiki target as a vault-relative path, **case preserved**: heading dropped,
/// leading slashes and the vault-name prefix stripped, `.md` left alone.
///
/// [`note_key`] lowercases on top of this for comparison; a PATH must not be
/// lowercased, because the notes root can sit on a case-sensitive filesystem
/// where `projects/` and `Projects/` are different directories. The two callers
/// share this so a future prefix (another rename) is one edit, not two.
///
/// This normalizes; it does NOT make a path safe. Confinement is
/// [`crate::todaydetail::resolve_under_root`]'s job, and it does not trust this.
pub fn vault_relative(target: &str) -> String {
    let t = target.split('#').next().unwrap_or(target).trim();
    let t = t.trim_start_matches('/');
    let t = t
        .strip_prefix("todo-list/")
        .or_else(|| t.strip_prefix(&format!("{}/", crate::config::VAULT_SUBDIR)))
        .unwrap_or(t);
    t.trim_matches('/').to_string()
}

/// The slug for a key that IS a Dashboard topic home (`Dashboard/Tag1`).
fn topic_home_slug(key: &str) -> Option<&'static str> {
    let stem = key.strip_prefix("dashboard/")?;
    TOPICS
        .iter()
        .find(|(name, _, _)| stem.eq_ignore_ascii_case(name))
        .map(|(_, slug, _)| *slug)
}

/// Which topic files claim which notes, read from the five `Dashboard/<Topic>.md`
/// files. This is the "rolls up to one topic" half of the derivation: an item
/// that links a project note rather than a topic home inherits the topic whose
/// Dashboard page links that note.
///
/// **It is not single-valued in practice.** Seven notes on the live vault are
/// linked from more than one topic page — including `Projects/Tag1/HR-Finance`,
/// the most-linked note in the day file, which both `Tag1` and `Personal` claim.
/// A multi-valued rollup is resolved by the section heading or not at all; see
/// [`derive_project`].
///
/// An absent or unreadable topic file contributes nothing rather than erroring,
/// the same degradation as every other store here: a Dashboard mid-edit costs
/// some items their slug for one request, never a failed day screen.
#[derive(Default)]
pub struct ProjectRollup {
    map: HashMap<String, Vec<&'static str>>,
}

impl ProjectRollup {
    /// Read the five topic pages under the configured vault root.
    ///
    /// The paths are composed from a constant table and the configured root —
    /// **no part of them comes from a request** — so this reads a fixed set of
    /// five files and is not a path surface. The link-keyed reader that IS one
    /// lives in [`crate::todaydetail`], behind the sandbox.
    pub fn load(cfg: &Config) -> Self {
        let dashboard = notes_root(cfg).join("Dashboard");
        let mut map: HashMap<String, Vec<&'static str>> = HashMap::new();
        for (stem, slug, _) in TOPICS {
            let Ok(src) = std::fs::read_to_string(dashboard.join(format!("{stem}.md"))) else {
                continue;
            };
            for link in extract_links(&src) {
                if link.kind != "wiki" {
                    continue;
                }
                let key = note_key(&link.target);
                if key.is_empty() {
                    continue;
                }
                push_unique(map.entry(key).or_default(), slug);
            }
        }
        Self { map }
    }

    /// Build a rollup directly from `(note key, topic slug)` pairs. Tests only —
    /// it keeps the derivation testable without a vault on disk.
    #[cfg(test)]
    pub fn from_pairs(pairs: &[(&str, &str)]) -> Self {
        let mut map: HashMap<String, Vec<&'static str>> = HashMap::new();
        for (key, slug) in pairs {
            let slug = PROJECT_SLUGS
                .iter()
                .find(|s| *s == slug)
                .expect("a test rollup may only name a frozen slug");
            push_unique(map.entry(note_key(key)).or_default(), slug);
        }
        Self { map }
    }

    fn topics_for(&self, key: &str) -> &[&'static str] {
        self.map.get(key).map_or(&[], |v| v.as_slice())
    }

    /// Re-derive every item's project with this rollup in hand.
    ///
    /// The second pass exists because [`parse_today`] is a pure function of the
    /// day file's own bytes and the rollup lives in five OTHER files. Parsing
    /// resolves what the day file alone can settle (a direct topic-home link);
    /// this fills in the rest. Both passes run the same [`derive_project`], so
    /// there is one derivation, not two that could drift.
    pub fn stamp_into(&self, snapshot: &mut TodaySnapshot) {
        if self.map.is_empty() {
            return;
        }
        for item in snapshot.lead_items.iter_mut().chain(
            snapshot
                .sections
                .iter_mut()
                .flat_map(|s| s.items.iter_mut()),
        ) {
            item.project = derive_project(&item.links, &item.section_name, self);
        }
    }
}

fn push_unique(out: &mut Vec<&'static str>, slug: &'static str) {
    if !out.contains(&slug) {
        out.push(slug);
    }
}

/// **The project derivation.** A pure function of an item's links, its section
/// heading and the rollup table — no clock, no request, no server state.
///
/// In order:
///
/// 1. A direct `[[…/Dashboard/<Topic>]]` link is the item's declared home and
///    wins outright.
/// 2. Otherwise every topic page that claims one of the item's linked notes is a
///    candidate.
/// 3. Exactly one candidate → that slug.
/// 4. More than one → the section heading breaks the tie, but **only among
///    candidates the item's own links already declared**. A heading never files
///    an item that declared nothing, and a heading that names two candidates (or
///    none) leaves the item unfiled. This is the narrow use the heading is
///    trustworthy for: it disambiguates a declared lineage, it does not invent one.
/// 5. No candidates → [`PROJECT_UNFILED`].
///
/// Step 5 is the common case for a large minority of live items and that is
/// deliberate: the durable fix is for the morning routine to stamp each item
/// with its topic, not for the bridge to guess from prose.
pub fn derive_project(
    links: &[TodayLink],
    section_name: &str,
    rollup: &ProjectRollup,
) -> &'static str {
    let wiki = || links.iter().filter(|l| l.kind == "wiki");
    let mut candidates: Vec<&'static str> = Vec::new();
    for link in wiki() {
        if let Some(slug) = topic_home_slug(&note_key(&link.target)) {
            push_unique(&mut candidates, slug);
        }
    }
    if candidates.is_empty() {
        for link in wiki() {
            for slug in rollup.topics_for(&note_key(&link.target)) {
                push_unique(&mut candidates, slug);
            }
        }
    }
    match candidates.as_slice() {
        [] => PROJECT_UNFILED,
        [only] => only,
        many => section_tiebreak(section_name, many),
    }
}

/// The topic a section heading names, when it names exactly one of `candidates`.
/// Hyphens read as spaces so `Via-Con-Me` and `Via Con Me` are one heading.
fn section_tiebreak(section_name: &str, candidates: &[&'static str]) -> &'static str {
    let hay = section_name.to_lowercase().replace('-', " ");
    let mut hit: Option<&'static str> = None;
    for slug in candidates {
        let named = TOPICS
            .iter()
            .any(|(_, s, needle)| s == slug && hay.contains(needle));
        if named {
            if hit.is_some() {
                // The heading names two of the candidates; it settles nothing.
                return PROJECT_UNFILED;
            }
            hit = Some(slug);
        }
    }
    hit.unwrap_or(PROJECT_UNFILED)
}

// ---- Line scanning ---------------------------------------------------------

/// One source line: its text (without the line terminator) and the byte range it
/// occupies (with it). Lines tile the source exactly — `lines[i].end ==
/// lines[i + 1].start` — which is what lets section ranges tile the document.
struct SrcLine<'a> {
    text: &'a str,
    start: usize,
    end: usize,
}

fn scan_lines(src: &str) -> Vec<SrcLine<'_>> {
    let mut out = Vec::new();
    let mut start = 0usize;
    for chunk in src.split_inclusive('\n') {
        let end = start + chunk.len();
        out.push(SrcLine {
            text: chunk.trim_end_matches('\n').trim_end_matches('\r'),
            start,
            end,
        });
        start = end;
    }
    out
}

/// The range spanning a run of lines.
fn span(lines: &[SrcLine]) -> SourceRange {
    match (lines.first(), lines.last()) {
        (Some(f), Some(l)) => SourceRange {
            start: f.start,
            end: l.end,
        },
        _ => SourceRange { start: 0, end: 0 },
    }
}

/// A task line at column zero: `* [ ]`, `- [ ]`, `* [x]`, `- [x]` (either case).
/// Returns `(checked, body)`. An INDENTED checkbox is deliberately not a task
/// start — indented lines belong to the item above (see [`is_continuation`]).
fn task_line(text: &str) -> Option<(bool, &str)> {
    let rest = text
        .strip_prefix("* ")
        .or_else(|| text.strip_prefix("- "))?
        .strip_prefix('[')?;
    let c = rest.chars().next()?;
    let checked = match c {
        ' ' => false,
        'x' | 'X' => true,
        _ => return None,
    };
    Some((checked, rest[c.len_utf8()..].strip_prefix(']')?.trim()))
}

/// A continuation line: indented (tab or spaces) and not blank. A blank line
/// ends the continuation block.
fn is_continuation(text: &str) -> bool {
    (text.starts_with(' ') || text.starts_with('\t')) && !text.trim().is_empty()
}

// ---- Text shaping ----------------------------------------------------------

/// Strip markdown decoration, keeping the words: `**bold**`, `*emphasis*`,
/// `` `code` `` and `~~strike~~` markers are removed, `[[target|alias]]` becomes
/// its alias (or its target), and `[text](url)` becomes its text.
fn strip_markdown(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0usize;
    while i < b.len() {
        let rest = &s[i..];
        if let Some(inner_end) = rest.strip_prefix("[[").and_then(|r| r.find("]]")) {
            let inner = &rest[2..2 + inner_end];
            out.push_str(inner.rsplit('|').next().unwrap_or(inner).trim());
            i += 2 + inner_end + 2;
        } else if rest.starts_with('[') && !rest.starts_with("[[") {
            // `[text](url)` — keep the text, drop the target. Anything else that
            // starts with `[` is ordinary punctuation.
            match rest
                .find("](")
                .and_then(|t| rest[t + 2..].find(')').map(|c| (t, t + 2 + c + 1)))
            {
                Some((text_end, after)) => {
                    out.push_str(&rest[1..text_end]);
                    i += after;
                }
                None => {
                    out.push('[');
                    i += 1;
                }
            }
        } else if rest.starts_with("**") || rest.starts_with("~~") {
            i += 2;
        } else if rest.starts_with('*') || rest.starts_with('`') {
            i += 1;
        } else {
            let ch = rest.chars().next().unwrap_or('\u{0}');
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

/// The inner text of the first `**bold**` span, if the line has a non-empty one.
fn bold_segment(s: &str) -> Option<&str> {
    let open = s.find("**")? + 2;
    let rest = &s[open..];
    let close = rest.find("**")?;
    let inner = &rest[..close];
    (!inner.trim().is_empty()).then_some(inner)
}

/// The first sentence: up to and including the first `.`, `!` or `?` that is
/// followed by whitespace or the end of the text — so decimals, version numbers
/// and `example.invalid/x` do not split a lead in half.
fn first_sentence(s: &str) -> &str {
    let b = s.as_bytes();
    for (i, c) in s.char_indices() {
        if matches!(c, '.' | '!' | '?') {
            let next = b.get(i + 1);
            if next.is_none() || next.is_some_and(|n| n.is_ascii_whitespace()) {
                return s[..=i].trim();
            }
        }
    }
    s.trim()
}

/// Drop the trailing `(Added …)` / `(updated …)` bookkeeping so it never reaches
/// a lead — and therefore never reaches an id. Only a trailer at the very end of
/// the text is removed; a parenthetical mid-sentence is content.
fn strip_trailers(body: &str) -> &str {
    let mut s = body.trim_end();
    while let Some(open) = s.rfind('(') {
        if !s.ends_with(')') {
            break;
        }
        let inner = s[open + 1..s.len() - 1].trim_start();
        let bookkeeping = inner.starts_with("Added ")
            || inner.starts_with("updated ")
            || inner.starts_with("Updated ");
        if !bookkeeping {
            break;
        }
        s = s[..open].trim_end();
    }
    s
}

/// The display lead for a line: its bold segment when it has one, else its first
/// sentence — markdown stripped either way, trailers removed first.
fn lead_of(body: &str) -> String {
    let body = strip_trailers(body);
    let raw = bold_segment(body).unwrap_or_else(|| first_sentence(body));
    strip_markdown(raw).trim().to_string()
}

/// Every link in the text, in source order, de-duplicated on the target.
fn extract_links(s: &str) -> Vec<TodayLink> {
    let mut out: Vec<TodayLink> = Vec::new();
    let mut push = |target: &str, kind: &'static str| {
        let target = target.trim();
        if !target.is_empty() && !out.iter().any(|l| l.target == target) {
            out.push(TodayLink {
                target: target.to_string(),
                kind,
            });
        }
    };
    let mut i = 0usize;
    while i < s.len() {
        let rest = &s[i..];
        if let Some(end) = rest.strip_prefix("[[").and_then(|r| r.find("]]")) {
            // `[[target|alias]]` / `[[target#heading]]` — the target is what a
            // client resolves, so the alias is dropped and the heading kept.
            let inner = &rest[2..2 + end];
            push(inner.split('|').next().unwrap_or(inner), "wiki");
            i += 2 + end + 2;
        } else if let Some(close) = rest.strip_prefix("](").and_then(|r| r.find(')')) {
            push(&rest[2..2 + close], "url");
            i += 2 + close + 1;
        } else if rest.starts_with("http://") || rest.starts_with("https://") {
            let end = rest
                .find(|c: char| c.is_whitespace() || matches!(c, ')' | ']' | '>' | '"' | '\''))
                .unwrap_or(rest.len());
            // Sentence punctuation clings to a bare URL; it is not part of it.
            push(rest[..end].trim_end_matches(['.', ',', ';', ':']), "url");
            i += end;
        } else {
            i += s[i..].chars().next().map_or(1, char::len_utf8);
        }
    }
    out
}

/// A `YYYY-MM-DD` immediately after `key`, at the first occurrence that actually
/// parses as a date.
fn trailer_date(hay: &str, key: &str) -> Option<String> {
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

/// The app's `*(app-completed <at> — <evidence>)*` sub-line, parsed leniently: a
/// leading timestamp-looking token becomes `at` and the remainder `evidence`;
/// anything that does not look like a timestamp is all evidence.
///
/// TWO timestamp spellings are recognized, and that is deliberate rather than
/// sloppy. The bridge writes one frozen shape — `YYYY-MM-DD HH:MM:`, a SPACE
/// between the date and the clock (see [`app_completed_sub_line`]) — which a
/// naive split-on-whitespace would tear in half, leaving the clock stranded at
/// the front of the evidence. A single ISO instant (`2026-03-03T08:12:00Z`) is
/// the older spelling, still written by hand and by the agent. Both parse to the
/// same two fields.
fn app_completed(continuations: &[&str]) -> Option<AppCompleted> {
    let line = continuations.iter().find(|l| l.contains("app-completed"))?;
    let after = line.split_once("app-completed")?.1;
    let body = after
        .trim()
        .trim_end_matches('*')
        .trim_end_matches(')')
        .trim();
    let (head, tail) = body.split_once(char::is_whitespace).unwrap_or((body, ""));
    let timestamp = head.starts_with(|c: char| c.is_ascii_digit());
    // `YYYY-MM-DD HH:MM:` — the bridge's own grammar. Pull the clock into `at`
    // rather than leaving it at the head of the evidence.
    let (at, rest) = match tail.split_once(char::is_whitespace).unwrap_or((tail, "")) {
        (clock, remainder)
            if valid_iso_date(head).is_some() && is_clock(clock.trim_end_matches(':')) =>
        {
            (
                Some(format!("{head} {}", clock.trim_end_matches(':'))),
                remainder,
            )
        }
        _ => (timestamp.then(|| head.to_string()), tail),
    };
    let evidence = if at.is_some() { rest } else { body }
        .trim()
        .trim_start_matches(['—', '-', '–'])
        .trim();
    Some(AppCompleted {
        at,
        evidence: (!evidence.is_empty()).then(|| evidence.to_string()),
    })
}

/// An `HH:MM` clock, strictly.
fn is_clock(s: &str) -> bool {
    let Some((h, m)) = s.split_once(':') else {
        return false;
    };
    h.len() == 2
        && m.len() == 2
        && h.bytes().chain(m.bytes()).all(|c| c.is_ascii_digit())
        && h.parse::<u32>().is_ok_and(|h| h < 24)
        && m.parse::<u32>().is_ok_and(|m| m < 60)
}

// ---- Classification --------------------------------------------------------

/// The rendering hint for a section name. Everything unrecognized is `tasks`,
/// which is both the common case and the safe default: an unknown section still
/// renders, and its task lines are still parsed.
fn section_kind(name: &str) -> &'static str {
    let n = name.trim();
    if n.eq_ignore_ascii_case("Schedule") {
        "schedule"
    } else if n.eq_ignore_ascii_case("Health")
        || n.eq_ignore_ascii_case("Currency")
        || n.eq_ignore_ascii_case("Still open (aging)")
        || n.starts_with("Reminders")
    {
        "briefing"
    } else {
        "tasks"
    }
}

/// The glanceable's flavour, for the client's iconography. Section first (a
/// Currency row is a currency row whatever it says), then the title.
fn report_kind(section: &str, title: &str) -> &'static str {
    let lower = title.to_lowercase();
    if section.eq_ignore_ascii_case("Currency") {
        "currency"
    } else if section.eq_ignore_ascii_case("Health") {
        "health"
    } else if lower.contains("cheatsheet") {
        "cheatsheet"
    } else if lower.contains("philosophy") || title.contains("SEP") {
        // "SEP" matches case-sensitively: lowercased it would swallow
        // "September" and "separate".
        "philosophy"
    } else {
        "general"
    }
}

/// A prose line with its list marker removed, for the `FYI:` test.
fn unbulleted(text: &str) -> &str {
    let t = text.trim_start();
    t.strip_prefix("* ")
        .or_else(|| t.strip_prefix("- "))
        .unwrap_or(t)
}

// ---- The parse -------------------------------------------------------------

/// Parse the day file into its snapshot. Pure, total, and never destructive:
/// see the module docs for what that buys.
pub fn parse_today(src: &str) -> TodaySnapshot {
    let lines = scan_lines(src);
    let mut ids = IdRegistry::default();

    // The H1, when there is one, and where the body starts.
    let h1 = lines
        .iter()
        .position(|l| l.text.starts_with("# ") && !l.text.starts_with("##"));
    let title = h1.map(|i| lines[i].text[2..].trim().to_string());
    let date = title.as_deref().and_then(date_from_title);
    let body_start = h1.map_or(0, |i| i + 1);

    // Section boundaries: every `## ` heading from the body start onward. What
    // precedes the first one is the lead block.
    let heads: Vec<usize> = (body_start..lines.len())
        .filter(|&i| lines[i].text.starts_with("## "))
        .collect();
    let lead_end = heads.first().copied().unwrap_or(lines.len());

    // The lead block: its task lines are the standing items, everything else is
    // the day narrative. It has no name, so lead items carry an empty
    // `sectionName` and hash under the empty section.
    let (lead_items, lead_prose, _) =
        parse_block(&lines[body_start..lead_end], "", "tasks", &mut ids);
    let narrative = (!lead_prose.is_empty()).then(|| {
        lead_prose
            .iter()
            .map(|p| p.text.as_str())
            .collect::<Vec<_>>()
            .join("\n\n")
    });

    let mut sections = Vec::with_capacity(heads.len());
    for (n, &start) in heads.iter().enumerate() {
        let end = heads.get(n + 1).copied().unwrap_or(lines.len());
        let name = lines[start].text[3..].trim().to_string();
        let kind = section_kind(&name);
        let (items, prose, reports) = parse_block(&lines[start + 1..end], &name, kind, &mut ids);
        sections.push(TodaySection {
            name,
            kind,
            prose,
            items,
            reports,
            // From the heading through the last line before the next one, so the
            // sections tile the document with no gaps.
            range: span(&lines[start..end]),
        });
    }

    let mut snapshot = TodaySnapshot {
        title,
        date,
        narrative,
        lead_items,
        sections,
        counts: TodayCounts::default(),
        missing: false,
    };
    snapshot.recount();
    snapshot
}

/// Parse one block of lines (the lead block, or one section's body) into its
/// items, prose and report rows.
fn parse_block(
    lines: &[SrcLine],
    section_name: &str,
    kind: &str,
    ids: &mut IdRegistry,
) -> (Vec<TodayItem>, Vec<TodayProse>, Vec<TodayReport>) {
    let (mut items, mut prose, mut reports) = (Vec::new(), Vec::new(), Vec::new());
    let mut i = 0usize;
    while i < lines.len() {
        let line = &lines[i];
        if let Some((checked, body)) = task_line(line.text) {
            // The item owns every indented line that follows it.
            let start = i;
            i += 1;
            while i < lines.len() && is_continuation(lines[i].text) {
                i += 1;
            }
            items.push(build_item(
                &lines[start..i],
                checked,
                body,
                section_name,
                ids,
            ));
            continue;
        }
        i += 1;
        if line.text.trim().is_empty() {
            continue;
        }
        // Non-task, non-blank: a glanceable row in a briefing section, else prose.
        let links = extract_links(line.text);
        let glanceable = kind == "briefing"
            && !links.is_empty()
            && (bold_segment(line.text).is_some() || unbulleted(line.text).starts_with("FYI:"));
        if glanceable {
            let title = lead_of(unbulleted(line.text));
            let added = trailer_date(line.text, "(Added ").unwrap_or_default();
            reports.push(TodayReport {
                id: ids.assign(today_id(section_name, &title, &added)),
                kind: report_kind(section_name, &title),
                title,
                links,
                section_name: section_name.to_string(),
                seen: false,
                seen_ms: 0,
                range: SourceRange {
                    start: line.start,
                    end: line.end,
                },
            });
        } else {
            prose.push(TodayProse {
                text: line.text.to_string(),
                range: SourceRange {
                    start: line.start,
                    end: line.end,
                },
            });
        }
    }
    (items, prose, reports)
}

/// Build one item from its task line and continuation block.
fn build_item(
    lines: &[SrcLine],
    checked: bool,
    body: &str,
    section_name: &str,
    ids: &mut IdRegistry,
) -> TodayItem {
    let text = lines.iter().map(|l| l.text).collect::<Vec<_>>().join("\n");
    let continuations: Vec<&str> = lines.iter().skip(1).map(|l| l.text).collect();
    let lead = lead_of(body);
    let added_date = trailer_date(&text, "(Added ");
    let links = extract_links(&text);
    TodayItem {
        id: ids.assign(today_id(
            section_name,
            &lead,
            added_date.as_deref().unwrap_or(""),
        )),
        checked,
        lead,
        // What the day file alone can settle: a direct topic-home link. The
        // rollup half needs the Dashboard pages and is stamped on afterwards by
        // [`ProjectRollup::stamp_into`], keeping this parse a pure function of
        // its own source.
        project: derive_project(&links, section_name, &ProjectRollup::default()),
        links,
        updated_date: trailer_date(&text, "updated "),
        added_date,
        app_completed: app_completed(&continuations),
        section_name: section_name.to_string(),
        range: span(lines),
        text,
    }
}

/// The `YYYY-MM-DD` a title names: an ISO date if one is written out, otherwise
/// a `Month D, YYYY` in any of the long or three-letter spellings. Anything else
/// is `None` — an undated title is not an error.
fn date_from_title(title: &str) -> Option<String> {
    // An ISO date anywhere in the line wins.
    for (i, _) in title.char_indices() {
        if let Some(w) = title.get(i..i + 10) {
            if valid_iso_date(w).is_some() {
                return Some(w.to_string());
            }
        }
    }
    const MONTHS: [&str; 12] = [
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
    ];
    let words: Vec<&str> = title
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect();
    for w in words.windows(3) {
        let lower = w[0].to_lowercase();
        let Some(m) = MONTHS
            .iter()
            .position(|name| *name == lower || (lower.len() == 3 && name.starts_with(&lower)))
        else {
            continue;
        };
        let (Ok(d), Ok(y)) = (w[1].parse::<u32>(), w[2].parse::<u32>()) else {
            continue;
        };
        if (1..=31).contains(&d) && (1000..=9999).contains(&y) {
            return Some(format!("{y:04}-{:02}-{d:02}", m + 1));
        }
    }
    None
}

impl TodaySnapshot {
    /// Every item in the document, lead items first, then each section in order.
    fn all_items(&self) -> impl Iterator<Item = &TodayItem> {
        self.lead_items
            .iter()
            .chain(self.sections.iter().flat_map(|s| s.items.iter()))
    }

    /// Recompute the counts from the current items and reports. Called once at
    /// the end of a parse, and again after glance flags are merged in.
    fn recount(&mut self) {
        let done = self.all_items().filter(|i| i.checked).count();
        let total = self.all_items().count();
        let unseen = self
            .sections
            .iter()
            .flat_map(|s| s.reports.iter())
            .filter(|r| !r.seen)
            .count();
        self.counts = TodayCounts {
            open: total - done,
            done,
            reports_unseen: unseen,
        };
    }
}

// ---- The glance store (read-only) ------------------------------------------

/// One report row's client-side state, as the glance store records it.
#[derive(serde::Serialize, serde::Deserialize, Default, Clone)]
pub struct GlanceFlag {
    #[serde(default)]
    pub seen: bool,
    #[serde(default)]
    pub seen_ms: u64,
}

/// How long a glance survives. A row's `seen` state is only meaningful while the
/// row can still be re-emitted by a rebuild; a week past its day it is dead
/// weight, and GC is what keeps the store from growing without bound.
pub const GLANCE_RETENTION_DAYS: i64 = 7;

/// Report-row `seen` state, read from `<state_dir>/glance.json` and keyed
/// `"YYYY-MM-DD/<id>"`.
///
/// **Why the date is part of the key.** A report row's id is a content hash, so
/// the same briefing line re-emitted tomorrow gets the SAME id — which is right
/// for a task (a check should survive the rebuild) and wrong for a glanceable
/// (today's currency report is a new thing to read, even when it is worded
/// identically). Scoping the key to the day the snapshot is for makes "seen"
/// mean "seen today", which is what the screen is actually claiming.
///
/// A bare-id key is still honored on read so a store written by hand, or by any
/// earlier shape of this file, degrades to its old meaning rather than to an
/// error. An absent, unreadable or malformed store reads as EMPTY, never as an
/// error — the day screen is never blocked by its own bookkeeping.
#[derive(Default)]
pub struct GlanceStore {
    map: HashMap<String, GlanceFlag>,
}

impl GlanceStore {
    /// The composite key for one row on one day.
    pub fn key(date: &str, id: &str) -> String {
        format!("{date}/{id}")
    }

    /// Load the store, or an empty one.
    pub fn load(state_dir: Option<&str>) -> Self {
        let Some(path) = glance_path(state_dir) else {
            return Self::default();
        };
        let map = std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str::<HashMap<String, GlanceFlag>>(&s).ok())
            .unwrap_or_default();
        Self { map }
    }

    /// Stamp `seen` / `seenMs` onto the report rows the store knows about, and
    /// bring `counts.reportsUnseen` back in line.
    pub fn merge_into(&self, snapshot: &mut TodaySnapshot) {
        if self.map.is_empty() {
            return;
        }
        let date = snapshot.date.clone().unwrap_or_default();
        for report in snapshot
            .sections
            .iter_mut()
            .flat_map(|s| s.reports.iter_mut())
        {
            if let Some(flag) = self
                .map
                .get(&Self::key(&date, &report.id))
                .or_else(|| self.map.get(&report.id))
            {
                report.seen = flag.seen;
                report.seen_ms = flag.seen_ms;
            }
        }
        snapshot.recount();
    }

    /// Record that one row was glanced at, last-writer-wins on the client's
    /// millisecond timestamp, and GC everything older than
    /// [`GLANCE_RETENTION_DAYS`] in the same write.
    ///
    /// LWW on a client clock, exactly like [`SessionFlags`]: two devices marking
    /// the same row converge on the later one whatever order the writes arrive
    /// in, and a stale write is ignored rather than winning by being last.
    ///
    /// Best-effort and never fatal — a glance that fails to persist costs one
    /// re-read of a briefing row.
    pub fn record(state_dir: Option<&str>, date: &str, id: &str, glanced_ms: u64) {
        let Some(path) = glance_path(state_dir) else {
            return;
        };
        let mut map = Self::load(state_dir).map;
        let key = Self::key(date, id);
        let entry = map.entry(key).or_default();
        if glanced_ms > entry.seen_ms {
            entry.seen = true;
            entry.seen_ms = glanced_ms;
        }
        gc_glances(&mut map, date);
        persist_glances(&path, &map);
    }

    /// The stored rows. Tests and introspection only.
    pub fn len(&self) -> usize {
        self.map.len()
    }

    /// Whether the store holds nothing.
    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

/// `<state_dir>/glance.json`, or `None` with no state dir (then glances are not
/// recorded at all — the same degradation every other bridge store has).
fn glance_path(state_dir: Option<&str>) -> Option<PathBuf> {
    state_dir.map(|d| Path::new(d).join("glance.json"))
}

/// Drop entries whose key names a day more than [`GLANCE_RETENTION_DAYS`] before
/// `reference`.
///
/// Aged against the SNAPSHOT's date rather than the wall clock, so the store
/// stays a pure function of what it is asked about — the same discipline the
/// parser keeps. A key whose date does not parse is kept: it is either the
/// legacy bare-id shape or something hand-written, and neither is ours to
/// discard.
fn gc_glances(map: &mut HashMap<String, GlanceFlag>, reference: &str) {
    let Some(today) = valid_iso_date(reference).map(civil_days) else {
        return;
    };
    map.retain(|k, _| {
        let Some((date, _)) = k.split_once('/') else {
            return true;
        };
        match valid_iso_date(date).map(civil_days) {
            Some(day) => today - day <= GLANCE_RETENTION_DAYS,
            None => true,
        }
    });
}

/// Persist the glance map atomically (temp + rename), mode 0600 — the same
/// discipline as [`persist_flags`]. Best-effort: a failure is logged, never fatal.
fn persist_glances(path: &Path, map: &HashMap<String, GlanceFlag>) {
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
        f.write_all(serde_json::to_string(map).unwrap_or_default().as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    if let Err(e) = write() {
        eprintln!("warning: could not persist the glance store: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

/// Days since the civil epoch (1970-01-01) for a `(y, m, d)`, so two dates can be
/// subtracted. Howard Hinnant's `days_from_civil`, which is exact for every date
/// in the proleptic Gregorian calendar and needs no date library.
pub fn civil_days((y, m, d): (i64, i64, i64)) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The UTC `YYYY-MM-DD` of a unix-millis instant. The fallback date for a glance
/// against a day file whose title carries no parseable date.
pub fn date_from_ms(ms: u64) -> String {
    rfc3339_utc(UNIX_EPOCH + Duration::from_millis(ms))
        .chars()
        .take(10)
        .collect()
}

// ---- The endpoint ----------------------------------------------------------

/// Serve the snapshot under a strong ETag.
///
/// The tag is computed over the snapshot WITHOUT `generatedAt` and `etag`, which
/// is the whole point: `generatedAt` moves every call, so folding it in would
/// mint a fresh tag each time and no client would ever see a `304`. What the
/// caller gets back therefore carries a tag that is a pure function of the day
/// file's content, and the same tag is echoed inside the body so a client that
/// stored the payload can compare without keeping headers.
fn today_response(headers: &HeaderMap, snapshot: &TodaySnapshot) -> Response {
    let mut value = serde_json::to_value(snapshot).unwrap_or_else(|_| json!({}));
    let etag = snapshot_etag(snapshot);
    if let Some(inm) = headers
        .get(axum::http::header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
    {
        if if_none_match_matches(inm, &etag) {
            return (StatusCode::NOT_MODIFIED, [(axum::http::header::ETAG, etag)]).into_response();
        }
    }
    if let Some(obj) = value.as_object_mut() {
        obj.insert(
            "generatedAt".to_string(),
            json!(rfc3339_utc(SystemTime::now())),
        );
        obj.insert("etag".to_string(), json!(etag.clone()));
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

/// `GET /jesse/today` — the vault's day file as a structured snapshot. Same
/// bearer auth and rate limiter as every other endpoint, strictly read-only, and
/// a pure function of the file: no query parameters, because the file is
/// undated by design and there is only ever a current state to serve.
///
/// A missing day file is `200` with an empty snapshot and `missing: true`, not a
/// `404`: before the morning routine has run there is legitimately no file, and
/// the phone should render an empty day rather than an error.
pub async fn jesse_today(
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
    let (_, snapshot) = build_snapshot(&st.cfg);
    Ok(today_response(&headers, &snapshot))
}

/// The day file's absolute path: a constant filename joined onto the configured
/// vault root. **No part of it comes from a request** — there is no traversal
/// surface on any of these endpoints, and this one function being the only way
/// to name the file is what keeps that true as endpoints are added.
pub fn day_file_path(cfg: &Config) -> PathBuf {
    notes_root(cfg).join(TODAY_FILE)
}

/// The notes root: the configured vault repo plus [`crate::config::VAULT_SUBDIR`].
/// The one place that composition is written, so the next relocation is one edit
/// — and the one root every vault path is confined to (see [`crate::todaydetail`]).
pub fn notes_root(cfg: &Config) -> PathBuf {
    Path::new(&cfg.vault).join(crate::config::VAULT_SUBDIR)
}

/// The strong ETag for a snapshot: a hash of the exact serialized snapshot,
/// WITHOUT `generatedAt` and `etag`.
///
/// The one definition, used by the `GET` and by every mutation's `If-Match`
/// check. If those two ever computed a tag differently, `If-Match` would reject
/// every write a client made from a tag it had just been handed — so they share
/// this function rather than each hashing their own body.
pub fn snapshot_etag(snapshot: &TodaySnapshot) -> String {
    strong_etag(&serde_json::to_string(snapshot).unwrap_or_default())
}

/// Build the snapshot every reader and every precondition check sees: the file
/// on disk, with pending intents merged in and glance state stamped on.
///
/// Returns the RAW on-disk source alongside it, because those two are different
/// documents whenever an intent is parked and a mutation must splice against the
/// former while addressing items in the latter.
///
/// The pending merge is what makes the app read its own writes: a tap parked
/// behind a running turn is not in the file yet, and a screen that showed the box
/// spring back open would be read as a failed tap.
pub fn build_snapshot(cfg: &Config) -> (Option<String>, TodaySnapshot) {
    let raw = std::fs::read_to_string(day_file_path(cfg)).ok();
    let mut snapshot = match &raw {
        Some(src) => parse_today(&merge_pending(src, &pending_intents(cfg))),
        None => TodaySnapshot {
            missing: true,
            ..TodaySnapshot::default()
        },
    };
    hydrate(cfg, &mut snapshot);
    (raw, snapshot)
}

/// Everything that happens to a snapshot AFTER the parse: the project rollup and
/// the glance flags.
///
/// **One definition, because the etag depends on it.** `snapshot_etag` hashes the
/// whole serialized snapshot, and the write path's `If-Match` check re-derives
/// that tag from its own parse rather than from [`build_snapshot`] (it already
/// holds the merged source). If a stamping pass ran on the read side and not the
/// write side, every tag a client was handed by a `GET` would fail the very next
/// `If-Match` and every mutation would `412`. Both sides call THIS, so the two
/// documents cannot drift apart.
pub fn hydrate(cfg: &Config, snapshot: &mut TodaySnapshot) {
    ProjectRollup::load(cfg).stamp_into(snapshot);
    GlanceStore::load(cfg.state_dir.as_deref()).merge_into(snapshot);
}

#[cfg(test)]
mod tests {
    use super::*;

    // Synthetic, invented fixtures — never a copy of the real personal Today.md.
    // `full.md` exercises the whole grammar in one file; the other two exist only
    // to pin the id contract.
    const FULL: &str = include_str!("../tests/fixtures/today/full.md");
    const VARIANT: &str = include_str!("../tests/fixtures/today/variant.md");
    const DUPES: &str = include_str!("../tests/fixtures/today/dupes.md");

    fn section<'a>(snap: &'a TodaySnapshot, name: &str) -> &'a TodaySection {
        snap.sections
            .iter()
            .find(|s| s.name == name)
            .unwrap_or_else(|| panic!("section {name:?} missing"))
    }

    fn item<'a>(sec: &'a TodaySection, lead_starts_with: &str) -> &'a TodayItem {
        sec.items
            .iter()
            .find(|i| i.lead.starts_with(lead_starts_with))
            .unwrap_or_else(|| panic!("item starting {lead_starts_with:?} missing"))
    }

    #[test]
    fn title_and_date_come_from_the_h1() {
        let snap = parse_today(FULL);
        assert_eq!(snap.title.as_deref(), Some("Today: Tuesday, March 3, 2026"));
        assert_eq!(snap.date.as_deref(), Some("2026-03-03"));
    }

    #[test]
    fn an_unparseable_date_serves_null_and_never_errors() {
        let snap = parse_today("# Today: sometime soon\n\n## Do Now\n\n* [ ] A thing.\n");
        assert_eq!(snap.title.as_deref(), Some("Today: sometime soon"));
        assert_eq!(snap.date, None, "an unparseable date is null, not an error");
        assert_eq!(section(&snap, "Do Now").items.len(), 1);
    }

    #[test]
    fn sections_split_on_h2_and_carry_their_rendering_kind() {
        let snap = parse_today(FULL);
        let got: Vec<(&str, &str)> = snap
            .sections
            .iter()
            .map(|s| (s.name.as_str(), s.kind))
            .collect();
        assert_eq!(
            got,
            vec![
                ("Schedule", "schedule"),
                ("Do Now", "tasks"),
                ("Errands", "tasks"),
                ("Health", "briefing"),
                ("Currency", "briefing"),
                ("Still open (aging)", "briefing"),
                ("Reminders (Mar 3 to Mar 10)", "briefing"),
                ("Done Today", "tasks"),
            ]
        );
    }

    #[test]
    fn the_lead_block_yields_the_standing_item_and_the_day_narrative() {
        let snap = parse_today(FULL);
        assert_eq!(snap.lead_items.len(), 1, "one standing item in the lead");
        let standing = &snap.lead_items[0];
        assert!(standing
            .lead
            .starts_with("TOP PRIORITY: Finish the kiln rebuild"));
        assert_eq!(standing.added_date.as_deref(), Some("2026-01-04"));
        assert_eq!(
            standing.section_name, "",
            "lead items sit above every section"
        );
        let narrative = snap.narrative.as_deref().expect("narrative");
        assert!(
            narrative.contains("it is a short day"),
            "narrative is the lead block's prose, got {narrative:?}"
        );
        assert!(
            !narrative.contains("Standing lead item"),
            "an item's continuation is NOT narrative: {narrative:?}"
        );
    }

    #[test]
    fn task_lines_are_parsed_wherever_they_appear_including_briefing_sections() {
        let snap = parse_today(FULL);
        assert_eq!(
            section(&snap, "Do Now").items.len(),
            4,
            "incl. the empty box"
        );
        assert_eq!(section(&snap, "Errands").items.len(), 2);
        assert_eq!(
            section(&snap, "Health").items.len(),
            1,
            "a briefing section still yields its task lines"
        );
        assert_eq!(section(&snap, "Done Today").items.len(), 1);
    }

    #[test]
    fn item_fields_are_extracted() {
        let snap = parse_today(FULL);
        let it = item(
            section(&snap, "Do Now"),
            "Order the replacement thermocouple",
        );
        assert!(!it.checked);
        assert_eq!(it.lead, "Order the replacement thermocouple.");
        assert_eq!(it.added_date.as_deref(), Some("2026-03-01"));
        assert_eq!(it.updated_date.as_deref(), Some("2026-03-03"));
        assert_eq!(it.section_name, "Do Now");
        assert!(it.text.starts_with("* [ ] **Order the replacement"));

        // Checked, both spellings of the box.
        let done = item(section(&snap, "Errands"), "Collect the glaze order");
        assert!(done.checked, "* [x] is checked");
        assert!(
            item(section(&snap, "Errands"), "Return the borrowed clamps").checked,
            "* [X] is checked too (case-insensitive)"
        );
    }

    #[test]
    fn an_unbolded_lead_falls_back_to_the_first_sentence() {
        let snap = parse_today(FULL);
        let it = item(section(&snap, "Do Now"), "Plain unbolded item");
        assert_eq!(it.lead, "Plain unbolded item with no trailer at all.");
    }

    #[test]
    fn continuations_travel_with_their_item() {
        let snap = parse_today(FULL);
        let standing = &snap.lead_items[0];
        assert_eq!(
            standing.text.lines().count(),
            3,
            "the task line plus its two tab-indented continuations: {:?}",
            standing.text
        );
        assert!(standing.text.contains("Standing lead item"));
        assert!(standing.text.contains("[[notes/Projects/kiln-rebuild]]"));

        // The app sub-line is a continuation AND is lifted into appCompleted.
        let done = item(section(&snap, "Errands"), "Collect the glaze order");
        let app = done.app_completed.clone().expect("appCompleted");
        assert_eq!(app.at.as_deref(), Some("2026-03-03T08:12:00Z"));
        assert_eq!(
            app.evidence.as_deref(),
            Some("checked off on the phone"),
            "the evidence is the text after the timestamp"
        );
    }

    #[test]
    fn links_are_extracted_and_tagged() {
        let snap = parse_today(FULL);
        let it = item(section(&snap, "Do Now"), "Reply to Ada");
        assert_eq!(
            it.links,
            vec![
                TodayLink {
                    target: "https://example.invalid/kiln/schedule".to_string(),
                    kind: "url",
                },
                TodayLink {
                    target: "notes/Dashboard/Workshop".to_string(),
                    kind: "wiki",
                },
            ],
            "bare URL and wiki target, in source order, each tagged"
        );
        // An item whose only link sits in a continuation still reports it.
        assert_eq!(
            snap.lead_items[0].links,
            vec![TodayLink {
                target: "notes/Projects/kiln-rebuild".to_string(),
                kind: "wiki",
            }]
        );
    }

    #[test]
    fn the_malformed_half_item_does_not_derail_the_parse() {
        let snap = parse_today(FULL);
        let sec = section(&snap, "Do Now");
        // An empty box is still an item (empty lead), and the malformed `- []`
        // line is prose, not a silently-dropped task.
        assert!(
            sec.items.iter().any(|i| i.lead.is_empty()),
            "the empty checkbox parses as an item with an empty lead"
        );
        assert!(
            sec.prose
                .iter()
                .any(|p| p.text.contains("not really a task")),
            "a malformed box is carried as prose, never dropped"
        );
    }

    #[test]
    fn glanceables_become_reports_with_a_kind() {
        let snap = parse_today(FULL);
        let kind_of = |section_name: &str, needle: &str| -> &'static str {
            section(&snap, section_name)
                .reports
                .iter()
                .find(|r| r.title.contains(needle))
                .unwrap_or_else(|| panic!("report {needle:?} missing from {section_name}"))
                .kind
        };
        assert_eq!(kind_of("Health", "run day"), "health");
        assert_eq!(kind_of("Currency", "fixing has not posted"), "currency");
        assert_eq!(
            kind_of("Reminders (Mar 3 to Mar 10)", "cheatsheet"),
            "cheatsheet"
        );
        assert_eq!(kind_of("Still open (aging)", "philosophy"), "philosophy");
        assert_eq!(
            kind_of("Still open (aging)", "insurance renewal"),
            "general"
        );

        // A bold briefing line with NO link is not glanceable — it stays prose.
        let currency = section(&snap, "Currency");
        assert!(
            !currency
                .reports
                .iter()
                .any(|r| r.title.contains("no link at all")),
            "a bold line without a link is not a report"
        );
        assert!(
            currency
                .prose
                .iter()
                .any(|p| p.text.contains("no link at all")),
            "…and it is still carried as prose"
        );

        // A `tasks` section never produces reports, however bold and linked.
        assert!(
            section(&snap, "Do Now").reports.is_empty(),
            "reports are a briefing-section concept"
        );
        // The FYI line is glanceable on its own, with no bold anywhere.
        let reminders = section(&snap, "Reminders (Mar 3 to Mar 10)");
        assert!(reminders
            .reports
            .iter()
            .any(|r| r.title.starts_with("FYI:")));
    }

    #[test]
    fn non_glanceable_prose_is_carried_per_section() {
        let snap = parse_today(FULL);
        assert!(
            section(&snap, "Health")
                .prose
                .iter()
                .any(|p| p.text.starts_with("Plain prose with no bold")),
            "body text is preserved for rendering"
        );
        assert_eq!(
            section(&snap, "Schedule").prose.len(),
            2,
            "a schedule's bullets are prose, not reports"
        );
    }

    #[test]
    fn counts_tally_open_done_and_unseen_reports() {
        let snap = parse_today(FULL);
        let all_items =
            snap.lead_items.len() + snap.sections.iter().map(|s| s.items.len()).sum::<usize>();
        assert_eq!(snap.counts.open + snap.counts.done, all_items);
        assert_eq!(
            snap.counts.done, 3,
            "two errands plus the start-of-day line"
        );
        let reports: usize = snap.sections.iter().map(|s| s.reports.len()).sum();
        assert_eq!(
            snap.counts.reports_unseen, reports,
            "with no glance store every report is unseen"
        );
    }

    // ---- The item identity contract ---------------------------------------

    #[test]
    fn the_id_survives_a_rebuild_that_changes_everything_but_the_lead_and_added_date() {
        let a = parse_today(FULL);
        let b = parse_today(VARIANT);
        let ia = item(section(&a, "Do Now"), "Order the replacement thermocouple.");
        let ib = item(section(&b, "Do Now"), "Order the replacement thermocouple.");
        assert_ne!(ia.text, ib.text, "the fixtures really do differ");
        assert_ne!(ia.updated_date, ib.updated_date, "…including the trailer");
        assert_eq!(
            ia.id, ib.id,
            "same section + lead + Added date → same id, so client state survives the morning rebuild"
        );
    }

    #[test]
    fn a_reworded_lead_gets_a_different_id() {
        let b = parse_today(VARIANT);
        let sec = section(&b, "Do Now");
        let one = item(sec, "Order the replacement thermocouple.");
        let two = item(sec, "Order the replacement thermocouples.");
        assert_ne!(one.id, two.id, "one letter of lead is a different item");
    }

    #[test]
    fn duplicate_leads_gain_ordinal_suffixes_in_file_order() {
        let snap = parse_today(DUPES);
        let ids: Vec<&str> = section(&snap, "Do Now")
            .items
            .iter()
            .map(|i| i.id.as_str())
            .collect();
        assert_eq!(ids.len(), 3);
        assert_eq!(ids[1], format!("{}-2", ids[0]));
        assert_eq!(ids[2], format!("{}-3", ids[0]));
    }

    #[test]
    fn the_id_is_the_documented_hash() {
        // First 12 hex of sha256(section|normalized_lead|added_date).
        let expected = today_id("Do Now", "**Chase the controller.**", "2026-03-01");
        let snap = parse_today(DUPES);
        assert_eq!(section(&snap, "Do Now").items[0].id, expected);
        assert_eq!(expected.len(), 12, "12 hex chars");
        assert!(expected.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn normalize_lead_strips_markup_lowercases_collapses_and_truncates() {
        assert_eq!(
            normalize_lead("**Chase   the [[notes/x|controller]].**"),
            "chase the controller."
        );
        assert_eq!(normalize_lead("`code` and *emphasis*"), "code and emphasis");
        assert_eq!(
            normalize_lead("[the text](https://example.invalid/x)"),
            "the text"
        );
        assert_eq!(
            normalize_lead(&"a".repeat(200)).len(),
            120,
            "truncated to 120 chars"
        );
        assert_eq!(
            normalize_lead("keeps snake_case identifiers intact"),
            "keeps snake_case identifiers intact",
            "underscores are vault identifiers, not emphasis"
        );
    }

    // ---- The project slug --------------------------------------------------

    const PROJECTS: &str = include_str!("../tests/fixtures/today/projects.md");

    /// The rollup the fixture is written against: one note claimed by a single
    /// topic page, one claimed by two.
    fn demo_rollup() -> ProjectRollup {
        ProjectRollup::from_pairs(&[
            ("todo-list/Projects/Demo/Claimed-Once", "tag1"),
            ("todo-list/Projects/Demo/Claimed-Twice", "tag1"),
            ("todo-list/Projects/Demo/Claimed-Twice", "personal"),
        ])
    }

    /// The fixture, parsed and then stamped with `demo_rollup` — the same two
    /// passes `build_snapshot` runs.
    fn projects_snapshot() -> TodaySnapshot {
        let mut snap = parse_today(PROJECTS);
        demo_rollup().stamp_into(&mut snap);
        snap
    }

    fn project_of(snap: &TodaySnapshot, section_name: &str, lead_starts: &str) -> &'static str {
        item(section(snap, section_name), lead_starts).project
    }

    #[test]
    fn each_topic_home_link_maps_to_its_slug() {
        let snap = projects_snapshot();
        for (lead, slug) in [
            ("A Tag1 home link", "tag1"),
            ("A Personal home link", "personal"),
            ("A Network home link", "network"),
            ("A Via-Con-Me home link", "via-con-me"),
            ("A Perseido home link", "perseido"),
        ] {
            assert_eq!(project_of(&snap, "Do Now", lead), slug, "{lead}");
        }
        // The alias/heading and the `vault/` spelling of the prefix resolve too.
        assert_eq!(
            project_of(&snap, "Do Now", "An alias and a heading still resolve"),
            "tag1"
        );
        assert_eq!(
            project_of(&snap, "Do Now", "The vault-subdir spelling resolves too"),
            "perseido"
        );
    }

    #[test]
    fn an_item_with_no_resolvable_home_is_unfiled() {
        let snap = projects_snapshot();
        for lead in [
            "No link at all, so no declared home",
            "A wiki link no topic page claims",
            "A URL is not a lineage",
        ] {
            assert_eq!(project_of(&snap, "Do Now", lead), PROJECT_UNFILED, "{lead}");
        }
        // And the OTHER fixtures, whose links name no topic at all, are unfiled
        // throughout — the derivation never invents a home.
        let full = parse_today(FULL);
        assert!(
            full.lead_items
                .iter()
                .chain(full.sections.iter().flat_map(|s| s.items.iter()))
                .all(|i| i.project == PROJECT_UNFILED),
            "an unrelated day file files nothing"
        );
    }

    #[test]
    fn a_note_a_topic_page_claims_rolls_up_to_that_topic() {
        let snap = projects_snapshot();
        assert_eq!(
            project_of(&snap, "Do Now", "A note one topic page claims"),
            "tag1"
        );
        // …and without the rollup table, the same item is unfiled rather than
        // guessed: the parse alone cannot know who claims that note.
        let bare = parse_today(PROJECTS);
        assert_eq!(
            project_of(&bare, "Do Now", "A note one topic page claims"),
            PROJECT_UNFILED
        );
        assert_eq!(
            project_of(&bare, "Do Now", "A Tag1 home link"),
            "tag1",
            "a DIRECT home link needs no rollup"
        );
    }

    #[test]
    fn a_direct_home_link_outranks_a_rollup_link() {
        assert_eq!(
            project_of(
                &projects_snapshot(),
                "Do Now",
                "A home link outranks a rollup link"
            ),
            "network",
            "the declared home wins over the note that merely rolls up"
        );
    }

    #[test]
    fn a_two_topic_rollup_is_settled_by_the_heading_or_left_unfiled() {
        let snap = projects_snapshot();
        // Under a heading that names one of the two candidates, the tie resolves.
        assert_eq!(
            project_of(
                &snap,
                "Tag1 (owed replies and decisions)",
                "A heading tie-break over a two-topic rollup"
            ),
            "tag1"
        );
        // Under a heading that names neither, it does not.
        assert_eq!(
            project_of(&snap, "Do Now", "A note two topic pages claim"),
            PROJECT_UNFILED
        );
        // Two home links and a heading that names neither: still unfiled.
        assert_eq!(
            project_of(&snap, "Do Now", "Two home links with nothing to separate"),
            PROJECT_UNFILED
        );
    }

    #[test]
    fn the_heading_only_disambiguates_and_never_files_on_its_own() {
        let snap = projects_snapshot();
        // A Tag1 heading over an item that declared no lineage at all.
        assert_eq!(
            project_of(
                &snap,
                "Tag1 (owed replies and decisions)",
                "A heading never files an item that declared nothing"
            ),
            PROJECT_UNFILED,
            "the heading is a tiebreak among declared candidates, not a source"
        );
        // A Personal heading does NOT override a single, unambiguous candidate.
        assert_eq!(
            project_of(
                &snap,
                "Personal, family and travel",
                "A heading that names a candidate the links did not offer"
            ),
            "tag1"
        );
    }

    #[test]
    fn duplicate_and_reworded_items_each_keep_their_own_project() {
        let snap = projects_snapshot();
        let dupes: Vec<&TodayItem> = section(&snap, "Tag1 (owed replies and decisions)")
            .items
            .iter()
            .filter(|i| i.lead.starts_with("A duplicate lead"))
            .collect();
        assert_eq!(dupes.len(), 2);
        assert_ne!(dupes[0].id, dupes[1].id, "the ids still disambiguate");
        assert!(
            dupes.iter().all(|i| i.project == "tag1"),
            "a duplicated item is filed like its twin"
        );

        // Rewording the lead mints a new id but must not move the project: the
        // slug is a function of the links, not of the words.
        let reworded = parse_today(
            "# Today\n\n## Do Now\n\n* [ ] **Quite different words.** [[todo-list/Dashboard/Tag1]] (Added 2026-03-01)\n",
        );
        let original = item(section(&snap, "Do Now"), "A Tag1 home link");
        let other = &section(&reworded, "Do Now").items[0];
        assert_ne!(original.id, other.id);
        assert_eq!(original.project, other.project);
    }

    #[test]
    fn the_project_is_on_the_wire_and_folds_into_the_snapshot_etag() {
        let snap = projects_snapshot();
        let wire = serde_json::to_value(&snap).unwrap();
        let first = &wire["sections"][0]["items"][0];
        assert_eq!(first["project"], "tag1", "the slug is serialized");
        assert!(
            wire.to_string().find("via-con-me").is_some(),
            "every resolved slug reaches the wire"
        );
        // A slug, and ONLY a slug: no colour or display string rides along.
        for key in ["color", "colour", "hex", "projectName", "projectLabel"] {
            assert!(
                first.get(key).is_none(),
                "{key} is a client concern and must not be on the wire"
            );
        }
        for item in snap
            .lead_items
            .iter()
            .chain(snap.sections.iter().flat_map(|s| s.items.iter()))
        {
            assert!(
                PROJECT_SLUGS.contains(&item.project),
                "{:?} is outside the frozen set",
                item.project
            );
        }

        // Changing only the project moves the etag, so a client's cache cannot
        // survive a re-filing.
        let before = snapshot_etag(&snap);
        let mut moved = snap.clone();
        moved.sections[0].items[0].project = "personal";
        assert_ne!(before, snapshot_etag(&moved));

        // The same document with a DIFFERENT rollup is a different etag too.
        let unstamped = parse_today(PROJECTS);
        assert_ne!(
            before,
            snapshot_etag(&unstamped),
            "stamping the rollup must invalidate a cached snapshot"
        );
    }

    #[test]
    fn note_key_normalizes_the_prefix_heading_and_extension() {
        assert_eq!(note_key("todo-list/Projects/A/B"), "projects/a/b");
        assert_eq!(note_key("vault/Projects/A/B.md"), "projects/a/b");
        assert_eq!(note_key("todo-list/Projects/A/B#Heading"), "projects/a/b");
        assert_eq!(note_key("/todo-list/Projects/A/B"), "projects/a/b");
        assert_eq!(note_key("Projects/A/B"), "projects/a/b");
        // A path is NOT lowercased — the notes root may be case-sensitive.
        assert_eq!(vault_relative("todo-list/Projects/A/B"), "Projects/A/B");
        assert_eq!(
            vault_relative("todo-list/Projects/A/B.md"),
            "Projects/A/B.md"
        );
        assert_eq!(vault_relative("todo-list/Projects/A#H"), "Projects/A");
    }

    // ---- Byte-range fidelity ----------------------------------------------

    #[test]
    fn every_range_reproduces_its_source_slice_exactly() {
        let snap = parse_today(FULL);
        let slice = |r: &SourceRange| FULL[r.start..r.end].trim_end_matches('\n');
        let mut checked = 0;
        for it in snap
            .lead_items
            .iter()
            .chain(snap.sections.iter().flat_map(|s| s.items.iter()))
        {
            assert_eq!(slice(&it.range), it.text, "item range must be its source");
            checked += 1;
        }
        for sec in &snap.sections {
            assert!(
                FULL[sec.range.start..sec.range.end].starts_with(&format!("## {}", sec.name)),
                "a section's range starts at its heading"
            );
            for p in &sec.prose {
                assert_eq!(slice(&p.range), p.text);
                checked += 1;
            }
            for r in &sec.reports {
                assert!(
                    FULL[r.range.start..r.range.end].contains(r.title.trim_start_matches("FYI: ")),
                    "a report's range covers its source line"
                );
                checked += 1;
            }
        }
        assert!(
            checked > 20,
            "the fixture exercises many nodes, got {checked}"
        );
    }

    #[test]
    fn section_ranges_tile_the_document_without_gaps_or_overlaps() {
        let snap = parse_today(FULL);
        let mut cursor = snap.sections[0].range.start;
        for sec in &snap.sections {
            assert_eq!(sec.range.start, cursor, "section {} starts a gap", sec.name);
            cursor = sec.range.end;
        }
        assert_eq!(cursor, FULL.len(), "the last section runs to EOF");
    }

    #[test]
    fn the_parser_never_reserializes_the_document() {
        // Splice one item out by its range and the rest of the file is byte-identical.
        let snap = parse_today(FULL);
        let target = &snap.sections[1].items[0];
        let mut spliced = String::with_capacity(FULL.len());
        spliced.push_str(&FULL[..target.range.start]);
        spliced.push_str(&FULL[target.range.end..]);
        assert_eq!(
            spliced.len(),
            FULL.len() - (target.range.end - target.range.start)
        );
        assert!(!spliced.contains(&target.text), "only that node is gone");
        assert!(
            spliced.contains("## Errands"),
            "every other line is untouched"
        );
    }

    #[test]
    fn an_empty_document_parses_to_an_empty_snapshot() {
        let snap = parse_today("");
        assert_eq!(snap.title, None);
        assert_eq!(snap.date, None);
        assert!(snap.sections.is_empty() && snap.lead_items.is_empty());
        assert_eq!(snap.counts, TodayCounts::default());
    }
}
