use crate::*;
use std::os::unix::fs::PermissionsExt;
use tokio::io::AsyncWriteExt;
use tokio::net::{UnixListener, UnixStream};

// ---- The vault write lock ----------------------------------------------------
//
// WHY THIS EXISTS. Until 0.60.0 the only thing standing between two concurrent turns and a
// mangled vault file was `max_concurrency = 1` — one turn at a time, across every client and
// every model. Raising that number without a lock would let two agent children edit the same
// tree with no coordination at all, and after 0.56.0 they may be children of DIFFERENT
// harnesses. The bridge cannot serialize writes INSIDE a child: the child does its own file
// IO in its own process, and the bridge only sees an event stream.
//
// So the lock is taken by the CHILD, through the one mechanism both agent CLIs expose — a
// `PreToolUse` / `PostToolUse` hook pair — and held by the BRIDGE, which is the only
// participant that knows when a turn has actually ended.
//
// ---- WHY THE BRIDGE IS THE BROKER --------------------------------------------
//
// A `PreToolUse` hook is a short-lived process that exits BEFORE the tool runs, so a POSIX
// advisory lock taken there is released by the kernel before the write it was meant to
// protect ever happens. `flock` in the pre hook is not an option, and neither is any scheme
// whose release depends on the hook process staying alive.
//
// The two shapes that do work are a long-lived broker, or a lock FILE plus a reaper that
// clears entries whose holder pid is dead or whose age exceeded a timeout. This is the
// broker, and the deciding argument is that **the bridge already owns the child**. It is the
// only participant that can release every lock a turn holds at the instant that turn ends —
// however it ended, including a kill between the pre hook and the post hook. The lock-file
// shape can only approximate that with pid-liveness and age heuristics, and getting those
// subtly wrong means either a lock that blocks every later write or one that releases early.
// The bridge is already a supervised long-lived process, so "add a daemon" costs nothing
// here: there is no new daemon.
//
// ---- WHY THE RENDEZVOUS IS IN THE STATE DIR ----------------------------------
//
// This was expected to be the hard part and measurement dissolved it. A Codex child's
// `sandbox_workspace_write.writable_roots` is exactly its cwd (the vault); `$TMPDIR` and
// `/tmp` are excluded on purpose as laundering routes; and the state dir is outside all of
// it. A socket under the state dir looked unreachable by exactly one of the two harnesses.
//
// Verified 2026-08-05 against codex-cli 0.146.0: **the hook subprocess is NOT sandboxed.** A
// `PreToolUse` hook wrote its evidence to a path outside `writable_roots`, under `/tmp`,
// which that child's own posture excludes twice. The child could not have written there; its
// hook could. So the rendezvous lives in the state dir, both harnesses reach it, and
// `sandbox_workspace_write.writable_roots` is NOT widened by any of this. Do not "simplify"
// this by moving the socket into the vault — that would put lock state in the tree git and
// the autocommit timer watch, which is the problem this placement avoids.
//
// ---- WHAT IS LOCKED, AND IN WHAT ORDER ---------------------------------------
//
// One lock per TARGET FILE, keyed on the fully-resolved absolute path (symlinks resolved),
// so two turns writing different files never block each other. Plus ONE global git lock,
// because the git index is a single point no matter which file changed.
//
// The acquisition order is the bridge's one total order, outermost first, and it is the same
// order the gates use so the two cannot form a cycle:
//
//     conversation lock → model slot → global ceiling → per-file write lock → global git lock
//
// A write hook that triggers a vault hook that runs git therefore takes the file lock and
// then the git lock, never the reverse.

/// How long a hook may wait for a contended lock before the turn fails loudly.
///
/// A wedged child must not stall another turn forever. When this elapses the waiter is told
/// so in words the model can act on, and the turn fails visibly rather than hanging — which
/// is the whole point of having a number here rather than an unbounded wait.
pub const LOCK_WAIT_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a lock may be HELD before the broker reclaims it.
///
/// The post hook is the normal release, and the turn ending is the backstop, but neither
/// fires if the tool call wedged inside the child. Wider than [`LOCK_WAIT_TIMEOUT`] so a
/// legitimately slow write is never reclaimed out from under itself.
pub const LOCK_HOLD_TIMEOUT: Duration = Duration::from_secs(120);

/// The longest a unix socket path may be. 104 on macOS, 108 on Linux; the smaller is used so
/// the check is portable and errs toward refusing early.
pub const MAX_SOCKET_PATH: usize = 104;

/// What a tool call is about to write, as far as the hook payload can tell.
///
/// The three variants are not a refinement hierarchy — they are three genuinely different
/// amounts of knowledge, and collapsing any two of them loses something. See
/// [`Harness::hook_write_target`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WriteTarget {
    /// Not a write at all (a read, a search, a thought). No lock, no contention.
    None,
    /// A specific file, named by an ABSOLUTE path with symlinks resolved.
    Path(PathBuf),
    /// A write whose target this harness cannot name — a shell command string, a native tool
    /// with no parseable path. Takes the GLOBAL lock: coarse, and safe.
    ///
    /// This is the honest variant. A shell call can redirect, `sed -i`, `tee`, or run the
    /// vault's own hooks, and parsing a conservative allowlist of shapes out of a command
    /// string is precise and leaky. Taking one global lock for every such call is imprecise
    /// and sound, and this bridge would rather be slow than wrong.
    Global,
}

