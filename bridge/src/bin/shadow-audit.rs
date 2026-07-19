//! `shadow-audit` — the daily judge of the opt-in shadow-comparison pipeline
//! (`JESSE_SHADOW_*`). It reads the shadow pair log, judges up to
//! `JESSE_SHADOW_JUDGE_CAP` unjudged pairs with TWO position-swapped `claude -p`
//! calls on AMBIENT hosted auth (no env overrides — judging never runs in the
//! request path), and emits a dated markdown note plus a JSON twin under
//! `~/Library/Logs/jesse-shadow-audit/`, mirroring the `vaultqa-audit` conventions.
//!
//! It is read-only over the shadow log; the shadow log stays APPEND-ONLY. Judge
//! state persists in a sidecar (`state.json`): a line-count WATERMARK so judging is
//! incremental across runs, and a judged index (turn id → outcome) so a pair is
//! never re-judged and cumulative W/L/T is derivable.
//!
//! The note reports, TRIPWIRES first: any injection-style leak in a shadow answer,
//! any shadow-child write attempt, or Fireworks spend above the daily cap — each
//! instructing the operator to disarm the triple. Then: pairs collected/judged/
//! skipped, W/L/T today and cumulative, per-side latency percentiles, measured
//! Fireworks cost vs the same turns on Opus, a judge-spend estimate, and progress
//! against the FIXED graduation criteria (printed every run so the target can't
//! drift). The audit only REPORTS — it never routes.

use std::collections::BTreeSet;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use jesse_bridge::{
    decide_pair, judge_prompt, parse_shadow_pairs, parse_verdict, percentile_ms,
    shadow_has_injection_leak, shadow_tripwires, tally_outcomes, GraduationProgress, PairOutcome,
    ShadowAuditState, ShadowPair, ShadowUsage, OPUS_IN_PER_M, OPUS_OUT_PER_M,
};

fn home() -> String {
    std::env::var("HOME").unwrap_or_default()
}

/// Today's local date (`YYYY-MM-DD`) via `date`, matching the audit convention.
fn today() -> String {
    Command::new("date")
        .env("LC_ALL", "C")
        .arg("+%Y-%m-%d")
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown-date".to_string())
}

fn env_string(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Extract `claude -p --output-format stream-json` final answer text: the terminal
/// `result` line's `result`, else the accumulated `text_delta`s.
fn final_answer_from_stream(stdout: &str) -> String {
    let mut acc = String::new();
    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        match v.get("type").and_then(|t| t.as_str()) {
            Some("result") => {
                if let Some(r) = v.get("result").and_then(|r| r.as_str()) {
                    return r.trim().to_string();
                }
            }
            Some("stream_event") => {
                let event = v.get("event");
                let is_text = event
                    .and_then(|e| e.get("delta"))
                    .and_then(|d| d.get("type"))
                    .and_then(|t| t.as_str())
                    == Some("text_delta");
                if is_text {
                    if let Some(t) = event
                        .and_then(|e| e.get("delta"))
                        .and_then(|d| d.get("text"))
                        .and_then(|t| t.as_str())
                    {
                        acc.push_str(t);
                    }
                }
            }
            _ => {}
        }
    }
    acc.trim().to_string()
}

/// Run ONE judge call via `claude` with NO env overrides (ambient auth + default
/// model) and no tools, bounded by `timeout`. Returns the final answer text, or
/// `None` on spawn failure / timeout (which the caller treats as an unparseable
/// verdict → TIE).
fn run_judge_call(claude_bin: &str, prompt: &str, timeout: Duration) -> Option<String> {
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
        .ok()?;

    let mut stdout = child.stdout.take()?;
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buf = String::new();
        let _ = stdout.read_to_string(&mut buf);
        let _ = tx.send(buf);
    });
    match rx.recv_timeout(timeout) {
        Ok(buf) => {
            let _ = child.wait();
            Some(final_answer_from_stream(&buf))
        }
        Err(_) => {
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    }
}

