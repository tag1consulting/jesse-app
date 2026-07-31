use crate::*;
use std::collections::HashSet;

// ---- The conversation registry ---------------------------------------------
//
// Before this store existed the bridge had no concept of a conversation: the list
// was a `read_dir` over the Claude Code CLI's transcript files and a conversation's
// identity was the filename stem of a jsonl the CLI created on its own schedule.
// Nothing the bridge returned at accept time named the thread, so a client that
// synced while its first turn was still in flight saw a session id it could not
// possibly know yet and adopted it as a SECOND thread. A CLI session fork on
// `--resume`, or a dropped `--resume` after a GC sweep, produced a third.
//
// A conversation is now a first-class, persisted record with a stable UUID that is
// registered BEFORE `POST /jesse` returns its 202. The client mints the UUID and the
// bridge echoes back the authoritative one, so there is never a window in which the
// server knows an identifier the client does not. A conversation owns an ORDERED list
// of Claude session ids, so a fork appends an alias instead of surfacing a new row.
//
// Same discipline as every other store in this crate: an in-memory map behind one
// mutex, the whole map snapshotted and written to a temp file, `sync_all`, atomic
// rename, mode 0600, a `{"v": 1, ...}` envelope, and best-effort persistence (a write
// failure is logged, never fatal). With no state dir the store is memory only: the
// same degradation the job / title / flag / deletion stores have. Only ids and
// timestamps are ever written; never conversation content and never a secret.

/// The namespace for the deterministic (v5) conversation id derived from a Claude
/// session id when a transcript is found on disk with no record. Fixed forever: it
/// is what makes adoption idempotent, and what makes a state dir rebuilt from the
/// transcripts alone reproduce the ids clients already hold.
pub const JESSE_CONVERSATION_NS: uuid::Uuid = uuid::uuid!("f5c1a0b2-8e3d-4a19-9b77-2c0d6e4f8a31");

/// One conversation. `session_ids` is the ordered alias list, oldest first, and its
/// LAST element is the session a resume targets. Every field is `#[serde(default)]`
/// so a record written by an older or newer bridge loads without error (the additive
/// compat property the flag store already relies on).
#[derive(serde::Serialize, serde::Deserialize, Clone, Default, PartialEq, Debug)]
pub struct ConversationRecord {
    /// Canonical lowercase hyphenated UUID.
    #[serde(default)]
    pub conversation_id: String,
    /// Claude session ids bound to this conversation, oldest first; the last element
    /// is the current one. Empty for a conversation registered at accept time whose
    /// turn has not yet returned (or failed before producing one).
    #[serde(default)]
    pub session_ids: Vec<String>,
    #[serde(default)]
    pub created_ms: u64,
    #[serde(default)]
    pub registered_ms: u64,
    /// Which client registered it (`phone` / `mac` / `watch` / `cli`). Advisory only:
    /// nothing branches on it, it exists so an operator reading the file can tell.
    #[serde(default)]
    pub origin: Option<String>,
}

impl ConversationRecord {
    /// The current (most recently bound) session id, or `None` for a conversation
    /// registered but not yet run.
    pub fn current_session(&self) -> Option<&str> {
        self.session_ids.last().map(String::as_str)
    }

    /// Whether this record was minted by [`ConversationStore::adopt_orphan_session`]
    /// rather than registered by a client at accept time.
    ///
    /// Derived, not stored: an adopted record's id is by construction the v5 of the
    /// single session it was adopted from, and only adoption ever mints an id that
    /// way. That keeps the persisted shape exactly the record above, and it stays
    /// correct across a state-dir rebuild (the derivation is the same function that
    /// produced the id). Used by `bind_session` to decide whether a session may be
    /// STOLEN: an orphan record is a placeholder for a transcript whose owning turn
    /// had not finished yet, so a real conversation claiming that session must win.
    pub fn is_orphan_adopted(&self) -> bool {
        self.session_ids
            .first()
            .is_some_and(|sid| orphan_conversation_id(sid) == self.conversation_id)
    }
}

/// The deterministic conversation id for a Claude session id: `uuid_v5(NS, session_id)`,
/// canonical lowercase hyphenated. Pure, so the "adopting twice yields the identical
/// id" property is a one-line unit test.
pub fn orphan_conversation_id(session_id: &str) -> String {
    uuid::Uuid::new_v5(&JESSE_CONVERSATION_NS, session_id.as_bytes())
        .hyphenated()
        .to_string()
}

/// Validate a client-supplied conversation id: a canonical lowercase hyphenated UUID
/// and nothing else: 8 hex, `-`, 4, `-`, 4, `-`, 4, `-`, 12 hex. Uppercase, braced,
/// and urn forms are rejected so the id has exactly ONE spelling everywhere (the
/// registry key, the reverse index, the title / flag / deletion key, the wire, the
/// URL path). The UUID VERSION is deliberately not checked: a v5 id from
/// [`orphan_conversation_id`] is a legitimate conversation id. Rejecting anything
/// else also makes the id safe as a path component by construction.
///
/// Returns a one-line message on rejection (the handler surfaces it as a `400`),
/// matching `validate_request_id`.
pub fn validate_conversation_id(s: &str) -> Result<(), String> {
    const GROUPS: [usize; 5] = [8, 4, 4, 4, 12];
    let mut parts = s.split('-');
    for want in GROUPS {
        let Some(part) = parts.next() else {
            return Err("conversation_id must be a canonical lowercase UUID".to_string());
        };
        if part.len() != want
            || !part
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err("conversation_id must be a canonical lowercase UUID".to_string());
        }
    }
    if parts.next().is_some() {
        return Err("conversation_id must be a canonical lowercase UUID".to_string());
    }
    Ok(())
}

