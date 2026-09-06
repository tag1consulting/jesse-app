//! **ONE CANONICAL SOURCE OF RULES, TWO GENERATED ENTRY DOCUMENTS, ONE SHARED CORE.**
//!
//! Claude Code discovers `CLAUDE.md` in its working directory; Codex discovers `AGENTS.md`
//! in the same place. Before this module the two files were written and maintained
//! separately, which is a guarantee that they drift: the same rule said twice is two rules
//! the moment either is edited. What this module does is make both of them OUTPUTS of one
//! generation, with a byte-identical shared core, so the drift has nowhere to happen.
//!
//! # The shape, in one paragraph
//!
//! Canonical Markdown (the owner's own guideline files) carries EXPLICITLY MARKED rule
//! blocks. A manifest at the source root names which files may contribute, in what order,
//! under which section headings, and which of the mechanically enforceable checks apply with
//! what parameters. [`select_rules`] reads the marked blocks verbatim; [`render_bundle`]
//! renders one bundle into two entry documents; [`publish`] writes both as one validated
//! generation; [`check`] detects every way the result can be wrong; [`preflight`] is the
//! cheap per-turn verification the bridge runs before a turn that depends on the bundle.
//!
//! # What the metadata may and may not be
//!
//! **Metadata SELECTS content. It never restates it.** A marker carries an id, a scope, a
//! section and (for task rules) the triggers that route to it — never the rule's own words.
//! The prose between the markers is copied byte for byte into the generated documents, so
//! there is exactly one place any rule is written down and the generated copies are
//! disposable. A schema that let a marker carry a `summary=` attribute would have
//! reintroduced the second handwritten copy this whole module exists to remove.
//!
//! # What a digest proves
//!
//! Every generated document carries the bundle digest, and the bridge logs it for each turn
//! it supplies. **That proves what was SUPPLIED, and nothing about what the model then did.**
//! No part of this module claims model compliance; the enforceable subset is exactly
//! [`enforce`], which acts at real action boundaries, and everything else is an instruction
//! with a behaviour test.
//!
//! # Not policy, mechanism
//!
//! Nothing in this module contains the owner's rules. The check KINDS live here (a filename
//! pattern, a forbidden substring, a denied tool name); their PARAMETERS come from the
//! manifest in the source root, which is a private repository. The fixtures under
//! `bridge/tests/fixtures/rules/` are representative test data written for this repository,
//! not a copy of anyone's guidelines.

use crate::*;

mod check;
mod enforce;
mod publish;
mod render;

pub use check::*;
pub use enforce::*;
pub use publish::*;
pub use render::*;

use std::collections::{BTreeMap, BTreeSet};

/// The schema version written into every generated document and into the state sidecar.
///
/// A document whose schema is not this one is REFUSED rather than parsed leniently: the
/// header is the only thing standing between "this file is a generated bundle" and "this
/// file is a note somebody wrote", and a lenient parser makes that distinction negotiable.
pub const SCHEMA_VERSION: u32 = 1;

/// The manifest's file name, at the configured source root.
pub const MANIFEST_NAME: &str = "jesse-rules.toml";

/// The directory (under the source root) holding the state sidecar and the recoverable
/// previous generation. Dot-prefixed so Obsidian and the vault's own tooling ignore it.
pub const STATE_DIR: &str = ".jesse-rules";

/// The sidecar recording what was last published: per-output bytes hash, per-source hash and
/// the bundle digest. It is what makes "this output was edited by hand" detectable at all.
pub const STATE_FILE: &str = "state.json";

/// Where [`publish`] copies the outgoing generation before overwriting it.
pub const PREVIOUS_DIR: &str = "previous";

/// The suffix of the temp file each output is written to before being renamed into place.
pub const TMP_SUFFIX: &str = ".jesse-rules-tmp";

// ---- Errors -----------------------------------------------------------------

/// Everything that can go wrong reading, rendering or publishing a bundle.
///
/// ONE enum rather than per-stage error types, because every consumer does the same thing
/// with them: refuse the work, and say which of the sources or outputs is at fault. The
/// `Display` text is written to be read by whoever has to go fix the file — it names the
/// path and, where there is one, the line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuleError {
    /// The manifest is absent at the configured root.
    MissingManifest(PathBuf),
    /// The manifest is present but cannot be understood.
    InvalidManifest(String),
    /// A declared source file could not be read.
    MissingSource { rel: String, detail: String },
    /// A path in the manifest, or a symlink under the root, resolves outside the root.
    PathEscape { rel: String, detail: String },
    /// A rule marker is malformed, unterminated, nested, or carries an unknown attribute.
    InvalidMetadata {
        rel: String,
        line: usize,
        detail: String,
    },
    /// The same rule id appears twice.
    DuplicateId {
        id: String,
        first: String,
        second: String,
    },
    /// A rule names a section the manifest does not declare, or a section whose scope
    /// disagrees with the rule's own.
    BrokenSelection { id: String, detail: String },
    /// A declared output path is also a declared source path.
    OutputIsSource(String),
    /// A generated document is absent, truncated, or missing its markers.
    IncompleteOutput { harness: String, detail: String },
    /// The two generated documents do not carry the same core.
    CoreDivergence(String),
    /// The generated documents no longer match what the sources say.
    Stale(String),
    /// An output's bytes differ from what the state sidecar says was published.
    ManuallyChanged { harness: String, path: PathBuf },
    /// The sources changed while the generation was being built.
    ConcurrentEdit(String),
    /// A rendered document exceeds the configured instruction budget.
    BudgetExceeded {
        harness: String,
        bytes: usize,
        max: usize,
    },
    /// Filesystem trouble that is nobody's policy mistake.
    Io { what: String, detail: String },
}