/// Judge one pair with the position-swapped protocol. Call 1: hosted = Answer 1,
/// shadow = Answer 2. Call 2 is swapped. The shadow wins only if it wins both.
fn judge_pair(claude_bin: &str, pair: &ShadowPair, timeout: Duration) -> PairOutcome {
    let hosted = pair.hosted_text.as_str();
    let shadow = pair.shadow_text.as_deref().unwrap_or("");
    let c1 = run_judge_call(
        claude_bin,
        &judge_prompt(&pair.question, hosted, shadow),
        timeout,
    )
    .and_then(|t| parse_verdict(&t));
    let c2 = run_judge_call(
        claude_bin,
        &judge_prompt(&pair.question, shadow, hosted),
        timeout,
    )
    .and_then(|t| parse_verdict(&t));
    decide_pair(c1, c2)
}

/// Sum shadow-side usage over pairs into one vector (for the two-deck cost compare).
fn sum_usage<'a>(pairs: impl IntoIterator<Item = &'a ShadowPair>) -> ShadowUsage {
    let mut acc = ShadowUsage::default();
    for p in pairs {
        if let Some(u) = &p.shadow_usage {
            *acc.input_tokens.get_or_insert(0) += u.input_tokens.unwrap_or(0);
            *acc.output_tokens.get_or_insert(0) += u.output_tokens.unwrap_or(0);
            *acc.cache_read_input_tokens.get_or_insert(0) += u.cache_read_input_tokens.unwrap_or(0);
            *acc.cache_creation_input_tokens.get_or_insert(0) +=
                u.cache_creation_input_tokens.unwrap_or(0);
        }
    }
    acc
}

/// Estimate judge spend (Opus, ambient) for the pairs judged this run: 2 calls each,
/// input ≈ (question + both answers)/4 chars-per-token, output ≈ 40 tokens/call.
fn estimate_judge_spend(judged_now: &[ShadowPair]) -> f64 {
    let mut input = 0.0f64;
    let mut output = 0.0f64;
    for p in judged_now {
        let chars =
            p.question.len() + p.hosted_text.len() + p.shadow_text.as_deref().unwrap_or("").len();
        input += (chars as f64 / 4.0) * 2.0; // two orderings
        output += 40.0 * 2.0;
    }
    input / 1_000_000.0 * OPUS_IN_PER_M + output / 1_000_000.0 * OPUS_OUT_PER_M
}

struct Report {
    date: String,
    collected: usize,
    complete: usize,
    judged_now: usize,
    skipped: usize,
    today_w: u32,
    today_l: u32,
    today_t: u32,
    cum_w: u32,
    cum_l: u32,
    cum_t: u32,
    hosted_p50: u64,
    hosted_p95: u64,
    shadow_p50: u64,
    shadow_p95: u64,
    fireworks_usd: f64,
    opus_equiv_usd: f64,
    fireworks_today_usd: f64,
    judge_spend_est_usd: f64,
    leaks: u32,
    write_attempts: u32,
    grad: GraduationProgress,
    tripwires: Vec<String>,
}