/// One turn currently running, claimed BEFORE the CLI is spawned.
///
/// This table is the reason the design works. A conversation is registered at accept
/// time with no bound session, but the CLI writes its transcript file DURING the turn.
/// A conversation-list refresh issued mid-turn would see that stem with no binding,
/// orphan-adopt it into a separate conversation, and the client would adopt that as a
/// duplicate, exactly the bug this whole change removes. The reply binding arrives
/// too late to help. So a running turn records the set of stems that existed just
/// before it spawned, and the refresh skips any stem that is not in ANY live snapshot:
/// such a stem is by construction attributable to a turn still in flight.
///
/// In memory only, never persisted: a bridge restart has no running turns.
#[derive(Clone, Debug)]
pub struct InFlight {
    pub conversation_id: String,
    pub spawn_ms: u64,
    /// Projects-dir stems snapshotted immediately before the spawn.
    pub stems_before: HashSet<String>,
}

/// A live claim on the in-flight table, released on drop.
///
/// The release must be unconditional, including on a panic and on the task abort a
/// cancel performs, because a leaked row would suppress orphan adoption for that
/// stem forever. Tying it to a guard's `Drop` (rather than an explicit call on each
/// terminal path) is what makes that guarantee structural. The terminal path calls
/// [`FlightClaim::take`] to consume the row it needs for the stem diff; the drop then
/// finds nothing left to release.
pub struct FlightClaim {
    store: Arc<ConversationStore>,
    job_id: String,
}

impl FlightClaim {
    /// Remove and return this turn's row, for the terminal stem diff. A second call
    /// (or a call after the row was already released) yields `None`.
    pub fn take(&self) -> Option<InFlight> {
        self.store.release_flight(&self.job_id)
    }
}

impl Drop for FlightClaim {
    fn drop(&mut self) {
        self.store.release_flight(&self.job_id);
    }
}

/// Everything behind the one mutex: the records, the session → conversation reverse
/// index rebuilt from them, the in-flight table, and whether the one-time key
/// migration has run.
#[derive(Default)]
struct Inner {
    map: HashMap<String, ConversationRecord>,
    by_session: HashMap<String, String>,
    /// Keyed on JOB id, not conversation id: two turns of one conversation can be in
    /// flight at once (`JESSE_MAX_CONCURRENCY` > 1) and neither may clobber the other.
    in_flight: HashMap<String, InFlight>,
    /// Transcript stems already reported as unowned, so the scan logs each one ONCE per
    /// process instead of once per conversation-list poll. In memory only, never
    /// persisted: re-reporting the directory after a restart is the point.
    reported_unowned: HashSet<String>,
    migrated: bool,
}

impl Inner {
    /// Rebuild the reverse index from the records. Called on load and after any
    /// mutation that could invalidate it.
    fn reindex(&mut self) {
        self.by_session.clear();
        for rec in self.map.values() {
            for sid in &rec.session_ids {
                self.by_session
                    .insert(sid.clone(), rec.conversation_id.clone());
            }
        }
    }

    fn snapshot(&self) -> HashMap<String, ConversationRecord> {
        self.map.clone()
    }
}

/// The conversation registry. Cheaply shared behind an `Arc` in `AppState`.
pub struct ConversationStore {
    inner: Mutex<Inner>,
    // Where the records are persisted. `None` -> in-memory only.
    path: Option<PathBuf>,
}

impl ConversationStore {
    /// Build the store, loading any records left from a previous run when a path is
    /// configured and rebuilding the reverse index from them. An unreadable / absent /
    /// garbage file loads as empty (not an error).
    pub fn new(path: Option<PathBuf>) -> Self {
        let (map, migrated) = path
            .as_deref()
            .map(load_conversations)
            .unwrap_or_else(|| (HashMap::new(), false));
        let mut inner = Inner {
            map,
            by_session: HashMap::new(),
            in_flight: HashMap::new(),
            reported_unowned: HashSet::new(),
            migrated,
        };
        inner.reindex();
        ConversationStore {
            inner: Mutex::new(inner),
            path,
        }
    }

    /// Persist a snapshot taken under the lock. Called off the lock by every mutator.
    fn persist(&self, snapshot: &HashMap<String, ConversationRecord>, migrated: bool) {
        if let Some(path) = &self.path {
            persist_conversations(path, snapshot, migrated);
        }
    }