impl std::fmt::Display for RuleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RuleError::MissingManifest(p) => write!(
                f,
                "no rule manifest at {} — a rules root must carry {MANIFEST_NAME}",
                p.display()
            ),
            RuleError::InvalidManifest(d) => write!(f, "the rule manifest is invalid: {d}"),
            RuleError::MissingSource { rel, detail } => {
                write!(
                    f,
                    "declared rule source `{rel}` could not be read: {detail}"
                )
            }
            RuleError::PathEscape { rel, detail } => {
                write!(f, "`{rel}` resolves outside the rules root: {detail}")
            }
            RuleError::InvalidMetadata { rel, line, detail } => {
                write!(f, "{rel}:{line}: invalid rule metadata: {detail}")
            }
            RuleError::DuplicateId { id, first, second } => write!(
                f,
                "rule id `{id}` is declared twice, in {first} and in {second} — ids are the \
                 selection key and must be unique across every source"
            ),
            RuleError::BrokenSelection { id, detail } => {
                write!(f, "rule `{id}` selects nothing usable: {detail}")
            }
            RuleError::OutputIsSource(rel) => write!(
                f,
                "`{rel}` is declared as both a rule source and a generated output — a \
                 generated file cannot be its own input, and publishing would destroy the \
                 rules it carries"
            ),
            RuleError::IncompleteOutput { harness, detail } => {
                write!(f, "the {harness} entry document is incomplete: {detail}")
            }
            RuleError::CoreDivergence(d) => write!(
                f,
                "the generated entry documents do not carry the same mandatory core: {d}"
            ),
            RuleError::Stale(d) => write!(
                f,
                "the generated entry documents no longer match the rule sources: {d}"
            ),
            RuleError::ManuallyChanged { harness, path } => write!(
                f,
                "{} was changed by hand since it was generated (harness {harness}) — \
                 re-publishing would discard that edit; move the change into the rule source \
                 it belongs to, or re-publish with --force to discard it",
                path.display()
            ),
            RuleError::ConcurrentEdit(d) => write!(
                f,
                "a rule source changed while this generation was being built ({d}) — nothing \
                 was published; run the generation again"
            ),
            RuleError::BudgetExceeded {
                harness,
                bytes,
                max,
            } => write!(
                f,
                "the {harness} entry document is {bytes} bytes, over the configured \
                 instruction budget of {max} — a document that does not fit is a document \
                 whose tail is silently missing, so this fails rather than truncates"
            ),
            RuleError::Io { what, detail } => write!(f, "{what}: {detail}"),
        }
    }
}

impl std::error::Error for RuleError {}

impl RuleError {
    pub(crate) fn io(what: impl Into<String>, e: std::io::Error) -> Self {
        RuleError::Io {
            what: what.into(),
            detail: e.to_string(),
        }
    }
}

// ---- The schema -------------------------------------------------------------

/// Where a rule goes in the generated documents.
///
/// Three scopes and no more. `Core` is the short mandatory block both harnesses carry
/// byte-identically; `Task` is the routed index, which preserves every other rule and its
/// source reference; `Adapter` is the small set of statements that are genuinely
/// harness-specific and therefore CANNOT be shared without being wrong somewhere.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum RuleScope {
    /// Mandatory for every turn on every harness. Rendered into the shared core.
    Core,
    /// Loaded when its triggers match. Rendered into the task index with its exact source.
    Task,
    /// True of one harness and not another. Rendered only into that harness's document.
    Adapter,
}

impl RuleScope {
    pub fn as_str(self) -> &'static str {
        match self {
            RuleScope::Core => "core",
            RuleScope::Task => "task",
            RuleScope::Adapter => "adapter",
        }
    }
    fn parse(s: &str) -> Option<Self> {
        match s {
            "core" => Some(RuleScope::Core),
            "task" => Some(RuleScope::Task),
            "adapter" => Some(RuleScope::Adapter),
            _ => None,
        }
    }
}

/// One rule, as selected from canonical Markdown.
///
/// `body` is VERBATIM. Nothing in this module rewrites, wraps, summarises or reflows it —
/// the generated documents are a concatenation of these bodies under section headings, which
/// is what makes "the generated copy is disposable" true rather than aspirational.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    pub id: String,
    pub scope: RuleScope,
    pub section: String,
    /// Declared routing triggers, lowercased and de-duplicated. Empty for a core rule.
    pub triggers: Vec<String>,
    /// Harness ids this rule applies to. EMPTY MEANS EVERY HARNESS, which is the only
    /// sensible default for a core rule and the reason an `adapter` rule must name one.
    pub adapters: Vec<String>,
    /// The root-relative source file, reproduced in the task index so a model can open it.
    pub source: String,
    /// 1-based line of the opening marker, for error messages.
    pub line: usize,
    /// The prose between the markers, verbatim, with the trailing newline normalised.
    pub body: String,
}

/// One section heading in the generated documents, and the scope it holds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SectionSpec {
    pub title: String,
    pub scope: RuleScope,
}

/// The manifest at the source root: what may contribute, in what order, and what is checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    pub schema: u32,
    /// Declared sources, root-relative, IN ORDER. No globs, deliberately: a glob makes
    /// "which files are policy" a property of the filesystem at generation time, so a note
    /// dropped in the right directory would become binding without anyone deciding it.
    pub sources: Vec<String>,
    /// Section headings in render order.
    pub sections: Vec<SectionSpec>,
    /// Harness id to root-relative output path. Sorted, so rendering is deterministic.
    pub outputs: BTreeMap<String, String>,
    /// The per-document instruction budget in bytes.
    pub max_bytes: usize,
    /// The document title rendered as the `#` heading of both outputs.
    pub title: String,
    /// The mechanically enforceable checks, with their parameters.
    pub enforce: Vec<EnforceSpec>,
}

