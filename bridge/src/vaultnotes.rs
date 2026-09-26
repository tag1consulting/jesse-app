//! `GET /jesse/vault/note` — one note from the Studio's vault, by path or by wiki target.
//!
//! ## Why this exists, when `todaydetail` says "don't"
//!
//! The item detail route is keyed by item id on purpose, and its module docs argue against a
//! path reader. That argument was about reach: a path parameter turns a fixed set of notes
//! into a general vault reader behind a token. It is now the lesser harm. Obsidian on iOS
//! syncs only while it is open in the foreground, so the phone's copy of the vault is
//! routinely hours behind the Studio, and the app was opening, showing and EDITING those
//! stale copies while this process held the current ones. On 2026-09-24 a folder renamed on
//! the Studio did not exist on the phone at all, and strand taps failed. The app now asks
//! here first, and uses its own folder only offline or when the two are byte-identical.
//!
//! The token already grants turns that read any file in the vault through the agent, so
//! serving one `.md` note directly adds no reach the bearer does not have; what it must not
//! add is reach OUTSIDE the notes: see [`safe_rel`] and [`resolve_note`].
//!
//! ## The contract
//!
//! Exactly one of `path` (vault relative) or `target` (a wiki target; alias and heading are
//! dropped by [`crate::today::vault_relative`]). `200` with `path`, `markdown`, `modified`
//! (RFC 3339), `sha256` (of the FULL file, even when the markdown is cut), `truncated`; the
//! `ETag` is the quoted sha256, and a matching `If-None-Match` is a `304`. That makes a
//! conditional fetch with the device's own hash the whole "is my copy current" question in
//! one round trip. A note that is not there is `404` with `{"error":"note_not_found"}`, a
//! body an older bridge's unknown-route `404` never carries, so the app can tell "no such
//! note" from "no such route". A path the rules refuse is `400` `{"error":"refused"}`.

use crate::*;
use std::io::Read as _;

/// The cap on the markdown served. The item detail route's, so a note is cut at the same
/// place whichever route served it.
pub const NOTE_MAX_BYTES: usize = crate::todaydetail::DETAIL_MAX_BYTES;

/// The folder that holds verified junk awaiting deletion. Never served, never written.
pub const PURGE_DIR: &str = "_to-purge";

/// The error word a missing note answers with. Checked by the app, so it is a constant.
pub const NOTE_NOT_FOUND: &str = "note_not_found";

/// Whether `rel` is a vault relative path this module may name at all, before anything
/// touches the filesystem: relative, only normal components, no segment starting with `.`
/// (which covers `..`, `.obsidian/` and dot files alike), not under `_to-purge/`, and a
/// `.md` file. Returns the normalised form (`/` separators, no empty segments).
pub fn safe_rel(rel: &str) -> Option<String> {
    let rel = rel.trim();
    if rel.is_empty() || rel.contains('\0') || rel.contains('\\') {
        return None;
    }
    if Path::new(rel).is_absolute() || rel.starts_with('/') {
        return None;
    }
    let segments: Vec<&str> = rel.split('/').filter(|s| !s.is_empty()).collect();
    if segments.is_empty() {
        return None;
    }
    for seg in &segments {
        if seg.starts_with('.') || seg.chars().any(|c| c.is_control()) {
            return None;
        }
    }
    if segments[0].eq_ignore_ascii_case(PURGE_DIR) {
        return None;
    }
    let last = segments[segments.len() - 1];
    if !last.ends_with(".md") || last.len() <= 3 {
        return None;
    }
    Some(segments.join("/"))
}