    /// Register a client-minted conversation id, IDEMPOTENTLY. An unknown id creates
    /// the record; a known id is returned unchanged. Never touches `session_ids`, so
    /// re-POSTing the same conversation registers nothing new and cannot disturb an
    /// established alias list.
    pub fn register(
        &self,
        conversation_id: &str,
        origin: Option<&str>,
        now_ms: u64,
    ) -> ConversationRecord {
        let (rec, snapshot) = {
            let mut inner = self.inner.lock_ok();
            if let Some(existing) = inner.map.get(conversation_id) {
                return existing.clone();
            }
            let rec = ConversationRecord {
                conversation_id: conversation_id.to_string(),
                session_ids: Vec::new(),
                created_ms: now_ms,
                registered_ms: now_ms,
                origin: origin.map(str::to_string),
            };
            inner.map.insert(conversation_id.to_string(), rec.clone());
            let snapshot = inner.snapshot();
            (rec, snapshot)
        };
        self.persist(&snapshot, self.migration_done());
        rec
    }

    /// Mint a brand-new conversation (v4) for a client that sent no id: an older app
    /// build, or a non-app caller. The id is returned in the 202 either way, so such a
    /// client simply ignores a field it does not decode.
    pub fn mint(&self, origin: Option<&str>, now_ms: u64) -> ConversationRecord {
        let id = uuid::Uuid::new_v4().hyphenated().to_string();
        self.register(&id, origin, now_ms)
    }

    /// Bind a Claude session id to a conversation, making it the CURRENT one.
    ///
    /// A no-op when it is already the last element. Otherwise it is appended, which is
    /// what turns a CLI session fork (a resume that returns a different id, or a
    /// dropped `--resume` after a sweep) into an ALIAS of the same conversation rather
    /// than a new row.
    ///
    /// When the session is currently bound elsewhere, the other record is checked:
    /// an ORPHAN-ADOPTED record (see [`ConversationRecord::is_orphan_adopted`]), or one
    /// holding no other session, loses the session to this conversation and is dropped
    /// once empty. That steal is the backstop that repairs a transcript orphan-adopted
    /// before its owning turn finished. A genuine registered conversation holding OTHER
    /// sessions keeps it, and the refusal is logged.
    pub fn bind_session(&self, conversation_id: &str, session_id: &str) {
        let session_id = session_id.trim();
        if conversation_id.is_empty() || session_id.is_empty() {
            return;
        }
        let snapshot = {
            let mut inner = self.inner.lock_ok();
            // Nothing to bind to: a conversation must be registered first.
            if !inner.map.contains_key(conversation_id) {
                return;
            }
            if let Some(owner) = inner.by_session.get(session_id).cloned() {
                if owner == conversation_id {
                    // Already ours; make sure it is the CURRENT one.
                    let rec = inner.map.get_mut(conversation_id).expect("checked above");
                    if rec.current_session() == Some(session_id) {
                        return;
                    }
                    rec.session_ids.retain(|s| s != session_id);
                    rec.session_ids.push(session_id.to_string());
                    let snapshot = inner.snapshot();
                    inner.reindex();
                    snapshot
                } else {
                    let other = inner.map.get(&owner).cloned().unwrap_or_default();
                    if !other.is_orphan_adopted() && other.session_ids.len() > 1 {
                        eprintln!(
                            "jesse-bridge: session {session_id} is already bound to registered \
                             conversation {owner} with other sessions, not stealing it for \
                             {conversation_id}"
                        );
                        return;
                    }
                    if let Some(loser) = inner.map.get_mut(&owner) {
                        loser.session_ids.retain(|s| s != session_id);
                        if loser.session_ids.is_empty() {
                            inner.map.remove(&owner);
                        }
                    }
                    let rec = inner.map.get_mut(conversation_id).expect("checked above");
                    rec.session_ids.push(session_id.to_string());
                    let snapshot = inner.snapshot();
                    inner.reindex();
                    snapshot
                }
            } else {
                let rec = inner.map.get_mut(conversation_id).expect("checked above");
                rec.session_ids.push(session_id.to_string());
                inner
                    .by_session
                    .insert(session_id.to_string(), conversation_id.to_string());
                inner.snapshot()
            }
        };
        self.persist(&snapshot, self.migration_done());
    }

    /// The conversation a Claude session id belongs to, if any.
    pub fn conversation_for_session(&self, session_id: &str) -> Option<String> {
        self.inner.lock_ok().by_session.get(session_id).cloned()
    }

    /// The conversation's CURRENT (last bound) session id, which is what a resume targets.
    pub fn current_session(&self, conversation_id: &str) -> Option<String> {
        self.inner
            .lock_ok()
            .map
            .get(conversation_id)
            .and_then(|r| r.current_session().map(str::to_string))
    }

    /// One conversation's record.
    pub fn get(&self, conversation_id: &str) -> Option<ConversationRecord> {
        self.inner.lock_ok().map.get(conversation_id).cloned()
    }

    /// Every record, unordered. The list handler sorts.
    pub fn all(&self) -> Vec<ConversationRecord> {
        self.inner.lock_ok().map.values().cloned().collect()
    }

    /// Adopt a transcript found on disk with no record: mint the DETERMINISTIC v5 id
    /// for that session and bind it. Idempotent: adopting the same stem twice yields
    /// the identical id and one record. Returns the conversation id.
    pub fn adopt_orphan_session(&self, session_id: &str, now_ms: u64) -> String {
        let ids = self.adopt_orphan_sessions(std::iter::once(session_id), now_ms);
        ids.into_iter()
            .next()
            .unwrap_or_else(|| orphan_conversation_id(session_id))
    }

