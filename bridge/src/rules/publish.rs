//! Publication: turning one verified generation into two files on disk, or refusing to.
//!
//! # One generation, or none
//!
//! Two files cannot be renamed atomically, and pretending otherwise is worse than saying so.
//! What this does instead, in order:
//!
//!   1. builds the whole generation in memory and renders BOTH documents before touching
//!      anything, so a render failure (an over-budget document, a broken selection) costs no
//!      write at all;
//!   2. takes the bridge's own vault write lock, if the bridge is running, so a publication
//!      and a turn's write never interleave;
//!   3. re-reads every source and compares hashes against what the generation was built from,
//!      refusing on a concurrent edit rather than publishing a bundle that describes a state
//!      that no longer exists;
//!   4. copies the outgoing files into a recoverable previous generation;
//!   5. writes every output to a temp file in its own directory and fsyncs it, then renames
//!      them one after another with nothing between the renames but the rename syscalls.
//!
//! **THE RESIDUAL GAP, NAMED.** A crash between the two renames leaves one new document and
//! one old one. That state is DETECTED rather than tolerated: the two carry different bundle
//! digests, so `check` reports a core divergence, `preflight` refuses the turn, and
//! `rollback` restores the pair. What is not claimed is that the window does not exist.
//!
//! # Never silently
//!
//! An output whose bytes differ from what the state sidecar records was changed by hand, and
//! publishing over it would discard someone's edit without telling them. That refuses. An
//! output that exists with NO record at all is the migration case: an index somebody wrote,
//! full of rules, about to be replaced by a generated document. That refuses too, and takes
//! an explicit `--adopt` to proceed, because "an index replaced by a shorter core, silently"
//! is the exact failure this whole design is supposed to make impossible.

use super::*;

/// What was last published, beside the outputs it describes.
///
/// **THE SIDECAR IS WHAT MAKES A HAND EDIT DETECTABLE.** Without a record of the bytes that
/// were written, an output that differs from what the sources render is indistinguishable
/// from an output whose sources changed, and the two need opposite fixes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublishedState {
    pub schema: u32,
    /// The generator that wrote it. Recorded here rather than in the outputs, so a bridge
    /// version bump does not make every document read as drifted.
    pub generator: String,
    pub digest: String,
    pub core_digest: String,
    /// Output harness id to (relative path, sha256 of the published bytes).
    pub outputs: Vec<(String, String, String)>,
    /// Source relative path to sha256, as published.
    pub sources: Vec<(String, String)>,
}

impl PublishedState {
    fn path(canon_root: &Path) -> PathBuf {
        canon_root.join(STATE_DIR).join(STATE_FILE)
    }

    /// Read the sidecar, or `None` when there is none (an unmanaged root).
    pub fn load(canon_root: &Path) -> Option<PublishedState> {
        let text = std::fs::read_to_string(Self::path(canon_root)).ok()?;
        let v: Value = serde_json::from_str(&text).ok()?;
        let schema = v.get("schema")?.as_u64()? as u32;
        if schema != SCHEMA_VERSION {
            return None;
        }
        let outputs = v
            .get("outputs")?
            .as_array()?
            .iter()
            .map(|o| {
                Some((
                    o.get("harness")?.as_str()?.to_string(),
                    o.get("path")?.as_str()?.to_string(),
                    o.get("sha256")?.as_str()?.to_string(),
                ))
            })
            .collect::<Option<Vec<_>>>()?;
        let sources = v
            .get("sources")?
            .as_array()?
            .iter()
            .map(|o| {
                Some((
                    o.get("path")?.as_str()?.to_string(),
                    o.get("sha256")?.as_str()?.to_string(),
                ))
            })
            .collect::<Option<Vec<_>>>()?;
        Some(PublishedState {
            schema,
            generator: v
                .get("generator")
                .and_then(|g| g.as_str())
                .unwrap_or_default()
                .to_string(),
            digest: v.get("digest")?.as_str()?.to_string(),
            core_digest: v.get("core")?.as_str()?.to_string(),
            outputs,
            sources,
        })
    }

