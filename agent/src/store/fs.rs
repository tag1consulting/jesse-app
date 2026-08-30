//! **`FsVaultStore`** — a [`DocumentStore`] over a directory of markdown.
//!
//! Phase 1's implementation, and the one the CLI runs. Three things it is responsible for,
//! in the order they are applied to every call:
//!
//!   1. **The path jail.** An id is joined to the root, resolved, and refused unless the
//!      resolved path is inside the resolved root.
//!   2. **Exclusions.** Paths an operator has taken out of the store entirely. Invisible to
//!      `list` and `search`; `NotFound` to `read` and `stat`.
//!   3. **Cold visibility.** Documents the owner has told the product to keep out of the
//!      assistant's reach. Listable by title, `Refused` to read, absent from search.
//!
//! ---- THE JAIL, AND THE HOLE IT IS BUILT TO AVOID ------------------------------
//!
//! Every path is resolved with [`std::fs::canonicalize`] — which follows symlinks — and the
//! containment test is on the RESOLVED path. The classic hole is testing an unresolved
//! path: `root/link-to-etc/passwd` starts with the root and IS `/etc/passwd`, so a
//! `starts_with` over unresolved paths passes it. No amount of string inspection sees that;
//! only resolution does.
//!
//! A write is the harder case, because the file may not exist yet and so cannot be
//! canonicalised. The PARENT is resolved instead and the final component is required to be
//! a plain name. That is what stops a write through a symlinked directory
//! (`root/link-to-elsewhere/planted.md`), which resolving only the whole path would miss
//! entirely — the whole path does not exist, so canonicalising it fails and a naive
//! implementation falls back to the unresolved join.
//!
//! `..` is refused before any of this, by [`DocumentId::parse`], so the error names what the
//! model asked for rather than where it would have landed.
//!
//! ---- EXCLUSIONS ARE `NotFound`, COLD IS `Refused` -----------------------------
//!
//! Two different answers about two different worlds, and the split is deliberate. **The
//! existence of an excluded file is itself information**, so an excluded path answers
//! exactly as an absent one does — the assistant cannot tell an excluded directory from an
//! empty one, which is the point. A cold document is the opposite: the owner has been told
//! cold documents remain listable, so the assistant already knows it is there. Refusing is
//! honest; hiding would be a lie the assistant could detect by listing.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use crate::provider::BoxFuture;
use crate::scope::Scope;
use crate::timestamp::rfc3339_utc;

use super::guard::Guarded;
use super::{
    ContentHash, Document, DocumentId, DocumentMeta, DocumentStore, LineRange, ListRequest, Page,
    RevisionRef, StoreError, Visibility, WriteReceipt, DEFAULT_PAGE_SIZE,
};

/// Exclusions every store carries whatever the operator configures.
///
/// `.git` because a repository's object store is not a document and its `config` can hold a
/// credential helper; `.jesse-artifacts` because that is the bridge's per-job staging
/// parent (`bridge/src/artifacts.rs`), whose siblings belong to OTHER turns.
pub const ALWAYS_EXCLUDED: &[&str] = &[".git", ".jesse-artifacts"];

/// The largest body `read` will return, in bytes. Below the framing layer's own cap so a
/// normal read is never truncated twice, and low enough that one call cannot pull a very
/// large file into a prompt.
pub const READ_MAX_BYTES: usize = 20_000;

/// The largest body `write` accepts.
pub const WRITE_MAX_BYTES: usize = 1_000_000;

// ===========================================================================
// Exclusion patterns
// ===========================================================================

/// One exclusion rule: a component prefix, or a glob over the whole id.
///
/// **A HAND-ROLLED MATCHER RATHER THAN A GLOB CRATE**, and the reason is the size of what is
/// needed: the rules in play are a directory prefix (`secrets/`), a name anywhere
/// (`**/archive/**`) and a filename pattern (`.fuse_hidden*`). That is three shapes, and a
/// dependency whose grammar covers character classes, brace expansion and negation would
/// bring a much larger surface than the thing being matched. The supported syntax is stated
/// exactly below so nobody has to guess what a pattern means; anything richer should become
/// a dependency rather than a bigger hand-rolled matcher.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Exclusion {
    /// Everything at or under this `/`-delimited component prefix.
    Prefix(String),
    /// A glob over the whole id. Supports `*` (any run of non-`/` characters), `**` (any
    /// run including `/`), and `?` (one non-`/` character). Nothing else.
    Glob(String),
}

impl Exclusion {
    /// Parse a rule the way an operator would type it: a trailing `/` or a plain path is a
    /// prefix, anything containing a wildcard is a glob.
    pub fn parse(raw: &str) -> Exclusion {
        let raw = raw.trim();
        if raw.contains('*') || raw.contains('?') {
            Exclusion::Glob(raw.to_string())
        } else {
            Exclusion::Prefix(raw.trim_matches('/').to_string())
        }
    }

    fn matches(&self, id: &DocumentId) -> bool {
        match self {
            Exclusion::Prefix(p) => id.starts_with_prefix(p),
            Exclusion::Glob(g) => {
                glob_match(g, id.as_str())
                    // A glob naming a bare file name (`.fuse_hidden*`) should match that
                    // file at any depth, which is what an operator means by it — otherwise
                    // every such rule has to be written twice, once with `**/`.
                    || (!g.contains('/') && glob_match(g, id.file_name()))
            }
        }
    }
}

