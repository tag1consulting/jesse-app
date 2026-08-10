//! `GET /jesse/today/items/{id}/detail` — the "more information" note behind one
//! day-file item.
//!
//! **This is the first time the bridge serves arbitrary vault CONTENT on the read
//! path**, so the sandbox below is the substance of this module and the endpoint
//! is the thin part. Everything else here is the same posture as
//! [`crate::today`]: bearer auth, the shared rate limiter, a strong ETag with
//! `If-None-Match`, and a pure function of file state.
//!
//! ## The reachable set is "notes linked from Today.md", by construction
//!
//! Detail is keyed by **item id**, never by a path. There is deliberately no
//! `?path=` reader: the caller cannot name a file, it can only name an item, and
//! the bridge re-parses `Today.md` to find out what that item links. Adding a
//! path parameter later would turn this from "a fixed, file-derived set of notes"
//! into a general vault reader with a token in front of it — a different security
//! object entirely. Don't.
//!
//! ## What the sandbox actually guarantees
//!
//! The link text is written by an agent into a file a human also edits, so it is
//! treated as untrusted input even though no request supplies it:
//!
//! * **No absolute paths.** A target that parses as absolute, or carries a root
//!   or prefix component, is refused before it is joined to anything.
//! * **No `..` traversal.** A `ParentDir` component is refused outright, and the
//!   canonicalized result must still sit under the canonicalized notes root — so
//!   the check does not depend on having enumerated every spelling of `..`.
//! * **No symlink escape.** [`std::fs::canonicalize`] resolves the whole chain
//!   before the confinement test, so a link inside the vault pointing at
//!   `/etc/passwd` resolves outside the root and is refused. A symlink that stays
//!   inside the vault is fine — it is still a vault note.
//! * **Regular files only.** A directory, fifo or device never becomes a detail.
//! * **Bounded read.** At most [`DETAIL_MAX_BYTES`] + 1 bytes ever enter memory
//!   (the read is capped at the syscall, not after slurping the file), and the
//!   answer is truncated on a UTF-8 char boundary.
//! * **Read-only.** Nothing in this module opens a file for writing, creates one
//!   or removes one. The detail path adds no write surface of any kind.

use crate::*;
use std::io::Read as _;

/// The cap on a detail note's markdown. Generous for a hand-written vault note
/// and small enough that a pathological file (a stray export, a log someone
/// dropped in the vault) can neither exhaust memory nor stall the phone.
///
/// Capped in BYTES on a char boundary via [`truncate_bytes_on_char_boundary`],
/// the same idiom and for the same reason as `MAX_OUTPUT_BYTES`: a character
/// count would admit ~4× the intended budget on multibyte text.
pub const DETAIL_MAX_BYTES: usize = 64 * 1024;

/// One resolved detail note.
#[derive(PartialEq, Debug, Clone)]
pub struct Detail {
    /// The note's path relative to the notes root — what a client displays and
    /// what an operator can look up. Never an absolute path: the bridge's own
    /// vault location is not the app's business.
    pub path: String,
    /// The wiki target this was resolved from, verbatim, so a client can show
    /// which of an item's links it got.
    pub target: String,
    pub markdown: String,
    /// The note was longer than [`DETAIL_MAX_BYTES`] and the markdown is a prefix.
    pub truncated: bool,
}

/// Why an item has no detail to serve. A **typed** answer, not an error: an item
/// with no linked note is an ordinary, expected item, and a `500` would have the
/// app render a failure for a perfectly healthy day file.
#[derive(PartialEq, Debug, Clone, Copy)]
pub enum NoDetail {
    /// The item carries no wiki link at all.
    NoTarget,
    /// It carries wiki links, but none resolved to a readable file under the
    /// vault root — a note not written yet, or a target the sandbox refused.
    Unresolved,
}

impl NoDetail {
    /// The wire spelling, in the response's `reason`.
    pub fn as_str(self) -> &'static str {
        match self {
            NoDetail::NoTarget => "no-target",
            NoDetail::Unresolved => "unresolved-target",
        }
    }
}

