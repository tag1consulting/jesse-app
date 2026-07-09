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
        Assertion::Completed => "completed",
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
    fn max_tool_calls_ceiling() {
        let t = tr("done", 3, true);
        let dir = std::env::temp_dir();
        assert!(eval_assertion(&Assertion::MaxToolCalls { max: 3 }, &t, &dir).passed);
        assert!(!eval_assertion(&Assertion::MaxToolCalls { max: 2 }, &t, &dir).passed);
        assert!(eval_assertion(&Assertion::MaxToolCalls { max: 0 }, &tr("x", 0, true), &dir).passed);
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
        assert!(eval_assertion(
            &Assertion::FileEquals {
                path: "log.csv".into(),
                content: "date,item\n2026-07-09,apple\n".into(),
            },
            &t,
            dir.path()
        )
        .passed);
        assert!(!eval_assertion(
            &Assertion::FileEquals {
                path: "log.csv".into(),
                content: "different".into(),
            },
            &t,
            dir.path()
        )
        .passed);
        assert!(eval_assertion(
            &Assertion::FileMatches {
                path: "log.csv".into(),
                pattern: r"2026-07-09,apple".into(),
            },
            &t,
            dir.path()
        )
        .passed);
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
