//! The **citation validator** — a pure, in-process gate (no model) that runs on
//! every vault-QA child answer BEFORE it is returned to the user. It enforces the
//! citation discipline the vault-QA prompt asks for, so a locally-answered turn can
//! never deliver an uncited or fabricated claim:
//!
//!   1. **At least one citation.** An answer that cites no `.md` file fails.
//!   2. **Every cited file resolves.** A citation whose file cannot be found under
//!      the vault (after path normalization) fails.
//!   3. **Every quoted claim is real.** When the answer quotes a string right against
//!      a `path:line` citation, that exact substring must occur in the file (the
//!      named line first, the whole file as fallback).
//!
//! Any failure is a ladder rung ([`vaultqa`]) — the turn falls through to the hosted
//! path — never an error the user sees. Pure and unit-tested.
//!
//! **Path normalization.** qmd returns collection-relative paths, and the design
//! probes caught the local model PREPENDING its cwd to them. So before resolving, a
//! cited path is stripped of any absolute prefix up to and including the vault root
//! or a `todo-list/` component, and the remainder is tried against the vault root AND
//! against `todo-list/` under it.

use crate::*;

/// One extracted citation: the cited path, an optional `:line`, and the byte offset
/// in the answer where the path token starts (used to bind an adjacent quote).
#[derive(Debug, Clone, PartialEq)]
pub struct Citation {
    pub path: String,
    pub line: Option<usize>,
    pub at: usize,
}

/// Why a vault-QA answer failed citation validation. Each maps to a ladder rung
/// (validator-fail); the specific reason is only ever logged, never shown.
#[derive(Debug, Clone, PartialEq)]
pub enum CitationFailure {
    /// The answer cited no `.md` file at all.
    NoCitations,
    /// A cited file could not be resolved under the vault.
    UnresolvedFile(String),
    /// A string quoted against a `path:line` does not occur in that file.
    FabricatedQuote { path: String, quote: String },
}

/// A byte is part of a cited path token: alphanumerics plus the path punctuation a
/// vault path uses. `:` is deliberately excluded (it introduces the `:line`).
fn is_path_byte(c: u8) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, b'/' | b'.' | b'-' | b'_')
}

/// Extract every `<path>.md` reference (with optional `:line`) from an answer, in
/// order, recording each path token's start offset. Regex-free: it scans for `.md`,
/// walks left over path bytes to the token start (paths are ASCII, so byte-walking
/// stays on char boundaries), then reads an optional `:<digits>` suffix.
pub fn extract_citations(answer: &str) -> Vec<Citation> {
    let bytes = answer.as_bytes();
    let mut out = Vec::new();
    let mut search = 0usize;
    while let Some(rel) = answer[search..].find(".md") {
        let dot = search + rel; // index of '.' in ".md"
        let end = dot + 3; // just past "md"
                           // Walk left over path bytes to the token start.
        let mut start = dot;
        while start > 0 && is_path_byte(bytes[start - 1]) {
            start -= 1;
        }
        // Optional `:<digits>` line suffix.
        let mut line = None;
        let mut cursor = end;
        if answer[end..].starts_with(':') {
            let digits: String = answer[end + 1..]
                .chars()
                .take_while(|c| c.is_ascii_digit())
                .collect();
            if !digits.is_empty() {
                line = digits.parse::<usize>().ok();
                cursor = end + 1 + digits.len();
            }
        }
        // Only record a token that actually has a name before ".md" (guards a bare
        // ".md" or ".md" glued to a non-path char).
        if start < dot {
            out.push(Citation {
                path: answer[start..end].to_string(),
                line,
                at: start,
            });
        }
        search = cursor.max(end);
    }
    out
}