/// Join `rel` under `root` **only if it cannot escape it**, and only if the
/// result is an existing regular file.
///
/// Two independent gates, on purpose. The component check refuses the shapes
/// that should never appear at all (absolute, rooted, `..`); the canonicalize +
/// `starts_with` check is what actually holds the boundary, because it is
/// evaluated on the fully symlink-resolved path and therefore does not depend on
/// having anticipated a spelling. Either alone would be defensible; both means a
/// gap in one is not a gap in the sandbox.
///
/// Returns the canonical absolute path, or `None` — never an error type, because
/// every rejection reason collapses to the same answer for the caller and
/// distinguishing them on the wire would be a probing oracle for what exists
/// outside the vault.
pub fn resolve_under_root(root: &Path, rel: &str) -> Option<PathBuf> {
    let rel = rel.trim();
    if rel.is_empty() || rel.contains('\0') {
        return None;
    }
    let rel = Path::new(rel);
    if rel.is_absolute() {
        return None;
    }
    for component in rel.components() {
        match component {
            std::path::Component::Normal(_) | std::path::Component::CurDir => {}
            // RootDir, Prefix and ParentDir all mean "not a vault-relative note".
            _ => return None,
        }
    }
    let root = std::fs::canonicalize(root).ok()?;
    let canonical = std::fs::canonicalize(root.join(rel)).ok()?;
    if !canonical.starts_with(&root) {
        return None;
    }
    // `canonicalize` resolved every symlink already, so this asks about the real
    // target: a directory or a device is not a note.
    std::fs::metadata(&canonical)
        .ok()?
        .is_file()
        .then_some(canonical)
}

/// The filenames a wiki target can name, in preference order.
///
/// Wiki links are extension-less (`[[todo-list/Projects/Tag1/HR-Finance]]`), so
/// `<rel>.md` is the overwhelmingly common form (44 of the 46 distinct targets in
/// a live day file). `<rel>` verbatim covers a link that already carries its
/// extension, and `<rel>/<basename>.md` is Obsidian's folder-note convention,
/// which the vault does use (2 of those 46).
fn candidate_names(rel: &str) -> Vec<String> {
    let mut out = vec![format!("{rel}.md"), rel.to_string()];
    if let Some(base) = Path::new(rel).file_name().and_then(|b| b.to_str()) {
        out.push(format!("{rel}/{base}.md"));
    }
    out
}

/// Resolve one wiki target to a readable note under the notes root, or `None`.
pub fn resolve_target(notes_root: &Path, target: &str) -> Option<PathBuf> {
    let rel = vault_relative(target);
    candidate_names(&rel)
        .into_iter()
        .find_map(|name| resolve_under_root(notes_root, &name))
}

/// Read at most [`DETAIL_MAX_BYTES`] of a note.
///
/// The cap is applied to the READ, not to the result: `take` bounds what the
/// kernel hands back, so a 2 GB file in the vault costs one 64 KB buffer rather
/// than 2 GB of resident memory. Invalid UTF-8 is replaced rather than refused —
/// a note with a stray byte in it still renders.
fn read_capped(path: &Path) -> std::io::Result<(String, bool)> {
    let mut buf = Vec::new();
    std::fs::File::open(path)?
        .take(DETAIL_MAX_BYTES as u64 + 1)
        .read_to_end(&mut buf)?;
    let truncated = buf.len() > DETAIL_MAX_BYTES;
    let text = String::from_utf8_lossy(&buf).into_owned();
    let text = if truncated {
        truncate_bytes_on_char_boundary(&text, DETAIL_MAX_BYTES).to_string()
    } else {
        text
    };
    Ok((text, truncated))
}

/// The item's canonical "more information" note: its **first** wiki link, in
/// source order, that resolves to a readable file under the vault root.
///
/// First-that-resolves is an interim rule, and the ordering is the contract that
/// makes it predictable: [`crate::today::extract_links`] emits links in source
/// order, so the target is the first one a reader would meet in the line. Once
/// the day file designates a detail note per item, this becomes a lookup of that
/// designation and the fallback stays for items written before it.
pub fn detail_for(notes_root: &Path, item: &TodayItem) -> Result<Detail, NoDetail> {
    let wiki: Vec<&TodayLink> = item.links.iter().filter(|l| l.kind == "wiki").collect();
    if wiki.is_empty() {
        return Err(NoDetail::NoTarget);
    }
    for link in wiki {
        let Some(path) = resolve_target(notes_root, &link.target) else {
            continue;
        };
        let Ok((markdown, truncated)) = read_capped(&path) else {
            continue;
        };
        return Ok(Detail {
            // Relative to the notes root — see `Detail::path`. The strip cannot
            // fail (resolution proved containment), but a lossy display path is
            // still better than leaking an absolute one if it somehow did.
            path: std::fs::canonicalize(notes_root)
                .ok()
                .and_then(|r| path.strip_prefix(r).ok().map(|p| p.display().to_string()))
                .unwrap_or_else(|| link.target.clone()),
            target: link.target.clone(),
            markdown,
            truncated,
        });
    }
    Err(NoDetail::Unresolved)
}