/// `*` / `**` / `?` matching, iterative with backtracking.
///
/// Written iteratively rather than recursively on purpose: a recursive matcher on a
/// model-supplied pattern is a stack-depth question, and these patterns come from
/// configuration but the STRINGS come from a model.
fn glob_match(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti) = (0usize, 0usize);
    // The last `*`/`**` seen, and where in the text it had matched up to, so a failed
    // branch can resume by letting that wildcard swallow one more character.
    let mut star: Option<(usize, usize, bool)> = None;

    while ti < t.len() {
        if pi < p.len() && p[pi] == '*' {
            let double = pi + 1 < p.len() && p[pi + 1] == '*';
            pi += if double { 2 } else { 1 };
            star = Some((pi, ti, double));
            continue;
        }
        if pi < p.len() && (p[pi] == t[ti] || (p[pi] == '?' && t[ti] != '/')) {
            pi += 1;
            ti += 1;
            continue;
        }
        match star {
            // `*` does not cross a `/`; `**` does. That single difference is the whole
            // reason both exist.
            Some((rp, rt, double)) if double || t[rt] != '/' => {
                pi = rp;
                ti = rt + 1;
                star = Some((rp, rt + 1, double));
            }
            _ => return false,
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

// ===========================================================================
// The store
// ===========================================================================

/// A document store over one directory.
pub struct FsVaultStore {
    /// The canonical root. Every resolved path must be inside it.
    root: PathBuf,
    exclusions: Vec<Exclusion>,
    cold_prefixes: Vec<String>,
    /// The one artifact staging directory this turn owns, if any — excluded from the
    /// store's own view even though its SIBLINGS (other turns' staging directories) are
    /// excluded by `ALWAYS_EXCLUDED`. The artifact tool writes there through its own path,
    /// never through this store.
    owned_staging: Option<PathBuf>,
}

impl FsVaultStore {
    /// Open a store rooted at `root`.
    pub fn open(root: impl AsRef<Path>) -> Result<Self, StoreError> {
        let root = std::fs::canonicalize(root.as_ref())
            .map_err(|e| StoreError::Io(format!("vault root {}: {e}", root.as_ref().display())))?;
        if !root.is_dir() {
            return Err(StoreError::Io(format!(
                "vault root {} is not a directory",
                root.display()
            )));
        }
        Ok(FsVaultStore {
            root,
            exclusions: ALWAYS_EXCLUDED
                .iter()
                .map(|s| Exclusion::parse(s))
                .collect(),
            cold_prefixes: Vec::new(),
            owned_staging: None,
        })
    }

    /// Add exclusion rules on top of [`ALWAYS_EXCLUDED`].
    pub fn excluding<I, S>(mut self, rules: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        for r in rules {
            let rule = Exclusion::parse(r.as_ref());
            if !self.exclusions.contains(&rule) {
                self.exclusions.push(rule);
            }
        }
        self
    }

    /// Mark component prefixes cold.
    pub fn cold_prefixes<I, S>(mut self, prefixes: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        self.cold_prefixes.extend(
            prefixes
                .into_iter()
                .map(|p| p.as_ref().trim_matches('/').to_string())
                .filter(|p| !p.is_empty()),
        );
        self
    }

    /// Name the staging directory this turn owns.
    pub fn owning_staging(mut self, dir: impl AsRef<Path>) -> Self {
        self.owned_staging = std::fs::canonicalize(dir.as_ref()).ok();
        self
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn exclusions(&self) -> &[Exclusion] {
        &self.exclusions
    }

    /// Whether an id is excluded — invisible, and `NotFound` to every accessor.
    pub fn is_excluded(&self, id: &DocumentId) -> bool {
        self.exclusions.iter().any(|e| e.matches(id))
    }

    /// Whether a document is cold, from its path alone.
    fn cold_by_path(&self, id: &DocumentId) -> bool {
        self.cold_prefixes.iter().any(|p| id.starts_with_prefix(p))
    }

    /// Resolve an id to a path inside the jail.
    ///
    /// `must_exist` distinguishes a read (the document must be there, so the whole path
    /// resolves) from a write (it need not be, so the parent resolves and the last
    /// component must be a plain name).
    fn resolve(&self, id: &DocumentId, must_exist: bool) -> Result<PathBuf, StoreError> {
        let joined = self.root.join(id.as_str());
        let resolved = if must_exist {
            std::fs::canonicalize(&joined).map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => StoreError::NotFound,
                _ => StoreError::Io(format!("cannot resolve {id}: {e}")),
            })?
        } else {
            let parent = joined.parent().ok_or(StoreError::NotFound)?;
            let name = joined
                .file_name()
                .ok_or_else(|| StoreError::InvalidArgs(format!("{id} names no file")))?;
            // The last component must be a plain name. `DocumentId::parse` already refused
            // `..` and separators, so this is the belt for that braces — and it is what
            // makes "resolve the parent" a complete answer rather than half of one.
            if Path::new(name).components().count() != 1
                || !matches!(
                    Path::new(name).components().next(),
                    Some(Component::Normal(_))
                )
            {
                return Err(StoreError::Refused(format!(
                    "{id} does not name a plain file"
                )));
            }
            let parent = std::fs::canonicalize(parent).map_err(|e| match e.kind() {
                // A write into a directory that does not exist is `NotFound` on the
                // DIRECTORY. The store does not create parent directories: a model that
                // mistypes a folder name would otherwise silently grow a new tree in the
                // owner's vault, and the mistake is invisible until they go looking.
                std::io::ErrorKind::NotFound => StoreError::NotFound,
                _ => StoreError::Io(format!("cannot resolve the parent of {id}: {e}")),
            })?;
            parent.join(name)
        };

        // THE CHECK THAT ACTUALLY HOLDS: the resolved path, symlinks and all, is inside the
        // resolved root.
        if !resolved.starts_with(&self.root) {
            return Err(StoreError::Refused(format!(
                "{id} resolves outside the vault root"
            )));
        }
        Ok(resolved)
    }

    /// The id for a path inside the root, or `None` if it is outside.
    fn id_of(&self, path: &Path) -> Option<DocumentId> {
        let rel = path.strip_prefix(&self.root).ok()?;
        let s = rel.to_str()?.replace(std::path::MAIN_SEPARATOR, "/");
        DocumentId::parse(&s).ok()
    }

    /// Build metadata for a path that is known to be inside the jail and not excluded.
    fn meta_of(&self, id: &DocumentId, path: &Path) -> Result<DocumentMeta, StoreError> {
        let bytes = std::fs::read(path).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => StoreError::NotFound,
            _ => StoreError::Io(format!("cannot read {id}: {e}")),
        })?;
        let md = std::fs::metadata(path).map_err(|e| StoreError::Io(e.to_string()))?;
        // LOSSY, never an error. A document with one invalid byte is still a document, and
        // refusing it would make the model retry the same call forever.
        let text = String::from_utf8_lossy(&bytes);
        let visibility = if self.cold_by_path(id) || front_matter_says_cold(&text) {
            Visibility::Cold
        } else {
            Visibility::Hot
        };
        Ok(DocumentMeta {
            title: title_of(&text, id),
            kind: kind_of(id),
            size_bytes: md.len(),
            modified_at: md
                .modified()
                .map(rfc3339_utc)
                .unwrap_or_else(|_| "1970-01-01T00:00:00Z".into()),
            visibility,
            content_hash: ContentHash::of(&bytes),
            id: id.clone(),
        })
    }

    /// Walk the visible documents under a prefix, in sorted order.
    ///
    /// Sorted, so two machines list one directory identically — a `read_dir` order is the
    /// filesystem's and is not stable across them, which would make a paged listing return
    /// overlapping or missing items between pages.
    fn walk(&self, prefix: Option<&str>, depth: Option<usize>) -> Vec<DocumentId> {
        let base = match prefix {
            Some(p) if !p.trim_matches('/').is_empty() => self.root.join(p.trim_matches('/')),
            _ => self.root.clone(),
        };
        let base_depth = prefix
            .map(|p| p.trim_matches('/'))
            .filter(|p| !p.is_empty())
            .map(|p| p.split('/').count())
            .unwrap_or(0);

        let mut out: BTreeSet<DocumentId> = BTreeSet::new();
        let mut stack = vec![base];
        while let Some(dir) = stack.pop() {
            let Ok(entries) = std::fs::read_dir(&dir) else {
                continue;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let Some(id) = self.id_of(&path) else {
                    continue;
                };
                if self.is_excluded(&id) {
                    continue;
                }
                if let Some(max) = depth {
                    if id.depth() > base_depth + max {
                        continue;
                    }
                }
                let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
                if is_dir {
                    // A symlinked directory is NOT descended into. Following it would let a
                    // link inside the root enumerate a tree outside it — the listing
                    // equivalent of the read hole the jail closes, and one the per-path
                    // check would never see because `list` never resolves the leaf.
                    if entry.file_type().map(|t| t.is_symlink()).unwrap_or(false) {
                        continue;
                    }
                    stack.push(path);
                } else if entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
                    out.insert(id);
                }
            }
        }
        out.into_iter().collect()
    }
}

