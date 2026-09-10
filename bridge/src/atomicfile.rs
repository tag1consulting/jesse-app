// ---- Whole-file writes for the bridge's JSON stores ------------------------
//
// Every store the bridge keeps on disk (conversations, context, titles, flags, deletions,
// the model selection, the profile, the artifact index, …) is one JSON file rewritten whole
// on each change: write a sibling temp file, fsync it, rename it over the target. That
// discipline is right, but the stores all spelled the temp file the same way —
// `path.with_extension("json.tmp")` — and a FIXED temp name is only safe when one writer
// can ever hold it at a time.
//
// They could not guarantee that. The in-memory stores snapshot under their lock and write
// OFF it, so a disk write never stalls a reader; two turns finishing together therefore run
// two writes of the same file at once. With one shared temp name the second `open` truncates
// the file the first is still writing, the first `rename` moves it into place, and the second
// `rename` then finds no temp file at all: `could not persist conversations: No such file or
// directory (os error 2)`, four times in one burst of five concurrent turns on 2026-09-10.
// Worse than the warning is what it hides. The second writer's bytes land in the inode the
// first rename already installed, so a shorter second snapshot leaves a longer first one's
// tail behind it — invalid JSON, which every store loads as EMPTY. And because the two
// writes race, an older snapshot can land after a newer one and quietly roll the file back.
//
// Two separate fixes, one for each failure:
//   - [`write_atomic`] gives every write its own temp file, so no two writers ever share an
//     inode and a rename can never find its temp gone. This alone ends the torn file.
//   - [`SnapshotWriter`] makes a store's writes take turns and take their snapshot INSIDE
//     the turn, so the file only ever moves forward. It does not hold the store's own lock
//     while writing — readers still never wait on the disk.

use crate::*;

/// Replace `path` with `bytes`, atomically and privately: a UNIQUE sibling temp file
/// (`.<name>.<pid>.<random>.tmp`, so concurrent writers — in this process or another — never
/// share one), mode 0600, fsync, then `rename` over the target. The parent directory is
/// created if missing, so a store works regardless of init order. On any failure the temp
/// file is removed and the error returned; the target is either the old file or the new one,
/// never a mixture.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "store".to_string());
    let tmp = path.with_file_name(format!(
        ".{name}.{}.{}.tmp",
        std::process::id(),
        random_hex()
    ));
    let write = || -> std::io::Result<()> {
        // `create_new`: a leftover temp file of the same name is an error, never reused.
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    let result = write();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

/// Orders one store's disk writes. A store that snapshots under its lock and writes off it
/// calls [`SnapshotWriter::persist`] instead of writing its own snapshot: each caller waits
/// its turn, then takes the snapshot, then writes it. A later write therefore always carries
/// a state at least as new as every earlier one, and the file can never be rolled back by a
/// slow writer holding a stale copy.
///
/// LOCK ORDER: this writer's turn, THEN the store's data lock (inside `snapshot`). A caller
/// must never call `persist` while holding the store's data lock — every store here releases
/// it before persisting, which is what kept the disk off the read path in the first place.
#[derive(Default)]
pub struct SnapshotWriter {
    turn: Mutex<()>,
}

impl SnapshotWriter {
    pub fn new() -> Self {
        SnapshotWriter::default()
    }

    /// Wait for this store's previous write to finish, then take `snapshot()` and hand it to
    /// `write`. `snapshot` must take (and release) the store's data lock itself.
    pub fn persist<T>(&self, snapshot: impl FnOnce() -> T, write: impl FnOnce(&T)) {
        let _turn = self.turn.lock_ok();
        let state = snapshot();
        write(&state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt as _;
    use std::sync::Arc;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("jesse-atomic-{tag}-{}", random_hex()));
        std::fs::create_dir_all(&dir).expect("a scratch dir");
        dir
    }

    fn leftovers(dir: &Path) -> Vec<String> {
        std::fs::read_dir(dir)
            .expect("the scratch dir")
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.ends_with(".tmp"))
            .collect()
    }

    #[test]
    fn a_write_lands_private_and_leaves_no_temp_file() {
        let dir = scratch("basic");
        let path = dir.join("nested").join("store.json");
        write_atomic(&path, b"{\"v\":1}").expect("the first write");
        write_atomic(&path, b"{\"v\":2}").expect("a replacing write");
        assert_eq!(std::fs::read(&path).unwrap(), b"{\"v\":2}");
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "store files are private");
        assert!(leftovers(path.parent().unwrap()).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A failed rename must not strand its temp file: the target here is a directory, so the
    /// rename is refused after the temp file was written.
    #[test]
    fn a_failed_write_removes_its_temp_file() {
        let dir = scratch("fail");
        let path = dir.join("store.json");
        std::fs::create_dir_all(path.join("occupied")).expect("a directory in the way");
        assert!(write_atomic(&path, b"{}").is_err());
        assert!(leftovers(&dir).is_empty(), "{:?}", leftovers(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// THE REGRESSION. Many threads rewriting one file at once, each with a payload of a
    /// different length. With a shared temp name this failed with ENOENT and could leave a
    /// torn file; now every write succeeds and the file is always exactly one whole payload.
    #[test]
    fn concurrent_writers_never_fail_and_never_tear_the_file() {
        let dir = scratch("race");
        let path = Arc::new(dir.join("store.json"));
        let payloads: Vec<String> = (0..16)
            .map(|i| format!("{{\"writer\":{i},\"pad\":\"{}\"}}", "x".repeat(i * 97)))
            .collect();
        let payloads = Arc::new(payloads);
        let handles: Vec<_> = (0..16)
            .map(|i| {
                let path = path.clone();
                let payloads = payloads.clone();
                std::thread::spawn(move || {
                    for _ in 0..40 {
                        write_atomic(&path, payloads[i].as_bytes()).expect("every write lands");
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().expect("no writer panicked");
        }
        let body = std::fs::read_to_string(&*path).expect("the file");
        assert!(
            payloads.contains(&body),
            "the file must be exactly one writer's payload, never a mixture"
        );
        serde_json::from_str::<serde_json::Value>(&body).expect("and valid JSON");
        assert!(leftovers(&dir).is_empty(), "{:?}", leftovers(&dir));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Writes take turns and snapshot inside the turn, so the sequence of states written is
    /// never out of order even when the callers race: every write sees a state at least as new
    /// as the one before it.
    #[test]
    fn a_snapshot_writer_never_writes_an_older_state_after_a_newer_one() {
        let state = Arc::new(Mutex::new(0u64));
        let writer = Arc::new(SnapshotWriter::new());
        let written = Arc::new(Mutex::new(Vec::<u64>::new()));
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let (state, writer, written) = (state.clone(), writer.clone(), written.clone());
                std::thread::spawn(move || {
                    for _ in 0..200 {
                        // Mutate under the data lock, release it, then persist — the stores'
                        // own shape.
                        *state.lock_ok() += 1;
                        writer.persist(
                            || *state.lock_ok(),
                            |s| {
                                std::thread::yield_now();
                                written.lock_ok().push(*s);
                            },
                        );
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().expect("no writer panicked");
        }
        let written = written.lock_ok();
        assert!(
            written.windows(2).all(|w| w[0] <= w[1]),
            "a write went backwards"
        );
        assert_eq!(
            *written.last().unwrap(),
            1600,
            "the last write carries the final state"
        );
    }
}
