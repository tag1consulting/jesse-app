//! The `judge` subcommand: pairwise LLM-as-judge comparison of a candidate run
//! against a baseline run, per judged task, with both orderings to counter
//! position bias.

use crate::runner::RunReport;
use crate::transcript;
use serde::Serialize;
use std::io::{BufReader, Read};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

/// A single judge verdict.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Verdict {
    /// Answer 1 is better.
    One,
    /// Answer 2 is better.
    Two,
    Tie,
}

/// Who won a task after combining both orderings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Outcome {
    Baseline,
    Candidate,
    Tie,
}

/// Combine the two ordering verdicts into a task outcome.
///
/// * Call 1 presents **baseline as Answer 1, candidate as Answer 2**.
/// * Call 2 presents **candidate as Answer 1, baseline as Answer 2** (swapped).
///
/// The candidate wins the task only if it wins BOTH orderings; the baseline
/// likewise. Any disagreement records as a TIE.
pub fn decide(call1: Verdict, call2: Verdict) -> Outcome {
    let cand_wins_1 = call1 == Verdict::Two; // candidate was Answer 2
    let cand_wins_2 = call2 == Verdict::One; // candidate was Answer 1
    let base_wins_1 = call1 == Verdict::One;
    let base_wins_2 = call2 == Verdict::Two;
    if cand_wins_1 && cand_wins_2 {
        Outcome::Candidate
    } else if base_wins_1 && base_wins_2 {
        Outcome::Baseline
    } else {
        Outcome::Tie
    }
}

/// Parse a judge response into a verdict. Looks for `VERDICT: 1|2|TIE`, then
/// falls back to a lone token. Returns `None` if nothing parseable is found.
pub fn parse_verdict(text: &str) -> Option<Verdict> {
    let re = regex::Regex::new(r"(?i)verdict\s*[:\-]?\s*(1|2|tie)").unwrap();
    if let Some(c) = re.captures(text) {
        return Some(match &c[1].to_lowercase()[..] {
            "1" => Verdict::One,
            "2" => Verdict::Two,
            _ => Verdict::Tie,
        });
    }
    // Fallback: first standalone 1/2/TIE anywhere.
    let re2 = regex::Regex::new(r"(?i)\b(1|2|tie)\b").unwrap();
    re2.captures(text).map(|c| match &c[1].to_lowercase()[..] {
        "1" => Verdict::One,
        "2" => Verdict::Two,
        _ => Verdict::Tie,
    })
}

/// Build the judge prompt for one ordering.
pub fn judge_prompt(rubric: &str, answer1: &str, answer2: &str) -> String {
    format!(
        "You are grading two answers to the same task against a rubric. Grade ONLY \
content accuracy and instruction-following. Explicitly IGNORE answer length, \
verbosity, and stylistic polish — a longer or more elaborate answer is NOT better \
for that reason alone.\n\n\
RUBRIC:\n{rubric}\n\n\
=== ANSWER 1 ===\n{answer1}\n=== END ANSWER 1 ===\n\n\
=== ANSWER 2 ===\n{answer2}\n=== END ANSWER 2 ===\n\n\
Decide which answer better satisfies the rubric. Reply on the FIRST line with \
exactly `VERDICT: 1`, `VERDICT: 2`, or `VERDICT: TIE`, then on the next line one \
sentence of reasoning. Nothing else."
    )
}

