use crate::*;

// ---- The global model selection store --------------------------------------
//
// A single JSON file `<state_dir>/model.json` holding the ACTIVE model id and the
// per-model `writes_allowed` overrides, so the choice of which model backs the
// conversation is the BRIDGE's (not one device's) and every device — iPhone, Mac —
// converges on one selection. Mirrors `FlagStore`'s discipline exactly: atomic
// temp+rename writes, mode 0600, best-effort (a write failure is logged, never fatal).
// With no state dir configured the store is in-memory only, the same degradation the
// job / device / title / flag stores have, so the selection resets to the default on
// restart in that mode.
//
// It NEVER holds a token, a base url, or any secret — only the active id and a map of
// booleans. The credentials for a hosted/local model live solely in the launch env
// (the `ModelRegistry`); this store just records which of those the user picked and
// whether they granted it write access.

/// The persisted selection: the active model id and the per-model write overrides.
#[derive(serde::Serialize, serde::Deserialize, Clone, PartialEq, Debug)]
pub struct ModelSelection {
    /// The active model id. Defaults to [`DEFAULT_MODEL_ID`] (`opus`).
    pub active: String,
    /// Per-model write overrides. A model absent from the map has no override and takes
    /// its registry `default_writes` (opus always writes-on; every other model default
    /// OFF). Only ever set by `POST /jesse/model/{id}/writes` (Phase 2 wires the effect).
    #[serde(default)]
    pub writes: HashMap<String, bool>,
}

impl Default for ModelSelection {
    fn default() -> Self {
        ModelSelection {
            active: DEFAULT_MODEL_ID.to_string(),
            writes: HashMap::new(),
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

    /// The stored write override for a model, or `None` when it has none (then the
    /// registry default applies). Used to compute a model's effective write permission.
    pub fn writes_override(&self, id: &str) -> Option<bool> {
        self.state.lock_ok().writes.get(id).copied()
    }

    /// A clone of the whole selection (active + overrides) for the `GET /jesse/models`
    /// read path.
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

    /// Set (or clear) a model's write override and persist. `enabled` records an explicit
    /// override; the registry default applies to any model with no override. Returns the
    /// stored value.
    pub fn set_writes(&self, id: &str, enabled: bool) -> bool {
        let snapshot = {
            let mut state = self.state.lock_ok();
            state.writes.insert(id.to_string(), enabled);
            state.clone()
        };
        if let Some(path) = &self.path {
            persist_selection(path, &snapshot);
        }
        enabled
    }
}

/// Load the selection from disk, tolerating corruption by returning `None` (→ the
/// default). An unreadable/absent/garbage file, or one whose `active` is blank, yields
/// `None`. Unknown fields are ignored and a missing `writes` defaults to empty, so a
/// file written by a future bridge loads cleanly (additive-forward-compatible).
pub fn load_selection(path: &Path) -> Option<ModelSelection> {
    let text = std::fs::read_to_string(path).ok()?;
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
    let value = json!({ "v": 1, "active": selection.active, "writes": selection.writes });
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
        assert_eq!(store.writes_override("glm-5.2"), None);
        assert!(store.snapshot().writes.is_empty());
    }

    #[test]
    fn set_active_and_writes_round_trip_in_memory() {
        let store = ModelStore::new(None);
        assert_eq!(store.set_active("glm-5.2"), "glm-5.2");
        assert_eq!(store.active(), "glm-5.2");
        assert!(store.set_writes("glm-5.2", true));
        assert_eq!(store.writes_override("glm-5.2"), Some(true));
        // An unrelated model still has no override.
        assert_eq!(store.writes_override("local"), None);
    }

    #[test]
    fn survives_a_restart_write_drop_reload_read() {
        let path = temp_model_path();
        {
            let store = ModelStore::new(Some(path.clone()));
            store.set_active("glm-5.2");
            store.set_writes("glm-5.2", true);
        }
        let reloaded = ModelStore::new(Some(path.clone()));
        assert_eq!(reloaded.active(), "glm-5.2");
        assert_eq!(reloaded.writes_override("glm-5.2"), Some(true));

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
        std::fs::write(&path, r#"{"v":1,"active":"   ","writes":{}}"#).unwrap();
        let store = ModelStore::new(Some(path.clone()));
        assert_eq!(store.active(), "opus", "blank active → default");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
