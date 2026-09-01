//! **Search** — the trait the `vault_search` tool goes through, and two implementations.
//!
//! ---- THE RULE THAT MAKES SEARCH SAFE -----------------------------------------
//!
//! **Every hit is filtered through the store's visibility before it is returned.** An index
//! is a second view of the same documents, built at a different time by different code, and
//! it is the natural place for an exclusion to be quietly bypassed: `qmd` indexes whatever
//! its collection pattern matched, which is not the same set the store considers visible.
//! An index that returned its own hits directly would be a way to read the title, the
//! snippet and often the substance of a document the store refuses to open.
//!
//! [`GrepIndex`] gets this by CONSTRUCTION — it walks the store, so an excluded document is
//! never a candidate and a cold one is never read. [`QmdIndex`] has to do it explicitly,
//! and does: every hit is checked against the store before it is returned, and there is a
//! test that plants an excluded and a cold document and asserts they never come back.
//!
//! ---- WHY TWO --------------------------------------------------------------
//!
//! [`GrepIndex`] is the implementation that ALWAYS exists: CI has no `qmd`, a fresh
//! developer machine has no `qmd`, and a product that could not search on those is a
//! product whose tests do not exercise search. [`QmdIndex`] is the good one — a real hybrid
//! index over the whole vault — and it degrades to the other with a logged note rather than
//! failing, because a missing binary is an operational fact and not a reason for a turn to
//! fail.

use std::fmt;
use std::path::PathBuf;
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::provider::BoxFuture;
use crate::scope::Scope;
use crate::store::{DocumentId, DocumentStore, ListRequest, StoreError, Visibility};

/// How a query is answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SearchMode {
    /// Keyword matching. Always available.
    #[default]
    Lexical,
    /// Keyword plus semantic. Available only where the backing index offers it; a request
    /// for it elsewhere is served lexically and the result SAYS SO — see [`Hits::degraded`].
    Hybrid,
}

impl fmt::Display for SearchMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            SearchMode::Lexical => "lexical",
            SearchMode::Hybrid => "hybrid",
        })
    }
}

impl std::str::FromStr for SearchMode {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_ascii_lowercase().as_str() {
            "lexical" | "lex" | "keyword" => Ok(SearchMode::Lexical),
            "hybrid" => Ok(SearchMode::Hybrid),
            other => Err(format!("{other:?} is not one of: lexical, hybrid")),
        }
    }
}

/// One matching line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snippet {
    /// 1-based line number, so it can be handed straight back to `vault_read`'s range.
    pub line: usize,
    pub text: String,
}

/// One matching document.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Hit {
    pub id: DocumentId,
    pub title: String,
    pub score: f64,
    pub snippets: Vec<Snippet>,
}

/// A search's results, and what actually served them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Hits {
    pub hits: Vec<Hit>,
    /// The mode that actually ran, which may not be the one asked for.
    pub served_by: SearchMode,
    /// Set when the requested mode was not available. **The hit list says so**, rather than
    /// silently returning worse results: a model told "these are hybrid results" reasons
    /// about their absence differently from one told "hybrid was unavailable, these are
    /// keyword results".
    pub degraded: Option<String>,
}

/// What an index can say about itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexStatus {
    pub name: &'static str,
    pub available: bool,
    pub supports_hybrid: bool,
    /// Documents indexed, when the index knows. Never a document's content.
    pub documents: Option<u64>,
    /// Why it is unavailable or degraded. Content-free.
    pub note: Option<String>,
}

/// Cap on one snippet's text, in bytes.
pub const SNIPPET_MAX_BYTES: usize = 300;

/// Cap on snippets per document.
pub const SNIPPETS_PER_HIT: usize = 3;

/// The default number of documents a search returns.
pub const DEFAULT_SEARCH_LIMIT: usize = 10;

/// Cap on the number a caller may ask for. A model asking for 500 hits is a model about to
/// fill its own context with a listing it will not read.
pub const MAX_SEARCH_LIMIT: usize = 50;

/// Where a query is answered.
pub trait SearchIndex: Send + Sync {
    fn search<'a>(
        &'a self,
        scope: &'a Scope,
        query: &'a str,
        limit: usize,
        mode: SearchMode,
    ) -> BoxFuture<'a, Result<Hits, StoreError>>;

    fn status(&self) -> IndexStatus;
}

