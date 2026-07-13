//! The assertion engine. Pure and file-system-aware, but with no knowledge of
//! how a transcript was obtained, so it is fully unit-testable.

use crate::suite::Assertion;
use crate::transcript::Transcript;
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
        Assertion::FileEquals { .. } => "file_equals",
        Assertion::FileMatches { .. } => "file_matches",
        Assertion::MaxToolCalls { .. } => "max_tool_calls",
        Assertion::NumberInRange { .. } => "number_in_range",
        Assertion::NumbersConsistent { .. } => "numbers_consistent",
        Assertion::Completed => "completed",
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

/// Build an [`AssertionResult`] — used by the early-return error paths.
fn done(kind: String, passed: bool, detail: String) -> AssertionResult {
    AssertionResult {
        kind,
        passed,
        detail,
    }
}

/// Evaluate one assertion against a transcript and workspace directory.
pub fn eval_assertion(a: &Assertion, t: &Transcript, workspace: &Path) -> AssertionResult {
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
) -> (bool, Vec<AssertionResult>) {
    let results: Vec<AssertionResult> = assertions
        .iter()
        .map(|a| eval_assertion(a, t, workspace))
        .collect();
    let all = results.iter().all(|r| r.passed);
    (all, results)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::Transcript;

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
}
