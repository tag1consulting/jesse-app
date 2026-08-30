//! **The thread store** — the conversation, in the provider-neutral model, on disk.
//!
//! ---- WHAT A THREAD IS ------------------------------------------------------
//!
//! An ordered list of [`Message`]s in the neutral model, plus a little metadata. Not a
//! transcript, not a summary, not a wire-shaped blob: **exactly what the model was shown**,
//! in the vocabulary every adapter can re-serialise. That is what makes a resumed thread
//! replay identically on a different wire from the one that produced it, which is the whole
//! reason the neutral model exists.
//!
//! **TOOL RESULT CONTENT IS STORED AS DELIVERED — FRAMED.** The loop writes the framed
//! bytes ([`crate::framing`]) into the thread, never the raw tool output plus a note to
//! re-frame it later. Re-deriving the frame on load would mean a stored thread's meaning
//! depended on the version of the framing code that read it, so a framing change would
//! silently rewrite history; and it would mean the bytes the model saw are nowhere on disk,
//! which makes "what was this turn actually shown" unanswerable after the fact. The cost is
//! that a framing improvement does not reach old threads. That is the right side of the
//! trade: an audit log that changes when you improve the code is not an audit log.
//!
//! ---- THREAD IDS ------------------------------------------------------------
//!
//! `direct-<uuid v4>`. The prefix is load bearing in two directions:
//!
//!   * The bridge mints SYNTHETIC ids prefixed `local-` for turns served by a local route,
//!     and a CLI session id is a bare uuid. A `direct-` id can collide with neither, so
//!     when D4 puts the two id spaces in one store there is no arrangement of them that
//!     makes one thread two or two threads one.
//!   * It names WHERE the thread came from. A thread run by this loop against a provider
//!     directly is a different kind of object from a thread the bridge drove through a
//!     child harness, and an id that says so keeps that legible without a second field.
//!
//! [`ThreadId`]'s inner string is PRIVATE and the only constructors are
//! [`ThreadId::generate`] and [`ThreadId::parse`], which validates the shape. That is not
//! tidiness: the id is a FILENAME in [`FileThreadStore`], so an id containing `/` or `..`
//! would be a path traversal handed to the store by whatever passed `--thread` on a command
//! line. Making an invalid id unconstructible removes that class rather than checking for
//! it at each of the four places a store touches the filesystem.

use std::collections::BTreeMap;
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::provider::Message;
use crate::timestamp::rfc3339_utc;

/// The prefix every thread this loop creates carries. See the module docs.
pub const THREAD_ID_PREFIX: &str = "direct-";

/// Schema version of a thread's on-disk records. Bumped when the record shape changes, so
/// a file written by an older build is identifiable on sight rather than by guessing.
pub const THREAD_SCHEMA_VERSION: u8 = 1;

// ===========================================================================
// The id
// ===========================================================================

/// A thread id: `direct-<uuid v4>`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ThreadId(String);

impl ThreadId {
    /// A fresh random id.
    pub fn generate() -> Self {
        ThreadId(format!("{THREAD_ID_PREFIX}{}", uuid_v4()))
    }