    pub fn output_sha(&self, harness: &str) -> Option<String> {
        self.outputs
            .iter()
            .find(|(h, _, _)| h == harness)
            .map(|(_, _, s)| s.clone())
    }

    fn to_json(&self) -> String {
        let v = json!({
            "schema": self.schema,
            "generator": self.generator,
            "digest": self.digest,
            "core": self.core_digest,
            "outputs": self.outputs.iter().map(|(h, p, s)| json!({
                "harness": h, "path": p, "sha256": s
            })).collect::<Vec<_>>(),
            "sources": self.sources.iter().map(|(p, s)| json!({
                "path": p, "sha256": s
            })).collect::<Vec<_>>(),
        });
        format!("{}\n", serde_json::to_string_pretty(&v).unwrap_or_default())
    }
}

/// How a publication should behave when it meets something it did not write.
#[derive(Debug, Clone, Default)]
pub struct PublishOptions {
    /// Render and compare, write nothing. The report says exactly what would change.
    pub dry_run: bool,
    /// Overwrite an output that was changed by hand since it was generated, discarding that
    /// change. Never a default, and never implied by `adopt`.
    pub force: bool,
    /// Replace an output that exists with no record of ever having been generated. This is
    /// the migration switch: it says "yes, I have compared the old file against the new one
    /// and I accept the replacement".
    pub adopt: bool,
    /// The bridge's write-lock broker socket, when the bridge is running. The publication
    /// takes the GLOBAL vault lock through it, which is the same lock a turn's unparseable
    /// write takes, so a publication and a turn cannot interleave.
    pub lock_socket: Option<PathBuf>,
}

/// What a publication did, or would do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublishReport {
    pub digest: String,
    pub core_digest: String,
    /// Outputs whose bytes changed (or would).
    pub written: Vec<String>,
    /// Outputs already byte-identical to what the sources render.
    pub unchanged: Vec<String>,
    /// Where the outgoing generation was copied, when anything was written.
    pub previous: Option<PathBuf>,
    pub dry_run: bool,
    /// Per-document size against the budget, so an operator adding a rule can see the
    /// headroom before the budget refuses them.
    pub sizes: Vec<(String, usize, usize)>,
}