/// The default per-document budget when a manifest does not set one.
///
/// **A POLICY BUDGET, NOT A MEASURED CLI LIMIT.** Neither Claude Code nor codex-cli
/// documents a hard ceiling on the size of its discovered instruction file, and this
/// repository has not measured one, so naming a number here as "the harness limit" would be
/// a claim nobody verified. What the number IS: the size beyond which an entry document has
/// stopped being an entry document, chosen so the mandatory core plus a routed index fits
/// comfortably and a pasted-in essay does not. Override it in the manifest.
pub const DEFAULT_MAX_BYTES: usize = 32 * 1024;

impl Manifest {
    /// Parse a manifest from TOML.
    ///
    /// Hand-walked from `toml::Table` rather than derived, for the reason `assert_no_user_config`
    /// walks its table by hand: the `toml` dependency is built with `default-features = false,
    /// features = ["parse"]` so the serde derive is not available, and every unknown key must
    /// be an ERROR rather than a silently ignored field. A manifest with `sorces = [...]` in it
    /// must fail loudly, not generate an empty bundle.
    pub fn parse(text: &str) -> Result<Manifest, RuleError> {
        let doc: toml::Table = text
            .parse()
            .map_err(|e| RuleError::InvalidManifest(format!("not valid TOML: {e}")))?;

        let schema = match doc.get("schema").and_then(|v| v.as_integer()) {
            Some(n) if n == SCHEMA_VERSION as i64 => SCHEMA_VERSION,
            Some(n) => {
                return Err(RuleError::InvalidManifest(format!(
                    "schema = {n}, but this build understands schema {SCHEMA_VERSION}"
                )))
            }
            None => {
                return Err(RuleError::InvalidManifest(
                    "no `schema` integer at the top level".to_string(),
                ))
            }
        };

        let title = doc
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("Working Rules")
            .to_string();

        let sources = string_list(&doc, "sources")?;
        if sources.is_empty() {
            return Err(RuleError::InvalidManifest(
                "`sources` is empty — a bundle with no declared source selects nothing".to_string(),
            ));
        }

        let mut sections = Vec::new();
        match doc.get("section") {
            Some(toml::Value::Array(items)) => {
                for (i, item) in items.iter().enumerate() {
                    let t = item.as_table().ok_or_else(|| {
                        RuleError::InvalidManifest(format!("[[section]] {i} is not a table"))
                    })?;
                    let title = t
                        .get("title")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| {
                            RuleError::InvalidManifest(format!("[[section]] {i} has no `title`"))
                        })?
                        .to_string();
                    let scope_s = t.get("scope").and_then(|v| v.as_str()).ok_or_else(|| {
                        RuleError::InvalidManifest(format!("[[section]] `{title}` has no `scope`"))
                    })?;
                    let scope = RuleScope::parse(scope_s).ok_or_else(|| {
                        RuleError::InvalidManifest(format!(
                            "[[section]] `{title}` has scope `{scope_s}`, which is not one of \
                             core/task/adapter"
                        ))
                    })?;
                    for k in t.keys() {
                        if k != "title" && k != "scope" {
                            return Err(RuleError::InvalidManifest(format!(
                                "[[section]] `{title}` carries unknown key `{k}`"
                            )));
                        }
                    }
                    sections.push(SectionSpec { title, scope });
                }
            }
            Some(_) => {
                return Err(RuleError::InvalidManifest(
                    "`section` must be an array of tables ([[section]])".to_string(),
                ))
            }
            None => {
                return Err(RuleError::InvalidManifest(
                    "no [[section]] declared — the generated documents would have nowhere to \
                     put a rule"
                        .to_string(),
                ))
            }
        }
        let mut seen_titles = BTreeSet::new();
        for s in &sections {
            if !seen_titles.insert(s.title.clone()) {
                return Err(RuleError::InvalidManifest(format!(
                    "[[section]] `{}` is declared twice",
                    s.title
                )));
            }
        }
        if !sections.iter().any(|s| s.scope == RuleScope::Core) {
            return Err(RuleError::InvalidManifest(
                "no [[section]] with scope = \"core\" — the mandatory core is the one part of \
                 the bundle both harnesses must carry"
                    .to_string(),
            ));
        }

        let outputs_tbl = doc
            .get("outputs")
            .and_then(|v| v.as_table())
            .ok_or_else(|| RuleError::InvalidManifest("no [outputs] table".to_string()))?;
        let mut outputs = BTreeMap::new();
        for (k, v) in outputs_tbl {
            let p = v.as_str().ok_or_else(|| {
                RuleError::InvalidManifest(format!("[outputs] `{k}` is not a string"))
            })?;
            outputs.insert(k.clone(), p.to_string());
        }
        if outputs.is_empty() {
            return Err(RuleError::InvalidManifest(
                "[outputs] is empty — generation would produce nothing".to_string(),
            ));
        }

        let max_bytes = match doc.get("budget").and_then(|v| v.as_table()) {
            Some(t) => {
                for k in t.keys() {
                    if k != "max_bytes" {
                        return Err(RuleError::InvalidManifest(format!(
                            "[budget] carries unknown key `{k}`"
                        )));
                    }
                }
                match t.get("max_bytes").and_then(|v| v.as_integer()) {
                    Some(n) if n > 0 => n as usize,
                    Some(n) => {
                        return Err(RuleError::InvalidManifest(format!(
                            "[budget] max_bytes = {n} is not a positive byte count"
                        )))
                    }
                    None => DEFAULT_MAX_BYTES,
                }
            }
            None => DEFAULT_MAX_BYTES,
        };