    /// Parse an id, refusing anything that is not `direct-<uuid v4 shape>`.
    ///
    /// The shape check is what makes an id safe to use as a filename. It is deliberately
    /// stricter than "contains no separator": a permissive check would still admit a
    /// 4 KB id, a leading dot, or a Windows device name, and none of those is something a
    /// store should have to think about.
    pub fn parse(s: &str) -> Result<Self, ThreadIdError> {
        let Some(uuid) = s.strip_prefix(THREAD_ID_PREFIX) else {
            return Err(ThreadIdError(format!(
                "{s:?} does not begin with {THREAD_ID_PREFIX:?}"
            )));
        };
        if !is_uuid_shaped(uuid) {
            return Err(ThreadIdError(format!(
                "{s:?} is not {THREAD_ID_PREFIX}<uuid>"
            )));
        }
        Ok(ThreadId(s.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ThreadId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl TryFrom<String> for ThreadId {
    type Error = ThreadIdError;

    fn try_from(s: String) -> Result<Self, Self::Error> {
        ThreadId::parse(&s)
    }
}

impl From<ThreadId> for String {
    fn from(id: ThreadId) -> String {
        id.0
    }
}

/// An id that is not a thread id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadIdError(String);

impl fmt::Display for ThreadIdError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ThreadIdError {}

/// `8-4-4-4-12` lowercase hex, with the version and variant nibbles a v4 uuid has.
fn is_uuid_shaped(s: &str) -> bool {
    let groups: Vec<&str> = s.split('-').collect();
    if groups.len() != 5 {
        return false;
    }
    let lengths = [8, 4, 4, 4, 12];
    for (g, want) in groups.iter().zip(lengths) {
        if g.len() != want || !g.bytes().all(|b| b.is_ascii_hexdigit()) {
            return false;
        }
    }
    groups[2].starts_with('4') && matches!(groups[3].as_bytes()[0], b'8' | b'9' | b'a' | b'b')
}

/// A random v4 uuid.
///
/// `getrandom` RATHER THAN `rand`, and rather than the crate's own xorshift jitter. The
/// jitter in `provider::http` is explicitly not cryptographic and says so — it exists to
/// spread retries — and a thread id needs the opposite property: two processes minting ids
/// in the same millisecond must not collide, and an id must not be guessable, because in
/// D4 it is the handle by which a stored conversation is fetched. `rand` would be a large
/// dependency for sixteen bytes; `getrandom` is the OS call and nothing else, and it is
/// already in this workspace's lockfile.
fn uuid_v4() -> String {
    let mut b = [0u8; 16];
    if getrandom::fill(&mut b).is_err() {
        // The OS entropy source failing is not a condition this program can continue
        // through meaningfully, but panicking in a library that a bridge calls per turn is
        // worse. Fall back to something that is still unique-per-process-per-nanosecond
        // and log it, so an id is still minted and the anomaly is visible.
        eprintln!("jesse-agent: warning could not read OS entropy for a thread id");
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        b[..16].copy_from_slice(&nanos.to_le_bytes()[..16]);
    }
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
    let h = |r: &[u8]| -> String { r.iter().map(|x| format!("{x:02x}")).collect() };
    format!(
        "{}-{}-{}-{}-{}",
        h(&b[0..4]),
        h(&b[4..6]),
        h(&b[6..8]),
        h(&b[8..10]),
        h(&b[10..16])
    )
}

// ===========================================================================
// The thread
// ===========================================================================

/// Per-thread metadata. Content-free: counts and timestamps, never a message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadMeta {
    pub v: u8,
    pub id: ThreadId,
    /// RFC-3339 UTC, fixed width — so `list_recent`'s ordering is a string comparison.
    pub created_at: String,
    pub updated_at: String,
    pub message_count: usize,
}

/// A loaded thread: its metadata and its messages, oldest first.
#[derive(Debug, Clone, PartialEq)]
pub struct Thread {
    pub meta: ThreadMeta,
    pub messages: Vec<Message>,
}

impl Thread {
    pub fn id(&self) -> &ThreadId {
        &self.meta.id
    }
}

/// A thread as [`ThreadStore::list_recent`] reports it — metadata only, no messages.
pub type ThreadSummary = ThreadMeta;

/// A thread store could not do the thing.
#[derive(Debug)]
pub enum ThreadError {
    NotFound(ThreadId),
    /// The store's backing failed: a disk error, a permission problem.
    Io(String),
    /// A record on disk could not be read back into the neutral model.
    Corrupt {
        thread: ThreadId,
        detail: String,
    },
}

impl fmt::Display for ThreadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ThreadError::NotFound(id) => write!(f, "no such thread: {id}"),
            ThreadError::Io(e) => write!(f, "thread store I/O: {e}"),
            ThreadError::Corrupt { thread, detail } => {
                write!(f, "thread {thread} has an unreadable record: {detail}")
            }
        }
    }
}

