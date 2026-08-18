use crate::*;

// ---- The artifact return channel -------------------------------------------
//
// Files have always moved in exactly one direction. `attachments` decodes what the
// phone sends, writes it to a per-request scratch dir and lets the child read it. The
// reply going the other way is a STRING, so a turn that renders a chart, exports a CSV
// or writes a PDF either described the work in prose or lost it.
//
// This module is the other direction: a per-job STAGING directory the child writes into,
// a SWEEP that moves what it finds into a bounded server-side store when the turn ends,
// and a metadata sidecar (never the bytes) that rides the reply to the phone.
//
// ---- WHERE THE STAGING DIRECTORY HAS TO LIVE, and why it is not beside the scratch dir
//
// It would be tidy to put it under the system temp dir next to `ScratchDir`. It cannot
// work, on either harness, and the measurements are already in the tree:
//
//   * CLAUDE CODE. `--add-dir` grants READS inside the named directory and confers NO
//     write — see the comment block at the push site in `harness::claude_code`, which
//     records the measurement against claude 2.1.223: with `Write(./**)` allowed and the
//     directory added, a write INTO the added directory was still refused and the file
//     was never created.
//   * CODEX. `sandbox_workspace_write.writable_roots` is set to exactly the turn's cwd,
//     with `/tmp` and `$TMPDIR` excluded on purpose so a write cannot be laundered
//     through a world-writable path (see `harness::codex`).
//
// On both harnesses THE ONLY WRITABLE LOCATION IS THE TURN'S OWN WORKING DIRECTORY. So
// the staging directory is inside it, and the bridge moves files out of it the moment
// the turn ends. No containment record moves for any of this: the working directory is
// already writable at `Capability::Write`, which is the only capability that gets a
// staging directory at all.
//
// ---- THE WORKING DIRECTORY IS A GIT REPOSITORY -----------------------------------
//
// The vault is committed by an automatic timer, so an artifact that lands in that
// history is there permanently and on a remote. The staging directory therefore carries
// a `.gitignore` whose entire content is `*` — a directory that ignores itself, needing
// no change to any file in the vault repository (which this bridge does not own).
//
// Verified 2026-08-18 against the real vault (`~/jesse`, whose working tree the child's
// cwd `~/jesse/vault` sits inside): with `.jesse-artifacts/.gitignore` written and a
// file staged under it, `git status --porcelain` was byte-identical to its baseline, and
// `git check-ignore -v` named `vault/.jesse-artifacts/.gitignore:1:*` as the matching
// rule. See `staging_gitignore_hides_the_directory_from_git`, which asserts the same
// property against a scratch repository so a regression is caught without a vault.
//
// ---- DEGRADATION ------------------------------------------------------------------
//
// With no state dir configured there is NO artifact store — nowhere to move a swept file
// to — so the channel degrades to off: no staging directory, no prompt fragment, no
// metadata on the reply. That is the same degradation the job / title / flag / deletion
// stores already have, and it is stated here rather than worked around.

// ---- Per-turn caps (env-overridable defaults) ------------------------------
//
// Three budgets, and none of them substitutes for the others: a file count, a per-file
// size, and a per-turn total. Keep in sync with `bridge/README.md`.

/// Max artifacts accepted from one turn. Override: `JESSE_MAX_ARTIFACTS`.
pub const DEFAULT_MAX_ARTIFACTS: usize = 10;
/// Max size of any one artifact. Override: `JESSE_MAX_ARTIFACT_BYTES`.
pub const DEFAULT_MAX_ARTIFACT_BYTES: u64 = 25 * 1024 * 1024;
/// Max combined size of all artifacts from one turn. Override:
/// `JESSE_MAX_ARTIFACTS_TOTAL_BYTES`.
pub const DEFAULT_MAX_ARTIFACTS_TOTAL_BYTES: u64 = 50 * 1024 * 1024;

// ---- Server-side budgets (env-overridable defaults) ------------------------

/// How long a stored artifact is kept. Override: `JESSE_ARTIFACT_TTL_DAYS`.
pub const DEFAULT_ARTIFACT_TTL_DAYS: u64 = 30;
/// The total-size high-water mark for the store. Over it, oldest-first eviction runs
/// until the total is back under. Override: `JESSE_ARTIFACT_STORE_MAX_BYTES`.
pub const DEFAULT_ARTIFACT_STORE_MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// The directory name the staging dir takes inside the working directory. One
/// constant: the prompt fragment, the `.gitignore` and the sweep all name it.
pub const STAGING_DIR_NAME: &str = ".jesse-artifacts";

// ---- The route decision ----------------------------------------------------

/// WHETHER THIS TURN GETS AN ARTIFACT CHANNEL AT ALL.
///
/// Stated as a type rather than a chain of `if`s for the same reason
/// [`AttachmentRoute`] is: the two ways of getting it wrong are both silent. Promise a
/// channel to a turn that cannot write and the model is told it can return a file it has
/// no way to produce; create a staging directory with nowhere to sweep it to and the
/// files are written, deleted, and never mentioned again.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactRoute {
    /// No staging directory, no prompt fragment, no metadata — byte-for-byte an
    /// ordinary turn. This is every `Read` and `Basic` turn (it cannot write, so an
    /// artifact channel would be a lie), and every turn on a bridge with no state dir
    /// (there is no store to sweep into).
    None,
    /// A per-job staging directory inside the turn's working directory, named in the
    /// prompt and swept into the artifact store when the turn ends.
    Staged,
}

/// Decide the route. Pure, so the exclusivity is a property the tests hold rather than a
/// shape a reader re-derives from the handler.
///
/// `store_available` must mean the artifact store actually EXISTS (a state dir is
/// configured), not that the feature is compiled in.
pub fn artifact_route(capability: Capability, store_available: bool) -> ArtifactRoute {
    match (capability, store_available) {
        (Capability::Write, true) => ArtifactRoute::Staged,
        _ => ArtifactRoute::None,
    }
}

// ---- The staging directory -------------------------------------------------

/// A per-job staging directory at `<working_dir>/.jesse-artifacts/<job_id>/`, mode 0700.
///
/// Removed by `Drop` on every exit path — success, error, timeout, panic, and the task
/// abort a cancel performs — because a directory that survives a failed turn is litter
/// inside a git repository. The SWEEP (which moves files into the store) is an explicit
/// call on the normal completion path; a CANCELLED turn therefore discards whatever it
/// had staged, which is the honest behaviour for a turn the user stopped.
pub struct StagingDir {
    pub path: PathBuf,
    /// The `.jesse-artifacts` parent. Removed by `Drop` too, but only if empty — a
    /// concurrent turn may still be staging into its own sibling job directory.
    parent: PathBuf,
}

impl StagingDir {
    /// Create `<working_dir>/.jesse-artifacts/<job_id>/` and the self-ignoring
    /// `.gitignore` beside it. Both are created before the child ever runs, so there is
    /// no window in which a staged file is visible to `git status`.
    pub fn create(working_dir: &Path, job_id: &str) -> std::io::Result<StagingDir> {
        let parent = working_dir.join(STAGING_DIR_NAME);
        // `create_dir_all` rather than `create`: a concurrent turn may have made the
        // parent already, and that is not an error. The per-job child below is
        // `create_new`, so two turns can never share one staging directory.
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&parent)?;
        write_staging_gitignore(&parent)?;
        let path = parent.join(job_id);
        std::fs::DirBuilder::new()
            .recursive(false)
            .mode(0o700)
            .create(&path)?;
        Ok(StagingDir { path, parent })
    }
}

impl Drop for StagingDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
        // Only when empty: `remove_dir` fails (and is ignored) while another turn's job
        // directory or the `.gitignore` is still in there. The `.gitignore` alone keeps
        // this non-empty in practice, which is correct — the next turn reuses it.
        let _ = std::fs::remove_dir(&self.parent);
    }
}

