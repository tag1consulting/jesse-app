//! **The write-guard seam** — the lock a store takes before it mutates a document, and the
//! shape D4 implements over the bridge's broker.
//!
//! ---- WHY THIS EXISTS IN PHASE 1 ----------------------------------------------
//!
//! Phase 1 runs the direct loop **beside the existing bridge**, on one git-backed vault,
//! with concurrent turns. A CLI child writing through the bridge's hooks and a direct turn
//! writing through [`DocumentStore`](super::DocumentStore) can target the same file in the
//! same second. The bridge already solved that — `bridge/src/writelock.rs` has a
//! `LockBroker` with `LockKey::{Path, Global, Git}`, per-conversation compare-and-swap
//! baselines, a 30-second wait timeout and a 120-second hold timeout — and the direct loop
//! must take THE SAME LOCKS, not a second scheme that is correct on its own and blind to
//! the first.
//!
//! So the seam is defined here, in the shape the broker can implement, and D4 supplies the
//! implementation. Defining it later would mean the store's mutation paths were written
//! without a lock and then had one threaded through them, which is how the one path that
//! does not take it survives.
//!
//! ---- THE D4 CONTRACT ----------------------------------------------------------
//!
//! `bridge/src/writelock.rs` is the implementation, and this trait maps onto it as:
//!
//!   * [`WriteGuard::acquire`] → the broker's `LockKey::Path` for the canonical path,
//!     blocking up to `LOCK_WAIT_TIMEOUT` (30 s).
//!   * [`WriteGuard::release`] → the broker's per-turn release; the broker's `release_turn`
//!     remains the backstop that frees everything a dead turn held.
//!   * [`WriteGuard::note_read`] → the broker's per-CONVERSATION baseline map
//!     (`path → content hash as this conversation last left it`). The store calls it on
//!     every read, which is what makes the compare-and-swap describe "since I last saw it"
//!     rather than "since anyone last wrote it".
//!
//! **A [`GuardRefused`] AFTER THE WAIT TIMEOUT IS A LOUD TOOL FAILURE, NEVER A SILENT
//! WRITE.** That is the rule this seam exists to make unbreakable. The tempting behaviour —
//! proceed without the lock when the broker is unreachable — is exactly wrong: the case
//! where the broker is down is the case where another writer is unaccounted for, so
//! "degrade to writing anyway" degrades precisely when the protection was load bearing. The
//! failure reaches the model as a tool error it can report, and reaches the operator as a
//! refusal in the trace.

use std::fmt;
use std::path::{Path, PathBuf};

use crate::provider::BoxFuture;

use super::ContentHash;

/// Everything the guard needs to attribute a lock, bundled.
///
/// The design note spells the store's parameter `guard: &dyn WriteGuard`, but
/// [`WriteGuard::acquire`] needs the turn, the conversation and the call id as well — the
/// broker attributes a held lock to a turn so `release_turn` can free it, and keys
/// baselines by conversation. Threading three more `&str` parameters through six store
/// methods is how two of them end up transposed, and a lock attributed to the wrong turn is
/// a lock that is never released. One struct, one parameter, named fields.
pub struct Guarded<'a> {
    pub guard: &'a dyn WriteGuard,
    /// The turn holding the lock. `release_turn` frees everything under it.
    pub turn: &'a str,
    /// The conversation, which is what the compare-and-swap baseline is keyed by.
    pub conversation: &'a str,
    /// The tool call, for the trace and for diagnosing a wedged hold.
    pub call_id: &'a str,
}

impl fmt::Debug for Guarded<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Guarded")
            .field("turn", &self.turn)
            .field("conversation", &self.conversation)
            .field("call_id", &self.call_id)
            .finish_non_exhaustive()
    }
}

impl<'a> Guarded<'a> {
    /// A guard bundle for a turn.
    pub fn new(
        guard: &'a dyn WriteGuard,
        turn: &'a str,
        conversation: &'a str,
        call_id: &'a str,
    ) -> Self {
        Guarded {
            guard,
            turn,
            conversation,
            call_id,
        }
    }

