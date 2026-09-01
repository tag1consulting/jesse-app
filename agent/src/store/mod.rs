//! **The document store** — what a document is, and the trait the vault tools read and
//! write through.
//!
//! ---- WHY A TRAIT, WHEN PHASE 1 IS A DIRECTORY OF MARKDOWN --------------------
//!
//! Because Phase 2 is not. The product's documents will live in Postgres with bodies in
//! object storage, and the thing that must not change when that happens is the TOOLS: a
//! model's view of `vault_read` is part of the product's API, and re-teaching it is a
//! migration nobody can stage. So the tools are written against [`DocumentStore`], the
//! filesystem implementation ([`fs::FsVaultStore`]) is Phase 1's answer, and the swap is a
//! constructor change at one call site.
//!
//! **THE TRAIT IS ASYNC**, which the thread store in D2 deliberately is not, and the
//! contrast is worth stating because it looks inconsistent. `ThreadStore` appends a few
//! hundred bytes to a local file with nothing to wait for, so a boxed future per call would
//! have bought nothing. This trait cannot be sync for two independent reasons: a write must
//! `await` the write guard ([`guard::WriteGuard::acquire`]), which in D4 is a round trip to
//! the bridge's lock broker over a unix socket; and the Phase 2 implementation is a
//! database. A sync trait would force every future implementation to block a runtime thread
//! or wrap itself in `spawn_blocking`, which is the cost landing on exactly the
//! implementations that can least afford it.
//!
//! ---- EVERY METHOD TAKES THE SCOPE --------------------------------------------
//!
//! And every filesystem implementation ignores it. That is not an oversight: the Phase 1
//! bridge is single-tenant and binds one [`Scope`] per process, so there is nothing for the
//! filesystem store to key on. The parameter is there so the product implementation keys on
//! it without a signature change, and so no tool is ever written in a way that would have
//! to grow a tenant argument later. See [`crate::scope`] for why that is the shape.

use std::fmt;

use serde::{Deserialize, Serialize};

use crate::provider::BoxFuture;
use crate::scope::Scope;

pub mod fs;
pub mod guard;

pub use fs::FsVaultStore;
pub use guard::{GuardPermit, GuardRefused, Guarded, NoGuard, WriteGuard};

// ===========================================================================
// Ids and hashes
// ===========================================================================

/// A document's identity.
///
/// **In the filesystem implementation this is the vault-relative path with forward
/// slashes, normalised — and that is a PHASE 1 CHOICE the product replaces with a database
/// id.** It is written down here rather than left implicit because it is the decision most
/// likely to be mistaken for a permanent fact: every tool description tells the model that
/// an id is a path, so Phase 2 either keeps paths as an alias or re-teaches the model.
/// Naming the coupling now is what makes that a decision somebody takes rather than
/// discovers.
///
/// The inner string is PRIVATE and [`DocumentId::parse`] is the only way in, for the reason
/// [`crate::thread::ThreadId`]'s is: this value becomes a filesystem path, so an id that
/// could hold `..`, an absolute path or a NUL byte would be a traversal handed to the store
/// by the model. Refusing them at construction removes the class rather than checking for
/// it at each of the seven places a store touches the disk.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct DocumentId(String);

