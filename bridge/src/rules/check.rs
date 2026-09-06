//! Verification: the one function that says whether what is on disk is what the sources say,
//! and the two consumers of it.
//!
//! [`verify`] is the whole check. [`check`] is the CLI's report shape, which keeps going
//! after the first independent problem so a mis-migrated root can be fixed in one pass rather
//! than one error at a time. [`preflight`] is what the BRIDGE runs before a turn that depends
//! on the bundle, and it is the same verification: a cheaper one that skipped rendering would
//! be a different check, and a turn that ran under a weaker check than CI does is exactly the
//! gap "never silently use stale policy" is about.
//!
//! # The cost, measured rather than assumed
//!
//! Verification reads every declared source, hashes it, extracts its markers and renders both
//! documents. For a bundle of the size this is built for (tens of small Markdown files) that
//! is a few hundred kilobytes of reads and two string builds. It runs once per turn, before a
//! process spawn that costs orders of magnitude more, so it is not cached: a cache keyed on
//! mtime is a second thing to be wrong, and the failure it would produce is a turn running on
//! policy the operator has already changed.

use super::*;

/// A root that verified clean, and everything a caller needs from it.
#[derive(Debug, Clone)]
pub struct Verified {
    pub bundle: Bundle,
    pub rendered: Vec<RenderedOutput>,
}

/// Verify a rules root against its own outputs.
///
/// Ordered so the message a caller gets names the FIRST thing wrong rather than a consequence
/// of it: a missing manifest before a missing source, a missing source before a broken
/// marker, a broken marker before a stale document.
pub fn verify(canon_root: &Path) -> Result<Verified, RuleError> {
    let bundle = build_bundle(canon_root)?;
    let rendered = render_all(&bundle)?;
    for out in &rendered {
        let path = resolve_under_root(canon_root, &out.rel)?;
        let text = std::fs::read_to_string(&path).map_err(|e| RuleError::IncompleteOutput {
            harness: out.harness.clone(),
            detail: format!("{} could not be read: {e}", path.display()),
        })?;
        // Parse first: it produces a precise message for the interesting failures (truncated,
        // hand-edited core, two half-published generations) where a byte comparison would only
        // be able to say "different".
        let header = parse_document(&out.harness, &text)?;
        if header.digest != bundle.digest {
            return Err(RuleError::Stale(format!(
                "{} carries bundle digest {} but the sources now hash to {}; regenerate",
                out.rel, header.digest, bundle.digest
            )));
        }
        if text != out.text {
            return Err(RuleError::Stale(format!(
                "{} agrees on the digest but its bytes differ from what the sources render; \
                 this build renders differently from the one that published it",
                out.rel
            )));
        }
    }
    // Cross-document core equality. Guaranteed by construction (there is one core string),
    // but this is the assertion that catches a HALF-PUBLISHED bundle on disk: two documents
    // from different generations both parse, and only their cores disagree.
    let mut cores = rendered.iter().map(|o| {
        parse_document(&o.harness, &o.text)
            .map(|h| (o.harness.clone(), h.core))
            .expect("a document this build just rendered parses")
    });
    if let Some((first_h, first_core)) = cores.next() {
        for (h, core) in cores {
            if core != first_core {
                return Err(RuleError::CoreDivergence(format!(
                    "{first_h} and {h} carry different cores"
                )));
            }
        }
    }
    Ok(Verified { bundle, rendered })
}

/// What the bridge learns from a clean root before a turn that depends on the bundle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreflightReport {
    /// The harness whose turn this is, as asked.
    pub harness: String,
    /// The harness whose DOCUMENT it reads. Differs for the in-process harness.
    pub document_harness: String,
    /// The document's root-relative path.
    pub document: String,
    pub digest: String,
    pub core_digest: String,
    pub bytes: usize,
    pub max_bytes: usize,
    /// The mandatory core's rule ids, in render order. Logged with the turn.
    pub core_rules: Vec<String>,
    /// The routed rule ids, in render order.
    pub task_rules: Vec<String>,
    /// The enforceable checks in force for this turn.
    pub enforce: Vec<EnforceSpec>,
}

