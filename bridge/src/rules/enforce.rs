//! **THE ENFORCEABLE SUBSET.** One component, called through thin harness adapters at real
//! action boundaries.
//!
//! # What belongs here and what does not
//!
//! A rule belongs here only if a machine can decide it from what the boundary can SEE, with
//! no judgement: a tool name, a resolved path, a file name, a substring of the bytes about
//! to be written. Everything else stays an instruction in the bundle with a behaviour test
//! beside it. The temptation this resists is the keyword blocker: refusing a write because
//! it contains the word "send" would refuse the sentence "I did not send it", and a guard
//! that fires on prose is a guard someone turns off.
//!
//! # Where it is called from
//!
//! `jesse-hook`, on the `PreToolUse` event of both spawned harnesses, BEFORE the tool runs.
//! That is the only boundary in this system that is genuinely pre-mutation and genuinely
//! shared: Claude Code and Codex both call it, both send the tool name and its input, and
//! both understand a refusal. The lock request follows the rule check, so a refused call
//! never takes a lock.
//!
//! # What it does not cover, stated rather than implied
//!
//! * **Turns with no write lock.** The hooks are installed only for a write-capable turn
//!   with the broker armed (see `TurnRequest::write_lock`). A read-level turn, a `Basic`
//!   child and any turn on a deployment with the broker off reach no hook at all, so nothing
//!   here runs for them. They also cannot write, which is why that is acceptable rather than
//!   a hole, but the outbound check does not run for them either.
//! * **The in-process `direct` harness.** It has no hooks by construction. It consumes the
//!   same instruction bundle and none of this enforcement.
//! * **A shell command.** `Bash(...)` reaches this with a command string and no path, so
//!   every path and content check is UNOBSERVABLE for it and says so. Only the tool-name
//!   check applies. A shell verb that writes a file is exactly the route this cannot see,
//!   and the write lock's `WriteTarget::Global` is what makes it safe rather than checked.
//! * **A browser session.** `mcp__browser__browser_click` on a webmail compose form is an
//!   outbound action this cannot distinguish from clicking a search result, because the
//!   payload carries no page identity. The outbound check names TOOLS, so this route is
//!   uncovered and is listed as such in the coverage report.
//! * **A dispatcher tool.** A tool that takes an action name as an argument (the UniFi
//!   `unifi_execute` shape) hides its real verb from a name-based check. Denying the
//!   dispatcher itself is the only name-based answer, and that is a policy decision for the
//!   manifest rather than something this file assumes.

use super::*;

// ---- The declared checks -----------------------------------------------------

/// One enforceable check, with its parameters.
///
/// **THE KIND IS MECHANISM AND LIVES IN CODE; THE PARAMETERS ARE POLICY AND LIVE IN THE
/// MANIFEST.** That split is what keeps the owner's paths, file-naming conventions and tool
/// denylists out of this repository while still letting them be enforced by it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnforceSpec {
    /// The rule id this check enforces. Must name a rule in the bundle, so a denial can cite
    /// the instruction the model was given rather than an anonymous guard.
    pub rule: String,
    pub kind: EnforceKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnforceKind {
    /// Refuse a tool whose name matches any of `tools`, unless it matches `except`.
    DenyTools {
        tools: Vec<String>,
        except: Vec<String>,
    },
    /// Refuse a write whose resolved target is not under one of these root-relative prefixes.
    WriteConfinedTo { paths: Vec<String> },
    /// Under `paths`, a written file's NAME must match the named pattern.
    FilenamePattern {
        paths: Vec<String>,
        pattern: NamePattern,
    },
    /// Under `paths`, for files matching `applies_to`, the written text must contain none of
    /// these needles.
    ContentForbid {
        paths: Vec<String>,
        applies_to: Vec<String>,
        needles: Vec<String>,
    },
    /// Under `paths`, for files matching `applies_to`, the complete written text must contain
    /// this marker. Skipped when only part of the content is observable.
    ContentRequire {
        paths: Vec<String>,
        applies_to: Vec<String>,
        marker: String,
    },
}

/// The file-name shapes this build can check. A closed set on purpose: a free-form regex in
/// a manifest is a program, and a program in a config file is a thing nobody tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NamePattern {
    /// `YYYY-MM-DD-HHMM-<rest>`
    DateTimeSlug,
    /// `YYYY-MM-DD-<rest>`
    DateSlug,
    /// `Word-Word-Word.<ext>`, each word starting with an uppercase letter or a digit.
    HyphenatedTitleCase,
}

