//! The speech models: which are known good, which are installed, and how a better one takes
//! over without ever leaving the Studio with none.
//!
//! # Where they live
//!
//! `<state_dir>/speech-models/`, a sibling of `jobs/` and `artifacts/`. The weights are
//! hundreds of megabytes to three gigabytes — far too large for any binary — so the bridge
//! downloads them on FIRST NEED, verifies them against a checksum pinned in this file, and
//! reuses what is already there. The record of what is installed is
//! `speech-models/models.json`, written with the discipline `crate::modelstore` uses for the
//! active-model selection: atomic temp-and-rename, mode 0600, best-effort, and a corrupt or
//! absent file loading as "nothing installed" rather than as an error.
//!
//! # The one fetch
//!
//! Downloading weights is the one network request this feature makes, the same category of
//! traffic as the phone fetching Apple's speech model: a body-less GET for a URL written in
//! this file, to the model's distribution host. [`ModelFetcher::fetch`] takes a catalog entry
//! and a destination path and nothing else, so no recording has a path into it.
//!
//! # What "better" means
//!
//! NOT "whatever is newest upstream". A regressed upstream release must not auto-install, so
//! the bridge consults [`known_good`], a list reviewed and shipped with the bridge, in which
//! each entry carries a tier, a rank and a pinned SHA-256. For each tier the TARGET is the
//! highest-ranked entry. The weekly check (a scheduled occurrence of the built-in scheduler,
//! so it lands as ran / failed / skipped like every other job) installs the target when it is
//! not installed, and so a better model reaches the Studio the week after a bridge release
//! adds it to the list. Bytes whose checksum differs from the pin are refused, whatever the
//! host serves.
//!
//! # Never with none
//!
//! A new model replaces the one in use only after it has downloaded, verified AND LOADED. Until
//! then the previous model keeps serving; if the new one fails any of the three, it is removed
//! and the previous stays. The superseded model is retired (its file deleted) by the weekly
//! check, and only once its replacement is installed and loadable.

use super::engine::{EngineLoader, ProgressFn, SpeechEngine};
use crate::*;
use tokio::io::AsyncWriteExt;

/// The two tiers a model can serve. The configured tier makes the PRIMARY reading; the other
/// tier makes the second reading, when there is one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SpeechTier {
    /// The most accurate model that finishes in reasonable time on the Studio. The default,
    /// because the Studio is not battery-bound.
    Accurate,
    /// A faster model, for when minutes matter more than the last few names.
    Fast,
}

impl SpeechTier {
    pub fn parse(raw: &str) -> Option<SpeechTier> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "accurate" | "best" => Some(SpeechTier::Accurate),
            "fast" => Some(SpeechTier::Fast),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            SpeechTier::Accurate => "accurate",
            SpeechTier::Fast => "fast",
        }
    }

    pub fn other(self) -> SpeechTier {
        match self {
            SpeechTier::Accurate => SpeechTier::Fast,
            SpeechTier::Fast => SpeechTier::Accurate,
        }
    }
}

/// One entry on the known-good list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogEntry {
    pub id: String,
    pub label: String,
    /// The file's name in the models directory.
    pub file: String,
    pub url: String,
    /// The pinned SHA-256, lowercase hex.
    pub sha256: String,
    pub bytes: u64,
    pub tier: SpeechTier,
    /// Higher is better, within a tier.
    pub rank: u32,
}

/// The host every known-good model is fetched from.
pub const DISTRIBUTION_HOST: &str = "huggingface.co";

/// THE KNOWN-GOOD LIST.
///
/// Sizes and checksums were read from the distribution host's own LFS metadata and then
/// confirmed by downloading both files on the Studio and hashing them (2026-09-11). Speeds are
/// that machine's, M3 Ultra with Metal, on a 41-second test recording: `large-v3` at 0.055 of
/// real time and `large-v3-turbo` at 0.02 — about 2.6 and 1 minute for a 47-minute recording.
/// Adding a model here is a reviewed change, and it is the ONLY way a new model reaches the
/// Studio.
pub fn known_good() -> Vec<CatalogEntry> {
    vec![
        CatalogEntry {
            id: "whisper-large-v3".to_string(),
            label: "Whisper large-v3".to_string(),
            file: "ggml-large-v3.bin".to_string(),
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"
                .to_string(),
            sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2".to_string(),
            bytes: 3_095_033_483,
            tier: SpeechTier::Accurate,
            rank: 30,
        },
        CatalogEntry {
            id: "whisper-large-v3-turbo".to_string(),
            label: "Whisper large-v3 turbo".to_string(),
            file: "ggml-large-v3-turbo.bin".to_string(),
            url:
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
                    .to_string(),
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69".to_string(),
            bytes: 1_624_555_275,
            tier: SpeechTier::Fast,
            rank: 20,
        },
    ]
}