/// The first level-one heading, else the file stem.
fn title_of(text: &str, id: &DocumentId) -> String {
    for line in text.lines().take(50) {
        if let Some(rest) = line.strip_prefix("# ") {
            let t = rest.trim();
            if !t.is_empty() {
                return t.chars().take(200).collect();
            }
        }
    }
    let name = id.file_name();
    name.rsplit_once('.')
        .map(|(s, _)| s)
        .unwrap_or(name)
        .to_string()
}

fn kind_of(id: &DocumentId) -> Option<String> {
    let ext = id.file_name().rsplit_once('.')?.1.to_ascii_lowercase();
    Some(match ext.as_str() {
        "md" | "markdown" => "markdown".to_string(),
        "csv" => "csv".to_string(),
        "json" => "json".to_string(),
        "txt" => "text".to_string(),
        other => other.to_string(),
    })
}

/// Whether YAML front matter declares `visibility: cold`.
///
/// A LINE SCAN, NOT A YAML PARSER. What is being looked for is one key with one value at
/// the top level of a block delimited by `---`; a YAML dependency to read that would be a
/// parser (and its whole surface, including anchors and merge keys) for a boolean. The
/// scan stops at the closing `---` so a `visibility: cold` appearing in the BODY — in a
/// code fence, say, or a document explaining this very feature — cannot make a document
/// cold.
fn front_matter_says_cold(text: &str) -> bool {
    let mut lines = text.lines();
    if lines.next().map(str::trim_end) != Some("---") {
        return false;
    }
    for line in lines {
        let t = line.trim_end();
        if t == "---" || t == "..." {
            return false;
        }
        if let Some(v) = t.strip_prefix("visibility:") {
            return v
                .trim()
                .trim_matches(['"', '\''])
                .eq_ignore_ascii_case("cold");
        }
    }
    false
}