impl NamePattern {
    fn parse(s: &str) -> Option<Self> {
        match s {
            "date-time-slug" => Some(NamePattern::DateTimeSlug),
            "date-slug" => Some(NamePattern::DateSlug),
            "hyphenated-title-case" => Some(NamePattern::HyphenatedTitleCase),
            _ => None,
        }
    }
    fn as_str(self) -> &'static str {
        match self {
            NamePattern::DateTimeSlug => "date-time-slug",
            NamePattern::DateSlug => "date-slug",
            NamePattern::HyphenatedTitleCase => "hyphenated-title-case",
        }
    }
    /// Whether a file name matches. Hand-written rather than a regex: the crate carries no
    /// regex dependency, the shapes are fixed, and a hand-written matcher is testable
    /// against exactly the cases that matter.
    pub fn matches(self, name: &str) -> bool {
        match self {
            NamePattern::DateTimeSlug => {
                let Some(rest) = strip_date(name) else {
                    return false;
                };
                // `-HHMM-` then a non-empty remainder.
                let Some(rest) = rest.strip_prefix('-') else {
                    return false;
                };
                if rest.len() < 5 || !rest[..4].chars().all(|c| c.is_ascii_digit()) {
                    return false;
                }
                let hh: u32 = rest[..2].parse().unwrap_or(99);
                let mm: u32 = rest[2..4].parse().unwrap_or(99);
                hh < 24 && mm < 60 && rest.as_bytes()[4] == b'-' && rest.len() > 5
            }
            NamePattern::DateSlug => match strip_date(name) {
                Some(rest) => rest.len() > 1 && rest.starts_with('-'),
                None => false,
            },
            NamePattern::HyphenatedTitleCase => {
                let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name);
                !stem.is_empty()
                    && stem.split('-').all(|w| {
                        w.chars()
                            .next()
                            .is_some_and(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
                            && w.chars().all(|c| c.is_ascii_alphanumeric())
                    })
            }
        }
    }
}

/// `YYYY-MM-DD` off the front, returning the rest. `None` if it is not a plausible date.
fn strip_date(name: &str) -> Option<&str> {
    let b = name.as_bytes();
    if b.len() < 10 {
        return None;
    }
    let digits = |r: std::ops::Range<usize>| name[r].chars().all(|c| c.is_ascii_digit());
    if !digits(0..4) || b[4] != b'-' || !digits(5..7) || b[7] != b'-' || !digits(8..10) {
        return None;
    }
    let mo: u32 = name[5..7].parse().ok()?;
    let da: u32 = name[8..10].parse().ok()?;
    if !(1..=12).contains(&mo) || !(1..=31).contains(&da) {
        return None;
    }
    Some(&name[10..])
}

impl EnforceSpec {
    /// The canonical one-line form that enters the bundle digest.
    ///
    /// It exists so an enforcement PARAMETER change moves the digest: a denylist that lost an
    /// entry is a policy change, and a bundle whose digest did not move for it would be a
    /// digest that proves less than it appears to.
    pub fn canonical(&self) -> String {
        match &self.kind {
            EnforceKind::DenyTools { tools, except } => format!(
                "{} deny-tools tools={} except={}",
                self.rule,
                tools.join("|"),
                except.join("|")
            ),
            EnforceKind::WriteConfinedTo { paths } => {
                format!("{} write-confined-to paths={}", self.rule, paths.join("|"))
            }
            EnforceKind::FilenamePattern { paths, pattern } => format!(
                "{} filename-pattern paths={} pattern={}",
                self.rule,
                paths.join("|"),
                pattern.as_str()
            ),
            EnforceKind::ContentForbid {
                paths,
                applies_to,
                needles,
            } => format!(
                "{} content-forbid paths={} applies_to={} needles={}",
                self.rule,
                paths.join("|"),
                applies_to.join("|"),
                needles.join("|")
            ),
            EnforceKind::ContentRequire {
                paths,
                applies_to,
                marker,
            } => format!(
                "{} content-require paths={} applies_to={} marker={}",
                self.rule,
                paths.join("|"),
                applies_to.join("|"),
                marker
            ),
        }
    }