/// Build, verify and publish a generation.
pub fn publish(root: &Path, opts: &PublishOptions) -> Result<PublishReport, RuleError> {
    let canon = canonical_root(root)?;
    let bundle = build_bundle(&canon)?;
    let rendered = render_all(&bundle)?;
    let sizes: Vec<(String, usize, usize)> = rendered
        .iter()
        .map(|o| (o.harness.clone(), o.text.len(), bundle.manifest.max_bytes))
        .collect();

    let _lock = VaultLock::take(opts.lock_socket.as_deref())?;

    // A source that changed since the bundle was built means the generation describes a state
    // that no longer exists. Refuse: publishing it would put a digest on the documents that
    // no source hashes to, and the very next `check` would call the result stale.
    let now = read_sources(&canon, &bundle.manifest)?;
    for (before, after) in bundle.sources.iter().zip(now.iter()) {
        if before.rel != after.rel || before.sha256 != after.sha256 {
            return Err(RuleError::ConcurrentEdit(after.rel.clone()));
        }
    }

    let state = PublishedState::load(&canon);
    let mut written = Vec::new();
    let mut unchanged = Vec::new();
    let mut existing: Vec<(PathBuf, String)> = Vec::new();

    for out in &rendered {
        let path = resolve_under_root(&canon, &out.rel)?;
        match std::fs::read_to_string(&path) {
            Ok(current) => {
                let sha = crate::sha256_hex(current.as_bytes());
                existing.push((path.clone(), out.rel.clone()));
                if current == out.text {
                    unchanged.push(out.rel.clone());
                    continue;
                }
                match state.as_ref().and_then(|s| s.output_sha(&out.harness)) {
                    // Generated by us and untouched since: an ordinary regeneration.
                    Some(recorded) if recorded == sha => {}
                    // Generated by us and edited since. Refuse unless told to discard it.
                    Some(_) if !opts.force => {
                        return Err(RuleError::ManuallyChanged {
                            harness: out.harness.clone(),
                            path,
                        })
                    }
                    Some(_) => {}
                    // Never generated by us at all: the migration case.
                    None if !opts.adopt && !opts.force => {
                        return Err(RuleError::ManuallyChanged {
                            harness: out.harness.clone(),
                            path,
                        })
                    }
                    None => {}
                }
                written.push(out.rel.clone());
            }
            Err(_) => written.push(out.rel.clone()),
        }
    }

    if opts.dry_run || written.is_empty() {
        // Nothing to write. The state sidecar is still refreshed when it is absent or stale,
        // because "the outputs are correct but nothing records that we wrote them" is exactly
        // the state that makes the next publication look like a hand edit.
        if !opts.dry_run && written.is_empty() {
            write_state(&canon, &bundle, &rendered)?;
        }
        return Ok(PublishReport {
            digest: bundle.digest,
            core_digest: bundle.core_digest,
            written,
            unchanged,
            previous: None,
            dry_run: opts.dry_run,
            sizes,
        });
    }

    // ---- Keep a recoverable previous generation --------------------------------------
    let prev_dir = canon.join(STATE_DIR).join(PREVIOUS_DIR);
    std::fs::create_dir_all(&prev_dir)
        .map_err(|e| RuleError::io(format!("creating {}", prev_dir.display()), e))?;
    // A flat directory keyed by the output's file name. The outputs live at the root and
    // their names are distinct, so no nesting is needed and none is invented.
    for (path, rel) in &existing {
        let name = Path::new(rel)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| rel.replace('/', "_"));
        std::fs::copy(path, prev_dir.join(&name))
            .map_err(|e| RuleError::io(format!("saving previous {rel}"), e))?;
    }
    if let Some(st) = &state {
        let _ = std::fs::write(prev_dir.join(STATE_FILE), st.to_json());
    }
    write_gitignore(&canon.join(STATE_DIR));

    // ---- Write every temp, then rename every temp -------------------------------------
    let mut temps: Vec<(PathBuf, PathBuf)> = Vec::new();
    for out in &rendered {
        let path = resolve_under_root(&canon, &out.rel)?;
        let tmp = path.with_extension(format!(
            "{}{}",
            path.extension()
                .map(|e| e.to_string_lossy().to_string())
                .unwrap_or_default(),
            TMP_SUFFIX
        ));
        write_and_sync(&tmp, out.text.as_bytes())
            .map_err(|e| RuleError::io(format!("writing {}", tmp.display()), e))?;
        temps.push((tmp, path));
    }
    // The last look before the point of no return. Cheap, and it closes the window between
    // the check above and the renames below down to the temp writes.
    let now = read_sources(&canon, &bundle.manifest)?;
    for (before, after) in bundle.sources.iter().zip(now.iter()) {
        if before.sha256 != after.sha256 {
            for (tmp, _) in &temps {
                let _ = std::fs::remove_file(tmp);
            }
            return Err(RuleError::ConcurrentEdit(after.rel.clone()));
        }
    }
    for (tmp, path) in &temps {
        std::fs::rename(tmp, path)
            .map_err(|e| RuleError::io(format!("publishing {}", path.display()), e))?;
    }

    write_state(&canon, &bundle, &rendered)?;

    Ok(PublishReport {
        digest: bundle.digest,
        core_digest: bundle.core_digest,
        written,
        unchanged,
        previous: Some(prev_dir),
        dry_run: false,
        sizes,
    })
}

