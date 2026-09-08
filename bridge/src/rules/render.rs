//! Rendering one bundle into two entry documents, and the digests that pin it.
//!
//! # The shared core is the point
//!
//! Everything between [`CORE_BEGIN`] and [`CORE_END`] is rendered ONCE, by [`render_core`],
//! and spliced unchanged into every output. That is why the byte-identity is a property of
//! the construction rather than something a test hopes for: there is one string, and both
//! documents contain it. The test still exists ([`core_is_byte_identical_across_harnesses`])
//! because a future edit could render per harness by accident, and the test is what turns
//! that accident into a build failure.
//!
//! # What differs between the two documents, and nothing else
//!
//! The `harness=` attribute in the header, and the ADAPTER section: how this document was
//! discovered, and what this harness can actually do. Both are facts about the program, not
//! about the owner's policy, which is why they are rendered from a table in this file rather
//! than written into the canonical sources. A source may still add a harness-specific rule
//! (`scope=adapter adapters=codex`), and those bodies render into the same section.
//!
//! # Determinism
//!
//! The rendered bytes are a pure function of (manifest, source bytes). Nothing here reads a
//! clock, a hostname, an environment variable or the generator's own version: a bridge
//! version bump must not make every previously generated document read as drifted. The
//! generator version is recorded in the state sidecar, which is not an output.

use super::*;

/// The prefix every marker this module WRITES shares. A rule body carrying it is refused at
/// selection time, so a source file cannot forge the end of a generated bundle.
pub const GENERATED_SENTINEL: &str = "<!-- jesse-rules:";

/// The first line of every generated document. A file without it is not one of ours.
pub const GENERATED_BANNER: &str =
    "<!-- GENERATED FILE. DO NOT EDIT. Produced by `jesse-rules generate` from the canonical \
     rule sources listed at the end of this file. -->";

/// Opens the byte-identical shared core.
pub const CORE_BEGIN: &str = "<!-- jesse-rules:core-begin";
/// Closes the byte-identical shared core.
pub const CORE_END: &str = "<!-- jesse-rules:core-end -->";
/// Opens the source manifest block at the foot of the document.
pub const SOURCES_BEGIN: &str = "<!-- jesse-rules:sources";
/// The last line of a complete document. Its absence means a truncated write.
pub const DOC_END: &str = "<!-- jesse-rules:end";

/// A whole generation: what was read, what it hashes to, and the rules it selected.
#[derive(Debug, Clone)]
pub struct Bundle {
    pub manifest: Manifest,
    pub rules: Vec<Rule>,
    pub sources: Vec<SourceFile>,
    /// Hex SHA-256 over the canonical serialisation. Changes whenever ANYTHING that could
    /// change an output changes: a source byte, a section order, an output path, a budget,
    /// an enforcement parameter.
    pub digest: String,
    /// Hex SHA-256 over the rendered shared core alone. What both documents must agree on.
    pub core_digest: String,
}

/// Read the root and build the bundle: sources, rules, digests. No writes.
pub fn build_bundle(canon_root: &Path) -> Result<Bundle, RuleError> {
    let manifest = Manifest::load(canon_root)?;
    let sources = read_sources(canon_root, &manifest)?;
    let rules = select_rules(&sources, &manifest)?;
    let digest = canonical_digest(&manifest, &rules, &sources);
    let core = render_core_body(&manifest, &rules);
    let core_digest = crate::sha256_hex(core.as_bytes());
    Ok(Bundle {
        manifest,
        rules,
        sources,
        digest,
        core_digest,
    })
}