    /// Adopt many orphan stems under ONE lock hold and ONE persist. The bulk form
    /// exists so a first run against a projects dir full of legacy transcripts does
    /// not rewrite `conversations.json` once per file.
    pub fn adopt_orphan_sessions<'a, I>(&self, session_ids: I, now_ms: u64) -> Vec<String>
    where
        I: IntoIterator<Item = &'a str>,
    {
        let (ids, changed, snapshot) = {
            let mut inner = self.inner.lock_ok();
            let mut ids = Vec::new();
            let mut changed = false;
            for sid in session_ids {
                let sid = sid.trim();
                if sid.is_empty() {
                    continue;
                }
                if let Some(existing) = inner.by_session.get(sid) {
                    ids.push(existing.clone());
                    continue;
                }
                let cid = orphan_conversation_id(sid);
                let rec = inner
                    .map
                    .entry(cid.clone())
                    .or_insert_with(|| ConversationRecord {
                        conversation_id: cid.clone(),
                        session_ids: Vec::new(),
                        created_ms: now_ms,
                        registered_ms: now_ms,
                        origin: Some("cli".to_string()),
                    });
                if !rec.session_ids.iter().any(|s| s == sid) {
                    rec.session_ids.push(sid.to_string());
                }
                inner.by_session.insert(sid.to_string(), cid.clone());
                ids.push(cid);
                changed = true;
            }
            let snapshot = if changed {
                Some(inner.snapshot())
            } else {
                None
            };
            (ids, changed, snapshot)
        };
        if changed {
            if let Some(snapshot) = snapshot {
                self.persist(&snapshot, self.migration_done());
            }
        }
        ids
    }

    /// Drop a conversation record and every reverse-index entry pointing at it.
    pub fn forget(&self, conversation_id: &str) {
        let snapshot = {
            let mut inner = self.inner.lock_ok();
            if inner.map.remove(conversation_id).is_none() {
                return;
            }
            let snapshot = inner.snapshot();
            inner.reindex();
            snapshot
        };
        self.persist(&snapshot, self.migration_done());
    }

    // ---- The in-flight claim table ----------------------------------------

    /// Claim the in-flight slot for one turn, snapshotting the stems that exist right
    /// now. Returns a guard whose `Drop` releases the row unconditionally.
    pub fn claim_flight(
        self: &Arc<Self>,
        job_id: &str,
        conversation_id: &str,
        stems_before: HashSet<String>,
        now_ms: u64,
    ) -> FlightClaim {
        self.inner.lock_ok().in_flight.insert(
            job_id.to_string(),
            InFlight {
                conversation_id: conversation_id.to_string(),
                spawn_ms: now_ms,
                stems_before,
            },
        );
        FlightClaim {
            store: self.clone(),
            job_id: job_id.to_string(),
        }
    }

    /// Remove one turn's in-flight row, returning it when it was still there.
    pub fn release_flight(&self, job_id: &str) -> Option<InFlight> {
        self.inner.lock_ok().in_flight.remove(job_id)
    }

    /// Whether orphan adoption must SKIP this stem because it is attributable to a
    /// turn that is still running: some turn is in flight and the stem is absent from
    /// every live pre-spawn snapshot, so it can only have been created by one of them.
    /// It will be bound when that turn terminates, and adopted on a later refresh if
    /// the turn dies without binding it.
    pub fn suppresses_orphan(&self, stem: &str) -> bool {
        let inner = self.inner.lock_ok();
        if inner.in_flight.is_empty() {
            return false;
        }
        !inner
            .in_flight
            .values()
            .any(|f| f.stems_before.contains(stem))
    }

    /// Claim the right to report `stem` as an unowned transcript: `true` the FIRST time
    /// it is offered, `false` every time after, so the conversation-list scan logs each
    /// foreign transcript once per process rather than once per poll.
    ///
    /// Recording it is not a claim of ownership — the stem gets no record and no list
    /// row. It exists only to bound the log and to keep the title-mint file read off the
    /// hot path.
    pub fn note_unowned_transcript(&self, stem: &str) -> bool {
        self.inner
            .lock_ok()
            .reported_unowned
            .insert(stem.to_string())
    }

    /// The conversation ids of every turn currently in flight. GC must never drop one.
    pub fn in_flight_conversations(&self) -> HashSet<String> {
        self.inner
            .lock_ok()
            .in_flight
            .values()
            .map(|f| f.conversation_id.clone())
            .collect()
    }

    // ---- The one-time key migration ---------------------------------------

    /// Whether the title / flag / deletion key migration has already run against this
    /// state dir. Persisted in the envelope, so it runs exactly once per deploy.
    pub fn migration_done(&self) -> bool {
        self.inner.lock_ok().migrated
    }

    /// Record that the key migration has run, and persist.
    pub fn mark_migration_done(&self) {
        let snapshot = {
            let mut inner = self.inner.lock_ok();
            if inner.migrated {
                return;
            }
            inner.migrated = true;
            inner.snapshot()
        };
        self.persist(&snapshot, true);
    }