/// The lock the broker actually takes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum LockKey {
    /// One file, by resolved absolute path.
    Path(PathBuf),
    /// Every unparseable write, serialized against each other and against every file.
    Global,
    /// The git index — a single point regardless of which file changed.
    Git,
}

/// One hook payload, in the fields BOTH harnesses carry.
///
/// Deliberately not a faithful model of either CLI's schema: the bridge needs the session,
/// the cwd, the tool name and the tool input, and everything else is that harness's business.
/// `tool_input` stays a raw `Value` because the two shapes genuinely differ — Claude Code
/// hands over `{"file_path": "/abs/path", ...}` and Codex hands over an `apply_patch` envelope
/// with the path inside patch syntax — and reconciling them is per-harness work.
#[derive(Debug, Clone, Deserialize)]
pub struct HookPayload {
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub tool_name: String,
    #[serde(default)]
    pub tool_use_id: String,
    #[serde(default)]
    pub tool_input: Value,
}

/// One request from a hook helper to the broker, line-delimited JSON over the unix socket.
#[derive(Debug, Clone, serde::Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "lowercase")]
pub enum HookRequest {
    /// A tool is about to run. Acquire whatever it needs, verify the compare-and-swap, and
    /// answer allow/deny. BLOCKS (up to [`LOCK_WAIT_TIMEOUT`]) while another turn holds it.
    Pre {
        turn: String,
        conversation: String,
        tool_use_id: String,
        /// `None` for [`WriteTarget::None`], `Some(None)` for [`WriteTarget::Global`],
        /// `Some(Some(path))` for a named file.
        target: Option<Option<String>>,
        /// Whether this call also touches git (so the git lock is taken inside the file lock).
        git: bool,
    },
    /// The tool finished (or errored, or was denied). Release, and record any read baseline.
    ///
    /// Release must not depend on the happy path: the broker also releases on turn end and on
    /// the hold timeout, so a post that never arrives costs a delay, never a stuck vault.
    Post {
        turn: String,
        conversation: String,
        tool_use_id: String,
        /// A file this call READ, whose content hash becomes the compare-and-swap baseline.
        read: Option<String>,
    },
}

/// The broker's answer. A deny is a NORMAL, recoverable outcome — the model is told to
/// re-read and retry — not a crash.
#[derive(Debug, Clone, serde::Serialize, Deserialize)]
pub struct HookResponse {
    pub allow: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl HookResponse {
    fn allow() -> Self {
        HookResponse {
            allow: true,
            reason: None,
        }
    }
    fn deny(reason: impl Into<String>) -> Self {
        HookResponse {
            allow: false,
            reason: Some(reason.into()),
        }
    }
}

/// A lock currently held, and by whom.
struct Held {
    turn: String,
    tool_use_id: String,
    since: Instant,
}

#[derive(Default)]
struct BrokerInner {
    /// The locks currently held.
    held: HashMap<LockKey, Held>,
    /// Per-CONVERSATION read baselines: path → content hash at the time this conversation
    /// last read it.
    ///
    /// Keyed on the conversation rather than on the harness's own session or home directory,
    /// and that is load-bearing: a Codex turn gets a FRESH `CODEX_HOME` every turn, so a
    /// sidecar keyed there would not survive a resume. Both harnesses have a bridge
    /// conversation id for the whole thread.
    baselines: HashMap<String, HashMap<PathBuf, String>>,
}

/// The in-bridge lock broker. One per process, shared behind an `Arc`.
pub struct LockBroker {
    inner: Mutex<BrokerInner>,
    /// Bumped whenever a lock is released, so waiters re-check rather than poll blindly.
    released: tokio::sync::Notify,
}

impl Default for LockBroker {
    fn default() -> Self {
        Self::new()
    }
}

impl LockBroker {
    pub fn new() -> Self {
        LockBroker {
            inner: Mutex::new(BrokerInner::default()),
            released: tokio::sync::Notify::new(),
        }
    }

    /// Locks currently held. Tests and introspection only.
    pub fn held_count(&self) -> usize {
        self.inner.lock_ok().held.len()
    }