impl DocumentId {
    /// Parse and normalise a model-supplied id.
    ///
    /// Refuses, in this order, so the message names what was asked rather than where it
    /// would have landed: an empty id; a NUL byte; a Windows drive prefix or a leading
    /// separator (absolute); any `..` component. Backslashes are NOT silently translated to
    /// forward slashes — an id containing one is refused, because translating it would mean
    /// two spellings of one document and the store would have to decide which is canonical.
    pub fn parse(raw: &str) -> Result<Self, IdError> {
        if raw.is_empty() {
            return Err(IdError::new(IdRefusal::Malformed, "an id may not be empty"));
        }
        if raw.contains('\0') {
            return Err(IdError::new(
                IdRefusal::IllegalByte,
                "an id may not contain a NUL byte",
            ));
        }
        if raw.contains('\\') {
            return Err(IdError::new(
                IdRefusal::IllegalByte,
                "an id may not contain a backslash; ids use forward slashes",
            ));
        }
        if raw.starts_with('/') || raw.starts_with("~/") || raw.chars().nth(1) == Some(':') {
            return Err(IdError::new(
                IdRefusal::Absolute,
                format!("an id is relative to the vault root, not absolute: {raw:?}"),
            ));
        }
        let mut parts: Vec<&str> = Vec::new();
        for part in raw.split('/') {
            match part {
                // A doubled slash or a trailing one is a spelling of the same document, so
                // it normalises away rather than being refused — `notes//a.md` is nobody's
                // attack, it is a string join that went slightly wrong.
                "" | "." => continue,
                ".." => {
                    return Err(IdError::new(
                        IdRefusal::Traversal,
                        format!("an id may not contain `..`: {raw:?}"),
                    ))
                }
                p => parts.push(p),
            }
        }
        if parts.is_empty() {
            return Err(IdError::new(
                IdRefusal::Malformed,
                format!("{raw:?} names no document"),
            ));
        }
        Ok(DocumentId(parts.join("/")))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The id's last component — the file name.
    pub fn file_name(&self) -> &str {
        self.0.rsplit('/').next().unwrap_or(&self.0)
    }

    /// Whether this id sits under `prefix` (a `/`-delimited component prefix, not a string
    /// prefix — `notes` matches `notes/a.md` and never `notes-archive/a.md`).
    pub fn starts_with_prefix(&self, prefix: &str) -> bool {
        let prefix = prefix.trim_matches('/');
        if prefix.is_empty() {
            return true;
        }
        self.0 == prefix || self.0.starts_with(&format!("{prefix}/"))
    }

    /// How many `/`-separated components deep this id is. `a.md` is 1.
    pub fn depth(&self) -> usize {
        self.0.split('/').count()
    }
}

impl fmt::Display for DocumentId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl TryFrom<String> for DocumentId {
    type Error = IdError;

    fn try_from(s: String) -> Result<Self, Self::Error> {
        DocumentId::parse(&s)
    }
}

impl From<DocumentId> for String {
    fn from(id: DocumentId) -> String {
        id.0
    }
}

/// Why an id was refused.
///
/// **THE SPLIT EXISTS SO THE TRACE COUNTS CORRECTLY.** Every reason but `Malformed` is a
/// CONTAINMENT rule — a traversal, an absolute path, a NUL byte — and a containment rule
/// firing is the boundary working, which the trace must record as a refusal. Folding them
/// all into "bad arguments" would file every traversal attempt under "a tool broke", and the
/// refusal count is precisely the number an operator watches to see whether the boundary is
/// being probed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdRefusal {
    /// Empty, or names no document. The model got the shape wrong.
    Malformed,
    /// A `..` component.
    Traversal,
    /// Absolute, or a drive prefix.
    Absolute,
    /// A NUL byte or a backslash — a separator this store will not interpret.
    IllegalByte,
}

/// An id that is not a document id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IdError {
    pub refusal: IdRefusal,
    message: String,
}

impl IdError {
    fn new(refusal: IdRefusal, message: impl Into<String>) -> Self {
        IdError {
            refusal,
            message: message.into(),
        }
    }

    /// Whether this refusal is a containment rule rather than a malformed argument.
    pub fn is_containment(&self) -> bool {
        !matches!(self.refusal, IdRefusal::Malformed)
    }
}

impl fmt::Display for IdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for IdError {}

/// A document's content hash: lowercase hex SHA-256 of its bytes.
///
/// **BYTE-IDENTICAL TO `bridge/src/writelock.rs`'s `hash_file`** — the same algorithm, the
/// same crate (`ring`, already in both dependency graphs), the same hex encoding. That is
/// load bearing rather than tidy: D4 implements [`guard::WriteGuard`] over the bridge's
/// `LockBroker`, and feeds the broker's per-conversation compare-and-swap baseline from
/// this store's reads. Two hashes that disagreed would make every baseline comparison fail,
/// so a turn would either never be allowed to write or would be told its own write was
/// somebody else's.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ContentHash(String);

impl ContentHash {
    /// Hash bytes.
    pub fn of(bytes: &[u8]) -> Self {
        let d = ring::digest::digest(&ring::digest::SHA256, bytes);
        ContentHash::from_digest(d.as_ref())
    }