        let enforce = EnforceSpec::parse_all(&doc)?;

        for k in doc.keys() {
            match k.as_str() {
                "schema" | "title" | "sources" | "section" | "outputs" | "budget" | "enforce" => {}
                other => {
                    return Err(RuleError::InvalidManifest(format!(
                        "unknown top-level key `{other}`"
                    )))
                }
            }
        }

        // A generated file cannot also be an input. Caught here rather than at publish time
        // so a `check` on a mis-migrated root names it before anything is written.
        for out in outputs.values() {
            if sources.iter().any(|s| s == out) {
                return Err(RuleError::OutputIsSource(out.clone()));
            }
        }

        Ok(Manifest {
            schema,
            sources,
            sections,
            outputs,
            max_bytes,
            title,
            enforce,
        })
    }

    /// Load the manifest at a root.
    pub fn load(root: &Path) -> Result<Manifest, RuleError> {
        let path = root.join(MANIFEST_NAME);
        let text =
            std::fs::read_to_string(&path).map_err(|_| RuleError::MissingManifest(path.clone()))?;
        Manifest::parse(&text)
    }

    /// The section spec for a title, if declared.
    pub fn section(&self, title: &str) -> Option<&SectionSpec> {
        self.sections.iter().find(|s| s.title == title)
    }
}

fn string_list(doc: &toml::Table, key: &str) -> Result<Vec<String>, RuleError> {
    match doc.get(key) {
        Some(toml::Value::Array(a)) => a
            .iter()
            .map(|v| {
                v.as_str().map(|s| s.to_string()).ok_or_else(|| {
                    RuleError::InvalidManifest(format!("`{key}` contains a non-string entry"))
                })
            })
            .collect(),
        Some(_) => Err(RuleError::InvalidManifest(format!(
            "`{key}` must be an array of strings"
        ))),
        None => Err(RuleError::InvalidManifest(format!("no `{key}` array"))),
    }
}

// ---- Path safety ------------------------------------------------------------

/// Resolve a root-relative declared path, refusing everything that leaves the root.
///
/// **THREE SEPARATE HOLES, CLOSED SEPARATELY**, because closing one of them looks like
/// closing all three and is not:
///
///   * a lexical escape (`../../etc/passwd`, an absolute path) — rejected before touching
///     the filesystem, so a manifest cannot even NAME something outside the root;
///   * a symlinked file inside the root pointing out of it — caught by canonicalizing the
///     resolved file and comparing against the canonicalized root;
///   * a symlinked DIRECTORY component — caught by the same canonicalization, which
///     resolves every component rather than only the last.
///
/// The root itself is canonicalized once by the caller and passed in already resolved, so a
/// vault reached through a symlink (which this one is, on the deployed host) does not fail
/// its own containment check.
pub fn resolve_under_root(canon_root: &Path, rel: &str) -> Result<PathBuf, RuleError> {
    if rel.is_empty() {
        return Err(RuleError::PathEscape {
            rel: rel.to_string(),
            detail: "empty path".to_string(),
        });
    }
    let p = Path::new(rel);
    if p.is_absolute() {
        return Err(RuleError::PathEscape {
            rel: rel.to_string(),
            detail: "declared paths are relative to the rules root".to_string(),
        });
    }
    for c in p.components() {
        match c {
            std::path::Component::Normal(_) => {}
            other => {
                return Err(RuleError::PathEscape {
                    rel: rel.to_string(),
                    detail: format!("path component {other:?} is not allowed"),
                })
            }
        }
    }
    let joined = canon_root.join(p);
    // A file that does not exist yet cannot be canonicalized; its PARENT still can, and that
    // is the check that matters for an output being created for the first time.
    let resolved = match joined.canonicalize() {
        Ok(r) => r,
        Err(_) => match (joined.parent(), joined.file_name()) {
            (Some(parent), Some(name)) => match parent.canonicalize() {
                Ok(rp) => rp.join(name),
                Err(e) => {
                    return Err(RuleError::MissingSource {
                        rel: rel.to_string(),
                        detail: e.to_string(),
                    })
                }
            },
            _ => joined.clone(),
        },
    };
    if !resolved.starts_with(canon_root) {
        return Err(RuleError::PathEscape {
            rel: rel.to_string(),
            detail: format!(
                "resolves to {} (a symlink out of the root, or a root that moved)",
                resolved.display()
            ),
        });
    }
    Ok(resolved)
}

/// Canonicalize the configured root once, so every path check below compares like with like.
pub fn canonical_root(root: &Path) -> Result<PathBuf, RuleError> {
    root.canonicalize()
        .map_err(|e| RuleError::io(format!("rules root {}", root.display()), e))
}

// ---- Marker selection -------------------------------------------------------

/// The opening marker of a rule block.
pub const MARKER_OPEN: &str = "<!-- jesse-rule:";
/// The closing marker of a rule block.
pub const MARKER_CLOSE: &str = "<!-- /jesse-rule -->";

/// One source file, with the hash that pins it into the bundle digest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceFile {
    pub rel: String,
    pub sha256: String,
    pub text: String,
}

/// Read every declared source, in manifest order, hashing each.
pub fn read_sources(canon_root: &Path, manifest: &Manifest) -> Result<Vec<SourceFile>, RuleError> {
    let mut out = Vec::with_capacity(manifest.sources.len());
    let mut seen = BTreeSet::new();
    for rel in &manifest.sources {
        if !seen.insert(rel.clone()) {
            return Err(RuleError::InvalidManifest(format!(
                "`{rel}` is declared as a source twice"
            )));
        }
        let path = resolve_under_root(canon_root, rel)?;
        let bytes = std::fs::read(&path).map_err(|e| RuleError::MissingSource {
            rel: rel.clone(),
            detail: e.to_string(),
        })?;
        let text = String::from_utf8(bytes.clone()).map_err(|_| RuleError::MissingSource {
            rel: rel.clone(),
            detail: "not valid UTF-8".to_string(),
        })?;
        out.push(SourceFile {
            rel: rel.clone(),
            sha256: crate::sha256_hex(&bytes),
            text,
        });
    }
    Ok(out)
}