/// The best entry for a tier: the target the check installs.
pub fn target_in(catalog: &[CatalogEntry], tier: SpeechTier) -> Option<&CatalogEntry> {
    catalog
        .iter()
        .filter(|e| e.tier == tier)
        .max_by_key(|e| e.rank)
}

// ---- The record ---------------------------------------------------------------------

/// The record's file name inside the models directory.
pub const RECORD_FILE: &str = "models.json";

#[derive(serde::Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct ModelRecord {
    #[serde(default)]
    pub installed: Vec<InstalledModel>,
    #[serde(default)]
    pub last_check: Option<CheckRecord>,
}

/// A model that downloaded, verified and loaded.
#[derive(serde::Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct InstalledModel {
    pub id: String,
    pub file: String,
    pub sha256: String,
    pub installed_ms: u64,
}

/// The last weekly check, as the record keeps it.
#[derive(serde::Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct CheckRecord {
    pub at_ms: u64,
    pub ok: bool,
    pub summary: String,
}

/// Load the record, tolerating anything: absent, unreadable or garbage is "nothing installed".
pub fn load_record(path: &Path) -> ModelRecord {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

/// Persist the record atomically, 0600. Best-effort: a failure is logged, never fatal.
pub fn persist_record(path: &Path, record: &ModelRecord) {
    let value = json!({
        "v": 1,
        "installed": record.installed,
        "last_check": record.last_check,
    });
    if let Err(e) = write_atomic(path, value.to_string().as_bytes()) {
        eprintln!("warning: could not persist the speech model record: {e}");
    }
}

/// SHA-256 of a file, lowercase hex, read in 1 MiB blocks.
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buf = vec![0u8; 1024 * 1024];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
    }
    Ok(hex(ctx.finish().as_ref()))
}

/// SHA-256 of bytes, lowercase hex.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(ring::digest::digest(&ring::digest::SHA256, bytes).as_ref())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ---- The fetch ----------------------------------------------------------------------

pub type FetchFuture<'a> = Pin<Box<dyn Future<Output = Result<(), String>> + Send + 'a>>;

/// Downloads one known-good model.
pub trait ModelFetcher: Send + Sync {
    /// Write `entry`'s bytes to `dest`, a path that does not exist yet. Implementations send a
    /// body-less GET for `entry.url` and nothing else; verification is the caller's.
    fn fetch<'a>(
        &'a self,
        entry: &'a CatalogEntry,
        dest: &'a Path,
        progress: ProgressFn,
    ) -> FetchFuture<'a>;
}

/// The real fetcher: reqwest (rustls), streaming to disk, refusing more bytes than the list
/// declares.
pub struct HttpFetcher {
    client: reqwest::Client,
}

impl Default for HttpFetcher {
    fn default() -> Self {
        HttpFetcher {
            client: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
        }
    }
}

fn host_of(url: &str) -> &str {
    url.split("://")
        .nth(1)
        .and_then(|rest| rest.split('/').next())
        .unwrap_or(url)
}

impl ModelFetcher for HttpFetcher {
    fn fetch<'a>(
        &'a self,
        entry: &'a CatalogEntry,
        dest: &'a Path,
        progress: ProgressFn,
    ) -> FetchFuture<'a> {
        Box::pin(async move {
            let host = host_of(&entry.url);
            let mut resp = self
                .client
                .get(&entry.url)
                .send()
                .await
                .map_err(|e| format!("could not reach {host}: {e}"))?;
            if !resp.status().is_success() {
                return Err(format!(
                    "{host} answered {} for {}",
                    resp.status(),
                    entry.file
                ));
            }
            let mut file = tokio::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(dest)
                .await
                .map_err(|e| format!("could not create {}: {e}", dest.display()))?;
            let mut got = 0u64;
            while let Some(chunk) = resp
                .chunk()
                .await
                .map_err(|e| format!("the download from {host} broke off: {e}"))?
            {
                got += chunk.len() as u64;
                if got > entry.bytes {
                    return Err(format!(
                        "{host} sent more than the {} bytes the known-good list pins for {}",
                        entry.bytes, entry.label
                    ));
                }
                file.write_all(&chunk)
                    .await
                    .map_err(|e| format!("could not write {}: {e}", dest.display()))?;
                progress(got as f64 / entry.bytes.max(1) as f64);
            }
            file.sync_all()
                .await
                .map_err(|e| format!("could not flush {}: {e}", dest.display()))?;
            Ok(())
        })
    }
}

// ---- The manager --------------------------------------------------------------------

/// What a reading at a tier can use right now.
#[derive(Debug, Clone, PartialEq)]
pub enum Readiness {
    /// The target is installed.
    Ready(CatalogEntry),
    /// The target must be installed first; `fallback` is the best installed model of the
    /// tier, used if the install fails.
    NeedsInstall {
        target: CatalogEntry,
        fallback: Option<CatalogEntry>,
    },
}