    /// Parse the `[[enforce]]` array of a manifest.
    pub fn parse_all(doc: &toml::Table) -> Result<Vec<EnforceSpec>, RuleError> {
        let items = match doc.get("enforce") {
            None => return Ok(Vec::new()),
            Some(toml::Value::Array(a)) => a,
            Some(_) => {
                return Err(RuleError::InvalidManifest(
                    "`enforce` must be an array of tables ([[enforce]])".to_string(),
                ))
            }
        };
        let mut out = Vec::new();
        let mut seen = std::collections::BTreeSet::new();
        for (i, item) in items.iter().enumerate() {
            let t = item.as_table().ok_or_else(|| {
                RuleError::InvalidManifest(format!("[[enforce]] {i} is not a table"))
            })?;
            let bad = |d: String| RuleError::InvalidManifest(format!("[[enforce]] {i}: {d}"));
            let rule = t
                .get("rule")
                .and_then(|v| v.as_str())
                .ok_or_else(|| bad("no `rule` naming the instruction it enforces".to_string()))?
                .to_string();
            let kind_s = t
                .get("kind")
                .and_then(|v| v.as_str())
                .ok_or_else(|| bad("no `kind`".to_string()))?;

            let list = |key: &str, required: bool| -> Result<Vec<String>, RuleError> {
                match t.get(key) {
                    None if !required => Ok(Vec::new()),
                    None => Err(bad(format!("`{kind_s}` needs `{key}`"))),
                    Some(toml::Value::Array(a)) => a
                        .iter()
                        .map(|v| {
                            v.as_str()
                                .map(|s| s.to_string())
                                .ok_or_else(|| bad(format!("`{key}` has a non-string entry")))
                        })
                        .collect(),
                    Some(_) => Err(bad(format!("`{key}` must be an array of strings"))),
                }
            };

            let mut allowed: Vec<&str> = vec!["rule", "kind"];
            let kind = match kind_s {
                "deny-tools" => {
                    allowed.extend(["tools", "except"]);
                    let tools = list("tools", true)?;
                    if tools.is_empty() {
                        return Err(bad("`tools` is empty".to_string()));
                    }
                    EnforceKind::DenyTools {
                        tools,
                        except: list("except", false)?,
                    }
                }
                "write-confined-to" => {
                    allowed.push("paths");
                    let paths = list("paths", true)?;
                    if paths.is_empty() {
                        return Err(bad(
                            "`paths` is empty, which would refuse every write".to_string()
                        ));
                    }
                    EnforceKind::WriteConfinedTo { paths }
                }
                "filename-pattern" => {
                    allowed.extend(["paths", "pattern"]);
                    let p = t
                        .get("pattern")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| bad("no `pattern`".to_string()))?;
                    let pattern = NamePattern::parse(p).ok_or_else(|| {
                        bad(format!(
                            "pattern `{p}` is not one of date-time-slug, date-slug, \
                             hyphenated-title-case"
                        ))
                    })?;
                    EnforceKind::FilenamePattern {
                        paths: list("paths", true)?,
                        pattern,
                    }
                }
                "content-forbid" => {
                    allowed.extend(["paths", "applies_to", "needles"]);
                    let needles = list("needles", true)?;
                    if needles.iter().any(|n| n.is_empty()) {
                        return Err(bad("`needles` has an empty entry".to_string()));
                    }
                    EnforceKind::ContentForbid {
                        paths: list("paths", true)?,
                        applies_to: list("applies_to", false)?,
                        needles,
                    }
                }
                "content-require" => {
                    allowed.extend(["paths", "applies_to", "marker"]);
                    let marker = t
                        .get("marker")
                        .and_then(|v| v.as_str())
                        .filter(|s| !s.is_empty())
                        .ok_or_else(|| bad("no non-empty `marker`".to_string()))?
                        .to_string();
                    EnforceKind::ContentRequire {
                        paths: list("paths", true)?,
                        applies_to: list("applies_to", false)?,
                        marker,
                    }
                }
                other => {
                    return Err(bad(format!(
                        "kind `{other}` is not one of deny-tools, write-confined-to, \
                         filename-pattern, content-forbid, content-require"
                    )))
                }
            };
            for k in t.keys() {
                if !allowed.contains(&k.as_str()) {
                    return Err(bad(format!("unknown key `{k}` for kind `{kind_s}`")));
                }
            }
            let spec = EnforceSpec { rule, kind };
            if !seen.insert(spec.canonical()) {
                return Err(bad("is a duplicate of an earlier check".to_string()));
            }
            out.push(spec);
        }
        Ok(out)
    }
}

// ---- The boundary -----------------------------------------------------------

/// How much of the write this boundary can actually see.
///
/// THREE VARIANTS BECAUSE THERE ARE THREE ANSWERS, and collapsing `Added` into `Full` is
/// exactly how a check comes to claim coverage it does not have: a `content-require` check
/// against an Edit's inserted fragment would refuse every legitimate edit of a file that
/// already carries the marker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ObservedContent {
    /// The complete bytes the file will hold after this call.
    Full(String),
    /// Only the text being inserted; the rest of the file is not visible here.
    Added(String),
    /// This tool exposes no content at this boundary.
    Opaque,
}

