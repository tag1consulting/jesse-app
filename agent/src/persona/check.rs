//! **The style checker** — voice as a checked property.
//!
//! A style instruction in a system prompt is a request. The model may honour it, and when it
//! does not, nothing anywhere says so: the turn looks exactly like a turn that complied. This
//! module closes that gap. [`check()`] reads the text that came back and counts what it found;
//! [`apply()`] decides what to do about it.
//!
//! **THE REPORT IS CONTENT FREE, and that is a hard constraint rather than a nicety.** A
//! [`Hit`] carries the pattern's SOURCE (which came from the owner's own configuration), the
//! LINE NUMBER, and the LENGTH of what matched. It never carries the matched text, and there
//! is no field it could be put in. The report rides the provenance channel out to a badge, a
//! log line and an eval assertion, all three of which are content free everywhere else, and
//! a report that carried an excerpt would be the one place a fragment of the answer leaked
//! into all of them.
//!
//! **WHERE THE CHECKER LOOKS: the prose.** Fenced code blocks are exempt entirely and inline
//! code spans are masked out before anything is matched. `--flag` in a shell line and `a--b`
//! in a C snippet are correct code, not writing tells, and a checker that flagged them would
//! be turned off within a week. One rule, applied to every check the module makes, so there
//! is never a question about which of them sees code.

use super::*;
use std::future::Future;

/// The default number of regeneration attempts for [`StylePolicy::Regenerate`].
///
/// ONE. Each attempt is a whole extra assistant turn: the second attempt doubles the cost of
/// a flagged turn and adds its whole latency to a person waiting. A model that broke the
/// rules twice with the rules in front of it is not going to be talked round by a third ask.
pub const DEFAULT_ATTEMPTS: u8 = 1;

// ===========================================================================
// The report
// ===========================================================================

/// One banned-pattern match. Content free: the pattern source is the owner's own
/// configuration, the line number is a position, and the length is a length.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hit {
    /// The pattern line as the owner wrote it, from [`Pattern::source`].
    pub pattern_source: String,
    /// The 1-based line number the match was on.
    pub line: usize,
    /// How many CHARACTERS the match covered. A size, never the text.
    pub excerpt_len: usize,
}

/// What a checked reply broke.
///
/// The three structural counts are separate from `hits` because they come from the
/// FORMATTING parameters rather than from a pattern list, and a caller reporting "3 hits"
/// wants a number it can explain. [`StyleReport::total`] adds them up.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct StyleReport {
    /// One entry per banned-pattern match, in reading order.
    pub hits: Vec<Hit>,
    /// Dash variants found while [`Dashes::Forbidden`] was set. Zero when dashes are allowed
    /// (the check is not run at all, rather than run and discarded).
    pub dash_hits: usize,
    /// Bullet or numbered list lines found while [`Lists::Avoid`] was set.
    pub list_hits: usize,
    /// Markdown heading lines found while [`Headings::Avoid`] was set.
    pub heading_hits: usize,
}

impl StyleReport {
    /// Everything the checker counted.
    pub fn total(&self) -> usize {
        self.hits.len() + self.dash_hits + self.list_hits + self.heading_hits
    }

    /// Nothing was found.
    pub fn is_clean(&self) -> bool {
        self.total() == 0
    }

    /// The distinct pattern sources that matched, in first-seen order, with a count each.
    pub fn by_pattern(&self) -> Vec<(&str, usize)> {
        let mut out: Vec<(&str, usize)> = Vec::new();
        for h in &self.hits {
            match out.iter_mut().find(|(s, _)| *s == h.pattern_source) {
                Some((_, n)) => *n += 1,
                None => out.push((h.pattern_source.as_str(), 1)),
            }
        }
        out
    }
}

// ===========================================================================
// The check
// ===========================================================================

