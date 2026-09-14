use crate::*;

// ---- Server-side per-session favorite / archived flags ---------------------
//
// A single JSON file `<state_dir>/flags.json` mapping conversation_id -> SessionFlags,
// so a conversation's favorite / archived state is the bridge's (not one device's)
// and every device converges on one set of favorites and one set of archived
// conversations. Mirrors `TitleStore`'s discipline exactly: atomic temp+rename
// writes, mode 0600, best-effort (a write failure is logged, never fatal). With no
// state dir configured the store is in-memory only, the same degradation the job,
// device, and title stores have, so flags are lost on restart in that mode.
//
// Each of the two flags is an independent last-writer-wins register keyed on a
// client-supplied change timestamp in unix milliseconds: a strictly newer
// timestamp wins, an equal or older write is ignored. That makes each flag
// order-independent, so writes arriving from different devices in any order
// converge to the same result. Only the two booleans and their timestamps are
// ever written; never a secret and never conversation content.

/// The favorite / archived / read state for one session. Each flag carries the
/// unix-millis client change time it was last set at, so a write applies
/// last-writer-wins. Defaults to `false` / `0` for a session with no row, and every field
/// is `#[serde(default)]` so a missing or future field loads without error (an added
/// flag is a purely additive change).
#[derive(serde::Serialize, serde::Deserialize, Clone, Default, PartialEq, Debug)]
pub struct SessionFlags {
    #[serde(default)]
    pub favorite: bool,
    #[serde(default)]
    pub favorite_updated_ms: u64,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub archived_updated_ms: u64,
    /// How far this conversation has been READ: the `last_reply_ms` value that was
    /// current when a device last had the transcript on screen. A conversation is unread
    /// when its [`ConversationRecord::last_reply_ms`](crate::ConversationRecord) is
    /// strictly greater than this.
    ///
    /// It holds a REPLY time, never a device's "now": marking read copies the
    /// conversation's own `last_reply_ms` across, so both sides of the comparison come
    /// off the bridge's clock and skew between devices can neither hide a new reply nor
    /// revive a read one. `0` means "never read", which against a `last_reply_ms` of `0`
    /// (no reply yet, and every record written before either field existed) reads as
    /// READ — so the upgrade marks nothing unread.
    #[serde(default)]
    pub read_through_ms: u64,
    /// The never-cleared last-writer-wins clock for `read_through_ms` — the DEVICE's
    /// change time, exactly like `favorite_updated_ms`. Separate from the value because
    /// the value moves backwards on "Mark as Unread", and a register whose own clock
    /// could go back would lose that write.
    #[serde(default)]
    pub read_updated_ms: u64,
}

impl SessionFlags {
    /// Apply a favorite write with client change time `ts_ms` (unix millis), LWW:
    /// a STRICTLY newer timestamp wins and updates both the value and the stored
    /// timestamp; an equal or older write is ignored. Returns whether anything
    /// changed (so the store only persists on a real change).
    fn apply_favorite(&mut self, value: bool, ts_ms: u64) -> bool {
        if ts_ms > self.favorite_updated_ms {
            self.favorite = value;
            self.favorite_updated_ms = ts_ms;
            true
        } else {
            false
        }
    }

    /// Apply an archived write with client change time `ts_ms` (unix millis), LWW:
    /// same rule as [`apply_favorite`](Self::apply_favorite) on the archived
    /// register. Returns whether anything changed.
    fn apply_archived(&mut self, value: bool, ts_ms: u64) -> bool {
        if ts_ms > self.archived_updated_ms {
            self.archived = value;
            self.archived_updated_ms = ts_ms;
            true
        } else {
            false
        }
    }

    /// Apply a read-through write with client change time `ts_ms` (unix millis), LWW:
    /// the same strictly-newer rule as [`apply_favorite`](Self::apply_favorite), on the
    /// read register. Returns whether anything changed.
    ///
    /// Deliberately last-writer-wins and NOT max-wins on the value: "Mark as Unread"
    /// moves `read_through_ms` BACKWARDS (to 0), and a max rule would silently discard
    /// it. The clock is what orders the writes; the value is free to go either way.
    fn apply_read(&mut self, value: u64, ts_ms: u64) -> bool {
        if ts_ms > self.read_updated_ms {
            self.read_through_ms = value;
            self.read_updated_ms = ts_ms;
            true
        } else {
            false
        }
    }
}