/// Extract every marked rule block from the read sources, in source order then file order.
///
/// # Why only marked blocks, and only in declared sources
///
/// **Ordinary note prose is never policy, and this is the mechanism that makes that true.**
/// A vault is content the model can write; a rule that could be created by writing a
/// convincing paragraph into a note would be a rule the model grants itself. Two independent
/// gates stand in the way: the file must be named in the manifest (which lives in the source
/// root and is not something a turn edits through the ordinary write path), AND the block
/// must be explicitly marked. A marker in an undeclared file selects nothing at all, which
/// `a_marker_in_an_undeclared_file_is_not_policy` asserts against a hostile fixture.
///
/// A block whose BODY contains another marker is refused rather than nested: nesting has no
/// meaning here, and the shape it would take is exactly the shape of a smuggled rule.
pub fn select_rules(sources: &[SourceFile], manifest: &Manifest) -> Result<Vec<Rule>, RuleError> {
    let mut rules: Vec<Rule> = Vec::new();
    let mut by_id: BTreeMap<String, String> = BTreeMap::new();

    for src in sources {
        let mut open: Option<(Attrs, usize)> = None;
        let mut body = String::new();
        for (idx, line) in src.text.lines().enumerate() {
            let lineno = idx + 1;
            let trimmed = line.trim_start();
            if trimmed.starts_with(MARKER_OPEN) {
                if open.is_some() {
                    return Err(RuleError::InvalidMetadata {
                        rel: src.rel.clone(),
                        line: lineno,
                        detail: "a rule block opens inside another rule block".to_string(),
                    });
                }
                let attrs = parse_attrs(&src.rel, lineno, trimmed)?;
                open = Some((attrs, lineno));
                body.clear();
                continue;
            }
            if trimmed.starts_with(MARKER_CLOSE) {
                let Some((attrs, open_line)) = open.take() else {
                    return Err(RuleError::InvalidMetadata {
                        rel: src.rel.clone(),
                        line: lineno,
                        detail: "a rule block closes without opening".to_string(),
                    });
                };
                let rule = attrs.into_rule(&src.rel, open_line, &body)?;
                if let Some(first) = by_id.get(&rule.id) {
                    return Err(RuleError::DuplicateId {
                        id: rule.id.clone(),
                        first: first.clone(),
                        second: format!("{}:{}", src.rel, open_line),
                    });
                }
                by_id.insert(rule.id.clone(), format!("{}:{}", src.rel, open_line));
                rules.push(rule);
                continue;
            }
            if open.is_some() {
                body.push_str(line);
                body.push('\n');
            }
        }
        if let Some((_, open_line)) = open {
            return Err(RuleError::InvalidMetadata {
                rel: src.rel.clone(),
                line: open_line,
                detail: format!("rule block is never closed (expected `{MARKER_CLOSE}`)"),
            });
        }
    }

    // Every rule must land in a declared section whose scope agrees with its own. A rule
    // that names an undeclared section is a BROKEN SELECTION rather than a new section: the
    // manifest owns the document's shape, and inventing a heading from a marker would let a
    // source file restructure the entry document.
    for r in &rules {
        match manifest.section(&r.section) {
            None => {
                return Err(RuleError::BrokenSelection {
                    id: r.id.clone(),
                    detail: format!("section `{}` is not declared in {MANIFEST_NAME}", r.section),
                })
            }
            Some(s) if s.scope != r.scope => {
                return Err(RuleError::BrokenSelection {
                    id: r.id.clone(),
                    detail: format!(
                        "scope `{}` but section `{}` holds `{}`",
                        r.scope.as_str(),
                        r.section,
                        s.scope.as_str()
                    ),
                })
            }
            Some(_) => {}
        }
        if r.scope == RuleScope::Adapter && r.adapters.is_empty() {
            return Err(RuleError::BrokenSelection {
                id: r.id.clone(),
                detail: "an adapter rule must name the harness it applies to (adapters=...)"
                    .to_string(),
            });
        }
        if r.scope == RuleScope::Core && !r.adapters.is_empty() {
            return Err(RuleError::BrokenSelection {
                id: r.id.clone(),
                detail: "a core rule applies to every harness and must not name adapters — \
                         a per-harness rule is scope=adapter"
                    .to_string(),
            });
        }
        for a in &r.adapters {
            if !manifest.outputs.contains_key(a) {
                return Err(RuleError::BrokenSelection {
                    id: r.id.clone(),
                    detail: format!("names harness `{a}`, which has no [outputs] entry"),
                });
            }
        }
    }

    // A section declared but never filled is a silent hole in the generated document, and
    // "the core is empty" is the specific shape of the migration failure worth catching.
    for s in &manifest.sections {
        if s.scope == RuleScope::Core && !rules.iter().any(|r| r.section == s.title) {
            return Err(RuleError::BrokenSelection {
                id: format!("<section {}>", s.title),
                detail: "the core section selected no rules — publishing would supply both \
                         harnesses an empty mandatory core"
                    .to_string(),
            });
        }
    }

    Ok(rules)
}

/// Attributes parsed off one opening marker.
#[derive(Debug, Clone, Default)]
struct Attrs {
    id: Option<String>,
    scope: Option<RuleScope>,
    section: Option<String>,
    triggers: Vec<String>,
    adapters: Vec<String>,
}