/// Check one reply against one pack.
///
/// Line by line, 1-based. Banned patterns are matched case-insensitively (the compiled
/// pattern carries the flag). The three structural checks run only when the corresponding
/// formatting parameter asks for them, so a pack that allows dashes pays nothing for the
/// dash scan and reports `dash_hits: 0` honestly rather than by omission.
pub fn check(text: &str, pack: &PersonaPack) -> StyleReport {
    let mut report = StyleReport::default();
    let check_dashes = pack.formatting.dashes == Dashes::Forbidden;
    let check_lists = pack.formatting.lists == Lists::Avoid;
    let check_headings = pack.formatting.headings == Headings::Avoid;

    let mut in_fence = false;
    for (i, raw) in text.lines().enumerate() {
        let line_no = i + 1;
        if is_fence(raw) {
            in_fence = !in_fence;
            continue;
        }
        if in_fence {
            continue;
        }
        // ONE masked line, shared by every content check below, so there is never a question
        // about which of them sees inline code.
        let masked = mask_inline_code(raw);

        for pattern in &pack.banned_patterns {
            for m in pattern.regex().find_iter(&masked) {
                report.hits.push(Hit {
                    pattern_source: pattern.source().to_string(),
                    line: line_no,
                    excerpt_len: m.as_str().chars().count(),
                });
            }
        }
        if check_dashes {
            report.dash_hits += count_dashes(&masked);
        }
        if check_lists && is_list_line(raw) {
            report.list_hits += 1;
        }
        if check_headings && is_heading_line(raw) {
            report.heading_hits += 1;
        }
    }
    report
}

/// A fenced-code delimiter: three or more backticks or tildes, optionally indented, with
/// only an info string after them.
fn is_fence(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("```") || t.starts_with("~~~")
}

/// Replace every inline code span, backticks included, with spaces of the same width.
///
/// SPACES rather than deletion so that byte and character positions inside the line are
/// unchanged; only the reported length would notice, and nothing that matches across a
/// removed span could be a writing tell anyway. An unclosed backtick masks to the end of the
/// line, which is the conservative direction: a checker that guesses wrong should under
/// report rather than accuse.
fn mask_inline_code(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut in_code = false;
    for c in line.chars() {
        if c == '`' {
            in_code = !in_code;
            out.push(' ');
        } else if in_code {
            // One space per character, so the mask keeps the line's character count.
            out.push(' ');
        } else {
            out.push(c);
        }
    }
    out
}

/// Every dash variant the [`Dashes::Forbidden`] rule names: em dash, en dash, double hyphen.
fn count_dashes(line: &str) -> usize {
    let em = line.matches('\u{2014}').count();
    let en = line.matches('\u{2013}').count();
    // `matches` on a `&str` pattern is non overlapping, so `---` counts once and `----`
    // twice. Either way the line is flagged, which is what the count is for.
    let double = line.matches("--").count();
    em + en + double
}

/// A bullet or numbered list item: `- x`, `* x`, `+ x`, `1. x`, `1) x`, optionally indented.
fn is_list_line(line: &str) -> bool {
    let t = line.trim_start();
    let mut chars = t.chars();
    match chars.next() {
        Some('-') | Some('*') | Some('+') => chars.next().is_some_and(|c| c == ' '),
        Some(d) if d.is_ascii_digit() => {
            let rest: String = chars.collect();
            let rest = rest.trim_start_matches(|c: char| c.is_ascii_digit());
            let mut r = rest.chars();
            matches!(r.next(), Some('.') | Some(')')) && r.next().is_some_and(|c| c == ' ')
        }
        _ => false,
    }
}

/// An ATX markdown heading: one to six `#` followed by a space.
fn is_heading_line(line: &str) -> bool {
    let t = line.trim_start();
    let hashes = t.chars().take_while(|c| *c == '#').count();
    (1..=6).contains(&hashes) && t[hashes..].starts_with(' ')
}

// ===========================================================================
// The policies
// ===========================================================================