/// What one weekly check did.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct CheckReport {
    pub installed: Vec<String>,
    pub retired: Vec<String>,
    pub current: Vec<String>,
    pub failures: Vec<String>,
}

impl CheckReport {
    /// Whether anything on disk changed — an upgrade to announce.
    pub fn changed(&self) -> bool {
        !self.installed.is_empty() || !self.retired.is_empty()
    }

    pub fn summary(&self) -> String {
        let mut parts = Vec::new();
        if !self.installed.is_empty() {
            parts.push(format!("installed {}", self.installed.join(", ")));
        }
        if !self.retired.is_empty() {
            parts.push(format!("retired {}", self.retired.join(", ")));
        }
        if !self.current.is_empty() {
            parts.push(format!("current: {}", self.current.join(", ")));
        }
        if !self.failures.is_empty() {
            parts.push(format!("failed: {}", self.failures.join("; ")));
        }
        parts.join("; ")
    }
}

/// The models on this machine.
pub struct ModelManager {
    dir: Option<PathBuf>,
    catalog: Vec<CatalogEntry>,
    record: Mutex<ModelRecord>,
    writer: SnapshotWriter,
    /// One install at a time: a transcription's first-need download and the weekly check may
    /// race for the same model, and the second must find it installed rather than fetch it
    /// again.
    install_lock: tokio::sync::Mutex<()>,
    fetcher: Arc<dyn ModelFetcher>,
    loader: Arc<dyn EngineLoader>,
    engines: Mutex<HashMap<String, Arc<dyn SpeechEngine>>>,
}

fn no_dir() -> String {
    "this bridge has no state dir, so there is nowhere to keep speech models (set \
     JESSE_STATE_DIR)"
        .to_string()
}

impl ModelManager {
    pub fn new(
        dir: Option<PathBuf>,
        catalog: Vec<CatalogEntry>,
        fetcher: Arc<dyn ModelFetcher>,
        loader: Arc<dyn EngineLoader>,
    ) -> Self {
        let mut record = dir
            .as_deref()
            .map(|d| load_record(&d.join(RECORD_FILE)))
            .unwrap_or_default();
        if let Some(d) = dir.as_deref() {
            // A recorded model whose file is gone, or the wrong size, was lost or truncated
            // behind the bridge's back. Forget it; the next need installs it again. A file for
            // an entry no longer on the list is kept on the record, so the weekly check can
            // retire it deliberately.
            record.installed.retain(|m| {
                let expected = catalog.iter().find(|e| e.id == m.id).map(|e| e.bytes);
                match std::fs::metadata(d.join(&m.file)) {
                    Ok(md) => expected.is_none_or(|b| md.len() == b),
                    Err(_) => false,
                }
            });
            sweep_partials(d);
        }
        ModelManager {
            dir,
            catalog,
            record: Mutex::new(record),
            writer: SnapshotWriter::new(),
            install_lock: tokio::sync::Mutex::new(()),
            fetcher,
            loader,
            engines: Mutex::new(HashMap::new()),
        }
    }

    pub fn available(&self) -> bool {
        self.dir.is_some()
    }

    pub fn target(&self, tier: SpeechTier) -> Option<&CatalogEntry> {
        target_in(&self.catalog, tier)
    }

    pub fn is_installed(&self, id: &str) -> bool {
        self.record.lock_ok().installed.iter().any(|m| m.id == id)
    }

    /// The best INSTALLED model of a tier that is still on the list.
    fn best_installed(&self, tier: SpeechTier) -> Option<CatalogEntry> {
        let installed: Vec<String> = self
            .record
            .lock_ok()
            .installed
            .iter()
            .map(|m| m.id.clone())
            .collect();
        self.catalog
            .iter()
            .filter(|e| e.tier == tier && installed.contains(&e.id))
            .max_by_key(|e| e.rank)
            .cloned()
    }

    pub fn readiness(&self, tier: SpeechTier) -> Result<Readiness, String> {
        if self.dir.is_none() {
            return Err(no_dir());
        }
        let target = self
            .target(tier)
            .cloned()
            .ok_or_else(|| format!("the known-good list names no {} model", tier.label()))?;
        if self.is_installed(&target.id) {
            Ok(Readiness::Ready(target))
        } else {
            Ok(Readiness::NeedsInstall {
                fallback: self.best_installed(tier),
                target,
            })
        }
    }

    /// A loaded engine for an INSTALLED entry. Loaded once and kept, so the second recording
    /// of the day does not pay for the model load again.
    pub async fn engine(&self, entry: &CatalogEntry) -> Result<Arc<dyn SpeechEngine>, String> {
        if let Some(e) = self.engines.lock_ok().get(&entry.id) {
            return Ok(e.clone());
        }
        let dir = self.dir.clone().ok_or_else(no_dir)?;
        let loaded = self.load(entry, dir.join(&entry.file)).await?;
        self.engines
            .lock_ok()
            .insert(entry.id.clone(), loaded.clone());
        Ok(loaded)
    }