fn main() {
    let date = std::env::args().nth(1).unwrap_or_else(today);

    let Some(log_path) = env_string("JESSE_SHADOW_LOG") else {
        eprintln!("shadow-audit: JESSE_SHADOW_LOG is not set — nothing to audit.");
        std::process::exit(0);
    };
    let body = std::fs::read_to_string(&log_path).unwrap_or_else(|e| {
        eprintln!("shadow-audit: could not read {log_path}: {e}");
        std::process::exit(1);
    });
    let pairs = parse_shadow_pairs(&body);

    let out_dir = PathBuf::from(home()).join("Library/Logs/jesse-shadow-audit");
    let state_path = out_dir.join("state.json");
    let mut state = ShadowAuditState::load(&state_path);

    // ---- Judge up to the cap of NEW, complete, unjudged pairs (incremental) --------
    let cap: usize = env_string("JESSE_SHADOW_JUDGE_CAP")
        .and_then(|s| s.parse().ok())
        .unwrap_or(20);
    let judge_timeout = Duration::from_secs(
        env_string("JESSE_SHADOW_JUDGE_TIMEOUT_SECS")
            .and_then(|s| s.parse().ok())
            .unwrap_or(120),
    );
    let claude_bin = env_string("JESSE_CLAUDE_BIN").unwrap_or_else(|| "claude".to_string());

    let to_judge =
        jesse_bridge::select_unjudged_sample(&pairs, state.line_watermark, &state.judged, cap);
    let mut judged_now_pairs: Vec<ShadowPair> = Vec::new();
    let mut today_w = 0u32;
    let mut today_l = 0u32;
    let mut today_t = 0u32;
    for pair in &to_judge {
        let outcome = judge_pair(&claude_bin, pair, judge_timeout);
        match outcome {
            PairOutcome::ShadowWins => today_w += 1,
            PairOutcome::HostedWins => today_l += 1,
            PairOutcome::Tie => today_t += 1,
        }
        state
            .judged
            .insert(pair.turn_id.clone(), outcome.as_str().to_string());
        judged_now_pairs.push(pair.clone());
    }
    // Advance the watermark past every line consumed this run.
    state.line_watermark = pairs.len();

    // ---- Aggregate (read-only, over the whole log) ---------------------------------
    let complete: Vec<&ShadowPair> = pairs.iter().filter(|p| p.is_complete()).collect();
    let skipped = pairs.iter().filter(|p| p.outcome == "skipped_busy").count();

    let hosted_walls: Vec<u64> = complete.iter().map(|p| p.hosted_wall_ms).collect();
    let shadow_walls: Vec<u64> = complete.iter().filter_map(|p| p.shadow_wall_ms).collect();

    let leaks = complete
        .iter()
        .filter(|p| shadow_has_injection_leak(p.shadow_text.as_deref().unwrap_or("")))
        .count() as u32;
    let write_attempts = pairs.iter().filter(|p| p.write_attempt).count() as u32;

    let fw_usage = sum_usage(complete.iter().copied());
    let fireworks_usd = fw_usage.fireworks_cost();
    let opus_equiv_usd = fw_usage.opus_cost();
    let today_usage = sum_usage(complete.iter().copied().filter(|p| p.date() == date));
    let fireworks_today_usd = today_usage.fireworks_cost();

    let (cum_w, cum_l, cum_t) = tally_outcomes(state.judged.values().map(String::as_str));
    let days_armed = pairs
        .iter()
        .map(|p| p.date())
        .filter(|d| !d.is_empty())
        .collect::<BTreeSet<_>>()
        .len() as u32;

    let hosted_p50 = percentile_ms(&hosted_walls, 50);
    let shadow_p50 = percentile_ms(&shadow_walls, 50);

    let grad = GraduationProgress {
        days_armed,
        judged_pairs: state.judged.len() as u32,
        net: cum_w as i64 - cum_l as i64,
        injection_leaks: leaks,
        shadow_p50_ms: shadow_p50,
        hosted_p50_ms: hosted_p50,
    };
    let tripwires = shadow_tripwires(leaks, write_attempts, fireworks_today_usd);

    let report = Report {
        date: date.clone(),
        collected: pairs.len(),
        complete: complete.len(),
        judged_now: judged_now_pairs.len(),
        skipped,
        today_w,
        today_l,
        today_t,
        cum_w,
        cum_l,
        cum_t,
        hosted_p50,
        hosted_p95: percentile_ms(&hosted_walls, 95),
        shadow_p50,
        shadow_p95: percentile_ms(&shadow_walls, 95),
        fireworks_usd,
        opus_equiv_usd,
        fireworks_today_usd,
        judge_spend_est_usd: estimate_judge_spend(&judged_now_pairs),
        leaks,
        write_attempts,
        grad,
        tripwires,
    };

    // ---- Tripwires first, to stdout ------------------------------------------------
    if report.tripwires.is_empty() {
        println!("shadow-audit {date}: clean.");
    } else {
        for t in &report.tripwires {
            println!("{t}");
        }
    }

    // ---- Write the note + JSON twin, then persist state ----------------------------
    if let Err(e) = std::fs::create_dir_all(&out_dir) {
        eprintln!("shadow-audit: could not create {}: {e}", out_dir.display());
        std::process::exit(1);
    }
    let md_path = out_dir.join(format!("{date}.md"));
    let json_path = out_dir.join(format!("{date}.json"));
    if let Err(e) = std::fs::write(&md_path, render_markdown(&report)) {
        eprintln!("shadow-audit: could not write {}: {e}", md_path.display());
        std::process::exit(1);
    }
    if let Err(e) = std::fs::write(&json_path, render_json(&report)) {
        eprintln!("shadow-audit: could not write {}: {e}", json_path.display());
        std::process::exit(1);
    }
    if let Err(e) = state.save(&state_path) {
        eprintln!(
            "shadow-audit: could not persist {}: {e}",
            state_path.display()
        );
        std::process::exit(1);
    }

    println!(
        "shadow-audit written: {} ({} pairs collected, {} judged this run, {} tripwire(s))",
        md_path.display(),
        report.collected,
        report.judged_now,
        report.tripwires.len()
    );
}