/// The canonical serialisation the bundle digest is taken over.
///
/// A LINE-ORIENTED TEXT FORMAT rather than a hash of the rendered documents, and the
/// difference matters: the rendered documents differ per harness, so hashing them would
/// produce two digests where the whole point is one. This hashes the INPUTS, which both
/// documents share.
///
/// Rule bodies enter as their own hash rather than inline, so the serialisation stays
/// line-oriented and a body containing a newline cannot shift the meaning of the next field.
fn canonical_digest(manifest: &Manifest, rules: &[Rule], sources: &[SourceFile]) -> String {
    let mut s = String::new();
    s.push_str(&format!("schema {}\n", manifest.schema));
    s.push_str(&format!("title {}\n", manifest.title));
    s.push_str(&format!("budget {}\n", manifest.max_bytes));
    // OMITTED WHEN IT IS THE DEFAULT, and the condition is on the EFFECTIVE reference rather
    // than on whether the table was written: a root that declares nothing and a root that
    // spells out the default render identically, so they must hash identically too. That is
    // also what keeps every already-published document's digest valid across this change.
    if manifest.reference != SourceReference::default() {
        s.push_str(&format!("reference {}\n", manifest.reference.canonical()));
    }
    for sec in &manifest.sections {
        s.push_str(&format!("section {} {}\n", sec.scope.as_str(), sec.title));
    }
    for (h, p) in &manifest.outputs {
        s.push_str(&format!("output {h} {p}\n"));
    }
    for f in sources {
        s.push_str(&format!("source {} {}\n", f.rel, f.sha256));
    }
    for r in rules {
        s.push_str(&format!(
            "rule {} {} {} triggers={} adapters={} from={} body={}\n",
            r.id,
            r.scope.as_str(),
            r.section,
            r.triggers.join(","),
            r.adapters.join(","),
            r.source,
            crate::sha256_hex(r.body.as_bytes()),
        ));
    }
    for e in &manifest.enforce {
        s.push_str(&format!("enforce {}\n", e.canonical()));
    }
    crate::sha256_hex(s.as_bytes())
}

/// The shared core, rendered once. Identical for every harness by construction.
fn render_core_body(manifest: &Manifest, rules: &[Rule]) -> String {
    let mut out = String::new();
    for sec in manifest
        .sections
        .iter()
        .filter(|s| s.scope == RuleScope::Core)
    {
        out.push_str(&format!("## {}\n\n", sec.title));
        for r in rules
            .iter()
            .filter(|r| r.scope == RuleScope::Core && r.section == sec.title)
        {
            out.push_str(&r.body);
            out.push_str("\n\n");
        }
    }
    out
}

/// The task index: every non-core rule, its verbatim prose, its declared triggers and the
/// exact source it came from.
///
/// **THE INDEX IS WHERE THE OTHER RULES SURVIVE.** The failure this guards against is a
/// migration that ships a short core and quietly loses everything the old index carried, so
/// every task rule is rendered in full with its own source reference; nothing is summarised
/// and nothing is dropped.
fn render_task_index(manifest: &Manifest, rules: &[Rule]) -> String {
    let mut out = String::new();
    for sec in manifest
        .sections
        .iter()
        .filter(|s| s.scope == RuleScope::Task)
    {
        out.push_str(&format!("## {}\n\n", sec.title));
        for r in rules
            .iter()
            .filter(|r| r.scope == RuleScope::Task && r.section == sec.title)
        {
            out.push_str(&r.body);
            out.push('\n');
            out.push_str(&format!(
                "  *Load when:* {}. *Source:* {} (rule `{}`).\n\n",
                r.triggers.join(", "),
                manifest.reference.render(&r.source),
                r.id
            ));
        }
    }
    out
}

/// What one harness is told about itself: how it got this document, and what it can do.
///
/// A TABLE IN CODE, not text in the vault, because every line of it is a statement about a
/// program rather than about the owner. The loading mechanics are what this repository
/// actually implements (a fresh child per turn, discovery from the working directory) and
/// the capability sentence is what that harness's containment levers actually are.
struct Adapter {
    id: &'static str,
    /// The file name this harness discovers.
    doc: &'static str,
    /// How the document reaches the model, and what that does and does not survive.
    loading: &'static str,
    /// What this harness can actually do, stated so a rule written for the other one does
    /// not get narrated rather than refused.
    capabilities: &'static str,
}

