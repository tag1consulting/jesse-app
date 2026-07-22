use crate::*;

// ---- Durable per-session deletion tombstones -------------------------------
//
// A single JSON file `<state_dir>/deletions.json` mapping session_id ->
// deleted_ms (unix millis of an explicit delete). Deleting a session already
// reclaims its transcript, but a device that adopted that session earlier gets no
// signal and keeps a stale local copy. A tombstone is that signal: recorded on an
// explicit delete, exposed on `GET /jesse/sessions`, so every device converges on
// removals the same way they already converge on favorite and archived flags.
//
// A tombstone is recorded ONLY on the explicit delete route (`jesse_session_delete`),
// NEVER on age-based GC: a device that was merely offline while a session aged out
// must keep its local copy, so GC deliberately records nothing here.
//
// The file is kept bounded: tombstones older than the retention window are pruned
// on load and on every write. The window is the config session TTL (a device
// offline longer than the TTL would already have lost the session to GC, so a
// tombstone gains nothing past that point); `DEFAULT_DELETION_RETENTION_DAYS` is
// the fallback used only when no TTL is configured. Mirrors `FlagStore`'s
// discipline exactly: atomic temp+rename writes, mode 0600, best-effort (a write
// failure is logged, never fatal); with no state dir the store is in-memory only,
// the same degradation the job / device / title / flag stores have. Only a
// session_id and a millis timestamp are ever written; never conversation content.

/// Fallback retention window (days) for deletion tombstones, used only when the
/// config session TTL is zero / unset. The window is normally the session TTL:
/// a device offline longer than the TTL would already have lost the session to
/// GC, so a tombstone gains nothing past that horizon. One named constant so the
/// choice lives in exactly one place.
pub const DEFAULT_DELETION_RETENTION_DAYS: u64 = 30;

/// The retention window in unix millis for a given config session TTL (days).
/// Reuses the session TTL when it is set, otherwise falls back to
/// [`DEFAULT_DELETION_RETENTION_DAYS`]. Saturating so an absurd TTL can't overflow.
pub fn deletion_retention_ms(session_ttl_days: u64) -> u64 {
    let days = if session_ttl_days > 0 {
        session_ttl_days
    } else {
        DEFAULT_DELETION_RETENTION_DAYS
    };
    days.saturating_mul(24 * 60 * 60 * 1000)
}

/// One deletion tombstone as exposed on the sessions list: the deleted session's
/// id and the unix-millis time it was deleted.
#[derive(serde::Serialize, serde::Deserialize, Clone, PartialEq, Debug)]
pub struct Tombstone {
    pub session_id: String,
    pub deleted_ms: u64,
}

/// The session_id -> deleted_ms map. Cheaply shared behind an `Arc` in `AppState`.
pub struct DeletionStore {
    map: Mutex<HashMap<String, u64>>,
    // Where the map is persisted. `None` -> in-memory only.
    path: Option<PathBuf>,
    // Tombstones older than this (relative to a supplied "now") are pruned and are
    // never reported by `recent`.
    retention_ms: u64,
}

impl DeletionStore {
    /// Build the store, loading any tombstones left from a previous run when a path
    /// is configured, then pruning anything already past the retention window so a
    /// long-idle bridge starts bounded. An unreadable / absent / garbage file loads
    /// as empty (not an error).
    pub fn new(path: Option<PathBuf>, retention_ms: u64) -> Self {
        let mut map = path.as_deref().map(load_deletions).unwrap_or_default();
        let now_ms = system_time_to_ms(SystemTime::now());
        prune_map(&mut map, now_ms, retention_ms);
        DeletionStore {
            map: Mutex::new(map),
            path,
            retention_ms,
        }
    }

    /// Record (or refresh) a tombstone for a session at client-independent server
    /// time `now_ms` (unix millis), prune anything now past the window, and persist
    /// atomically when a state dir is configured. Idempotent: a second delete of the
    /// same id just updates the millis. A blank session_id is a no-op.
    pub fn record(&self, session_id: &str, now_ms: u64) {
        let session_id = session_id.trim();
        if session_id.is_empty() {
            return;
        }
        let snapshot = {
            let mut map = self.map.lock_ok();
            map.insert(session_id.to_string(), now_ms);
            // Prune on every write so `deletions.json` stays bounded.
            prune_map(&mut map, now_ms, self.retention_ms);
            map.clone()
        };
        if let Some(path) = &self.path {
            persist_deletions(path, &snapshot);
        }
    }