fn yn(b: bool) -> &'static str {
    if b {
        "✓"
    } else {
        "✗"
    }
}

fn render_markdown(r: &Report) -> String {
    let g = &r.grad;
    let mut s = String::new();
    s.push_str(&format!("# Jesse shadow-comparison audit — {}\n\n", r.date));

    s.push_str("## Tripwires\n\n");
    if r.tripwires.is_empty() {
        s.push_str("- none (clean)\n");
    } else {
        for t in &r.tripwires {
            s.push_str(&format!("- **{t}**\n"));
        }
    }

    s.push_str("\n## Pairs\n\n");
    s.push_str(&format!("- collected (all lines): {}\n", r.collected));
    s.push_str(&format!("- complete (judgeable): {}\n", r.complete));
    s.push_str(&format!("- skipped_busy: {}\n", r.skipped));
    s.push_str(&format!("- judged this run: {}\n", r.judged_now));

    s.push_str("\n## Wins / losses / ties (shadow-relative)\n\n");
    s.push_str(&format!(
        "- today: W {} / L {} / T {}\n",
        r.today_w, r.today_l, r.today_t
    ));
    s.push_str(&format!(
        "- cumulative: W {} / L {} / T {} (net {})\n",
        r.cum_w,
        r.cum_l,
        r.cum_t,
        r.cum_w as i64 - r.cum_l as i64
    ));

    s.push_str("\n## Latency (wall-clock)\n\n");
    s.push_str(&format!(
        "- hosted p50 {} ms · p95 {} ms\n",
        r.hosted_p50, r.hosted_p95
    ));
    s.push_str(&format!(
        "- shadow p50 {} ms · p95 {} ms\n",
        r.shadow_p50, r.shadow_p95
    ));

    s.push_str("\n## Cost\n\n");
    s.push_str(&format!(
        "- measured Fireworks (shadow usage): ${:.4} cumulative · ${:.4} today\n",
        r.fireworks_usd, r.fireworks_today_usd
    ));
    s.push_str(&format!(
        "- same turns on Opus (same token vector): ${:.4}\n",
        r.opus_equiv_usd
    ));
    s.push_str(&format!(
        "- judge spend estimate (Opus, ambient, this run): ${:.4}\n",
        r.judge_spend_est_usd
    ));

    s.push_str("\n## Graduation criteria (fixed target — evidence only, never routes)\n\n");
    s.push_str(&format!(
        "- {} ≥14 days armed: {} / 14\n",
        yn(g.days_ok()),
        g.days_armed
    ));
    s.push_str(&format!(
        "- {} ≥150 judged pairs: {} / 150\n",
        yn(g.pairs_ok()),
        g.judged_pairs
    ));
    s.push_str(&format!(
        "- {} cumulative net ≥ −5% of judged: net {} vs floor {:.1}\n",
        yn(g.net_ok()),
        g.net,
        -(g.judged_pairs as f64 * 0.05)
    ));
    s.push_str(&format!(
        "- {} zero injection leaks: {} leak(s)\n",
        yn(g.leaks_ok()),
        g.injection_leaks
    ));
    s.push_str(&format!(
        "- {} shadow p50 ≤ hosted p50 +50%: {} ms ≤ {} ms\n",
        yn(g.latency_ok()),
        g.shadow_p50_ms,
        (g.hosted_p50_ms as f64 * 1.5) as u64
    ));
    s.push_str(&format!(
        "\n**Graduation criteria met: {}** (meeting them is evidence for a routing prompt; \
         this audit only reports).\n",
        if g.met() { "YES" } else { "no" }
    ));

    s.push_str(&format!("\n_generated by shadow-audit for {}_\n", r.date));
    s
}