/// What this call writes, as the harness's own adapter was able to say.
///
/// **THREE ANSWERS, AND THE MIDDLE ONE IS WHY THIS IS NOT AN `Option`.** `None` and `Unnamed`
/// mean opposite things to a path check: a read is a call every path check simply does not
/// apply to, while a shell command is a call every path check WANTED to apply to and could
/// not. Collapsing them either fills the log with an unobservable line for every read, or
/// quietly reports a shell write as having passed checks nothing ran. It is deliberately the
/// same three-way distinction [`crate::WriteTarget`] draws, because it is the same question.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteScope<'a> {
    /// Not a write at all: a read, a search, a lookup.
    None,
    /// A write to this fully resolved absolute path.
    Named(&'a Path),
    /// A write whose target this harness cannot name.
    Unnamed,
}

/// One tool call, as the shared component sees it.
pub struct ActionContext<'a> {
    /// Which harness is asking. Logged with the decision; not used to vary policy.
    pub harness: &'a str,
    /// The tool name exactly as the harness reported it.
    pub tool: &'a str,
    /// What this call writes, if anything, and whether the harness could name it.
    pub target: WriteScope<'a>,
    /// What the boundary can see of the content.
    pub content: &'a ObservedContent,
    /// The canonical rules root, which every declared path is relative to.
    pub root: &'a Path,
}

/// Allowed, or refused with the rule that refused it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny { rule: String, reason: String },
}

/// The result of running every declared check against one action.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Verdict {
    pub decision: Decision,
    /// Checks that applied to this target but could not be evaluated, and why.
    ///
    /// **THIS IS THE HONESTY FIELD.** A check that skipped because the boundary could not see
    /// the content has not passed, and reporting it as a pass is how a guard comes to be
    /// credited with coverage it never had. The caller logs these.
    pub unobservable: Vec<String>,
    /// Checks that ran and passed, by rule id. Logged, so a turn's record says what was
    /// actually evaluated rather than only what fired.
    pub evaluated: Vec<String>,
}

impl Verdict {
    pub fn allowed(&self) -> bool {
        matches!(self.decision, Decision::Allow)
    }
    /// The refusal text, or empty when the call was allowed.
    pub fn decision_reason(&self) -> &str {
        match &self.decision {
            Decision::Deny { reason, .. } => reason,
            Decision::Allow => "",
        }
    }
}

/// Run every declared check against one action.
///
/// ORDER IS FIXED (manifest order) and the FIRST denial wins, so a denial message is stable
/// for a given action rather than depending on which check happened to be evaluated first.
pub fn check_action(specs: &[EnforceSpec], ctx: &ActionContext<'_>) -> Verdict {
    let mut unobservable = Vec::new();
    let mut evaluated = Vec::new();
    let mut decision = Decision::Allow;

    for spec in specs {
        let outcome = evaluate(spec, ctx);
        match outcome {
            Outcome::Passed => evaluated.push(spec.rule.clone()),
            Outcome::NotApplicable => {}
            Outcome::Unobservable(why) => {
                unobservable.push(format!("{}: {why}", spec.rule));
            }
            Outcome::Denied(reason) => {
                evaluated.push(spec.rule.clone());
                if matches!(decision, Decision::Allow) {
                    decision = Decision::Deny {
                        rule: spec.rule.clone(),
                        reason,
                    };
                }
            }
        }
    }
    Verdict {
        decision,
        unobservable,
        evaluated,
    }
}

enum Outcome {
    Passed,
    NotApplicable,
    Unobservable(String),
    Denied(String),
}