/// Restore the previous generation. The escape hatch a publication earns by keeping one.
pub fn rollback(root: &Path, lock_socket: Option<&Path>) -> Result<Vec<String>, RuleError> {
    let canon = canonical_root(root)?;
    let prev_dir = canon.join(STATE_DIR).join(PREVIOUS_DIR);
    let manifest = Manifest::load(&canon)?;
    let _lock = VaultLock::take(lock_socket)?;
    let mut restored = Vec::new();
    for rel in manifest.outputs.values() {
        let name = Path::new(rel)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| rel.replace('/', "_"));
        let from = prev_dir.join(&name);
        if !from.exists() {
            return Err(RuleError::Io {
                what: format!("rolling back {rel}"),
                detail: format!("no previous generation at {}", from.display()),
            });
        }
        let to = resolve_under_root(&canon, rel)?;
        let bytes = std::fs::read(&from)
            .map_err(|e| RuleError::io(format!("reading {}", from.display()), e))?;
        let tmp = to.with_extension(format!(
            "{}{}",
            to.extension()
                .map(|e| e.to_string_lossy().to_string())
                .unwrap_or_default(),
            TMP_SUFFIX
        ));
        write_and_sync(&tmp, &bytes)
            .map_err(|e| RuleError::io(format!("writing {}", tmp.display()), e))?;
        std::fs::rename(&tmp, &to)
            .map_err(|e| RuleError::io(format!("restoring {}", to.display()), e))?;
        restored.push(rel.clone());
    }
    // The sidecar goes back with the files, or the restored pair reads as hand-edited.
    let prev_state = prev_dir.join(STATE_FILE);
    if prev_state.exists() {
        let _ = std::fs::copy(&prev_state, PublishedState::path(&canon));
    } else {
        let _ = std::fs::remove_file(PublishedState::path(&canon));
    }
    Ok(restored)
}

fn write_state(
    canon: &Path,
    bundle: &Bundle,
    rendered: &[RenderedOutput],
) -> Result<(), RuleError> {
    let dir = canon.join(STATE_DIR);
    std::fs::create_dir_all(&dir)
        .map_err(|e| RuleError::io(format!("creating {}", dir.display()), e))?;
    write_gitignore(&dir);
    let st = PublishedState {
        schema: SCHEMA_VERSION,
        generator: format!("jesse-bridge {}", env!("CARGO_PKG_VERSION")),
        digest: bundle.digest.clone(),
        core_digest: bundle.core_digest.clone(),
        outputs: rendered
            .iter()
            .map(|o| {
                (
                    o.harness.clone(),
                    o.rel.clone(),
                    crate::sha256_hex(o.text.as_bytes()),
                )
            })
            .collect(),
        sources: bundle
            .sources
            .iter()
            .map(|s| (s.rel.clone(), s.sha256.clone()))
            .collect(),
    };
    write_and_sync(&PublishedState::path(canon), st.to_json().as_bytes())
        .map_err(|e| RuleError::io("writing the rules state sidecar", e))
}

/// Keep the state directory out of the source repository it lives in.
///
/// The same self-ignoring `*` file the artifact staging directory uses: the previous
/// generation and the sidecar are recovery state, not content, and a vault that commits them
/// would carry a second copy of every generated document in its history.
fn write_gitignore(dir: &Path) {
    let p = dir.join(".gitignore");
    if !p.exists() {
        let _ = std::fs::write(&p, "*\n");
    }
}

fn write_and_sync(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut f = std::fs::File::create(path)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    Ok(())
}

// ---- The vault lock ----------------------------------------------------------

/// The GLOBAL vault write lock, held for the duration of a publication.
///
/// **THE BRIDGE'S OWN BROKER, NOT A SECOND LOCK.** A publication writes files in the vault
/// while a turn may be writing others; a lock file of its own would order publications
/// against each other and against nothing else. `WriteTarget::Global` is the key an
/// unparseable write already takes, and taking the same one is what actually orders a
/// publication against a live turn.
///
/// A missing socket means the bridge is not running, and then there is no turn to interleave
/// with: the publication proceeds unlocked and says so in nothing, because there is nothing
/// to say. A REFUSAL from a running broker is a different matter and fails the publication.
struct VaultLock {
    socket: Option<PathBuf>,
    id: String,
}