impl std::error::Error for ThreadError {}

/// Where a conversation lives.
///
/// **SYNCHRONOUS, in an otherwise async crate, and that is a decision.** An `append` is a
/// few hundred bytes to a local file; making the trait async would put a boxed future on
/// every call and a `BoxFuture` in every implementation, to buy nothing for either of the
/// two stores that exist. A future networked store adapts at its own boundary with
/// `spawn_blocking` — which is where the cost belongs, since it is that store's cost. The
/// rejected alternative (async from the start, "because a database will want it") is the
/// shape of the abstraction that is paid for at every call site by every implementation
/// that does not need it.
///
/// Every method returns a `Result`, including [`load`](ThreadStore::load), whose signature
/// in the design note was a bare `Thread`. A store that swallowed an I/O failure and
/// returned an empty thread would silently start a NEW conversation in the middle of an
/// old one — the model would answer without the context it was supposed to have, and
/// nothing would say why.
pub trait ThreadStore: Send + Sync {
    /// Mint a new, empty thread.
    fn create(&self) -> Result<ThreadId, ThreadError>;

    /// Read a thread whole.
    fn load(&self, id: &ThreadId) -> Result<Thread, ThreadError>;

    /// Append messages, in order. Atomic per call as far as a reader is concerned: either
    /// all of them are durable or the call failed.
    fn append(&self, id: &ThreadId, messages: &[Message]) -> Result<(), ThreadError>;

    /// The most recently updated threads, newest first, metadata only.
    fn list_recent(&self, limit: usize) -> Result<Vec<ThreadSummary>, ThreadError>;
}

// ===========================================================================
// The in-memory store
// ===========================================================================

/// A thread store in a `Mutex<BTreeMap>`. For tests and for a caller that genuinely wants
/// a conversation to end with the process.
#[derive(Debug, Default)]
pub struct MemoryThreadStore {
    threads: Mutex<BTreeMap<ThreadId, Thread>>,
    /// A monotonically increasing stamp, so `list_recent`'s ordering is deterministic in a
    /// test that creates several threads inside one clock tick. The wall clock is not
    /// precise enough for that and a test that sorted by it would be flaky.
    seq: Mutex<u64>,
}

impl MemoryThreadStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn stamp(&self) -> String {
        let mut g = self.seq.lock().expect("MemoryThreadStore seq poisoned");
        *g += 1;
        // Fixed width, so it sorts like the RFC-3339 strings the file store writes.
        format!("seq-{:016}", *g)
    }
}

impl ThreadStore for MemoryThreadStore {
    fn create(&self) -> Result<ThreadId, ThreadError> {
        let id = ThreadId::generate();
        let now = self.stamp();
        let thread = Thread {
            meta: ThreadMeta {
                v: THREAD_SCHEMA_VERSION,
                id: id.clone(),
                created_at: now.clone(),
                updated_at: now,
                message_count: 0,
            },
            messages: Vec::new(),
        };
        self.threads
            .lock()
            .expect("MemoryThreadStore poisoned")
            .insert(id.clone(), thread);
        Ok(id)
    }

    fn load(&self, id: &ThreadId) -> Result<Thread, ThreadError> {
        self.threads
            .lock()
            .expect("MemoryThreadStore poisoned")
            .get(id)
            .cloned()
            .ok_or_else(|| ThreadError::NotFound(id.clone()))
    }

    fn append(&self, id: &ThreadId, messages: &[Message]) -> Result<(), ThreadError> {
        let now = self.stamp();
        let mut g = self.threads.lock().expect("MemoryThreadStore poisoned");
        let t = g
            .get_mut(id)
            .ok_or_else(|| ThreadError::NotFound(id.clone()))?;
        t.messages.extend_from_slice(messages);
        t.meta.message_count = t.messages.len();
        t.meta.updated_at = now;
        Ok(())
    }

