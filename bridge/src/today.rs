//! `GET /jesse/today` — a structured, read-only snapshot of the vault's
//! `Today.md`. STUB: types and signatures only, so the test suite compiles and
//! fails. The parser lands in the next commit.

use crate::*;

/// The vault-relative name of the day file, under `config::VAULT_SUBDIR`.
pub const TODAY_FILE: &str = "Today.md";

#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct SourceRange {
    pub start: usize,
    pub end: usize,
}

#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct TodayLink {
    pub target: String,
    pub kind: &'static str,
}

#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct AppCompleted {
    pub at: Option<String>,
    pub evidence: Option<String>,
}

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

#[derive(serde::Serialize, PartialEq, Debug, Clone)]
pub struct TodayProse {
    pub text: String,
    pub range: SourceRange,
}

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

/// Parse the day file. STUB.
pub fn parse_today(_src: &str) -> TodaySnapshot {
    TodaySnapshot::default()
}

/// The item identity contract. STUB.
pub fn today_id(_section: &str, _lead: &str, _added_date: &str) -> String {
    String::new()
}

/// Lead normalization for the id contract. STUB.
pub fn normalize_lead(_lead: &str) -> String {
    String::new()
}

/// `GET /jesse/today`. STUB.
pub async fn jesse_today(
    State(st): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    Err((StatusCode::NOT_IMPLEMENTED, "not implemented".to_string()))
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
        assert!(standing.lead.starts_with("TOP PRIORITY: Finish the kiln rebuild"));
        assert_eq!(standing.added_date.as_deref(), Some("2026-01-04"));
        assert_eq!(standing.section_name, "", "lead items sit above every section");
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
        assert_eq!(section(&snap, "Do Now").items.len(), 4, "incl. the empty box");
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
        let it = item(section(&snap, "Do Now"), "Order the replacement thermocouple");
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
            sec.prose.iter().any(|p| p.text.contains("not really a task")),
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
        assert_eq!(kind_of("Reminders (Mar 3 to Mar 10)", "cheatsheet"), "cheatsheet");
        assert_eq!(kind_of("Still open (aging)", "philosophy"), "philosophy");
        assert_eq!(kind_of("Still open (aging)", "insurance renewal"), "general");

        // A bold briefing line with NO link is not glanceable — it stays prose.
        let currency = section(&snap, "Currency");
        assert!(
            !currency.reports.iter().any(|r| r.title.contains("no link at all")),
            "a bold line without a link is not a report"
        );
        assert!(
            currency.prose.iter().any(|p| p.text.contains("no link at all")),
            "…and it is still carried as prose"
        );

        // A `tasks` section never produces reports, however bold and linked.
        assert!(
            section(&snap, "Do Now").reports.is_empty(),
            "reports are a briefing-section concept"
        );
        // The FYI line is glanceable on its own, with no bold anywhere.
        let reminders = section(&snap, "Reminders (Mar 3 to Mar 10)");
        assert!(reminders.reports.iter().any(|r| r.title.starts_with("FYI:")));
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
        let all_items = snap.lead_items.len()
            + snap.sections.iter().map(|s| s.items.len()).sum::<usize>();
        assert_eq!(snap.counts.open + snap.counts.done, all_items);
        assert_eq!(snap.counts.done, 3, "two errands plus the start-of-day line");
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
        assert_eq!(
            normalize_lead("`code` and *emphasis*"),
            "code and emphasis"
        );
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
        for it in snap.lead_items.iter().chain(
            snap.sections
                .iter()
                .flat_map(|s| s.items.iter()),
        ) {
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
        assert!(checked > 20, "the fixture exercises many nodes, got {checked}");
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