    /// Number of records. For tests / introspection only.
    pub fn len(&self) -> usize {
        self.inner.lock_ok().map.len()
    }

    /// Whether the registry holds no records. For tests / introspection only.
    pub fn is_empty(&self) -> bool {
        self.inner.lock_ok().map.is_empty()
    }
}

/// Load the records from disk, tolerating any corruption by returning what's
/// parseable (an unreadable / absent / garbage file -> empty). Returns the map and the
/// persisted migration flag. A record whose key and `conversation_id` disagree is
/// normalized to the key (the key is what the reverse index and every other store use);
/// a blank key or an unparseable entry is skipped rather than failing the whole load.
pub fn load_conversations(path: &Path) -> (HashMap<String, ConversationRecord>, bool) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return (HashMap::new(), false);
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return (HashMap::new(), false);
    };
    let migrated = value
        .get("migrated")
        .and_then(|m| m.as_bool())
        .unwrap_or(false);
    let mut out = HashMap::new();
    if let Some(obj) = value.get("conversations").and_then(|c| c.as_object()) {
        for (cid, val) in obj {
            let cid = cid.trim();
            if cid.is_empty() {
                continue;
            }
            if let Ok(mut rec) = serde_json::from_value::<ConversationRecord>(val.clone()) {
                rec.conversation_id = cid.to_string();
                rec.session_ids.retain(|s| !s.trim().is_empty());
                out.insert(cid.to_string(), rec);
            }
        }
    }
    (out, migrated)
}