/// One judged task's full record.
#[derive(Debug, Clone, Serialize)]
pub struct TaskJudgment {
    pub id: String,
    pub class: String,
    /// Verdict with baseline=Answer1, candidate=Answer2.
    pub call1: Option<String>,
    /// Verdict with candidate=Answer1, baseline=Answer2 (swapped).
    pub call2: Option<String>,
    pub outcome: Outcome,
    pub reasoning1: String,
    pub reasoning2: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct JudgmentReport {
    pub baseline_dir: String,
    pub candidate_dir: String,
    pub tasks: Vec<TaskJudgment>,
    pub candidate_wins: u32,
    pub baseline_wins: u32,
    pub ties: u32,
}

/// Read a run's `results.json`.
fn load_report(dir: &Path) -> Result<RunReport, String> {
    let path = dir.join("results.json");
    let bytes = std::fs::read(&path)
        .map_err(|e| format!("could not read {}: {e}", path.display()))?;
    serde_json::from_slice(&bytes).map_err(|e| format!("invalid results.json in {}: {e}", dir.display()))
}

/// Run one judge call via `claude` with NO env overrides (ambient auth + default
/// model) and no tools. Returns the final answer text.
fn run_judge_call(claude_bin: &str, prompt: &str, timeout: Duration) -> Result<String, String> {
    let mut child = Command::new(claude_bin)
        .arg("-p")
        .arg(prompt)
        .arg("--output-format")
        .arg("stream-json")
        .arg("--verbose")
        .arg("--permission-mode")
        .arg("default")
        .arg("--allowedTools")
        .arg("")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to spawn '{claude_bin}': {e}"))?;

    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");
    let err_handle = thread::spawn(move || {
        let mut s = String::new();
        let _ = BufReader::new(stderr).read_to_string(&mut s);
        s
    });
    let (tx, rx) = mpsc::channel::<String>();
    let out_handle = thread::spawn(move || {
        let mut s = String::new();
        let _ = BufReader::new(stdout).read_to_string(&mut s);
        let _ = tx.send(s);
    });

    let raw = match rx.recv_timeout(timeout) {
        Ok(s) => s,
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            let _ = out_handle.join();
            return Err(format!("judge call timed out after {}s", timeout.as_secs()));
        }
    };
    let _ = child.wait();
    let _ = out_handle.join();

    let lines: Vec<String> = raw.lines().map(|l| l.to_string()).collect();
    let parsed = transcript::parse(&lines);
    parsed.final_answer.ok_or_else(|| {
        let e = err_handle.join().unwrap_or_default();
        format!("judge produced no answer; stderr: {}", e.lines().rev().take(4).collect::<Vec<_>>().join(" | "))
    })
}

/// Run the full judge comparison.
pub fn judge(
    baseline_dir: &Path,
    candidate_dir: &Path,
    out_dir: &Path,
    claude_bin: &str,
    timeout: Duration,
) -> Result<JudgmentReport, String> {
    let base = load_report(baseline_dir)?;
    let cand = load_report(candidate_dir)?;
    std::fs::create_dir_all(out_dir).map_err(|e| format!("could not create out dir: {e}"))?;

    // Index candidate judged tasks by id for lookup.
    let mut tasks = Vec::new();
    let (mut cw, mut bw, mut tie) = (0u32, 0u32, 0u32);

    for bt in base.tasks.iter().filter(|t| t.judged) {
        let ct = match cand.tasks.iter().find(|c| c.id == bt.id && c.judged) {
            Some(c) => c,
            None => continue, // must be present in both
        };
        let rubric = bt.rubric.clone().unwrap_or_default();
        let a_base = bt.final_answer.clone().unwrap_or_default();
        let a_cand = ct.final_answer.clone().unwrap_or_default();

        // Call 1: baseline = Answer 1, candidate = Answer 2.
        let r1 = run_judge_call(claude_bin, &judge_prompt(&rubric, &a_base, &a_cand), timeout);
        // Call 2: swapped — candidate = Answer 1, baseline = Answer 2.
        let r2 = run_judge_call(claude_bin, &judge_prompt(&rubric, &a_cand, &a_base), timeout);

        let (v1, reasoning1) = split_verdict(&r1);
        let (v2, reasoning2) = split_verdict(&r2);

        // If either call failed to produce a parseable verdict, record a TIE.
        let outcome = match (v1, v2) {
            (Some(a), Some(b)) => decide(a, b),
            _ => Outcome::Tie,
        };
        match outcome {
            Outcome::Candidate => cw += 1,
            Outcome::Baseline => bw += 1,
            Outcome::Tie => tie += 1,
        }
        tasks.push(TaskJudgment {
            id: bt.id.clone(),
            class: bt.class.clone(),
            call1: v1.map(|v| format!("{v:?}")),
            call2: v2.map(|v| format!("{v:?}")),
            outcome,
            reasoning1,
            reasoning2,
        });
    }

    let report = JudgmentReport {
        baseline_dir: baseline_dir.display().to_string(),
        candidate_dir: candidate_dir.display().to_string(),
        tasks,
        candidate_wins: cw,
        baseline_wins: bw,
        ties: tie,
    };

    std::fs::write(
        out_dir.join("judgment.json"),
        serde_json::to_string_pretty(&report).map_err(|e| e.to_string())?,
    )
    .map_err(|e| format!("could not write judgment.json: {e}"))?;
    std::fs::write(out_dir.join("judgment.md"), judgment_md(&report))
        .map_err(|e| format!("could not write judgment.md: {e}"))?;

    Ok(report)
}