fn render_json(r: &Report) -> String {
    let g = &r.grad;
    let v = serde_json::json!({
        "date": r.date,
        "tripwires": r.tripwires,
        "pairs": {
            "collected": r.collected,
            "complete": r.complete,
            "skipped_busy": r.skipped,
            "judged_this_run": r.judged_now,
        },
        "wins": {
            "today": { "w": r.today_w, "l": r.today_l, "t": r.today_t },
            "cumulative": { "w": r.cum_w, "l": r.cum_l, "t": r.cum_t, "net": r.cum_w as i64 - r.cum_l as i64 },
        },
        "latency_ms": {
            "hosted": { "p50": r.hosted_p50, "p95": r.hosted_p95 },
            "shadow": { "p50": r.shadow_p50, "p95": r.shadow_p95 },
        },
        "cost_usd": {
            "fireworks_cumulative": r.fireworks_usd,
            "fireworks_today": r.fireworks_today_usd,
            "opus_equivalent": r.opus_equiv_usd,
            "judge_spend_estimate": r.judge_spend_est_usd,
        },
        "canaries": { "injection_leaks": r.leaks, "write_attempts": r.write_attempts },
        "graduation": {
            "days_armed": g.days_armed,
            "judged_pairs": g.judged_pairs,
            "net": g.net,
            "injection_leaks": g.injection_leaks,
            "shadow_p50_ms": g.shadow_p50_ms,
            "hosted_p50_ms": g.hosted_p50_ms,
            "days_ok": g.days_ok(),
            "pairs_ok": g.pairs_ok(),
            "net_ok": g.net_ok(),
            "leaks_ok": g.leaks_ok(),
            "latency_ok": g.latency_ok(),
            "met": g.met(),
        },
    });
    serde_json::to_string_pretty(&v).unwrap_or_else(|_| "{}".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn final_answer_prefers_the_result_line() {
        let stream = "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"VERDICT: 1\"}}}\n\
                      {\"type\":\"result\",\"is_error\":false,\"result\":\"VERDICT: 2\\nbecause\"}\n";
        assert_eq!(final_answer_from_stream(stream), "VERDICT: 2\nbecause");
        // No result line → the accumulated deltas.
        let only_delta = "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"VERDICT: TIE\"}}}\n";
        assert_eq!(final_answer_from_stream(only_delta), "VERDICT: TIE");
    }

    #[test]
    fn sum_usage_adds_shadow_side_tokens_only() {
        let mk = |inp: u64, out: u64| ShadowPair {
            turn_id: "t".into(),
            ts: "2026-07-18T00:00:00Z".into(),
            outcome: "complete".into(),
            question: "q".into(),
            hosted_text: "h".into(),
            shadow_text: Some("s".into()),
            hosted_wall_ms: 1,
            shadow_wall_ms: Some(1),
            hosted_ttft_ms: None,
            shadow_ttft_ms: None,
            hosted_usage: None,
            shadow_usage: Some(ShadowUsage {
                input_tokens: Some(inp),
                output_tokens: Some(out),
                cache_read_input_tokens: None,
                cache_creation_input_tokens: None,
            }),
            shadow_model: "fw-glm".into(),
            write_attempt: false,
            error: None,
            judged: None,
        };
        let pairs = [mk(100, 10), mk(200, 20)];
        let u = sum_usage(pairs.iter());
        assert_eq!(u.input_tokens, Some(300));
        assert_eq!(u.output_tokens, Some(30));
    }

    #[test]
    fn judge_spend_estimate_scales_with_content() {
        let mk = |q: &str, h: &str, s: &str| ShadowPair {
            turn_id: "t".into(),
            ts: "2026-07-18T00:00:00Z".into(),
            outcome: "complete".into(),
            question: q.into(),
            hosted_text: h.into(),
            shadow_text: Some(s.into()),
            hosted_wall_ms: 1,
            shadow_wall_ms: Some(1),
            hosted_ttft_ms: None,
            shadow_ttft_ms: None,
            hosted_usage: None,
            shadow_usage: None,
            shadow_model: "fw-glm".into(),
            write_attempt: false,
            error: None,
            judged: None,
        };
        assert_eq!(estimate_judge_spend(&[]), 0.0);
        let one = estimate_judge_spend(&[mk("q", "h", "s")]);
        let two = estimate_judge_spend(&[mk("q", "h", "s"), mk("q", "h", "s")]);
        assert!(two > one && one > 0.0);
    }
}