/// What to do with a reply the checker flagged.
///
/// **The default is [`StylePolicy::Annotate`]**, and the reason is arithmetic.
/// [`StylePolicy::Regenerate`] asks the loop for another whole assistant turn: it doubles the
/// token cost of every flagged turn and adds a second turn's latency to somebody who is
/// waiting for the first. That is a real trade with a real bill attached, so it is a
/// deployment's decision to make rather than a default it discovers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StylePolicy {
    /// Do not check at all. The report is never built, so nothing is counted and nothing is
    /// reported.
    Off,
    /// Check and REPORT. The text is delivered exactly as the model wrote it, and the report
    /// rides the provenance channel so a reader can see the voice drifting before anybody
    /// pays to fix it. THE DEFAULT.
    #[default]
    Annotate,
    /// Check, and ask for a rewrite when something was found.
    Regenerate {
        /// How many extra assistant turns may be spent. See [`DEFAULT_ATTEMPTS`].
        max_attempts: u8,
    },
}

impl std::fmt::Display for StylePolicy {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StylePolicy::Off => f.write_str("off"),
            StylePolicy::Annotate => f.write_str("annotate"),
            StylePolicy::Regenerate { max_attempts } => write!(f, "regenerate:{max_attempts}"),
        }
    }
}

impl std::str::FromStr for StylePolicy {
    type Err = String;

    /// `off` | `annotate` | `regenerate` | `regenerate:<n>`.
    ///
    /// A config file spells a policy as one word, so one word is what parses. `regenerate`
    /// with no count means [`DEFAULT_ATTEMPTS`]; `regenerate:0` is refused rather than
    /// silently treated as `annotate`, because an operator who typed it meant something.
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let s = s.trim().to_ascii_lowercase();
        let (head, count) = match s.split_once(':') {
            Some((h, c)) => (h.trim().to_string(), Some(c.trim().to_string())),
            None => (s, None),
        };
        match head.as_str() {
            "off" | "none" => Ok(StylePolicy::Off),
            "annotate" => Ok(StylePolicy::Annotate),
            "regenerate" => {
                let max_attempts = match count {
                    None => DEFAULT_ATTEMPTS,
                    Some(c) => c
                        .parse::<u8>()
                        .map_err(|_| format!("`{c}` is not an attempt count"))?,
                };
                if max_attempts == 0 {
                    return Err("regenerate needs at least one attempt".to_string());
                }
                Ok(StylePolicy::Regenerate { max_attempts })
            }
            other => Err(format!(
                "`{other}` is not a style policy (off, annotate, regenerate, regenerate:<n>)"
            )),
        }
    }
}

/// What [`apply`] settled on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Applied {
    /// The text to deliver.
    pub text: String,
    /// How many EXTRA assistant turns were spent. Zero under every policy but
    /// [`StylePolicy::Regenerate`], and zero under that one when the first reply was clean.
    pub attempts: u8,
    /// The report on `text` — the report on the LAST thing generated, not on the first.
    pub final_report: StyleReport,
}

/// Apply a policy to a checked reply.
///
/// `regenerate` is handed the report and asked for one more assistant turn. It returns
/// `None` when it could not produce one (the loop failed, the budget is gone, the turn was
/// cancelled), and `None` STOPS the loop with what is already in hand: a regeneration that
/// failed must never erase an answer that exists. That is the one place this signature
/// departs from a plain future of a string, and it is why.
pub async fn apply<F, Fut>(
    policy: StylePolicy,
    pack: &PersonaPack,
    text: String,
    report: StyleReport,
    regenerate: F,
) -> Applied
where
    F: Fn(&StyleReport) -> Fut,
    Fut: Future<Output = Option<String>>,
{
    let max_attempts = match policy {
        // Both deliver the model's own text. `Off` should not have been checked at all, and
        // a caller that checked anyway gets its report back rather than a lie about it.
        StylePolicy::Off | StylePolicy::Annotate => {
            return Applied {
                text,
                attempts: 0,
                final_report: report,
            }
        }
        StylePolicy::Regenerate { max_attempts } => max_attempts,
    };

    let mut text = text;
    let mut report = report;
    let mut attempts = 0u8;
    while !report.is_clean() && attempts < max_attempts {
        let Some(next) = regenerate(&report).await else {
            break;
        };
        attempts += 1;
        report = check(&next, pack);
        text = next;
    }
    Applied {
        text,
        attempts,
        final_report: report,
    }
}