/// A write to the flags endpoint: any subset of the six fields. A flag is applied
/// only when its value is present; its timestamp defaults to 0 when absent
/// (which, being not strictly greater than any real prior timestamp, is a no-op),
/// so a well-formed client always sends the value and its unix-millis change time
/// together.
#[derive(serde::Deserialize, Default, Debug)]
pub struct FlagUpdate {
    #[serde(default)]
    pub favorite: Option<bool>,
    #[serde(default)]
    pub favorite_updated_ms: Option<u64>,
    #[serde(default)]
    pub archived: Option<bool>,
    #[serde(default)]
    pub archived_updated_ms: Option<u64>,
    /// The read-through value: the conversation's `last_reply_ms` as the marking device
    /// saw it, or `0` for "Mark as Unread". Not a boolean like the other two, which is
    /// why the register has its own `apply_read`.
    #[serde(default)]
    pub read_through_ms: Option<u64>,
    #[serde(default)]
    pub read_updated_ms: Option<u64>,
}

/// The conversation_id -> flags map. Cheaply shared behind an `Arc` in `AppState`.
pub struct FlagStore {
    map: Mutex<HashMap<String, SessionFlags>>,
    // Where the map is persisted. `None` -> in-memory only.
    path: Option<PathBuf>,
    // Orders the disk writes, so the file only ever moves forward (see `atomicfile`).
    writer: SnapshotWriter,
}

impl FlagStore {
    /// Build the store, loading any flags left from a previous run when a path is
    /// configured. An unreadable/absent/garbage file loads as empty (not an error).
    pub fn new(path: Option<PathBuf>) -> Self {
        let map = path.as_deref().map(load_flags).unwrap_or_default();
        FlagStore {
            map: Mutex::new(map),
            path,
            writer: SnapshotWriter::new(),
        }
    }

    /// Write the map as it is now, after any write already in progress. Every mutator calls
    /// this AFTER releasing the lock. No-op without a path.
    fn persist(&self) {
        if let Some(path) = &self.path {
            self.writer.persist(
                || self.map.lock_ok().clone(),
                |flags| persist_flags(path, flags),
            );
        }
    }

    /// The stored flags for a session, or the all-false/zero default when it has no
    /// row. The read path uses this so an unflagged session lists as
    /// `favorite:false, archived:false` with zero timestamps.
    pub fn get(&self, session_id: &str) -> SessionFlags {
        self.map
            .lock_ok()
            .get(session_id)
            .cloned()
            .unwrap_or_default()
    }

    /// Apply an update to a session's flags last-writer-wins per provided flag, then
    /// persist (atomically) when a state dir is configured AND a flag actually
    /// changed. Returns the resulting flags either way. A blank session_id is a
    /// no-op that returns the default (the handler already rejects such ids). An
    /// update whose every provided write is stale changes nothing and writes nothing.
    pub fn apply(&self, session_id: &str, update: &FlagUpdate) -> SessionFlags {
        let session_id = session_id.trim();
        if session_id.is_empty() {
            return SessionFlags::default();
        }
        let (result, changed) = {
            let mut map = self.map.lock_ok();
            let entry = map.entry(session_id.to_string()).or_default();
            let mut changed = false;
            if let Some(value) = update.favorite {
                changed |= entry.apply_favorite(value, update.favorite_updated_ms.unwrap_or(0));
            }
            if let Some(value) = update.archived {
                changed |= entry.apply_archived(value, update.archived_updated_ms.unwrap_or(0));
            }
            if let Some(value) = update.read_through_ms {
                changed |= entry.apply_read(value, update.read_updated_ms.unwrap_or(0));
            }
            (entry.clone(), changed)
        };
        // Persist only when a flag actually changed.
        if changed {
            self.persist();
        }
        result
    }

