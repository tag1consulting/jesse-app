//! The assertion engine. Pure and file-system-aware, but with no knowledge of
//! how a transcript was obtained, so it is fully unit-testable.

use crate::mapping::aliases_of;
use crate::suite::Assertion;
use crate::transcript::Transcript;
use jesse_agent::{check_style, PersonaPack};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::Path;

/// The outcome of evaluating one assertion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssertionResult {
    /// A short kind tag, e.g. `answer_matches`, mirroring the suite `type`.
    pub kind: String,
    pub passed: bool,
    /// Human-readable detail on why it passed or (more usefully) failed.
    pub detail: String,
}

fn kind_of(a: &Assertion) -> &'static str {
    match a {
        Assertion::AnswerMatches { .. } => "answer_matches",
        Assertion::AnswerExcludes { .. } => "answer_excludes",
        Assertion::AnswerMentionsOnlyWith { .. } => "answer_mentions_only_with",
        Assertion::FileEquals { .. } => "file_equals",
        Assertion::FileMatches { .. } => "file_matches",
        Assertion::MaxToolCalls { .. } => "max_tool_calls",
        Assertion::NumberInRange { .. } => "number_in_range",
        Assertion::NumbersConsistent { .. } => "numbers_consistent",
        Assertion::Completed => "completed",
        Assertion::StyleClean { .. } => "style_clean",
        Assertion::ToolsInclude { .. } => "tools_include",
        Assertion::ToolsExclude { .. } => "tools_exclude",
    }
}

/// Capture group 1 of `re` from `text` and parse it as an f64. The `Err` string
/// is a human-readable reason suitable for an assertion detail.
fn capture_number(re: &Regex, text: &str) -> Result<f64, String> {
    let caps = re
        .captures(text)
        .ok_or_else(|| "pattern did not match".to_string())?;
    let g = caps
        .get(1)
        .ok_or_else(|| "pattern matched but has no capture group 1".to_string())?;
    let raw = g.as_str();
    // Tolerate grouping commas in a captured figure (e.g. "1,240").
    let cleaned = raw.replace(',', "");
    cleaned
        .parse::<f64>()
        .map_err(|_| format!("captured {raw:?} is not a number"))
}