/// From a judge-call result (Ok(text) or Err(msg)), extract verdict + one-line
/// reasoning. A failed call yields `(None, <error>)`.
fn split_verdict(r: &Result<String, String>) -> (Option<Verdict>, String) {
    match r {
        Err(e) => (None, format!("(judge call failed: {e})")),
        Ok(text) => {
            let v = parse_verdict(text);
            // First non-verdict, non-empty line as the reasoning.
            let reasoning = text
                .lines()
                .map(|l| l.trim())
                .find(|l| !l.is_empty() && !l.to_lowercase().starts_with("verdict"))
                .unwrap_or("")
                .to_string();
            (v, reasoning)
        }
    }
}

fn judgment_md(r: &JudgmentReport) -> String {
    let mut out = String::new();
    out.push_str("# Judgment\n\n");
    out.push_str(&format!("Baseline: `{}`\n\n", r.baseline_dir));
    out.push_str(&format!("Candidate: `{}`\n\n", r.candidate_dir));
    out.push_str("| Task | Class | Call 1 | Call 2 (swapped) | Outcome |\n");
    out.push_str("|---|---|---|---|---|\n");
    for t in &r.tasks {
        out.push_str(&format!(
            "| {} | {} | {} | {} | **{:?}** |\n",
            t.id,
            t.class,
            t.call1.as_deref().unwrap_or("—"),
            t.call2.as_deref().unwrap_or("—"),
            t.outcome
        ));
    }
    out.push_str(&format!(
        "\n**Totals:** candidate wins {}, baseline wins {}, ties {} (of {} judged tasks).\n",
        r.candidate_wins,
        r.baseline_wins,
        r.ties,
        r.tasks.len()
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidate_wins_only_when_both_orderings_agree() {
        // Candidate is Answer2 in call1, Answer1 in call2.
        assert_eq!(decide(Verdict::Two, Verdict::One), Outcome::Candidate);
    }

    #[test]
    fn baseline_wins_only_when_both_orderings_agree() {
        // Baseline is Answer1 in call1, Answer2 in call2.
        assert_eq!(decide(Verdict::One, Verdict::Two), Outcome::Baseline);
    }

    #[test]
    fn disagreement_is_tie() {
        // Both calls pick "Answer 1": position bias, no real winner.
        assert_eq!(decide(Verdict::One, Verdict::One), Outcome::Tie);
        assert_eq!(decide(Verdict::Two, Verdict::Two), Outcome::Tie);
    }

    #[test]
    fn explicit_ties_are_ties() {
        assert_eq!(decide(Verdict::Tie, Verdict::Tie), Outcome::Tie);
        assert_eq!(decide(Verdict::Two, Verdict::Tie), Outcome::Tie);
        assert_eq!(decide(Verdict::Tie, Verdict::One), Outcome::Tie);
    }

    #[test]
    fn every_combination_is_symmetric_and_safe() {
        use Verdict::*;
        // Exhaustive truth table: a win requires agreement in both orderings.
        let cases = [One, Two, Tie];
        for &a in &cases {
            for &b in &cases {
                let o = decide(a, b);
                let cand = a == Two && b == One;
                let base = a == One && b == Two;
                if cand {
                    assert_eq!(o, Outcome::Candidate);
                } else if base {
                    assert_eq!(o, Outcome::Baseline);
                } else {
                    assert_eq!(o, Outcome::Tie);
                }
            }
        }
    }

    #[test]
    fn parses_verdicts() {
        assert_eq!(parse_verdict("VERDICT: 1\nbecause"), Some(Verdict::One));
        assert_eq!(parse_verdict("verdict: 2"), Some(Verdict::Two));
        assert_eq!(parse_verdict("VERDICT: TIE\nboth equal"), Some(Verdict::Tie));
        assert_eq!(parse_verdict("I think answer 2 is best"), Some(Verdict::Two));
        assert_eq!(parse_verdict("no digits here at all"), None);
    }
}