    /// The same hash, from a digest computed incrementally.
    ///
    /// A store that reads a large file in chunks cannot call [`ContentHash::of`], which
    /// wants every byte at once — and the whole point of reading in chunks is that they are
    /// never all resident. This is the same SHA-256 rendered the same way, so a hash from a
    /// streaming read and a hash from a buffer are interchangeable; the compare-and-swap
    /// cannot tell them apart, which is the property that matters.
    pub(crate) fn from_digest(digest: &[u8]) -> Self {
        ContentHash(digest.iter().map(|b| format!("{b:02x}")).collect())
    }

    /// Accept a hash the model handed back. Validated as 64 hex characters rather than
    /// taken on trust: an `expected_hash` that is not a hash can only ever fail the
    /// compare-and-swap, and failing it with "that is not a hash" is a message the model
    /// can act on where "the document changed" is one it cannot.
    pub fn parse(raw: &str) -> Result<Self, IdError> {
        let ok = raw.len() == 64 && raw.bytes().all(|b| b.is_ascii_hexdigit());
        if !ok {
            return Err(IdError::new(
                IdRefusal::Malformed,
                "expected_hash must be the 64-character hex hash from a prior read",
            ));
        }
        Ok(ContentHash(raw.to_ascii_lowercase()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ContentHash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

// ===========================================================================
// The document model
// ===========================================================================

/// Whether the assistant may see a document's body.
///
/// **THE SPLIT VAULT SHIPS AT LAUNCH**, so this attribute exists from the first commit
/// rather than being retrofitted. A `Cold` document is one the owner has told the product
/// to keep out of the assistant's reach — an old archive, a sensitive folder, a client's
/// material — and the product needs to be able to say so per document, not only per
/// directory.
///
/// `Cold` is deliberately NOT "invisible". A cold document still appears in
/// [`DocumentStore::list`] with
/// its title, because the alternative — hiding it entirely — makes the assistant confidently
/// tell the owner that a document they can see in their own vault does not exist. Listable,
/// unreadable, unsearchable is the honest posture: the assistant knows the document is
/// there and knows it may not read it, and can say exactly that.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Visibility {
    Hot,
    Cold,
}

impl fmt::Display for Visibility {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Visibility::Hot => "hot",
            Visibility::Cold => "cold",
        })
    }
}

/// What is known about a document without reading its body.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DocumentMeta {
    pub id: DocumentId,
    /// The first level-one heading, else the file stem. Titles are shown to the model for
    /// cold documents, so this must be derivable without exposing the body — a level-one
    /// heading is the one line a document publishes about itself.
    pub title: String,
    /// A coarse type (`markdown`, `csv`, …) when the store can tell. `None` rather than a
    /// guess: the model treats "I do not know" better than a wrong label.
    pub kind: Option<String>,
    pub size_bytes: u64,
    /// RFC-3339 UTC, fixed width — so an ordering is a string comparison.
    pub modified_at: String,
    pub visibility: Visibility,
    pub content_hash: ContentHash,
}

/// A document, with its body.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Document {
    pub meta: DocumentMeta,
    pub body: String,
    /// The lines actually returned, when a range was asked for. `None` means the whole
    /// document. Echoed back so the model knows what it is looking at rather than assuming
    /// its range was honoured.
    pub range: Option<LineRange>,
    /// The document's total line count, so a ranged read can say what it did not show.
    pub total_lines: usize,
}

/// A 1-based, inclusive line range.
///
/// One-based and inclusive because that is what a person and a model both mean by "lines 10
/// to 20", and what every editor and `sed` address agrees on. A zero-based half-open range
/// would be more natural in Rust and would silently disagree with every other tool the
/// answer is compared against.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct LineRange {
    pub from: usize,
    pub to: usize,
}

impl LineRange {
    /// Build a range, refusing a reversed or zero-based one.
    pub fn new(from: usize, to: usize) -> Result<Self, IdError> {
        if from == 0 {
            return Err(IdError::new(
                IdRefusal::Malformed,
                "line numbers are 1-based; from_line must be >= 1",
            ));
        }
        if to < from {
            return Err(IdError::new(
                IdRefusal::Malformed,
                format!("to_line ({to}) is before from_line ({from})"),
            ));
        }
        Ok(LineRange { from, to })
    }
}