impl Attrs {
    fn into_rule(self, rel: &str, line: usize, body: &str) -> Result<Rule, RuleError> {
        let bad = |detail: String| RuleError::InvalidMetadata {
            rel: rel.to_string(),
            line,
            detail,
        };
        let id = self.id.ok_or_else(|| bad("no `id`".to_string()))?;
        let scope = self.scope.ok_or_else(|| bad("no `scope`".to_string()))?;
        let section = self
            .section
            .ok_or_else(|| bad("no `section`".to_string()))?;
        let body = body.trim_matches('\n');
        if body.trim().is_empty() {
            return Err(bad(format!("rule `{id}` has an empty body")));
        }
        if body.contains(MARKER_OPEN) || body.contains(MARKER_CLOSE) {
            return Err(bad(format!(
                "rule `{id}` carries a rule marker inside its body"
            )));
        }
        // The generated documents are delimited by their own sentinels. A rule body that
        // carried one would let a source file forge the end of a bundle.
        if body.contains(GENERATED_SENTINEL) {
            return Err(bad(format!(
                "rule `{id}` carries the generated-document sentinel in its body"
            )));
        }
        if scope == RuleScope::Task && self.triggers.is_empty() {
            return Err(bad(format!(
                "task rule `{id}` declares no triggers — a routed rule with no trigger can \
                 never be selected, and routing is by declared trigger rather than by guess"
            )));
        }
        if scope != RuleScope::Task && !self.triggers.is_empty() {
            return Err(bad(format!(
                "rule `{id}` is scope={} but declares triggers, which only route task rules",
                scope.as_str()
            )));
        }
        Ok(Rule {
            id,
            scope,
            section,
            triggers: self.triggers,
            adapters: self.adapters,
            source: rel.to_string(),
            line,
            body: body.to_string(),
        })
    }
}

/// Parse `<!-- jesse-rule: k=v k="v v" -->`.
fn parse_attrs(rel: &str, line: usize, raw: &str) -> Result<Attrs, RuleError> {
    let bad = |detail: String| RuleError::InvalidMetadata {
        rel: rel.to_string(),
        line,
        detail,
    };
    let rest = raw
        .strip_prefix(MARKER_OPEN)
        .ok_or_else(|| bad("not a rule marker".to_string()))?;
    let rest = rest
        .trim_end()
        .strip_suffix("-->")
        .ok_or_else(|| bad("marker is not closed with `-->` on the same line".to_string()))?;

    let mut attrs = Attrs::default();
    for (key, value) in tokenize_attrs(rest).map_err(bad)? {
        match key.as_str() {
            "id" => {
                if !is_valid_id(&value) {
                    return Err(bad(format!(
                        "id `{value}` must be lowercase letters, digits and hyphens, starting \
                         with a letter or digit"
                    )));
                }
                if attrs.id.replace(value).is_some() {
                    return Err(bad("`id` given twice".to_string()));
                }
            }
            "scope" => {
                let s = RuleScope::parse(&value).ok_or_else(|| {
                    bad(format!("scope `{value}` is not one of core/task/adapter"))
                })?;
                if attrs.scope.replace(s).is_some() {
                    return Err(bad("`scope` given twice".to_string()));
                }
            }
            "section" => {
                if attrs.section.replace(value).is_some() {
                    return Err(bad("`section` given twice".to_string()));
                }
            }
            "triggers" => {
                if !attrs.triggers.is_empty() {
                    return Err(bad("`triggers` given twice".to_string()));
                }
                attrs.triggers = split_list(&value);
                if attrs.triggers.is_empty() {
                    return Err(bad("`triggers` is empty".to_string()));
                }
            }
            "adapters" => {
                if !attrs.adapters.is_empty() {
                    return Err(bad("`adapters` given twice".to_string()));
                }
                attrs.adapters = split_list(&value);
                if attrs.adapters.is_empty() {
                    return Err(bad("`adapters` is empty".to_string()));
                }
            }
            other => {
                return Err(bad(format!(
                    "unknown attribute `{other}` — the schema selects content and carries no \
                     free-form fields"
                )))
            }
        }
    }
    Ok(attrs)
}

/// Split a `k=v k="v v"` run into pairs. Rejects anything that is not a pair.
fn tokenize_attrs(s: &str) -> Result<Vec<(String, String)>, String> {
    let mut out = Vec::new();
    let mut it = s.char_indices().peekable();
    let bytes: Vec<char> = s.chars().collect();
    let mut i = 0usize;
    let _ = &mut it;
    while i < bytes.len() {
        while i < bytes.len() && bytes[i].is_whitespace() {
            i += 1;
        }
        if i >= bytes.len() {
            break;
        }
        let key_start = i;
        while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == '_') {
            i += 1;
        }
        if i == key_start {
            return Err(format!("unexpected character `{}` in the marker", bytes[i]));
        }
        let key: String = bytes[key_start..i].iter().collect();
        if i >= bytes.len() || bytes[i] != '=' {
            return Err(format!("attribute `{key}` has no `=` value"));
        }
        i += 1;
        let value = if i < bytes.len() && bytes[i] == '"' {
            i += 1;
            let start = i;
            while i < bytes.len() && bytes[i] != '"' {
                i += 1;
            }
            if i >= bytes.len() {
                return Err(format!(
                    "attribute `{key}` has an unterminated quoted value"
                ));
            }
            let v: String = bytes[start..i].iter().collect();
            i += 1;
            v
        } else {
            let start = i;
            while i < bytes.len() && !bytes[i].is_whitespace() {
                i += 1;
            }
            bytes[start..i].iter().collect()
        };
        if value.is_empty() {
            return Err(format!("attribute `{key}` has an empty value"));
        }
        out.push((key, value));
    }
    Ok(out)
}