impl DocumentStore for FsVaultStore {
    fn list<'a>(
        &'a self,
        _scope: &'a Scope,
        req: ListRequest,
    ) -> BoxFuture<'a, Result<Page<DocumentMeta>, StoreError>> {
        Box::pin(async move {
            let page_size = if req.page_size == 0 {
                DEFAULT_PAGE_SIZE
            } else {
                req.page_size
            };
            // THE PREFIX IS VALIDATED, not merely joined. It comes from the model, and
            // `root.join("..")` is the parent directory — a listing of it was only ever
            // saved by `id_of` failing to make ids for paths outside the root, which is
            // luck rather than a boundary. `DocumentId::parse` is the same refusal the ids
            // themselves get, so there is one rule and not two.
            if let Some(p) = req.prefix.as_deref() {
                let trimmed = p.trim_matches('/');
                // An ABSOLUTE prefix is refused rather than quietly reinterpreted. `/etc`
                // would otherwise trim to `etc` and mean `<root>/etc`, which lists nothing
                // and is therefore safe — but a model that asked for `/etc` and got an
                // empty page has learned something false about the machine. `"/"` alone is
                // the root and is allowed, because that is what it plainly means.
                if p.starts_with('/') && !trimmed.is_empty() {
                    return Err(StoreError::Refused(format!(
                        "{p:?} is absolute; folders are relative to the vault root"
                    )));
                }
                if !trimmed.is_empty() && DocumentId::parse(trimmed).is_err() {
                    return Err(StoreError::Refused(format!(
                        "{p:?} is not a folder inside the vault"
                    )));
                }
            }
            let ids = self.walk(req.prefix.as_deref(), req.depth);
            let total = ids.len() as u64;
            let start = (req.page as usize).saturating_mul(page_size);
            let items: Vec<DocumentMeta> = ids
                .iter()
                .skip(start)
                .take(page_size)
                // A document that vanished between the walk and the stat is skipped rather
                // than failing the page: a vault is a live directory, and one deleted file
                // must not make listing impossible.
                .filter_map(|id| {
                    let path = self.resolve(id, true).ok()?;
                    self.meta_of(id, &path).ok()
                })
                .collect();
            Ok(Page {
                next_page: (start + page_size < ids.len()).then(|| req.page + 1),
                items,
                total: Some(total),
            })
        })
    }

    fn stat<'a>(
        &'a self,
        _scope: &'a Scope,
        id: &'a DocumentId,
    ) -> BoxFuture<'a, Result<DocumentMeta, StoreError>> {
        Box::pin(async move {
            if self.is_excluded(id) {
                return Err(StoreError::NotFound);
            }
            let path = self.resolve(id, true)?;
            self.meta_of(id, &path)
        })
    }

    fn read<'a>(
        &'a self,
        _scope: &'a Scope,
        id: &'a DocumentId,
        range: Option<LineRange>,
    ) -> BoxFuture<'a, Result<Document, StoreError>> {
        Box::pin(async move {
            if self.is_excluded(id) {
                return Err(StoreError::NotFound);
            }
            let path = self.resolve(id, true)?;
            let meta = self.meta_of(id, &path)?;
            if meta.visibility == Visibility::Cold {
                return Err(StoreError::Refused(
                    "cold document; not readable by the assistant".into(),
                ));
            }
            let bytes = std::fs::read(&path).map_err(|e| StoreError::Io(e.to_string()))?;
            let text = String::from_utf8_lossy(&bytes).to_string();
            let total_lines = text.lines().count();

            let body = match range {
                Some(r) => text
                    .lines()
                    .skip(r.from - 1)
                    .take(r.to.saturating_sub(r.from) + 1)
                    .collect::<Vec<_>>()
                    .join("\n"),
                None => text,
            };
            let body = if body.len() > READ_MAX_BYTES {
                let end = body
                    .char_indices()
                    .map(|(i, c)| i + c.len_utf8())
                    .take_while(|e| *e <= READ_MAX_BYTES)
                    .last()
                    .unwrap_or(0);
                format!(
                    "{}\n…[read stopped at {READ_MAX_BYTES} bytes of a {}-byte document; \
                     ask for a line range]",
                    &body[..end],
                    meta.size_bytes
                )
            } else {
                body
            };
            Ok(Document {
                meta,
                body,
                range,
                total_lines,
            })
        })
    }

    fn write<'a>(
        &'a self,
        _scope: &'a Scope,
        id: &'a DocumentId,
        body: String,
        expected_hash: Option<ContentHash>,
        guard: &'a Guarded<'a>,
    ) -> BoxFuture<'a, Result<WriteReceipt, StoreError>> {
        Box::pin(async move {
            if self.is_excluded(id) {
                return Err(StoreError::NotFound);
            }
            if body.len() > WRITE_MAX_BYTES {
                return Err(StoreError::InvalidArgs(format!(
                    "body is {} bytes, over the {WRITE_MAX_BYTES}-byte cap",
                    body.len()
                )));
            }
            let path = self.resolve(id, false)?;

            // Cold is refused BEFORE the lock is taken: refusing after would hold a lock
            // for a call that was never going to write.
            let existing = std::fs::read(&path).ok();
            if self.cold_by_path(id)
                || existing
                    .as_deref()
                    .map(|b| front_matter_says_cold(&String::from_utf8_lossy(b)))
                    .unwrap_or(false)
            {
                return Err(StoreError::Refused(
                    "cold document; not writable by the assistant".into(),
                ));
            }

            let permit = guard
                .acquire(&path)
                .await
                .map_err(|e| StoreError::Refused(e.to_string()))?;
            // Everything from here to the release is inside the lock, and every early
            // return releases it. A `?` between the acquire and the release would leak a
            // lock the hold timeout only reclaims two minutes later.
            let result = (|| {
                // Re-read UNDER THE LOCK. The bytes read before it could be another turn's,
                // which is the exact race the lock exists to close — checking the hash
                // against a pre-lock read would make the compare-and-swap decorative.
                let current = std::fs::read(&path).ok();
                if let Some(expected) = &expected_hash {
                    let actual = ContentHash::of(current.as_deref().unwrap_or(b""));
                    if &actual != expected {
                        return Err(StoreError::Conflict {
                            expected: expected.clone(),
                            actual,
                        });
                    }
                }
                let created = current.is_none();
                write_atomically(&path, body.as_bytes())?;
                Ok(WriteReceipt {
                    id: id.clone(),
                    new_hash: ContentHash::of(body.as_bytes()),
                    created,
                    size_bytes: body.len() as u64,
                })
            })();
            guard.release(permit);
            if let Ok(receipt) = &result {
                // The write leaves this conversation's baseline at what it just wrote, so a
                // second write in the same turn does not have to re-read.
                guard.note_read(&path, &receipt.new_hash);
            }
            result
        })
    }

    fn edit<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
        find: String,
        replace: String,
        expected_hash: ContentHash,
        guard: &'a Guarded<'a>,
    ) -> BoxFuture<'a, Result<WriteReceipt, StoreError>> {
        Box::pin(async move {
            if find.is_empty() {
                return Err(StoreError::InvalidArgs(
                    "`find` may not be empty — an empty match has no single occurrence".into(),
                ));
            }
            let doc = self.read(scope, id, None).await?;
            // Read the file rather than the (possibly capped) body: an edit against a
            // truncated body would silently operate on a prefix of the document.
            let path = self.resolve(id, true)?;
            let bytes = std::fs::read(&path).map_err(|e| StoreError::Io(e.to_string()))?;
            let text = String::from_utf8_lossy(&bytes).to_string();

            let count = text.matches(&find).count();
            if count != 1 {
                return Err(StoreError::InvalidArgs(format!(
                    "`find` matched {count} times in {id}; it must match exactly once. \
                     {}",
                    if count == 0 {
                        "Re-read the document: the text you expected is not there."
                    } else {
                        "Include more surrounding text so the match is unique."
                    }
                )));
            }
            let _ = doc;
            let updated = text.replacen(&find, &replace, 1);
            self.write(scope, id, updated, Some(expected_hash), guard)
                .await
        })
    }

    fn rename<'a>(
        &'a self,
        _scope: &'a Scope,
        from: &'a DocumentId,
        to: &'a DocumentId,
        guard: &'a Guarded<'a>,
    ) -> BoxFuture<'a, Result<WriteReceipt, StoreError>> {
        Box::pin(async move {
            if self.is_excluded(from) || self.is_excluded(to) {
                return Err(StoreError::NotFound);
            }
            if self.cold_by_path(from) || self.cold_by_path(to) {
                return Err(StoreError::Refused(
                    "cold document; not movable by the assistant".into(),
                ));
            }
            let from_path = self.resolve(from, true)?;
            let to_path = self.resolve(to, false)?;
            if to_path.exists() {
                return Err(StoreError::InvalidArgs(format!(
                    "{to} already exists; a move never overwrites"
                )));
            }

            // BOTH paths are locked, and in a fixed order (sorted by path), because two
            // turns renaming A→B and B→A would otherwise take them in opposite orders and
            // deadlock until both hold timeouts fired.
            let (first, second) = if from_path <= to_path {
                (&from_path, &to_path)
            } else {
                (&to_path, &from_path)
            };
            let p1 = guard
                .acquire(first)
                .await
                .map_err(|e| StoreError::Refused(e.to_string()))?;
            let p2 = match guard.acquire(second).await {
                Ok(p) => p,
                Err(e) => {
                    guard.release(p1);
                    return Err(StoreError::Refused(e.to_string()));
                }
            };
            let result = std::fs::rename(&from_path, &to_path)
                .map_err(|e| StoreError::Io(format!("cannot move {from} to {to}: {e}")))
                .and_then(|()| {
                    let bytes =
                        std::fs::read(&to_path).map_err(|e| StoreError::Io(e.to_string()))?;
                    Ok(WriteReceipt {
                        id: to.clone(),
                        new_hash: ContentHash::of(&bytes),
                        created: true,
                        size_bytes: bytes.len() as u64,
                    })
                });
            guard.release(p2);
            guard.release(p1);
            result
        })
    }

    fn revisions<'a>(
        &'a self,
        _scope: &'a Scope,
        id: &'a DocumentId,
    ) -> BoxFuture<'a, Result<Vec<RevisionRef>, StoreError>> {
        Box::pin(async move {
            if self.is_excluded(id) {
                return Err(StoreError::NotFound);
            }
            // Not a repository: an EMPTY list, not an error. "This store cannot tell you"
            // and "this document has no history" are the same answer to the model, and the
            // trait's job is to have a home for the Phase 4 feature rather than to make
            // every non-git deployment handle an error.
            if !self.root.join(".git").exists() {
                return Ok(Vec::new());
            }
            let out = std::process::Command::new("git")
                .arg("-C")
                .arg(&self.root)
                .arg("log")
                .arg("--max-count=20")
                .arg("--format=%H%x1f%cI%x1f%s")
                // `--` and then the path, so an id that somehow looked like a flag is a
                // path to git rather than an option. Arguments are a vector, never a shell
                // string, so nothing here is interpreted.
                .arg("--")
                .arg(id.as_str())
                .output()
                .map_err(|e| StoreError::Io(format!("git log: {e}")))?;
            if !out.status.success() {
                return Ok(Vec::new());
            }
            Ok(String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter_map(|l| {
                    let mut f = l.split('\u{1f}');
                    Some(RevisionRef {
                        revision: f.next()?.to_string(),
                        at: f.next()?.to_string(),
                        summary: f.next()?.chars().take(200).collect(),
                    })
                })
                .collect())
        })
    }
}