    async fn load(
        &self,
        entry: &CatalogEntry,
        path: PathBuf,
    ) -> Result<Arc<dyn SpeechEngine>, String> {
        let loader = self.loader.clone();
        let entry = entry.clone();
        tokio::task::spawn_blocking(move || loader.load(&entry, &path))
            .await
            .map_err(|e| format!("the model load stopped unexpectedly ({e})"))?
    }

    /// Install `entry`: download it (or adopt a copy already on disk), verify it against the
    /// pinned size and checksum, and LOAD it — and only then record it. A no-op when it is
    /// already installed.
    pub async fn install(&self, entry: &CatalogEntry, progress: ProgressFn) -> Result<(), String> {
        let _one_at_a_time = self.install_lock.lock().await;
        if self.is_installed(&entry.id) {
            return Ok(());
        }
        let dir = self.dir.clone().ok_or_else(no_dir)?;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir)
            .map_err(|e| format!("could not create {}: {e}", dir.display()))?;
        let dest = dir.join(&entry.file);
        if dest.is_file() {
            // A copy already on disk — seeded by hand, or installed before the record was
            // lost — is adopted if and only if it verifies.
            if let Err(e) = verify(&dest, entry).await {
                let _ = std::fs::remove_file(&dest);
                return Err(format!(
                    "{e}; the file was removed and the next attempt downloads a fresh copy"
                ));
            }
        } else {
            let partial = dir.join(format!(".{}.{}.partial", entry.file, random_hex()));
            let fetched = match self.fetcher.fetch(entry, &partial, progress).await {
                Ok(()) => verify(&partial, entry).await,
                Err(e) => Err(e),
            };
            if let Err(e) = fetched {
                let _ = std::fs::remove_file(&partial);
                return Err(e);
            }
            if let Err(e) = std::fs::rename(&partial, &dest) {
                let _ = std::fs::remove_file(&partial);
                return Err(format!(
                    "could not move the verified download into place: {e}"
                ));
            }
        }
        let engine = match self.load(entry, dest.clone()).await {
            Ok(e) => e,
            Err(e) => {
                let _ = std::fs::remove_file(&dest);
                return Err(format!(
                    "{} verified but did not load ({e}); the model in use was kept",
                    entry.label
                ));
            }
        };
        self.engines.lock_ok().insert(entry.id.clone(), engine);
        {
            let mut r = self.record.lock_ok();
            r.installed.retain(|m| m.id != entry.id);
            r.installed.push(InstalledModel {
                id: entry.id.clone(),
                file: entry.file.clone(),
                sha256: entry.sha256.clone(),
                installed_ms: system_time_to_ms(SystemTime::now()),
            });
        }
        self.persist();
        eprintln!(
            "jesse-bridge: speech model INSTALLED {} ({} MB, checksum verified, loaded)",
            entry.id,
            entry.bytes / (1024 * 1024)
        );
        Ok(())
    }

    /// Retire every installed model of `tier` other than its target — only once the target is
    /// installed, which is what keeps a failed upgrade from leaving the tier empty.
    fn retire_superseded(&self, tier: SpeechTier) -> Vec<String> {
        let Some(target) = self.target(tier).cloned() else {
            return Vec::new();
        };
        if !self.is_installed(&target.id) {
            return Vec::new();
        }
        let doomed: Vec<String> = self
            .catalog
            .iter()
            .filter(|e| e.tier == tier && e.id != target.id && self.is_installed(&e.id))
            .map(|e| e.id.clone())
            .collect();
        doomed.iter().filter_map(|id| self.retire(id)).collect()
    }

    /// Retire every installed model that is no longer on the list.
    fn retire_unlisted(&self) -> Vec<String> {
        let unlisted: Vec<String> = self
            .record
            .lock_ok()
            .installed
            .iter()
            .filter(|m| !self.catalog.iter().any(|e| e.id == m.id))
            .map(|m| m.id.clone())
            .collect();
        unlisted.iter().filter_map(|id| self.retire(id)).collect()
    }

    fn retire(&self, id: &str) -> Option<String> {
        let dir = self.dir.as_deref()?;
        let removed = {
            let mut r = self.record.lock_ok();
            let pos = r.installed.iter().position(|m| m.id == id)?;
            r.installed.remove(pos)
        };
        let _ = std::fs::remove_file(dir.join(&removed.file));
        self.engines.lock_ok().remove(id);
        self.persist();
        eprintln!("jesse-bridge: speech model RETIRED {id}");
        Some(
            self.catalog
                .iter()
                .find(|e| e.id == id)
                .map(|e| e.label.clone())
                .unwrap_or_else(|| id.to_string()),
        )
    }

    /// THE WEEKLY CHECK: make each tier's target installed, then retire what it supersedes.
    pub async fn check(&self, tiers: &[SpeechTier]) -> CheckReport {
        let mut report = CheckReport::default();
        if self.dir.is_none() {
            report.failures.push(no_dir());
            return report;
        }
        for &tier in tiers {
            let Some(target) = self.target(tier).cloned() else {
                report.failures.push(format!(
                    "the known-good list names no {} model",
                    tier.label()
                ));
                continue;
            };
            if self.is_installed(&target.id) {
                report.current.push(target.label.clone());
            } else {
                let quiet: ProgressFn = Arc::new(|_| {});
                match self.install(&target, quiet).await {
                    Ok(()) => report.installed.push(target.label.clone()),
                    Err(e) => report.failures.push(e),
                }
            }
            report.retired.extend(self.retire_superseded(tier));
        }
        report.retired.extend(self.retire_unlisted());
        self.record.lock_ok().last_check = Some(CheckRecord {
            at_ms: system_time_to_ms(SystemTime::now()),
            ok: report.failures.is_empty(),
            summary: report.summary(),
        });
        self.persist();
        report
    }

    pub fn last_check(&self) -> Option<CheckRecord> {
        self.record.lock_ok().last_check.clone()
    }

    /// The list, with what is installed and what each entry is for.
    pub fn overview(&self, primary: SpeechTier, second_reading: bool) -> Value {
        let rows: Vec<Value> = self
            .catalog
            .iter()
            .map(|e| {
                let target = self.target(e.tier).map(|t| t.id == e.id).unwrap_or(false);
                let role = if !target {
                    None
                } else if e.tier == primary {
                    Some("primary")
                } else if second_reading {
                    Some("second")
                } else {
                    None
                };
                json!({
                    "id": e.id,
                    "label": e.label,
                    "tier": e.tier.label(),
                    "role": role,
                    "installed": self.is_installed(&e.id),
                    "bytes": e.bytes,
                })
            })
            .collect();
        json!({ "models": rows, "last_check": self.last_check() })
    }

    fn persist(&self) {
        if let Some(dir) = &self.dir {
            let path = dir.join(RECORD_FILE);
            self.writer.persist(
                || self.record.lock_ok().clone(),
                |record| persist_record(&path, record),
            );
        }
    }
}