/// The path of `canonical` relative to the canonical notes root, if it sits under it.
fn relative_to_root(root: &Path, canonical: &Path) -> Option<String> {
    let root = std::fs::canonicalize(root).ok()?;
    let rel = canonical.strip_prefix(&root).ok()?;
    let parts: Vec<String> = rel
        .components()
        .map(|c| match c {
            std::path::Component::Normal(s) => s.to_str().map(str::to_string),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()?;
    Some(parts.join("/"))
}

/// An EXISTING note at vault relative `rel`, confined to the notes root: the canonical
/// absolute path and the canonical relative path, or `None`.
///
/// The relative path is re-derived from the canonical one and put through [`safe_rel`]
/// AGAIN, so a symlink inside the vault that points at `.obsidian/workspace.md`, at
/// `_to-purge/`, or at a non-markdown file is refused exactly as naming it directly would be.
pub fn resolve_note(root: &Path, rel: &str) -> Option<(PathBuf, String)> {
    let rel = safe_rel(rel)?;
    let canonical = crate::todaydetail::resolve_under_root(root, &rel)?;
    let canonical_rel = safe_rel(&relative_to_root(root, &canonical)?)?;
    Some((canonical, canonical_rel))
}

/// A note by wiki target, through the one resolver the item detail route uses, and then
/// through the same rules a path gets.
pub fn resolve_note_target(root: &Path, target: &str) -> Option<(PathBuf, String)> {
    let found = crate::todaydetail::resolve_target(root, target)?;
    let rel = relative_to_root(root, &found)?;
    resolve_note(root, &rel)
}

/// One note, read.
#[derive(Debug, Clone, PartialEq)]
pub struct NoteRead {
    pub path: String,
    pub markdown: String,
    pub modified: String,
    pub sha256: String,
    pub truncated: bool,
}

/// Hash the whole file and keep at most [`NOTE_MAX_BYTES`] of it.
///
/// The hash is over EVERY byte, streamed, because it is what the device compares its own
/// copy against, and a hash of a prefix would call a note current that differs past the
/// cut. Only the prefix is held in memory.
pub fn read_note(canonical: &Path, rel: &str) -> std::io::Result<NoteRead> {
    let mut file = std::fs::File::open(canonical)?;
    let mut ctx = ring::digest::Context::new(&ring::digest::SHA256);
    let mut kept: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 64 * 1024];
    let mut total = 0usize;
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
        total += n;
        if kept.len() <= NOTE_MAX_BYTES {
            let room = NOTE_MAX_BYTES + 1 - kept.len();
            kept.extend_from_slice(&buf[..n.min(room)]);
        }
    }
    let truncated = total > NOTE_MAX_BYTES;
    let text = String::from_utf8_lossy(&kept).into_owned();
    let markdown = if truncated {
        truncate_bytes_on_char_boundary(&text, NOTE_MAX_BYTES).to_string()
    } else {
        text
    };
    let modified = std::fs::metadata(canonical)
        .and_then(|m| m.modified())
        .map(rfc3339_utc)
        .unwrap_or_default();
    Ok(NoteRead {
        path: rel.to_string(),
        markdown,
        modified,
        sha256: hex(ctx.finish().as_ref()),
        truncated,
    })
}

/// Lowercase hex.
pub fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

/// The ETag for a note: its sha256, quoted, so `If-None-Match` carries the device's own
/// hash of its copy and nothing else.
pub fn note_etag(sha256: &str) -> String {
    format!("\"{sha256}\"")
}

#[derive(serde::Deserialize, Default)]
pub struct NoteQuery {
    pub path: Option<String>,
    pub target: Option<String>,
}

/// The JSON error body every refusal and miss carries.
fn error_response(status: StatusCode, error: &str, message: &str) -> Response {
    (
        status,
        [(
            axum::http::header::CONTENT_TYPE,
            "application/json".to_string(),
        )],
        serde_json::to_string(&json!({ "error": error, "message": message })).unwrap_or_default(),
    )
        .into_response()
}

/// What a query resolves to, before any response is built: pure over the filesystem, so
/// the tests drive every branch without a router.
#[derive(Debug, PartialEq)]
pub enum NoteLookup {
    Found(NoteRead),
    NotFound,
    Refused(&'static str),
}

pub fn lookup(root: &Path, query: &NoteQuery) -> NoteLookup {
    let path = query
        .path
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let target = query
        .target
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let resolved = match (path, target) {
        (Some(_), Some(_)) | (None, None) => {
            return NoteLookup::Refused("exactly one of path or target")
        }
        (Some(path), None) => {
            if safe_rel(path).is_none() {
                return NoteLookup::Refused("not a note this route serves");
            }
            resolve_note(root, path)
        }
        (None, Some(target)) => resolve_note_target(root, target),
    };
    match resolved.and_then(|(canonical, rel)| read_note(&canonical, &rel).ok()) {
        Some(read) => NoteLookup::Found(read),
        None => NoteLookup::NotFound,
    }
}

/// `GET /jesse/vault/note?path=…` or `?target=…`.
pub async fn jesse_vault_note(
    State(st): State<AppState>,
    Query(query): Query<NoteQuery>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }
    let read = match lookup(&notes_root(&st.cfg), &query) {
        NoteLookup::Found(read) => read,
        NoteLookup::NotFound => {
            return Ok(error_response(
                StatusCode::NOT_FOUND,
                NOTE_NOT_FOUND,
                "no such note on the Studio",
            ))
        }
        NoteLookup::Refused(why) => {
            return Ok(error_response(StatusCode::BAD_REQUEST, "refused", why))
        }
    };
    let etag = note_etag(&read.sha256);
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
    let body = json!({
        "path": read.path,
        "markdown": read.markdown,
        "modified": read.modified,
        "sha256": read.sha256,
        "truncated": read.truncated,
    });
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
pub(crate) mod tests {
    use super::*;
    use tower::ServiceExt as _;