    /// Drop the flags row for a session and persist, if one was stored (session
    /// delete / GC reclaim: a reclaimed session's transcript is gone, so its stashed
    /// flags must not linger in `flags.json` and resurrect a stale favorite). A
    /// no-op (no write) when the session has no row or the id is blank.
    pub fn remove(&self, session_id: &str) {
        let session_id = session_id.trim();
        if session_id.is_empty() {
            return;
        }
        if self.map.lock_ok().remove(session_id).is_none() {
            return;
        }
        self.persist();
    }

    /// A copy of the whole map. Needed by the one-time key migration, which has to
    /// walk every existing key to re-key it onto a conversation id.
    pub fn snapshot(&self) -> HashMap<String, SessionFlags> {
        self.map.lock_ok().clone()
    }

    /// Replace the whole map and persist. The one-time key migration's commit step:
    /// the re-keyed map is installed in one write, so a partially migrated file can
    /// never be observed. Rows are carried over UNCHANGED, so each flag keeps its
    /// last-writer-wins clock and convergence is unaffected by the re-keying. Not for
    /// ordinary use: `apply` / `remove` are the per-entry API.
    pub fn replace(&self, flags: HashMap<String, SessionFlags>) {
        *self.map.lock_ok() = flags;
        self.persist();
    }

    /// Number of stored flag rows. For tests/introspection only.
    pub fn len(&self) -> usize {
        self.map.lock_ok().len()
    }

    /// Whether the store holds no flag rows. For tests/introspection only.
    pub fn is_empty(&self) -> bool {
        self.map.lock_ok().is_empty()
    }
}

/// THE UNREAD RULE, in one place: a conversation has a reply nobody has seen when its
/// last reply is strictly newer than how far it has been read.
///
/// Pure, and shared with both apps' `JesseThread.hasUnreadReply` — the badge the bridge
/// puts on a push and the dot the app draws on a row have to be the same claim, or the
/// number on the icon disagrees with the list behind it.
pub fn has_unread_reply(last_reply_ms: u64, read_through_ms: u64) -> bool {
    last_reply_ms > read_through_ms
}

/// How many conversations have a reply nobody has seen — the number the app icon badges.
///
/// ARCHIVED CONVERSATIONS ARE EXCLUDED, and deleted ones are already gone from the
/// registry (a delete `forget`s the record), so this counts exactly what the phone's
/// Chats list counts. An archived thread keeps its dot inside the Archived view; what it
/// does not do is drive a number on the home screen, because archiving is precisely the
/// gesture for "stop showing me this".
pub fn unread_conversation_count(conversations: &ConversationStore, flags: &FlagStore) -> u64 {
    let rows = flags.snapshot();
    conversations
        .all()
        .iter()
        .filter(|rec| {
            let f = rows.get(&rec.conversation_id);
            let archived = f.is_some_and(|f| f.archived);
            let read_through = f.map(|f| f.read_through_ms).unwrap_or(0);
            !archived && has_unread_reply(rec.last_reply_ms, read_through)
        })
        .count() as u64
}

/// Load the flags map from disk, tolerating any corruption by returning what's
/// parseable (an unreadable/absent/garbage file -> empty map). Each entry is parsed
/// field-by-field with defaults, so a hand-edited file missing a field, or one
/// written by a future bridge with an extra flag, loads cleanly (unknown fields are
/// ignored, missing ones default). A blank session_id or an unparseable entry is
/// skipped rather than failing the whole load.
pub fn load_flags(path: &Path) -> HashMap<String, SessionFlags> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return HashMap::new();
    };
    let mut out = HashMap::new();
    if let Some(obj) = value.get("flags").and_then(|t| t.as_object()) {
        for (sid, val) in obj {
            let sid = sid.trim();
            if sid.is_empty() {
                continue;
            }
            if let Ok(flags) = serde_json::from_value::<SessionFlags>(val.clone()) {
                out.insert(sid.to_string(), flags);
            }
        }
    }
    out
}

