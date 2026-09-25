//! Print the nightly Strands audit for a vault, writing nothing.
//!
//!     cargo run --example strands_audit -- ~/jesse/vault [YYYY-MM-DD] [--items]
//!
//! The argument is the NOTES root (the directory that holds `Strands/`), not the vault
//! repository above it. The date defaults to today on the host clock. This is the same
//! `snapshot`, `add_unstranded` and `render_report` the bridge's nightly writer uses, with
//! the day file's strands derived by the same `StrandTable` and `derive_strand`; only the
//! write is missing, which is what makes it safe to point at the live vault.
//!
//! The day file is parsed as it sits on disk. The bridge also merges any journaled tap
//! that has not reached the file yet, which can only change which items are checked,
//! never which strand an item derives.
//!
//! `--items` prints every Today item's lead with its derived strand (or `null`) instead
//! of the report.

use std::path::PathBuf;

fn main() {
    let mut items = false;
    let mut positional: Vec<String> = Vec::new();
    for arg in std::env::args().skip(1) {
        match arg.as_str() {
            "--items" => items = true,
            _ => positional.push(arg),
        }
    }
    let mut args = positional.into_iter();
    let Some(root) = args.next() else {
        eprintln!("usage: strands_audit <notes root> [YYYY-MM-DD] [--items]");
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
    let mut day = match std::fs::read_to_string(root.join(jesse_bridge::TODAY_FILE)) {
        Ok(src) => jesse_bridge::parse_today(&src),
        Err(_) => jesse_bridge::TodaySnapshot::default(),
    };
    jesse_bridge::StrandTable::load_from(&root).stamp_into(&mut day);
    if items {
        let all = day
            .lead_items
            .iter()
            .chain(day.sections.iter().flat_map(|s| s.items.iter()));
        for item in all {
            let strand = item.strand.as_ref().map_or("null", |s| s.slug.as_str());
            let mark = if item.checked { "x" } else { " " };
            println!("[{mark}] {} · {} → {strand}", item.section_name, item.lead);
        }
        return;
    }
    let mut snapshot = jesse_bridge::strands::snapshot(&root, &date);
    jesse_bridge::strands::add_unstranded(&mut snapshot, &day);
    print!("{}", jesse_bridge::strands::render_report(&snapshot, &date));
}