fn evaluate(spec: &EnforceSpec, ctx: &ActionContext<'_>) -> Outcome {
    match &spec.kind {
        EnforceKind::DenyTools { tools, except } => {
            if except.iter().any(|p| glob_match(p, ctx.tool)) {
                return Outcome::Passed;
            }
            if tools.iter().any(|p| glob_match(p, ctx.tool)) {
                Outcome::Denied(format!(
                    "`{}` is refused by rule `{}`: this tool performs an action the bundle \
                     prohibits on this surface. Produce the draft and stop; do not attempt \
                     another route to the same effect.",
                    ctx.tool, spec.rule
                ))
            } else {
                Outcome::Passed
            }
        }

        // THE ONE CHECK THAT MUST NOT USE `relative_target` TO DECIDE APPLICABILITY. A path
        // outside the root does not strip to a relative one, and treating that as "does not
        // apply" would let the exact write this check exists to refuse straight through. So
        // the three scopes are matched by hand and the outside-the-root arm DENIES.
        EnforceKind::WriteConfinedTo { paths } => match ctx.target {
            WriteScope::None => Outcome::NotApplicable,
            WriteScope::Unnamed => Outcome::Unobservable(format!(
                "`{}` names no path this harness can resolve",
                ctx.tool
            )),
            WriteScope::Named(t) => match t.strip_prefix(ctx.root) {
                Ok(rel) => {
                    let rel = rel.to_string_lossy().replace('\\', "/");
                    if paths.iter().any(|p| under(&rel, p)) {
                        Outcome::Passed
                    } else {
                        Outcome::Denied(format!(
                            "writing `{rel}` is refused by rule `{}`: it is outside every \
                             location this bundle allows writes in ({}).",
                            spec.rule,
                            paths.join(", ")
                        ))
                    }
                }
                Err(_) => Outcome::Denied(format!(
                    "writing `{}` is refused by rule `{}`: it is outside the rules root \
                     entirely.",
                    t.display(),
                    spec.rule
                )),
            },
        },

        EnforceKind::FilenamePattern { paths, pattern } => {
            let Some(rel) = relative_target(ctx) else {
                return path_outcome(ctx);
            };
            if !paths.iter().any(|p| under(&rel, p)) {
                return Outcome::NotApplicable;
            }
            let name = rel.rsplit('/').next().unwrap_or(&rel);
            if pattern.matches(name) {
                Outcome::Passed
            } else {
                Outcome::Denied(format!(
                    "`{name}` is refused by rule `{}`: a file in {} must be named in the \
                     `{}` form.",
                    spec.rule,
                    paths.join(", "),
                    pattern.as_str()
                ))
            }
        }

        EnforceKind::ContentForbid {
            paths,
            applies_to,
            needles,
        } => {
            let Some(rel) = applicable_content_path(ctx, paths, applies_to) else {
                return path_outcome(ctx);
            };
            let text = match ctx.content {
                ObservedContent::Full(t) | ObservedContent::Added(t) => t,
                ObservedContent::Opaque => {
                    return Outcome::Unobservable(format!(
                        "`{}` writes `{rel}` without exposing its content at this boundary",
                        ctx.tool
                    ))
                }
            };
            match needles.iter().find(|n| text.contains(n.as_str())) {
                Some(n) => Outcome::Denied(format!(
                    "the text written to `{rel}` contains {n:?}, refused by rule `{}`.",
                    spec.rule
                )),
                None => Outcome::Passed,
            }
        }

        EnforceKind::ContentRequire {
            paths,
            applies_to,
            marker,
        } => {
            let Some(rel) = applicable_content_path(ctx, paths, applies_to) else {
                return path_outcome(ctx);
            };
            match ctx.content {
                ObservedContent::Full(t) => {
                    if t.contains(marker.as_str()) {
                        Outcome::Passed
                    } else {
                        Outcome::Denied(format!(
                            "`{rel}` does not contain {marker:?}, required by rule `{}`.",
                            spec.rule
                        ))
                    }
                }
                // An edit shows an inserted fragment, never the whole file. Requiring a
                // marker the rest of the file may already carry would refuse correct work.
                ObservedContent::Added(_) => Outcome::Unobservable(format!(
                    "`{}` edits `{rel}` and this boundary sees only the inserted text, not \
                     whether the whole file carries the required marker",
                    ctx.tool
                )),
                ObservedContent::Opaque => Outcome::Unobservable(format!(
                    "`{}` writes `{rel}` without exposing its content at this boundary",
                    ctx.tool
                )),
            }
        }
    }
}

/// A write is a call the harness resolved to a path, or one it could not resolve at all.
fn is_write(ctx: &ActionContext<'_>) -> bool {
    !matches!(ctx.target, WriteScope::None)
}

/// Say why a path-scoped check could not run, or that it simply does not apply.
///
/// The three answers are the three scopes: a read is NOT APPLICABLE, a write the harness could
/// not name is UNOBSERVABLE, and a named write outside the root is not applicable to a check
/// whose paths are all inside it (the confinement check is the one that refuses that case, and
/// it does not come through here).
fn path_outcome(ctx: &ActionContext<'_>) -> Outcome {
    match ctx.target {
        WriteScope::None | WriteScope::Named(_) => Outcome::NotApplicable,
        WriteScope::Unnamed => Outcome::Unobservable(format!(
            "`{}` names no path this harness can resolve",
            ctx.tool
        )),
    }
}