/// Write the `.gitignore` whose entire content is `*`.
///
/// Rewritten unconditionally rather than created-if-missing: the file is the only thing
/// standing between a staged artifact and a permanent commit on a remote, so a truncated
/// or tampered copy must not survive a restart.
fn write_staging_gitignore(parent: &Path) -> std::io::Result<()> {
    let path = parent.join(".gitignore");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)?;
    f.write_all(b"*\n")
}

/// The prompt fragment that tells the model where a returned file must be written.
///
/// Short on purpose, and in the same spirit as [`attachment_prompt_suffix`]: it names
/// one directory and one rule. It is appended ONLY on a turn that actually has a staging
/// directory, so an ordinary turn's prompt is byte-for-byte what it was.
pub fn artifact_prompt_suffix(dir: &Path, caps: &ArtifactCaps) -> String {
    format!(
        "\n\n(If this turn produces a file for the user — a chart, a PDF, a CSV export, a \
         rendered page — write it into {} and it is returned with your reply. A file \
         written anywhere else is NOT returned. Up to {} file(s), {} MB each. Accepted: \
         PNG, JPEG, PDF, SVG, plain text, CSV, JSON, Markdown, HTML.)",
        dir.display(),
        caps.max_files,
        caps.max_file_bytes / (1024 * 1024),
    )
}

// ---- Sniffing --------------------------------------------------------------

/// Sniff a returned file's type FROM ITS BYTES, and decide whether the channel carries
/// it at all. Returns `(canonical_mime, on-disk extension)`, or `None` to reject.
///
/// `name_hint` is the model's own filename and is used for EXACTLY ONE thing: choosing
/// between `text/plain`, `text/csv` and `text/markdown` for a file whose bytes have
/// already been verified to be text. It never decides acceptance, it never reaches a
/// path, and a lying extension on a binary file cannot survive the magic-byte checks
/// above it.
///
/// # Why the extension appears here at all
///
/// The rule this channel follows is "sniff from the bytes, never the extension", and for
/// every BINARY type it holds exactly: PNG, JPEG and PDF each have a signature, anything
/// unrecognized is rejected, and this is fail-closed on purpose — a real new type the
/// channel should carry fails loudly in testing and gets added deliberately.
///
/// CSV, Markdown and plain text have no signature and are not distinguishable from one
/// another by content: a one-column CSV, a Markdown paragraph and a line of prose are
/// the same bytes. Applied literally the rule would reject all three, which contradicts
/// the same requirement that lists them as accepted types. So the bytes decide
/// ACCEPTANCE (valid UTF-8, no control characters beyond tab/CR/LF, not a script) and
/// the structured text forms that DO have a recognizable shape (SVG, HTML, JSON) are
/// still recognized from content; the extension only picks a display label among three
/// MIMEs that describe the identical, already-accepted bytes.
pub fn sniff_artifact(b: &[u8], name_hint: &str) -> Option<(&'static str, &'static str)> {
    // Executables first, so a Mach-O with a `.png` name and a shell script with a `.txt`
    // name are both refused before any accepting branch can see them.
    if is_executable(b) {
        return None;
    }
    if b.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return Some(("image/png", "png"));
    }
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(("image/jpeg", "jpg"));
    }
    if b.starts_with(b"%PDF-") {
        return Some(("application/pdf", "pdf"));
    }
    // Everything below is text, so it must BE text: valid UTF-8 with no control
    // characters other than tab / CR / LF. This is what refuses an arbitrary binary
    // blob that happens to start with a `<`.
    let text = std::str::from_utf8(b).ok()?;
    if text.is_empty() {
        return None;
    }
    if text
        .chars()
        .any(|c| c.is_control() && !matches!(c, '\t' | '\n' | '\r'))
    {
        return None;
    }
    let head: String = text.chars().take(1024).collect::<String>().to_lowercase();
    let head = head.trim_start();
    if head.starts_with("<svg") || (head.starts_with("<?xml") && head.contains("<svg")) {
        return Some(("image/svg+xml", "svg"));
    }
    if head.starts_with("<!doctype html") || head.starts_with("<html") {
        return Some(("text/html", "html"));
    }
    // JSON is checked by PARSING, not by a leading brace: `{ not json` must not be
    // labelled `application/json` and then fail to open on the phone.
    let trimmed = text.trim_start();
    if (trimmed.starts_with('{') || trimmed.starts_with('['))
        && serde_json::from_str::<Value>(text).is_ok()
    {
        return Some(("application/json", "json"));
    }
    // Verified text with no recognizable structure. The extension picks the label.
    match extension_of(name_hint).as_str() {
        "csv" => Some(("text/csv", "csv")),
        "md" | "markdown" => Some(("text/markdown", "md")),
        _ => Some(("text/plain", "txt")),
    }
}

/// The lowercased extension of a display filename, or `""`. Never used as a path
/// component — only to read the three text labels above.
fn extension_of(name: &str) -> String {
    Path::new(name)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase()
}

/// Whether these bytes are a program. Mach-O (both endiannesses, 32- and 64-bit, plus
/// the fat/universal wrappers), ELF, and a `#!` script.
///
/// A script is the one that matters most here: it is valid UTF-8 text and would sail
/// through the text branch, and "the model returned a shell script the user then ran"
/// is the failure this rejection exists to prevent.
pub fn is_executable(b: &[u8]) -> bool {
    const MACH_O: [[u8; 4]; 6] = [
        [0xFE, 0xED, 0xFA, 0xCE], // 32-bit big-endian
        [0xFE, 0xED, 0xFA, 0xCF], // 64-bit big-endian
        [0xCE, 0xFA, 0xED, 0xFE], // 32-bit little-endian
        [0xCF, 0xFA, 0xED, 0xFE], // 64-bit little-endian
        [0xCA, 0xFE, 0xBA, 0xBE], // fat/universal
        [0xBE, 0xBA, 0xFE, 0xCA], // fat/universal, byte-swapped
    ];
    if b.len() >= 4 && MACH_O.iter().any(|m| b.starts_with(m)) {
        return true;
    }
    if b.starts_with(b"\x7FELF") {
        return true;
    }
    b.starts_with(b"#!")
}

// ---- SHA-256 ---------------------------------------------------------------

/// Hex SHA-256 of a byte slice, through `ring` — already in the graph as rustls' crypto
/// backend and as the APNs JWT signer, so this adds no dependency.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let d = ring::digest::digest(&ring::digest::SHA256, bytes);
    let mut s = String::with_capacity(64);
    for b in d.as_ref() {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

// ---- The wire element ------------------------------------------------------

/// ONE artifact as the reply carries it: identity, display metadata, and a content hash.
///
/// **It never carries the bytes.** Inlining base64 would push binary content into the job
/// JSON, the persisted job file, the SSE frame and the conversation store all at once,
/// which is the failure this whole design exists to avoid. The bytes are fetched
/// separately from `GET /jesse/artifact/{id}`.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Artifact {
    /// Fresh random hex from the same generator `ScratchDir` uses. It reaches a URL, so
    /// it must be unguessable, and it is re-validated as hex on the way back in.
    pub id: String,
    /// The model's own filename, kept for DISPLAY ONLY. Never a path component: the
    /// on-disk name is `<id>.<sniffed ext>`.
    pub filename: String,
    /// The canonical MIME the byte sniff decided.
    pub mime: String,
    pub bytes: u64,
    /// Hex SHA-256 of the content. Doubles as the fetch route's `ETag`.
    pub sha256: String,
}

/// The `artifacts` sidecar as JSON, mirroring `directives_to_value` /
/// `provenance_to_value`: an EMPTY list serializes to `null`, so a reply with no
/// artifacts is byte-for-byte the reply an older bridge sent and an older client sees
/// exactly the field it has always seen (absent/null).
pub fn artifacts_to_value(artifacts: &[Artifact]) -> Value {
    if artifacts.is_empty() {
        return Value::Null;
    }
    serde_json::to_value(artifacts).unwrap_or(Value::Null)
}

