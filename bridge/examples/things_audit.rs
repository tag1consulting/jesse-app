//! Print the nightly Things audit for a vault, writing nothing.
//!
//!     cargo run --example things_audit -- ~/jesse/vault [YYYY-MM-DD]
//!
//! The argument is the NOTES root (the directory that holds `Things/`), not the vault
//! repository above it. The date defaults to today on the host clock. This is the same
//! `snapshot` and `render_report` the bridge's nightly writer uses; only the write is
//! missing, which is what makes it safe to point at the live vault.

use std::path::PathBuf;

fn main() {
    let mut args = std::env::args().skip(1);
    let Some(root) = args.next() else {
        eprintln!("usage: things_audit <notes root> [YYYY-MM-DD]");
        std::process::exit(2);
    };
    let date = args
        .next()
        .unwrap_or_else(|| chrono::Local::now().format("%Y-%m-%d").to_string());
    let root = PathBuf::from(root);
    if !root.join(jesse_bridge::things::THINGS_DIR).is_dir() {
        eprintln!("no Things/ directory under {}", root.display());
        std::process::exit(1);
    }
    let snapshot = jesse_bridge::things::snapshot(&root, &date);
    print!("{}", jesse_bridge::things::render_report(&snapshot, &date));
}
