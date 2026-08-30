//! Print the manifest a fixture tool set produces at each level.
//!
//! An EXAMPLE rather than a test, for the reason `smoke.rs` is one: its output is meant to
//! be read by a person (and pasted into a report), and a test whose value is its stdout is
//! a test nobody runs. What it asserts is asserted properly in `tests/loop_conformance.rs`.
//!
//! ```text
//!   cargo run -p jesse-agent --example manifest -- <dir>
//! ```
use jesse_agent::tools::{fixture::fixture_tool_set, Level, ToolSet};

fn main() -> Result<(), String> {
    let root = std::env::args().nth(1).ok_or("usage: manifest <dir>")?;
    for level in [Level::Basic, Level::Read, Level::Write] {
        let set = fixture_tool_set(&root, level)?;
        println!("--- level={level} ---");
        println!("withheld: {:?}", set.withheld());
        println!(
            "{}",
            serde_json::to_string_pretty(&set.manifest()).map_err(|e| e.to_string())?
        );
    }
    Ok(())
}
