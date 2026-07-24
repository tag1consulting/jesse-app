//! `vision-compare` — the vision-helper comparison harness. Runs ONE attachment (image
//! or PDF) through EACH named vision helper via the exact live path (same rasterization,
//! same gateway aliases the running bridge uses) and prints their transcriptions side by
//! side with per-helper latency and token cost. This is how a candidate helper (including
//! a newer trending model) is vetted before it earns a pairing slot: register it, run it
//! through here on the eval set, and only then pair it with a text model.
//!
//! It requires NO chat turn and NO app — just the bridge's env (the `[[models]]` / role
//! backends the registry reads) and network reach to each helper's backend.
//!
//! Usage:
//!     vision-compare <attachment-path> <helper-id>[,<helper-id>...]
//! Example:
//!     JESSE_HOME=… FIREWORKS_API_KEY=… \
//!         vision-compare ./eval/vision/fixtures/statement.pdf paddleocr-vl,qwen3-vl
//!
//! Output is plain and diffable: one labeled block per helper, so quality differences read
//! at a glance and the latency/cost numbers support a fidelity-vs-cost call.

use jesse_bridge::{compare, sniff_attachment, Config, HelperComparison, VisionInput};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: vision-compare <attachment-path> <helper-id>[,<helper-id>...]");
        std::process::exit(2);
    }
    let path = &args[1];
    let helper_ids: Vec<String> = args[2]
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    if helper_ids.is_empty() {
        eprintln!("no helper ids given");
        std::process::exit(2);
    }

    let bytes = match std::fs::read(path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("could not read {path}: {e}");
            std::process::exit(1);
        }
    };
    let Some((mime, ext)) = sniff_attachment(&bytes) else {
        eprintln!("{path}: unsupported or unrecognized file type (not an image or PDF)");
        std::process::exit(1);
    };
    let source = std::path::Path::new(path)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.clone());
    let input = VisionInput {
        source: source.clone(),
        ext: ext.to_string(),
        bytes: bytes.clone(),
    };

    // The registry (helpers + their backends) comes from the bridge's env, exactly as the
    // running server reads it — so what you compare is what a live turn would produce.
    let cfg = Config::from_env();

    println!(
        "=== vision-compare: {source} ({mime}, {} bytes) — {} helper(s) ===",
        bytes.len(),
        helper_ids.len()
    );
    let comparisons: Vec<HelperComparison> = compare(&cfg, &helper_ids, &input).await;

    for c in &comparisons {
        println!("\n--- helper: {} (model={}) ---", c.id, c.model);
        if let Some(err) = &c.error {
            println!("[unavailable: {err}]");
            continue;
        }
        for r in &c.results {
            let page = match (r.page_no, r.total_pages) {
                (Some(n), Some(t)) => format!("page {n}/{t}"),
                (Some(n), None) => format!("page {n}"),
                _ => "single".to_string(),
            };
            print!(
                "[{page}] latency={}ms in_tok={} out_tok={}",
                r.latency_ms, r.input_tokens, r.output_tokens
            );
            if r.truncated {
                print!(" (source PDF truncated to the page cap)");
            }
            println!();
            match &r.error {
                Some(e) => println!("  [error: {e}]"),
                None => {
                    for line in r.text.lines() {
                        println!("  {line}");
                    }
                }
            }
        }
        let (lat, input_tok, output_tok, dollars) = c.totals();
        println!(
            "totals: latency={lat}ms in_tok={input_tok} out_tok={output_tok} cost=${dollars:.5}"
        );
    }

    // A compact final table so cost-vs-fidelity is readable without scrolling the blocks.
    println!("\n=== summary (helper | pages | latency_ms | in_tok | out_tok | cost) ===");
    for c in &comparisons {
        if c.error.is_some() {
            println!("{:<24} UNAVAILABLE", c.id);
            continue;
        }
        let (lat, input_tok, output_tok, dollars) = c.totals();
        println!(
            "{:<24} {:>5} {:>10} {:>8} {:>8} ${:.5}",
            c.id,
            c.results.len(),
            lat,
            input_tok,
            output_tok,
            dollars
        );
    }
}