/// The root-relative target, if there is a named one inside the root.
///
/// A named target OUTSIDE the root also answers `None` here, which is why
/// [`EnforceKind::WriteConfinedTo`] is the check that must not use this to decide
/// applicability: an escape is exactly the case it exists to refuse. It reads
/// [`ActionContext::target`] directly.
fn relative_target(ctx: &ActionContext<'_>) -> Option<String> {
    let WriteScope::Named(t) = ctx.target else {
        return None;
    };
    let rel = t.strip_prefix(ctx.root).ok()?;
    Some(rel.to_string_lossy().replace('\\', "/"))
}

/// The root-relative path this content check applies to, or `None` when it does not apply.
fn applicable_content_path(
    ctx: &ActionContext<'_>,
    paths: &[String],
    applies_to: &[String],
) -> Option<String> {
    if !is_write(ctx) {
        return None;
    }
    let rel = relative_target(ctx)?;
    if !paths.iter().any(|p| under(&rel, p)) {
        return None;
    }
    let name = rel.rsplit('/').next().unwrap_or(&rel);
    if !applies_to.is_empty() && !applies_to.iter().any(|g| glob_match(g, name)) {
        return None;
    }
    Some(rel)
}

/// Is a root-relative path under a declared root-relative prefix?
///
/// COMPONENT-WISE, not a raw `starts_with`: `vault/Projects/draftsmen/x.md` must not count as
/// being under `vault/Projects/drafts/`, and a string prefix says it does.
fn under(rel: &str, prefix: &str) -> bool {
    let p = prefix.trim_end_matches('/');
    if p.is_empty() {
        return true;
    }
    rel == p || rel.starts_with(&format!("{p}/"))
}