/// The user message that asks for the rewrite.
///
/// **IT NEVER QUOTES THE MODEL'S OWN TEXT BACK.** Listing the offending phrases would put
/// every banned phrase the model just used into the prompt for the turn that is supposed to
/// avoid them, which is the most reliable way to get them used again. So the request names
/// the RULES that were broken, by the pattern source the owner wrote, with a count, and says
/// plainly not to reuse the previous wording.
///
/// A pattern source is configuration rather than model output, so it is safe to send; that is
/// the same reason a [`Hit`] may carry it.
pub fn regeneration_request(report: &StyleReport, pack: &PersonaPack) -> String {
    let mut rules: Vec<String> = Vec::new();
    for (source, n) in report.by_pattern() {
        rules.push(format!(
            "the banned pattern `{source}` ({} {})",
            n,
            times(n)
        ));
    }
    if report.dash_hits > 0 {
        rules.push(format!(
            "an em dash, an en dash or a double hyphen ({} {})",
            report.dash_hits,
            times(report.dash_hits)
        ));
    }
    if report.list_hits > 0 {
        rules.push(format!(
            "a bullet or numbered list, which you were asked not to use ({} {})",
            report.list_hits,
            lines_word(report.list_hits)
        ));
    }
    if report.heading_hits > 0 {
        rules.push(format!(
            "a heading, which you were asked not to use ({} {})",
            report.heading_hits,
            lines_word(report.heading_hits)
        ));
    }
    let owner = &pack.owner.name;
    format!(
        "That answer broke rules {owner} gave you. Write the same answer again, saying the \
         same things, without breaking them. What it used:\n{}\n\nDo not reuse the wording of \
         the parts that broke a rule; write those parts again from scratch. Reply with the \
         rewritten answer and nothing else.",
        rules
            .iter()
            .enumerate()
            .map(|(i, r)| format!("{}. {r}", i + 1))
            .collect::<Vec<_>>()
            .join("\n")
    )
}

fn times(n: usize) -> &'static str {
    if n == 1 {
        "time"
    } else {
        "times"
    }
}