    fn list_recent(&self, limit: usize) -> Result<Vec<ThreadSummary>, ThreadError> {
        let g = self.threads.lock().expect("MemoryThreadStore poisoned");
        let mut metas: Vec<ThreadMeta> = g.values().map(|t| t.meta.clone()).collect();
        metas.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        metas.truncate(limit);
        Ok(metas)
    }
}

// ===========================================================================
// The file store
// ===========================================================================

/// One JSONL file per thread, plus a metadata file written temp-and-rename.
///
/// **TWO FILES, NOT ONE, and the split is the reason it is durable.** The message log is
/// APPEND-ONLY: a turn's messages are written to the end and `fsync`ed, and nothing ever
/// rewrites an earlier byte. That is the one file operation that cannot half-destroy
/// existing data — a crash mid-append leaves a truncated last line, which the loader can
/// see and refuse, and never a corrupted middle. Metadata (the counts and timestamps) DOES
/// have to be rewritten, so it lives in its own small file written to a temp path and
/// renamed over the old one, which is atomic on every filesystem this runs on.
///
/// The rejected alternative was one file with a header line rewritten in place. It makes
/// every metadata update a rewrite of a file that also holds the conversation, so the
/// failure mode of a bad update is losing the conversation.
///
/// **Mode `0600` on every file and `0700` on the root.** A thread holds whatever the user
/// said and whatever the tools read on their behalf, which is the most sensitive material
/// this crate touches. On a shared host the default umask is not a policy.
pub struct FileThreadStore {
    root: PathBuf,
    /// Serialises appends within this process, so two concurrent turns on ONE thread
    /// cannot interleave their messages. Cross-process safety is NOT claimed and is not
    /// needed: a thread has one conversation, and `O_APPEND` keeps concurrent writers from
    /// overwriting each other even if that changed.
    write_lock: Mutex<()>,
}

impl FileThreadStore {
    /// Open (creating if needed) a store rooted at `root`.
    pub fn open(root: impl Into<PathBuf>) -> Result<Self, ThreadError> {
        let root = root.into();
        std::fs::create_dir_all(&root).map_err(|e| ThreadError::Io(e.to_string()))?;
        restrict_dir(&root);
        Ok(FileThreadStore {
            root,
            write_lock: Mutex::new(()),
        })
    }

    fn log_path(&self, id: &ThreadId) -> PathBuf {
        self.root.join(format!("{id}.jsonl"))
    }

    fn meta_path(&self, id: &ThreadId) -> PathBuf {
        self.root.join(format!("{id}.meta.json"))
    }

    fn read_meta(&self, id: &ThreadId) -> Result<ThreadMeta, ThreadError> {
        let path = self.meta_path(id);
        let bytes = std::fs::read(&path).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => ThreadError::NotFound(id.clone()),
            _ => ThreadError::Io(e.to_string()),
        })?;
        serde_json::from_slice(&bytes).map_err(|e| ThreadError::Corrupt {
            thread: id.clone(),
            detail: format!("metadata: {e}"),
        })
    }

    fn write_meta(&self, meta: &ThreadMeta) -> Result<(), ThreadError> {
        let path = self.meta_path(&meta.id);
        let tmp = path.with_extension("json.tmp");
        let body = serde_json::to_vec(meta).map_err(|e| ThreadError::Io(e.to_string()))?;
        let write = || -> std::io::Result<()> {
            let mut f = private_file(&tmp, false)?;
            f.write_all(&body)?;
            f.sync_all()?;
            std::fs::rename(&tmp, &path)
        };
        write().map_err(|e| {
            let _ = std::fs::remove_file(&tmp);
            ThreadError::Io(e.to_string())
        })
    }
}

/// One line of a thread's message log.
#[derive(Debug, Serialize, Deserialize)]
struct LogRecord {
    v: u8,
    /// When this record was appended. Not used on load — the ORDER of the file is the
    /// order of the conversation — but present so a human reading the file can see when a
    /// turn happened without correlating with anything.
    at: String,
    message: Message,
}

