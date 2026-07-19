use crate::*;

// ---- Server-side session title store ---------------------------------------
//
// A single JSON file `<state_dir>/titles.json` mapping session_id → title, so a
// conversation's minted title survives a bridge restart and `GET /jesse/sessions`
// can show it. Mirrors `DeviceStore`'s discipline exactly: atomic temp+rename
// writes, mode 0600, best-effort (a write failure is logged, never fatal). With
// no state dir configured the store is in-memory only — the same degradation the
// job store and device store have — so titles are lost on restart in that mode.
// Only the title text is ever written; never a secret.

/// The session_id → title map. Cheaply shared behind an `Arc` in `AppState`.
pub struct TitleStore {
    map: Mutex<HashMap<String, String>>,
    // Where the map is persisted. `None` → in-memory only.
    path: Option<PathBuf>,
}

impl TitleStore {
    /// Build the store, loading any titles left from a previous run when a path is
    /// configured. An unreadable/absent file loads as empty (not an error).
    pub fn new(path: Option<PathBuf>) -> Self {
        let map = path.as_deref().map(load_titles).unwrap_or_default();
        TitleStore {
            map: Mutex::new(map),
            path,
        }
    }

    /// Upsert a title for a session and persist (atomically) when a state dir is
    /// configured. Defensive at the boundary: the session_id and title are trimmed
    /// and the title is clamped to `MAX_TITLE_CHARS` chars (the sanitizer already
    /// bounds it upstream; enforce here too so a store call can never grow the file
    /// with an oversized value). An empty session_id or title is a no-op.
    pub fn set(&self, session_id: &str, title: &str) {
        let session_id = session_id.trim();
        let title = truncate_chars(title.trim(), MAX_TITLE_CHARS);
        if session_id.is_empty() || title.is_empty() {
            return;
        }
        // Snapshot under the lock, persist off it (mirrors the device store).
        let snapshot = {
            let mut map = self.map.lock_ok();
            map.insert(session_id.to_string(), title);
            map.clone()
        };
        if let Some(path) = &self.path {
            persist_titles(path, &snapshot);
        }
    }

    /// The stored title for a session, if any.
    pub fn get(&self, session_id: &str) -> Option<String> {
        self.map.lock_ok().get(session_id).cloned()
    }

    /// Move a title from `from` to `to`, then persist (context carry): when a fresh
    /// locally-served thread's synthetic id becomes a real claude session id on its first
    /// hosted turn, its title must follow. Overwrites any title already under `to`. A
    /// no-op when `from == to`, `from` has no title, or `from`/`to` is empty.
    pub fn rename(&self, from: &str, to: &str) {
        let from = from.trim();
        let to = to.trim();
        if from.is_empty() || to.is_empty() || from == to {
            return;
        }
        let snapshot = {
            let mut map = self.map.lock_ok();
            let Some(title) = map.remove(from) else {
                return;
            };
            map.insert(to.to_string(), title);
            map.clone()
        };
        if let Some(path) = &self.path {
            persist_titles(path, &snapshot);
        }
    }

    /// Drop the title for a session and persist, if one was stored (session
    /// delete / GC reclaim: a reclaimed session's transcript is gone, so its
    /// stashed title must not linger in `titles.json` and re-surface). A no-op
    /// (no write) when the session has no title or the id is blank.
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
            persist_titles(path, &snapshot);
        }
    }

    /// Number of stored titles. For tests/introspection only.
    pub fn len(&self) -> usize {
        self.map.lock_ok().len()
    }

    /// Whether the store holds no titles. For tests/introspection only.
    pub fn is_empty(&self) -> bool {
        self.map.lock_ok().is_empty()
    }
}

/// Load the title map from disk, tolerating any corruption by returning what's
/// parseable (an unreadable/absent/garbage file → empty map). Applies the same
/// trim + `MAX_TITLE_CHARS` clamp as `set`, so a hand-edited or older file can't
/// smuggle in an oversized or blank title.
pub fn load_titles(path: &Path) -> HashMap<String, String> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return HashMap::new();
    };
    let Ok(value) = serde_json::from_str::<Value>(&text) else {
        return HashMap::new();
    };
    let mut out = HashMap::new();
    if let Some(obj) = value.get("titles").and_then(|t| t.as_object()) {
        for (sid, val) in obj {
            let sid = sid.trim();
            if sid.is_empty() {
                continue;
            }
            if let Some(title) = val.as_str() {
                let title = truncate_chars(title.trim(), MAX_TITLE_CHARS);
                if !title.is_empty() {
                    out.insert(sid.to_string(), title);
                }
            }
        }
    }
    out
}