const ADAPTERS: &[Adapter] = &[
    Adapter {
        id: crate::CLAUDE_CODE_ID,
        doc: "CLAUDE.md",
        loading:
            "Claude Code discovers this file in its working directory when the process starts. \
             The bridge starts a fresh process for every turn, so this core is loaded again on \
             a new conversation, on a resumed one, and after a bridge restart. It is not \
             reloaded by a turn that compacts its own context part way through: after a \
             compaction, re-read this file before doing anything else.",
        capabilities:
            "This harness has file reads and edits, a shell, and the MCP servers named in the \
             turn's configuration, all bounded by a per-turn tool allowlist. A tool that was \
             not granted does not exist for this turn. Say plainly that you could not do \
             something rather than describing having done it.",
    },
    Adapter {
        id: crate::CODEX_ID,
        doc: "AGENTS.md",
        loading: "Codex discovers this file in its working directory when the process starts. The \
             bridge starts a fresh process with a fresh home for every turn, so this core is \
             loaded again on a new conversation, on a resumed one, and after a bridge restart. \
             It is not reloaded by a turn that compacts its own context part way through: \
             after a compaction, re-read this file before doing anything else.",
        capabilities:
            "This harness has file reads and edits, a shell, and the MCP servers named in the \
             turn's configuration, bounded by an operating system sandbox whose writable roots \
             are the turn's working directory. A refusal from the sandbox is a boundary, not \
             an error to work around. Say plainly that you could not do something rather than \
             describing having done it.",
    },
];

fn adapter(id: &str) -> Option<&'static Adapter> {
    ADAPTERS.iter().find(|a| a.id == id)
}

/// Which generated document a harness reads.
///
/// `direct` is the interesting entry: it has no child process and no working directory, so
/// it discovers nothing. It loads the vault's `CLAUDE.md` itself (see
/// `harness::direct::load_operating_manual`), which is the claude-code output. Naming that
/// here is what keeps the in-process harness on the same bundle as the spawned one instead
/// of quietly reading whatever file happens to be at that path.
pub fn document_harness(harness_id: &str) -> &str {
    match harness_id {
        crate::DIRECT_ID => crate::CLAUDE_CODE_ID,
        other => other,
    }
}

/// Render the entry document for one harness.
pub fn render_for(bundle: &Bundle, harness: &str) -> Result<String, RuleError> {
    let Some(out_rel) = bundle.manifest.outputs.get(harness) else {
        return Err(RuleError::InvalidManifest(format!(
            "[outputs] has no entry for harness `{harness}`"
        )));
    };
    let core = render_core_body(&bundle.manifest, &bundle.rules);
    let mut s = String::with_capacity(8 * 1024);

    s.push_str(GENERATED_BANNER);
    s.push('\n');
    s.push_str(&format!(
        "<!-- jesse-rules: schema={} harness={} digest={} core={} -->\n\n",
        bundle.manifest.schema, harness, bundle.digest, bundle.core_digest
    ));
    s.push_str(&format!("# {}\n\n", bundle.manifest.title));
    s.push_str(
        "This file is generated. Editing it here is lost on the next generation: change the \
         rule in its own source file, listed at the end of each entry, and regenerate. The \
         block below is the mandatory core and is byte for byte the same in every harness's \
         copy.\n\n",
    );

    s.push_str(&format!("{CORE_BEGIN} core={} -->\n", bundle.core_digest));
    s.push_str(&core);
    s.push_str(CORE_END);
    s.push_str("\n\n");

    s.push_str(&render_task_index(&bundle.manifest, &bundle.rules));

    // ---- The adapter section: the only place the two documents differ ----------------
    for sec in bundle
        .manifest
        .sections
        .iter()
        .filter(|x| x.scope == RuleScope::Adapter)
    {
        s.push_str(&format!("## {}\n\n", sec.title));
        match adapter(harness) {
            Some(a) => {
                s.push_str(&format!(
                    "This document is `{}`, and `{}` is the harness reading it.\n\n{}\n\n{}\n\n",
                    a.doc, a.id, a.loading, a.capabilities
                ));
            }
            // A harness with no entry here still gets a document, and it says exactly what is
            // known about it rather than borrowing another harness's sentences. Silence would
            // have been the alternative, and a document that says nothing about its own
            // reloading behaviour is the one that gets assumed to reload.
            None => {
                s.push_str(&format!(
                    "This document is `{out_rel}`, and `{harness}` is the harness reading it. \
                     This build carries no verified description of how `{harness}` loads or \
                     reloads it, so assume it is loaded once when the turn starts and re-read \
                     it after any context compaction.\n\n"
                ));
            }
        }
        for r in bundle
            .rules
            .iter()
            .filter(|r| r.scope == RuleScope::Adapter && r.section == sec.title)
            .filter(|r| r.adapters.iter().any(|a| a == harness))
        {
            s.push_str(&r.body);
            s.push_str(&format!(
                "\n  *Source:* {} (rule `{}`).\n\n",
                bundle.manifest.reference.render(&r.source),
                r.id
            ));
        }
    }

    // ---- Provenance -----------------------------------------------------------------
    s.push_str(SOURCES_BEGIN);
    s.push('\n');
    for f in &bundle.sources {
        s.push_str(&format!("{} {}\n", f.rel, f.sha256));
    }
    s.push_str("-->\n");
    s.push_str(&format!("{DOC_END} digest={} -->\n", bundle.digest));
    Ok(s)
}