    /// A synthetic notes root under the temp dir. Invented content only.
    pub(crate) struct Vault {
        pub(crate) root: PathBuf,
    }

    impl Vault {
        pub(crate) fn new(name: &str) -> Self {
            let root =
                std::env::temp_dir().join(format!("jesse-vaultnotes-{name}-{}", random_hex()));
            std::fs::create_dir_all(root.join(config::VAULT_SUBDIR)).unwrap();
            Self { root }
        }

        pub(crate) fn notes(&self) -> PathBuf {
            self.root.join(config::VAULT_SUBDIR)
        }

        pub(crate) fn write(&self, rel: &str, body: &str) -> PathBuf {
            let path = self.notes().join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, body).unwrap();
            path
        }

        pub(crate) fn read(&self, rel: &str) -> String {
            std::fs::read_to_string(self.notes().join(rel)).unwrap()
        }

        pub(crate) fn cfg(&self) -> Config {
            Config {
                vault: self.root.to_string_lossy().into_owned(),
                token: "t0ken".to_string(),
                ..testutil::test_config()
            }
        }
    }

    impl Drop for Vault {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn by_path(p: &str) -> NoteQuery {
        NoteQuery {
            path: Some(p.to_string()),
            target: None,
        }
    }

    fn by_target(t: &str) -> NoteQuery {
        NoteQuery {
            path: None,
            target: Some(t.to_string()),
        }
    }

    #[test]
    fn a_path_is_served_with_the_hash_of_its_bytes() {
        let v = Vault::new("path");
        v.write("Strands/Family.md", "# Family\n\n- [ ] **P1** Kits.\n");
        let NoteLookup::Found(read) = lookup(&v.notes(), &by_path("Strands/Family.md")) else {
            panic!("expected the note")
        };
        assert_eq!(read.path, "Strands/Family.md");
        assert_eq!(read.markdown, "# Family\n\n- [ ] **P1** Kits.\n");
        assert_eq!(
            read.sha256,
            crate::artifacts::sha256_hex(b"# Family\n\n- [ ] **P1** Kits.\n")
        );
        assert!(!read.truncated);
        assert!(read.modified.ends_with('Z'), "{}", read.modified);
    }

    #[test]
    fn a_target_resolves_through_the_detail_resolver() {
        let v = Vault::new("target");
        v.write("Projects/Demo.md", "demo\n");
        v.write("Projects/Folder/Folder.md", "folder note\n");
        for (target, path) in [
            ("todo-list/Projects/Demo", "Projects/Demo.md"),
            ("Projects/Demo#Heading|alias", "Projects/Demo.md"),
            ("vault/Projects/Demo", "Projects/Demo.md"),
            ("Projects/Folder", "Projects/Folder/Folder.md"),
        ] {
            let NoteLookup::Found(read) = lookup(&v.notes(), &by_target(target)) else {
                panic!("{target} should resolve")
            };
            assert_eq!(read.path, path, "{target}");
        }
    }

    #[test]
    fn a_missing_note_is_not_found_and_a_bad_query_is_refused() {
        let v = Vault::new("missing");
        assert_eq!(
            lookup(&v.notes(), &by_path("Projects/Nope.md")),
            NoteLookup::NotFound
        );
        assert_eq!(
            lookup(&v.notes(), &by_target("Projects/Nope")),
            NoteLookup::NotFound
        );
        assert!(matches!(
            lookup(&v.notes(), &NoteQuery::default()),
            NoteLookup::Refused(_)
        ));
        let both = NoteQuery {
            path: Some("A.md".into()),
            target: Some("A".into()),
        };
        assert!(matches!(lookup(&v.notes(), &both), NoteLookup::Refused(_)));
    }