impl ThreadStore for FileThreadStore {
    fn create(&self) -> Result<ThreadId, ThreadError> {
        let id = ThreadId::generate();
        let now = rfc3339_utc(std::time::SystemTime::now());
        // The log file is created empty NOW rather than lazily on the first append, so
        // that a thread which exists has both its files and `load` never has to decide
        // whether a missing log means "new" or "lost".
        private_file(&self.log_path(&id), true).map_err(|e| ThreadError::Io(e.to_string()))?;
        self.write_meta(&ThreadMeta {
            v: THREAD_SCHEMA_VERSION,
            id: id.clone(),
            created_at: now.clone(),
            updated_at: now,
            message_count: 0,
        })?;
        Ok(id)
    }

    fn load(&self, id: &ThreadId) -> Result<Thread, ThreadError> {
        let meta = self.read_meta(id)?;
        let file = File::open(self.log_path(id)).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => ThreadError::NotFound(id.clone()),
            _ => ThreadError::Io(e.to_string()),
        })?;
        let mut messages = Vec::new();
        for (n, line) in BufReader::new(file).lines().enumerate() {
            let line = line.map_err(|e| ThreadError::Io(e.to_string()))?;
            if line.trim().is_empty() {
                continue;
            }
            // A CORRUPT RECORD IS AN ERROR, not a skip. Skipping would hand the model a
            // conversation with a hole in it — most damagingly a hole where a tool result
            // used to be, leaving a tool call the model made with no answer, which reads
            // to it as a tool that silently does nothing.
            let rec: LogRecord = serde_json::from_str(&line).map_err(|e| ThreadError::Corrupt {
                thread: id.clone(),
                detail: format!("line {}: {e}", n + 1),
            })?;
            messages.push(rec.message);
        }
        Ok(Thread { meta, messages })
    }

    fn append(&self, id: &ThreadId, messages: &[Message]) -> Result<(), ThreadError> {
        if messages.is_empty() {
            return Ok(());
        }
        let _guard = self
            .write_lock
            .lock()
            .expect("FileThreadStore lock poisoned");
        let mut meta = self.read_meta(id)?;
        let now = rfc3339_utc(std::time::SystemTime::now());

        let mut buf = String::new();
        for message in messages {
            let rec = LogRecord {
                v: THREAD_SCHEMA_VERSION,
                at: now.clone(),
                message: message.clone(),
            };
            // `to_string`, never `to_string_pretty`: one record must be one line, because
            // the loader's recovery story ("a crash leaves a truncated LAST line") only
            // holds if a partial write can only ever damage one record.
            let line = serde_json::to_string(&rec).map_err(|e| ThreadError::Io(e.to_string()))?;
            debug_assert!(!line.contains('\n'));
            buf.push_str(&line);
            buf.push('\n');
        }

        let write = || -> std::io::Result<()> {
            let mut f = OpenOptions::new()
                .append(true)
                .open(self.log_path(id))
                .or_else(|e| match e.kind() {
                    std::io::ErrorKind::NotFound => private_file(&self.log_path(id), true),
                    _ => Err(e),
                })?;
            f.write_all(buf.as_bytes())?;
            // FSYNC ON APPEND. Without it a crash can lose a turn the loop has already
            // reported as complete, and the next run resumes a conversation missing its
            // last exchange — the model then answers a question it has already answered,
            // or re-runs a tool call whose result is gone. The cost is one sync per turn,
            // which against a provider call taking seconds is not measurable.
            f.sync_all()
        };
        write().map_err(|e| ThreadError::Io(e.to_string()))?;

        meta.message_count += messages.len();
        meta.updated_at = now;
        self.write_meta(&meta)
    }

    fn list_recent(&self, limit: usize) -> Result<Vec<ThreadSummary>, ThreadError> {
        let dir = std::fs::read_dir(&self.root).map_err(|e| ThreadError::Io(e.to_string()))?;
        let mut metas = Vec::new();
        for entry in dir {
            let entry = entry.map_err(|e| ThreadError::Io(e.to_string()))?;
            let name = entry.file_name().to_string_lossy().to_string();
            let Some(stem) = name.strip_suffix(".meta.json") else {
                continue;
            };
            // A file whose name is not a valid thread id is not this store's — skipped
            // rather than errored, so an unrelated file in the directory does not make
            // listing fail. An id that parses but whose metadata is corrupt IS an error:
            // that one is ours and is broken.
            let Ok(id) = ThreadId::parse(stem) else {
                continue;
            };
            metas.push(self.read_meta(&id)?);
        }
        metas.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        metas.truncate(limit);
        Ok(metas)
    }
}