/// Render every declared output. The one entry point publication uses, so a caller cannot
/// publish one document without the other.
pub fn render_all(bundle: &Bundle) -> Result<Vec<RenderedOutput>, RuleError> {
    let mut out = Vec::new();
    for (harness, rel) in &bundle.manifest.outputs {
        let text = render_for(bundle, harness)?;
        if text.len() > bundle.manifest.max_bytes {
            return Err(RuleError::BudgetExceeded {
                harness: harness.clone(),
                bytes: text.len(),
                max: bundle.manifest.max_bytes,
            });
        }
        out.push(RenderedOutput {
            harness: harness.clone(),
            rel: rel.clone(),
            text,
        });
    }
    Ok(out)
}

/// One rendered entry document, before it is anywhere near the filesystem.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderedOutput {
    pub harness: String,
    pub rel: String,
    pub text: String,
}

// ---- Reading a generated document back --------------------------------------

/// What a generated document says about itself, parsed back out of its own bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentHeader {
    pub schema: u32,
    pub harness: String,
    pub digest: String,
    pub core_digest: String,
    /// The declared source hashes, in file order.
    pub sources: Vec<(String, String)>,
    /// The exact bytes between the core markers.
    pub core: String,
    /// Total document length in bytes.
    pub bytes: usize,
}

