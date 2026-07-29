use crate::*;

// ---- The global model selection store --------------------------------------
//
// A single JSON file `<state_dir>/model.json` holding the ACTIVE model id, so the choice
// of which model backs the conversation is the BRIDGE's (not one device's) and every
// device — iPhone, Mac — converges on one selection.
//
// It used to hold a per-model `writes` map too, set by `POST /jesse/model/{id}/writes`.
// Both are GONE: what a model may touch is its `level`, which lives in the bridge config
// and is validated at startup against the containment record. A leftover `writes` map in
// an existing file is dropped with one logged notice on first load (see `load_selection`)
// rather than silently ignored, because a persisted grant that stops being honored should
// say so once. Mirrors `FlagStore`'s discipline exactly: atomic
// temp+rename writes, mode 0600, best-effort (a write failure is logged, never fatal).
// With no state dir configured the store is in-memory only, the same degradation the
// job / device / title / flag stores have, so the selection resets to the default on
// restart in that mode.
//
// It NEVER holds a token, a base url, or any secret — only the active id and a map of
// booleans. The credentials for a hosted/local model live solely in the launch env
// (the `ModelRegistry`); this store just records which of those the user picked and
// whether they granted it write access.

/// The persisted selection: the active model id.
#[derive(serde::Serialize, serde::Deserialize, Clone, PartialEq, Debug)]
pub struct ModelSelection {
    /// The active model id. Defaults to [`DEFAULT_MODEL_ID`] (`opus`).
    pub active: String,
}

impl Default for ModelSelection {
    fn default() -> Self {
        ModelSelection {
            active: DEFAULT_MODEL_ID.to_string(),
        }
    }
}

/// The model-selection store. Cheaply shared behind an `Arc` in `AppState`.
pub struct ModelStore {
    state: Mutex<ModelSelection>,
    // Where the selection is persisted. `None` -> in-memory only.
    path: Option<PathBuf>,
}

impl ModelStore {
    /// Build the store, loading any selection left from a previous run when a path is
    /// configured. An unreadable/absent/garbage file loads as the default (`opus`, no
    /// overrides), never an error.
    pub fn new(path: Option<PathBuf>) -> Self {
        let state = path
            .as_deref()
            .and_then(load_selection)
            .unwrap_or_default();
        ModelStore {
            state: Mutex::new(state),
            path,
        }
    }

    /// The active model id.
    pub fn active(&self) -> String {
        self.state.lock_ok().active.clone()
    }

    /// A clone of the selection for the `GET /jesse/models` read path.
    pub fn snapshot(&self) -> ModelSelection {
        self.state.lock_ok().clone()
    }

    /// Set the active model id and persist. The CALLER is responsible for validating that
    /// the id names an available registry entry BEFORE calling this (the store holds only
    /// strings and cannot know the registry). A no-op write (same id) still persists
    /// harmlessly. Returns the id now active.
    pub fn set_active(&self, id: &str) -> String {
        let snapshot = {
            let mut state = self.state.lock_ok();
            state.active = id.to_string();
            state.clone()
        };
        if let Some(path) = &self.path {
            persist_selection(path, &snapshot);
        }
        snapshot.active
    }

}

/// Load the selection from disk, tolerating corruption by returning `None` (→ the
/// default). An unreadable/absent/garbage file, or one whose `active` is blank, yields
/// `None`. Unknown fields are ignored, so a file written by a future bridge loads cleanly
/// (additive-forward-compatible).
///
/// A leftover per-model `writes` map from a bridge that still had the toggle is DROPPED,
/// with one logged notice. Silently ignoring it would leave an operator believing a grant
/// they set is still in force; the notice says once that levels replaced it and where they
/// live now.
pub fn load_selection(path: &Path) -> Option<ModelSelection> {
    let text = std::fs::read_to_string(path).ok()?;
    if serde_json::from_str::<Value>(&text)
        .ok()
        .and_then(|v| v.get("writes").cloned())
        .map(|w| w.as_object().map(|m| !m.is_empty()).unwrap_or(false))
        .unwrap_or(false)
    {
        eprintln!(
            "jesse-bridge: NOTICE {} carries a per-model `writes` map from an older bridge.              The per-model writes toggle was removed; a model's `level` in the bridge config              now decides what it may touch. Dropping the stored overrides.",
            path.display()
        );
    }
    let mut sel = serde_json::from_str::<ModelSelection>(&text).ok()?;
    sel.active = sel.active.trim().to_string();
    if sel.active.is_empty() {
        return None;
    }
    Some(sel)
}

/// Persist the selection atomically (temp + rename), mode 0600, the same discipline as
/// `persist_flags`. Best-effort: a failure is logged, never fatal. The parent dir is
/// created if missing so the store works regardless of init order.
pub fn persist_selection(path: &Path, selection: &ModelSelection) {
    let value = json!({ "v": 1, "active": selection.active });
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
        eprintln!("warning: could not persist model selection: {e}");
        let _ = std::fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_model_path() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-model-{}/model.json", random_hex()))
    }

    #[test]
    fn fresh_store_defaults_to_opus_with_no_overrides() {
        let store = ModelStore::new(None);
        assert_eq!(store.active(), "opus");
        assert_eq!(store.snapshot().active, "opus");
    }

    #[test]
    fn set_active_round_trips_in_memory() {
        let store = ModelStore::new(None);
        assert_eq!(store.set_active("glm-5.2"), "glm-5.2");
        assert_eq!(store.active(), "glm-5.2");
    }

    /// A file written by a bridge that still had the writes toggle: the selection still
    /// loads, and the stale grants are dropped rather than honored.
    #[test]
    fn a_leftover_writes_map_is_dropped_and_the_selection_still_loads() {
        let path = temp_model_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            r#"{"v":1,"active":"glm-5.2","writes":{"glm-5.2":true}}"#,
        )
        .unwrap();
        let store = ModelStore::new(Some(path.clone()));
        assert_eq!(store.active(), "glm-5.2", "the active id still loads");
        // Re-persisting drops the map from disk entirely.
        store.set_active("local");
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(!text.contains("writes"), "{text}");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn survives_a_restart_write_drop_reload_read() {
        let path = temp_model_path();
        {
            let store = ModelStore::new(Some(path.clone()));
            store.set_active("glm-5.2");
        }
        let reloaded = ModelStore::new(Some(path.clone()));
        assert_eq!(reloaded.active(), "glm-5.2");

        // File is 0600.
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "model.json must be 0600");

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_corrupt_file_loads_as_the_default_not_an_error() {
        let path = temp_model_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "not json at all {").unwrap();
        let store = ModelStore::new(Some(path.clone()));
        assert_eq!(store.active(), "opus", "corrupt → default");
        // And it's usable: a set after a corrupt load still persists.
        store.set_active("local");
        let reloaded = ModelStore::new(Some(path.clone()));
        assert_eq!(reloaded.active(), "local");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    #[test]
    fn a_blank_active_field_loads_as_the_default() {
        let path = temp_model_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, r#"{"v":1,"active":"   "}"#).unwrap();
        let store = ModelStore::new(Some(path.clone()));
        assert_eq!(store.active(), "opus", "blank active → default");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