impl fmt::Display for LineRange {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}-{}", self.from, self.to)
    }
}

/// One page of a listing.
///
/// **LISTING IS PAGED AND NEVER UNBOUNDED.** The real vault is over seven thousand
/// documents; a `list` that returned all of them would put a megabyte of file names into a
/// prompt, cost more than the answer, and be truncated by the framing layer anyway — so the
/// model would silently see an arbitrary prefix. A page with an explicit `next` lets the
/// model decide to go on, and lets the framing cap never be the thing that decides.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    /// The page number to ask for next, if there is more. `None` means this was the last.
    pub next_page: Option<u32>,
    /// How many items matched in total, when the store can say cheaply.
    pub total: Option<u64>,
}

/// What to list.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ListRequest {
    /// Restrict to ids under this component prefix. `None` is the whole store.
    pub prefix: Option<String>,
    /// How many components deep below the prefix to descend. `None` is unlimited.
    pub depth: Option<usize>,
    /// Zero-based page number.
    pub page: u32,
    pub page_size: usize,
}

/// The default page size for a listing. Sized so one page is a few hundred lines of framed
/// output — enough to be useful, small enough that the model is never handed a wall.
pub const DEFAULT_PAGE_SIZE: usize = 100;

/// What a write did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WriteReceipt {
    pub id: DocumentId,
    pub new_hash: ContentHash,
    /// The document did not exist before this call.
    pub created: bool,
    pub size_bytes: u64,
}

/// One prior version of a document.
///
/// **A TRAIT HOME NOW FOR A PHASE 4 FEATURE.** The product shows a revision list; the
/// filesystem store answers this from `git log` when the root is a repository and returns
/// empty otherwise. Defining it now costs one method and means the Phase 4 work is an
/// implementation rather than a change to a trait every tool depends on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RevisionRef {
    /// Opaque — a commit hash in the filesystem implementation.
    pub revision: String,
    /// RFC-3339 UTC.
    pub at: String,
    /// The commit subject. Content the OWNER wrote about their own vault, not document
    /// body text; still framed like everything else when it reaches the model.
    pub summary: String,
}

// ===========================================================================
// Errors
// ===========================================================================

/// Why a store operation did not happen.
///
/// The three-way split matters and maps onto [`crate::tools::ToolError`] exactly once, in
/// [`crate::tools::vault`]: `NotFound` and `Refused` are DIFFERENT ANSWERS ABOUT DIFFERENT
/// WORLDS, and conflating them leaks. An excluded document answers `NotFound`, because the
/// existence of a file the operator has excluded is itself information the assistant should
/// not have. A cold document answers `Refused`, because the owner has been told cold
/// documents are listable — the assistant already knows it exists, so refusing is honest and
/// hiding would be a lie it could detect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    /// No such document — or one the caller may not know exists.
    NotFound,
    /// A boundary said no: outside the jail, a cold body, a write at a read level.
    Refused(String),
    /// The arguments cannot be interpreted.
    InvalidArgs(String),
    /// The compare-and-swap failed: the document changed since the caller read it.
    Conflict {
        expected: ContentHash,
        actual: ContentHash,
    },
    /// The backing failed.
    Io(String),
}

impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            StoreError::NotFound => f.write_str("no such document"),
            StoreError::Refused(m) => write!(f, "{m}"),
            StoreError::InvalidArgs(m) => write!(f, "{m}"),
            // THE MESSAGE TELLS THE MODEL WHAT TO DO. A conflict the model cannot act on
            // becomes a retry of the identical write, which fails identically, forever.
            StoreError::Conflict { .. } => f.write_str(
                "the document changed since you read it. Read it again to get the current \
                 content and hash, decide whether your edit still applies, and write with \
                 the new expected_hash.",
            ),
            StoreError::Io(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for StoreError {}

// ===========================================================================
// The trait
// ===========================================================================

/// Where documents live.
pub trait DocumentStore: Send + Sync {
    /// One page of document metadata.
    fn list<'a>(
        &'a self,
        scope: &'a Scope,
        req: ListRequest,
    ) -> BoxFuture<'a, Result<Page<DocumentMeta>, StoreError>>;

    /// Metadata for one document, without its body.
    fn stat<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
    ) -> BoxFuture<'a, Result<DocumentMeta, StoreError>>;

    /// A document's body, whole or by line range.
    fn read<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
        range: Option<LineRange>,
    ) -> BoxFuture<'a, Result<Document, StoreError>>;

    /// Replace (or create) a document.
    ///
    /// `expected_hash` is the compare-and-swap. `None` means "I have not read this and do
    /// not care what is there", which is correct for a create and dangerous for an
    /// overwrite — the tool layer, not the store, is where that policy lives.
    fn write<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
        body: String,
        expected_hash: Option<ContentHash>,
        guard: &'a Guarded<'a>,
    ) -> BoxFuture<'a, Result<WriteReceipt, StoreError>>;

    /// Replace exactly one occurrence of `find` with `replace`.
    ///
    /// Zero or more than one occurrence is [`StoreError::InvalidArgs`] NAMING THE COUNT.
    /// That number is the whole value of the operation: "found 4" tells the model to
    /// lengthen its anchor, "found 0" tells it the document is not what it thought, and a
    /// bare "failed" tells it to try the same thing again.
    fn edit<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
        find: String,
        replace: String,
        expected_hash: ContentHash,
        guard: &'a Guarded<'a>,
    ) -> BoxFuture<'a, Result<WriteReceipt, StoreError>>;

    /// Move a document. Takes the guard on BOTH paths — a rename is two mutations.
    fn rename<'a>(
        &'a self,
        scope: &'a Scope,
        from: &'a DocumentId,
        to: &'a DocumentId,
        guard: &'a Guarded<'a>,
    ) -> BoxFuture<'a, Result<WriteReceipt, StoreError>>;

    /// Prior versions, newest first. Empty when the store cannot answer.
    fn revisions<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
    ) -> BoxFuture<'a, Result<Vec<RevisionRef>, StoreError>>;
}