fn split_list(v: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for part in v.split(',') {
        let t = part.trim().to_ascii_lowercase();
        if !t.is_empty() && !out.contains(&t) {
            out.push(t);
        }
    }
    out
}

fn is_valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !s.ends_with('-')
}

/// A representative rules root on disk, for the suites that need one.
///
/// **THE FIXTURE IS TEST DATA, NOT A MIGRATION.** Its rules are written for this repository:
/// they exercise the semantics the scenario suite asserts (an outbound refusal, a routed task
/// rule, a harness-specific adapter rule, a draft's path, name and content) and they are
/// nobody's actual guidelines. The real parameters live in the private source root.
#[cfg(test)]
pub(crate) mod tests_support {
    use super::*;

    pub(crate) const MANIFEST: &str = r#"
schema = 1
title = "Working Rules"
sources = ["hard.md", "guides.md"]

[[section]]
title = "Hard Rules"
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

[budget]
max_bytes = 32768

[[enforce]]
rule = "no-outbound"
kind = "deny-tools"
tools = ["mcp__mail__send_*", "mcp__chat__post_*"]
except = ["mcp__forge__open_issue"]

[[enforce]]
rule = "drafts-land-in-drafts"
kind = "write-confined-to"
paths = ["vault/"]

[[enforce]]
rule = "draft-names"
kind = "filename-pattern"
paths = ["vault/Projects/drafts/"]
pattern = "date-time-slug"

[[enforce]]
rule = "no-dash-punctuation"
kind = "content-forbid"
paths = ["vault/"]
applies_to = ["*.md"]
needles = ["—"]
"#;

    pub(crate) const HARD: &str = concat!(
        "# Hard rules\n\n",
        "<!-- jesse-rule: id=no-outbound scope=core section=\"Hard Rules\" -->\n",
        "- **Never send outbound communication on the owner's behalf.** Draft it and stop.\n",
        "<!-- /jesse-rule -->\n\n",
        "<!-- jesse-rule: id=drafts-land-in-drafts scope=core section=\"Hard Rules\" -->\n",
        "- **Deliverables land under `vault/`.** Nowhere else counts as delivery.\n",
        "<!-- /jesse-rule -->\n\n",
        "<!-- jesse-rule: id=draft-names scope=core section=\"Hard Rules\" -->\n",
        "- **A draft is named `YYYY-MM-DD-HHMM-slug.md`.**\n",
        "<!-- /jesse-rule -->\n\n",
        "<!-- jesse-rule: id=no-dash-punctuation scope=core section=\"Hard Rules\" -->\n",
        "- **No dash punctuation in prose.**\n",
        "<!-- /jesse-rule -->\n\n",
        "<!-- jesse-rule: id=record-facts scope=core section=\"Hard Rules\" -->\n",
        "- **Record a newly learned durable fact in its existing record, without asking.**\n",
        "<!-- /jesse-rule -->\n\n",
        "<!-- jesse-rule: id=reload-after-compaction scope=core section=\"Hard Rules\" -->\n",
        "- **Re-read this file after a context compaction, before anything else.**\n",
        "<!-- /jesse-rule -->\n"
    );

    pub(crate) const GUIDES: &str = concat!(
        "# Guidance\n\n",
        "<!-- jesse-rule: id=meeting-agendas scope=task section=\"Task Guidance\" ",
        "triggers=\"meeting, agenda\" -->\n",
        "- **Meeting agendas:** keep them fresh until the meeting starts.\n",
        "<!-- /jesse-rule -->\n\n",
        "<!-- jesse-rule: id=entity-journals scope=task section=\"Task Guidance\" ",
        "triggers=\"person, project, journal\" -->\n",
        "- **Read a Journal before engaging with the entity that has one.**\n",
        "<!-- /jesse-rule -->\n\n",
        "<!-- jesse-rule: id=codex-sandbox scope=adapter section=\"This Harness\" ",
        "adapters=\"codex\" -->\n",
        "- A sandbox refusal is a boundary, not an error to route around.\n",
        "<!-- /jesse-rule -->\n"
    );

