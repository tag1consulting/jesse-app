//! `GET /jesse/today` — a structured, read-only snapshot of the vault's
//! `Today.md`, the file the morning routine rewrites in full every day.
//!
//! Read-only. There is no write path here — checking a box, marking a
//! glanceable seen and pushing a change over SSE are all follow-on work.
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
//! from ([`SourceRange`]), so a later write path can splice a line — check a box,
//! append a sub-line — by replacing exactly those bytes and leaving every other
//! byte of the file untouched. That matters because the file is hand-edited and
//! agent-edited between rebuilds: a round-trip through a markdown serializer
//! would reflow prose, renumber lists and normalize whitespace that a human
//! chose. There is no write path here yet (this endpoint is read-only); the
//! ranges are what makes one possible without a reformat.
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
    let evidence = if timestamp { tail } else { body }
        .trim()
        .trim_start_matches(['—', '-', '–'])
        .trim();
    Some(AppCompleted {
        at: timestamp.then(|| head.to_string()),
        evidence: (!evidence.is_empty()).then(|| evidence.to_string()),
    })
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
    TodayItem {
        id: ids.assign(today_id(
            section_name,
            &lead,
            added_date.as_deref().unwrap_or(""),
        )),
        checked,
        lead,
        links: extract_links(&text),
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
#[derive(serde::Deserialize, Default, Clone)]
pub struct GlanceFlag {
    #[serde(default)]
    pub seen: bool,
    #[serde(default)]
    pub seen_ms: u64,
}

/// Report-row `seen` state, keyed on the item id, read from
/// `<state_dir>/glance.json`.
///
/// **No such file exists yet** — the write path that would create it is out of
/// scope for this endpoint. It is read here rather than deferred because the
/// absent case and the present case must be the same code path: an absent,
/// unreadable or malformed store reads as EMPTY, never as an error, so this
/// endpoint keeps working identically whether the store lands later or never.
#[derive(Default)]
pub struct GlanceStore {
    map: HashMap<String, GlanceFlag>,
}

impl GlanceStore {
    /// Load the store, or an empty one. Any failure — no state dir, no file, bad
    /// JSON — is an empty store; the day screen is never blocked by it.
    pub fn load(state_dir: Option<&str>) -> Self {
        let Some(dir) = state_dir else {
            return Self::default();
        };
        let map = std::fs::read_to_string(Path::new(dir).join("glance.json"))
            .ok()
            .and_then(|s| serde_json::from_str::<HashMap<String, GlanceFlag>>(&s).ok())
            .unwrap_or_default();
        Self { map }
    }

    /// Stamp `seen` / `seenMs` onto the report rows the store knows about, and
    /// bring `counts.reportsUnseen` back in line.
    pub fn merge_into(&self, snapshot: &mut TodaySnapshot) {
        if !self.map.is_empty() {
            for report in snapshot
                .sections
                .iter_mut()
                .flat_map(|s| s.reports.iter_mut())
            {
                if let Some(flag) = self.map.get(&report.id) {
                    report.seen = flag.seen;
                    report.seen_ms = flag.seen_ms;
                }
            }
            snapshot.recount();
        }
    }
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

    let path = Path::new(&st.cfg.vault)
        .join(crate::config::VAULT_SUBDIR)
        .join(TODAY_FILE);
    let mut snapshot = match std::fs::read_to_string(&path) {
        Ok(src) => parse_today(&src),
        Err(_) => TodaySnapshot {
            missing: true,
            ..TodaySnapshot::default()
        },
    };
    GlanceStore::load(st.cfg.state_dir.as_deref()).merge_into(&mut snapshot);
    Ok(today_response(&headers, &snapshot))
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