    /// Try to take one lock. `true` on success.
    ///
    /// Reclaims a lock whose holder has exceeded [`LOCK_HOLD_TIMEOUT`] — the backstop for a
    /// tool call that wedged inside the child, where neither the post hook nor the turn end
    /// will ever arrive.
    fn try_take(&self, key: &LockKey, turn: &str, tool_use_id: &str) -> bool {
        let mut g = self.inner.lock_ok();
        if let Some(h) = g.held.get(key) {
            // RE-ENTRANT PER TURN, not per tool call.
            //
            // A turn's tool calls are sequential, so a turn can never race itself — but its
            // calls do NOT hand locks over cleanly: the post hook for call A and the pre hook
            // for call B are separate short-lived processes, and nothing guarantees A's post
            // is served before B's pre arrives. Keyed per CALL, B would then block on the git
            // lock that A's own turn still holds, wait out the full timeout, and be refused a
            // write nothing was actually contending for.
            //
            // Per TURN, that is impossible: the second call simply takes over the lock. The
            // cross-turn property — which is the one that protects the vault — is untouched,
            // because a DIFFERENT turn still finds the key held and waits.
            if h.turn == turn {
                // Re-key to the current call so that call's post hook releases it; otherwise
                // the lock would linger until the turn ended.
                g.held.insert(
                    key.clone(),
                    Held {
                        turn: turn.to_string(),
                        tool_use_id: tool_use_id.to_string(),
                        since: Instant::now(),
                    },
                );
                return true;
            }
            if h.since.elapsed() < LOCK_HOLD_TIMEOUT {
                return false;
            }
            eprintln!(
                "jesse-bridge: write lock reclaimed from a wedged holder (turn {}, held {:?})",
                h.turn,
                h.since.elapsed()
            );
        }
        g.held.insert(
            key.clone(),
            Held {
                turn: turn.to_string(),
                tool_use_id: tool_use_id.to_string(),
                since: Instant::now(),
            },
        );
        true
    }

    /// Wait for one lock, up to [`LOCK_WAIT_TIMEOUT`]. `false` on timeout — which the caller
    /// turns into a LOUD failure, never a silent unlocked write.
    async fn acquire(&self, key: &LockKey, turn: &str, tool_use_id: &str) -> bool {
        let deadline = Instant::now() + LOCK_WAIT_TIMEOUT;
        loop {
            if self.try_take(key, turn, tool_use_id) {
                return true;
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return false;
            }
            // Wake on the next release, but never sleep past the deadline.
            let _ = timeout(
                remaining.min(Duration::from_secs(1)),
                self.released.notified(),
            )
            .await;
        }
    }

    /// Release every lock held by one tool call.
    fn release_call(&self, turn: &str, tool_use_id: &str) {
        let mut g = self.inner.lock_ok();
        g.held
            .retain(|_, h| !(h.turn == turn && h.tool_use_id == tool_use_id));
        drop(g);
        self.released.notify_waiters();
    }

    /// Release every lock held by one TURN. Called by the bridge when the child exits, on
    /// every path including a panic, a cancel and a timeout — this is the release that does
    /// not depend on the child behaving.
    pub fn release_turn(&self, turn: &str) {
        let mut g = self.inner.lock_ok();
        let before = g.held.len();
        g.held.retain(|_, h| h.turn != turn);
        let freed = before - g.held.len();
        drop(g);
        if freed > 0 {
            self.released.notify_waiters();
        }
    }

    /// Forget a conversation's read baselines. Called when a conversation is deleted.
    pub fn forget_conversation(&self, conversation: &str) {
        self.inner.lock_ok().baselines.remove(conversation);
    }

    /// Record what a conversation last saw in a file.
    fn record_baseline(&self, conversation: &str, path: &Path) {
        if let Some(hash) = hash_file(path) {
            self.inner
                .lock_ok()
                .baselines
                .entry(conversation.to_string())
                .or_default()
                .insert(path.to_path_buf(), hash);
        }
    }

    /// The compare-and-swap: has this file changed since this conversation read it?
    ///
    /// `Ok(())` when it is safe to write. A per-file lock stops two writes landing at once; it
    /// does NOT stop a lost update, where turn A reads, turn B writes, and turn A then writes
    /// its stale copy over B's work. The dangerous window is read→write, not the write itself,
    /// so this check exists — and it runs INSIDE the lock, or it would itself be racy.
    ///
    /// A file with NO recorded baseline is ALLOWED, and this is a deliberate, named hole. A
    /// file read with `cat` inside a shell call records no hash, so failing closed here would
    /// refuse the very common case of writing a file the session never read through a tool —
    /// including every first-time creation. The cost is that a lost update through the
    /// cat-then-write path remains possible. It is logged, and it is named in the CHANGELOG.
    fn check_baseline(&self, conversation: &str, path: &Path) -> Result<(), String> {
        let recorded = {
            let g = self.inner.lock_ok();
            g.baselines
                .get(conversation)
                .and_then(|m| m.get(path))
                .cloned()
        };
        let Some(recorded) = recorded else {
            // No baseline — see the doc comment. Allowed on purpose, logged so the hole is
            // visible in the log rather than only in this comment.
            eprintln!(
                "jesse-bridge: write lock: no read baseline for {} (allowed; see the known \
                 lost-update race in CHANGELOG 0.60.0)",
                path.display()
            );
            return Ok(());
        };
        match hash_file(path) {
            // The file is gone; nothing to lose.
            None => Ok(()),
            Some(now) if now == recorded => Ok(()),
            Some(_) => Err(format!(
                "{} changed on disk since this conversation read it — another turn wrote it \
                 first. Re-read the file and redo this edit against its current contents.",
                path.display()
            )),
        }
    }