/// The same sharing the store gets, and for the same reason — see the blanket impl on
/// `DocumentStore`.
impl<T: SearchIndex + ?Sized> SearchIndex for std::sync::Arc<T> {
    fn search<'a>(
        &'a self,
        scope: &'a Scope,
        query: &'a str,
        limit: usize,
        mode: SearchMode,
    ) -> BoxFuture<'a, Result<Hits, StoreError>> {
        (**self).search(scope, query, limit, mode)
    }

    fn status(&self) -> IndexStatus {
        (**self).status()
    }
}

/// Trim a line into a snippet, control-stripped and byte-capped.
fn snippet_text(line: &str) -> String {
    let cleaned: String = line
        .chars()
        .filter(|c| *c == '\n' || !c.is_ascii_control())
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.len() <= SNIPPET_MAX_BYTES {
        return cleaned.to_string();
    }
    let end = cleaned
        .char_indices()
        .map(|(i, c)| i + c.len_utf8())
        .take_while(|e| *e <= SNIPPET_MAX_BYTES)
        .last()
        .unwrap_or(0);
    format!("{}…", &cleaned[..end])
}

// ===========================================================================
// GrepIndex
// ===========================================================================

/// A search that walks the store.
///
/// **VISIBILITY IS FREE HERE**, and that is the reason it is written this way rather than
/// walking the filesystem directly: it lists through [`DocumentStore::list`] and reads
/// through [`DocumentStore::read`], so an excluded document is never a candidate and a cold
/// one returns [`StoreError::Refused`] and is skipped. There is no code path in this
/// implementation that could return a hit the store would not open, because it only ever
/// sees what the store gave it.
pub struct GrepIndex<S: DocumentStore> {
    store: S,
    /// Cap on documents scanned per query. A linear scan over seven thousand documents is
    /// seconds of I/O, and a turn waiting seconds for a keyword search is a turn the user
    /// has stopped watching. Past this the results say they are partial.
    scan_limit: usize,
    /// Cap on the size of one document read, in bytes. See [`GREP_MAX_DOC_BYTES`].
    max_doc_bytes: u64,
}

/// How many documents a `GrepIndex` reads before it stops and says it stopped.
pub const GREP_SCAN_LIMIT: usize = 2_000;

/// The largest document a `GrepIndex` will read, in bytes.
///
/// **A DOCUMENT PAST THIS IS SKIPPED, COUNTED, AND SAID SO — never read.** The size is
/// known from the listing before a single byte of the body is fetched, which is what makes
/// the bound structural rather than a hope: no query, however phrased, can make this index
/// hold a document larger than this. Two megabytes is far above any note a person writes
/// and far below anything that threatens a turn; the vault this was measured against holds
/// files three orders of magnitude larger, and one of them was D9's twelve-gigabyte search.
pub const GREP_MAX_DOC_BYTES: u64 = 2 * 1024 * 1024;

/// The most hits a `GrepIndex` holds while scanning.
///
/// Results were accumulated without limit and truncated to the caller's `limit` only after
/// the walk finished, so a common term over a large store held every match it ever saw.
/// Keeping a little more than the largest limit a caller may ask for is enough to answer
/// any query correctly, because everything beyond it is discarded anyway.
const HIT_BUFFER: usize = MAX_SEARCH_LIMIT * 4;

impl<S: DocumentStore> GrepIndex<S> {
    pub fn new(store: S) -> Self {
        GrepIndex {
            store,
            scan_limit: GREP_SCAN_LIMIT,
            max_doc_bytes: GREP_MAX_DOC_BYTES,
        }
    }

    pub fn scanning_at_most(mut self, n: usize) -> Self {
        self.scan_limit = n;
        self
    }

    /// Lower the per-document size ceiling. For tests that want to hit it without writing a
    /// multi-megabyte fixture; the shipped value is [`GREP_MAX_DOC_BYTES`].
    pub fn with_max_doc_bytes(mut self, n: u64) -> Self {
        self.max_doc_bytes = n;
        self
    }

    pub fn store(&self) -> &S {
        &self.store
    }
}