    /// The tombstones within the retention window as of `now_ms`, newest first
    /// (ties broken on session_id) for a stable, deterministic order — so the ETag
    /// the sessions handler computes over the body is stable across unchanged calls.
    /// Read-only: pruning happens on load and on write, not here.
    pub fn recent(&self, now_ms: u64) -> Vec<Tombstone> {
        let cutoff = now_ms.saturating_sub(self.retention_ms);
        let map = self.map.lock_ok();
        let mut out: Vec<Tombstone> = map
            .iter()
            .filter(|(_, &ms)| ms >= cutoff)
            .map(|(sid, &ms)| Tombstone {
                session_id: sid.clone(),
                deleted_ms: ms,
            })
            .collect();
        out.sort_by(|a, b| {
            b.deleted_ms
                .cmp(&a.deleted_ms)
                .then_with(|| a.session_id.cmp(&b.session_id))
        });
        out
    }

    /// Number of stored tombstones (including any not yet pruned). For
    /// tests / introspection only.
    pub fn len(&self) -> usize {
        self.map.lock_ok().len()
    }

    /// Whether the store holds no tombstones. For tests / introspection only.
    pub fn is_empty(&self) -> bool {
        self.map.lock_ok().is_empty()
    }
}

/// Drop tombstones strictly older than the retention window measured from `now_ms`
/// (i.e. `deleted_ms < now_ms - retention_ms`); a tombstone exactly at the horizon
/// is kept. Shared by load, write, and the `recent` cutoff so all three agree.
fn prune_map(map: &mut HashMap<String, u64>, now_ms: u64, retention_ms: u64) {
    let cutoff = now_ms.saturating_sub(retention_ms);
    map.retain(|_, &mut ms| ms >= cutoff);
}

/// Load the deletions map from disk, tolerating any corruption by returning what's
/// parseable (an unreadable / absent / garbage file -> empty map). A blank
/// session_id or a non-integer value is skipped rather than failing the whole load;
/// unknown top-level fields are ignored, so a file written by a future bridge with
/// extra fields loads cleanly (the additive-compat property).
pub fn load_deletions(path: &Path) -> HashMap<String, u64> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return HashMap::new();
    };
    let mut out = HashMap::new();
    if let Some(obj) = value.get("deletions").and_then(|d| d.as_object()) {
        for (sid, val) in obj {
            let sid = sid.trim();
            if sid.is_empty() {
                continue;
            }
            if let Some(ms) = val.as_u64() {
                out.insert(sid.to_string(), ms);
            }
        }
    }
    out
}