/// Candidate on-disk paths a cited `raw` path may resolve to under `vault_root`.
/// Applies the normalization the design requires: try the path as-is (relative);
/// strip any prefix up to and including the vault root; strip any prefix up to a
/// `todo-list/` component; then resolve each remainder against the vault root AND
/// against `todo-list/` under it.
pub fn normalize_candidates(raw: &str, vault_root: &Path) -> Vec<PathBuf> {
    let raw = raw.trim();
    let vault_str = vault_root.to_string_lossy().to_string();
    let mut remainders = vec![raw.to_string()];
    // Strip an absolute prefix up to and including the vault root.
    if let Some(idx) = raw.find(&vault_str) {
        remainders.push(raw[idx + vault_str.len()..].to_string());
    }
    // Strip up to (and including the start of) a `todo-list/` component.
    if let Some(idx) = raw.rfind("todo-list/") {
        remainders.push(raw[idx..].to_string());
    }
    let mut out = Vec::new();
    for rem in remainders {
        let rem = rem.trim_start_matches('/');
        if rem.is_empty() {
            continue;
        }
        out.push(vault_root.join(rem));
        out.push(vault_root.join("todo-list").join(rem));
    }
    out
}

/// Resolve a cited path to an existing file under the vault, or `None`.
fn resolve(raw: &str, vault_root: &Path) -> Option<PathBuf> {
    normalize_candidates(raw, vault_root)
        .into_iter()
        .find(|c| c.is_file())
}

/// Separator characters allowed between a closing quote and the citation it binds
/// to (`"quote" (path.md:42)`, `"quote" — path.md:12`, `"quote", path.md`).
fn is_bind_sep(c: char) -> bool {
    matches!(
        c,
        ' ' | '\t'
            | '\n'
            | '('
            | '['
            | ')'
            | ']'
            | '`'
            | '—'
            | '–'
            | '-'
            | ','
            | ':'
            | ';'
            | '"'
            | '\''
    )
}

/// Find quoted substrings (inside straight double quotes) each bound to the citation
/// that immediately follows it — the "quotes a string against a path:line" form.
/// Returns `(quote, citation_index)` pairs. A quote with no citation right after it
/// is not a bound claim and is ignored (a scare-quote in prose is not a fabrication).
fn bound_quotes<'a>(answer: &'a str, cites: &[Citation]) -> Vec<(&'a str, usize)> {
    let bytes = answer.as_bytes();
    let mut pairs = Vec::new();
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'"' {
            // Find the closing quote.
            if let Some(rel) = answer[i + 1..].find('"') {
                let inner_start = i + 1;
                let inner_end = inner_start + rel;
                let quote = &answer[inner_start..inner_end];
                let close = inner_end + 1; // just past the closing quote
                                           // Bind to a citation whose token starts within the gap after the
                                           // close, if every char in the gap is a separator.
                if let Some(idx) = cites
                    .iter()
                    .position(|c| c.at >= close && answer[close..c.at].chars().all(is_bind_sep))
                {
                    if !quote.trim().is_empty() {
                        pairs.push((quote, idx));
                    }
                }
                i = close;
                continue;
            }
        }
        i += 1;
    }
    pairs
}

/// Whether `quote` occurs in `content`: the named `line` first (1-indexed), then the
/// whole file as fallback. Exact substring match.
fn quote_present(content: &str, quote: &str, line: Option<usize>) -> bool {
    if let Some(l) = line {
        if let Some(named) = l.checked_sub(1).and_then(|n| content.lines().nth(n)) {
            if named.contains(quote) {
                return true;
            }
        }
    }
    content.contains(quote)
}

