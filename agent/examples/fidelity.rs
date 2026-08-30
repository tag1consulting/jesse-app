//! **Vault fidelity** — run the real tool set over a real vault, read-only, and report
//! counts.
//!
//! An EXAMPLE, not a test, for two reasons that both matter. CI has no vault, so a test
//! would either be `#[ignore]`d (and never run) or would fail on every machine but one. And
//! its whole output is counts a person reads.
//!
//! **NOTHING HERE PRINTS A DOCUMENT'S CONTENT.** Titles and ids are file names, which are
//! reportable; bodies and snippets are not, and no code path below can emit one — the
//! search results are reduced to counts before anything is printed.
//!
//! **READ ONLY.** There is no `Write`-level call in this file, no store mutation, and the
//! tool set is built at `Level::Read` so the write tools do not exist in it.
//!
//! ```text
//!   cargo run -p jesse-agent --example fidelity -- <vault-root> [--cold-prefix P]... [--exclude E]...
//! ```

use std::sync::Arc;

use jesse_agent::index::{GrepIndex, SearchIndex, SearchMode};
use jesse_agent::store::{DocumentStore, FsVaultStore, ListRequest, Visibility};
use jesse_agent::tools::{Level, ToolSet};
use jesse_agent::Scope;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let root = args
        .next()
        .ok_or("usage: fidelity <vault-root> [--exclude E]... [--cold-prefix P]...")?;
    let mut excludes: Vec<String> = Vec::new();
    let mut cold: Vec<String> = Vec::new();
    let mut queries: Vec<String> = Vec::new();
    let mut scan_limit: Option<usize> = None;
    while let Some(flag) = args.next() {
        match flag.as_str() {
            "--exclude" => excludes.push(args.next().ok_or("--exclude needs a value")?),
            "--cold-prefix" => cold.push(args.next().ok_or("--cold-prefix needs a value")?),
            "--query" => queries.push(args.next().ok_or("--query needs a value")?),
            "--scan-limit" => {
                scan_limit = Some(
                    args.next()
                        .ok_or("--scan-limit needs a value")?
                        .parse()
                        .map_err(|_| "--scan-limit must be a number")?,
                )
            }
            other => return Err(format!("unknown flag {other:?}")),
        }
    }

    let store = Arc::new(
        FsVaultStore::open(&root)
            .map_err(|e| e.to_string())?
            .excluding(&excludes)
            .cold_prefixes(&cold),
    );
    let mut index = GrepIndex::new(store.clone());
    if let Some(n) = scan_limit {
        index = index.scanning_at_most(n);
    }
    let scope = Scope::new("local", "owner", "default");

    println!("root            {root}");
    println!("exclusions      {:?}", store.exclusions());
    println!("cold prefixes   {cold:?}");

    // ---- The manifest at Read ------------------------------------------
    let vault = Arc::new(jesse_agent::tools::vault::VaultContext {
        store: store.clone(),
        index: Arc::new(GrepIndex::new(store.clone())),
        guard: Arc::new(jesse_agent::store::NoGuard),
    });
    let tools = jesse_agent::tools::vault::vault_tool_set(
        vault,
        jesse_agent::tools::vault::FetchConfig::default(),
        Level::Read,
    )?;
    println!(
        "manifest(read)  [{}]",
        tools
            .manifest()
            .iter()
            .map(|t| t.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );

    // ---- Listing at depth 2 --------------------------------------------
    let mut total = 0usize;
    let mut cold_count = 0usize;
    let mut page = 0u32;
    let mut top: std::collections::BTreeMap<String, usize> = Default::default();
    loop {
        let p = store
            .list(
                &scope,
                ListRequest {
                    depth: Some(2),
                    page,
                    page_size: 500,
                    ..Default::default()
                },
            )
            .await
            .map_err(|e| e.to_string())?;
        for m in &p.items {
            total += 1;
            if m.visibility == Visibility::Cold {
                cold_count += 1;
            }
            let folder =
                m.id.as_str()
                    .split_once('/')
                    .map(|(a, _)| a.to_string())
                    .unwrap_or_else(|| "(root)".into());
            *top.entry(folder).or_default() += 1;
        }
        match p.next_page {
            Some(n) => page = n,
            None => break,
        }
    }
    println!("\n--- vault_list, depth 2 ---");
    println!("documents       {total}  (cold: {cold_count})");
    println!("top-level folders and counts:");
    for (folder, n) in &top {
        println!("  {folder:<28} {n}");
    }

    // ---- Exclusions actually bite ---------------------------------------
    println!("\n--- exclusions ---");
    for rule in &excludes {
        let name = rule.trim_matches('/');
        let present = top.keys().any(|k| k == name);
        println!("  {rule:<28} present in listing: {present}");
    }

    // ---- Searches --------------------------------------------------------
    println!("\n--- vault_search (counts only, no content) ---");
    for q in &queries {
        let hits = index
            .search(&scope, q, 10, SearchMode::Lexical)
            .await
            .map_err(|e| e.to_string())?;
        let from_excluded = hits
            .hits
            .iter()
            .filter(|h| {
                excludes
                    .iter()
                    .any(|e| h.id.starts_with_prefix(e.trim_matches('/')))
            })
            .count();
        let from_cold = hits
            .hits
            .iter()
            .filter(|h| {
                cold.iter()
                    .any(|c| h.id.starts_with_prefix(c.trim_matches('/')))
            })
            .count();
        // COUNTS ONLY. Not a title, not an id, not a snippet.
        let from_archive = hits
            .hits
            .iter()
            .filter(|h| h.id.as_str().contains("/archive/"))
            .count();
        let from_drafts = hits
            .hits
            .iter()
            .filter(|h| h.id.as_str().contains("/drafts/"))
            .count();
        // COUNTS ONLY. Not a title, not an id, not a snippet.
        println!(
            "  query {:<20} hits: {:<4} excluded: {from_excluded}  cold: {from_cold}  \
             under-archive: {from_archive}  under-drafts: {from_drafts}{}",
            format!("{q:?}"),
            hits.hits.len(),
            hits.degraded
                .as_deref()
                .map(|n| format!("   [{n}]"))
                .unwrap_or_default()
        );
        assert_eq!(
            from_excluded, 0,
            "an excluded document reached a search result"
        );
        assert_eq!(from_cold, 0, "a cold document reached a search result");
    }

    println!("\nno write-level call was made; nothing under the vault was modified.");
    Ok(())
}