fn lines_word(n: usize) -> &'static str {
    if n == 1 {
        "line"
    } else {
        "lines"
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::fully_populated;
    use super::*;

    fn pack_with(patterns: &[&str]) -> PersonaPack {
        PersonaPack {
            banned_patterns: patterns
                .iter()
                .map(|p| Pattern::new(*p).expect("compiles"))
                .collect(),
            ..PersonaPack::default()
        }
    }

    #[test]
    fn a_clean_reply_reports_nothing() {
        let pack = fully_populated();
        let report = check(
            "The archive is fine. Nothing in it needs your attention today.",
            &pack,
        );
        assert!(report.is_clean(), "{report:?}");
        assert_eq!(report.total(), 0);
    }

    #[test]
    fn every_dash_variant_is_caught() {
        let pack = PersonaPack::default();
        let report = check(
            "one \u{2014} two\nthree \u{2013} four\nfive -- six\nseven - eight",
            &pack,
        );
        // Em, en, double hyphen. A single hyphen is a hyphen and is not a variant.
        assert_eq!(report.dash_hits, 3);
        assert!(report.hits.is_empty());
    }

    #[test]
    fn dashes_are_allowed_when_the_pack_allows_them() {
        let pack = PersonaPack {
            formatting: FormattingParams {
                dashes: Dashes::Allowed,
                ..FormattingParams::default()
            },
            ..PersonaPack::default()
        };
        assert_eq!(check("one \u{2014} two -- three", &pack).dash_hits, 0);
    }

    #[test]
    fn inline_code_and_fenced_blocks_are_exempt_from_the_dash_rule() {
        let pack = PersonaPack::default();
        let text = "Run `grep --color` first.\n\n```sh\ncargo test -- --nocapture\n```\n\nThen \
                    stop \u{2014} really.";
        let report = check(text, &pack);
        // Only the em dash in the prose line counts.
        assert_eq!(report.dash_hits, 1);
    }

    #[test]
    fn a_pattern_list_in_the_draft_lint_format_is_applied_case_insensitively() {
        // The fixture is in the draft-lint file format: comments, blank lines, one regex per
        // line. No list from anywhere else is copied in.
        let (patterns, warnings) = parse_pattern_file(
            "# fixture list\n\n\\bdelve\\b\n\\btapestry\\b\nstands as a testament to\n",
        );
        assert!(warnings.is_empty());
        let pack = PersonaPack {
            banned_patterns: patterns,
            ..PersonaPack::default()
        };
        let report = check(
            "Let us Delve in.\nIt stands as a testament to nothing.\nA delve, and a delve.",
            &pack,
        );
        assert_eq!(report.hits.len(), 4);
        assert_eq!(report.hits[0].line, 1);
        assert_eq!(report.hits[0].pattern_source, "\\bdelve\\b");
        assert_eq!(report.hits[0].excerpt_len, 5);
        assert_eq!(report.hits[1].line, 2);
        assert_eq!(report.hits[1].pattern_source, "stands as a testament to");
        assert_eq!(report.hits[2].line, 3);
        assert_eq!(report.hits[3].line, 3);
        assert_eq!(
            report.by_pattern(),
            vec![("\\bdelve\\b", 3), ("stands as a testament to", 1)]
        );
    }

    #[test]
    fn the_report_carries_no_excerpt_text() {
        let pack = pack_with(&["\\bsecretword\\b"]);
        let report = check("a line with secretword in it", &pack);
        assert_eq!(report.hits.len(), 1);
        let json = serde_json::to_string(&report).expect("serialises");
        assert!(!json.contains("a line with"), "{json}");
        assert!(
            json.contains("secretword"),
            "the PATTERN is config, and is named: {json}"
        );
        assert_eq!(report.hits[0].excerpt_len, 10);
    }

    #[test]
    fn lists_and_headings_are_counted_only_when_avoided() {
        let text = "## A heading\n\n- one\n- two\n1. three\n\nprose\n\n```\n# not a heading\n- not a list\n```";
        let avoid = PersonaPack {
            formatting: FormattingParams {
                lists: Lists::Avoid,
                headings: Headings::Avoid,
                dashes: Dashes::Allowed,
            },
            ..PersonaPack::default()
        };
        let report = check(text, &avoid);
        assert_eq!(report.heading_hits, 1);
        assert_eq!(report.list_hits, 3);

        let allowed = PersonaPack {
            formatting: FormattingParams {
                lists: Lists::Freely,
                headings: Headings::Freely,
                dashes: Dashes::Allowed,
            },
            ..PersonaPack::default()
        };
        let report = check(text, &allowed);
        assert_eq!(report.heading_hits, 0);
        assert_eq!(report.list_hits, 0);
    }

    #[test]
    fn policies_parse_and_print() {
        use std::str::FromStr;
        assert_eq!(StylePolicy::from_str("off"), Ok(StylePolicy::Off));
        assert_eq!(
            StylePolicy::from_str(" Annotate "),
            Ok(StylePolicy::Annotate)
        );
        assert_eq!(
            StylePolicy::from_str("regenerate"),
            Ok(StylePolicy::Regenerate {
                max_attempts: DEFAULT_ATTEMPTS
            })
        );
        assert_eq!(
            StylePolicy::from_str("regenerate:3"),
            Ok(StylePolicy::Regenerate { max_attempts: 3 })
        );
        assert!(StylePolicy::from_str("regenerate:0").is_err());
        assert!(StylePolicy::from_str("shout").is_err());
        assert_eq!(StylePolicy::default(), StylePolicy::Annotate);
        assert_eq!(
            StylePolicy::Regenerate { max_attempts: 2 }.to_string(),
            "regenerate:2"
        );
    }

    /// A tiny runtime, so the async `apply` can be exercised without pulling a test harness
    /// into the crate's dependency set.
    fn block_on<F: Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .build()
            .expect("runtime")
            .block_on(f)
    }

    #[test]
    fn annotate_delivers_the_model_text_and_the_report() {
        let pack = PersonaPack::default();
        let text = "one \u{2014} two".to_string();
        let report = check(&text, &pack);
        let applied = block_on(apply(
            StylePolicy::Annotate,
            &pack,
            text.clone(),
            report,
            |_| async { panic!("annotate must never regenerate") },
        ));
        assert_eq!(applied.text, text);
        assert_eq!(applied.attempts, 0);
        assert_eq!(applied.final_report.dash_hits, 1);
    }

    #[test]
    fn regenerate_retries_until_clean_and_reports_on_the_last_text() {
        let pack = PersonaPack::default();
        let text = "one \u{2014} two".to_string();
        let report = check(&text, &pack);
        let calls = std::cell::Cell::new(0usize);
        let applied = block_on(apply(
            StylePolicy::Regenerate { max_attempts: 3 },
            &pack,
            text,
            report,
            |r| {
                calls.set(calls.get() + 1);
                // The request names the rule, never the model's own words.
                assert!(regeneration_request(r, &pack).contains("an em dash"));
                async move { Some("one, two".to_string()) }
            },
        ));
        assert_eq!(applied.text, "one, two");
        assert_eq!(applied.attempts, 1);
        assert!(applied.final_report.is_clean());
        assert_eq!(calls.get(), 1, "a clean rewrite stops the loop");
    }

    #[test]
    fn regenerate_stops_at_the_cap_and_annotates_what_it_has() {
        let pack = PersonaPack::default();
        let text = "one \u{2014} two".to_string();
        let report = check(&text, &pack);
        let calls = std::cell::Cell::new(0usize);
        let applied = block_on(apply(
            StylePolicy::Regenerate { max_attempts: 2 },
            &pack,
            text,
            report,
            |_| {
                calls.set(calls.get() + 1);
                let n = calls.get();
                async move { Some(format!("still \u{2014} bad {n}")) }
            },
        ));
        assert_eq!(calls.get(), 2);
        assert_eq!(applied.attempts, 2);
        assert_eq!(applied.text, "still \u{2014} bad 2");
        assert_eq!(applied.final_report.dash_hits, 1);
    }

    #[test]
    fn a_regeneration_that_fails_keeps_the_answer_that_exists() {
        let pack = PersonaPack::default();
        let text = "one \u{2014} two".to_string();
        let report = check(&text, &pack);
        let applied = block_on(apply(
            StylePolicy::Regenerate { max_attempts: 2 },
            &pack,
            text.clone(),
            report,
            |_| async { None },
        ));
        assert_eq!(applied.text, text);
        assert_eq!(applied.attempts, 0);
        assert_eq!(applied.final_report.dash_hits, 1);
    }

    #[test]
    fn a_clean_first_reply_is_never_regenerated() {
        let pack = PersonaPack::default();
        let text = "one, two".to_string();
        let report = check(&text, &pack);
        let applied = block_on(apply(
            StylePolicy::Regenerate { max_attempts: 3 },
            &pack,
            text.clone(),
            report,
            |_| async { panic!("a clean reply must never be regenerated") },
        ));
        assert_eq!(applied.text, text);
        assert_eq!(applied.attempts, 0);
    }

    #[test]
    fn the_regeneration_request_lists_rules_and_never_the_text() {
        let pack = PersonaPack {
            banned_patterns: vec![Pattern::new("\\bdelve\\b").expect("compiles")],
            formatting: FormattingParams {
                lists: Lists::Avoid,
                headings: Headings::Avoid,
                dashes: Dashes::Forbidden,
            },
            ..PersonaPack::default()
        };
        let reply = "Let us delve \u{2014} into the tapestry.\n- and a bullet";
        let report = check(reply, &pack);
        assert_eq!(report.hits.len(), 1);
        assert_eq!(report.dash_hits, 1);
        assert_eq!(report.list_hits, 1);
        let msg = regeneration_request(&report, &pack);
        assert!(
            msg.contains("the banned pattern `\\bdelve\\b` (1 time)"),
            "{msg}"
        );
        assert!(
            msg.contains("an em dash, an en dash or a double hyphen (1 time)"),
            "{msg}"
        );
        assert!(msg.contains("a bullet or numbered list"), "{msg}");
        // THE PROPERTY: none of the model's own wording is quoted back into the prompt.
        for fragment in ["Let us", "tapestry", "and a bullet"] {
            assert!(!msg.contains(fragment), "`{fragment}` leaked into: {msg}");
        }
    }
}