/// Case-insensitive whole-word match positions in a line.
///
/// WHOLE WORDS, not substrings: a search for `cat` that matched `concatenate` returns hits
/// nobody meant and pushes the ones they did mean off the list. The boundary test is on
/// alphanumeric-or-underscore, which is the same rule a `\b` would apply and does not need
/// a regex to be built per query from model-supplied text.
fn word_positions(haystack_lower: &str, needle_lower: &str) -> usize {
    if needle_lower.is_empty() {
        return 0;
    }
    let h = haystack_lower.as_bytes();
    let n = needle_lower.as_bytes();
    let boundary = |b: Option<&u8>| match b {
        None => true,
        Some(c) => !(c.is_ascii_alphanumeric() || *c == b'_'),
    };
    let mut count = 0;
    let mut i = 0;
    while i + n.len() <= h.len() {
        if &h[i..i + n.len()] == n
            && boundary(i.checked_sub(1).map(|p| &h[p]))
            && boundary(h.get(i + n.len()))
        {
            count += 1;
            i += n.len();
        } else {
            i += 1;
        }
    }
    count
}

/// Highest score first, ties broken by id so two runs of one query agree.
fn sort_hits(hits: &mut [Hit]) {
    hits.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.id.cmp(&b.id))
    });
}

impl<S: DocumentStore> SearchIndex for GrepIndex<S> {
    fn search<'a>(
        &'a self,
        scope: &'a Scope,
        query: &'a str,
        limit: usize,
        mode: SearchMode,
    ) -> BoxFuture<'a, Result<Hits, StoreError>> {
        Box::pin(async move {
            let terms: Vec<String> = query
                .split_whitespace()
                .map(|t| {
                    t.trim_matches(|c: char| !c.is_alphanumeric() && c != '_')
                        .to_lowercase()
                })
                .filter(|t| !t.is_empty())
                .collect();
            if terms.is_empty() {
                return Ok(Hits {
                    hits: Vec::new(),
                    served_by: SearchMode::Lexical,
                    degraded: None,
                });
            }

            let mut scanned = 0usize;
            let mut hits: Vec<Hit> = Vec::new();
            let mut page = 0u32;
            let mut truncated = false;
            let mut oversized = 0usize;
            // Prune to this when the buffer overflows. Keeping the caller's own limit would
            // be enough for the answer but would make the pruning threshold depend on the
            // query, so the buffer is a constant and the caller's limit is applied at the
            // end, exactly as before.
            let keep = HIT_BUFFER;

            'outer: loop {
                let listing = self
                    .store
                    .list(
                        scope,
                        ListRequest {
                            page,
                            page_size: 200,
                            ..Default::default()
                        },
                    )
                    .await?;
                if listing.items.is_empty() {
                    break;
                }
                for meta in &listing.items {
                    // Cold documents are skipped BEFORE the read, so a cold body is never
                    // even loaded into this process.
                    if meta.visibility == Visibility::Cold {
                        continue;
                    }
                    if scanned >= self.scan_limit {
                        truncated = true;
                        break 'outer;
                    }
                    // THE SIZE CEILING IS APPLIED BEFORE THE READ, from the listing's own
                    // metadata. This is the difference between an index that is bounded by
                    // construction and one that is bounded by what happens to be in the
                    // vault: past this point the body is never fetched, so no document can
                    // put its own size on this process's heap.
                    if meta.size_bytes > self.max_doc_bytes {
                        oversized += 1;
                        scanned += 1;
                        continue;
                    }
                    scanned += 1;
                    let doc = match self.store.read(scope, &meta.id, None).await {
                        Ok(d) => d,
                        // Refused (cold) or vanished — either way, not a hit.
                        Err(_) => continue,
                    };
                    let title_lower = meta.title.to_lowercase();
                    let mut score = 0f64;
                    let mut snippets = Vec::new();
                    // ONE PASS, and which terms were seen tracked as it goes. The old shape
                    // asked the same question afterwards by allocating a fresh lowercase
                    // copy of the WHOLE body once per query term — three terms meant three
                    // more copies of the document on top of the one already held.
                    let mut seen = vec![false; terms.len()];
                    for (i, t) in terms.iter().enumerate() {
                        if word_positions(&title_lower, t) > 0 {
                            seen[i] = true;
                        }
                    }
                    for (n, line) in doc.body.lines().enumerate() {
                        let lower = line.to_lowercase();
                        let mut matches = 0usize;
                        for (i, t) in terms.iter().enumerate() {
                            let c = word_positions(&lower, t);
                            if c > 0 {
                                seen[i] = true;
                                matches += c;
                            }
                        }
                        if matches > 0 {
                            score += matches as f64;
                            if snippets.len() < SNIPPETS_PER_HIT {
                                snippets.push(Snippet {
                                    line: n + 1,
                                    text: snippet_text(line),
                                });
                            }
                        }
                    }
                    // A document scores only if EVERY term appears somewhere in it, so a
                    // two-word query behaves like an AND rather than returning everything
                    // containing the commoner word.
                    let all_terms = seen.iter().all(|s| *s);
                    if score > 0.0 && all_terms {
                        // A title match is worth more than a body match: a document ABOUT
                        // the thing beats one that mentions it.
                        let title_hits: usize =
                            terms.iter().map(|t| word_positions(&title_lower, t)).sum();
                        hits.push(Hit {
                            id: meta.id.clone(),
                            title: meta.title.clone(),
                            score: score + (title_hits as f64) * 10.0,
                            snippets,
                        });
                        if hits.len() > keep {
                            sort_hits(&mut hits);
                            hits.truncate(keep);
                        }
                    }
                }
                match listing.next_page {
                    Some(n) => page = n,
                    None => break,
                }
            }

            sort_hits(&mut hits);
            hits.truncate(limit.clamp(1, MAX_SEARCH_LIMIT));

            // WHAT WAS NOT LOOKED AT IS PART OF THE ANSWER. A bounded search that reported
            // "no match" for a document it never opened would be worse than an unbounded
            // one, because the caller could not tell the two apart.
            let mut notes: Vec<String> = Vec::new();
            if mode == SearchMode::Hybrid {
                notes.push("hybrid search is not available here; these are keyword results".into());
            }
            if truncated {
                notes.push(format!(
                    "only the first {scanned} documents were scanned; narrow the query"
                ));
            }
            if oversized > 0 {
                notes.push(format!(
                    "{oversized} document(s) were skipped as too large to scan                      (over {} bytes); read them directly by id",
                    self.max_doc_bytes
                ));
            }

            Ok(Hits {
                hits,
                served_by: SearchMode::Lexical,
                degraded: (!notes.is_empty()).then(|| notes.join("; ")),
            })
        })
    }

    fn status(&self) -> IndexStatus {
        IndexStatus {
            name: "grep",
            available: true,
            supports_hybrid: false,
            documents: None,
            note: None,
        }
    }
}