/// The strong ETag for a detail answer: a hash over the resolved path and the
/// bytes served, so editing the note OR the item's link to a different note both
/// move the tag. A no-detail answer gets a stable tag of its own, so an item that
/// will never have a note still costs one `304` per poll rather than a body.
pub fn detail_etag(detail: &Result<Detail, NoDetail>) -> String {
    match detail {
        Ok(d) => strong_etag(&format!("ok\u{0}{}\u{0}{}", d.path, d.markdown)),
        Err(reason) => strong_etag(&format!("none\u{0}{}", reason.as_str())),
    }
}

fn detail_body(id: &str, detail: &Result<Detail, NoDetail>, etag: &str) -> Value {
    match detail {
        Ok(d) => json!({
            "id": id,
            "status": "ok",
            "path": d.path,
            "target": d.target,
            "markdown": d.markdown,
            "truncated": d.truncated,
            "etag": etag,
            "generatedAt": rfc3339_utc(SystemTime::now()),
        }),
        Err(reason) => json!({
            "id": id,
            "status": "no-detail",
            "reason": reason.as_str(),
            "etag": etag,
            "generatedAt": rfc3339_utc(SystemTime::now()),
        }),
    }
}

/// `GET /jesse/today/items/:id/detail` — the note behind one item.
///
/// The item is located by **re-parsing `Today.md` at request time**, never by a
/// stored offset: the day file is rewritten in full every morning and edited
/// between rebuilds, so a remembered position is wrong by construction. That
/// re-parse is also what bounds the reachable set (see the module docs).
///
/// `410 Gone` — not `404` — when the id is unknown: the client had this id from a
/// snapshot, and the honest answer is that the item it names no longer exists in
/// the day file, so the client should drop its row rather than retry the URL.
pub async fn jesse_today_detail(
    State(st): State<AppState>,
    UrlPath(id): UrlPath<String>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    let (_, snapshot) = build_snapshot(&st.cfg);
    let located = locate_by_id(&snapshot, &id).ok_or_else(|| {
        (
            StatusCode::GONE,
            "no such item in the day file — refetch GET /jesse/today".to_string(),
        )
    })?;

    let detail = detail_for(&notes_root(&st.cfg), located.item);
    let etag = detail_etag(&detail);
    if let Some(inm) = headers
        .get(axum::http::header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
    {
        if if_none_match_matches(inm, &etag) {
            return Ok(
                (StatusCode::NOT_MODIFIED, [(axum::http::header::ETAG, etag)]).into_response(),
            );
        }
    }
    let body = detail_body(&id, &detail, &etag);
    Ok((
        StatusCode::OK,
        [
            (axum::http::header::ETAG, etag),
            (
                axum::http::header::CONTENT_TYPE,
                "application/json".to_string(),
            ),
        ],
        serde_json::to_string(&body).unwrap_or_default(),
    )
        .into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A synthetic notes root: `<tmp>/<name>/vault/…`, with the day file and a
    /// couple of notes. Invented content only — never a copy of a real vault.
    struct Vault {
        root: PathBuf,
    }

    impl Vault {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("jesse-detail-{name}"));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(root.join(config::VAULT_SUBDIR)).unwrap();
            Self { root }
        }

        fn notes(&self) -> PathBuf {
            self.root.join(config::VAULT_SUBDIR)
        }

        fn write(&self, rel: &str, body: &str) -> PathBuf {
            let path = self.notes().join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, body).unwrap();
            path
        }

        fn cfg(&self) -> Config {
            Config {
                vault: self.root.to_string_lossy().into_owned(),
                ..testutil::test_config()
            }
        }
    }

    impl Drop for Vault {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn item_with(links: &str) -> TodayItem {
        let snap = parse_today(&format!(
            "# Today\n\n## Do Now\n\n* [ ] **A thing.** {links}\n"
        ));
        snap.sections[0].items[0].clone()
    }

    #[test]
    fn a_wiki_link_resolves_to_its_note_and_reports_a_vault_relative_path() {
        let v = Vault::new("resolves");
        v.write("Projects/Demo/Widget.md", "# Widget\n\nThe body.\n");
        let got = detail_for(&v.notes(), &item_with("[[todo-list/Projects/Demo/Widget]]")).unwrap();
        assert_eq!(got.path, "Projects/Demo/Widget.md");
        assert_eq!(got.target, "todo-list/Projects/Demo/Widget");
        assert!(got.markdown.contains("The body."));
        assert!(!got.truncated);
        assert!(
            !got.path.starts_with('/'),
            "the bridge's own vault location is not on the wire: {}",
            got.path
        );
    }

    #[test]
    fn the_folder_note_and_explicit_extension_forms_both_resolve() {
        let v = Vault::new("forms");
        v.write("Projects/Folder/Folder.md", "folder note\n");
        v.write("Projects/Explicit.md", "explicit\n");
        assert_eq!(
            detail_for(&v.notes(), &item_with("[[todo-list/Projects/Folder]]"))
                .unwrap()
                .path,
            "Projects/Folder/Folder.md"
        );
        assert_eq!(
            detail_for(&v.notes(), &item_with("[[todo-list/Projects/Explicit.md]]"))
                .unwrap()
                .path,
            "Projects/Explicit.md"
        );
    }

    #[test]
    fn a_heading_link_resolves_to_the_note_and_the_first_resolvable_link_wins() {
        let v = Vault::new("order");
        v.write("Projects/Second.md", "second\n");
        // The FIRST wiki link names a note that does not exist; the second does.
        let item =
            item_with("[[todo-list/Projects/Missing]] and [[todo-list/Projects/Second#A-Heading]]");
        let got = detail_for(&v.notes(), &item).unwrap();
        assert_eq!(got.path, "Projects/Second.md");
        assert!(got.markdown.contains("second"));
    }

    #[test]
    fn an_item_with_no_wiki_link_is_typed_no_detail_not_an_error() {
        let v = Vault::new("nolink");
        assert_eq!(
            detail_for(&v.notes(), &item_with("https://example.invalid/x")),
            Err(NoDetail::NoTarget)
        );
        assert_eq!(NoDetail::NoTarget.as_str(), "no-target");
    }

    #[test]
    fn a_link_to_a_note_that_does_not_exist_is_typed_no_detail() {
        let v = Vault::new("missing");
        assert_eq!(
            detail_for(&v.notes(), &item_with("[[todo-list/Projects/Nope]]")),
            Err(NoDetail::Unresolved)
        );
        assert_eq!(NoDetail::Unresolved.as_str(), "unresolved-target");
    }

    // ---- The sandbox ------------------------------------------------------

    #[test]
    fn dot_dot_traversal_out_of_the_vault_is_refused_and_nothing_leaks() {
        let v = Vault::new("traversal");
        // A real, readable file OUTSIDE the notes root — one directory up, which
        // is exactly what `..` reaches.
        let secret = v.root.join("outside-secret.md");
        std::fs::write(&secret, "TOP SECRET outside the vault\n").unwrap();

        for target in [
            "[[../outside-secret]]",
            "[[todo-list/../outside-secret]]",
            "[[../../../../etc/passwd]]",
            "[[Projects/../../outside-secret]]",
        ] {
            let got = detail_for(&v.notes(), &item_with(target));
            assert_eq!(got, Err(NoDetail::Unresolved), "escaped via {target}");
        }
        assert_eq!(
            std::fs::read_to_string(&secret).unwrap(),
            "TOP SECRET outside the vault\n",
            "the file outside the vault is untouched"
        );
    }

    #[test]
    fn an_absolute_path_from_the_file_is_refused() {
        let v = Vault::new("absolute");
        let secret = v.root.join("outside-secret.md");
        std::fs::write(&secret, "TOP SECRET\n").unwrap();
        for target in [
            format!("[[{}]]", secret.display()),
            "[[/etc/passwd]]".to_string(),
            "[[//etc/passwd]]".to_string(),
        ] {
            assert_eq!(
                detail_for(&v.notes(), &item_with(&target)),
                Err(NoDetail::Unresolved),
                "absolute target served: {target}"
            );
        }
    }

    #[test]
    fn a_symlink_escaping_the_vault_root_is_refused() {
        let v = Vault::new("symlink");
        let secret = v.root.join("outside-secret.md");
        std::fs::write(&secret, "TOP SECRET via symlink\n").unwrap();
        // A symlink that LIVES in the vault and POINTS outside it. Every
        // component is `Normal`, so only the canonicalize check catches this.
        std::os::unix::fs::symlink(&secret, v.notes().join("Escape.md")).unwrap();
        assert_eq!(
            detail_for(&v.notes(), &item_with("[[todo-list/Escape]]")),
            Err(NoDetail::Unresolved),
            "a symlink out of the vault must not be followed"
        );

        // …while a symlink that stays inside it is still a vault note.
        v.write("Projects/Real.md", "inside\n");
        std::os::unix::fs::symlink(
            v.notes().join("Projects/Real.md"),
            v.notes().join("Alias.md"),
        )
        .unwrap();
        assert!(detail_for(&v.notes(), &item_with("[[todo-list/Alias]]"))
            .unwrap()
            .markdown
            .contains("inside"));
    }

    #[test]
    fn a_directory_is_never_served_as_a_detail() {
        let v = Vault::new("directory");
        std::fs::create_dir_all(v.notes().join("Projects/Bare")).unwrap();
        assert_eq!(
            detail_for(&v.notes(), &item_with("[[todo-list/Projects/Bare]]")),
            Err(NoDetail::Unresolved)
        );
    }

    #[test]
    fn resolve_under_root_refuses_every_escape_shape() {
        let v = Vault::new("under-root");
        v.write("Inside.md", "ok\n");
        let root = v.notes();
        assert!(resolve_under_root(&root, "Inside.md").is_some());
        assert!(resolve_under_root(&root, "./Inside.md").is_some());
        for bad in ["", "   ", "/etc/passwd", "../x", "a/../../x", "In\0side.md"] {
            assert!(resolve_under_root(&root, bad).is_none(), "accepted {bad:?}");
        }
    }

    #[test]
    fn a_note_over_the_cap_is_truncated_on_a_char_boundary() {
        let v = Vault::new("cap");
        // Multibyte throughout, so a byte cap that ignored char boundaries would
        // slice one in half and a char cap would keep ~3× the byte budget.
        let big = "é".repeat(DETAIL_MAX_BYTES);
        v.write("Big.md", &big);
        let got = detail_for(&v.notes(), &item_with("[[todo-list/Big]]")).unwrap();
        assert!(got.truncated, "a note over the cap reports truncated");
        assert!(
            got.markdown.len() <= DETAIL_MAX_BYTES,
            "capped in bytes, got {}",
            got.markdown.len()
        );
        assert!(
            got.markdown.chars().all(|c| c == 'é'),
            "the cut lands on a char boundary — no replacement char at the end"
        );
    }

    #[test]
    fn the_etag_covers_the_path_and_the_bytes() {
        let v = Vault::new("etag");
        v.write("Projects/A.md", "first\n");
        v.write("Projects/B.md", "first\n");
        let a = detail_for(&v.notes(), &item_with("[[todo-list/Projects/A]]"));
        let b = detail_for(&v.notes(), &item_with("[[todo-list/Projects/B]]"));
        assert_ne!(
            detail_etag(&a),
            detail_etag(&b),
            "same bytes at a different path is a different answer"
        );

        v.write("Projects/A.md", "second\n");
        let edited = detail_for(&v.notes(), &item_with("[[todo-list/Projects/A]]"));
        assert_ne!(
            detail_etag(&a),
            detail_etag(&edited),
            "editing the note moves the tag"
        );

        // A no-detail answer still carries a stable tag, so polling it 304s.
        let none = detail_for(&v.notes(), &item_with("no links here"));
        assert_eq!(detail_etag(&none), detail_etag(&none.clone()));
        assert_ne!(detail_etag(&none), detail_etag(&a));
    }

    #[test]
    fn the_endpoint_serves_reads_304s_and_gones() {
        let v = Vault::new("endpoint");
        v.write(
            today::TODAY_FILE,
            "# Today\n\n## Do Now\n\n* [ ] **A thing.** [[todo-list/Projects/Demo]]\n",
        );
        v.write("Projects/Demo.md", "# Demo\n\nthe detail note\n");
        let cfg = v.cfg();
        let (_, snapshot) = build_snapshot(&cfg);
        let id = snapshot.sections[0].items[0].id.clone();

        let detail = detail_for(&notes_root(&cfg), &snapshot.sections[0].items[0]);
        let etag = detail_etag(&detail);
        let body = detail_body(&id, &detail, &etag);
        assert_eq!(body["status"], "ok");
        assert_eq!(body["path"], "Projects/Demo.md");
        assert!(body["markdown"]
            .as_str()
            .unwrap()
            .contains("the detail note"));

        // The `If-None-Match` contract this endpoint honours.
        assert!(if_none_match_matches(&etag, &etag));
        assert!(if_none_match_matches("*", &etag));
        assert!(!if_none_match_matches("\"nope\"", &etag));

        // An id that is not in the file is gone, not merely absent.
        assert!(locate_by_id(&snapshot, "0123456789ab").is_none());
    }
}