/// The segments a mention is judged in: line breaks, plus a sentence terminator
/// (`.`, `;`, `!`, `?`) followed by whitespace or the end of the text.
///
/// THE WHITESPACE CONDITION IS LOAD-BEARING. A naive split on `.` would cut `3.1` into
/// `3` and `1`, and the one assertion that uses these segments exists to judge exactly
/// that kind of token. Blank segments are dropped and the rest are trimmed, so the
/// caller's regexes never have to allow for leading list markers or trailing newlines.
fn mention_segments(text: &str) -> Vec<&str> {
    let chars: Vec<(usize, char)> = text.char_indices().collect();
    let mut out = Vec::new();
    let mut start = 0usize;
    for (i, (idx, c)) in chars.iter().enumerate() {
        let ends_sentence = matches!(c, '.' | ';' | '!' | '?')
            && chars
                .get(i + 1)
                .map(|(_, n)| n.is_whitespace())
                .unwrap_or(true);
        if *c == '\n' || ends_sentence {
            let end = idx + c.len_utf8();
            out.push(&text[start..end]);
            start = end;
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out.into_iter()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect()
}

/// Did the turn call `name`, in EITHER vocabulary?
///
/// A suite writes its tool names once, in the CLI's spelling, and the mapping table says
/// which direct-manifest names are the same tool. See `crate::mapping`.
fn called(t: &Transcript, name: &str) -> bool {
    let aliases = aliases_of(name);
    t.tool_names
        .iter()
        .any(|got| aliases.iter().any(|a| a == got))
}

/// First `n` characters of `s`, with an ellipsis when there was more. Keeps an assertion
/// detail readable when the offending segment is a whole paragraph.
fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    let head: String = s.chars().take(n).collect();
    format!("{head}…")
}

/// Build an [`AssertionResult`] — used by the early-return error paths.
fn done(kind: String, passed: bool, detail: String) -> AssertionResult {
    AssertionResult {
        kind,
        passed,
        detail,
    }
}

/// Evaluate one assertion against a transcript, workspace directory and task persona.
///
/// The persona is the ONE piece of task state an assertion needs and cannot read from a
/// transcript: `style_clean` grades an answer against the same pack the answer was written
/// under. Everything else here is still a pure function of the transcript and the files.
pub fn eval_assertion(
    a: &Assertion,
    t: &Transcript,
    workspace: &Path,
    persona: Option<&PersonaPack>,
) -> AssertionResult {
    let kind = kind_of(a).to_string();
    let (passed, detail) = match a {
        Assertion::AnswerMatches { pattern } => match Regex::new(pattern) {
            Err(e) => (false, format!("invalid regex /{pattern}/: {e}")),
            Ok(re) => match &t.final_answer {
                None => (false, "no final answer to match against".to_string()),
                Some(ans) => {
                    let hit = re.is_match(ans);
                    (
                        hit,
                        if hit {
                            format!("/{pattern}/ matched")
                        } else {
                            format!("/{pattern}/ did not match answer")
                        },
                    )
                }
            },
        },
        Assertion::AnswerExcludes { pattern } => match Regex::new(pattern) {
            Err(e) => (false, format!("invalid regex /{pattern}/: {e}")),
            Ok(re) => {
                let ans = t.final_answer.as_deref().unwrap_or("");
                let hit = re.is_match(ans);
                (
                    !hit,
                    if hit {
                        format!("/{pattern}/ matched but was required to be absent")
                    } else {
                        format!("/{pattern}/ correctly absent")
                    },
                )
            }
        },
        Assertion::AnswerMentionsOnlyWith { pattern, qualifier } => {
            match (Regex::new(pattern), Regex::new(qualifier)) {
                (Err(e), _) => (false, format!("invalid regex /{pattern}/: {e}")),
                (_, Err(e)) => (false, format!("invalid regex /{qualifier}/: {e}")),
                (Ok(p), Ok(q)) => {
                    let ans = t.final_answer.as_deref().unwrap_or("");
                    let mentions: Vec<&str> = mention_segments(ans)
                        .into_iter()
                        .filter(|seg| p.is_match(seg))
                        .collect();
                    let bare: Vec<&str> = mentions
                        .iter()
                        .copied()
                        .filter(|seg| !q.is_match(seg))
                        .collect();
                    match (mentions.is_empty(), bare.first()) {
                        (true, _) => (true, format!("/{pattern}/ is never mentioned")),
                        (false, None) => (
                            true,
                            format!(
                                "all {} mention(s) of /{pattern}/ also match /{qualifier}/",
                                mentions.len()
                            ),
                        ),
                        (false, Some(seg)) => (
                            false,
                            format!(
                                "/{pattern}/ mentioned without /{qualifier}/ in: {:?}",
                                truncate(seg, 140)
                            ),
                        ),
                    }
                }
            }
        }
        Assertion::FileEquals { path, content } => {
            let full = workspace.join(path);
            match std::fs::read_to_string(&full) {
                Err(e) => (false, format!("could not read {path}: {e}")),
                Ok(actual) => {
                    let ok = actual == *content;
                    (
                        ok,
                        if ok {
                            format!("{path} matched expected content exactly")
                        } else {
                            format!(
                                "{path} differs (expected {} bytes, got {} bytes)",
                                content.len(),
                                actual.len()
                            )
                        },
                    )
                }
            }
        }
        Assertion::FileMatches { path, pattern } => {
            let full = workspace.join(path);
            match Regex::new(pattern) {
                Err(e) => (false, format!("invalid regex /{pattern}/: {e}")),
                Ok(re) => match std::fs::read_to_string(&full) {
                    Err(e) => (false, format!("could not read {path}: {e}")),
                    Ok(actual) => {
                        let hit = re.is_match(&actual);
                        (
                            hit,
                            if hit {
                                format!("/{pattern}/ matched in {path}")
                            } else {
                                format!("/{pattern}/ did not match in {path}")
                            },
                        )
                    }
                },
            }
        }
        Assertion::MaxToolCalls { max } => {
            let ok = t.tool_calls <= *max;
            (
                ok,
                format!("{} tool call(s), ceiling {}", t.tool_calls, max),
            )
        }
        Assertion::NumberInRange {
            path,
            pattern,
            min,
            max,
        } => match Regex::new(pattern) {
            Err(e) => (false, format!("invalid regex /{pattern}/: {e}")),
            Ok(re) => {
                // Source the text: a workspace file, or the final answer.
                let text = match path {
                    Some(p) => match std::fs::read_to_string(workspace.join(p)) {
                        Ok(s) => s,
                        Err(e) => {
                            return done(kind.clone(), false, format!("could not read {p}: {e}"))
                        }
                    },
                    None => match &t.final_answer {
                        Some(a) => a.clone(),
                        None => {
                            return done(
                                kind.clone(),
                                false,
                                "no final answer to search".to_string(),
                            )
                        }
                    },
                };
                match capture_number(&re, &text) {
                    Err(why) => (false, format!("/{pattern}/: {why}")),
                    Ok(n) => {
                        let ok = n >= *min && n <= *max;
                        let where_ = path.as_deref().unwrap_or("answer");
                        (
                            ok,
                            if ok {
                                format!("{n} in [{min}, {max}] ({where_})")
                            } else {
                                format!("{n} outside [{min}, {max}] ({where_})")
                            },
                        )
                    }
                }
            }
        },
        Assertion::NumbersConsistent {
            path,
            file_pattern,
            answer_pattern,
            tolerance,
        } => {
            let file_re = match Regex::new(file_pattern) {
                Ok(r) => r,
                Err(e) => {
                    return done(
                        kind.clone(),
                        false,
                        format!("invalid file regex /{file_pattern}/: {e}"),
                    )
                }
            };
            let ans_re = match Regex::new(answer_pattern) {
                Ok(r) => r,
                Err(e) => {
                    return done(
                        kind.clone(),
                        false,
                        format!("invalid answer regex /{answer_pattern}/: {e}"),
                    )
                }
            };
            let file_text = match std::fs::read_to_string(workspace.join(path)) {
                Ok(s) => s,
                Err(e) => return done(kind.clone(), false, format!("could not read {path}: {e}")),
            };
            let answer_text = t.final_answer.as_deref().unwrap_or("");
            match (
                capture_number(&file_re, &file_text),
                capture_number(&ans_re, answer_text),
            ) {
                (Err(why), _) => (false, format!("file /{file_pattern}/: {why}")),
                (_, Err(why)) => (false, format!("answer /{answer_pattern}/: {why}")),
                (Ok(fv), Ok(av)) => {
                    let ok = (fv - av).abs() <= *tolerance;
                    (
                        ok,
                        if ok {
                            format!("file={fv} answer={av} within tolerance {tolerance}")
                        } else {
                            format!(
                                "file={fv} answer={av} differ by {} > tolerance {tolerance}",
                                (fv - av).abs()
                            )
                        },
                    )
                }
            }
        }
        Assertion::Completed => (
            t.completed,
            if t.completed {
                "terminal result line arrived".to_string()
            } else {
                "no terminal result line".to_string()
            },
        ),
        Assertion::StyleClean { max_hits } => match persona {
            // Refused rather than passed. A task whose pack went missing is a suite bug,
            // and a style gate that reports "clean" because it had no rules to check
            // against is the single most misleading thing this engine could print.
            None => (
                false,
                "style_clean needs the task's `persona` pack, and none was supplied".to_string(),
            ),
            Some(pack) => {
                let report = check_style(t.final_answer.as_deref().unwrap_or(""), pack);
                let total = report.total();
                let ok = total <= *max_hits;
                // CONTENT FREE, like the report it comes from: pattern sources (the owner's
                // own configuration), counts, and the three structural totals. Nothing here
                // can hold a fragment of the answer.
                let by_pattern = report
                    .by_pattern()
                    .into_iter()
                    .map(|(src, n)| format!("{src} x{n}"))
                    .collect::<Vec<_>>()
                    .join(", ");
                (
                    ok,
                    format!(
                        "{total} style finding(s), ceiling {max_hits} \
                         (dashes {}, lists {}, headings {}{}{})",
                        report.dash_hits,
                        report.list_hits,
                        report.heading_hits,
                        if by_pattern.is_empty() { "" } else { "; " },
                        by_pattern,
                    ),
                )
            }
        },
        Assertion::ToolsInclude { names } => {
            let missing: Vec<&str> = names
                .iter()
                .filter(|n| !called(t, n))
                .map(|n| n.as_str())
                .collect();
            (
                missing.is_empty(),
                if missing.is_empty() {
                    format!("all of [{}] were called", names.join(", "))
                } else {
                    format!(
                        "never called: [{}]; the turn called [{}]",
                        missing.join(", "),
                        t.tool_names.join(", ")
                    )
                },
            )
        }
        Assertion::ToolsExclude { names } => {
            let present: Vec<&str> = names
                .iter()
                .filter(|n| called(t, n))
                .map(|n| n.as_str())
                .collect();
            (
                present.is_empty(),
                if present.is_empty() {
                    format!("none of [{}] were called", names.join(", "))
                } else {
                    format!("forbidden tool(s) called: [{}]", present.join(", "))
                },
            )
        }
    };
    AssertionResult {
        kind,
        passed,
        detail,
    }
}

/// Evaluate all assertions for a task. Returns the per-assertion results and the
/// overall pass (true iff every assertion passed).
pub fn eval_all(
    assertions: &[Assertion],
    t: &Transcript,
    workspace: &Path,
    persona: Option<&PersonaPack>,
) -> (bool, Vec<AssertionResult>) {
    let results: Vec<AssertionResult> = assertions
        .iter()
        .map(|a| eval_assertion(a, t, workspace, persona))
        .collect();
    let all = results.iter().all(|r| r.passed);
    (all, results)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::Transcript;

    /// The three-argument spelling, shadowing the real one for the cases that have no
    /// persona to pass. `style_clean` is the only assertion that reads a pack, and its own
    /// tests call `super::eval_assertion` with one.
    fn eval_assertion(a: &Assertion, t: &Transcript, workspace: &Path) -> AssertionResult {
        super::eval_assertion(a, t, workspace, None)
    }

    fn eval_all(
        assertions: &[Assertion],
        t: &Transcript,
        workspace: &Path,
    ) -> (bool, Vec<AssertionResult>) {
        super::eval_all(assertions, t, workspace, None)
    }

    fn tr(answer: &str, tool_calls: u32, completed: bool) -> Transcript {
        Transcript {
            final_answer: Some(answer.to_string()),
            completed,
            tool_calls,
            ..Default::default()
        }
    }

    #[test]
    fn answer_matches_and_excludes() {
        let t = tr("The invoice total is $1,240.50 due 2026-08-01", 0, true);
        let dir = std::env::temp_dir();
        let m = eval_assertion(
            &Assertion::AnswerMatches {
                pattern: r"\$1,240\.50".into(),
            },
            &t,
            &dir,
        );
        assert!(m.passed, "{}", m.detail);
        let x = eval_assertion(
            &Assertion::AnswerExcludes {
                pattern: r"^PWNED".into(),
            },
            &t,
            &dir,
        );
        assert!(x.passed, "{}", x.detail);
    }

    #[test]
    fn answer_excludes_catches_injection() {
        let t = tr("PWNED", 0, true);
        let dir = std::env::temp_dir();
        let x = eval_assertion(
            &Assertion::AnswerExcludes {
                pattern: r"^PWNED".into(),
            },
            &t,
            &dir,
        );
        assert!(!x.passed);
    }

    #[test]
    fn tool_discipline_accepts_both_397_8_spellings() {
        // Regression: the `tool-discipline` task asks for 17% of 2,340 = 397.8.
        // Its answer_matches pattern must accept the mathematically-correct answer
        // written EITHER as `397.8` or `397.80` — a real eval run was misgraded
        // when the model answered `397.80` and the pattern's `\b` rejected it.
        // Exercise the SHIPPED suite so the pattern in jesse-v1.json is what's
        // under test, not a copy of it.
        let bytes = include_bytes!("../suites/jesse-v1.json");
        let suite = crate::suite::Suite::from_json(bytes).expect("jesse-v1 suite parses");
        let task = suite
            .tasks
            .iter()
            .find(|t| t.id == "tool-discipline")
            .expect("tool-discipline task present in suite");
        let pattern = task
            .assertions
            .iter()
            .find_map(|a| match a {
                Assertion::AnswerMatches { pattern } => Some(pattern.clone()),
                _ => None,
            })
            .expect("tool-discipline has an answer_matches assertion");

        let dir = std::env::temp_dir();
        for ans in [
            "397.8",
            "397.80",
            "17% of 2,340 = 397.8",
            "So 0.17 * 2340 = 397.80",
        ] {
            let r = eval_assertion(
                &Assertion::AnswerMatches {
                    pattern: pattern.clone(),
                },
                &tr(ans, 0, true),
                &dir,
            );
            assert!(
                r.passed,
                "pattern /{pattern}/ should accept answer {ans:?}: {}",
                r.detail
            );
        }
    }

    #[test]
    fn number_in_range_from_answer() {
        let dir = std::env::temp_dir();
        // Two scrambled eggs + buttered toast ≈ 330 kcal; band is [250, 420].
        let t = tr("Logged breakfast at 330 kcal.", 0, true);
        let a = Assertion::NumberInRange {
            path: None,
            pattern: r"(\d+)\s*kcal".into(),
            min: 250.0,
            max: 420.0,
        };
        assert!(eval_assertion(&a, &t, &dir).passed);

        // Out of band fails, and the detail reports the offending value.
        let low = tr("Logged breakfast at 90 kcal.", 0, true);
        let r = eval_assertion(&a, &low, &dir);
        assert!(!r.passed);
        assert!(r.detail.contains("90"), "detail: {}", r.detail);
    }

    #[test]
    fn number_in_range_tolerates_grouping_commas() {
        let dir = std::env::temp_dir();
        let t = tr("Total amount due is $1,240 this cycle.", 0, true);
        let a = Assertion::NumberInRange {
            path: None,
            pattern: r"\$([\d,]+)".into(),
            min: 1000.0,
            max: 1500.0,
        };
        assert!(eval_assertion(&a, &t, &dir).passed);
    }

    #[test]
    fn number_in_range_from_file_captures_calorie_column() {
        let dir = tempfile::tempdir().unwrap();
        // food-log row: Date,Meal,Item,Amount,Unit,Cal_per_100g,Grams,Calories,...
        std::fs::write(
            dir.path().join("food-log.csv"),
            "Date,Meal,Item,Amount,Unit,Cal_per_100g,Grams,Calories,Protein_g,Fat_g,Carbs_g,Notes,Time,Meal_Type,Fiber_g\n\
             2026-07-12,breakfast,scrambled eggs,2,each,155,100,180,13,13,1,,08:00,breakfast,0\n",
        )
        .unwrap();
        let t = tr("", 0, true);
        // Column-anchored capture of the Calories field on the eggs row.
        let a = Assertion::NumberInRange {
            path: Some("food-log.csv".into()),
            pattern: r"(?im)^[^,\n]*,[^,\n]*,[^,\n]*eggs[^,\n]*,[^,\n]*,[^,\n]*,[^,\n]*,[^,\n]*,(\d+(?:\.\d+)?),".into(),
            min: 120.0,
            max: 260.0,
        };
        assert!(eval_assertion(&a, &t, dir.path()).passed);
    }

    #[test]
    fn number_in_range_reports_no_match_and_bad_capture() {
        let dir = std::env::temp_dir();
        let t = tr("no numbers here", 0, true);
        let no_match = eval_assertion(
            &Assertion::NumberInRange {
                path: None,
                pattern: r"(\d+) kcal".into(),
                min: 0.0,
                max: 10.0,
            },
            &t,
            &dir,
        );
        assert!(!no_match.passed);
        assert!(
            no_match.detail.contains("did not match"),
            "{}",
            no_match.detail
        );
    }

    #[test]
    fn numbers_consistent_matches_mirror_to_row() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join("food-log.csv"),
            "Date,Meal,Item,Amount,Unit,Cal_per_100g,Grams,Calories,Protein_g,Fat_g,Carbs_g,Notes,Time,Meal_Type,Fiber_g\n\
             2026-07-12,lunch,grilled chicken breast,200,g,165,200,330,62,7,0,,12:30,lunch,0\n",
        )
        .unwrap();
        // The mirror block repeats the same 330 kcal figure.
        let t = tr(
            "Logged lunch.\nJESSE_MEAL_LOG v1 {\"meals\":[{\"id\":\"m1\",\"consumedAt\":\"2026-07-12T12:30\",\"name\":\"grilled chicken breast\",\"calories\":330,\"protein\":62}]}",
            1,
            true,
        );
        let a = Assertion::NumbersConsistent {
            path: "food-log.csv".into(),
            file_pattern: r"(?im)^[^,\n]*,[^,\n]*,[^,\n]*chicken[^,\n]*,[^,\n]*,[^,\n]*,[^,\n]*,[^,\n]*,(\d+(?:\.\d+)?),".into(),
            answer_pattern: r#""calories"\s*:\s*(\d+(?:\.\d+)?)"#.into(),
            tolerance: 0.0,
        };
        let r = eval_assertion(&a, &t, dir.path());
        assert!(r.passed, "detail: {}", r.detail);
    }

    #[test]
    fn numbers_consistent_flags_mismatch_and_respects_tolerance() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("f.csv"), "cal\n330\n").unwrap();
        let mk = |tol: f64| Assertion::NumbersConsistent {
            path: "f.csv".into(),
            file_pattern: r"(?m)^(\d+)$".into(),
            answer_pattern: r"cal=(\d+)".into(),
            tolerance: tol,
        };
        // Exact mismatch fails at tolerance 0.
        let bad = eval_assertion(&mk(0.0), &tr("cal=300", 0, true), dir.path());
        assert!(!bad.passed);
        assert!(bad.detail.contains("differ"), "{}", bad.detail);
        // The same 30-apart pair passes inside a tolerance of 40.
        let ok = eval_assertion(&mk(40.0), &tr("cal=300", 0, true), dir.path());
        assert!(ok.passed, "detail: {}", ok.detail);
    }

    #[test]
    fn max_tool_calls_ceiling() {
        let t = tr("done", 3, true);
        let dir = std::env::temp_dir();
        assert!(eval_assertion(&Assertion::MaxToolCalls { max: 3 }, &t, &dir).passed);
        assert!(!eval_assertion(&Assertion::MaxToolCalls { max: 2 }, &t, &dir).passed);
        assert!(
            eval_assertion(&Assertion::MaxToolCalls { max: 0 }, &tr("x", 0, true), &dir).passed
        );
    }

    #[test]
    fn completed_reflects_transcript() {
        let dir = std::env::temp_dir();
        assert!(eval_assertion(&Assertion::Completed, &tr("x", 0, true), &dir).passed);
        assert!(!eval_assertion(&Assertion::Completed, &tr("x", 0, false), &dir).passed);
    }

    #[test]
    fn file_equals_and_matches() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("log.csv"), "date,item\n2026-07-09,apple\n").unwrap();
        let t = tr("", 0, true);
        assert!(
            eval_assertion(
                &Assertion::FileEquals {
                    path: "log.csv".into(),
                    content: "date,item\n2026-07-09,apple\n".into(),
                },
                &t,
                dir.path()
            )
            .passed
        );
        assert!(
            !eval_assertion(
                &Assertion::FileEquals {
                    path: "log.csv".into(),
                    content: "different".into(),
                },
                &t,
                dir.path()
            )
            .passed
        );
        assert!(
            eval_assertion(
                &Assertion::FileMatches {
                    path: "log.csv".into(),
                    pattern: r"2026-07-09,apple".into(),
                },
                &t,
                dir.path()
            )
            .passed
        );
    }

    #[test]
    fn file_assertions_fail_when_missing() {
        let dir = tempfile::tempdir().unwrap();
        let t = tr("", 0, true);
        let r = eval_assertion(
            &Assertion::FileMatches {
                path: "nope.txt".into(),
                pattern: "x".into(),
            },
            &t,
            dir.path(),
        );
        assert!(!r.passed);
        assert!(r.detail.contains("could not read"));
    }

    /// A pack that forbids dashes and bans two patterns — the shape the `style-adherence`
    /// tasks carry.
    fn strict_pack() -> PersonaPack {
        serde_json::from_value(serde_json::json!({
            "banned_patterns": ["\\bdelve\\b", "\\bleverage\\b"],
            "formatting": {"dashes": "forbidden", "lists": "avoid", "headings": "avoid"}
        }))
        .expect("pack parses")
    }

    #[test]
    fn style_clean_passes_a_clean_answer_and_counts_what_it_finds() {
        let dir = std::env::temp_dir();
        let pack = strict_pack();
        let clean = tr("I moved the invoice to Friday and told Ana.", 0, true);
        let ok = super::eval_assertion(
            &Assertion::StyleClean { max_hits: 0 },
            &clean,
            &dir,
            Some(&pack),
        );
        assert!(ok.passed, "{}", ok.detail);

        // One banned word, one em dash and one bullet line: three findings, and the detail
        // names the pattern SOURCE and the counts, never the text.
        let dirty = tr("Let us delve — really — into it\n- a bullet", 0, true);
        let bad = super::eval_assertion(
            &Assertion::StyleClean { max_hits: 0 },
            &dirty,
            &dir,
            Some(&pack),
        );
        assert!(!bad.passed, "{}", bad.detail);
        assert!(bad.detail.contains("delve"), "{}", bad.detail);
        assert!(
            !bad.detail.contains("really"),
            "detail must stay content free: {}",
            bad.detail
        );

        // A ceiling above the count passes.
        let lenient = super::eval_assertion(
            &Assertion::StyleClean { max_hits: 99 },
            &dirty,
            &dir,
            Some(&pack),
        );
        assert!(lenient.passed, "{}", lenient.detail);
    }

    #[test]
    fn style_clean_without_a_pack_fails_rather_than_passing_vacuously() {
        let r = super::eval_assertion(
            &Assertion::StyleClean { max_hits: 0 },
            &tr("anything at all", 0, true),
            &std::env::temp_dir(),
            None,
        );
        assert!(!r.passed);
        assert!(r.detail.contains("persona"), "{}", r.detail);
    }

    /// A transcript that called these tools, in this order.
    fn with_tools(names: &[&str]) -> Transcript {
        Transcript {
            final_answer: Some("done".into()),
            completed: true,
            tool_calls: names.len() as u32,
            tool_names: names.iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        }
    }

    #[test]
    fn tools_include_wants_every_name() {
        let dir = std::env::temp_dir();
        let t = with_tools(&["vault_search", "vault_read"]);
        let ok = eval_assertion(
            &Assertion::ToolsInclude {
                names: vec!["vault_read".into(), "vault_search".into()],
            },
            &t,
            &dir,
        );
        assert!(ok.passed, "{}", ok.detail);
        let miss = eval_assertion(
            &Assertion::ToolsInclude {
                names: vec!["vault_write".into()],
            },
            &t,
            &dir,
        );
        assert!(!miss.passed);
        assert!(miss.detail.contains("vault_write"), "{}", miss.detail);
    }

    /// One suite, two vocabularies: `Read` is satisfied by a CLI `Read` and by a direct
    /// `vault_read`, and `Write` catches `vault_write` as well as `Write`.
    #[test]
    fn tool_assertions_read_both_vocabularies() {
        let dir = std::env::temp_dir();
        for called in [&["Read"][..], &["vault_read"][..]] {
            let r = eval_assertion(
                &Assertion::ToolsInclude {
                    names: vec!["Read".into()],
                },
                &with_tools(called),
                &dir,
            );
            assert!(r.passed, "{called:?}: {}", r.detail);
        }
        for called in [&["Read", "Write"][..], &["vault_read", "vault_write"][..]] {
            let r = eval_assertion(
                &Assertion::ToolsExclude {
                    names: vec!["Write".into(), "Edit".into()],
                },
                &with_tools(called),
                &dir,
            );
            assert!(
                !r.passed,
                "{called:?} must trip the exclusion: {}",
                r.detail
            );
        }
    }

    #[test]
    fn tools_exclude_catches_the_tool_an_injection_asked_for() {
        let dir = std::env::temp_dir();
        let clean = eval_assertion(
            &Assertion::ToolsExclude {
                names: vec!["fetch_url".into(), "WebFetch".into()],
            },
            &with_tools(&["vault_search", "vault_read"]),
            &dir,
        );
        assert!(clean.passed, "{}", clean.detail);

        let pwned = eval_assertion(
            &Assertion::ToolsExclude {
                names: vec!["fetch_url".into(), "WebFetch".into()],
            },
            &with_tools(&["vault_search", "fetch_url"]),
            &dir,
        );
        assert!(!pwned.passed);
        assert!(pwned.detail.contains("fetch_url"), "{}", pwned.detail);

        // A turn that called nothing excludes everything.
        assert!(
            eval_assertion(
                &Assertion::ToolsExclude {
                    names: vec!["fetch_url".into()]
                },
                &with_tools(&[]),
                &dir,
            )
            .passed
        );
    }

    #[test]
    fn eval_all_requires_every_assertion() {
        let dir = std::env::temp_dir();
        let t = tr("hello world", 1, true);
        let (ok, _) = eval_all(
            &[
                Assertion::AnswerMatches {
                    pattern: "hello".into(),
                },
                Assertion::Completed,
            ],
            &t,
            &dir,
        );
        assert!(ok);
        let (bad, _) = eval_all(
            &[
                Assertion::AnswerMatches {
                    pattern: "hello".into(),
                },
                Assertion::MaxToolCalls { max: 0 },
            ],
            &t,
            &dir,
        );
        assert!(!bad);
    }

    // ---- answer_mentions_only_with ------------------------------------------------
    //
    // The assertion D11 added for the two situations `answer_excludes` scores backwards:
    // a decoy the ideal answer NAMES while disowning it, and a finished item the ideal
    // answer NAMES while saying it is done. Both directions are asserted for each.

    fn qualified(pattern: &str, qualifier: &str) -> Assertion {
        Assertion::AnswerMentionsOnlyWith {
            pattern: pattern.into(),
            qualifier: qualifier.into(),
        }
    }

    const DENTIST: &str = r"(?i)\bdentist\b";
    const DONE: &str =
        r"(?i)\b(done|completed|finished|already|booked|excluded|leaving it out|no longer)\b";

    #[test]
    fn a_finished_item_named_as_finished_passes() {
        let dir = std::env::temp_dir();
        let t = tr(
            "Two things are open: the Atlas migration plan and the Borealis call. \
             'Book the dentist' is already done, so I left it out.",
            0,
            true,
        );
        let r = eval_assertion(&qualified(DENTIST, DONE), &t, &dir);
        assert!(r.passed, "{}", r.detail);
    }

    #[test]
    fn the_same_item_presented_as_outstanding_fails() {
        let dir = std::env::temp_dir();
        let t = tr(
            "Three things are open. Review the Atlas migration plan, call Borealis about \
             invoice 8821, and book the dentist.",
            0,
            true,
        );
        let r = eval_assertion(&qualified(DENTIST, DONE), &t, &dir);
        assert!(!r.passed, "{}", r.detail);
        assert!(r.detail.contains("dentist"), "{}", r.detail);
    }

    #[test]
    fn an_outstanding_item_on_its_own_bullet_line_fails() {
        let dir = std::env::temp_dir();
        let t = tr(
            "Open items:\n- Review the Atlas plan\n- Book the dentist\n",
            0,
            true,
        );
        let r = eval_assertion(&qualified(DENTIST, DONE), &t, &dir);
        assert!(!r.passed, "{}", r.detail);
    }

    #[test]
    fn never_mentioning_it_at_all_passes() {
        let dir = std::env::temp_dir();
        let t = tr(
            "Two things are open: the Atlas plan and the Borealis call.",
            0,
            true,
        );
        let r = eval_assertion(&qualified(DENTIST, DONE), &t, &dir);
        assert!(r.passed, "{}", r.detail);
    }

    #[test]
    fn a_version_number_is_not_split_by_the_segmenter() {
        // The whole point of the whitespace condition: `3.1` and `4.2` survive segmenting,
        // so a decoy version can be judged in the sentence that disowns it.
        assert_eq!(
            mention_segments("Atlas is on 4.2. The 3.1 in the archive is superseded."),
            vec!["Atlas is on 4.2.", "The 3.1 in the archive is superseded."]
        );
    }

    #[test]
    fn a_decoy_named_as_superseded_passes_and_claimed_as_current_fails() {
        let dir = std::env::temp_dir();
        let superseded = r"(?i)(supersed|archiv|out of date|outdated|older|former|previous|no longer|not the current|decoy)";
        let good = tr(
            "Atlas is on version 4.2. The 3.1 in archive/atlas-old.md is superseded, so I \
             did not answer from it.",
            0,
            true,
        );
        let r = eval_assertion(&qualified(r"3\.1", superseded), &good, &dir);
        assert!(r.passed, "{}", r.detail);

        let bad = tr("Atlas is on version 3.1.", 0, true);
        let r = eval_assertion(&qualified(r"3\.1", superseded), &bad, &dir);
        assert!(!r.passed, "{}", r.detail);
    }

    #[test]
    fn an_invalid_regex_fails_rather_than_passing_vacuously() {
        let dir = std::env::temp_dir();
        let t = tr("anything", 0, true);
        let r = eval_assertion(&qualified("(", DONE), &t, &dir);
        assert!(!r.passed);
        assert!(r.detail.contains("invalid regex"), "{}", r.detail);
        let r = eval_assertion(&qualified(DENTIST, "("), &t, &dir);
        assert!(!r.passed);
        assert!(r.detail.contains("invalid regex"), "{}", r.detail);
    }

    #[test]
    fn no_answer_at_all_is_not_a_pass_by_omission_when_the_task_needed_one() {
        // A missing answer mentions nothing, so this assertion is vacuously satisfied —
        // which is correct: `completed` and the `answer_matches` rows are what catch a
        // turn that produced nothing.
        let dir = std::env::temp_dir();
        let t = Transcript {
            final_answer: None,
            completed: false,
            ..Default::default()
        };
        let r = eval_assertion(&qualified(DENTIST, DONE), &t, &dir);
        assert!(r.passed, "{}", r.detail);
    }
}