/// Persist the deletions map atomically (temp + rename), mode 0600, the same
/// discipline as `persist_flags`. Best-effort: a failure is logged, never fatal.
/// The parent dir is created if missing so the store works regardless of init order.
pub fn persist_deletions(path: &Path, deletions: &HashMap<String, u64>) {
    let value = json!({ "v": 1, "deletions": deletions });
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
        eprintln!("warning: could not persist deletions: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_deletions_path() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-deletions-{}/deletions.json", random_hex()))
    }

    // A generous window for tests where pruning must NOT fire.
    const WIDE_MS: u64 = 30 * 24 * 60 * 60 * 1000;

    #[test]
    fn record_then_recent_reports_the_tombstone() {
        let store = DeletionStore::new(None, WIDE_MS);
        assert!(store.is_empty());
        store.record("sess-a", 1000);
        let recent = store.recent(1000);
        assert_eq!(
            recent,
            vec![Tombstone {
                session_id: "sess-a".to_string(),
                deleted_ms: 1000
            }]
        );
    }

    #[test]
    fn blank_id_is_a_noop() {
        let store = DeletionStore::new(None, WIDE_MS);
        store.record("", 1000);
        store.record("   ", 1000);
        assert!(store.is_empty());
    }

    #[test]
    fn record_is_idempotent_and_refreshes_the_millis() {
        // A second delete of the same id just updates the timestamp — one row, newer ms.
        let store = DeletionStore::new(None, WIDE_MS);
        store.record("s", 100);
        store.record("s", 250);
        assert_eq!(store.len(), 1);
        assert_eq!(store.recent(250)[0].deleted_ms, 250);
    }

    #[test]
    fn survives_a_restart_record_drop_reload_read() {
        // Use a near-now timestamp so it survives load-time pruning (which is measured
        // against the real wall clock, not a synthetic value).
        let now = system_time_to_ms(SystemTime::now());
        let path = temp_deletions_path();
        {
            let store = DeletionStore::new(Some(path.clone()), WIDE_MS);
            store.record("sess-x", now);
            // store drops here; the file is already fsync'd + renamed by `record`.
        }
        // A fresh store over the same path reloads what was written.
        let reloaded = DeletionStore::new(Some(path.clone()), WIDE_MS);
        let recent = reloaded.recent(now);
        assert_eq!(recent.len(), 1);
        assert_eq!(recent[0].session_id, "sess-x");
        assert_eq!(recent[0].deleted_ms, now);

        // File is 0600.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "deletions.json must be 0600");

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn recent_prunes_and_bounds_to_the_window() {
        // A narrow 1000ms window: an old tombstone falls outside it, a fresh one stays.
        let store = DeletionStore::new(None, 1000);
        store.record("old", 100);
        store.record("fresh", 5000);
        // As of now=5000 the window is [4000, 5000]; "old" (100) is outside it.
        let recent = store.recent(5000);
        assert_eq!(recent.len(), 1, "only the in-window tombstone is reported");
        assert_eq!(recent[0].session_id, "fresh");
    }

    #[test]
    fn write_prunes_expired_rows_so_the_file_stays_bounded() {
        // Recording a fresh tombstone prunes ones already past the window from the
        // in-memory map (and thus from the persisted file). A 60s window with a
        // near-now "fresh" so it also survives the reload's wall-clock prune.
        let now = system_time_to_ms(SystemTime::now());
        let window = 60_000;
        let path = temp_deletions_path();
        let store = DeletionStore::new(Some(path.clone()), window);
        store.record("old", now.saturating_sub(120_000)); // outside the window
        assert_eq!(store.len(), 1);
        // Recording "fresh" at now prunes "old" (now-120000 < now-60000) in the same write.
        store.record("fresh", now);
        assert_eq!(store.len(), 1, "the expired row was pruned on write");
        // And the persisted file no longer carries the expired row.
        let reloaded = DeletionStore::new(Some(path.clone()), window);
        assert_eq!(reloaded.len(), 1);
        assert_eq!(reloaded.recent(now)[0].session_id, "fresh");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn load_prunes_expired_rows() {
        // A file carrying a very old tombstone loads pruned against real "now".
        let path = temp_deletions_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let now = system_time_to_ms(SystemTime::now());
        let fresh = now.saturating_sub(500);
        // window 1000ms; "old" at ms 1 is far outside it, "fresh" is inside.
        std::fs::write(
            &path,
            format!(r#"{{"v":1,"deletions":{{"old":1,"fresh":{fresh}}}}}"#),
        )
        .unwrap();
        let store = DeletionStore::new(Some(path.clone()), 1000);
        assert_eq!(store.len(), 1, "the expired row was pruned on load");
        assert_eq!(store.recent(now)[0].session_id, "fresh");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn recent_is_sorted_newest_first_with_stable_ties() {
        let store = DeletionStore::new(None, WIDE_MS);
        store.record("b", 200);
        store.record("a", 200); // tie on ms -> session_id ascending
        store.record("c", 300);
        let recent = store.recent(300);
        let ids: Vec<&str> = recent.iter().map(|t| t.session_id.as_str()).collect();
        assert_eq!(ids, vec!["c", "a", "b"]);
    }

    #[test]
    fn a_corrupt_file_loads_as_empty_not_an_error() {
        let path = temp_deletions_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "not json at all {").unwrap();
        let store = DeletionStore::new(Some(path.clone()), WIDE_MS);
        assert!(store.is_empty());
        // And it's usable: a record after a corrupt load still works and rewrites.
        let now = system_time_to_ms(SystemTime::now());
        store.record("s", now);
        let reloaded = DeletionStore::new(Some(path.clone()), WIDE_MS);
        assert_eq!(reloaded.recent(now).len(), 1);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn load_tolerates_unknown_fields_and_bad_values() {
        // Unknown top-level field ignored, non-integer value skipped, good row kept.
        // The good row carries a near-now ms so it survives the load-time prune.
        let now = system_time_to_ms(SystemTime::now());
        let path = temp_deletions_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            format!(r#"{{"v":1,"future":true,"deletions":{{"good":{now},"bad":"nope","":99}}}}"#),
        )
        .unwrap();
        let store = DeletionStore::new(Some(path.clone()), WIDE_MS);
        assert_eq!(store.len(), 1, "only the well-formed, non-blank row loads");
        assert_eq!(store.recent(now)[0].session_id, "good");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn retention_falls_back_when_ttl_is_zero() {
        assert_eq!(
            deletion_retention_ms(0),
            DEFAULT_DELETION_RETENTION_DAYS * 24 * 60 * 60 * 1000
        );
        assert_eq!(deletion_retention_ms(90), 90 * 24 * 60 * 60 * 1000);
    }
}