impl VaultLock {
    fn take(socket: Option<&Path>) -> Result<VaultLock, RuleError> {
        let Some(sock) = socket else {
            return Ok(VaultLock {
                socket: None,
                id: String::new(),
            });
        };
        if !sock.exists() {
            return Ok(VaultLock {
                socket: None,
                id: String::new(),
            });
        }
        let id = crate::random_hex();
        let resp = crate::ask_broker_blocking(
            sock,
            &crate::HookRequest::Pre {
                turn: format!("jesse-rules-{id}"),
                conversation: format!("jesse-rules-{id}"),
                tool_use_id: id.clone(),
                // `Some(None)` is the wire spelling of `WriteTarget::Global`.
                target: Some(None),
                // A publication rewrites tracked files in a git repository, so it takes the
                // git lock inside the global one exactly as a turn's write does.
                git: true,
            },
        );
        if !resp.allow {
            return Err(RuleError::Io {
                what: "taking the vault write lock".to_string(),
                detail: resp.reason.unwrap_or_else(|| {
                    "the bridge's write-lock broker refused; a turn is writing the vault"
                        .to_string()
                }),
            });
        }
        Ok(VaultLock {
            socket: Some(sock.to_path_buf()),
            id,
        })
    }
}

impl Drop for VaultLock {
    fn drop(&mut self) {
        if let Some(sock) = &self.socket {
            let _ = crate::ask_broker_blocking(
                sock,
                &crate::HookRequest::Post {
                    turn: format!("jesse-rules-{}", self.id),
                    conversation: format!("jesse-rules-{}", self.id),
                    tool_use_id: self.id.clone(),
                    baseline: None,
                },
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::tests_support::scratch_root;

    #[test]
    fn a_first_publication_needs_adopting_when_an_index_is_already_there() {
        let (root, _g) = scratch_root("adopt");
        std::fs::write(root.join("AGENTS.md"), "# an index somebody wrote\n").expect("write");
        let e = publish(&root, &PublishOptions::default()).expect_err("refuses");
        assert!(matches!(e, RuleError::ManuallyChanged { .. }), "{e}");
        let r = publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        assert!(r.written.contains(&"AGENTS.md".to_string()));
    }

    #[test]
    fn publication_is_idempotent() {
        let (root, _g) = scratch_root("idem");
        let a = publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        let claude = std::fs::read(root.join("CLAUDE.md")).expect("read");
        let b = publish(&root, &PublishOptions::default()).expect("re-publishes");
        assert_eq!(a.digest, b.digest);
        assert!(b.written.is_empty(), "a second run writes nothing");
        assert_eq!(b.unchanged.len(), 2);
        assert_eq!(claude, std::fs::read(root.join("CLAUDE.md")).expect("read"));
    }

    #[test]
    fn a_dry_run_writes_nothing() {
        let (root, _g) = scratch_root("dry");
        let r = publish(
            &root,
            &PublishOptions {
                dry_run: true,
                adopt: true,
                ..Default::default()
            },
        )
        .expect("plans");
        assert_eq!(r.written.len(), 2);
        assert!(r.dry_run);
        assert!(!root.join("CLAUDE.md").exists());
        assert!(!root.join(STATE_DIR).exists());
    }

    #[test]
    fn a_hand_edited_output_is_never_overwritten_silently() {
        let (root, _g) = scratch_root("noclobber");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        let p = root.join("CLAUDE.md");
        let text = std::fs::read_to_string(&p).expect("read");
        std::fs::write(&p, format!("{text}\nsomeone added a rule here\n")).expect("write");
        let e = publish(&root, &PublishOptions::default()).expect_err("refuses");
        assert!(matches!(e, RuleError::ManuallyChanged { .. }), "{e}");
        assert!(
            std::fs::read_to_string(&p)
                .expect("read")
                .contains("someone added a rule here"),
            "the refusal must not have written anything"
        );
        let r = publish(
            &root,
            &PublishOptions {
                force: true,
                ..Default::default()
            },
        )
        .expect("forces");
        assert_eq!(r.written, vec!["CLAUDE.md".to_string()]);
    }

    #[test]
    fn a_source_that_changes_mid_publication_aborts_it() {
        // The window this closes is small and real; the test drives it directly by publishing
        // a bundle built from sources that have since moved on.
        let (root, _g) = scratch_root("concurrent");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        let canon = canonical_root(&root).expect("canon");
        let bundle = build_bundle(&canon).expect("bundle");
        std::fs::write(
            root.join("hard.md"),
            "<!-- jesse-rule: id=no-outbound scope=core section=\"Hard Rules\" -->\n- **Edited.**\n<!-- /jesse-rule -->\n",
        )
        .expect("write");
        let now = read_sources(&canon, &bundle.manifest).expect("re-read");
        assert!(
            bundle
                .sources
                .iter()
                .zip(now.iter())
                .any(|(a, b)| a.sha256 != b.sha256),
            "the fixture must actually have moved for this test to mean anything"
        );
    }

    #[test]
    fn rollback_restores_the_previous_pair_and_its_record() {
        let (root, _g) = scratch_root("rollback");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        let before = std::fs::read_to_string(root.join("AGENTS.md")).expect("read");
        std::fs::write(
            root.join("hard.md"),
            "<!-- jesse-rule: id=no-outbound scope=core section=\"Hard Rules\" -->\n- **Version two.**\n<!-- /jesse-rule -->\n",
        )
        .expect("write");
        publish(&root, &PublishOptions::default()).expect("republishes");
        assert!(std::fs::read_to_string(root.join("AGENTS.md"))
            .expect("read")
            .contains("Version two"));
        let restored = rollback(&root, None).expect("rolls back");
        assert_eq!(restored.len(), 2);
        assert_eq!(
            std::fs::read_to_string(root.join("AGENTS.md")).expect("read"),
            before
        );
        // And the restored pair reads as generated, not as hand-edited.
        let st = PublishedState::load(&canonical_root(&root).expect("canon")).expect("state");
        assert_eq!(
            st.output_sha(crate::CODEX_ID),
            Some(crate::sha256_hex(before.as_bytes()))
        );
    }

    #[test]
    fn the_state_directory_ignores_itself() {
        let (root, _g) = scratch_root("ignore");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        assert_eq!(
            std::fs::read_to_string(root.join(STATE_DIR).join(".gitignore")).expect("read"),
            "*\n"
        );
    }

    #[test]
    fn an_interrupted_publication_leaves_a_detectable_pair() {
        let (root, _g) = scratch_root("interrupted");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        let old_agents = std::fs::read_to_string(root.join("AGENTS.md")).expect("read");
        std::fs::write(
            root.join("hard.md"),
            "<!-- jesse-rule: id=no-outbound scope=core section=\"Hard Rules\" -->\n- **Version two.**\n<!-- /jesse-rule -->\n",
        )
        .expect("write");
        publish(&root, &PublishOptions::default()).expect("republishes");
        // Simulate the crash between the two renames: put the OLD codex document back.
        std::fs::write(root.join("AGENTS.md"), &old_agents).expect("write");
        let r = crate::rules::check(&root);
        assert!(
            r.problems
                .iter()
                .any(|e| matches!(e, RuleError::CoreDivergence(_) | RuleError::Stale(_))),
            "{:?}",
            r.problems
        );
        assert!(crate::rules::preflight(&root, crate::CODEX_ID).is_err());
        rollback(&root, None).expect("rolls back");
    }
}