    #[test]
    fn a_note_over_the_cap_is_cut_but_hashed_whole() {
        let v = Vault::new("cap");
        let big = "é".repeat(NOTE_MAX_BYTES); // two bytes each: twice the cap
        v.write("Big.md", &big);
        let NoteLookup::Found(read) = lookup(&v.notes(), &by_path("Big.md")) else {
            panic!("expected the note")
        };
        assert!(read.truncated);
        assert!(read.markdown.len() <= NOTE_MAX_BYTES);
        assert!(read.markdown.len() >= NOTE_MAX_BYTES - 1);
        assert_eq!(read.sha256, crate::artifacts::sha256_hex(big.as_bytes()));
    }

    #[test]
    fn every_unsafe_path_is_refused() {
        let v = Vault::new("rules");
        v.write("Projects/A.md", "a\n");
        v.write(".obsidian/workspace.md", "hidden\n");
        v.write("Projects/.hidden.md", "hidden\n");
        v.write("_to-purge/Old.md", "junk\n");
        v.write("Projects/data.json", "{}\n");
        // A file outside the notes root, and a link to it from inside.
        let outside = v.root.join("secret.md");
        std::fs::write(&outside, "secret\n").unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&outside, v.notes().join("Projects/Escape.md")).unwrap();
            std::os::unix::fs::symlink(
                v.notes().join(".obsidian/workspace.md"),
                v.notes().join("Projects/Sneak.md"),
            )
            .unwrap();
        }
        for bad in [
            "../secret.md",
            "Projects/../../secret.md",
            "/etc/passwd.md",
            &outside.to_string_lossy(),
            ".obsidian/workspace.md",
            "Projects/.hidden.md",
            "_to-purge/Old.md",
            "Projects/data.json",
            "Projects",
            "",
        ] {
            assert!(
                resolve_note(&v.notes(), bad).is_none(),
                "{bad:?} must be refused"
            );
            assert!(
                !matches!(lookup(&v.notes(), &by_path(bad)), NoteLookup::Found(_)),
                "{bad:?} must never be served"
            );
        }
        #[cfg(unix)]
        {
            assert!(resolve_note(&v.notes(), "Projects/Escape.md").is_none());
            assert!(resolve_note(&v.notes(), "Projects/Sneak.md").is_none());
        }
        assert!(resolve_note(&v.notes(), "Projects/A.md").is_some());
        // A target cannot reach what a path cannot.
        assert_eq!(
            lookup(&v.notes(), &by_target("_to-purge/Old")),
            NoteLookup::NotFound
        );
        assert_eq!(
            lookup(&v.notes(), &by_target(".obsidian/workspace")),
            NoteLookup::NotFound
        );
    }

    async fn get(
        app: axum::Router,
        uri: &str,
        inm: Option<&str>,
    ) -> (StatusCode, HeaderMap, Value) {
        let mut req = axum::http::Request::builder()
            .uri(uri)
            .header("authorization", "Bearer t0ken");
        if let Some(tag) = inm {
            req = req.header("if-none-match", tag);
        }
        let resp = app
            .oneshot(req.body(axum::body::Body::empty()).unwrap())
            .await
            .unwrap();
        let status = resp.status();
        let headers = resp.headers().clone();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let body = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, headers, body)
    }

    #[tokio::test]
    async fn the_route_serves_304s_and_typed_404s() {
        let v = Vault::new("route");
        v.write("Strands/Family.md", "family\n");
        let app = crate::app(AppState::new(v.cfg()));

        let (status, headers, body) = get(
            app.clone(),
            "/jesse/vault/note?path=Strands/Family.md",
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let sha = body["sha256"].as_str().unwrap().to_string();
        assert_eq!(headers["etag"], note_etag(&sha).as_str());
        assert_eq!(body["path"], "Strands/Family.md");
        assert_eq!(body["markdown"], "family\n");
        assert_eq!(body["truncated"], false);

        let (status, _, _) = get(
            app.clone(),
            "/jesse/vault/note?target=todo-list/Strands/Family",
            Some(&note_etag(&sha)),
        )
        .await;
        assert_eq!(status, StatusCode::NOT_MODIFIED);

        let (status, _, body) =
            get(app.clone(), "/jesse/vault/note?path=Strands/Gone.md", None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(body["error"], NOTE_NOT_FOUND);

        let (status, _, body) = get(app.clone(), "/jesse/vault/note?path=../x.md", None).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(body["error"], "refused");

        // Same bearer auth as every other route.
        let resp = app
            .oneshot(
                axum::http::Request::builder()
                    .uri("/jesse/vault/note?path=Strands/Family.md")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }
}