/// Parse a persisted/absent `artifacts` value back. Absent, `null`, or malformed → an
/// empty list, which is exactly how a job file written before this field existed loads.
pub fn artifacts_from_value(v: Option<&Value>) -> Vec<Artifact> {
    v.filter(|a| !a.is_null())
        .and_then(|a| serde_json::from_value::<Vec<Artifact>>(a.clone()).ok())
        .unwrap_or_default()
}

// ---- The per-turn caps, resolved -------------------------------------------

/// The three per-turn budgets, resolved once from config so the sweep and the prompt
/// fragment can never quote different numbers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ArtifactCaps {
    pub max_files: usize,
    pub max_file_bytes: u64,
    pub max_total_bytes: u64,
}

impl ArtifactCaps {
    pub fn from_cfg(cfg: &Config) -> Self {
        ArtifactCaps {
            max_files: cfg.max_artifacts,
            max_file_bytes: cfg.max_artifact_bytes,
            max_total_bytes: cfg.max_artifacts_total_bytes,
        }
    }
}

/// What one sweep produced: the artifacts to put on the reply, and the notes the USER
/// must see.
///
/// Rejections are never silent. A dropped or capped file produces a line appended to the
/// reply, the same way the PDF page cap already appends one — a dropped artifact the user
/// is not told about is a wrong answer they cannot detect.
#[derive(Debug, Default)]
pub struct SweepOutcome {
    pub artifacts: Vec<Artifact>,
    pub notes: Vec<String>,
}

impl SweepOutcome {
    /// The notes as the sentence(s) appended to the delivered reply, or `None` when the
    /// sweep had nothing to report.
    pub fn note_suffix(&self) -> Option<String> {
        if self.notes.is_empty() {
            return None;
        }
        Some(format!("\n\n({})", self.notes.join(". ")))
    }
}

// ---- The store -------------------------------------------------------------

/// One stored artifact's metadata, as the index file holds it.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ArtifactRecord {
    pub id: String,
    pub job_id: String,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub conversation_id: Option<String>,
    pub filename: String,
    pub mime: String,
    pub ext: String,
    pub bytes: u64,
    pub sha256: String,
    pub created_ms: u64,
    /// SHA-256 of the DELIVERED assistant text this artifact was produced with, trimmed
    /// and taken BEFORE the model badge is appended.
    ///
    /// This is the hydration binding, and it exists because hydration has no job id to
    /// bind on: a hydrated turn is reconstructed from the harness's own transcript,
    /// which knows nothing about this bridge's jobs. What it does have is the invariant
    /// `hydrate_conversation_in` already documents and the app already depends on — the
    /// assistant text hydration returns IS the text delivery produced — so that text is
    /// the key. Absent on a record written before the field, and on a failed turn.
    #[serde(default)]
    pub turn_text_sha256: Option<String>,
}

impl ArtifactRecord {
    /// The wire element for this record, under a possibly-different display filename
    /// (a deduplicated second copy keeps its own name — see the sweep).
    pub fn to_artifact(&self, filename: &str) -> Artifact {
        Artifact {
            id: self.id.clone(),
            filename: filename.to_string(),
            mime: self.mime.clone(),
            bytes: self.bytes,
            sha256: self.sha256.clone(),
        }
    }
}

/// Why a fetch for an artifact id found nothing. The app renders the two differently —
/// "this was never here" is a bug in the client, "this expired" is the system working —
/// so the 404 body distinguishes them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArtifactMiss {
    /// No record, and no tombstone: this id was never stored (or its tombstone has itself
    /// aged out, which is indistinguishable and is reported as unknown).
    Unknown,
    /// A tombstone says this id was stored and has since been evicted by age, by the
    /// high-water mark, or by its conversation being deleted.
    Expired,
}

/// The bounded, on-disk artifact store: bytes under
/// `<state_dir>/artifacts/<job_id>/<artifact_id>.<ext>`, metadata in
/// `<state_dir>/artifacts/index.json`.
///
/// The index is loaded once at startup and held in memory behind one `Mutex`, persisted
/// atomically (temp + rename, mode 0600) on every mutation — the same discipline
/// `FlagStore` and `TitleStore` use, and best-effort in the same way: a persist failure
/// is logged, never fatal.
pub struct ArtifactStore {
    inner: Mutex<ArtifactIndex>,
    /// `<state_dir>/artifacts`. `None` disables the store entirely, which is what makes
    /// [`artifact_route`] return [`ArtifactRoute::None`] on a bridge with no state dir.
    root: Option<PathBuf>,
    ttl_ms: u64,
    max_bytes: u64,
}

#[derive(Default)]
struct ArtifactIndex {
    /// id → record.
    records: HashMap<String, ArtifactRecord>,
    /// id → the unix-millis it was evicted. What separates "expired" from "never
    /// existed" on a fetch. Pruned on the same TTL window as the records themselves, so
    /// it cannot grow without bound.
    tombstones: HashMap<String, u64>,
}

/// The store's current size, for the observability line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ArtifactUsage {
    pub files: usize,
    pub bytes: u64,
}

/// What one server-side eviction pass removed. Counts and bytes only — never a filename.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EvictionReport {
    pub aged_out: usize,
    pub over_high_water: usize,
    pub bytes: u64,
}

impl EvictionReport {
    pub fn removed(&self) -> usize {
        self.aged_out + self.over_high_water
    }
}

impl ArtifactStore {
    /// Build the store from config, loading any index left by a previous run. With no
    /// state dir the store is INERT: [`Self::is_available`] is false, every sweep is a
    /// no-op and no route ever hands out an id.
    pub fn from_cfg(cfg: &Config) -> Self {
        let root = cfg.artifacts_dir();
        let index = root
            .as_deref()
            .map(|r| load_index(&r.join("index.json")))
            .unwrap_or_default();
        ArtifactStore {
            inner: Mutex::new(index),
            root,
            ttl_ms: cfg.artifact_ttl_days.saturating_mul(24 * 60 * 60 * 1000),
            max_bytes: cfg.artifact_store_max_bytes,
        }
    }

    /// An in-memory-only store rooted at an explicit directory. Tests only — production
    /// always goes through [`Self::from_cfg`].
    #[cfg(test)]
    pub fn for_test(root: PathBuf, ttl_ms: u64, max_bytes: u64) -> Self {
        ArtifactStore {
            inner: Mutex::new(ArtifactIndex::default()),
            root: Some(root),
            ttl_ms,
            max_bytes,
        }
    }

    pub fn is_available(&self) -> bool {
        self.root.is_some()
    }

    fn index_path(&self) -> Option<PathBuf> {
        self.root.as_ref().map(|r| r.join("index.json"))
    }

    /// Current file count and total bytes. Emitted at startup and after every eviction
    /// pass so the growth is observable BEFORE it is a problem rather than after.
    pub fn usage(&self) -> ArtifactUsage {
        let g = self.inner.lock_ok();
        ArtifactUsage {
            files: g.records.len(),
            bytes: g.records.values().map(|r| r.bytes).sum(),
        }
    }

    /// Look one artifact up for the fetch route: the record and the bytes' path.
    pub fn get(&self, id: &str) -> Result<(ArtifactRecord, PathBuf), ArtifactMiss> {
        let g = self.inner.lock_ok();
        match g.records.get(id) {
            Some(r) => {
                let root = self.root.as_ref().ok_or(ArtifactMiss::Unknown)?;
                let path = root.join(&r.job_id).join(format!("{}.{}", r.id, r.ext));
                Ok((r.clone(), path))
            }
            None if g.tombstones.contains_key(id) => Err(ArtifactMiss::Expired),
            None => Err(ArtifactMiss::Unknown),
        }
    }