/// Persist the title map atomically (temp + rename), mode 0600 — same discipline
/// as `persist_device_token`. Best-effort: a failure is logged, never fatal. The
/// parent dir is created if missing so the store works regardless of init order.
pub fn persist_titles(path: &Path, titles: &HashMap<String, String>) {
    let value = json!({ "v": 1, "titles": titles });
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
        eprintln!("warning: could not persist titles: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_titles_path() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-titles-{}/titles.json", random_hex()))
    }

    #[test]
    fn in_memory_store_upserts_and_reads_back() {
        let store = TitleStore::new(None);
        assert_eq!(store.get("sess-a"), None);
        store.set("sess-a", "Weekend Trip Planning");
        store.set("sess-b", "Roof Repair Notes");
        assert_eq!(
            store.get("sess-a").as_deref(),
            Some("Weekend Trip Planning")
        );
        assert_eq!(store.get("sess-b").as_deref(), Some("Roof Repair Notes"));
        // Upsert overwrites.
        store.set("sess-a", "New Title");
        assert_eq!(store.get("sess-a").as_deref(), Some("New Title"));
        assert_eq!(store.len(), 2);
    }

    #[test]
    fn empty_session_or_title_is_a_noop() {
        let store = TitleStore::new(None);
        store.set("", "has a title");
        store.set("sess", "   ");
        assert_eq!(store.len(), 0);
    }

    #[test]
    fn title_is_clamped_at_the_store_boundary() {
        let store = TitleStore::new(None);
        let long = "x".repeat(MAX_TITLE_CHARS + 50);
        store.set("sess", &long);
        let got = store.get("sess").unwrap();
        assert_eq!(
            got.chars().count(),
            MAX_TITLE_CHARS,
            "the store clamps an oversized title defensively"
        );
    }

    #[test]
    fn rename_moves_a_title_from_synthetic_to_real_id() {
        // Context carry: a fresh local thread's synthetic id becomes a real session id on
        // its first hosted turn; its title must follow.
        let store = TitleStore::new(None);
        store.set("local-abc", "Jamie's Birthday");
        store.rename("local-abc", "real-sess-1");
        assert_eq!(store.get("local-abc"), None, "old key cleared");
        assert_eq!(
            store.get("real-sess-1").as_deref(),
            Some("Jamie's Birthday")
        );
        // No-ops: same id, missing source, empty ids.
        store.rename("real-sess-1", "real-sess-1");
        assert_eq!(
            store.get("real-sess-1").as_deref(),
            Some("Jamie's Birthday")
        );
        store.rename("ghost", "real-sess-1");
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn remove_drops_a_title_and_is_a_noop_when_absent() {
        // Session delete / GC reclaim: a reclaimed session's stashed title must not
        // linger. Removing a stored title clears it; removing an unknown/blank id
        // is a harmless no-op.
        let store = TitleStore::new(None);
        store.set("sess-a", "Weekend Trip");
        store.set("sess-b", "Roof Notes");
        store.remove("sess-a");
        assert_eq!(store.get("sess-a"), None, "removed title is gone");
        assert_eq!(store.get("sess-b").as_deref(), Some("Roof Notes"), "others untouched");
        // No-ops.
        store.remove("ghost");
        store.remove("");
        assert_eq!(store.len(), 1);
    }

    #[test]
    fn survives_a_restart_write_drop_reload_read() {
        let path = temp_titles_path();
        {
            let store = TitleStore::new(Some(path.clone()));
            store.set("sess-x", "Persisted Title");
            // store drops here — the file is already fsync'd + renamed by `set`.
        }
        // A fresh store over the same path reloads what was written.
        let reloaded = TitleStore::new(Some(path.clone()));
        assert_eq!(reloaded.get("sess-x").as_deref(), Some("Persisted Title"));

        // File is 0600.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "titles.json must be 0600");

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_corrupt_file_loads_as_empty_not_an_error() {
        let path = temp_titles_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "not json at all {").unwrap();
        let store = TitleStore::new(Some(path.clone()));
        assert_eq!(store.len(), 0);
        // And it's usable — a set after a corrupt load still works and rewrites.
        store.set("sess", "Recovered");
        let reloaded = TitleStore::new(Some(path.clone()));
        assert_eq!(reloaded.get("sess").as_deref(), Some("Recovered"));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
