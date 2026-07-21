use crate::*;

// ---- Server-side per-session favorite / archived flags ---------------------
//
// A single JSON file `<state_dir>/flags.json` mapping session_id -> SessionFlags,
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

/// The favorite / archived state for one session. Each flag carries the unix-millis
/// client change time it was last set at, so a write applies last-writer-wins.
/// Defaults to `false` / `0` for a session with no row, and every field is
/// `#[serde(default)]` so a missing or future field loads without error (an added
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
}

/// A write to the flags endpoint: any subset of the four fields. A flag is applied
/// only when its boolean value is present; its timestamp defaults to 0 when absent
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
}

/// The session_id -> flags map. Cheaply shared behind an `Arc` in `AppState`.
pub struct FlagStore {
    map: Mutex<HashMap<String, SessionFlags>>,
    // Where the map is persisted. `None` -> in-memory only.
    path: Option<PathBuf>,
}

impl FlagStore {
    /// Build the store, loading any flags left from a previous run when a path is
    /// configured. An unreadable/absent/garbage file loads as empty (not an error).
    pub fn new(path: Option<PathBuf>) -> Self {
        let map = path.as_deref().map(load_flags).unwrap_or_default();
        FlagStore {
            map: Mutex::new(map),
            path,
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
        let (result, changed, snapshot) = {
            let mut map = self.map.lock_ok();
            let entry = map.entry(session_id.to_string()).or_default();
            let mut changed = false;
            if let Some(value) = update.favorite {
                changed |= entry.apply_favorite(value, update.favorite_updated_ms.unwrap_or(0));
            }
            if let Some(value) = update.archived {
                changed |= entry.apply_archived(value, update.archived_updated_ms.unwrap_or(0));
            }
            let result = entry.clone();
            // Snapshot only when we will actually persist, to keep the lock hold tiny.
            let snapshot = if changed { Some(map.clone()) } else { None };
            (result, changed, snapshot)
        };
        if changed {
            if let (Some(path), Some(snapshot)) = (&self.path, snapshot) {
                persist_flags(path, &snapshot);
            }
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
        let snapshot = {
            let mut map = self.map.lock_ok();
            if map.remove(session_id).is_none() {
                return;
            }
            map.clone()
        };
        if let Some(path) = &self.path {
            persist_flags(path, &snapshot);
        }
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
        eprintln!("warning: could not persist flags: {e}");
        let _ = std::fs::remove_file(&tmp);
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
        assert!(r.favorite && r.favorite_updated_ms == 100, "older write ignored");

        // An EQUAL write (ts 100) is ignored too (strictly-newer only).
        let r = store.apply("s", &fav(false, 100));
        assert!(r.favorite && r.favorite_updated_ms == 100, "equal write ignored");

        // A strictly NEWER write (ts 101) wins.
        let r = store.apply("s", &fav(false, 101));
        assert!(!r.favorite && r.favorite_updated_ms == 101, "newer write wins");
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
        assert!(r.favorite && r.favorite_updated_ms == 100, "favorite untouched");
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
        assert_eq!(store.get("sess-a"), SessionFlags::default(), "removed row gone");
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
        assert!(!f.archived && f.archived_updated_ms == 0, "missing fields default");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