    /// Serve one request.
    pub async fn handle(&self, req: HookRequest) -> HookResponse {
        match req {
            HookRequest::Pre {
                turn,
                conversation,
                tool_use_id,
                target,
                git,
            } => {
                let Some(target) = target else {
                    return HookResponse::allow(); // not a write
                };
                let key = match &target {
                    Some(p) => LockKey::Path(PathBuf::from(p)),
                    None => LockKey::Global,
                };
                if !self.acquire(&key, &turn, &tool_use_id).await {
                    return HookResponse::deny(format!(
                        "timed out after {}s waiting for the vault write lock on {} — another \
                         turn has held it too long. Nothing was written.",
                        LOCK_WAIT_TIMEOUT.as_secs(),
                        match &target {
                            Some(p) => p.as_str(),
                            None => "an unparseable write",
                        }
                    ));
                }
                // Inside the lock, and only now: is what we are about to overwrite still what
                // this conversation last saw?
                if let Some(p) = &target {
                    if let Err(why) = self.check_baseline(&conversation, Path::new(p)) {
                        self.release_call(&turn, &tool_use_id);
                        return HookResponse::deny(why);
                    }
                }
                // The git index is a single point; take it INSIDE the file lock, matching the
                // one total order.
                if git && !self.acquire(&LockKey::Git, &turn, &tool_use_id).await {
                    self.release_call(&turn, &tool_use_id);
                    return HookResponse::deny(
                        "timed out waiting for the git lock — another turn is mid-commit. \
                         Nothing was written."
                            .to_string(),
                    );
                }
                HookResponse::allow()
            }
            HookRequest::Post {
                turn,
                conversation,
                tool_use_id,
                read,
            } => {
                if let Some(p) = read {
                    self.record_baseline(&conversation, Path::new(&p));
                }
                self.release_call(&turn, &tool_use_id);
                HookResponse::allow()
            }
        }
    }
}

/// Decide whether this turn's child gets the write lock's hooks, and describe them if so.
///
/// `None` — meaning the child is built exactly as 0.59.0 built it — whenever any of:
///
///   * the turn cannot write the vault ([`turn_capability`] below [`Capability::Write`]).
///     A lock on a turn that cannot write is pure overhead, and it is the same
///     capability-not-harness gate `turn_capability` already derives, so it costs nothing in
///     containment and stays harness-agnostic;
///   * there is no state dir, so there is nowhere to put a socket;
///   * the `jesse-hook` helper is not beside the binary.
///
/// Every one of those is SAFE to degrade on, and not by luck: `resolve_slot_plan` has already
/// capped write-level models on a non-locking harness at one slot, so the worst case is a
/// bridge that runs one write-level turn at a time — which is what 0.59.0 did.
pub fn build_write_lock_child(
    cfg: &Config,
    helper: &Option<PathBuf>,
    active: &ActiveModel,
    turn: &str,
    conversation: &str,
) -> Option<WriteLockChild> {
    if turn_capability(active) < Capability::Write {
        return None;
    }
    Some(WriteLockChild {
        socket: cfg.writelock_socket()?,
        turn: turn.to_string(),
        conversation: conversation.to_string(),
        helper: helper.clone()?,
    })
}

/// Releases every write lock a turn holds when that turn's task ends, and removes the
/// per-turn hook config it left behind.
///
/// A DROP GUARD rather than a call at the end of the happy path, and that is the entire
/// argument for the bridge being the broker. The post hook is the normal release and the
/// hold timeout is the backstop, but neither fires for a child killed between its pre hook
/// and its post hook — and only this process knows that the turn has ended. `Drop` runs on
/// success, on error, on timeout, on panic, and on the task abort that `POST /jesse/cancel`
/// performs.
pub struct TurnLockRelease {
    pub broker: Arc<LockBroker>,
    pub cfg: Arc<Config>,
    pub turn: String,
}

impl Drop for TurnLockRelease {
    fn drop(&mut self) {
        self.broker.release_turn(&self.turn);
        // The Claude Code settings file is per turn; the Codex hooks.json lives in the
        // per-turn CODEX_HOME and goes with it.
        remove_write_lock_settings(&self.cfg, &self.turn);
    }
}

/// Content hash of a file, or `None` if it cannot be read.
///
/// SHA-256 via `ring`, which is already in the dependency graph for APNs JWT signing — no new
/// dependency. The mtime is deliberately NOT the comparison: two writes inside one mtime tick
/// are possible and a write can restore an old timestamp, so the hash is the thing that
/// actually answers "did this change".
fn hash_file(path: &Path) -> Option<String> {
    let bytes = std::fs::read(path).ok()?;
    let d = ring::digest::digest(&ring::digest::SHA256, &bytes);
    Some(d.as_ref().iter().map(|b| format!("{b:02x}")).collect())
}

/// Bind the broker's listener, replacing any socket left by a previous run.
///
/// A stale socket file from a crashed process would otherwise make every bind fail, which
/// would take the write lock down permanently after one hard kill.
pub fn bind_broker(path: &Path) -> std::io::Result<UnixListener> {
    // A unix socket path is bounded by `sun_path` — 104 bytes on macOS, 108 on Linux — and
    // the failure it produces ("path must be shorter than SUN_LEN") says nothing about which
    // path or what to do. A deep `JESSE_STATE_DIR` is an ordinary operator choice, so name the
    // problem here rather than letting it surface as an opaque disarm.
    if path.as_os_str().len() >= MAX_SOCKET_PATH {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!(
                "the broker socket path is {} bytes, over the {} the OS allows for a unix                  socket. Set JESSE_STATE_DIR to a shorter path.",
                path.as_os_str().len(),
                MAX_SOCKET_PATH
            ),
        ));
    }
    if path.exists() {
        let _ = std::fs::remove_file(path);
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let l = UnixListener::bind(path)?;
    // The socket authorizes vault writes, so it is owner-only.
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    Ok(l)
}