/// Parse a generated document, refusing anything incomplete.
///
/// **INCOMPLETENESS IS THE INTERESTING FAILURE**, not malformation: a document truncated by
/// an interrupted write parses fine as Markdown and is missing the rules at the end of it.
/// Every structural element is therefore required, and the closing `digest=` must equal the
/// header's: those two are written at opposite ends of the file, so a partial write cannot
/// produce a document where they agree.
pub fn parse_document(harness: &str, text: &str) -> Result<DocumentHeader, RuleError> {
    let bad = |detail: String| RuleError::IncompleteOutput {
        harness: harness.to_string(),
        detail,
    };
    if !text.starts_with(GENERATED_BANNER) {
        return Err(bad(
            "does not begin with the generated-file banner; it was not produced by \
             `jesse-rules generate`"
                .to_string(),
        ));
    }
    let header_line = text
        .lines()
        .nth(1)
        .ok_or_else(|| bad("has no header line".to_string()))?;
    let attrs = header_attrs(header_line)
        .ok_or_else(|| bad(format!("has an unreadable header line: {header_line}")))?;
    let schema: u32 = attrs
        .get("schema")
        .and_then(|v| v.parse().ok())
        .ok_or_else(|| bad("header has no readable `schema`".to_string()))?;
    if schema != SCHEMA_VERSION {
        return Err(bad(format!(
            "was generated at schema {schema}; this build understands {SCHEMA_VERSION}"
        )));
    }
    let doc_harness = attrs
        .get("harness")
        .cloned()
        .ok_or_else(|| bad("header has no `harness`".to_string()))?;
    if doc_harness != harness {
        return Err(bad(format!(
            "declares harness `{doc_harness}` but was read as `{harness}`"
        )));
    }
    let digest = attrs
        .get("digest")
        .cloned()
        .ok_or_else(|| bad("header has no `digest`".to_string()))?;
    let core_digest = attrs
        .get("core")
        .cloned()
        .ok_or_else(|| bad("header has no `core` digest".to_string()))?;

    // The core, taken as the exact bytes between the two marker LINES.
    let core_open_at = text
        .find(CORE_BEGIN)
        .ok_or_else(|| bad("has no core-begin marker".to_string()))?;
    let after_open = text[core_open_at..]
        .find("-->\n")
        .map(|i| core_open_at + i + 4)
        .ok_or_else(|| bad("core-begin marker is not closed".to_string()))?;
    let core_close_at = text
        .find(CORE_END)
        .ok_or_else(|| bad("has no core-end marker".to_string()))?;
    if core_close_at < after_open {
        return Err(bad("core markers are out of order".to_string()));
    }
    let core = text[after_open..core_close_at].to_string();
    if crate::sha256_hex(core.as_bytes()) != core_digest {
        return Err(bad(
            "the core block does not hash to the `core` digest in its own header".to_string(),
        ));
    }

    // Provenance.
    let sources_at = text
        .find(SOURCES_BEGIN)
        .ok_or_else(|| bad("has no source manifest block".to_string()))?;
    let sources_body_at = sources_at + SOURCES_BEGIN.len();
    let sources_end = text[sources_body_at..]
        .find("\n-->")
        .map(|i| sources_body_at + i)
        .ok_or_else(|| bad("source manifest block is not closed".to_string()))?;
    let mut sources = Vec::new();
    for line in text[sources_body_at..sources_end].lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let mut parts = line.rsplitn(2, ' ');
        let hash = parts.next().unwrap_or_default().to_string();
        let rel = parts.next().unwrap_or_default().to_string();
        if rel.is_empty() || hash.len() != 64 {
            return Err(bad(format!("source manifest line is unreadable: {line}")));
        }
        sources.push((rel, hash));
    }
    if sources.is_empty() {
        return Err(bad("source manifest block is empty".to_string()));
    }

    // The closing line, which is what a truncated write does not have.
    let end_at = text
        .rfind(DOC_END)
        .ok_or_else(|| bad("has no closing marker; the write was truncated".to_string()))?;
    let end_attrs = header_attrs(&text[end_at..])
        .ok_or_else(|| bad("closing marker is unreadable".to_string()))?;
    match end_attrs.get("digest") {
        Some(d) if *d == digest => {}
        Some(d) => {
            return Err(bad(format!(
                "opens with digest {digest} and closes with {d}; this file is a mix of two \
                 generations"
            )))
        }
        None => return Err(bad("closing marker has no digest".to_string())),
    }

    Ok(DocumentHeader {
        schema,
        harness: doc_harness,
        digest,
        core_digest,
        sources,
        core,
        bytes: text.len(),
    })
}