/// **ONE STORE, SHARED.** The index and the tools must be backed by the SAME store object,
/// not by two built from the same configuration: an index whose exclusion list had drifted
/// from the tools' would be a search that returns documents the tools then refuse to open —
/// and, far worse, could return snippets from a document the store considers excluded. The
/// blanket impl over `Arc` is what lets one instance be handed to both without either taking
/// ownership.
///
/// It covers `Arc<dyn DocumentStore>` as well as `Arc<FsVaultStore>`, so the erased form the
/// tools hold satisfies the same trait as the concrete one the index is generic over.
impl<T: DocumentStore + ?Sized> DocumentStore for std::sync::Arc<T> {
    fn list<'a>(
        &'a self,
        scope: &'a Scope,
        req: ListRequest,
    ) -> BoxFuture<'a, Result<Page<DocumentMeta>, StoreError>> {
        (**self).list(scope, req)
    }

    fn stat<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
    ) -> BoxFuture<'a, Result<DocumentMeta, StoreError>> {
        (**self).stat(scope, id)
    }

    fn read<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
        range: Option<LineRange>,
    ) -> BoxFuture<'a, Result<Document, StoreError>> {
        (**self).read(scope, id, range)
    }

    fn write<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
        body: String,
        expected_hash: Option<ContentHash>,
        guard: &'a Guarded<'a>,
    ) -> BoxFuture<'a, Result<WriteReceipt, StoreError>> {
        (**self).write(scope, id, body, expected_hash, guard)
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
        (**self).edit(scope, id, find, replace, expected_hash, guard)
    }

    fn rename<'a>(
        &'a self,
        scope: &'a Scope,
        from: &'a DocumentId,
        to: &'a DocumentId,
        guard: &'a Guarded<'a>,
    ) -> BoxFuture<'a, Result<WriteReceipt, StoreError>> {
        (**self).rename(scope, from, to, guard)
    }

    fn revisions<'a>(
        &'a self,
        scope: &'a Scope,
        id: &'a DocumentId,
    ) -> BoxFuture<'a, Result<Vec<RevisionRef>, StoreError>> {
        (**self).revisions(scope, id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_normalise_and_refuse_every_traversal_shape() {
        assert_eq!(
            DocumentId::parse("notes/a.md").unwrap().as_str(),
            "notes/a.md"
        );
        // Normalised, not refused: these are string joins that went slightly wrong.
        assert_eq!(
            DocumentId::parse("notes//a.md").unwrap().as_str(),
            "notes/a.md"
        );
        assert_eq!(
            DocumentId::parse("./notes/a.md").unwrap().as_str(),
            "notes/a.md"
        );
        assert_eq!(
            DocumentId::parse("notes/./a.md").unwrap().as_str(),
            "notes/a.md"
        );

        for hostile in [
            "",
            "..",
            "../etc/passwd",
            "notes/../../etc/passwd",
            "/etc/passwd",
            "~/secrets",
            "C:/Windows",
            "notes\\a.md",
            "notes/a\0.md",
            ".",
            "/",
        ] {
            assert!(
                DocumentId::parse(hostile).is_err(),
                "{hostile:?} must not parse as a document id"
            );
        }
    }

    #[test]
    fn id_refusals_distinguish_containment_from_a_malformed_argument() {
        // The trace's refusal count depends on this: a traversal is the boundary working,
        // and must not be counted as a tool breaking.
        for (raw, want) in [
            ("../etc/passwd", IdRefusal::Traversal),
            ("notes/../../x", IdRefusal::Traversal),
            ("/etc/passwd", IdRefusal::Absolute),
            ("C:/x", IdRefusal::Absolute),
            ("a\u{0}b", IdRefusal::IllegalByte),
            ("a\\b", IdRefusal::IllegalByte),
            ("", IdRefusal::Malformed),
            (".", IdRefusal::Malformed),
        ] {
            let e = DocumentId::parse(raw).unwrap_err();
            assert_eq!(e.refusal, want, "for {raw:?}");
            assert_eq!(
                e.is_containment(),
                want != IdRefusal::Malformed,
                "for {raw:?}"
            );
        }
    }

    #[test]
    fn prefix_matching_is_on_components_not_strings() {
        let id = DocumentId::parse("notes/a.md").unwrap();
        assert!(id.starts_with_prefix("notes"));
        assert!(id.starts_with_prefix("notes/"));
        assert!(id.starts_with_prefix(""));
        // The bug a string prefix would have.
        assert!(!id.starts_with_prefix("note"));
        assert!(!id.starts_with_prefix("notes-archive"));
        assert_eq!(id.depth(), 2);
        assert_eq!(id.file_name(), "a.md");
    }

    #[test]
    fn the_content_hash_matches_the_bridges_sha256_hex_convention() {
        // The empty string's SHA-256, so this is checkable against any other tool — which
        // is the point: D4 feeds these to the bridge's lock broker.
        assert_eq!(
            ContentHash::of(b"").as_str(),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            ContentHash::of(b"abc").as_str(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn a_supplied_hash_is_validated_rather_than_trusted() {
        let good = ContentHash::of(b"x");
        assert_eq!(ContentHash::parse(good.as_str()).unwrap(), good);
        // Case-insensitive in, canonical lowercase out.
        assert_eq!(
            ContentHash::parse(&good.as_str().to_uppercase()).unwrap(),
            good
        );
        for bad in ["", "deadbeef", "not-a-hash", &"z".repeat(64)] {
            assert!(ContentHash::parse(bad).is_err(), "{bad:?} is not a hash");
        }
    }

    #[test]
    fn line_ranges_are_one_based_and_refuse_a_reversed_pair() {
        assert!(LineRange::new(1, 1).is_ok());
        assert!(LineRange::new(10, 20).is_ok());
        assert!(LineRange::new(0, 5).is_err(), "1-based");
        assert!(LineRange::new(20, 10).is_err(), "reversed");
    }

    #[test]
    fn a_conflict_tells_the_model_what_to_do_next() {
        let e = StoreError::Conflict {
            expected: ContentHash::of(b"a"),
            actual: ContentHash::of(b"b"),
        };
        let m = e.to_string();
        assert!(m.contains("Read it again"), "{m}");
        assert!(m.contains("expected_hash"), "{m}");
        // And it does not leak either hash into the model-visible text: the hashes are on
        // the error for a caller to log, not for the model to reason about.
        assert!(!m.contains(ContentHash::of(b"a").as_str()));
    }
}