    /// Every artifact belonging to a conversation, oldest first. Read by the hydration
    /// path to re-attach an older turn's artifacts to its hydrated twin.
    pub fn for_conversation(&self, conversation_id: &str) -> Vec<ArtifactRecord> {
        let g = self.inner.lock_ok();
        let mut out: Vec<ArtifactRecord> = g
            .records
            .values()
            .filter(|r| r.conversation_id.as_deref() == Some(conversation_id))
            .cloned()
            .collect();
        out.sort_by(|a, b| (a.created_ms, &a.id).cmp(&(b.created_ms, &b.id)));
        out
    }

    /// THE SWEEP. Move everything a turn staged into the store, in a stable order,
    /// enforcing the per-turn caps and the type allowlist, and report what was dropped.
    ///
    /// Runs on the normal completion path — success, error and timeout all reach it —
    /// and is a no-op for a store that is not available. The staging directory itself is
    /// removed by [`StagingDir`]'s `Drop` whatever happened here, so a sweep that fails
    /// halfway still leaves nothing behind.
    ///
    /// # The cap rule
    ///
    /// Files are processed in a stable (sorted-by-name) order and THE FIRST ONE TO
    /// BREACH A CAP STOPS THE SWEEP. Everything already accepted is kept, and the user is
    /// told what was dropped and why. A rejected TYPE is not a breach: it is skipped, it
    /// is noted, and the sweep continues — one unsupported file must not silently discard
    /// the three good ones behind it.
    pub fn sweep(&self, ctx: &SweepContext<'_>, staging: &Path) -> SweepOutcome {
        let mut out = SweepOutcome::default();
        if !self.is_available() {
            return out;
        }
        let files = match list_regular_files(staging) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("jesse-bridge: artifact sweep: could not read staging dir: {e}");
                return out;
            }
        };
        if files.is_empty() {
            return out;
        }
        let caps = ctx.caps;
        let mut total: u64 = 0;
        // hash → the id already stored for it THIS TURN. Deduplication: an identical file
        // produced twice is stored once and referenced twice.
        let mut by_hash: HashMap<String, ArtifactRecord> = HashMap::new();
        let mut fresh: Vec<ArtifactRecord> = Vec::new();
        for (i, path) in files.iter().enumerate() {
            let display = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("file")
                .to_string();
            if out.artifacts.len() >= caps.max_files {
                out.notes.push(format!(
                    "{} more file(s) were written but not returned: a turn returns at most {}",
                    files.len() - i,
                    caps.max_files
                ));
                break;
            }
            let len = match std::fs::metadata(path) {
                Ok(m) => m.len(),
                Err(e) => {
                    out.notes.push(format!(
                        "{} could not be returned: it disappeared before it could be read ({e})",
                        sanitize_note(&display)
                    ));
                    continue;
                }
            };
            if len > caps.max_file_bytes {
                out.notes.push(format!(
                    "{} was not returned: it is {} MB and the per-file limit is {} MB. \
                     Nothing after it was returned either",
                    sanitize_note(&display),
                    len / (1024 * 1024),
                    caps.max_file_bytes / (1024 * 1024),
                ));
                break;
            }
            if total + len > caps.max_total_bytes {
                out.notes.push(format!(
                    "{} was not returned: it would take this turn past the {} MB total. \
                     Nothing after it was returned either",
                    sanitize_note(&display),
                    caps.max_total_bytes / (1024 * 1024),
                ));
                break;
            }
            let bytes = match std::fs::read(path) {
                Ok(b) => b,
                Err(e) => {
                    out.notes.push(format!(
                        "{} could not be returned: it could not be read ({e})",
                        sanitize_note(&display)
                    ));
                    continue;
                }
            };
            let Some((mime, ext)) = sniff_artifact(&bytes, &display) else {
                out.notes.push(format!(
                    "{} was not returned: the channel does not carry that kind of file",
                    sanitize_note(&display)
                ));
                continue;
            };
            let hash = sha256_hex(&bytes);
            total += len;
            if let Some(existing) = by_hash.get(&hash) {
                // Identical content, already stored under `existing.id`. Reference it
                // again under this file's own display name rather than storing the bytes
                // twice.
                out.artifacts.push(existing.to_artifact(&display));
                continue;
            }
            let id = random_hex();
            let record = ArtifactRecord {
                id: id.clone(),
                job_id: ctx.job_id.to_string(),
                session_id: ctx.session_id.map(str::to_string),
                conversation_id: Some(ctx.conversation_id.to_string()),
                filename: display.clone(),
                mime: mime.to_string(),
                ext: ext.to_string(),
                bytes: len,
                sha256: hash.clone(),
                created_ms: system_time_to_ms(SystemTime::now()),
                turn_text_sha256: ctx.turn_text_sha256.clone(),
            };
            if let Err(e) = self.store_bytes(&record, &bytes) {
                out.notes.push(format!(
                    "{} could not be returned: the bridge could not store it ({e})",
                    sanitize_note(&display)
                ));
                total -= len;
                continue;
            }
            out.artifacts.push(record.to_artifact(&display));
            by_hash.insert(hash, record.clone());
            fresh.push(record);
        }
        if !fresh.is_empty() {
            let mut g = self.inner.lock_ok();
            for r in fresh {
                g.records.insert(r.id.clone(), r);
            }
            let snapshot = g.clone_for_persist();
            drop(g);
            self.persist(&snapshot);
        }
        out
    }

    /// Write one artifact's bytes to `<root>/<job_id>/<id>.<ext>`, mode 0600 — which is
    /// also where the execute bit is cleared, since the file is created fresh rather than
    /// moved with its staged permissions.
    fn store_bytes(&self, r: &ArtifactRecord, bytes: &[u8]) -> std::io::Result<()> {
        let Some(root) = self.root.as_ref() else {
            return Err(std::io::Error::other("no artifact store"));
        };
        let dir = root.join(&r.job_id);
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)?;
        let path = dir.join(format!("{}.{}", r.id, r.ext));
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)?;
        f.write_all(bytes)
    }

    /// Delete every artifact belonging to a conversation. The cascade: an artifact that
    /// outlives the conversation it belonged to is unreachable and pure cost.
    ///
    /// Returns how many were removed.
    pub fn forget_conversation(&self, conversation_id: &str) -> usize {
        let now_ms = system_time_to_ms(SystemTime::now());
        let mut g = self.inner.lock_ok();
        let doomed: Vec<ArtifactRecord> = g
            .records
            .values()
            .filter(|r| r.conversation_id.as_deref() == Some(conversation_id))
            .cloned()
            .collect();
        for r in &doomed {
            g.records.remove(&r.id);
            g.tombstones.insert(r.id.clone(), now_ms);
        }
        let snapshot = g.clone_for_persist();
        drop(g);
        for r in &doomed {
            self.unlink(r);
        }
        if !doomed.is_empty() {
            self.persist(&snapshot);
        }
        doomed.len()
    }

    /// The server-side sweep: evict by AGE first, then oldest-first until the total is
    /// back under the high-water mark. Runs at startup and on `EVICTION_INTERVAL`,
    /// reusing the job store's existing scheduling rather than inventing a second timer.
    pub fn evict(&self) -> EvictionReport {
        let now_ms = system_time_to_ms(SystemTime::now());
        let mut report = EvictionReport::default();
        let mut doomed: Vec<ArtifactRecord> = Vec::new();
        {
            let mut g = self.inner.lock_ok();
            // 1. Age.
            let aged: Vec<ArtifactRecord> = g
                .records
                .values()
                .filter(|r| now_ms.saturating_sub(r.created_ms) > self.ttl_ms)
                .cloned()
                .collect();
            for r in &aged {
                g.records.remove(&r.id);
                g.tombstones.insert(r.id.clone(), now_ms);
                report.aged_out += 1;
                report.bytes += r.bytes;
            }
            doomed.extend(aged);
            // 2. The high-water mark, oldest first.
            let mut total: u64 = g.records.values().map(|r| r.bytes).sum();
            if total > self.max_bytes {
                let mut by_age: Vec<ArtifactRecord> = g.records.values().cloned().collect();
                by_age.sort_by(|a, b| (a.created_ms, &a.id).cmp(&(b.created_ms, &b.id)));
                for r in by_age {
                    if total <= self.max_bytes {
                        break;
                    }
                    g.records.remove(&r.id);
                    g.tombstones.insert(r.id.clone(), now_ms);
                    total = total.saturating_sub(r.bytes);
                    report.over_high_water += 1;
                    report.bytes += r.bytes;
                    doomed.push(r);
                }
            }
            // 3. Tombstones age out on the same window, so the "expired" answer is
            //    bounded memory rather than a set that grows for the life of the deploy.
            g.tombstones
                .retain(|_, at| now_ms.saturating_sub(*at) <= self.ttl_ms);
            let snapshot = g.clone_for_persist();
            drop(g);
            if report.removed() > 0 {
                self.persist(&snapshot);
            }
        }
        for r in &doomed {
            self.unlink(r);
        }
        if report.removed() > 0 {
            let usage = self.usage();
            eprintln!(
                "jesse-bridge: artifacts evicted {} ({} aged out, {} over the {} MB mark), \
                 {} MB freed; store now {} file(s), {} MB",
                report.removed(),
                report.aged_out,
                report.over_high_water,
                self.max_bytes / (1024 * 1024),
                report.bytes / (1024 * 1024),
                usage.files,
                usage.bytes / (1024 * 1024),
            );
        }
        report
    }

    /// Remove one artifact's bytes, and its job directory when that empties it.
    fn unlink(&self, r: &ArtifactRecord) {
        let Some(root) = self.root.as_ref() else {
            return;
        };
        let dir = root.join(&r.job_id);
        let _ = std::fs::remove_file(dir.join(format!("{}.{}", r.id, r.ext)));
        let _ = std::fs::remove_dir(&dir); // only when empty
    }

    fn persist(&self, snapshot: &ArtifactIndex) {
        let Some(path) = self.index_path() else {
            return;
        };
        persist_index(&path, snapshot);
    }
}