    /// Take the lock for one path.
    pub async fn acquire(&self, path: &Path) -> Result<GuardPermit, GuardRefused> {
        self.guard
            .acquire(path, self.turn, self.conversation, self.call_id)
            .await
    }

    /// Hand it back.
    pub fn release(&self, permit: GuardPermit) {
        self.guard.release(permit)
    }

    /// Record what a read saw, so the compare-and-swap baseline is fed.
    pub fn note_read(&self, path: &Path, hash: &ContentHash) {
        self.guard.note_read(self.conversation, path, hash)
    }
}

/// A held lock.
///
/// **NOT `Drop`-RELEASING, DELIBERATELY.** A permit that released on drop reads well and
/// cannot express the thing that matters here: the release has to happen through the same
/// guard object that granted it, because in D4 that is a round trip to a broker, and a
/// `Drop` impl cannot be async. Making release explicit means a path that forgets is
/// visible in review, where a `Drop` that silently did nothing useful would not be. The
/// broker's `LOCK_HOLD_TIMEOUT` is the backstop for the path that forgets anyway.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GuardPermit {
    pub path: PathBuf,
    /// Opaque to the store; the implementation's handle on the lock.
    pub token: String,
}

/// The lock was not granted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuardRefused {
    /// Another writer held it past the wait timeout.
    Busy { path: PathBuf, waited_ms: u64 },
    /// The broker could not be reached, or answered something unusable.
    ///
    /// **STILL A REFUSAL.** See the module docs: the case where the broker is down is the
    /// case where another writer is unaccounted for.
    Unavailable(String),
}

impl fmt::Display for GuardRefused {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // The path is named because the model chose it and may pick another; nothing
            // about the file's CONTENT is said.
            GuardRefused::Busy { path, waited_ms } => write!(
                f,
                "another turn is writing {} (waited {waited_ms}ms). Nothing was written; \
                 try again or work on something else.",
                path.display()
            ),
            GuardRefused::Unavailable(m) => write!(
                f,
                "the write lock is unavailable ({m}). Nothing was written — writing without \
                 the lock could silently overwrite another turn's work."
            ),
        }
    }
}

impl std::error::Error for GuardRefused {}

/// What a store takes before it mutates.
pub trait WriteGuard: Send + Sync {
    /// Take the lock for `path`, blocking up to the implementation's wait timeout.
    fn acquire<'a>(
        &'a self,
        path: &'a Path,
        turn: &'a str,
        conversation: &'a str,
        call_id: &'a str,
    ) -> BoxFuture<'a, Result<GuardPermit, GuardRefused>>;

    /// Release a permit. Infallible from the caller's view: a release that fails to reach
    /// the broker leaves a lock the hold timeout reclaims, and turning that into an error
    /// the caller must handle would put error handling on the success path of every write.
    fn release(&self, permit: GuardPermit);

    /// Record that this conversation has seen `path` at `hash`.
    ///
    /// Called by the store on EVERY read, including reads that later turn out not to
    /// precede a write. That is cheap and it is the only ordering that works: the store
    /// cannot know at read time whether a write will follow, and a baseline recorded only
    /// when one does would be missing exactly when the model reads, thinks, and then writes.
    fn note_read(&self, conversation: &str, path: &Path, hash: &ContentHash);
}

impl<T: WriteGuard + ?Sized> WriteGuard for std::sync::Arc<T> {
    fn acquire<'a>(
        &'a self,
        path: &'a Path,
        turn: &'a str,
        conversation: &'a str,
        call_id: &'a str,
    ) -> BoxFuture<'a, Result<GuardPermit, GuardRefused>> {
        (**self).acquire(path, turn, conversation, call_id)
    }

    fn release(&self, permit: GuardPermit) {
        (**self).release(permit)
    }

    fn note_read(&self, conversation: &str, path: &Path, hash: &ContentHash) {
        (**self).note_read(conversation, path, hash)
    }
}