/// `k=v` pairs off one marker line. Values are unquoted words; the generator writes no
/// quoted values into a header, so a quoted value here would be a hand edit.
fn header_attrs(line: &str) -> Option<HashMap<String, String>> {
    let start = line.find("<!--")?;
    let end = line[start..].find("-->")? + start;
    let body = &line[start + 4..end];
    let mut out = HashMap::new();
    for tok in body.split_whitespace() {
        if let Some((k, v)) = tok.split_once('=') {
            out.insert(k.to_string(), v.to_string());
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    pub(crate) const FIXTURE_MANIFEST: &str = r#"
schema = 1
title = "Working Rules"
sources = ["hard.md", "guides.md"]

[[section]]
title = "Hard Rules (read first)"
scope = "core"

[[section]]
title = "Task Guidance"
scope = "task"

[[section]]
title = "This Harness"
scope = "adapter"

[outputs]
claude-code = "CLAUDE.md"
codex = "AGENTS.md"
"#;

    fn bundle() -> Bundle {
        bundle_with(FIXTURE_MANIFEST, "guides.md")
    }

    /// The same two fixture sources, under a manifest and a task-source path the caller
    /// chooses. Parameterised so the reference-style tests can put the routed rule in a
    /// NESTED file and then move it, which is the case a bare path reference gets wrong.
    fn bundle_with(manifest_src: &str, guides_rel: &str) -> Bundle {
        let manifest = Manifest::parse(manifest_src).expect("manifest");
        let hard = "<!-- jesse-rule: id=no-outbound scope=core section=\"Hard Rules (read first)\" -->\n- **Never send outbound communication.** Draft it and stop.\n<!-- /jesse-rule -->\n";
        let guides = "<!-- jesse-rule: id=meeting-agendas scope=task section=\"Task Guidance\" triggers=\"meeting, agenda\" -->\n- **Meeting agendas:** keep them fresh until the meeting starts.\n<!-- /jesse-rule -->\n<!-- jesse-rule: id=codex-shell scope=adapter section=\"This Harness\" adapters=\"codex\" -->\n- The sandbox refusal is the boundary.\n<!-- /jesse-rule -->\n";
        let sources = vec![
            SourceFile {
                rel: "hard.md".to_string(),
                sha256: crate::sha256_hex(hard.as_bytes()),
                text: hard.to_string(),
            },
            SourceFile {
                rel: guides_rel.to_string(),
                sha256: crate::sha256_hex(guides.as_bytes()),
                text: guides.to_string(),
            },
        ];
        let rules = select_rules(&sources, &manifest).expect("selects");
        let digest = canonical_digest(&manifest, &rules, &sources);
        let core_digest = crate::sha256_hex(render_core_body(&manifest, &rules).as_bytes());
        Bundle {
            manifest,
            rules,
            sources,
            digest,
            core_digest,
        }
    }

    /// `FIXTURE_MANIFEST` with the task source moved to `rel` and `extra` appended.
    fn manifest_src(rel: &str, extra: &str) -> String {
        format!(
            "{}{extra}",
            FIXTURE_MANIFEST.replace(
                "sources = [\"hard.md\", \"guides.md\"]",
                &format!("sources = [\"hard.md\", \"{rel}\"]"),
            )
        )
    }

    const WIKI: &str = "\n[reference]\nstyle = \"wiki-link\"\n";

    #[test]
    fn core_is_byte_identical_across_harnesses() {
        let b = bundle();
        let cc = render_for(&b, "claude-code").expect("renders");
        let cx = render_for(&b, "codex").expect("renders");
        let a = parse_document("claude-code", &cc).expect("parses");
        let c = parse_document("codex", &cx).expect("parses");
        assert_eq!(a.core, c.core, "the mandatory core must be byte-identical");
        assert_eq!(a.core_digest, c.core_digest);
        assert_eq!(a.digest, c.digest, "one bundle, one digest");
    }

    #[test]
    fn the_documents_differ_only_in_their_adapter() {
        let b = bundle();
        let cc = render_for(&b, "claude-code").expect("renders");
        let cx = render_for(&b, "codex").expect("renders");
        assert_ne!(cc, cx);
        assert!(cx.contains("The sandbox refusal is the boundary."));
        assert!(
            !cc.contains("The sandbox refusal is the boundary."),
            "an adapter rule must not leak into the other harness's document"
        );
        assert!(cc.contains("CLAUDE.md"));
        assert!(cx.contains("AGENTS.md"));
    }

    #[test]
    fn every_task_rule_keeps_its_prose_its_triggers_and_its_source() {
        let b = bundle();
        let cc = render_for(&b, "claude-code").expect("renders");
        assert!(cc.contains("- **Meeting agendas:** keep them fresh until the meeting starts."));
        assert!(cc.contains("*Load when:* meeting, agenda."));
        assert!(cc.contains("*Source:* `guides.md` (rule `meeting-agendas`)."));
    }

    #[test]
    fn rendering_is_idempotent_and_carries_no_clock() {
        let b = bundle();
        let one = render_for(&b, "codex").expect("renders");
        let two = render_for(&b, "codex").expect("renders");
        assert_eq!(one, two);
        let three = render_for(&bundle(), "codex").expect("renders");
        assert_eq!(
            one, three,
            "a fresh build of the same inputs renders the same bytes"
        );
    }

    #[test]
    fn a_truncated_document_is_incomplete_rather_than_accepted() {
        let b = bundle();
        let full = render_for(&b, "codex").expect("renders");
        let cut = &full[..full.len() - 40];
        let e = parse_document("codex", cut).expect_err("refuses");
        assert!(matches!(e, RuleError::IncompleteOutput { .. }), "{e}");
    }

    #[test]
    fn a_mixed_generation_is_detected_at_the_two_ends() {
        let b = bundle();
        let full = render_for(&b, "codex").expect("renders");
        // Simulate an interrupted publication: the head of one generation, the tail of another.
        let other = full.replacen(&b.digest, &"0".repeat(64), 1);
        let e = parse_document("codex", &other).expect_err("refuses");
        assert!(e.to_string().contains("mix of two generations"), "{e}");
    }

    #[test]
    fn a_hand_edited_core_fails_its_own_digest() {
        let b = bundle();
        let full = render_for(&b, "claude-code").expect("renders");
        let tampered = full.replace("Draft it and stop.", "Send it if asked twice.");
        let e = parse_document("claude-code", &tampered).expect_err("refuses");
        assert!(e.to_string().contains("does not hash"), "{e}");
    }

    #[test]
    fn the_direct_harness_reads_the_claude_code_document() {
        assert_eq!(document_harness(crate::DIRECT_ID), crate::CLAUDE_CODE_ID);
        assert_eq!(document_harness(crate::CODEX_ID), crate::CODEX_ID);
    }

    // ---- The reference a rendered rule carries ------------------------------------

    #[test]
    fn a_root_that_declares_nothing_keeps_the_bare_path_reference() {
        let b = bundle();
        let cc = render_for(&b, "claude-code").expect("renders");
        // The exact string the release before this field shipped; the byte-for-byte proof
        // over whole documents is `the_default_reference_renders_both_documents_byte_for_byte`
        // in tests/rules_scenarios.rs.
        assert!(
            cc.contains("*Source:* `guides.md` (rule `meeting-agendas`)."),
            "{cc}"
        );
    }

    #[test]
    fn a_declared_wiki_link_style_renders_a_followable_reference() {
        let src = manifest_src("Knowledge/Guides/Meeting-Agendas.md", WIKI);
        let b = bundle_with(&src, "Knowledge/Guides/Meeting-Agendas.md");
        let cc = render_for(&b, "claude-code").expect("renders");
        assert!(
            cc.contains("*Source:* [[Knowledge/Guides/Meeting-Agendas]] (rule `meeting-agendas`)."),
            "the nested source did not render as a link with its extension dropped:\n{cc}"
        );
        assert!(
            !cc.contains("*Source:* `"),
            "a bare path reference survived alongside the link:\n{cc}"
        );

        // THE CASE THIS FIELD EXISTS FOR: the same rule moved to a different source file
        // still renders a reference a reader can follow, rather than inert prose.
        let moved = "Knowledge/Guides/Meetings/Agendas.md";
        let b = bundle_with(&manifest_src(moved, WIKI), moved);
        let cc = render_for(&b, "claude-code").expect("renders");
        assert!(
            cc.contains(
                "*Source:* [[Knowledge/Guides/Meetings/Agendas]] (rule `meeting-agendas`)."
            ),
            "{cc}"
        );

        // Both render sites, not just the routed index: the adapter section carries the same
        // reference and would otherwise keep emitting a bare path.
        let cx = render_for(&b, "codex").expect("renders");
        assert!(
            cx.contains("*Source:* [[Knowledge/Guides/Meetings/Agendas]] (rule `codex-shell`)."),
            "the adapter section kept the old reference:\n{cx}"
        );
    }

    #[test]
    fn the_affixes_rewrite_the_leading_segment_of_the_link() {
        let rel = "notes/Guides/Agendas.md";
        let src = manifest_src(
            rel,
            "\n[reference]\nstyle = \"wiki-link\"\nstrip_prefix = \"notes/\"\nprefix = \"collection/\"\n",
        );
        let b = bundle_with(&src, rel);
        let cc = render_for(&b, "claude-code").expect("renders");
        assert!(
            cc.contains("*Source:* [[collection/Guides/Agendas]] "),
            "{cc}"
        );
    }

    #[test]
    fn declaring_a_reference_style_moves_the_bundle_digest() {
        // Otherwise identical inputs: same sources, same sections, same outputs.
        let plain = bundle_with(&manifest_src("guides.md", ""), "guides.md");
        let linked = bundle_with(&manifest_src("guides.md", WIKI), "guides.md");
        assert_eq!(
            plain.sources, linked.sources,
            "the inputs must be identical"
        );
        assert_ne!(
            plain.digest, linked.digest,
            "a turn reading a stale bundle could not tell the reference style had changed"
        );

        // And the digest is over the EFFECTIVE reference, not over whether the table exists:
        // spelling out the default renders the same bytes, so it must hash the same.
        let spelled = bundle_with(
            &manifest_src("guides.md", "\n[reference]\nstyle = \"path\"\n"),
            "guides.md",
        );
        assert_eq!(plain.digest, spelled.digest);
        assert_eq!(
            render_for(&plain, "claude-code").expect("renders"),
            render_for(&spelled, "claude-code").expect("renders")
        );
    }

    #[test]
    fn an_unusable_reference_declaration_is_refused_by_name() {
        for (extra, needle) in [
            (
                "\n[reference]\nstyle = \"obsidian\"\n",
                "\"obsidian\" is not one of path/wiki-link",
            ),
            (
                "\n[reference]\nstyle = \"wiki-link\"\nlink = \"x\"\n",
                "unknown key `link`",
            ),
            ("\n[reference]\nstyle = 3\n", "`style` is not a string"),
            ("\n[reference]\nprefix = 3\n", "`prefix` is not a string"),
            ("\n[reference]\nprefix = \"a\\nb\"\n", "control character"),
        ] {
            let e = Manifest::parse(&manifest_src("guides.md", extra))
                .expect_err("the manifest is refused");
            assert!(
                e.to_string().contains(needle),
                "expected `{needle}`, got: {e}"
            );
        }
        // A bare key rather than a table. Written at the TOP, because appending it would
        // make it a key of whichever table the manifest ends with.
        let e = Manifest::parse(&format!("reference = \"wiki-link\"{FIXTURE_MANIFEST}"))
            .expect_err("the manifest is refused");
        assert!(e.to_string().contains("must be a table"), "{e}");
    }

    #[test]
    fn only_the_last_extension_of_the_last_segment_is_dropped() {
        let r = SourceReference {
            style: ReferenceStyle::WikiLink,
            ..Default::default()
        };
        assert_eq!(r.render("a.b/Notes.v2.md"), "[[a.b/Notes.v2]]");
        assert_eq!(r.render("Guides/README"), "[[Guides/README]]");
        // A dotfile's leading dot is its whole name, not an extension to strip.
        assert_eq!(r.render("Guides/.keep"), "[[Guides/.keep]]");
    }

    #[test]
    fn a_harness_with_no_adapter_entry_still_gets_an_honest_document() {
        let mut b = bundle();
        b.manifest
            .outputs
            .insert("someday".to_string(), "SOMEDAY.md".to_string());
        let text = render_for(&b, "someday").expect("renders");
        assert!(text.contains("no verified description of how `someday` loads"));
    }
}