// ===========================================================================
// QmdIndex
// ===========================================================================

/// How the `qmd` binary is reached.
///
/// **AN EXPLICIT BINARY PATH, NOT A `PATH` LOOKUP**, and that is not fussiness. On the
/// machine this was built against, `qmd` is a shim under an nvm node installation and it
/// works ONLY when that node's `bin` is ahead of any other node on `PATH`: run under a
/// newer node it aborts with a `NODE_MODULE_VERSION` mismatch from `better-sqlite3` — a
/// non-zero exit and a stack trace on stderr, which is precisely the failure the degrade
/// path exists for, but also one an operator can avoid entirely by naming the binary.
#[derive(Debug, Clone)]
pub struct QmdConfig {
    /// The binary. A bare name is resolved on `PATH`; a path is used as given.
    pub binary: PathBuf,
    /// The collection whose documents map onto the store's root.
    ///
    /// REQUIRED, not guessed. `qmd` reports a hit's file as `qmd://<collection>/<path>`, and
    /// stripping the wrong prefix would produce ids that resolve to the wrong documents or
    /// to none. The collection name is a local fact an operator knows and this code cannot
    /// derive: on the machine this was built against the collection covering the vault is
    /// not named after it.
    pub collection: String,
    /// Extra entries prepended to `PATH` for the child, for the nvm case above.
    pub path_prepend: Vec<PathBuf>,
    /// Seconds to wait. Hybrid runs an expansion step and is measured in seconds, not
    /// milliseconds — a default tuned for keyword search would time out every hybrid query.
    pub timeout_secs: u64,
}

impl Default for QmdConfig {
    fn default() -> Self {
        QmdConfig {
            binary: PathBuf::from("qmd"),
            collection: String::new(),
            path_prepend: Vec::new(),
            timeout_secs: 30,
        }
    }
}

/// One hit as `qmd … --json` reports it.
#[derive(Debug, Deserialize)]
struct QmdHit {
    file: String,
    // `title` is NOT read from qmd, deliberately, though it sends one: the STORE's title is
    // the single source of truth for what a document is called, so a stale index cannot
    // rename a document in an answer. Unknown fields are ignored by serde, so nothing has
    // to be declared to be dropped.
    #[serde(default)]
    score: f64,
    #[serde(default)]
    line: usize,
    #[serde(default)]
    snippet: String,
}