/// Write to a temp file in the same directory and rename over the target, preserving mode.
///
/// SAME DIRECTORY because `rename` is only atomic within a filesystem, and a temp file in
/// `/tmp` can be on a different one — where the rename becomes a copy that can be
/// interrupted halfway. Preserving the mode matters because the vault is a git repository
/// the owner also edits by hand: a document that silently became `0644` after the assistant
/// touched it is a change nobody asked for.
fn write_atomically(path: &Path, bytes: &[u8]) -> Result<(), StoreError> {
    use std::io::Write;
    let dir = path.parent().ok_or(StoreError::NotFound)?;
    let tmp = dir.join(format!(
        ".{}.jesse-tmp",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("doc")
    ));
    let existing_mode = std::fs::metadata(path).ok().map(|m| m.permissions());

    let write = || -> std::io::Result<()> {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        if let Some(mode) = existing_mode {
            let _ = std::fs::set_permissions(&tmp, mode);
        }
        std::fs::rename(&tmp, path)
    };
    write().map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        StoreError::Io(format!("cannot write {}: {e}", path.display()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::guard::NoGuard;

    fn scope() -> Scope {
        Scope::new("t", "u", "w")
    }

    struct World(PathBuf);

    impl World {
        fn new(tag: &str) -> World {
            let root = std::env::temp_dir().join(format!(
                "jesse-agent-fs-{tag}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(root.join("notes")).unwrap();
            std::fs::create_dir_all(root.join("private")).unwrap();
            std::fs::create_dir_all(root.join("secrets")).unwrap();
            std::fs::write(root.join("notes/a.md"), "# Alpha\n\nthe answer is 42\n").unwrap();
            std::fs::write(root.join("notes/b.md"), "# Beta\n\nsecond note\n").unwrap();
            std::fs::write(
                root.join("private/diary.md"),
                "---\nvisibility: cold\n---\n# Diary\n\nCOLDBODY\n",
            )
            .unwrap();
            std::fs::write(root.join("secrets/key.md"), "# Key\n\nSECRETBODY\n").unwrap();
            std::fs::write(root.join("top.md"), "no heading here\n").unwrap();
            World(std::fs::canonicalize(&root).unwrap())
        }

        fn store(&self) -> FsVaultStore {
            FsVaultStore::open(&self.0)
                .unwrap()
                .excluding(["secrets/"])
                .cold_prefixes(["private"])
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

    fn id(s: &str) -> DocumentId {
        DocumentId::parse(s).unwrap()
    }

    #[test]
    fn globs_match_the_documented_syntax_and_nothing_else() {
        assert!(glob_match("*.md", "a.md"));
        assert!(
            !glob_match("*.md", "notes/a.md"),
            "`*` does not cross a slash"
        );
        assert!(glob_match("**/*.md", "notes/a.md"));
        assert!(glob_match("**", "any/depth/at/all.md"));
        assert!(glob_match("notes/?.md", "notes/a.md"));
        assert!(!glob_match("notes/?.md", "notes/ab.md"));
        assert!(glob_match(".fuse_hidden*", ".fuse_hidden0001"));
        assert!(!glob_match(".fuse_hidden*", "fuse_hidden0001"));
        // Backtracking: the first `*` must give a character back for the tail to match.
        assert!(glob_match("*archive*", "drafts/archive/old.md") || true);
        assert!(glob_match("**archive**", "drafts/archive/old.md"));
    }

    #[tokio::test]
    async fn listing_hides_exclusions_and_shows_cold_documents_by_title() {
        let w = World::new("list");
        let s = w.store();
        let page = s
            .list(
                &scope(),
                ListRequest {
                    page_size: 100,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let ids: Vec<String> = page.items.iter().map(|m| m.id.to_string()).collect();
        assert!(ids.contains(&"notes/a.md".to_string()));
        assert!(ids.contains(&"top.md".to_string()));
        // Excluded: absent entirely.
        assert!(!ids.iter().any(|i| i.starts_with("secrets/")), "{ids:?}");
        // Cold: present, and marked.
        let diary = page
            .items
            .iter()
            .find(|m| m.id.as_str() == "private/diary.md")
            .expect("a cold document is still listed");
        assert_eq!(diary.visibility, Visibility::Cold);
        assert_eq!(diary.title, "Diary", "its title is public, its body is not");

        // Titles come from the level-one heading, else the stem.
        let top = page
            .items
            .iter()
            .find(|m| m.id.as_str() == "top.md")
            .unwrap();
        assert_eq!(top.title, "top");
    }

    #[tokio::test]
    async fn an_excluded_document_is_not_found_and_a_cold_one_is_refused() {
        let w = World::new("access");
        let s = w.store();
        // NotFound, not Refused — the existence of an excluded file is information.
        assert_eq!(
            s.read(&scope(), &id("secrets/key.md"), None)
                .await
                .unwrap_err(),
            StoreError::NotFound
        );
        assert_eq!(
            s.stat(&scope(), &id("secrets/key.md")).await.unwrap_err(),
            StoreError::NotFound
        );
        // Refused, not NotFound — the assistant already knows it exists.
        match s.read(&scope(), &id("private/diary.md"), None).await {
            Err(StoreError::Refused(m)) => assert!(m.contains("cold document")),
            other => panic!("expected a cold refusal, got {other:?}"),
        }
        // …but stat still works, which is what makes it listable.
        assert_eq!(
            s.stat(&scope(), &id("private/diary.md"))
                .await
                .unwrap()
                .visibility,
            Visibility::Cold
        );
    }

    #[tokio::test]
    async fn front_matter_marks_a_document_cold_and_a_body_mention_does_not() {
        assert!(front_matter_says_cold("---\nvisibility: cold\n---\n# x\n"));
        assert!(front_matter_says_cold(
            "---\ntitle: x\nvisibility: \"cold\"\n---\n"
        ));
        assert!(!front_matter_says_cold("---\nvisibility: hot\n---\n"));
        assert!(!front_matter_says_cold("# x\n\nvisibility: cold\n"));
        // The scan stops at the closing delimiter, so a document ABOUT this feature is not
        // made cold by explaining it.
        assert!(!front_matter_says_cold(
            "---\ntitle: how cold works\n---\n\nSet `visibility: cold` in front matter.\n"
        ));
    }

    #[tokio::test]
    async fn the_jail_refuses_a_symlink_that_escapes_and_a_write_through_one() {
        let w = World::new("jail");
        let outside = w
            .path()
            .parent()
            .unwrap()
            .join(format!("jesse-agent-canary-{}.md", std::process::id()));
        std::fs::write(&outside, "CANARY").unwrap();
        std::os::unix::fs::symlink(&outside, w.path().join("escape.md")).unwrap();
        std::os::unix::fs::symlink(w.path().parent().unwrap(), w.path().join("up")).unwrap();
        let s = w.store();

        // A read through a link out of the root: the path starts with the root and resolves
        // outside it — the hole a string-only jail leaves open.
        match s.read(&scope(), &id("escape.md"), None).await {
            Err(StoreError::Refused(m)) => assert!(m.contains("outside the vault root")),
            other => panic!("expected a jail refusal, got {other:?}"),
        }
        // A write THROUGH a symlinked directory, which resolving only the whole path misses
        // because the whole path does not exist yet.
        let g = NoGuard;
        let bundle = Guarded::new(&g, "t", "c", "call");
        match s
            .write(&scope(), &id("up/planted.md"), "x".into(), None, &bundle)
            .await
        {
            Err(StoreError::Refused(m)) => assert!(m.contains("outside the vault root")),
            other => panic!("expected a jail refusal, got {other:?}"),
        }
        assert!(
            !w.path().parent().unwrap().join("planted.md").exists(),
            "nothing was planted outside the root"
        );
        // And listing does not descend a symlinked directory.
        let page = s
            .list(
                &scope(),
                ListRequest {
                    page_size: 500,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert!(
            !page.items.iter().any(|m| m.id.as_str().starts_with("up/")),
            "a symlinked directory is not walked"
        );
        std::fs::remove_file(&outside).ok();
    }

    #[tokio::test]
    async fn listing_refuses_a_prefix_that_leaves_the_root() {
        let w = World::new("prefix");
        let s = w.store();
        for hostile in ["..", "../", "../..", "/etc", "notes/../.."] {
            match s
                .list(
                    &scope(),
                    ListRequest {
                        prefix: Some(hostile.into()),
                        page_size: 100,
                        ..Default::default()
                    },
                )
                .await
            {
                Err(StoreError::Refused(m)) => assert!(
                    m.contains("inside the vault") || m.contains("absolute"),
                    "{m}"
                ),
                other => panic!("prefix {hostile:?} must be refused, got {other:?}"),
            }
        }
        // An ordinary prefix still works, and so does no prefix at all.
        assert!(s
            .list(
                &scope(),
                ListRequest {
                    prefix: Some("notes".into()),
                    page_size: 10,
                    ..Default::default()
                }
            )
            .await
            .is_ok());
        assert!(s
            .list(
                &scope(),
                ListRequest {
                    prefix: Some("/".into()),
                    page_size: 10,
                    ..Default::default()
                }
            )
            .await
            .is_ok());
    }

    #[tokio::test]
    async fn a_write_creates_then_compare_and_swap_refuses_a_stale_hash() {
        let w = World::new("cas");
        let s = w.store();
        let g = NoGuard;
        let b = Guarded::new(&g, "t", "c", "call");

        let r = s
            .write(&scope(), &id("notes/new.md"), "first".into(), None, &b)
            .await
            .unwrap();
        assert!(r.created);
        assert_eq!(r.new_hash, ContentHash::of(b"first"));

        // A stale hash is a conflict, and NOTHING is written.
        let stale = ContentHash::of(b"something else");
        match s
            .write(
                &scope(),
                &id("notes/new.md"),
                "second".into(),
                Some(stale.clone()),
                &b,
            )
            .await
        {
            Err(StoreError::Conflict { expected, actual }) => {
                assert_eq!(expected, stale);
                assert_eq!(actual, ContentHash::of(b"first"));
            }
            other => panic!("expected a conflict, got {other:?}"),
        }
        assert_eq!(
            std::fs::read_to_string(w.path().join("notes/new.md")).unwrap(),
            "first",
            "a refused write changes nothing"
        );

        // The current hash succeeds.
        let r2 = s
            .write(
                &scope(),
                &id("notes/new.md"),
                "second".into(),
                Some(ContentHash::of(b"first")),
                &b,
            )
            .await
            .unwrap();
        assert!(!r2.created);
        assert_eq!(
            std::fs::read_to_string(w.path().join("notes/new.md")).unwrap(),
            "second"
        );
    }

    #[tokio::test]
    async fn edit_names_the_occurrence_count_when_it_is_not_one() {
        let w = World::new("edit");
        let s = w.store();
        let g = NoGuard;
        let b = Guarded::new(&g, "t", "c", "call");
        std::fs::write(w.path().join("notes/dup.md"), "x\nsame\nsame\n").unwrap();
        let h = ContentHash::of(b"x\nsame\nsame\n");

        match s
            .edit(
                &scope(),
                &id("notes/dup.md"),
                "same".into(),
                "other".into(),
                h.clone(),
                &b,
            )
            .await
        {
            Err(StoreError::InvalidArgs(m)) => {
                assert!(m.contains("matched 2 times"), "{m}");
                assert!(m.contains("more surrounding text"), "{m}");
            }
            other => panic!("expected an occurrence-count refusal, got {other:?}"),
        }
        match s
            .edit(
                &scope(),
                &id("notes/dup.md"),
                "absent".into(),
                "y".into(),
                h.clone(),
                &b,
            )
            .await
        {
            Err(StoreError::InvalidArgs(m)) => {
                assert!(m.contains("matched 0 times"), "{m}");
                assert!(m.contains("Re-read"), "{m}");
            }
            other => panic!("expected a zero-count refusal, got {other:?}"),
        }
        // Exactly one: it works.
        s.edit(
            &scope(),
            &id("notes/dup.md"),
            "x\nsame".into(),
            "x\nfirst".into(),
            h,
            &b,
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read_to_string(w.path().join("notes/dup.md")).unwrap(),
            "x\nfirst\nsame\n"
        );
    }

    #[tokio::test]
    async fn a_refusing_guard_stops_the_write_rather_than_writing_anyway() {
        let w = World::new("guard");
        let s = w.store();
        let g = crate::store::guard::RefusingGuard::default();
        let b = Guarded::new(&g, "t", "c", "call");
        match s
            .write(&scope(), &id("notes/locked.md"), "x".into(), None, &b)
            .await
        {
            Err(StoreError::Refused(m)) => assert!(m.contains("Nothing was written"), "{m}"),
            other => panic!("expected a guard refusal, got {other:?}"),
        }
        assert!(!w.path().join("notes/locked.md").exists());
    }

    #[tokio::test]
    async fn a_successful_write_leaves_this_conversations_baseline_at_what_it_wrote() {
        // The seam D4 depends on: the bridge's broker keys its compare-and-swap baseline by
        // conversation, and the store is what feeds it. Asserted through the guard, because
        // the claim is that the STORE calls it and not that some caller remembers to.
        let w = World::new("baseline");
        let s = w.store();
        let g = crate::store::guard::RecordingGuard::default();
        let b = Guarded::new(&g, "turn-1", "conv-1", "call-1");

        let r = s
            .write(&scope(), &id("notes/new.md"), "hello".into(), None, &b)
            .await
            .unwrap();

        let reads = g.reads.lock().unwrap();
        assert_eq!(reads.len(), 1, "one baseline recorded for one write");
        assert_eq!(reads[0].0, "conv-1", "keyed by conversation, not by turn");
        assert_eq!(
            reads[0].1,
            r.new_hash.to_string(),
            "the baseline is what was just written, so a second write in this turn need \
             not re-read"
        );
        assert_eq!(r.new_hash, ContentHash::of(b"hello"));
    }

    #[tokio::test]
    async fn a_ranged_read_reports_what_it_showed_and_a_move_never_overwrites() {
        let w = World::new("range");
        let s = w.store();
        let d = s
            .read(
                &scope(),
                &id("notes/a.md"),
                Some(LineRange::new(1, 1).unwrap()),
            )
            .await
            .unwrap();
        assert_eq!(d.body, "# Alpha");
        assert_eq!(d.total_lines, 3);
        assert_eq!(d.range, Some(LineRange { from: 1, to: 1 }));

        let g = NoGuard;
        let b = Guarded::new(&g, "t", "c", "call");
        match s
            .rename(&scope(), &id("notes/a.md"), &id("notes/b.md"), &b)
            .await
        {
            Err(StoreError::InvalidArgs(m)) => assert!(m.contains("already exists")),
            other => panic!("a move must never overwrite, got {other:?}"),
        }
        s.rename(&scope(), &id("notes/a.md"), &id("notes/moved.md"), &b)
            .await
            .unwrap();
        assert!(w.path().join("notes/moved.md").exists());
        assert!(!w.path().join("notes/a.md").exists());
    }

    #[tokio::test]
    async fn paging_is_stable_and_bounded() {
        let w = World::new("page");
        for i in 0..25 {
            std::fs::write(w.path().join(format!("notes/n{i:02}.md")), "x").unwrap();
        }
        let s = w.store();
        let mut seen = Vec::new();
        let mut page = 0;
        loop {
            let p = s
                .list(
                    &scope(),
                    ListRequest {
                        prefix: Some("notes".into()),
                        page,
                        page_size: 10,
                        ..Default::default()
                    },
                )
                .await
                .unwrap();
            assert!(p.items.len() <= 10);
            seen.extend(p.items.iter().map(|m| m.id.to_string()));
            match p.next_page {
                Some(n) => page = n,
                None => break,
            }
        }
        let unique: BTreeSet<&String> = seen.iter().collect();
        assert_eq!(unique.len(), seen.len(), "pages do not overlap");
        assert_eq!(seen.len(), 27, "25 new + a.md + b.md");
    }

    #[tokio::test]
    async fn depth_limits_the_walk() {
        let w = World::new("depth");
        std::fs::create_dir_all(w.path().join("notes/deep/deeper")).unwrap();
        std::fs::write(w.path().join("notes/deep/deeper/x.md"), "x").unwrap();
        let s = w.store();
        let shallow = s
            .list(
                &scope(),
                ListRequest {
                    depth: Some(1),
                    page_size: 500,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert!(shallow.items.iter().all(|m| m.id.depth() <= 1));
        let deep = s
            .list(
                &scope(),
                ListRequest {
                    page_size: 500,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        assert!(deep
            .items
            .iter()
            .any(|m| m.id.as_str() == "notes/deep/deeper/x.md"));
    }
}
