//! Print the nightly Strands audit for a vault, writing nothing.
//!
//!     cargo run --example strands_audit -- ~/jesse/vault [YYYY-MM-DD]
//!
//! The argument is the NOTES root (the directory that holds `Strands/`), not the vault
//! repository above it. The date defaults to today on the host clock. This is the same
//! `snapshot` and `render_report` the bridge's nightly writer uses; only the write is
//! missing, which is what makes it safe to point at the live vault.

use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(root) = args.next() else {
        eprintln!("usage: strands_audit <notes root> [YYYY-MM-DD]");
        std::process::exit(2);
    };
    let date = args
        .next()
        .unwrap_or_else(|| chrono::Local::now().format("%Y-%m-%d").to_string());
    let root = PathBuf::from(root);
    if !root.join(jesse_bridge::strands::STRANDS_DIR).is_dir() {
        eprintln!("no Strands/ directory under {}", root.display());
        std::process::exit(1);
    }
    let snapshot = jesse_bridge::strands::snapshot(&root, &date);
    print!("{}", jesse_bridge::strands::render_report(&snapshot, &date));
}