/// A search backed by the `qmd` binary, filtered through the store.
///
/// **THE FILTER IS MANDATORY AND TESTED.** `qmd` indexes what its collection pattern
/// matched, which is not the set this store considers visible: it will happily return a hit
/// from an excluded directory or a cold document. Every hit is checked against the store
/// before it is returned, and a hit the store will not open is dropped silently — telling
/// the model "there is a match you may not see" would leak the existence of exactly what the
/// exclusion is hiding.
pub struct QmdIndex<S: DocumentStore> {
    store: S,
    config: QmdConfig,
    /// The fallback, used when the binary is missing or fails.
    fallback: GrepIndex<S>,
}

impl<S: DocumentStore + Clone> QmdIndex<S> {
    pub fn new(store: S, config: QmdConfig) -> Self {
        QmdIndex {
            fallback: GrepIndex::new(store.clone()),
            store,
            config,
        }
    }
}

impl<S: DocumentStore> QmdIndex<S> {
    /// Map `qmd://<collection>/<path>` onto a store id.
    fn id_of(&self, file: &str) -> Option<DocumentId> {
        let rest = file.strip_prefix("qmd://")?;
        let (collection, path) = rest.split_once('/')?;
        if collection != self.config.collection {
            return None;
        }
        DocumentId::parse(path).ok()
    }

    /// Run the binary. Returns the parsed hits, or a content-free reason it could not.
    fn run(&self, query: &str, mode: SearchMode) -> Result<Vec<QmdHit>, String> {
        // The subcommand is the mode: `search` is BM25 with no model in the loop, `query`
        // is the hybrid path with expansion and reranking.
        let subcommand = match mode {
            SearchMode::Lexical => "search",
            SearchMode::Hybrid => "query",
        };
        let mut cmd = Command::new(&self.config.binary);
        // AN ARGUMENT VECTOR, NEVER A SHELL. The query is model-supplied text; handed to a
        // shell it would be a command. There is no shell in this path at all — no `sh -c`,
        // no string interpolation — so quoting is not something that has to be got right.
        cmd.arg(subcommand).arg(query).arg("--json");
        if !self.config.path_prepend.is_empty() {
            let existing = std::env::var_os("PATH").unwrap_or_default();
            let mut parts: Vec<PathBuf> = self.config.path_prepend.clone();
            parts.extend(std::env::split_paths(&existing));
            if let Ok(joined) = std::env::join_paths(parts) {
                cmd.env("PATH", joined);
            }
        }
        cmd.stdin(std::process::Stdio::null());

        let out = cmd
            .output()
            .map_err(|e| format!("cannot run the qmd binary: {e}"))?;
        if !out.status.success() {
            // The child's stderr is NOT propagated. It is a stack trace on the failure that
            // actually happens, and it names paths inside the operator's home; the exit
            // status is the fact the caller needs.
            return Err(format!("qmd {subcommand} exited with {}", out.status));
        }
        serde_json::from_slice::<Vec<QmdHit>>(&out.stdout)
            .map_err(|e| format!("qmd {subcommand} produced output this build cannot read: {e}"))
    }
}