/// A guard that grants everything.
///
/// **FOR SINGLE-WRITER DEPLOYMENTS AND TESTS.** It is the honest name for "there is no
/// lock": the CLI running one turn against a directory nobody else is touching genuinely
/// does not need a broker, and pretending otherwise would mean the CLI could not run
/// without one. It is NOT the right guard for Phase 1 beside the bridge — D4 supplies that
/// one — and the CLI says which it is using so the choice is never invisible.
#[derive(Debug, Default)]
pub struct NoGuard;

impl WriteGuard for NoGuard {
    fn acquire<'a>(
        &'a self,
        path: &'a Path,
        _turn: &'a str,
        _conversation: &'a str,
        _call_id: &'a str,
    ) -> BoxFuture<'a, Result<GuardPermit, GuardRefused>> {
        Box::pin(async move {
            Ok(GuardPermit {
                path: path.to_path_buf(),
                token: "no-guard".into(),
            })
        })
    }

    fn release(&self, _permit: GuardPermit) {}

    fn note_read(&self, _conversation: &str, _path: &Path, _hash: &ContentHash) {}
}

/// A guard that refuses every acquire and records every `note_read`.
///
/// `#[cfg(test)]` and `pub(crate)` so the STORE's tests can use it: the property worth
/// asserting — that a mutation path propagates a refusal rather than writing anyway — is a
/// property of the store, and it can only be tested with a guard that says no.
#[cfg(test)]
#[derive(Debug, Default)]
pub(crate) struct RefusingGuard {
    pub reads: std::sync::Mutex<Vec<(String, String)>>,
}

#[cfg(test)]
impl WriteGuard for RefusingGuard {
    fn acquire<'a>(
        &'a self,
        path: &'a Path,
        _t: &'a str,
        _c: &'a str,
        _i: &'a str,
    ) -> BoxFuture<'a, Result<GuardPermit, GuardRefused>> {
        Box::pin(async move {
            Err(GuardRefused::Busy {
                path: path.to_path_buf(),
                waited_ms: 30_000,
            })
        })
    }

    fn release(&self, _permit: GuardPermit) {}

    fn note_read(&self, conversation: &str, path: &Path, hash: &ContentHash) {
        self.reads.lock().unwrap().push((
            format!("{conversation}:{}", path.display()),
            hash.to_string(),
        ));
    }
}

/// A guard that grants everything and records every `note_read`, so a test can assert the
/// store fed the compare-and-swap baseline.
#[cfg(test)]
#[derive(Debug, Default)]
pub(crate) struct RecordingGuard {
    pub reads: std::sync::Mutex<Vec<(String, String)>>,
}

#[cfg(test)]
impl WriteGuard for RecordingGuard {
    fn acquire<'a>(
        &'a self,
        path: &'a Path,
        _t: &'a str,
        _c: &'a str,
        _i: &'a str,
    ) -> BoxFuture<'a, Result<GuardPermit, GuardRefused>> {
        Box::pin(async move {
            Ok(GuardPermit {
                path: path.to_path_buf(),
                token: "recording".into(),
            })
        })
    }

    fn release(&self, _permit: GuardPermit) {}

    fn note_read(&self, conversation: &str, path: &Path, hash: &ContentHash) {
        self.reads
            .lock()
            .unwrap()
            .push((conversation.to_string(), hash.to_string()));
        let _ = path;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn the_no_op_guard_grants_and_records_nothing() {
        let g = NoGuard;
        let bundle = Guarded::new(&g, "turn", "conv", "call");
        let permit = bundle.acquire(Path::new("/tmp/x.md")).await.unwrap();
        assert_eq!(permit.path, PathBuf::from("/tmp/x.md"));
        bundle.release(permit);
        bundle.note_read(Path::new("/tmp/x.md"), &ContentHash::of(b"x"));
    }

    #[test]
    fn a_refusal_says_nothing_was_written() {
        let busy = GuardRefused::Busy {
            path: PathBuf::from("/v/notes/a.md"),
            waited_ms: 30_000,
        };
        assert!(busy.to_string().contains("Nothing was written"));
        let down = GuardRefused::Unavailable("broker socket missing".into());
        let m = down.to_string();
        assert!(m.contains("Nothing was written"));
        assert!(
            m.contains("could silently overwrite"),
            "the refusal explains why it did not degrade to writing: {m}"
        );
    }
}