/// Validate a vault-QA child answer against its citations, in-process. Returns the
/// citation count on success, or the first [`CitationFailure`] encountered. Reads the
/// cited files (read-only) to check quotes; a file that can't be read is treated as
/// unresolved.
pub fn validate_vaultqa_answer(answer: &str, vault_root: &Path) -> Result<usize, CitationFailure> {
    let cites = extract_citations(answer);
    if cites.is_empty() {
        return Err(CitationFailure::NoCitations);
    }
    // Every cited file must resolve.
    let mut resolved: Vec<PathBuf> = Vec::with_capacity(cites.len());
    for c in &cites {
        match resolve(&c.path, vault_root) {
            Some(p) => resolved.push(p),
            None => return Err(CitationFailure::UnresolvedFile(c.path.clone())),
        }
    }
    // Every quoted claim bound to a citation must occur in that citation's file.
    for (quote, idx) in bound_quotes(answer, &cites) {
        let content = std::fs::read_to_string(&resolved[idx])
            .map_err(|_| CitationFailure::UnresolvedFile(cites[idx].path.clone()))?;
        if !quote_present(&content, quote, cites[idx].line) {
            return Err(CitationFailure::FabricatedQuote {
                path: cites[idx].path.clone(),
                quote: quote.to_string(),
            });
        }
    }
    Ok(cites.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A throwaway vault with `todo-list/Today.md` holding known lines. Returns the
    /// root; the caller removes it.
    fn temp_vault() -> PathBuf {
        let root = std::env::temp_dir().join(format!("jesse-vaultqa-cite-{}", random_hex()));
        std::fs::create_dir_all(root.join("todo-list")).unwrap();
        std::fs::write(
            root.join("todo-list/Today.md"),
            "# Today\nVO2 max is 52 as of last week.\nDentist appointment is on Friday.\n",
        )
        .unwrap();
        root
    }

    #[test]
    fn extract_finds_paths_with_and_without_line() {
        let cites =
            extract_citations("See `todo-list/Today.md:2` and also notes/plan.md for context.");
        assert_eq!(cites.len(), 2);
        assert_eq!(cites[0].path, "todo-list/Today.md");
        assert_eq!(cites[0].line, Some(2));
        assert_eq!(cites[1].path, "notes/plan.md");
        assert_eq!(cites[1].line, None);
    }

    #[test]
    fn valid_relative_path_passes() {
        let root = temp_vault();
        let answer = "Your VO2 max is 52 (todo-list/Today.md:2).";
        assert_eq!(validate_vaultqa_answer(answer, &root), Ok(1));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn bare_name_resolves_under_todo_list() {
        // A citation without the `todo-list/` prefix resolves via the "against
        // todo-list/ under the vault" arm.
        let root = temp_vault();
        let answer = "Friday, per Today.md.";
        assert_eq!(validate_vaultqa_answer(answer, &root), Ok(1));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn misrooted_absolute_path_from_the_probes_is_normalized_and_passes() {
        // The model prepended its cwd (the vault) to a collection-relative path, the
        // exact mis-rooting the design probes caught. Stripping up to and including
        // the vault root recovers `todo-list/Today.md`, which resolves.
        let root = temp_vault();
        let mis = format!("{}/todo-list/Today.md:2", root.display());
        let answer = format!("VO2 max is 52 ({mis}).");
        assert_eq!(validate_vaultqa_answer(&answer, &root), Ok(1));
        // Also handle a DIFFERENT absolute cwd prefix, stripped at the todo-list/ arm.
        let other = "/private/tmp/scratch/todo-list/Today.md:2".to_string();
        let answer2 = format!("VO2 max is 52 ({other}).");
        assert_eq!(validate_vaultqa_answer(&answer2, &root), Ok(1));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn nonexistent_file_fails() {
        let root = temp_vault();
        let answer = "It's in todo-list/Ghost.md.";
        assert_eq!(
            validate_vaultqa_answer(answer, &root),
            Err(CitationFailure::UnresolvedFile(
                "todo-list/Ghost.md".to_string()
            ))
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn real_file_with_a_fabricated_quote_fails() {
        // The file resolves, but the quoted string does not occur in it (the model
        // invented a quotation and attributed it to a real line).
        let root = temp_vault();
        let answer = "It says \"VO2 max is 61 and rising\" (todo-list/Today.md:2).";
        match validate_vaultqa_answer(answer, &root) {
            Err(CitationFailure::FabricatedQuote { path, quote }) => {
                assert_eq!(path, "todo-list/Today.md");
                assert_eq!(quote, "VO2 max is 61 and rising");
            }
            other => panic!("expected FabricatedQuote, got {other:?}"),
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn real_quote_against_the_named_line_passes() {
        // The honest counterpart: the quoted substring is on the cited line.
        let root = temp_vault();
        let answer = "It says \"VO2 max is 52\" (todo-list/Today.md:2).";
        assert_eq!(validate_vaultqa_answer(answer, &root), Ok(1));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn zero_citation_answer_fails() {
        let root = temp_vault();
        assert_eq!(
            validate_vaultqa_answer("Your VO2 max is around 52, I think.", &root),
            Err(CitationFailure::NoCitations)
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