/// `*` matches any run of characters, including none. No other metacharacter.
///
/// Deliberately the smallest thing that can express `mcp__slack__*` and `*.md`. A fuller
/// glob (character classes, `?`, negation) is a language, and a language in a config file
/// invites the reader to guess at semantics this file would then have to guarantee.
pub fn glob_match(pattern: &str, s: &str) -> bool {
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return pattern == s;
    }
    let mut rest = s;
    // The first segment must be a prefix.
    if let Some(first) = parts.first() {
        match rest.strip_prefix(first) {
            Some(r) => rest = r,
            None => return false,
        }
    }
    // The last must be a suffix, checked after the middles so it cannot overlap them.
    let last = parts[parts.len() - 1];
    for mid in &parts[1..parts.len() - 1] {
        if mid.is_empty() {
            continue;
        }
        match rest.find(mid) {
            Some(i) => rest = &rest[i + mid.len()..],
            None => return false,
        }
    }
    rest.len() >= last.len() && rest.ends_with(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> PathBuf {
        PathBuf::from("/w")
    }

    /// A tool call whose target is a named write when a path is given, and a plain read when
    /// it is not. The third scope (a write nothing can name) is built explicitly by the one
    /// test that is about it.
    fn ctx<'a>(
        tool: &'a str,
        target: Option<&'a Path>,
        content: &'a ObservedContent,
        root: &'a Path,
    ) -> ActionContext<'a> {
        ActionContext {
            harness: "claude-code",
            tool,
            target: match target {
                Some(p) => WriteScope::Named(p),
                None => WriteScope::None,
            },
            content,
            root,
        }
    }

    fn specs(toml_text: &str) -> Vec<EnforceSpec> {
        let doc: toml::Table = toml_text.parse().expect("toml");
        EnforceSpec::parse_all(&doc).expect("specs")
    }

    #[test]
    fn glob_matches_only_star() {
        assert!(glob_match("mcp__slack__*", "mcp__slack__send_message"));
        assert!(!glob_match("mcp__slack__*", "mcp__slacker__send"));
        assert!(glob_match("*.md", "a.md"));
        assert!(!glob_match("*.md", "a.mdx"));
        assert!(glob_match("*send*", "mcp__x__send_it"));
        assert!(glob_match("exact", "exact"));
        assert!(!glob_match("exact", "exactly"));
        assert!(glob_match("*", "anything"));
    }

    #[test]
    fn an_outbound_tool_is_refused_and_its_exception_is_not() {
        let s = specs(
            r#"
[[enforce]]
rule = "no-outbound"
kind = "deny-tools"
tools = ["mcp__mail__send_*", "mcp__chat__post_message"]
except = ["mcp__mail__send_draft_to_self"]
"#,
        );
        let r = root();
        let c = ObservedContent::Opaque;
        let v = check_action(&s, &ctx("mcp__mail__send_message", None, &c, &r));
        assert!(!v.allowed());
        match v.decision {
            Decision::Deny { rule, .. } => assert_eq!(rule, "no-outbound"),
            Decision::Allow => unreachable!(),
        }
        let v = check_action(&s, &ctx("mcp__mail__send_draft_to_self", None, &c, &r));
        assert!(v.allowed(), "the declared exception survives");
        let v = check_action(&s, &ctx("Read", None, &c, &r));
        assert!(v.allowed());
    }

    #[test]
    fn a_write_outside_the_allowed_roots_is_refused() {
        let s = specs(
            r#"
[[enforce]]
rule = "writes-stay-inside"
kind = "write-confined-to"
paths = ["vault/", ".jesse-artifacts/"]
"#,
        );
        let r = root();
        let c = ObservedContent::Full("x".to_string());
        let inside = PathBuf::from("/w/vault/Projects/a.md");
        assert!(check_action(&s, &ctx("Write", Some(&inside), &c, &r)).allowed());
        let outside = PathBuf::from("/w/.claude/settings.json");
        let v = check_action(&s, &ctx("Write", Some(&outside), &c, &r));
        assert!(!v.allowed());
    }

    #[test]
    fn a_write_outside_the_root_entirely_is_refused_rather_than_skipped() {
        // The hole this closes: a path outside the root does not strip to a root-relative
        // one, so a check that used "no relative path" to mean "does not apply" would let
        // the exact write it exists to refuse straight through.
        let s = specs(
            r#"
[[enforce]]
rule = "writes-stay-inside"
kind = "write-confined-to"
paths = ["vault/"]
"#,
        );
        let r = root();
        let c = ObservedContent::Full("x".to_string());
        let outside = PathBuf::from("/etc/somewhere-else.md");
        let v = check_action(&s, &ctx("Write", Some(&outside), &c, &r));
        assert!(!v.allowed(), "a write outside the root was allowed");
        assert!(v.decision_reason().contains("outside the rules root"));
    }

    #[test]
    fn a_read_is_not_reported_as_a_write_nothing_could_name() {
        // Otherwise every read in every turn logs a line about path checks that were never
        // going to apply to it, and the unobservable list stops meaning anything.
        let s = specs(
            r#"
[[enforce]]
rule = "writes-stay-inside"
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
needles = ["—"]
"#,
        );
        let r = root();
        let opaque = ObservedContent::Opaque;
        let v = check_action(&s, &ctx("Read", None, &opaque, &r));
        assert!(v.allowed());
        assert!(
            v.unobservable.is_empty(),
            "a read reported path checks as unchecked: {:?}",
            v.unobservable
        );
        // And the same call as an UNNAMEABLE write does report all three.
        let unnamed = ActionContext {
            harness: "codex",
            tool: "shell",
            target: WriteScope::Unnamed,
            content: &opaque,
            root: &r,
        };
        assert_eq!(check_action(&s, &unnamed).unobservable.len(), 3);
    }

    #[test]
    fn a_prefix_that_is_not_a_directory_boundary_does_not_count_as_under() {
        assert!(under(
            "vault/Projects/drafts/a.md",
            "vault/Projects/drafts/"
        ));
        assert!(!under(
            "vault/Projects/draftsmen/a.md",
            "vault/Projects/drafts/"
        ));
        assert!(under("vault/Projects/drafts", "vault/Projects/drafts"));
    }

    #[test]
    fn the_filename_pattern_covers_the_shapes_it_names() {
        assert!(NamePattern::DateTimeSlug.matches("2026-09-06-1430-plan.md"));
        assert!(!NamePattern::DateTimeSlug.matches("plan.md"));
        assert!(!NamePattern::DateTimeSlug.matches("2026-09-06-plan.md"));
        assert!(!NamePattern::DateTimeSlug.matches("2026-09-06-2599-plan.md"));
        assert!(NamePattern::DateSlug.matches("2026-09-06-plan.md"));
        assert!(!NamePattern::DateSlug.matches("2026-13-06-plan.md"));
        assert!(NamePattern::HyphenatedTitleCase.matches("Hyphenated-Title-Case.md"));
        assert!(!NamePattern::HyphenatedTitleCase.matches("lower-case.md"));
    }

    #[test]
    fn a_badly_named_draft_is_refused_and_a_file_elsewhere_is_not_checked() {
        let s = specs(
            r#"
[[enforce]]
rule = "draft-names"
kind = "filename-pattern"
paths = ["vault/Projects/drafts/"]
pattern = "date-time-slug"
"#,
        );
        let r = root();
        let c = ObservedContent::Full("x".to_string());
        let bad = PathBuf::from("/w/vault/Projects/drafts/notes.md");
        assert!(!check_action(&s, &ctx("Write", Some(&bad), &c, &r)).allowed());
        let good = PathBuf::from("/w/vault/Projects/drafts/2026-09-06-1430-notes.md");
        assert!(check_action(&s, &ctx("Write", Some(&good), &c, &r)).allowed());
        let elsewhere = PathBuf::from("/w/vault/Knowledge/notes.md");
        assert!(check_action(&s, &ctx("Write", Some(&elsewhere), &c, &r)).allowed());
    }

    #[test]
    fn a_forbidden_substring_is_refused_in_full_and_in_added_content() {
        let s = specs(
            r#"
[[enforce]]
rule = "no-dash-punctuation"
kind = "content-forbid"
paths = ["vault/Projects/drafts/"]
applies_to = ["*.md"]
needles = ["—"]
"#,
        );
        let r = root();
        let p = PathBuf::from("/w/vault/Projects/drafts/2026-09-06-1430-a.md");
        let full = ObservedContent::Full("clean text".to_string());
        assert!(check_action(&s, &ctx("Write", Some(&p), &full, &r)).allowed());
        let dirty = ObservedContent::Full("a \u{2014} b".to_string());
        assert!(!check_action(&s, &ctx("Write", Some(&p), &dirty, &r)).allowed());
        let added = ObservedContent::Added("a \u{2014} b".to_string());
        assert!(
            !check_action(&s, &ctx("Edit", Some(&p), &added, &r)).allowed(),
            "an edit that inserts a forbidden character is still a forbidden write"
        );
    }

    #[test]
    fn an_opaque_call_reports_the_check_as_unobservable_rather_than_passed() {
        let s = specs(
            r#"
[[enforce]]
rule = "no-dash-punctuation"
kind = "content-forbid"
paths = ["vault/"]
needles = ["—"]
"#,
        );
        let r = root();
        let opaque = ObservedContent::Opaque;
        let c = ActionContext {
            harness: "claude-code",
            tool: "Bash",
            target: WriteScope::Unnamed,
            content: &opaque,
            root: &r,
        };
        let v = check_action(&s, &c);
        assert!(
            v.allowed(),
            "an unobservable check does not refuse the call"
        );
        assert!(
            v.evaluated.is_empty(),
            "and it must not report as evaluated"
        );
        assert_eq!(v.unobservable.len(), 1);
        assert!(v.unobservable[0].starts_with("no-dash-punctuation:"));
    }

    #[test]
    fn a_required_marker_is_checked_on_a_full_write_and_skipped_on_an_edit() {
        let s = specs(
            r###"
[[enforce]]
rule = "archive-footer"
kind = "content-require"
paths = ["vault/Projects/drafts/"]
applies_to = ["*.md"]
marker = "## Archive"
"###,
        );
        let r = root();
        let p = PathBuf::from("/w/vault/Projects/drafts/2026-09-06-1430-a.md");
        let without = ObservedContent::Full("body".to_string());
        assert!(!check_action(&s, &ctx("Write", Some(&p), &without, &r)).allowed());
        let with = ObservedContent::Full("body\n\n## Archive\n- [ ] done".to_string());
        assert!(check_action(&s, &ctx("Write", Some(&p), &with, &r)).allowed());
        let edit = ObservedContent::Added("one more line".to_string());
        let v = check_action(&s, &ctx("Edit", Some(&p), &edit, &r));
        assert!(v.allowed());
        assert_eq!(v.unobservable.len(), 1, "the skip is reported, not silent");
    }

    #[test]
    fn an_unknown_enforcement_kind_is_refused_at_parse_time() {
        let doc: toml::Table = "[[enforce]]\nrule = \"x\"\nkind = \"run-a-script\"\n"
            .parse()
            .expect("toml");
        let e = EnforceSpec::parse_all(&doc).expect_err("refuses");
        assert!(e.to_string().contains("run-a-script"), "{e}");
    }

    #[test]
    fn an_unknown_key_on_a_known_kind_is_refused() {
        let doc: toml::Table =
            "[[enforce]]\nrule = \"x\"\nkind = \"deny-tools\"\ntools = [\"a\"]\nallow = [\"b\"]\n"
                .parse()
                .expect("toml");
        let e = EnforceSpec::parse_all(&doc).expect_err("refuses");
        assert!(e.to_string().contains("allow"), "{e}");
    }

    #[test]
    fn the_canonical_form_moves_when_a_parameter_changes() {
        let a = specs("[[enforce]]\nrule=\"r\"\nkind=\"deny-tools\"\ntools=[\"a\",\"b\"]\n");
        let b = specs("[[enforce]]\nrule=\"r\"\nkind=\"deny-tools\"\ntools=[\"a\"]\n");
        assert_ne!(a[0].canonical(), b[0].canonical());
    }
}