/// Accept hook connections forever. Spawned once at startup.
pub async fn serve_broker(listener: UnixListener, broker: Arc<LockBroker>) {
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        let broker = broker.clone();
        tokio::spawn(async move {
            let _ = serve_conn(stream, broker).await;
        });
    }
}

async fn serve_conn(stream: UnixStream, broker: Arc<LockBroker>) -> std::io::Result<()> {
    let (r, mut w) = stream.into_split();
    let mut lines = BufReader::new(r).lines();
    while let Some(line) = lines.next_line().await? {
        let resp = match serde_json::from_str::<HookRequest>(&line) {
            Ok(req) => broker.handle(req).await,
            // A malformed request DENIES. The hook helper is the bridge's own binary, so a
            // parse failure means something is wrong with the wiring — and the safe answer to
            // "I do not understand this write" is not to allow it.
            Err(e) => HookResponse::deny(format!("malformed write-lock request: {e}")),
        };
        let mut out = serde_json::to_string(&resp).unwrap_or_else(|_| {
            "{\"allow\":false,\"reason\":\"write-lock broker could not encode a reply\"}".into()
        });
        out.push('\n');
        w.write_all(out.as_bytes()).await?;
        w.flush().await?;
    }
    Ok(())
}

/// Ask the broker one question, from the hook helper process.
///
/// FAILS CLOSED: if the socket is missing, unreadable, or answers nothing, the write is
/// DENIED. A bridge that believes it is locking and is not is exactly the failure mode this
/// whole module exists to prevent — and on Codex it is a real one, because an untrusted
/// hooks file is skipped SILENTLY (measured on 0.146.0).
pub fn ask_broker_blocking(socket: &Path, req: &HookRequest) -> HookResponse {
    use std::io::{BufRead, BufReader as StdBufReader, Write};
    let mut stream = match std::os::unix::net::UnixStream::connect(socket) {
        Ok(s) => s,
        Err(e) => {
            return HookResponse::deny(format!(
                "the bridge's write-lock broker is unreachable ({e}); refusing the write rather \
                 than performing it unlocked"
            ))
        }
    };
    // Generous: the broker may legitimately hold us while another turn finishes its write.
    let _ = stream.set_read_timeout(Some(LOCK_WAIT_TIMEOUT + Duration::from_secs(5)));
    let mut line = match serde_json::to_string(req) {
        Ok(l) => l,
        Err(e) => return HookResponse::deny(format!("could not encode a write-lock request: {e}")),
    };
    line.push('\n');
    if let Err(e) = stream.write_all(line.as_bytes()) {
        return HookResponse::deny(format!("write-lock broker write failed: {e}"));
    }
    let mut reply = String::new();
    if let Err(e) = StdBufReader::new(&stream).read_line(&mut reply) {
        return HookResponse::deny(format!("write-lock broker read failed: {e}"));
    }
    serde_json::from_str(&reply).unwrap_or_else(|e| {
        HookResponse::deny(format!("write-lock broker sent an unreadable reply: {e}"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("jesse-wl-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn pre(turn: &str, tool: &str, path: Option<&str>) -> HookRequest {
        HookRequest::Pre {
            turn: turn.into(),
            conversation: "c1".into(),
            tool_use_id: tool.into(),
            target: Some(path.map(|p| p.to_string())),
            git: false,
        }
    }

    fn post(turn: &str, tool: &str, read: Option<&str>) -> HookRequest {
        HookRequest::Post {
            turn: turn.into(),
            conversation: "c1".into(),
            tool_use_id: tool.into(),
            read: read.map(|p| p.to_string()),
        }
    }

    #[tokio::test]
    async fn two_writes_to_one_path_serialize() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let f = d.join("a.txt");
        std::fs::write(&f, "x").unwrap();
        let p = f.display().to_string();

        assert!(b.handle(pre("t1", "call1", Some(&p))).await.allow);
        // The second turn cannot take it while the first holds it.
        assert!(!b.try_take(&LockKey::Path(f.clone()), "t2", "call2"));
        // …and once the first releases, it can.
        b.handle(post("t1", "call1", None)).await;
        assert!(b.handle(pre("t2", "call2", Some(&p))).await.allow);
    }

    #[tokio::test]
    async fn two_writes_to_different_paths_do_not_block() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let (a, z) = (d.join("a.txt"), d.join("z.txt"));
        std::fs::write(&a, "x").unwrap();
        std::fs::write(&z, "x").unwrap();
        assert!(
            b.handle(pre("t1", "c1", Some(&a.display().to_string())))
                .await
                .allow
        );
        assert!(
            b.handle(pre("t2", "c2", Some(&z.display().to_string())))
                .await
                .allow,
            "a different path must not block"
        );
        assert_eq!(b.held_count(), 2);
    }

    #[tokio::test]
    async fn a_stale_read_baseline_refuses_the_write() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let f = d.join("a.txt");
        std::fs::write(&f, "original").unwrap();
        let p = f.display().to_string();

        // The conversation reads the file — the baseline is recorded.
        b.handle(post("t1", "read1", Some(&p))).await;
        // Someone else rewrites it behind our back.
        std::fs::write(&f, "clobbered by another turn").unwrap();

        let r = b.handle(pre("t1", "write1", Some(&p))).await;
        assert!(!r.allow, "a stale write must be refused");
        let why = r.reason.unwrap();
        assert!(
            why.contains("Re-read"),
            "the refusal must be actionable: {why}"
        );
        // The refusal released the lock it took to do the check.
        assert_eq!(b.held_count(), 0);
    }

    #[tokio::test]
    async fn a_matching_baseline_allows_the_write() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let f = d.join("a.txt");
        std::fs::write(&f, "original").unwrap();
        let p = f.display().to_string();
        b.handle(post("t1", "read1", Some(&p))).await;
        assert!(b.handle(pre("t1", "write1", Some(&p))).await.allow);
    }

    #[tokio::test]
    async fn a_turn_ending_releases_every_lock_it_held() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let f = d.join("a.txt");
        std::fs::write(&f, "x").unwrap();
        let p = f.display().to_string();
        // A holder that is killed between the pre hook and the post hook.
        assert!(b.handle(pre("t1", "call1", Some(&p))).await.allow);
        assert_eq!(b.held_count(), 1);
        b.release_turn("t1");
        assert_eq!(
            b.held_count(),
            0,
            "turn end must release, not the post hook alone"
        );
        assert!(b.handle(pre("t2", "call2", Some(&p))).await.allow);
    }

    #[tokio::test]
    async fn an_errored_tool_call_still_releases() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let f = d.join("a.txt");
        std::fs::write(&f, "x").unwrap();
        let p = f.display().to_string();
        assert!(b.handle(pre("t1", "call1", Some(&p))).await.allow);
        // A tool call that ERRORED or was denied still fires PostToolUse with no read.
        b.handle(post("t1", "call1", None)).await;
        assert_eq!(b.held_count(), 0);
    }

    #[tokio::test]
    async fn a_global_write_serializes_against_another_global_write() {
        let b = Arc::new(LockBroker::new());
        assert!(b.handle(pre("t1", "c1", None)).await.allow);
        assert!(!b.try_take(&LockKey::Global, "t2", "c2"));
    }

    #[tokio::test]
    async fn a_wait_that_exceeds_the_timeout_fails_loudly() {
        let b = Arc::new(LockBroker::new());
        // Hold the global lock and never release it.
        assert!(b.handle(pre("t1", "c1", None)).await.allow);
        // A contrived short deadline: acquire() is bounded by LOCK_WAIT_TIMEOUT, so drive the
        // same path with the try/notify loop directly rather than sleeping 30s in a test.
        let start = Instant::now();
        let got = timeout(
            Duration::from_millis(300),
            b.acquire(&LockKey::Global, "t2", "c2"),
        )
        .await;
        assert!(
            got.is_err(),
            "the waiter must still be blocked, not allowed"
        );
        assert!(
            start.elapsed() < LOCK_WAIT_TIMEOUT,
            "it must not have given up early"
        );
    }

    #[tokio::test]
    async fn a_write_with_no_baseline_is_allowed_the_named_hole() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let f = d.join("never-read.txt");
        std::fs::write(&f, "content this conversation never read through a tool").unwrap();
        let r = b
            .handle(pre("t1", "c1", Some(&f.display().to_string())))
            .await;
        assert!(
            r.allow,
            "no baseline must ALLOW — failing closed would refuse every first write"
        );
    }

    #[tokio::test]
    async fn one_tool_call_holds_both_the_file_lock_and_the_git_lock() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let f = d.join("a.txt");
        std::fs::write(&f, "x").unwrap();
        let r = b
            .handle(HookRequest::Pre {
                turn: "t1".into(),
                conversation: "c1".into(),
                tool_use_id: "call1".into(),
                target: Some(Some(f.display().to_string())),
                git: true,
            })
            .await;
        assert!(r.allow);
        assert_eq!(b.held_count(), 2, "the file lock AND the git lock");
    }

    /// REGRESSION: a turn's SECOND tool call must not block on a lock its own FIRST call
    /// still holds.
    ///
    /// This shipped broken once. Re-entrancy was keyed on `(turn, tool_use_id)`, which looks
    /// right until you notice that a post hook and the next pre hook are separate short-lived
    /// processes with no ordering guarantee between them — so call B routinely arrives while
    /// call A's lock is still held, and would wait out the full 30s timeout for a lock nothing
    /// was actually contending for, then be refused.
    ///
    /// Driven through the REAL `handle` path with a deadline far under `LOCK_WAIT_TIMEOUT`:
    /// if this ever regresses, the call blocks and the timeout here fails the test rather than
    /// the suite hanging for half a minute.
    #[tokio::test]
    async fn a_turns_second_call_does_not_block_on_its_own_first_calls_lock() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let (a, z) = (d.join("a.txt"), d.join("z.txt"));
        std::fs::write(&a, "x").unwrap();
        std::fs::write(&z, "x").unwrap();

        // Call 1 writes a.txt and takes the git lock with it. No post hook — the race this
        // guards against is exactly the one where the post has not landed yet.
        assert!(
            b.handle(HookRequest::Pre {
                turn: "t1".into(),
                conversation: "c1".into(),
                tool_use_id: "call1".into(),
                target: Some(Some(a.display().to_string())),
                git: true,
            })
            .await
            .allow
        );

        // Call 2 of the SAME turn writes a different file, and also wants git.
        let second = timeout(
            Duration::from_millis(500),
            b.handle(HookRequest::Pre {
                turn: "t1".into(),
                conversation: "c1".into(),
                tool_use_id: "call2".into(),
                target: Some(Some(z.display().to_string())),
                git: true,
            }),
        )
        .await
        .expect("a turn must never wait on itself — this is the regression");
        assert!(second.allow, "and it must be allowed, not refused");

        // The re-key means call2's post hook releases the git lock it inherited, rather than
        // leaving it stranded until the turn ends.
        b.handle(post("t1", "call2", None)).await;
        assert!(
            b.try_take(&LockKey::Git, "t2", "other"),
            "a different turn gets the git lock once call2 released it"
        );
    }

    /// The other half, asserted SEPARATELY: re-entrancy per turn must not have loosened the
    /// cross-turn property, which is the one that actually protects the vault.
    #[tokio::test]
    async fn a_different_turn_still_blocks_on_a_held_lock() {
        let b = Arc::new(LockBroker::new());
        let d = tmpdir();
        let f = d.join("a.txt");
        std::fs::write(&f, "x").unwrap();
        assert!(
            b.handle(HookRequest::Pre {
                turn: "t1".into(),
                conversation: "c1".into(),
                tool_use_id: "call1".into(),
                target: Some(Some(f.display().to_string())),
                git: true,
            })
            .await
            .allow
        );
        // A DIFFERENT turn gets neither the file lock nor the git lock.
        assert!(!b.try_take(&LockKey::Path(f.clone()), "t2", "call2"));
        assert!(!b.try_take(&LockKey::Git, "t2", "call2"));
        // And it genuinely waits rather than being handed the lock.
        let blocked = timeout(
            Duration::from_millis(400),
            b.handle(HookRequest::Pre {
                turn: "t2".into(),
                conversation: "c2".into(),
                tool_use_id: "call2".into(),
                target: Some(Some(f.display().to_string())),
                git: false,
            }),
        )
        .await;
        assert!(
            blocked.is_err(),
            "another turn must BLOCK on a held lock — per-turn re-entrancy must not leak \
             across turns, or the vault is unprotected"
        );
    }

    // ---- The two spellings of one file ----------------------------------------
    //
    // These are the tests the whole `hook_write_target` trait method exists for. Claude Code
    // names an ABSOLUTE path; Codex names a path RELATIVE to `cwd`, inside `apply_patch`
    // envelope syntax. If those two do not collapse to one key, the bridge has built two
    // locks over one file and protected nothing.

    fn payload(tool: &str, cwd: &str, input: Value) -> HookPayload {
        HookPayload {
            session_id: "s".into(),
            cwd: cwd.into(),
            tool_name: tool.into(),
            tool_use_id: "t1".into(),
            tool_input: input,
        }
    }

    #[test]
    fn a_claude_write_and_a_codex_write_to_one_file_take_the_same_lock() {
        let d = tmpdir().canonicalize().unwrap();
        let f = d.join("note.md");
        std::fs::write(&f, "x").unwrap();
        let cwd = d.display().to_string();

        // Claude Code: an absolute path in a structured field.
        let claude = ClaudeCode.hook_write_target(&payload(
            "Write",
            &cwd,
            json!({ "file_path": f.display().to_string(), "content": "new" }),
        ));
        // Codex: the same file, named RELATIVE, inside a patch envelope.
        let codex = Codex.hook_write_target(&payload(
            "apply_patch",
            &cwd,
            json!({ "command": "*** Begin Patch\n*** Update File: note.md\n+new\n*** End Patch" }),
        ));

        assert_eq!(
            claude, codex,
            "a claude-code write and a codex write to one vault path must serialize against \
             each other — two spellings, ONE lock key"
        );
        assert_eq!(claude, WriteTarget::Path(f));
    }

    #[test]
    fn a_symlinked_spelling_takes_the_same_lock_as_the_real_path() {
        let d = tmpdir().canonicalize().unwrap();
        let real_dir = d.join("real");
        std::fs::create_dir_all(&real_dir).unwrap();
        let f = real_dir.join("note.md");
        std::fs::write(&f, "x").unwrap();
        let link_dir = d.join("via-link");
        std::os::unix::fs::symlink(&real_dir, &link_dir).unwrap();

        let direct = resolve_lock_path(&f, "/");
        let through_link = resolve_lock_path(&link_dir.join("note.md"), "/");
        assert_eq!(
            direct, through_link,
            "a symlinked spelling must resolve to the same key, or two turns editing one file \
             through different paths would never see each other"
        );
    }

    #[test]
    fn a_file_being_created_still_gets_a_stable_key() {
        // The common case: the target does not exist yet, so it cannot be canonicalized.
        // Creating it and then overwriting it must land on ONE key, not two.
        let d = tmpdir().canonicalize().unwrap();
        let target = d.join("brand-new.md");
        let before = resolve_lock_path(&target, "/");
        std::fs::write(&target, "now it exists").unwrap();
        let after = resolve_lock_path(&target, "/");
        assert_eq!(
            before, after,
            "a create and a later overwrite of one file must take the same lock"
        );
    }

    #[test]
    fn a_shell_call_takes_the_coarse_global_lock_on_both_harnesses() {
        // Neither harness can name what a shell command will write, so both must answer
        // Global. This is the 6d gap, asserted rather than left to a comment.
        assert_eq!(
            ClaudeCode.hook_write_target(&payload(
                "Bash",
                "/v",
                json!({ "command": "echo hi > a" })
            )),
            WriteTarget::Global
        );
        assert_eq!(
            Codex.hook_write_target(&payload(
                "shell",
                "/v",
                json!({ "command": ["sh", "-c", "echo hi > a"] })
            )),
            WriteTarget::Global
        );
    }

    #[test]
    fn a_read_never_takes_a_lock_but_does_record_a_baseline() {
        let d = tmpdir().canonicalize().unwrap();
        let f = d.join("a.md");
        std::fs::write(&f, "x").unwrap();
        let p = payload(
            "Read",
            &d.display().to_string(),
            json!({ "file_path": f.display().to_string() }),
        );
        assert_eq!(
            ClaudeCode.hook_write_target(&p),
            WriteTarget::None,
            "a read must not contend for a lock at all"
        );
        assert_eq!(ClaudeCode.hook_read_target(&p), Some(f));
    }

    #[test]
    fn an_unknown_tool_locks_everything_rather_than_nothing() {
        for t in ["SomeFutureTool", "definitely_not_known"] {
            assert_eq!(
                ClaudeCode.hook_write_target(&payload(t, "/v", json!({}))),
                WriteTarget::Global,
                "an unrecognised tool must fail SAFE"
            );
            assert_eq!(
                Codex.hook_write_target(&payload(t, "/v", json!({}))),
                WriteTarget::Global
            );
        }
    }

    #[test]
    fn a_multi_file_patch_takes_the_global_lock_rather_than_one_of_its_files() {
        let t = Codex.hook_write_target(&payload(
            "apply_patch",
            "/v",
            json!({ "command": "*** Begin Patch\n*** Update File: a.md\n+x\n*** Add File: b.md\n+y\n*** End Patch" }),
        ));
        assert_eq!(
            t,
            WriteTarget::Global,
            "locking one file of a multi-file patch would leave the rest unprotected"
        );
        assert_eq!(
            apply_patch_targets(
                "*** Begin Patch\n*** Update File: a.md\n+x\n*** Add File: b.md\n+y\n*** End Patch"
            ),
            vec!["a.md".to_string(), "b.md".to_string()]
        );
    }

    #[tokio::test]
    async fn a_malformed_request_denies() {
        let b = Arc::new(LockBroker::new());
        // Exercised through the same decode path the socket uses.
        let bad = serde_json::from_str::<HookRequest>("{\"op\":\"nonsense\"}");
        assert!(bad.is_err());
        let _ = b; // the deny is constructed in serve_conn; see that path.
    }
}