/// Persist the flags map atomically (temp + rename), mode 0600, the same
/// discipline as `persist_titles`. Best-effort: a failure is logged, never fatal.
/// The parent dir is created if missing so the store works regardless of init order.
pub fn persist_flags(path: &Path, flags: &HashMap<String, SessionFlags>) {
    let value = json!({ "v": 1, "flags": flags });
    if let Err(e) = write_atomic(path, value.to_string().as_bytes()) {
        eprintln!("warning: could not persist flags: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_flags_path() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-flags-{}/flags.json", random_hex()))
    }

    /// An update that sets `favorite` to `value` at client time `ts`.
    fn fav(value: bool, ts: u64) -> FlagUpdate {
        FlagUpdate {
            favorite: Some(value),
            favorite_updated_ms: Some(ts),
            ..FlagUpdate::default()
        }
    }

    /// An update that sets `archived` to `value` at client time `ts`.
    fn arch(value: bool, ts: u64) -> FlagUpdate {
        FlagUpdate {
            archived: Some(value),
            archived_updated_ms: Some(ts),
            ..FlagUpdate::default()
        }
    }

    #[test]
    fn unknown_session_reads_the_default_all_false_zero() {
        let store = FlagStore::new(None);
        assert_eq!(store.get("nope"), SessionFlags::default());
        assert!(store.is_empty());
    }

    #[test]
    fn lww_newer_wins_older_and_equal_are_ignored() {
        // The core last-writer-wins register: a strictly newer timestamp wins; an
        // equal or older write is ignored. Each flag is independent.
        let store = FlagStore::new(None);

        // First write establishes the value.
        let r = store.apply("s", &fav(true, 100));
        assert!(r.favorite && r.favorite_updated_ms == 100);

        // An OLDER write (ts 50) is ignored (value and timestamp both unchanged).
        let r = store.apply("s", &fav(false, 50));
        assert!(
            r.favorite && r.favorite_updated_ms == 100,
            "older write ignored"
        );

        // An EQUAL write (ts 100) is ignored too (strictly-newer only).
        let r = store.apply("s", &fav(false, 100));
        assert!(
            r.favorite && r.favorite_updated_ms == 100,
            "equal write ignored"
        );

        // A strictly NEWER write (ts 101) wins.
        let r = store.apply("s", &fav(false, 101));
        assert!(
            !r.favorite && r.favorite_updated_ms == 101,
            "newer write wins"
        );
    }

    #[test]
    fn out_of_order_writes_converge_regardless_of_arrival_order() {
        // Two devices' writes at ts 10 and ts 20 converge to the ts-20 value no
        // matter which arrives first; the register is order-independent.
        let a = FlagStore::new(None);
        a.apply("s", &fav(true, 10));
        a.apply("s", &fav(false, 20));

        let b = FlagStore::new(None);
        b.apply("s", &fav(false, 20));
        b.apply("s", &fav(true, 10));

        assert_eq!(a.get("s"), b.get("s"));
        assert!(!a.get("s").favorite, "the ts-20 value (false) wins in both");
        assert_eq!(a.get("s").favorite_updated_ms, 20);
    }

    #[test]
    fn favorite_and_archived_are_independent_registers() {
        let store = FlagStore::new(None);
        store.apply("s", &fav(true, 100));
        store.apply("s", &arch(true, 5));
        let f = store.get("s");
        assert!(f.favorite && f.favorite_updated_ms == 100);
        assert!(f.archived && f.archived_updated_ms == 5);

        // A stale favorite write leaves archived untouched, and vice versa.
        store.apply("s", &fav(false, 1));
        store.apply("s", &arch(false, 6));
        let f = store.get("s");
        assert!(f.favorite, "stale favorite write did not change favorite");
        assert!(!f.archived, "newer archived write flipped archived only");
        assert_eq!(f.favorite_updated_ms, 100);
        assert_eq!(f.archived_updated_ms, 6);
    }

    #[test]
    fn partial_update_touches_only_the_provided_flag() {
        // A body carrying just archived must not disturb favorite's value or ts.
        let store = FlagStore::new(None);
        store.apply("s", &fav(true, 100));
        let r = store.apply("s", &arch(true, 200));
        assert!(
            r.favorite && r.favorite_updated_ms == 100,
            "favorite untouched"
        );
        assert!(r.archived && r.archived_updated_ms == 200, "archived set");
    }

    #[test]
    fn survives_a_restart_write_drop_reload_read() {
        let path = temp_flags_path();
        {
            let store = FlagStore::new(Some(path.clone()));
            store.apply("sess-x", &fav(true, 111));
            store.apply("sess-x", &arch(true, 222));
            // store drops here; the file is already fsync'd + renamed by `apply`.
        }
        // A fresh store over the same path reloads what was written.
        let reloaded = FlagStore::new(Some(path.clone()));
        let f = reloaded.get("sess-x");
        assert_eq!(
            f,
            SessionFlags {
                favorite: true,
                favorite_updated_ms: 111,
                archived: true,
                archived_updated_ms: 222,
                read_through_ms: 0,
                read_updated_ms: 0,
            }
        );

        // File is 0600.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "flags.json must be 0600");

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn remove_drops_a_row_and_is_a_noop_when_absent() {
        // Session delete / GC reclaim: a reclaimed session's stashed flags must not
        // linger and resurrect a stale favorite.
        let store = FlagStore::new(None);
        store.apply("sess-a", &fav(true, 10));
        store.apply("sess-b", &arch(true, 10));
        store.remove("sess-a");
        assert_eq!(
            store.get("sess-a"),
            SessionFlags::default(),
            "removed row gone"
        );
        assert!(store.get("sess-b").archived, "others untouched");
        // No-ops.
        store.remove("ghost");
        store.remove("");
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn a_stale_only_update_persists_nothing_but_still_returns_state() {
        // An update whose every write is stale changes nothing; the returned state is
        // the current one. (Also exercises the "no snapshot when unchanged" path.)
        let path = temp_flags_path();
        let store = FlagStore::new(Some(path.clone()));
        store.apply("s", &fav(true, 100));
        let r = store.apply("s", &fav(false, 100)); // equal ts, ignored
        assert!(r.favorite && r.favorite_updated_ms == 100);
        let reloaded = FlagStore::new(Some(path.clone()));
        assert!(reloaded.get("s").favorite, "the winning value survived");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_corrupt_file_loads_as_empty_not_an_error() {
        let path = temp_flags_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "not json at all {").unwrap();
        let store = FlagStore::new(Some(path.clone()));
        assert!(store.is_empty());
        // And it's usable: an apply after a corrupt load still works and rewrites.
        store.apply("s", &fav(true, 7));
        let reloaded = FlagStore::new(Some(path.clone()));
        assert!(reloaded.get("s").favorite);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn load_tolerates_a_missing_field_additive_forward_compat() {
        // A hand-written / older file with only `favorite` set must load, defaulting
        // the rest; the additive-compat property for a future flag.
        let path = temp_flags_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            r#"{"v":1,"flags":{"s":{"favorite":true,"favorite_updated_ms":9,"extra_future_flag":true}}}"#,
        )
        .unwrap();
        let store = FlagStore::new(Some(path.clone()));
        let f = store.get("s");
        assert!(f.favorite && f.favorite_updated_ms == 9);
        assert!(
            !f.archived && f.archived_updated_ms == 0,
            "missing fields default"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    // ---- The read register ------------------------------------------------

    /// An update that marks read through `value` at client change time `ts`.
    fn read(value: u64, ts: u64) -> FlagUpdate {
        FlagUpdate {
            read_through_ms: Some(value),
            read_updated_ms: Some(ts),
            ..FlagUpdate::default()
        }
    }

    #[test]
    fn read_through_is_lww_and_a_newer_mark_unread_moves_it_backwards() {
        // The property the boolean flags do not have: the VALUE goes backwards on
        // "Mark as Unread", and only the CLOCK orders the writes. A max-wins rule on
        // the value would silently discard the unread mark.
        let store = FlagStore::new(None);

        // Read through a reply at 5_000, marked at client time 100.
        let r = store.apply("s", &read(5_000, 100));
        assert_eq!((r.read_through_ms, r.read_updated_ms), (5_000, 100));

        // A NEWER mark-unread (value 0, clock 200) wins even though the value drops.
        let r = store.apply("s", &read(0, 200));
        assert_eq!(
            (r.read_through_ms, r.read_updated_ms),
            (0, 200),
            "a newer mark-unread moves read_through_ms backwards"
        );

        // An OLDER write is ignored, value and clock both.
        let r = store.apply("s", &read(9_000, 150));
        assert_eq!(
            (r.read_through_ms, r.read_updated_ms),
            (0, 200),
            "older ignored"
        );

        // An EQUAL clock is ignored too (strictly-newer only), matching the other flags.
        let r = store.apply("s", &read(9_000, 200));
        assert_eq!(
            (r.read_through_ms, r.read_updated_ms),
            (0, 200),
            "equal ignored"
        );
    }

    #[test]
    fn read_is_independent_of_favorite_and_archived() {
        let store = FlagStore::new(None);
        store.apply("s", &fav(true, 100));
        store.apply("s", &arch(true, 100));
        let r = store.apply("s", &read(7, 1));
        assert!(r.favorite && r.archived, "the boolean flags are untouched");
        assert_eq!(r.read_through_ms, 7);
        // And a stale read write leaves the others alone in turn.
        let r = store.apply("s", &fav(false, 200));
        assert_eq!(
            r.read_through_ms, 7,
            "read_through_ms untouched by a favorite write"
        );
        assert!(!r.favorite);
    }

    #[test]
    fn a_flags_file_without_the_read_fields_loads_with_them_defaulted() {
        // THE UPGRADE MARKS NOTHING UNREAD. A flags.json written by a bridge that
        // predates the read register must load with `read_through_ms == 0` — which,
        // against a conversation whose `last_reply_ms` is also 0 (no field either),
        // reads as READ.
        let path = temp_flags_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            r#"{"v":1,"flags":{"s":{"favorite":true,"favorite_updated_ms":9,"archived":false,"archived_updated_ms":0}}}"#,
        )
        .unwrap();
        let store = FlagStore::new(Some(path.clone()));
        let f = store.get("s");
        assert!(f.favorite, "the pre-existing flag survives");
        assert_eq!(f.read_through_ms, 0, "read_through_ms defaults to 0");
        assert_eq!(f.read_updated_ms, 0, "read_updated_ms defaults to 0");
        assert!(
            !has_unread_reply(0, f.read_through_ms),
            "which reads as READ"
        );
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn the_unread_rule_is_strictly_greater() {
        assert!(!has_unread_reply(0, 0), "no reply yet is read");
        assert!(has_unread_reply(1, 0), "a reply nobody marked is unread");
        assert!(
            !has_unread_reply(5, 5),
            "read exactly through the last reply"
        );
        assert!(has_unread_reply(6, 5), "a newer reply than the mark");
        assert!(
            !has_unread_reply(5, 6),
            "a mark past the last reply stays read"
        );
    }

    #[test]
    fn the_count_skips_archived_and_read_conversations() {
        let convs = ConversationStore::new(None);
        let flags = FlagStore::new(None);
        let mk = |origin: &str| convs.mint(Some(origin), 1_000).conversation_id;

        let unread = mk("phone");
        let read_one = mk("phone");
        let archived_unread = mk("phone");
        let never_replied = mk("phone");

        // Each of the first three got a reply at bridge time 5_000.
        for cid in [&unread, &read_one, &archived_unread] {
            convs.note_reply(cid, 5_000);
        }
        // One was read through that reply; one was archived (and stays unread inside the
        // Archived view, but must not drive the icon badge).
        flags.apply(&read_one, &read(5_000, 1));
        flags.apply(&archived_unread, &arch(true, 1));

        assert_eq!(unread_conversation_count(&convs, &flags), 1);

        // Marking the remaining one read empties the badge.
        flags.apply(&unread, &read(5_000, 1));
        assert_eq!(unread_conversation_count(&convs, &flags), 0);

        // And a conversation that never replied never counted.
        assert_eq!(convs.get(&never_replied).unwrap().last_reply_ms, 0);

        // A NEW reply on the read conversation makes it unread again.
        convs.note_reply(&read_one, 6_000);
        assert_eq!(unread_conversation_count(&convs, &flags), 1);
    }
}