async fn verify(path: &Path, entry: &CatalogEntry) -> Result<(), String> {
    let (path, entry) = (path.to_path_buf(), entry.clone());
    tokio::task::spawn_blocking(move || {
        let len = std::fs::metadata(&path)
            .map_err(|e| format!("could not stat {}: {e}", path.display()))?
            .len();
        if len != entry.bytes {
            return Err(format!(
                "{} is {len} bytes, not the {} the known-good list pins",
                entry.label, entry.bytes
            ));
        }
        let got =
            sha256_file(&path).map_err(|e| format!("could not hash {}: {e}", path.display()))?;
        if !got.eq_ignore_ascii_case(&entry.sha256) {
            return Err(format!(
                "{}'s checksum is {got}, not the pinned {}",
                entry.label, entry.sha256
            ));
        }
        Ok(())
    })
    .await
    .map_err(|e| format!("verification stopped unexpectedly ({e})"))?
}

/// Delete download leftovers: a `.partial` exists only while an install is running, and none
/// is running at construction.
fn sweep_partials(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') && name.ends_with(".partial") {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

#[cfg(test)]
pub mod fakes {
    use super::*;

    /// A catalog entry whose "weights" are `content`, pinned honestly.
    pub fn entry(id: &str, tier: SpeechTier, rank: u32, content: &[u8]) -> CatalogEntry {
        CatalogEntry {
            id: id.to_string(),
            label: format!("Model {id}"),
            file: format!("{id}.bin"),
            url: format!("https://{DISTRIBUTION_HOST}/test/{id}.bin"),
            sha256: sha256_hex(content),
            bytes: content.len() as u64,
            tier,
            rank,
        }
    }

    /// Serves bytes by catalog id from memory, and records every fetch.
    #[derive(Default)]
    pub struct FakeFetcher {
        pub contents: Mutex<HashMap<String, Vec<u8>>>,
        pub fetched: Mutex<Vec<String>>,
        pub fail: Mutex<Option<String>>,
    }

    impl FakeFetcher {
        pub fn serving(items: &[(&CatalogEntry, &[u8])]) -> FakeFetcher {
            let f = FakeFetcher::default();
            for (e, b) in items {
                f.contents.lock_ok().insert(e.id.clone(), b.to_vec());
            }
            f
        }
    }

    impl ModelFetcher for FakeFetcher {
        fn fetch<'a>(
            &'a self,
            entry: &'a CatalogEntry,
            dest: &'a Path,
            progress: ProgressFn,
        ) -> FetchFuture<'a> {
            self.fetched.lock_ok().push(entry.id.clone());
            let fail = self.fail.lock_ok().clone();
            let body = self.contents.lock_ok().get(&entry.id).cloned();
            Box::pin(async move {
                if let Some(e) = fail {
                    return Err(e);
                }
                let body = body.ok_or_else(|| format!("404 for {}", entry.id))?;
                std::fs::write(dest, body).map_err(|e| e.to_string())?;
                progress(1.0);
                Ok(())
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fakes::*;
    use super::*;
    use crate::speech::engine::fakes::ScriptedLoader;

    fn scratch() -> PathBuf {
        std::env::temp_dir().join(format!("jesse-speech-models-{}", random_hex()))
    }

    fn manager(
        dir: &Path,
        catalog: Vec<CatalogEntry>,
        fetcher: FakeFetcher,
    ) -> (ModelManager, Arc<FakeFetcher>, Arc<ScriptedLoader>) {
        let fetcher = Arc::new(fetcher);
        let loader = Arc::new(ScriptedLoader::default());
        let m = ModelManager::new(
            Some(dir.to_path_buf()),
            catalog,
            fetcher.clone(),
            loader.clone(),
        );
        (m, fetcher, loader)
    }

    fn quiet() -> ProgressFn {
        Arc::new(|_| {})
    }

    /// THE SHIPPED LIST IS WELL-FORMED: one target per tier, every entry pinned, every fetch
    /// to the distribution host over TLS.
    #[test]
    fn the_known_good_list_pins_every_model_it_names() {
        let list = known_good();
        assert_eq!(
            target_in(&list, SpeechTier::Accurate).unwrap().id,
            "whisper-large-v3"
        );
        assert_eq!(
            target_in(&list, SpeechTier::Fast).unwrap().id,
            "whisper-large-v3-turbo"
        );
        for e in &list {
            assert!(
                e.url.starts_with(&format!("https://{DISTRIBUTION_HOST}/")),
                "{}",
                e.url
            );
            assert_eq!(e.sha256.len(), 64);
            assert!(e
                .sha256
                .chars()
                .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
            assert!(
                e.bytes > 100 * 1024 * 1024,
                "{} looks too small to be a model",
                e.id
            );
            assert!(e.url.ends_with(&e.file));
        }
        let mut files: Vec<&str> = list.iter().map(|e| e.file.as_str()).collect();
        files.dedup();
        assert_eq!(files.len(), list.len());
    }

    #[tokio::test]
    async fn install_downloads_verifies_loads_and_records() {
        let dir = scratch();
        let a = entry("acc-1", SpeechTier::Accurate, 10, b"weights for acc-1");
        let (m, fetcher, loader) = manager(
            &dir,
            vec![a.clone()],
            FakeFetcher::serving(&[(&a, b"weights for acc-1")]),
        );
        assert!(matches!(
            m.readiness(SpeechTier::Accurate),
            Ok(Readiness::NeedsInstall { fallback: None, .. })
        ));
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = seen.clone();
        m.install(&a, Arc::new(move |f| s.lock_ok().push(f)))
            .await
            .expect("installs");
        assert_eq!(
            m.readiness(SpeechTier::Accurate),
            Ok(Readiness::Ready(a.clone()))
        );
        assert_eq!(*fetcher.fetched.lock_ok(), vec!["acc-1".to_string()]);
        assert_eq!(
            *loader.loads.lock_ok(),
            vec!["acc-1".to_string()],
            "proven loadable before recorded"
        );
        assert_eq!(*seen.lock_ok(), vec![1.0]);
        use std::os::unix::fs::PermissionsExt;
        let record = dir.join(RECORD_FILE);
        assert_eq!(
            std::fs::metadata(&record).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(load_record(&record).installed[0].id, "acc-1");
        // A second install is a no-op, not a second download.
        m.install(&a, quiet()).await.unwrap();
        assert_eq!(fetcher.fetched.lock_ok().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn bytes_that_do_not_match_the_pin_are_refused_and_leave_nothing() {
        let dir = scratch();
        let a = entry("acc-1", SpeechTier::Accurate, 10, b"the real weights");
        let (m, _, loader) = manager(
            &dir,
            vec![a.clone()],
            FakeFetcher::serving(&[(&a, b"the evil weights")]),
        );
        let err = m.install(&a, quiet()).await.unwrap_err();
        assert!(err.contains("checksum"), "{err}");
        assert!(!m.is_installed("acc-1"));
        assert!(
            loader.loads.lock_ok().is_empty(),
            "an unverified file is never loaded"
        );
        let left: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name())
            .collect();
        assert!(
            left.is_empty(),
            "no partial or rejected file left behind: {left:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_seeded_copy_is_adopted_only_if_it_verifies() {
        let dir = scratch();
        std::fs::create_dir_all(&dir).unwrap();
        let a = entry("acc-1", SpeechTier::Accurate, 10, b"good weights");
        std::fs::write(dir.join(&a.file), b"good weights").unwrap();
        let (m, fetcher, _) = manager(&dir, vec![a.clone()], FakeFetcher::default());
        m.install(&a, quiet()).await.expect("adopted");
        assert!(
            fetcher.fetched.lock_ok().is_empty(),
            "no download for a verified copy"
        );

        let dir2 = scratch();
        std::fs::create_dir_all(&dir2).unwrap();
        std::fs::write(dir2.join(&a.file), b"bad  weights").unwrap();
        let (m2, _, _) = manager(&dir2, vec![a.clone()], FakeFetcher::default());
        assert!(m2.install(&a, quiet()).await.is_err());
        assert!(
            !dir2.join(&a.file).exists(),
            "a copy that fails the pin is removed"
        );
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&dir2);
    }

    /// NEVER WITH NONE: v2 downloads and verifies but will not load, so v1 keeps serving and
    /// stays installed.
    #[tokio::test]
    async fn an_upgrade_that_will_not_load_keeps_the_model_in_use() {
        let dir = scratch();
        let v1 = entry("acc-1", SpeechTier::Accurate, 10, b"v1");
        let v2 = entry("acc-2", SpeechTier::Accurate, 20, b"v2");
        let (m, _, loader) = manager(
            &dir,
            vec![v1.clone(), v2.clone()],
            FakeFetcher::serving(&[(&v1, b"v1"), (&v2, b"v2")]),
        );
        m.install(&v1, quiet()).await.unwrap();
        loader.refuse.lock_ok().insert("acc-2".to_string());
        let report = m.check(&[SpeechTier::Accurate]).await;
        assert_eq!(report.installed, Vec::<String>::new());
        assert_eq!(report.failures.len(), 1, "{report:?}");
        assert!(report.failures[0].contains("did not load"), "{report:?}");
        assert!(
            report.retired.is_empty(),
            "nothing retired while the upgrade is not in place"
        );
        assert!(m.is_installed("acc-1"));
        assert!(dir.join(&v1.file).exists());
        assert!(!dir.join(&v2.file).exists());
        assert_eq!(
            m.readiness(SpeechTier::Accurate),
            Ok(Readiness::NeedsInstall {
                target: v2,
                fallback: Some(v1)
            })
        );
        assert!(!m.last_check().unwrap().ok);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn the_weekly_check_upgrades_then_retires_then_reports_nothing_to_do() {
        let dir = scratch();
        let v1 = entry("acc-1", SpeechTier::Accurate, 10, b"v1");
        let fast = entry("fast-1", SpeechTier::Fast, 10, b"f1");
        {
            let (m, _, _) = manager(
                &dir,
                vec![v1.clone(), fast.clone()],
                FakeFetcher::serving(&[(&v1, b"v1"), (&fast, b"f1")]),
            );
            m.install(&v1, quiet()).await.unwrap();
        }
        // A later bridge ships a better accurate model on its list.
        let v2 = entry("acc-2", SpeechTier::Accurate, 20, b"v2");
        let (m, _, _) = manager(
            &dir,
            vec![v1.clone(), v2.clone(), fast.clone()],
            FakeFetcher::serving(&[(&v2, b"v2"), (&fast, b"f1")]),
        );
        let report = m.check(&[SpeechTier::Accurate, SpeechTier::Fast]).await;
        assert_eq!(report.installed, vec![v2.label.clone(), fast.label.clone()]);
        assert_eq!(report.retired, vec![v1.label.clone()]);
        assert!(report.changed());
        assert!(
            !dir.join(&v1.file).exists(),
            "the superseded file is deleted"
        );

        let again = m.check(&[SpeechTier::Accurate, SpeechTier::Fast]).await;
        assert!(!again.changed(), "{again:?}");
        assert_eq!(again.current, vec![v2.label.clone(), fast.label.clone()]);
        assert!(m.last_check().unwrap().ok);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn a_model_dropped_from_the_list_is_retired_by_the_check() {
        let dir = scratch();
        let old = entry("old", SpeechTier::Accurate, 5, b"old");
        let new = entry("new", SpeechTier::Accurate, 50, b"new");
        {
            let (m, _, _) = manager(
                &dir,
                vec![old.clone()],
                FakeFetcher::serving(&[(&old, b"old")]),
            );
            m.install(&old, quiet()).await.unwrap();
        }
        let (m, _, _) = manager(
            &dir,
            vec![new.clone()],
            FakeFetcher::serving(&[(&new, b"new")]),
        );
        assert!(
            m.is_installed("old"),
            "kept on the record until the check decides"
        );
        let report = m.check(&[SpeechTier::Accurate]).await;
        assert!(report.retired.contains(&"old".to_string()), "{report:?}");
        assert!(!dir.join(&old.file).exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn two_racing_installs_fetch_once() {
        let dir = scratch();
        let a = entry("acc-1", SpeechTier::Accurate, 10, b"weights");
        let (m, fetcher, _) = manager(
            &dir,
            vec![a.clone()],
            FakeFetcher::serving(&[(&a, b"weights")]),
        );
        let (r1, r2) = tokio::join!(m.install(&a, quiet()), m.install(&a, quiet()));
        assert!(r1.is_ok() && r2.is_ok());
        assert_eq!(fetcher.fetched.lock_ok().len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_record_tolerates_corruption_loss_and_leftovers() {
        let dir = scratch();
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(RECORD_FILE), "{ not json").unwrap();
        std::fs::write(dir.join(".acc-1.bin.abc.partial"), b"half").unwrap();
        let a = entry("acc-1", SpeechTier::Accurate, 10, b"weights");
        let (m, _, _) = manager(&dir, vec![a.clone()], FakeFetcher::default());
        assert!(
            !m.is_installed("acc-1"),
            "corrupt record is nothing installed"
        );
        assert!(
            !dir.join(".acc-1.bin.abc.partial").exists(),
            "stale partial swept"
        );

        // A record naming a file that has since vanished is forgotten.
        persist_record(
            &dir.join(RECORD_FILE),
            &ModelRecord {
                installed: vec![InstalledModel {
                    id: "acc-1".into(),
                    file: a.file.clone(),
                    sha256: a.sha256.clone(),
                    installed_ms: 1,
                }],
                last_check: None,
            },
        );
        let (m, _, _) = manager(&dir, vec![a.clone()], FakeFetcher::default());
        assert!(!m.is_installed("acc-1"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn no_state_dir_is_a_named_refusal_everywhere() {
        let a = entry("acc-1", SpeechTier::Accurate, 10, b"w");
        let m = ModelManager::new(
            None,
            vec![a.clone()],
            Arc::new(FakeFetcher::default()),
            Arc::new(ScriptedLoader::default()),
        );
        assert!(!m.available());
        assert!(m
            .readiness(SpeechTier::Accurate)
            .unwrap_err()
            .contains("JESSE_STATE_DIR"));
        assert!(m
            .install(&a, quiet())
            .await
            .unwrap_err()
            .contains("JESSE_STATE_DIR"));
        assert!(!m.check(&[SpeechTier::Accurate]).await.failures.is_empty());
    }

    /// THE ONE FETCH, on the wire: a body-less GET for the catalog URL, and a download that
    /// runs past the pinned size is cut off rather than written.
    #[tokio::test]
    async fn the_real_fetcher_sends_a_bodiless_get_and_refuses_an_overlong_body() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        async fn serve(body: Vec<u8>) -> (String, Arc<Mutex<Vec<u8>>>) {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let seen = Arc::new(Mutex::new(Vec::new()));
            let s = seen.clone();
            tokio::spawn(async move {
                let (mut sock, _) = listener.accept().await.unwrap();
                let mut buf = vec![0u8; 4096];
                let mut req = Vec::new();
                while !req.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = sock.read(&mut buf).await.unwrap();
                    if n == 0 {
                        break;
                    }
                    req.extend_from_slice(&buf[..n]);
                }
                s.lock_ok().extend_from_slice(&req);
                let head = format!("HTTP/1.1 200 OK\r\ncontent-length: {}\r\n\r\n", body.len());
                let _ = sock.write_all(head.as_bytes()).await;
                let _ = sock.write_all(&body).await;
            });
            (format!("http://{addr}/model.bin"), seen)
        }
        let dir = scratch();
        std::fs::create_dir_all(&dir).unwrap();
        let mut e = entry("acc-1", SpeechTier::Accurate, 10, b"exactly these bytes");
        let (url, seen) = serve(b"exactly these bytes".to_vec()).await;
        e.url = url;
        let dest = dir.join("one.partial");
        HttpFetcher::default()
            .fetch(&e, &dest, quiet())
            .await
            .expect("fetches");
        assert_eq!(std::fs::read(&dest).unwrap(), b"exactly these bytes");
        let req = String::from_utf8_lossy(&seen.lock_ok()).to_ascii_lowercase();
        assert!(req.starts_with("get /model.bin "), "{req}");
        assert!(
            !req.contains("content-length") || req.contains("content-length: 0"),
            "{req}"
        );

        let (url, _) = serve(vec![b'x'; 64]).await;
        e.url = url;
        let err = HttpFetcher::default()
            .fetch(&e, &dir.join("two.partial"), quiet())
            .await
            .unwrap_err();
        assert!(err.contains("more than"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