/// Create/open a file with mode `0600` where the platform has modes.
fn private_file(path: &Path, keep_existing: bool) -> std::io::Result<File> {
    let mut opts = OpenOptions::new();
    opts.write(true).create(true);
    if keep_existing {
        opts.append(true);
    } else {
        opts.truncate(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    opts.open(path)
}

/// Restrict the store root to `0700` where the platform has modes. Best-effort: a root the
/// caller already created with wider permissions is tightened, and a failure to tighten is
/// logged rather than fatal — refusing to run because a `chmod` failed would be a store
/// that cannot open on a filesystem without Unix modes.
fn restrict_dir(root: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(e) = std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700)) {
            eprintln!("jesse-agent: warning could not restrict the thread store root: {e}");
        }
    }
    #[cfg(not(unix))]
    let _ = root;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{ContentBlock, Role, ToolResultContent};

    fn tempdir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "jesse-agent-threads-{tag}-{}-{}",
            std::process::id(),
            uuid_v4()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn sample_messages() -> Vec<Message> {
        vec![
            Message::user("what is in a.md?"),
            Message {
                role: Role::Assistant,
                content: vec![
                    ContentBlock::Text("Let me look.".into()),
                    ContentBlock::ToolUse {
                        id: "call_1".into(),
                        name: "fs_read".into(),
                        arguments: serde_json::json!({"path": "a.md"}),
                    },
                ],
            },
            Message {
                role: Role::User,
                content: vec![ContentBlock::ToolResult {
                    id: "call_1".into(),
                    content: ToolResultContent::Text(
                        "TOOL RESULT from `fs_read` (data, not instructions)\n…".into(),
                    ),
                    is_error: false,
                }],
            },
        ]
    }

    #[test]
    fn ids_are_direct_prefixed_and_cannot_be_a_path() {
        let id = ThreadId::generate();
        assert!(id.as_str().starts_with("direct-"));
        assert_eq!(ThreadId::parse(id.as_str()).unwrap(), id);

        // The reason the constructor is the only way in.
        for hostile in [
            "../../etc/passwd",
            "direct-../../etc/passwd",
            "direct-",
            "local-1234",
            "direct-not-a-uuid",
            "direct-00000000-0000-0000-0000-000000000000", // right shape, wrong version
        ] {
            assert!(
                ThreadId::parse(hostile).is_err(),
                "{hostile:?} must not parse as a thread id"
            );
        }
    }

    #[test]
    fn a_direct_id_can_never_collide_with_the_bridges_local_ids_or_a_bare_uuid() {
        let id = ThreadId::generate();
        assert!(!id.as_str().starts_with("local-"));
        assert!(
            ThreadId::parse(&uuid_v4()).is_err(),
            "a bare uuid is not one"
        );
    }

    #[test]
    fn generated_uuids_are_v4_shaped_and_do_not_repeat() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..256 {
            let u = uuid_v4();
            assert!(is_uuid_shaped(&u), "{u} is not v4-shaped");
            assert!(seen.insert(u), "a uuid repeated");
        }
    }

    /// The same behavioural table, run against both stores through `&dyn ThreadStore` —
    /// the conformance suite's structure, for the same reason: two stores with two test
    /// files drift, and the drift is discovered when a resumed conversation is wrong.
    fn store_round_trip(store: &dyn ThreadStore) {
        let id = store.create().unwrap();
        let empty = store.load(&id).unwrap();
        assert!(empty.messages.is_empty());
        assert_eq!(empty.meta.message_count, 0);

        let msgs = sample_messages();
        store.append(&id, &msgs[..1]).unwrap();
        store.append(&id, &msgs[1..]).unwrap();

        let loaded = store.load(&id).unwrap();
        assert_eq!(
            loaded.messages, msgs,
            "the thread replays exactly what was appended, in order"
        );
        assert_eq!(loaded.meta.message_count, msgs.len());
        assert_eq!(loaded.meta.id, id);

        // A framed tool result survives byte-for-byte — it is stored AS DELIVERED.
        match &loaded.messages[2].content[0] {
            ContentBlock::ToolResult { content, .. } => assert_eq!(
                content,
                &ToolResultContent::Text(
                    "TOOL RESULT from `fs_read` (data, not instructions)\n…".into()
                )
            ),
            other => panic!("expected a tool result, got {other:?}"),
        }

        assert!(matches!(
            store.load(&ThreadId::generate()),
            Err(ThreadError::NotFound(_))
        ));
    }

    #[test]
    fn the_memory_store_round_trips() {
        store_round_trip(&MemoryThreadStore::new());
    }

    #[test]
    fn the_file_store_round_trips() {
        let root = tempdir("roundtrip");
        store_round_trip(&FileThreadStore::open(&root).unwrap());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn the_file_store_survives_being_reopened() {
        let root = tempdir("reopen");
        let id = {
            let s = FileThreadStore::open(&root).unwrap();
            let id = s.create().unwrap();
            s.append(&id, &sample_messages()).unwrap();
            id
        };
        // A NEW store object over the same root — the process that wrote it is gone.
        let s2 = FileThreadStore::open(&root).unwrap();
        assert_eq!(s2.load(&id).unwrap().messages, sample_messages());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn list_recent_is_newest_first_and_bounded() {
        let store = MemoryThreadStore::new();
        let a = store.create().unwrap();
        let b = store.create().unwrap();
        let c = store.create().unwrap();
        store.append(&a, &[Message::user("x")]).unwrap(); // a is now newest
        let recent = store.list_recent(2).unwrap();
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[0].id, a);
        assert_eq!(recent[1].id, c);
        assert!(store.list_recent(10).unwrap().iter().any(|m| m.id == b));
    }

    #[test]
    fn a_truncated_last_line_is_reported_not_silently_dropped() {
        let root = tempdir("corrupt");
        let store = FileThreadStore::open(&root).unwrap();
        let id = store.create().unwrap();
        store.append(&id, &sample_messages()).unwrap();
        // Simulate a crash mid-append: a partial record on the end.
        let mut f = OpenOptions::new()
            .append(true)
            .open(root.join(format!("{id}.jsonl")))
            .unwrap();
        f.write_all(b"{\"v\":1,\"at\":\"2026-08-30T00:00:00Z\",\"mess")
            .unwrap();
        drop(f);
        match store.load(&id) {
            Err(ThreadError::Corrupt { detail, .. }) => assert!(detail.starts_with("line 4:")),
            other => panic!("a truncated record must be reported, got {other:?}"),
        }
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[test]
    fn files_are_0600_and_the_root_is_0700() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempdir("modes");
        let store = FileThreadStore::open(&root).unwrap();
        let id = store.create().unwrap();
        store.append(&id, &[Message::user("x")]).unwrap();
        let mode = |p: PathBuf| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(root.clone()), 0o700);
        assert_eq!(mode(root.join(format!("{id}.jsonl"))), 0o600);
        assert_eq!(mode(root.join(format!("{id}.meta.json"))), 0o600);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn an_unrelated_file_in_the_root_does_not_break_listing() {
        let root = tempdir("stray");
        let store = FileThreadStore::open(&root).unwrap();
        store.create().unwrap();
        std::fs::write(root.join("README.meta.json"), b"not ours").unwrap();
        std::fs::write(root.join("notes.txt"), b"nor this").unwrap();
        assert_eq!(store.list_recent(10).unwrap().len(), 1);
        std::fs::remove_dir_all(&root).ok();
    }
}
