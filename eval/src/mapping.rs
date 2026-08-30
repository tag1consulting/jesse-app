//! **The tool-name mapping table** — one suite allowlist, two tool surfaces.
//!
//! A task's `allowed_tools` is written in the CLI child's vocabulary (`Read`, `Grep`,
//! `Glob`, the four `mcp__qmd__*` names, `Write`, `Edit`) because that is the surface the
//! product ships against today and the surface every existing suite is written in. The
//! direct driver has a different, typed surface (`vault_read`, `vault_search`, `vault_list`,
//! `vault_write`, `vault_edit`, `vault_move`), and the two are not the same shape: three
//! CLI names collapse onto `vault_read`, and one CLI name (`Write`) opens two direct tools.
//!
//! **SO THE TABLE IS EXPLICIT AND IT IS HERE, ONCE.** The alternative — a suite carrying
//! both allowlists — means a task can grant `Read` on one driver and `vault_write` on the
//! other, and the comparison the whole seam exists to make would be between two different
//! experiments.
//!
//! **AN UNMAPPED NAME IS REFUSED, NOT IGNORED.** A task that asks for `Bash(ls:*)` or
//! `WebFetch` has no meaning on the direct driver, and running it with those tools quietly
//! absent would score a task that could not possibly have succeeded as a model failure. The
//! refusal names the table, so the fix is obvious.
//!
//! | `allowed_tools` name | Direct manifest names |
//! |---|---|
//! | `Read` | `vault_read` |
//! | `Grep` | `vault_search` |
//! | `Glob` | `vault_list` |
//! | `mcp__qmd__query` | `vault_search` |
//! | `mcp__qmd__get` | `vault_read` |
//! | `mcp__qmd__multi_get` | `vault_read` |
//! | `mcp__qmd__status` | `vault_list` |
//! | `Write` | `vault_write`, `vault_move` |
//! | `Edit` | `vault_edit` |
//! | anything else | **refused** |
//!
//! **THE TABLE IS ALSO WHAT THE `tools_include` / `tools_exclude` ASSERTIONS MATCH THROUGH.**
//! A suite names tools in one vocabulary — the CLI's — in `allowed_tools`, and an assertion
//! that named them in a different one per driver would make the suite unrunnable on both.
//! So `tools_include: ["Read"]` is satisfied by a `Read` call on the CLI driver and by a
//! `vault_read` call on the direct one, and `tools_exclude: ["Write"]` catches `vault_write`
//! and `vault_move` as well as `Write`. A name that is in no row (`WebFetch`, `fetch_url`)
//! matches literally and only literally, which is what makes it usable for a tool NEITHER
//! driver should ever reach.
//!
//! `fetch_url` is deliberately absent from the right-hand column. The vault tool set exposes
//! it at `read` level with an EMPTY host allowlist, so it refuses every URL; leaving it out
//! of the mapping means an eval turn never even sees it in its manifest. That is what makes
//! `tools_exclude: ["fetch_url"]` on the injection tasks a regression guard on this table
//! rather than a hope about the model.

use std::collections::BTreeSet;

/// One row of the table.
type Row = (&'static str, &'static [&'static str]);

/// The table itself. Ordered as the doc comment lists it.
pub const TABLE: &[Row] = &[
    ("Read", &["vault_read"]),
    ("Grep", &["vault_search"]),
    ("Glob", &["vault_list"]),
    ("mcp__qmd__query", &["vault_search"]),
    ("mcp__qmd__get", &["vault_read"]),
    ("mcp__qmd__multi_get", &["vault_read"]),
    ("mcp__qmd__status", &["vault_list"]),
    ("Write", &["vault_write", "vault_move"]),
    ("Edit", &["vault_edit"]),
];

/// Every name that counts as a call to `name`: the name itself, plus its direct-manifest
/// equivalents.
///
/// Used by the `tools_include` / `tools_exclude` assertions so one suite reads correctly on
/// both drivers. A name in no row answers only to itself.
pub fn aliases_of(name: &str) -> Vec<&str> {
    let mut out = vec![name];
    if let Some((_, direct)) = TABLE.iter().find(|(cli, _)| *cli == name) {
        out.extend(direct.iter().copied());
    }
    out
}

/// Map a task's allowlist onto the direct manifest names it grants.
///
/// The result is a SET, in manifest order-independent form: two CLI names mapping to the
/// same direct tool grant it once. An empty allowlist maps to an empty set, which is a turn
/// with no tools — the honest reading of "this task granted none".
pub fn map_allowed_tools(allowed: &[String]) -> Result<BTreeSet<String>, String> {
    let mut out = BTreeSet::new();
    for name in allowed {
        match TABLE.iter().find(|(cli, _)| *cli == name.as_str()) {
            Some((_, direct)) => out.extend(direct.iter().map(|s| s.to_string())),
            None => {
                return Err(format!(
                    "the direct driver has no tool for '{name}'. The mapping is: {}",
                    render_table_inline()
                ))
            }
        }
    }
    Ok(out)
}

/// The table as one line, for a refusal message.
fn render_table_inline() -> String {
    TABLE
        .iter()
        .map(|(cli, direct)| format!("{cli} -> {}", direct.join("+")))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The table as a markdown table, for the report and the README.
pub fn render_table_markdown() -> String {
    let mut out = String::from("| `allowed_tools` name | Direct manifest names |\n|---|---|\n");
    for (cli, direct) in TABLE {
        out.push_str(&format!(
            "| `{cli}` | {} |\n",
            direct
                .iter()
                .map(|d| format!("`{d}`"))
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }
    out.push_str("| anything else | **refused** |\n");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(names: &[&str]) -> Vec<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_read_names_collapse_onto_the_three_read_tools() {
        let got = map_allowed_tools(&v(&[
            "Read",
            "Grep",
            "Glob",
            "mcp__qmd__query",
            "mcp__qmd__get",
            "mcp__qmd__multi_get",
            "mcp__qmd__status",
        ]))
        .unwrap();
        assert_eq!(
            got.into_iter().collect::<Vec<_>>(),
            ["vault_list", "vault_read", "vault_search"]
        );
    }

    #[test]
    fn write_and_edit_between_them_open_the_three_write_tools() {
        let got = map_allowed_tools(&v(&["Write", "Edit"])).unwrap();
        assert_eq!(
            got.into_iter().collect::<Vec<_>>(),
            ["vault_edit", "vault_move", "vault_write"]
        );
    }

    #[test]
    fn an_unmapped_tool_is_refused_and_the_message_names_the_table() {
        let err = map_allowed_tools(&v(&["Read", "Bash(ls:*)"])).unwrap_err();
        assert!(err.contains("Bash(ls:*)"), "{err}");
        assert!(err.contains("Read -> vault_read"), "{err}");
    }

    #[test]
    fn fetch_url_is_reachable_from_no_row() {
        for (_, direct) in TABLE {
            assert!(
                !direct.contains(&"fetch_url"),
                "no allowlist name may grant the egress tool"
            );
        }
    }

    #[test]
    fn an_alias_covers_both_vocabularies() {
        assert_eq!(aliases_of("Read"), ["Read", "vault_read"]);
        assert_eq!(aliases_of("Write"), ["Write", "vault_write", "vault_move"]);
        // A name in no row answers only to itself — which is the point for a tool neither
        // driver should ever reach.
        assert_eq!(aliases_of("WebFetch"), ["WebFetch"]);
        assert_eq!(aliases_of("fetch_url"), ["fetch_url"]);
    }

    #[test]
    fn an_empty_allowlist_grants_nothing() {
        assert!(map_allowed_tools(&[]).unwrap().is_empty());
    }
}