impl PreflightReport {
    /// The one log line a turn writes about its bundle.
    ///
    /// **CONTENT-FREE ON PURPOSE.** Ids, digests, counts and a path. No rule body, no note
    /// text, no secret, and nothing from the owner's vault: the log says WHICH policy was
    /// supplied, and the digest is what makes that checkable afterwards. It says nothing
    /// about whether the model obeyed it, because nothing here could know that.
    pub fn log_line(&self) -> String {
        format!(
            "rules bundle digest={} core={} harness={} document={} bytes={}/{} core_rules={} \
             task_rules={} enforced={}",
            &self.digest[..16.min(self.digest.len())],
            &self.core_digest[..16.min(self.core_digest.len())],
            self.harness,
            self.document,
            self.bytes,
            self.max_bytes,
            self.core_rules.join(","),
            self.task_rules.len(),
            self.enforce.len(),
        )
    }
}

/// Verify the root and report what THIS harness's turn will be supplied.
///
/// Called on the turn path, so it takes the uncanonicalized configured root and does the
/// canonicalization itself: a rules root that has been moved or unmounted must fail here with
/// a message naming the path, not panic somewhere further in.
pub fn preflight(root: &Path, harness_id: &str) -> Result<PreflightReport, RuleError> {
    let canon = canonical_root(root)?;
    let v = verify(&canon)?;
    let doc_harness = document_harness(harness_id).to_string();
    let out = v
        .rendered
        .iter()
        .find(|o| o.harness == doc_harness)
        .ok_or_else(|| {
            RuleError::InvalidManifest(format!(
                "[outputs] has no entry for harness `{doc_harness}`, so a turn on `{harness_id}` \
                 has no entry document to load"
            ))
        })?;
    let header = parse_document(&out.harness, &out.text)?;
    Ok(PreflightReport {
        harness: harness_id.to_string(),
        document_harness: doc_harness,
        document: out.rel.clone(),
        digest: v.bundle.digest.clone(),
        core_digest: header.core_digest,
        bytes: out.text.len(),
        max_bytes: v.bundle.manifest.max_bytes,
        core_rules: v
            .bundle
            .rules
            .iter()
            .filter(|r| r.scope == RuleScope::Core)
            .map(|r| r.id.clone())
            .collect(),
        task_rules: v
            .bundle
            .rules
            .iter()
            .filter(|r| r.scope == RuleScope::Task)
            .map(|r| r.id.clone())
            .collect(),
        enforce: v.bundle.manifest.enforce.clone(),
    })
}

/// The one sentence a turn's PROMPT carries about the bundle, or `None`.
///
/// # Why a pointer and not the core
///
/// **THE CORE MUST NOT BE INJECTED TWICE.** Both harnesses discover the entry document from
/// their working directory when the process starts, so the core is already in the context
/// before the prompt is read; pasting it in again would double it, spend the budget twice and
/// give a compaction two copies to disagree about. What this adds is the one thing native
/// discovery cannot survive: a mid-turn compaction, which drops file content that the turn's
/// own request text usually outlives.
///
/// # The boundary this reinjects at, and the gap it does not close
///
/// The bridge starts a FRESH child process per turn, so discovery re-runs on a new
/// conversation, a resumed one, a bridge restart and a redeploy. That is the durable
/// mechanism, and it is the harness's own. The turn's prompt is the one further boundary the
/// bridge controls. What neither reaches is a compaction that happens INSIDE a running turn:
/// neither CLI reports one on a channel this bridge reads, so there is nothing to hook and no
/// callback to register. This sentence is what a post-compaction context is left holding, and
/// it is an instruction rather than a guarantee.
pub fn reload_prompt_suffix(root: &Path, harness_id: &str) -> Option<String> {
    let canon = canonical_root(root).ok()?;
    let manifest = Manifest::load(&canon).ok()?;
    let doc = manifest.outputs.get(document_harness(harness_id))?;
    Some(format!(
        "\n\nYour working directory carries `{doc}`, the generated entry document whose \
         mandatory core was loaded when this turn started. If your context is compacted part \
         way through this turn, re-read that file as your first action afterwards, then \
         re-read the guidance files the summary lists as in active use."
    ))
}

// ---- The CLI's report --------------------------------------------------------

/// Everything wrong with a root, rather than the first thing wrong with it.
#[derive(Debug, Clone)]
pub struct CheckReport {
    pub root: PathBuf,
    pub problems: Vec<RuleError>,
    /// Present when the sources themselves are sound, even if the outputs are not.
    pub digest: Option<String>,
    /// Per-output size against the budget, for the operator who is about to add a rule.
    pub sizes: Vec<(String, usize, usize)>,
}