impl ArtifactIndex {
    fn clone_for_persist(&self) -> ArtifactIndex {
        ArtifactIndex {
            records: self.records.clone(),
            tombstones: self.tombstones.clone(),
        }
    }
}

/// Everything the sweep needs to know about the turn it is sweeping for.
pub struct SweepContext<'a> {
    pub job_id: &'a str,
    pub conversation_id: &'a str,
    pub session_id: Option<&'a str>,
    /// SHA-256 of the trimmed, pre-badge delivered text — the hydration binding. `None`
    /// on a turn that delivered no text (a failure), whose artifacts are then reachable
    /// by job id but never re-attached to a hydrated turn.
    pub turn_text_sha256: Option<String>,
    pub caps: ArtifactCaps,
}

/// The regular files directly inside `dir`, sorted by name so the cap rule is
/// deterministic. Directories, symlinks and anything else are skipped: a symlink is
/// exactly how a staged "file" would point at something outside the staging directory.
fn list_regular_files(dir: &Path) -> std::io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        // `symlink_metadata`, NOT `metadata`: the latter follows the link, so a symlink
        // to `/etc/passwd` would report as a regular file and be swept.
        let Ok(md) = entry.path().symlink_metadata() else {
            continue;
        };
        if md.is_file() {
            out.push(entry.path());
        }
    }
    out.sort();
    Ok(out)
}

/// A model-controlled filename on its way into a user-visible note. Newlines and control
/// characters are stripped and the length is bounded, so a crafted name cannot forge
/// extra lines of reply text.
fn sanitize_note(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .filter(|c| !c.is_control())
        .take(80)
        .collect::<String>();
    if cleaned.trim().is_empty() {
        "a file".to_string()
    } else {
        format!("`{}`", cleaned.replace('`', "'"))
    }
}

/// Whether an id is safe to turn into a path component: non-empty lowercase hex within a
/// sane length. THE TRAVERSAL GUARD — `..`, a slash, a NUL and every other escape are all
/// non-hex, so this one check is what keeps the fetch route inside the artifacts
/// directory.
pub fn is_valid_artifact_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id.bytes().all(|b| b.is_ascii_hexdigit())
        && id.bytes().all(|b| !b.is_ascii_uppercase())
}

// ---- Index persistence -----------------------------------------------------

/// Load the index, tolerating everything: an absent, unreadable or garbage file loads as
/// empty, and a single unparseable record is skipped rather than failing the whole load.
fn load_index(path: &Path) -> ArtifactIndex {
    let Ok(text) = std::fs::read_to_string(path) else {
        return ArtifactIndex::default();
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return ArtifactIndex::default();
    };
    let mut records = HashMap::new();
    if let Some(arr) = value.get("artifacts").and_then(|a| a.as_array()) {
        for v in arr {
            if let Ok(r) = serde_json::from_value::<ArtifactRecord>(v.clone()) {
                records.insert(r.id.clone(), r);
            }
        }
    }
    let mut tombstones = HashMap::new();
    if let Some(obj) = value.get("tombstones").and_then(|t| t.as_object()) {
        for (id, at) in obj {
            if let Some(ms) = at.as_u64() {
                tombstones.insert(id.clone(), ms);
            }
        }
    }
    ArtifactIndex {
        records,
        tombstones,
    }
}

