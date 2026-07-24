//! `vision-eval` — the fixed-eval-set faithfulness harness. Runs each fixture in a
//! manifest through a chosen vision helper via the live path and MEASURES faithfulness:
//! every ground-truth string must appear (case-insensitively) in the transcription. It
//! reports a per-fixture pass/fail plus latency and token cost, and an aggregate score —
//! so "the transcription actually contains the ground-truth values" is measured, not
//! eyeballed once.
//!
//! The manifest (JSON) lists fixtures relative to its own directory:
//!   { "fixtures": [ { "file": "statement.pdf", "kind": "text-pdf",
//!                     "ground_truth": ["Invoice", "Total: $42.00"],
//!                     "question": "What is the invoice total?" }, … ] }
//!
//! Usage:
//!     vision-eval <manifest.json> <helper-id>
//! Example:
//!     FIREWORKS_API_KEY=… vision-eval ./eval/vision/manifest.json paddleocr-vl
//!
//! `question` is carried for the downstream answer-correctness check (a text model
//! answering over the spliced transcription); this harness measures transcription
//! faithfulness, the deterministic half of the definition-of-done.

use jesse_bridge::{eval_fixture, sniff_attachment, Config, VisionInput};

#[derive(serde::Deserialize)]
struct Manifest {
    fixtures: Vec<Fixture>,
}

#[derive(serde::Deserialize)]
struct Fixture {
    file: String,
    #[serde(default)]
    kind: String,
    #[serde(default)]
    ground_truth: Vec<String>,
    #[serde(default)]
    question: String,
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: vision-eval <manifest.json> <helper-id>");
        std::process::exit(2);
    }
    let manifest_path = std::path::PathBuf::from(&args[1]);
    let helper_id = &args[2];

    let manifest_dir = manifest_path
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    let manifest: Manifest = match std::fs::read_to_string(&manifest_path) {
        Ok(s) => match serde_json::from_str(&s) {
            Ok(m) => m,
            Err(e) => {
                eprintln!("bad manifest {}: {e}", manifest_path.display());
                std::process::exit(1);
            }
        },
        Err(e) => {
            eprintln!("could not read {}: {e}", manifest_path.display());
            std::process::exit(1);
        }
    };

    let cfg = Config::from_env();

    println!(
        "=== vision-eval: {} fixture(s) via helper '{helper_id}' ===",
        manifest.fixtures.len()
    );
    let mut total_gt = 0usize;
    let mut total_hits = 0usize;
    let mut any_error = false;

    for fx in &manifest.fixtures {
        let path = manifest_dir.join(&fx.file);
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) => {
                println!("\n# {} [{}]\n  MISSING: {e}", fx.file, fx.kind);
                any_error = true;
                continue;
            }
        };
        let Some((_, ext)) = sniff_attachment(&bytes) else {
            println!("\n# {} [{}]\n  UNSUPPORTED FILE TYPE", fx.file, fx.kind);
            any_error = true;
            continue;
        };
        let input = VisionInput {
            source: fx.file.clone(),
            ext: ext.to_string(),
            bytes,
        };
        let res = eval_fixture(&cfg, helper_id, &input, &fx.ground_truth).await;

        println!("\n# {} [{}]", fx.file, fx.kind);
        if !fx.question.is_empty() {
            println!("  question: {}", fx.question);
        }
        if let Some(err) = &res.error {
            println!("  ERROR: {err}");
            any_error = true;
        }
        for (gt, ok) in &res.faithfulness {
            println!("  [{}] {gt}", if *ok { "FOUND" } else { "MISS " });
        }
        total_gt += res.faithfulness.len();
        total_hits += res.faithfulness.iter().filter(|(_, ok)| *ok).count();
        println!(
            "  faithfulness={:.0}%  latency={}ms  in_tok={}  out_tok={}  cost=${:.5}",
            res.faithfulness_score() * 100.0,
            res.latency_ms,
            res.input_tokens,
            res.output_tokens,
            res.dollars,
        );
    }

    let overall = if total_gt == 0 {
        100.0
    } else {
        total_hits as f64 / total_gt as f64 * 100.0
    };
    println!("\n=== aggregate: {total_hits}/{total_gt} ground-truth strings found ({overall:.0}%) ===");
    if any_error {
        std::process::exit(1);
    }
}