/// Persist the records atomically (temp + rename), mode 0600, the same discipline as
/// `persist_titles`. Best-effort: a failure is logged, never fatal. The parent dir is
/// created if missing so the store works regardless of init order.
pub fn persist_conversations(
    path: &Path,
    conversations: &HashMap<String, ConversationRecord>,
    migrated: bool,
) {
    let value = json!({ "v": 1, "migrated": migrated, "conversations": conversations });
    let tmp = path.with_extension("json.tmp");
    let write = || -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
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
        eprintln!("warning: could not persist conversations: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

/// What the one-time key migration moved, for the single log line it emits.
#[derive(Default, PartialEq, Debug)]
pub struct MigrationCounts {
    pub titles_moved: usize,
    pub titles_dropped: usize,
    pub flags_moved: usize,
    pub flags_dropped: usize,
    pub deletions_moved: usize,
}

/// Re-key the title, flag, and deletion stores from Claude session ids onto
/// conversation ids, ONCE.
///
/// All three predate the conversation record and keyed on a session id, which is no
/// longer stable. For each existing key: a key that is already a registered
/// conversation id is left alone; a key that resolves through the reverse index is
/// rewritten under that conversation id; a key that resolves to nothing (a session
/// swept by GC) is DROPPED for titles and flags, since there is nothing left to show it
/// on, and for deletions is additionally recorded under its deterministic v5 id, so
/// an in-flight tombstone for a session whose transcript is already gone still reaches
/// a client that keys on the conversation.
///
/// A converted deletion key REPLACES the legacy one: nothing reads the session key space any
/// more (the session-keyed route that projected tombstones through it is gone), so keeping
/// it would only grow the file.
///
/// Idempotent in effect: re-running it moves nothing that has already moved and never
/// converts its own output. A Claude session id is UUID-shaped too, so a converted
/// deletion key cannot be told from an unconverted one by shape, so the pass
/// computes the set of v5 images of the keys it is looking at and skips those. The
/// caller additionally guards on [`ConversationStore::migration_done`] so the whole
/// pass runs once per state dir.
pub fn migrate_keys_to_conversations(
    conversations: &ConversationStore,
    titles: &TitleStore,
    flags: &FlagStore,
    deletions: &DeletionStore,
) -> MigrationCounts {
    let mut counts = MigrationCounts::default();

    let mut migrated_titles: HashMap<String, String> = HashMap::new();
    for (key, title) in titles.snapshot() {
        if conversations.get(&key).is_some() {
            migrated_titles.insert(key, title);
        } else if let Some(cid) = conversations.conversation_for_session(&key) {
            migrated_titles.insert(cid, title);
            counts.titles_moved += 1;
        } else {
            counts.titles_dropped += 1;
        }
    }
    titles.replace(migrated_titles);

    let mut migrated_flags: HashMap<String, SessionFlags> = HashMap::new();
    for (key, row) in flags.snapshot() {
        if conversations.get(&key).is_some() {
            migrated_flags.insert(key, row);
        } else if let Some(cid) = conversations.conversation_for_session(&key) {
            migrated_flags.insert(cid, row);
            counts.flags_moved += 1;
        } else {
            counts.flags_dropped += 1;
        }
    }
    flags.replace(migrated_flags);

    let existing_deletions = deletions.snapshot();
    // A key that is the v5 image of another key in this same map is output from an
    // earlier pass, not input. That is the only way to tell, since a Claude session id is
    // UUID-shaped exactly like a conversation id.
    let images: HashSet<String> = existing_deletions
        .keys()
        .map(|k| orphan_conversation_id(k))
        .collect();
    let mut migrated_deletions: HashMap<String, u64> = HashMap::new();
    for (key, ms) in existing_deletions {
        if let Some(cid) = conversations.conversation_for_session(&key) {
            migrated_deletions.insert(cid, ms);
            counts.deletions_moved += 1;
        } else if conversations.get(&key).is_none() && !images.contains(&key) {
            migrated_deletions.insert(orphan_conversation_id(&key), ms);
            counts.deletions_moved += 1;
        } else {
            // Already a conversation-space key: carry it over unchanged.
            migrated_deletions.insert(key, ms);
        }
    }
    deletions.replace(migrated_deletions);

    counts
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_conversations_path() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-convs-{}/conversations.json", random_hex()))
    }

    /// A canonical v4 id, for tests that need a well-formed client-minted id.
    fn cid() -> String {
        uuid::Uuid::new_v4().hyphenated().to_string()
    }

    #[test]
    fn validate_accepts_only_a_canonical_lowercase_uuid() {
        assert!(validate_conversation_id("f5c1a0b2-8e3d-4a19-9b77-2c0d6e4f8a31").is_ok());
        // A v5 id is legitimate: the version is deliberately not checked.
        assert!(validate_conversation_id(&orphan_conversation_id("sess-1")).is_ok());
        // Rejected: uppercase, braced, urn, unhyphenated, wrong group lengths,
        // non-hex, empty, and a traversal attempt.
        assert!(validate_conversation_id("F5C1A0B2-8E3D-4A19-9B77-2C0D6E4F8A31").is_err());
        assert!(validate_conversation_id("{f5c1a0b2-8e3d-4a19-9b77-2c0d6e4f8a31}").is_err());
        assert!(validate_conversation_id("urn:uuid:f5c1a0b2-8e3d-4a19-9b77-2c0d6e4f8a31").is_err());
        assert!(validate_conversation_id("f5c1a0b28e3d4a199b772c0d6e4f8a31").is_err());
        assert!(validate_conversation_id("f5c1a0b2-8e3d-4a19-9b77-2c0d6e4f8a3").is_err());
        assert!(validate_conversation_id("g5c1a0b2-8e3d-4a19-9b77-2c0d6e4f8a31").is_err());
        assert!(validate_conversation_id("").is_err());
        assert!(validate_conversation_id("../x").is_err());
        assert!(validate_conversation_id("local-abc").is_err());
    }

    #[test]
    fn register_is_idempotent_and_never_touches_the_alias_list() {
        let store = ConversationStore::new(None);
        let id = cid();
        let first = store.register(&id, Some("phone"), 1_000);
        assert_eq!(first.conversation_id, id);
        assert!(first.session_ids.is_empty());
        assert_eq!(first.registered_ms, 1_000);
        store.bind_session(&id, "sess-1");
        // A second register of the same id returns the EXISTING record untouched.
        let again = store.register(&id, Some("mac"), 9_999);
        assert_eq!(again.session_ids, vec!["sess-1".to_string()]);
        assert_eq!(again.registered_ms, 1_000, "registered_ms is not refreshed");
        assert_eq!(again.origin.as_deref(), Some("phone"));
        assert_eq!(store.len(), 1, "no second record");
    }

    #[test]
    fn mint_produces_a_canonical_id_and_one_record() {
        let store = ConversationStore::new(None);
        let rec = store.mint(Some("phone"), 5);
        assert!(validate_conversation_id(&rec.conversation_id).is_ok());
        assert_eq!(store.len(), 1);
        // Two mints never collide.
        let other = store.mint(None, 6);
        assert_ne!(rec.conversation_id, other.conversation_id);
    }

    #[test]
    fn bind_appends_aliases_and_tracks_the_current_session() {
        let store = ConversationStore::new(None);
        let id = cid();
        store.register(&id, None, 1);
        assert_eq!(store.current_session(&id), None);
        store.bind_session(&id, "sess-1");
        assert_eq!(store.current_session(&id).as_deref(), Some("sess-1"));
        // A fork appends rather than replacing: BOTH ids resolve to this conversation.
        store.bind_session(&id, "sess-2");
        assert_eq!(store.current_session(&id).as_deref(), Some("sess-2"));
        assert_eq!(
            store.get(&id).unwrap().session_ids,
            vec!["sess-1".to_string(), "sess-2".to_string()]
        );
        assert_eq!(
            store.conversation_for_session("sess-1").as_deref(),
            Some(&id[..])
        );
        assert_eq!(
            store.conversation_for_session("sess-2").as_deref(),
            Some(&id[..])
        );
        // Re-binding the current session is a no-op.
        store.bind_session(&id, "sess-2");
        assert_eq!(store.get(&id).unwrap().session_ids.len(), 2);
        // Re-binding an OLDER alias makes it current again without duplicating it.
        store.bind_session(&id, "sess-1");
        assert_eq!(
            store.get(&id).unwrap().session_ids,
            vec!["sess-2".to_string(), "sess-1".to_string()]
        );
    }

    #[test]
    fn bind_to_an_unregistered_conversation_is_a_noop() {
        let store = ConversationStore::new(None);
        store.bind_session(&cid(), "sess-1");
        assert!(store.is_empty());
        assert_eq!(store.conversation_for_session("sess-1"), None);
    }

    #[test]
    fn adopting_a_legacy_transcript_twice_yields_the_identical_v5_id() {
        let store = ConversationStore::new(None);
        let first = store.adopt_orphan_session("sess-legacy", 100);
        let again = store.adopt_orphan_session("sess-legacy", 999);
        assert_eq!(first, again, "adoption is deterministic and idempotent");
        assert_eq!(first, orphan_conversation_id("sess-legacy"));
        assert_eq!(store.len(), 1, "one record, not two");
        assert!(store.get(&first).unwrap().is_orphan_adopted());
    }

    #[test]
    fn bind_steals_a_session_from_an_orphan_record_and_drops_it() {
        // The repair path: a transcript orphan-adopted while its owning turn was still
        // running must be reclaimed by the real conversation when that turn finishes.
        let store = ConversationStore::new(None);
        let orphan = store.adopt_orphan_session("sess-1", 10);
        let real = cid();
        store.register(&real, Some("phone"), 20);
        store.bind_session(&real, "sess-1");
        assert_eq!(
            store.conversation_for_session("sess-1").as_deref(),
            Some(&real[..])
        );
        assert!(
            store.get(&orphan).is_none(),
            "emptied orphan record is dropped"
        );
        assert_eq!(store.len(), 1, "exactly one conversation remains");
    }

    #[test]
    fn bind_refuses_to_steal_from_a_registered_conversation_with_other_sessions() {
        let store = ConversationStore::new(None);
        let owner = cid();
        store.register(&owner, Some("phone"), 1);
        store.bind_session(&owner, "sess-1");
        store.bind_session(&owner, "sess-2");
        let thief = cid();
        store.register(&thief, Some("mac"), 2);
        store.bind_session(&thief, "sess-2");
        assert_eq!(
            store.conversation_for_session("sess-2").as_deref(),
            Some(&owner[..]),
            "a genuine registered conversation with other sessions keeps its session"
        );
        assert!(store.get(&thief).unwrap().session_ids.is_empty());
        assert_eq!(store.get(&owner).unwrap().session_ids.len(), 2);
    }

    #[test]
    fn forget_removes_the_record_and_every_reverse_index_entry() {
        let store = ConversationStore::new(None);
        let id = cid();
        store.register(&id, None, 1);
        store.bind_session(&id, "sess-1");
        store.bind_session(&id, "sess-2");
        store.forget(&id);
        assert!(store.is_empty());
        assert_eq!(store.conversation_for_session("sess-1"), None);
        assert_eq!(store.conversation_for_session("sess-2"), None);
        // Forgetting an unknown id is a harmless no-op.
        store.forget(&cid());
    }

    #[test]
    fn survives_a_restart_and_rebuilds_the_reverse_index() {
        let path = temp_conversations_path();
        let id = cid();
        {
            let store = ConversationStore::new(Some(path.clone()));
            store.register(&id, Some("phone"), 1_234);
            store.bind_session(&id, "sess-a");
            store.bind_session(&id, "sess-b");
        }
        let reloaded = ConversationStore::new(Some(path.clone()));
        let rec = reloaded.get(&id).unwrap();
        assert_eq!(
            rec.session_ids,
            vec!["sess-a".to_string(), "sess-b".to_string()]
        );
        assert_eq!(rec.registered_ms, 1_234);
        // The reverse index is rebuilt from the records, not persisted.
        assert_eq!(
            reloaded.conversation_for_session("sess-a").as_deref(),
            Some(&id[..])
        );
        assert_eq!(reloaded.current_session(&id).as_deref(), Some("sess-b"));
        // File is 0600.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "conversations.json must be 0600");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_corrupt_file_loads_as_empty_not_an_error() {
        let path = temp_conversations_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "not json at all {").unwrap();
        let store = ConversationStore::new(Some(path.clone()));
        assert!(store.is_empty());
        assert!(!store.migration_done());
        // And it is usable: a register after a corrupt load still works and rewrites.
        let id = cid();
        store.register(&id, None, 1);
        let reloaded = ConversationStore::new(Some(path.clone()));
        assert!(reloaded.get(&id).is_some());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn the_migration_flag_persists_so_the_migration_runs_once() {
        let path = temp_conversations_path();
        {
            let store = ConversationStore::new(Some(path.clone()));
            assert!(!store.migration_done());
            store.mark_migration_done();
            assert!(store.migration_done());
        }
        assert!(ConversationStore::new(Some(path.clone())).migration_done());
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn in_flight_suppresses_only_stems_created_after_a_spawn() {
        let store = Arc::new(ConversationStore::new(None));
        let id = cid();
        store.register(&id, Some("phone"), 1);
        // With nothing in flight, no stem is ever suppressed.
        assert!(!store.suppresses_orphan("brand-new"));
        let before: HashSet<String> = ["old-1".to_string(), "old-2".to_string()]
            .into_iter()
            .collect();
        let claim = store.claim_flight("job-1", &id, before, 100);
        // A stem that existed before the spawn is adoptable as usual.
        assert!(!store.suppresses_orphan("old-1"));
        // A stem that appeared DURING the turn is suppressed: it is this turn's.
        assert!(store.suppresses_orphan("mid-turn"));
        // Taking the row for the terminal stem diff releases it.
        let row = claim.take().expect("the claim is still live");
        assert_eq!(row.conversation_id, id);
        assert_eq!(row.spawn_ms, 100);
        assert!(!store.suppresses_orphan("mid-turn"));
        assert!(claim.take().is_none(), "a second take yields nothing");
    }

    #[test]
    fn dropping_the_claim_releases_the_row_even_without_take() {
        // The panic / abort path: the guard's Drop must free the suppression, or a
        // leaked row would hide that stem from adoption forever.
        let store = Arc::new(ConversationStore::new(None));
        let id = cid();
        store.register(&id, None, 1);
        {
            let _claim = store.claim_flight("job-1", &id, HashSet::new(), 1);
            assert!(store.suppresses_orphan("x"));
            assert_eq!(store.in_flight_conversations().len(), 1);
        }
        assert!(!store.suppresses_orphan("x"));
        assert!(store.in_flight_conversations().is_empty());
    }

    #[test]
    fn migration_moves_resolvable_keys_drops_swept_titles_and_converts_tombstones() {
        let store = ConversationStore::new(None);
        let live = cid();
        store.register(&live, Some("phone"), 1);
        store.bind_session(&live, "sess-live");
        // A conversation whose title/flag key is ALREADY the conversation id (a row
        // written by a post-migration bridge): it must be left exactly alone.
        let already = cid();
        store.register(&already, Some("mac"), 2);
        store.bind_session(&already, "sess-already");

        let titles = TitleStore::new(None);
        titles.set("sess-live", "Live Conversation");
        titles.set("sess-swept", "Gone Conversation");
        titles.set(&already, "Already Migrated");

        let flags = FlagStore::new(None);
        flags.apply(
            "sess-live",
            &FlagUpdate {
                favorite: Some(true),
                favorite_updated_ms: Some(500),
                ..FlagUpdate::default()
            },
        );
        flags.apply(
            "sess-swept",
            &FlagUpdate {
                archived: Some(true),
                archived_updated_ms: Some(500),
                ..FlagUpdate::default()
            },
        );

        let now = system_time_to_ms(SystemTime::now());
        let deletions = DeletionStore::new(None, 30 * 24 * 60 * 60 * 1000);
        deletions.record("sess-deleted", now);

        let counts = migrate_keys_to_conversations(&store, &titles, &flags, &deletions);
        assert_eq!(counts.titles_moved, 1);
        assert_eq!(counts.titles_dropped, 1);
        assert_eq!(counts.flags_moved, 1);
        assert_eq!(counts.flags_dropped, 1);
        assert_eq!(counts.deletions_moved, 1);

        // The resolvable title moved onto the conversation; the swept one is gone; the
        // key that was already a conversation id is untouched.
        assert_eq!(titles.get(&live).as_deref(), Some("Live Conversation"));
        assert_eq!(titles.get(&already).as_deref(), Some("Already Migrated"));
        assert_eq!(titles.get("sess-live"), None);
        assert_eq!(titles.get("sess-swept"), None);
        // Flags moved with their LWW clocks intact.
        let f = flags.get(&live);
        assert!(f.favorite && f.favorite_updated_ms == 500);
        assert_eq!(flags.get("sess-swept"), SessionFlags::default());
        // The tombstone moved onto its conversation key, REPLACING the legacy session key:
        // nothing reads the session key space any more, so keeping it would only grow the file.
        let ids: Vec<String> = deletions
            .recent(now)
            .into_iter()
            .map(|t| t.session_id)
            .collect();
        assert_eq!(ids, vec![orphan_conversation_id("sess-deleted")]);

        // The title and flag halves are idempotent in EFFECT: a second pass moves nothing and
        // drops nothing, because a key that is already a registered conversation id is
        // recognized as such.
        let titles_before = titles.snapshot();
        let flags_before = flags.snapshot();
        let again = migrate_keys_to_conversations(&store, &titles, &flags, &deletions);
        assert_eq!(again.titles_moved, 0);
        assert_eq!(again.titles_dropped, 0);
        assert_eq!(again.flags_moved, 0);
        assert_eq!(again.flags_dropped, 0);
        assert_eq!(titles.snapshot(), titles_before);
        assert_eq!(flags.snapshot(), flags_before);
        assert!(
            flags.get(&live).favorite,
            "the LWW clock survived unchanged"
        );
        // The DELETION half is different, and the difference is worth being explicit about: a
        // tombstone for a swept session converts to a key that cannot be told from an
        // unconverted one, because a Claude session id is UUID-shaped exactly like a
        // conversation id. So this half is idempotent only under the caller's
        // `migration_done` guard, which is the mechanism production actually relies on. The
        // guard is asserted below and end to end by the restart test.
        assert!(
            !store.migration_done(),
            "the pass itself does not set the flag"
        );
        store.mark_migration_done();
        assert!(
            store.migration_done(),
            "the caller marks it, and `AppState` skips the whole pass when it is set"
        );
    }
}