    /// A temp directory that removes itself.
    pub(crate) struct TempRoot(pub PathBuf);
    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// A fresh rules root carrying the fixture. Unique per tag AND per process, so a
    /// parallel `cargo test` never has two suites in one directory.
    pub(crate) fn scratch_root(tag: &str) -> (PathBuf, TempRoot) {
        let dir = std::env::temp_dir().join(format!(
            "jesse-rules-{tag}-{}-{}",
            std::process::id(),
            crate::random_hex()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("vault").join("Projects").join("drafts"))
            .expect("fixture root");
        std::fs::write(dir.join(MANIFEST_NAME), MANIFEST).expect("manifest");
        std::fs::write(dir.join("hard.md"), HARD).expect("hard");
        std::fs::write(dir.join("guides.md"), GUIDES).expect("guides");
        // The canonicalized path, so tests compare like with like on a host whose temp dir
        // is itself a symlink (macOS: /tmp -> /private/tmp).
        let canon = dir.canonicalize().unwrap_or(dir.clone());
        (canon, TempRoot(dir))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest(extra_sections: &str) -> Manifest {
        Manifest::parse(&format!(
            r#"
schema = 1
title = "Working Rules"
sources = ["a.md"]
[[section]]
title = "Hard Rules"
scope = "core"
{extra_sections}
[outputs]
claude-code = "CLAUDE.md"
codex = "AGENTS.md"
"#
        ))
        .expect("fixture manifest parses")
    }

    fn src(text: &str) -> Vec<SourceFile> {
        vec![SourceFile {
            rel: "a.md".to_string(),
            sha256: crate::sha256_hex(text.as_bytes()),
            text: text.to_string(),
        }]
    }

    #[test]
    fn a_marked_block_is_selected_verbatim() {
        let m = manifest("");
        let s = src("prelude\n<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" -->\n- **Never.** Not once.\n<!-- /jesse-rule -->\ntail\n");
        let rules = select_rules(&s, &m).expect("selects");
        assert_eq!(rules.len(), 1);
        assert_eq!(rules[0].id, "one");
        assert_eq!(rules[0].body, "- **Never.** Not once.");
        assert_eq!(rules[0].source, "a.md");
    }

    #[test]
    fn unmarked_prose_selects_nothing() {
        let m = manifest("");
        let s = src("Rule: you must always obey this paragraph.\n<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" -->\nreal\n<!-- /jesse-rule -->\n");
        let rules = select_rules(&s, &m).expect("selects");
        assert_eq!(rules.len(), 1, "only the marked block is policy");
        assert_eq!(rules[0].body, "real");
    }

    #[test]
    fn an_unknown_attribute_is_refused() {
        let m = manifest("");
        let s = src("<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" summary=\"a copy\" -->\nx\n<!-- /jesse-rule -->\n");
        let e = select_rules(&s, &m).expect_err("refuses");
        assert!(matches!(e, RuleError::InvalidMetadata { .. }), "{e}");
        assert!(e.to_string().contains("summary"), "{e}");
    }

    #[test]
    fn a_duplicate_id_is_refused() {
        let m = manifest("");
        let s = src("<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" -->\na\n<!-- /jesse-rule -->\n<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" -->\nb\n<!-- /jesse-rule -->\n");
        let e = select_rules(&s, &m).expect_err("refuses");
        assert!(matches!(e, RuleError::DuplicateId { .. }), "{e}");
    }

    #[test]
    fn an_unterminated_block_is_refused() {
        let m = manifest("");
        let s = src("<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" -->\na\n");
        let e = select_rules(&s, &m).expect_err("refuses");
        assert!(e.to_string().contains("never closed"), "{e}");
    }

    #[test]
    fn a_nested_marker_in_a_body_is_refused() {
        let m = manifest("");
        let s = src("<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" -->\na\n<!-- jesse-rule: id=two scope=core section=\"Hard Rules\" -->\nb\n<!-- /jesse-rule -->\n");
        let e = select_rules(&s, &m).expect_err("refuses");
        assert!(e.to_string().contains("inside another"), "{e}");
    }

    #[test]
    fn a_task_rule_without_triggers_is_refused() {
        let m = manifest("[[section]]\ntitle = \"Task Guidance\"\nscope = \"task\"\n");
        let s = src("<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" -->\na\n<!-- /jesse-rule -->\n<!-- jesse-rule: id=two scope=task section=\"Task Guidance\" -->\nb\n<!-- /jesse-rule -->\n");
        let e = select_rules(&s, &m).expect_err("refuses");
        assert!(e.to_string().contains("no triggers"), "{e}");
    }

    #[test]
    fn a_rule_naming_an_undeclared_section_is_a_broken_selection() {
        let m = manifest("");
        let s = src("<!-- jesse-rule: id=one scope=core section=\"Hard Rules\" -->\na\n<!-- /jesse-rule -->\n<!-- jesse-rule: id=two scope=core section=\"Nowhere\" -->\nb\n<!-- /jesse-rule -->\n");
        let e = select_rules(&s, &m).expect_err("refuses");
        assert!(matches!(e, RuleError::BrokenSelection { .. }), "{e}");
    }

    #[test]
    fn an_empty_core_section_is_refused() {
        let m = manifest("[[section]]\ntitle = \"Task Guidance\"\nscope = \"task\"\n");
        let s = src("<!-- jesse-rule: id=two scope=task section=\"Task Guidance\" triggers=\"x\" -->\nb\n<!-- /jesse-rule -->\n");
        let e = select_rules(&s, &m).expect_err("refuses");
        assert!(e.to_string().contains("empty mandatory core"), "{e}");
    }

    #[test]
    fn an_output_that_is_also_a_source_is_refused() {
        let e = Manifest::parse(
            r#"
schema = 1
sources = ["CLAUDE.md"]
[[section]]
title = "Hard Rules"
scope = "core"
[outputs]
claude-code = "CLAUDE.md"
"#,
        )
        .expect_err("refuses");
        assert!(matches!(e, RuleError::OutputIsSource(_)), "{e}");
    }

    #[test]
    fn an_unknown_manifest_key_is_refused() {
        let e = Manifest::parse(
            r#"
schema = 1
sorces = ["a.md"]
[[section]]
title = "Hard Rules"
scope = "core"
[outputs]
claude-code = "CLAUDE.md"
"#,
        )
        .expect_err("refuses");
        assert!(matches!(e, RuleError::InvalidManifest(_)), "{e}");
    }

    #[test]
    fn a_future_schema_is_refused_rather_than_parsed_leniently() {
        let e = Manifest::parse("schema = 99\nsources = [\"a.md\"]\n").expect_err("refuses");
        assert!(e.to_string().contains("schema"), "{e}");
    }

    #[test]
    fn a_lexical_escape_never_reaches_the_filesystem() {
        let root = std::env::temp_dir();
        let e = resolve_under_root(&root, "../etc/passwd").expect_err("refuses");
        assert!(matches!(e, RuleError::PathEscape { .. }), "{e}");
        let e = resolve_under_root(&root, "/etc/passwd").expect_err("refuses");
        assert!(matches!(e, RuleError::PathEscape { .. }), "{e}");
    }
}