impl CheckReport {
    pub fn ok(&self) -> bool {
        self.problems.is_empty()
    }
}

/// Check a root, collecting every INDEPENDENT problem.
///
/// "Independent" is doing work in that sentence: a broken manifest makes every later question
/// unanswerable, so the report stops there rather than emitting a cascade of consequences
/// that all disappear when the first one is fixed. Where the questions genuinely are
/// independent, they are all asked: each output is checked separately, and the state sidecar's
/// hand-edit detection runs whether or not the sources are stale.
pub fn check(root: &Path) -> CheckReport {
    let mut problems = Vec::new();
    let mut sizes = Vec::new();

    let canon = match canonical_root(root) {
        Ok(c) => c,
        Err(e) => {
            return CheckReport {
                root: root.to_path_buf(),
                problems: vec![e],
                digest: None,
                sizes,
            }
        }
    };

    let bundle = match build_bundle(&canon) {
        Ok(b) => b,
        Err(e) => {
            return CheckReport {
                root: canon,
                problems: vec![e],
                digest: None,
                sizes,
            }
        }
    };
    let digest = Some(bundle.digest.clone());

    // Render each output on its own so a budget failure on one does not hide the state of
    // the other.
    let mut rendered: Vec<RenderedOutput> = Vec::new();
    for (harness, rel) in &bundle.manifest.outputs {
        match render_for(&bundle, harness) {
            Ok(text) => {
                sizes.push((harness.clone(), text.len(), bundle.manifest.max_bytes));
                if text.len() > bundle.manifest.max_bytes {
                    problems.push(RuleError::BudgetExceeded {
                        harness: harness.clone(),
                        bytes: text.len(),
                        max: bundle.manifest.max_bytes,
                    });
                }
                rendered.push(RenderedOutput {
                    harness: harness.clone(),
                    rel: rel.clone(),
                    text,
                });
            }
            Err(e) => problems.push(e),
        }
    }

    let state = PublishedState::load(&canon);
    let mut cores: Vec<(String, String)> = Vec::new();

    for out in &rendered {
        let path = match resolve_under_root(&canon, &out.rel) {
            Ok(p) => p,
            Err(e) => {
                problems.push(e);
                continue;
            }
        };
        let Ok(text) = std::fs::read_to_string(&path) else {
            problems.push(RuleError::IncompleteOutput {
                harness: out.harness.clone(),
                detail: format!("{} is missing; nothing has been published yet", out.rel),
            });
            continue;
        };
        // A hand edit is a DIFFERENT problem from drift and deserves its own message: drift
        // is fixed by regenerating, a hand edit is fixed by moving the change into a source
        // first. It is asked FIRST because it needs no parsing, and because a hand edit
        // inside the core also breaks the core digest: reporting only the digest failure
        // would tell the operator the file is corrupt when what actually happened is that
        // somebody wrote a rule into it.
        if let Some(st) = &state {
            if let Some(recorded) = st.output_sha(&out.harness) {
                if recorded != crate::sha256_hex(text.as_bytes()) {
                    problems.push(RuleError::ManuallyChanged {
                        harness: out.harness.clone(),
                        path: path.clone(),
                    });
                }
            }
        }
        match parse_document(&out.harness, &text) {
            Ok(h) => cores.push((out.harness.clone(), h.core)),
            Err(e) => {
                problems.push(e);
                continue;
            }
        }
        if text != out.text {
            problems.push(RuleError::Stale(format!(
                "{} does not match what its sources render",
                out.rel
            )));
        }
    }

    if let Some((fh, fc)) = cores.first() {
        for (h, c) in cores.iter().skip(1) {
            if c != fc {
                problems.push(RuleError::CoreDivergence(format!(
                    "{fh} and {h} carry different cores; a publication was interrupted between \
                     the two renames"
                )));
            }
        }
    }

    // An enforcement check that cites a rule id nothing declares would produce a denial the
    // model was never told about. That is a broken selection in the other direction, and it
    // is only checkable once both halves are in hand.
    for spec in &bundle.manifest.enforce {
        if !bundle.rules.iter().any(|r| r.id == spec.rule) {
            problems.push(RuleError::BrokenSelection {
                id: spec.rule.clone(),
                detail: "an [[enforce]] check names this rule, but no source declares it — a \
                         refusal would cite an instruction the model was never given"
                    .to_string(),
            });
        }
    }

    CheckReport {
        root: canon,
        problems,
        digest,
        sizes,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::tests_support::scratch_root;

    #[test]
    fn a_clean_root_verifies_and_preflights() {
        let (root, _g) = scratch_root("clean");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        let r = check(&root);
        assert!(r.ok(), "{:?}", r.problems);
        let p = preflight(&root, crate::CODEX_ID).expect("preflight");
        assert_eq!(p.document, "AGENTS.md");
        assert!(!p.core_rules.is_empty());
        assert!(p.log_line().contains("digest="));
    }

    #[test]
    fn the_direct_harness_preflights_against_the_claude_code_document() {
        let (root, _g) = scratch_root("direct");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        let p = preflight(&root, crate::DIRECT_ID).expect("preflight");
        assert_eq!(p.document_harness, crate::CLAUDE_CODE_ID);
        assert_eq!(p.document, "CLAUDE.md");
    }

    #[test]
    fn a_changed_source_makes_the_published_bundle_stale() {
        let (root, _g) = scratch_root("stale");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        std::fs::write(
            root.join("hard.md"),
            "<!-- jesse-rule: id=no-outbound scope=core section=\"Hard Rules\" -->\n- **Changed.**\n<!-- /jesse-rule -->\n",
        )
        .expect("write");
        let e = preflight(&root, crate::CODEX_ID).expect_err("stale");
        assert!(matches!(e, RuleError::Stale(_)), "{e}");
        let r = check(&root);
        assert!(!r.ok());
    }

    #[test]
    fn a_hand_edited_output_is_reported_as_hand_edited() {
        let (root, _g) = scratch_root("handedit");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        let p = root.join("AGENTS.md");
        let text = std::fs::read_to_string(&p).expect("read");
        std::fs::write(&p, text.replace("Draft it and stop.", "Send it.")).expect("write");
        let r = check(&root);
        assert!(
            r.problems
                .iter()
                .any(|e| matches!(e, RuleError::ManuallyChanged { .. })),
            "{:?}",
            r.problems
        );
    }

    #[test]
    fn a_missing_output_is_a_problem_rather_than_a_pass() {
        let (root, _g) = scratch_root("missing");
        publish(
            &root,
            &PublishOptions {
                adopt: true,
                ..Default::default()
            },
        )
        .expect("publishes");
        std::fs::remove_file(root.join("AGENTS.md")).expect("remove");
        let r = check(&root);
        assert!(!r.ok());
        assert!(preflight(&root, crate::CODEX_ID).is_err());
        // The OTHER harness must fail too: a bundle is published as one generation, so a
        // missing half is not a Codex-only problem.
        assert!(preflight(&root, crate::CLAUDE_CODE_ID).is_err());
    }

    #[test]
    fn an_enforcement_check_citing_an_undeclared_rule_is_a_problem() {
        let (root, _g) = scratch_root("citeless");
        let m = std::fs::read_to_string(root.join(MANIFEST_NAME)).expect("read");
        std::fs::write(
            root.join(MANIFEST_NAME),
            format!("{m}\n[[enforce]]\nrule = \"nobody-declares-this\"\nkind = \"deny-tools\"\ntools = [\"x\"]\n"),
        )
        .expect("write");
        let r = check(&root);
        assert!(r
            .problems
            .iter()
            .any(|e| matches!(e, RuleError::BrokenSelection { .. })));
    }

    #[test]
    fn a_document_over_budget_fails_explicitly_rather_than_truncating() {
        let (root, _g) = scratch_root("budget");
        let m = std::fs::read_to_string(root.join(MANIFEST_NAME)).expect("read");
        std::fs::write(
            root.join(MANIFEST_NAME),
            m.replace("max_bytes = 32768", "max_bytes = 64"),
        )
        .expect("write");
        let r = check(&root);
        assert!(r
            .problems
            .iter()
            .any(|e| matches!(e, RuleError::BudgetExceeded { .. })));
        let e = preflight(&root, crate::CODEX_ID).expect_err("refuses");
        assert!(matches!(e, RuleError::BudgetExceeded { .. }), "{e}");
    }
}