/// Persist the index atomically (temp + rename), mode 0600 — `FlagStore`'s discipline
/// exactly. Best-effort: a failure is logged, never fatal.
fn persist_index(path: &Path, index: &ArtifactIndex) {
    let mut records: Vec<&ArtifactRecord> = index.records.values().collect();
    records.sort_by(|a, b| (a.created_ms, &a.id).cmp(&(b.created_ms, &b.id)));
    let value = json!({ "v": 1, "artifacts": records, "tombstones": index.tombstones });
    let tmp = path.with_extension("json.tmp");
    let write = || -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)?;
        }
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(value.to_string().as_bytes())?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    if let Err(e) = write() {
        eprintln!("warning: could not persist the artifact index: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

// ---- Content-Disposition ---------------------------------------------------

/// The `Content-Disposition` value for a fetch, naming the model's display filename.
///
/// Always `attachment`, never `inline`: an SVG or an HTML page served inline is a script
/// execution surface, and this route serves both. The name is emitted twice per RFC 6266
/// — an ASCII-sanitized `filename=` for anything old, and a percent-encoded UTF-8
/// `filename*=` for everything else — and BOTH forms are stripped of the CR, LF and quote
/// characters a crafted name would use to forge a header.
pub fn content_disposition(filename: &str) -> String {
    let ascii: String = filename
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | ' ') {
                c
            } else {
                '_'
            }
        })
        .take(120)
        .collect();
    let ascii = if ascii.trim().is_empty() {
        "artifact".to_string()
    } else {
        ascii
    };
    let encoded: String = filename
        .bytes()
        .take(240)
        .map(|b| {
            if b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b'~') {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect();
    format!("attachment; filename=\"{ascii}\"; filename*=UTF-8''{encoded}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;
    use std::os::unix::fs::PermissionsExt;

    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
    const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F'];
    const PDF: &[u8] = b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n";

    fn temp_dir(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("jesse-artifact-{tag}-{}", random_hex()));
        std::fs::create_dir_all(&p).expect("temp dir");
        p
    }

    fn caps() -> ArtifactCaps {
        ArtifactCaps {
            max_files: DEFAULT_MAX_ARTIFACTS,
            max_file_bytes: DEFAULT_MAX_ARTIFACT_BYTES,
            max_total_bytes: DEFAULT_MAX_ARTIFACTS_TOTAL_BYTES,
        }
    }

    fn ctx<'a>(job: &'a str, conv: &'a str, caps: ArtifactCaps) -> SweepContext<'a> {
        SweepContext {
            job_id: job,
            conversation_id: conv,
            session_id: None,
            turn_text_sha256: None,
            caps,
        }
    }

    fn write(dir: &Path, name: &str, bytes: &[u8]) {
        std::fs::write(dir.join(name), bytes).expect("staged file");
    }

    // ---- The route decision, at every capability level ----------------------

    #[test]
    fn route_is_staged_only_at_write_with_a_store() {
        assert_eq!(
            artifact_route(Capability::Write, true),
            ArtifactRoute::Staged
        );
        // A turn that cannot write gets nothing: promising it a channel would be a lie.
        assert_eq!(artifact_route(Capability::Read, true), ArtifactRoute::None);
        assert_eq!(artifact_route(Capability::Basic, true), ArtifactRoute::None);
        // No store → nowhere to sweep to, so no staging directory either.
        assert_eq!(
            artifact_route(Capability::Write, false),
            ArtifactRoute::None
        );
        assert_eq!(artifact_route(Capability::Read, false), ArtifactRoute::None);
        assert_eq!(
            artifact_route(Capability::Basic, false),
            ArtifactRoute::None
        );
    }

    // ---- The sniffer --------------------------------------------------------

    #[test]
    fn sniff_accepts_the_allowlisted_types() {
        assert_eq!(sniff_artifact(PNG, "chart.png"), Some(("image/png", "png")));
        assert_eq!(sniff_artifact(JPEG, "p.jpg"), Some(("image/jpeg", "jpg")));
        assert_eq!(
            sniff_artifact(PDF, "report.pdf"),
            Some(("application/pdf", "pdf"))
        );
        assert_eq!(
            sniff_artifact(b"<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>", "a.svg"),
            Some(("image/svg+xml", "svg"))
        );
        assert_eq!(
            sniff_artifact(b"<?xml version=\"1.0\"?><svg></svg>", "a.svg"),
            Some(("image/svg+xml", "svg"))
        );
        assert_eq!(
            sniff_artifact(b"<!DOCTYPE html><html><body>hi</body></html>", "p.html"),
            Some(("text/html", "html"))
        );
        assert_eq!(
            sniff_artifact(b"{\"a\": 1}", "d.json"),
            Some(("application/json", "json"))
        );
        assert_eq!(
            sniff_artifact(b"a,b,c\n1,2,3\n", "t.csv"),
            Some(("text/csv", "csv"))
        );
        assert_eq!(
            sniff_artifact(b"# Title\n\nbody\n", "n.md"),
            Some(("text/markdown", "md"))
        );
        assert_eq!(
            sniff_artifact(b"just some prose\n", "n.txt"),
            Some(("text/plain", "txt"))
        );
    }

    #[test]
    fn sniff_believes_the_bytes_when_the_extension_lies() {
        // A PNG named `.txt` is still a PNG…
        assert_eq!(
            sniff_artifact(PNG, "definitely-a-text-file.txt"),
            Some(("image/png", "png"))
        );
        // …and a text file named `.png` is still text, labelled from its (lying)
        // extension only among the three text MIMEs — never promoted to image/png.
        assert_eq!(
            sniff_artifact(b"not a png at all\n", "liar.png"),
            Some(("text/plain", "txt"))
        );
        // A binary blob with a `.json` name is rejected outright, not guessed at.
        assert_eq!(sniff_artifact(&[0x00, 0x01, 0x02, 0x03], "x.json"), None);
        // Malformed JSON is text, not `application/json` — the sniff PARSES.
        assert_eq!(
            sniff_artifact(b"{ not json at all", "x.json"),
            Some(("text/plain", "txt"))
        );
    }

    #[test]
    fn sniff_rejects_unknown_and_executable_content() {
        // A ZIP/Office doc is deliberately NOT on the allowlist.
        assert_eq!(sniff_artifact(b"PK\x03\x04\x00\x00", "x.docx"), None);
        assert_eq!(sniff_artifact(b"", "empty.txt"), None);
        // GIF and WEBP are accepted INBOUND but are not on this channel's allowlist.
        assert_eq!(sniff_artifact(b"GIF89a\x01\x00\x01\x00", "a.gif"), None);
        // Executables, every shape.
        assert!(is_executable(&[0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0])); // Mach-O 64 LE
        assert!(is_executable(&[0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0])); // fat
        assert!(is_executable(b"\x7FELF\x02\x01\x01\x00"));
        assert!(is_executable(b"#!/bin/sh\necho hi\n"));
        assert!(!is_executable(PNG));
        assert_eq!(sniff_artifact(b"#!/bin/sh\nrm -rf /\n", "helper.txt"), None);
        assert_eq!(
            sniff_artifact(&[0xCF, 0xFA, 0xED, 0xFE, 0, 0], "a.bin"),
            None
        );
    }

    // ---- The traversal guard ------------------------------------------------

    #[test]
    fn artifact_ids_are_hex_and_nothing_else() {
        assert!(is_valid_artifact_id("0123456789abcdef"));
        assert!(is_valid_artifact_id(&random_hex()));
        assert!(!is_valid_artifact_id(""));
        assert!(!is_valid_artifact_id(".."));
        assert!(!is_valid_artifact_id("../../etc/passwd"));
        assert!(!is_valid_artifact_id("abc/def"));
        assert!(!is_valid_artifact_id("abc.def"));
        assert!(!is_valid_artifact_id("ABCDEF")); // uppercase never minted
        assert!(!is_valid_artifact_id("abc\0"));
        assert!(!is_valid_artifact_id(&"a".repeat(65)));
    }

    // ---- The sweep ----------------------------------------------------------

    #[test]
    fn sweep_stores_hashes_and_returns_two_files() {
        let root = temp_dir("store");
        let staging = temp_dir("staging");
        write(&staging, "01-chart.png", PNG);
        write(&staging, "02-report.pdf", PDF);
        let store = ArtifactStore::for_test(root.clone(), 60_000, 1 << 30);
        let out = store.sweep(&ctx("job1", "conv1", caps()), &staging);
        assert_eq!(out.artifacts.len(), 2, "both files returned: {out:?}");
        assert!(out.notes.is_empty(), "nothing dropped: {:?}", out.notes);
        assert_eq!(out.artifacts[0].mime, "image/png");
        assert_eq!(out.artifacts[0].filename, "01-chart.png");
        assert_eq!(out.artifacts[1].mime, "application/pdf");
        assert_eq!(out.artifacts[0].sha256, sha256_hex(PNG));
        // The bytes are in the store under `<job>/<id>.<ext>`, never under the model's
        // own filename.
        let stored = root
            .join("job1")
            .join(format!("{}.png", out.artifacts[0].id));
        assert_eq!(std::fs::read(&stored).expect("stored bytes"), PNG);
        assert_eq!(store.usage().files, 2);
        assert_eq!(store.usage().bytes, (PNG.len() + PDF.len()) as u64);
        // Fetchable by id, with a path inside the store.
        let (rec, path) = store.get(&out.artifacts[0].id).expect("found");
        assert_eq!(rec.mime, "image/png");
        assert_eq!(path, stored);
    }

    #[test]
    fn sweep_deduplicates_identical_content() {
        let root = temp_dir("dedup");
        let staging = temp_dir("dedup-staging");
        write(&staging, "a.png", PNG);
        write(&staging, "b.png", PNG);
        let store = ArtifactStore::for_test(root, 60_000, 1 << 30);
        let out = store.sweep(&ctx("job1", "conv1", caps()), &staging);
        assert_eq!(out.artifacts.len(), 2, "referenced twice");
        assert_eq!(
            out.artifacts[0].id, out.artifacts[1].id,
            "stored once: both wire entries name the same id"
        );
        assert_eq!(out.artifacts[0].filename, "a.png");
        assert_eq!(out.artifacts[1].filename, "b.png");
        assert_eq!(store.usage().files, 1, "one record, one blob on disk");
    }

    #[test]
    fn sweep_notes_a_rejected_type_and_keeps_going() {
        let root = temp_dir("reject");
        let staging = temp_dir("reject-staging");
        write(&staging, "01-bad.zip", b"PK\x03\x04\x00\x00\x00\x00");
        write(&staging, "02-good.png", PNG);
        let store = ArtifactStore::for_test(root, 60_000, 1 << 30);
        let out = store.sweep(&ctx("job1", "conv1", caps()), &staging);
        assert_eq!(out.artifacts.len(), 1, "the good file still comes back");
        assert_eq!(out.notes.len(), 1, "and the bad one is NOT silent");
        assert!(
            out.notes[0].contains("01-bad.zip"),
            "the note names the file: {:?}",
            out.notes
        );
        assert!(out.note_suffix().is_some());
    }

    #[test]
    fn sweep_stops_at_the_file_count_cap_and_says_so() {
        let root = temp_dir("count");
        let staging = temp_dir("count-staging");
        for i in 0..5 {
            // Distinct content, or dedup would collapse them.
            let mut bytes = PNG.to_vec();
            bytes.push(i);
            write(&staging, &format!("{i:02}.png"), &bytes);
        }
        let store = ArtifactStore::for_test(root, 60_000, 1 << 30);
        let mut c = caps();
        c.max_files = 3;
        let out = store.sweep(&ctx("job1", "conv1", c), &staging);
        assert_eq!(out.artifacts.len(), 3, "the accepted three are KEPT");
        assert_eq!(out.notes.len(), 1);
        assert!(
            out.notes[0].contains("2 more file(s)") && out.notes[0].contains("at most 3"),
            "{:?}",
            out.notes
        );
    }

    #[test]
    fn sweep_stops_at_the_per_file_cap_and_says_so() {
        let root = temp_dir("perfile");
        let staging = temp_dir("perfile-staging");
        write(&staging, "01-small.png", PNG);
        let mut big = PDF.to_vec();
        big.resize(4 * 1024 * 1024, b' ');
        write(&staging, "02-big.pdf", &big);
        write(&staging, "03-after.png", &[PNG, &[9u8]].concat());
        let store = ArtifactStore::for_test(root, 60_000, 1 << 30);
        let mut c = caps();
        c.max_file_bytes = 2 * 1024 * 1024;
        let out = store.sweep(&ctx("job1", "conv1", c), &staging);
        assert_eq!(
            out.artifacts.len(),
            1,
            "partial acceptance: the first is kept"
        );
        assert!(
            out.notes[0].contains("02-big.pdf") && out.notes[0].contains("per-file limit"),
            "{:?}",
            out.notes
        );
        assert!(
            out.notes[0].contains("Nothing after it"),
            "the user is told the sweep STOPPED: {:?}",
            out.notes
        );
    }

    #[test]
    fn sweep_stops_at_the_turn_total_cap_and_says_so() {
        let root = temp_dir("total");
        let staging = temp_dir("total-staging");
        for i in 0..3u8 {
            let mut bytes = PNG.to_vec();
            bytes.resize(600 * 1024, i); // distinct content, ~0.6 MB each
            write(&staging, &format!("{i:02}.png"), &bytes);
        }
        let store = ArtifactStore::for_test(root, 60_000, 1 << 30);
        let mut c = caps();
        c.max_total_bytes = 1024 * 1024; // one fits, the second breaches
        let out = store.sweep(&ctx("job1", "conv1", c), &staging);
        assert_eq!(out.artifacts.len(), 1);
        assert!(
            out.notes[0].contains("total"),
            "the total cap is named: {:?}",
            out.notes
        );
    }

    #[test]
    fn sweep_skips_a_symlink_rather_than_following_it() {
        let root = temp_dir("link");
        let staging = temp_dir("link-staging");
        let outside = temp_dir("link-outside").join("secret.png");
        std::fs::write(&outside, PNG).expect("outside file");
        std::os::unix::fs::symlink(&outside, staging.join("sneaky.png")).expect("symlink");
        let store = ArtifactStore::for_test(root, 60_000, 1 << 30);
        let out = store.sweep(&ctx("job1", "conv1", caps()), &staging);
        assert!(
            out.artifacts.is_empty(),
            "a symlink out of the staging dir is not an artifact: {out:?}"
        );
    }

    #[test]
    fn sweep_is_a_no_op_without_a_store() {
        let staging = temp_dir("nostore-staging");
        write(&staging, "a.png", PNG);
        let store = ArtifactStore {
            inner: Mutex::new(ArtifactIndex::default()),
            root: None,
            ttl_ms: 60_000,
            max_bytes: 1 << 30,
        };
        assert!(!store.is_available());
        let out = store.sweep(&ctx("job1", "conv1", caps()), &staging);
        assert!(out.artifacts.is_empty() && out.notes.is_empty());
    }

    // ---- Server eviction ----------------------------------------------------

    #[test]
    fn eviction_removes_aged_out_artifacts_and_tombstones_them() {
        let root = temp_dir("age");
        let staging = temp_dir("age-staging");
        write(&staging, "a.png", PNG);
        let store = ArtifactStore::for_test(root, 0, 1 << 30); // TTL 0 → everything is old
        let out = store.sweep(&ctx("job1", "conv1", caps()), &staging);
        let id = out.artifacts[0].id.clone();
        // A TTL of 0 with a `>` comparison needs one millisecond of age to bite.
        std::thread::sleep(Duration::from_millis(5));
        let report = store.evict();
        assert_eq!(report.aged_out, 1);
        assert_eq!(report.bytes, PNG.len() as u64);
        assert_eq!(store.usage().files, 0);
        // …and the fetch now says EXPIRED, not unknown — the app renders those
        // differently.
        assert_eq!(store.get(&id), Err(ArtifactMiss::Expired));
        assert_eq!(store.get(&random_hex()), Err(ArtifactMiss::Unknown));
    }

    #[test]
    fn eviction_removes_oldest_first_over_the_high_water_mark() {
        let root = temp_dir("water");
        let store = ArtifactStore::for_test(root.clone(), 86_400_000, 1500);
        let mut ids = Vec::new();
        for i in 0..3u8 {
            let staging = temp_dir(&format!("water-staging-{i}"));
            let mut bytes = PNG.to_vec();
            bytes.resize(600, i);
            write(&staging, "a.png", &bytes);
            let out = store.sweep(&ctx(&format!("job{i}"), "conv1", caps()), &staging);
            ids.push(out.artifacts[0].id.clone());
            // Distinct creation millis, so "oldest first" is a real order.
            std::thread::sleep(Duration::from_millis(3));
        }
        assert_eq!(store.usage().bytes, 1800);
        let report = store.evict();
        assert_eq!(report.aged_out, 0, "nothing is old enough");
        assert_eq!(
            report.over_high_water, 1,
            "exactly enough to get under 1500"
        );
        assert!(store.usage().bytes <= 1500);
        assert_eq!(
            store.get(&ids[0]),
            Err(ArtifactMiss::Expired),
            "the OLDEST went first"
        );
        assert!(store.get(&ids[2]).is_ok(), "the newest survives");
    }

    #[test]
    fn deleting_a_conversation_cascades_to_its_artifacts() {
        let root = temp_dir("cascade");
        let store = ArtifactStore::for_test(root.clone(), 86_400_000, 1 << 30);
        let s1 = temp_dir("cascade-1");
        write(&s1, "a.png", PNG);
        let keep = store.sweep(&ctx("job1", "conv-KEEP", caps()), &s1);
        let s2 = temp_dir("cascade-2");
        write(&s2, "b.pdf", PDF);
        let doomed = store.sweep(&ctx("job2", "conv-GONE", caps()), &s2);
        assert_eq!(store.usage().files, 2);
        assert_eq!(store.forget_conversation("conv-GONE"), 1);
        assert_eq!(store.usage().files, 1);
        assert_eq!(
            store.get(&doomed.artifacts[0].id),
            Err(ArtifactMiss::Expired)
        );
        assert!(
            store.get(&keep.artifacts[0].id).is_ok(),
            "the other survives"
        );
        // And the bytes are actually gone from disk, not just from the index.
        assert!(!root
            .join("job2")
            .join(format!("{}.pdf", doomed.artifacts[0].id))
            .exists());
    }

    #[test]
    fn for_conversation_returns_only_that_conversations_artifacts_oldest_first() {
        let root = temp_dir("byconv");
        let store = ArtifactStore::for_test(root, 86_400_000, 1 << 30);
        let s1 = temp_dir("byconv-1");
        write(&s1, "a.png", PNG);
        store.sweep(&ctx("job1", "conv-A", caps()), &s1);
        std::thread::sleep(Duration::from_millis(3));
        let s2 = temp_dir("byconv-2");
        write(&s2, "b.pdf", PDF);
        store.sweep(&ctx("job2", "conv-A", caps()), &s2);
        let s3 = temp_dir("byconv-3");
        write(&s3, "c.png", &[PNG, &[7u8]].concat());
        store.sweep(&ctx("job3", "conv-B", caps()), &s3);
        let a = store.for_conversation("conv-A");
        assert_eq!(a.len(), 2);
        assert!(a[0].created_ms <= a[1].created_ms);
        assert_eq!(store.for_conversation("conv-B").len(), 1);
        assert!(store.for_conversation("conv-missing").is_empty());
    }

    // ---- Index persistence --------------------------------------------------

    #[test]
    fn the_index_round_trips_and_tolerates_a_garbage_file() {
        let dir = temp_dir("index");
        let path = dir.join("index.json");
        let mut index = ArtifactIndex::default();
        index.records.insert(
            "abc123".to_string(),
            ArtifactRecord {
                id: "abc123".into(),
                job_id: "job1".into(),
                session_id: Some("s1".into()),
                conversation_id: Some("c1".into()),
                filename: "chart.png".into(),
                mime: "image/png".into(),
                ext: "png".into(),
                bytes: 12,
                sha256: "deadbeef".into(),
                created_ms: 1_700_000_000_000,
                turn_text_sha256: Some("cafe".into()),
            },
        );
        index.tombstones.insert("gone".to_string(), 42);
        persist_index(&path, &index);
        let back = load_index(&path);
        assert_eq!(back.records.len(), 1);
        assert_eq!(back.records["abc123"].filename, "chart.png");
        assert_eq!(back.tombstones.get("gone"), Some(&42));
        std::fs::write(&path, b"not json at all").expect("garbage");
        assert!(load_index(&path).records.is_empty());
        assert!(load_index(&dir.join("nope.json")).records.is_empty());
    }

    // ---- The wire shape -----------------------------------------------------

    #[test]
    fn artifacts_to_value_is_null_when_empty_and_round_trips_otherwise() {
        assert_eq!(artifacts_to_value(&[]), Value::Null);
        assert!(artifacts_from_value(None).is_empty());
        assert!(artifacts_from_value(Some(&Value::Null)).is_empty());
        assert!(artifacts_from_value(Some(&json!("nonsense"))).is_empty());
        let a = vec![Artifact {
            id: "abcd".into(),
            filename: "chart.png".into(),
            mime: "image/png".into(),
            bytes: 42,
            sha256: "ff".into(),
        }];
        let v = artifacts_to_value(&a);
        assert_eq!(v[0]["id"], "abcd");
        assert_eq!(v[0]["filename"], "chart.png");
        assert_eq!(v[0]["bytes"], 42);
        // No bytes on the wire, ever.
        assert!(v[0].get("data").is_none() && v[0].get("data_base64").is_none());
        assert_eq!(artifacts_from_value(Some(&v)), a);
    }

    // ---- The staging directory ----------------------------------------------

    #[test]
    fn staging_dir_is_created_0700_and_removed_by_drop() {
        let work = temp_dir("work");
        let path;
        {
            let staging = StagingDir::create(&work, "job-abc").expect("created");
            path = staging.path.clone();
            assert!(path.is_dir());
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "0700, not group/world readable");
            assert_eq!(
                std::fs::read_to_string(work.join(STAGING_DIR_NAME).join(".gitignore")).unwrap(),
                "*\n"
            );
            std::fs::write(path.join("a.png"), PNG).expect("staged");
        }
        assert!(!path.exists(), "Drop removes it on every exit path");
    }

    /// THE GIT PROPERTY, asserted against a real repository rather than a comment.
    ///
    /// The working directory is a git repo whose contents are committed by a timer, so an
    /// artifact that lands in that history is there permanently and on a remote. This is
    /// the check that says the self-ignoring directory actually holds — it is the same
    /// check that was run by hand against the real vault (see the module header).
    #[test]
    fn staging_gitignore_hides_the_directory_from_git() {
        let repo = temp_dir("repo");
        let git = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&repo)
                .args(args)
                .output()
                .expect("git runs")
        };
        if git(&["init", "-q", "."]).status.code() != Some(0) {
            eprintln!("skipping: no usable git");
            return;
        }
        std::fs::write(repo.join("note.md"), b"# a note\n").expect("tracked file");
        git(&["add", "note.md"]);
        git(&[
            "-c",
            "user.email=t@example.invalid",
            "-c",
            "user.name=t",
            "commit",
            "-qm",
            "init",
        ]);
        let before = git(&["status", "--porcelain"]).stdout;
        let staging = StagingDir::create(&repo, "job-abc").expect("created");
        std::fs::write(staging.path.join("chart.png"), PNG).expect("staged");
        let after = git(&["status", "--porcelain"]).stdout;
        assert_eq!(
            String::from_utf8_lossy(&after),
            String::from_utf8_lossy(&before),
            "a staged artifact must not show as untracked content"
        );
        // And it is ignored BY OUR OWN FILE, not by luck.
        let why = git(&["check-ignore", "-v", ".jesse-artifacts/job-abc/chart.png"]);
        assert!(
            String::from_utf8_lossy(&why.stdout).contains(".jesse-artifacts/.gitignore"),
            "the matching rule must be the staging dir's own .gitignore: {:?}",
            String::from_utf8_lossy(&why.stdout)
        );
    }

    #[test]
    fn the_prompt_fragment_names_the_directory_and_the_caps() {
        let s = artifact_prompt_suffix(Path::new("/v/.jesse-artifacts/job1"), &caps());
        assert!(s.contains("/v/.jesse-artifacts/job1"));
        assert!(s.contains("10 file(s)"));
        assert!(s.contains("25 MB each"));
        assert!(s.contains("NOT returned"));
    }

    #[test]
    fn caps_come_from_config() {
        let cfg = test_config();
        let c = ArtifactCaps::from_cfg(&cfg);
        assert_eq!(c.max_files, DEFAULT_MAX_ARTIFACTS);
        assert_eq!(c.max_file_bytes, DEFAULT_MAX_ARTIFACT_BYTES);
        assert_eq!(c.max_total_bytes, DEFAULT_MAX_ARTIFACTS_TOTAL_BYTES);
    }

    // ---- Content-Disposition ------------------------------------------------

    #[test]
    fn content_disposition_cannot_be_used_to_forge_a_header() {
        let d = content_disposition("chart.png");
        assert!(d.starts_with("attachment; filename=\"chart.png\""));
        assert!(d.contains("filename*=UTF-8''chart.png"));
        // A crafted name: no raw CR/LF and no unescaped quote survives into either form.
        let nasty = content_disposition("a\r\nX-Evil: 1\"; drop=\"me\n.png");
        assert!(!nasty.contains('\r') && !nasty.contains('\n'));
        assert_eq!(nasty.matches('"').count(), 2, "exactly the one quoted pair");
        // Non-ASCII survives in the RFC 6266 form and is replaced in the legacy one.
        let uni = content_disposition("café.pdf");
        assert!(uni.contains("filename=\"caf_.pdf\""));
        assert!(uni.contains("filename*=UTF-8''caf%C3%A9.pdf"));
        // An unusable name still yields something openable.
        assert!(content_disposition("///").contains("filename=\"___\""));
        assert!(content_disposition("").contains("filename=\"artifact\""));
    }

    #[test]
    fn sha256_matches_a_known_vector() {
        // The canonical empty-string digest.
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