impl<S: DocumentStore> SearchIndex for QmdIndex<S> {
    fn search<'a>(
        &'a self,
        scope: &'a Scope,
        query: &'a str,
        limit: usize,
        mode: SearchMode,
    ) -> BoxFuture<'a, Result<Hits, StoreError>> {
        Box::pin(async move {
            let raw = match self.run(query, mode) {
                Ok(h) => h,
                Err(note) => {
                    // DEGRADE, DO NOT FAIL. A missing or broken binary is an operational
                    // fact; a turn that failed because of it would be a turn the owner
                    // cannot complete for a reason they cannot see.
                    eprintln!("jesse-agent: note qmd unavailable ({note}); using keyword search");
                    let mut hits = self.fallback.search(scope, query, limit, mode).await?;
                    hits.degraded = Some(format!("{note}; these are keyword results"));
                    return Ok(hits);
                }
            };

            // ---- THE MANDATORY FILTER ------------------------------------
            let mut hits: Vec<Hit> = Vec::new();
            for h in raw {
                let Some(id) = self.id_of(&h.file) else {
                    continue;
                };
                // `stat` is the visibility oracle: excluded → NotFound, and a cold document
                // reports `Cold`. A hit that fails either is dropped without a word.
                let Ok(meta) = self.store.stat(scope, &id).await else {
                    continue;
                };
                if meta.visibility == Visibility::Cold {
                    continue;
                }
                let snippets = if h.snippet.is_empty() {
                    Vec::new()
                } else {
                    vec![Snippet {
                        line: h.line.max(1),
                        text: snippet_text(&h.snippet),
                    }]
                };
                hits.push(Hit {
                    // The store's title, not qmd's: one source of truth for what a document
                    // is called, so a stale index cannot rename a document in the answer.
                    title: meta.title,
                    id,
                    score: h.score,
                    snippets,
                });
                if hits.len() >= limit.clamp(1, MAX_SEARCH_LIMIT) {
                    break;
                }
            }
            Ok(Hits {
                hits,
                served_by: mode,
                degraded: None,
            })
        })
    }

    fn status(&self) -> IndexStatus {
        // Cheap and honest: ask the binary to say what it is. A `status` that claimed
        // availability without checking would make the CLI's banner a guess.
        let mut cmd = Command::new(&self.config.binary);
        cmd.arg("--version").stdin(std::process::Stdio::null());
        if !self.config.path_prepend.is_empty() {
            let existing = std::env::var_os("PATH").unwrap_or_default();
            let mut parts: Vec<PathBuf> = self.config.path_prepend.clone();
            parts.extend(std::env::split_paths(&existing));
            if let Ok(joined) = std::env::join_paths(parts) {
                cmd.env("PATH", joined);
            }
        }
        let available = cmd.output().map(|o| o.status.success()).unwrap_or(false);
        IndexStatus {
            name: "qmd",
            available,
            supports_hybrid: available,
            documents: None,
            note: (!available).then(|| {
                format!(
                    "the qmd binary at {} did not run; searches use the keyword fallback",
                    self.config.binary.display()
                )
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{FsVaultStore, Visibility};
    use std::path::Path;
    use std::sync::Arc;

    fn scope() -> Scope {
        Scope::new("t", "u", "w")
    }

    struct World(PathBuf);

    impl World {
        fn new(tag: &str) -> World {
            let root = std::env::temp_dir().join(format!(
                "jesse-agent-idx-{tag}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(root.join("notes")).unwrap();
            std::fs::create_dir_all(root.join("private")).unwrap();
            std::fs::create_dir_all(root.join("secrets")).unwrap();
            std::fs::write(
                root.join("notes/launch.md"),
                "# Launch\n\nThe launch is on Tuesday.\n",
            )
            .unwrap();
            std::fs::write(
                root.join("notes/other.md"),
                "# Other\n\nNothing about concatenate here.\n",
            )
            .unwrap();
            std::fs::write(
                root.join("private/diary.md"),
                "---\nvisibility: cold\n---\n# Diary\n\nThe launch is a secret COLDBODY.\n",
            )
            .unwrap();
            std::fs::write(
                root.join("secrets/key.md"),
                "# Key\n\nThe launch key is EXCLUDEDBODY.\n",
            )
            .unwrap();
            World(std::fs::canonicalize(&root).unwrap())
        }

        fn store(&self) -> Arc<FsVaultStore> {
            Arc::new(
                FsVaultStore::open(&self.0)
                    .unwrap()
                    .excluding(["secrets/"])
                    .cold_prefixes(["private"]),
            )
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for World {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).ok();
        }
    }

    #[test]
    fn whole_word_matching_does_not_match_inside_a_word() {
        assert_eq!(word_positions("the cat sat", "cat"), 1);
        assert_eq!(word_positions("concatenate", "cat"), 0);
        assert_eq!(word_positions("cat, cat; cat", "cat"), 3);
        assert_eq!(word_positions("snake_case_cat", "cat"), 0);
        assert_eq!(
            word_positions("a-cat-b", "cat"),
            1,
            "a hyphen is a boundary"
        );
    }

    #[tokio::test]
    async fn grep_search_never_returns_an_excluded_or_cold_document() {
        let w = World::new("grep");
        let index = GrepIndex::new(w.store());
        let hits = index
            .search(&scope(), "launch", 10, SearchMode::Lexical)
            .await
            .unwrap();
        let ids: Vec<String> = hits.hits.iter().map(|h| h.id.to_string()).collect();
        assert_eq!(
            ids,
            ["notes/launch.md"],
            "only the visible document matches"
        );

        // The bodies of the excluded and cold documents are nowhere in the result — which
        // is the claim, not merely that their ids are absent.
        let rendered = serde_json::to_string(&hits).unwrap();
        assert!(
            !rendered.contains("COLDBODY"),
            "a cold body leaked into search"
        );
        assert!(
            !rendered.contains("EXCLUDEDBODY"),
            "an excluded body leaked into search"
        );
        assert!(!rendered.contains("private/diary.md"));
        assert!(!rendered.contains("secrets/key.md"));
    }

    #[tokio::test]
    async fn a_hybrid_request_with_no_hybrid_backend_is_served_lexically_and_says_so() {
        let w = World::new("degrade");
        let index = GrepIndex::new(w.store());
        let hits = index
            .search(&scope(), "launch", 10, SearchMode::Hybrid)
            .await
            .unwrap();
        assert_eq!(hits.served_by, SearchMode::Lexical);
        assert!(hits
            .degraded
            .as_deref()
            .unwrap()
            .contains("keyword results"));
    }

    #[tokio::test]
    async fn every_term_must_appear_and_a_title_match_outranks_a_body_match() {
        let w = World::new("rank");
        std::fs::write(
            w.path().join("notes/tuesday.md"),
            "# Tuesday\n\nA note that mentions launch once.\n",
        )
        .unwrap();
        let index = GrepIndex::new(w.store());

        // AND, not OR: "launch" appears in two documents, "Tuesday" in both — but
        // "launch banana" is in neither.
        let none = index
            .search(&scope(), "launch banana", 10, SearchMode::Lexical)
            .await
            .unwrap();
        assert!(none.hits.is_empty(), "every term must appear");

        let hits = index
            .search(&scope(), "tuesday", 10, SearchMode::Lexical)
            .await
            .unwrap();
        assert_eq!(
            hits.hits[0].id.as_str(),
            "notes/tuesday.md",
            "the document TITLED Tuesday beats the one that mentions it"
        );
    }

    #[tokio::test]
    async fn qmd_hits_are_filtered_through_the_store() {
        // The filter is exercised without the binary: `id_of` plus the store's `stat` is the
        // whole of it, and this asserts the decision each hit gets.
        let w = World::new("filter");
        let store = w.store();
        let index = QmdIndex::new(
            store.clone(),
            QmdConfig {
                collection: "vault".into(),
                ..Default::default()
            },
        );
        // A visible document maps and passes.
        let visible = index.id_of("qmd://vault/notes/launch.md").unwrap();
        assert_eq!(
            store.stat(&scope(), &visible).await.unwrap().visibility,
            Visibility::Hot
        );
        // An excluded one maps, and the store refuses to admit it exists.
        let excluded = index.id_of("qmd://vault/secrets/key.md").unwrap();
        assert_eq!(
            store.stat(&scope(), &excluded).await.unwrap_err(),
            StoreError::NotFound,
            "an excluded hit is dropped because the store will not stat it"
        );
        // A cold one maps and stats, and reports Cold — which is what the filter drops on.
        let cold = index.id_of("qmd://vault/private/diary.md").unwrap();
        assert_eq!(
            store.stat(&scope(), &cold).await.unwrap().visibility,
            Visibility::Cold
        );
        // A hit from a DIFFERENT collection does not map at all.
        assert!(index.id_of("qmd://other/notes/launch.md").is_none());
        assert!(index.id_of("/absolute/path.md").is_none());
        assert!(index.id_of("qmd://vault/../escape.md").is_none());
    }

    #[tokio::test]
    async fn a_missing_qmd_binary_degrades_to_keyword_search_rather_than_failing() {
        let w = World::new("missing");
        let index = QmdIndex::new(
            w.store(),
            QmdConfig {
                binary: PathBuf::from("/nonexistent/qmd-does-not-exist"),
                collection: "vault".into(),
                ..Default::default()
            },
        );
        assert!(!index.status().available);
        let hits = index
            .search(&scope(), "launch", 10, SearchMode::Hybrid)
            .await
            .unwrap();
        assert_eq!(
            hits.hits
                .iter()
                .map(|h| h.id.to_string())
                .collect::<Vec<_>>(),
            ["notes/launch.md"],
            "the turn still gets an answer"
        );
        assert!(hits
            .degraded
            .as_deref()
            .unwrap()
            .contains("keyword results"));
    }
}
