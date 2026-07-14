use crate::*;

// ---- GET /jesse/sessions — the session list --------------------------------
//
// Threads are Claude Code sessions. Each session's transcript is one jsonl file
// under `~/.claude/projects/<escaped-vault-path>/<session_id>.jsonl`, where the
// filename stem IS the session_id. This endpoint enumerates those files for the
// bridge's vault, newest first by mtime, with the first user turn as a snippet and
// the stored title (if any). Read-only: it never writes a session file.

/// How many bytes of a session jsonl to scan for the first user turn. A real
/// first user turn sits at the top of the file, so a bounded prefix suffices — we
/// never read a multi-MB transcript to find it.
pub const SESSION_SCAN_BYTES: u64 = 64 * 1024;

/// The first-message snippet is truncated to this many CHARS on a char boundary.
pub const FIRST_MESSAGE_CHARS: usize = 120;

/// Escape an absolute working-directory path into the directory name Claude Code
/// uses under `~/.claude/projects/`.
///
/// VERIFIED against `claude 2.1.208` (2026-07-14) by creating a session in a
/// controlled cwd and matching the created dir: **every character that is not
/// ASCII-alphanumeric is replaced with `-`** — so `/`, `.`, and `_` all become
/// `-`, an existing `-` is kept, and runs are NOT collapsed (`/.claude` → `--claude`).
/// e.g. `/Users/u/devel/tag1/jesse-app` → `-Users-u-devel-tag1-jesse-app` and
/// `/private/tmp/jt_esc.mix-dir` → `-private-tmp-jt-esc-mix-dir`. (An older CLI
/// preserved `_`; the current one does not — this matches the current CLI.)
pub fn escape_project_path(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// The `~/.claude/projects/<escaped-vault>` directory a vault's session jsonl
/// files live in. `home` is the bridge user's HOME (the projects dir is under the
/// user running the bridge, not under the vault).
pub fn vault_sessions_dir(home: &str, vault: &str) -> PathBuf {
    PathBuf::from(home)
        .join(".claude")
        .join("projects")
        .join(escape_project_path(vault))
}

/// One session summary in the response, newest-first ordered by the caller.
#[derive(serde::Serialize, PartialEq, Debug)]
pub struct SessionSummary {
    pub session_id: String,
    pub last_modified: u64,
    pub first_message: Option<String>,
    pub title: Option<String>,
}

/// Pull the user text out of a `{"type":"user","message":{...}}` transcript line.
/// Handles both shapes seen in real transcripts: `message.content` as a plain
/// string, and as an array of content blocks (the `text` of each `{"type":"text"}`
/// block, joined). Returns `None` for a non-user line or one with no text.
pub fn extract_user_text(v: &Value) -> Option<String> {
    if v.get("type").and_then(|t| t.as_str()) != Some("user") {
        return None;
    }
    let content = v.get("message")?.get("content")?;
    match content {
        Value::String(s) => Some(s.clone()),
        Value::Array(blocks) => {
            let mut parts = Vec::new();
            for b in blocks {
                if b.get("type").and_then(|t| t.as_str()) == Some("text") {
                    if let Some(t) = b.get("text").and_then(|t| t.as_str()) {
                        parts.push(t);
                    }
                }
            }
            (!parts.is_empty()).then(|| parts.join("\n"))
        }
        _ => None,
    }
}

/// Read a bounded prefix of a session jsonl and return the text of its first user
/// turn, truncated to `FIRST_MESSAGE_CHARS` chars on a char boundary. `None` when
/// no user turn with text is found within the prefix, or the file can't be read —
/// never an error (such a session just shows `first_message: null`). Unparseable
/// lines are skipped.
pub fn first_user_message(path: &Path) -> Option<String> {
    use std::io::Read;
    let file = std::fs::File::open(path).ok()?;
    let mut buf = Vec::new();
    file.take(SESSION_SCAN_BYTES).read_to_end(&mut buf).ok()?;
    let text = String::from_utf8_lossy(&buf);
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue; // skip an unparseable (or trailing partial) line
        };
        if let Some(t) = extract_user_text(&v) {
            let t = t.trim();
            if !t.is_empty() {
                return Some(truncate_chars(t, FIRST_MESSAGE_CHARS));
            }
        }
    }
    None
}

/// Enumerate the session jsonl files in `dir`, newest first by mtime, filling each
/// summary's `first_message` and `title`. Robust by contract:
/// - a missing/unreadable `dir` → an empty list (the bridge may run before any
///   session exists), never an error;
/// - only `*.jsonl` regular files directly in `dir` are considered — subdirs and
///   other files are ignored;
/// - a filename stem that isn't a plain component (empty, `.`/`..`, or containing a
///   path separator) is skipped defensively, so a listing can never reach outside
///   `dir`;
/// - `since` (unix seconds), when set, keeps only sessions with mtime STRICTLY
///   greater — the delta-poll filter.
pub fn list_sessions(dir: &Path, since: Option<u64>, titles: &TitleStore) -> Vec<SessionSummary> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        // Defensive: the stem must be a plain filename component. It comes from a
        // directory listing (so this is belt-and-suspenders), but a name that could
        // escape the dir must never become a session_id.
        if stem.is_empty()
            || stem == "."
            || stem == ".."
            || stem.contains('/')
            || stem.contains('\\')
        {
            continue;
        }
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if let Some(s) = since {
            if mtime <= s {
                continue;
            }
        }
        out.push(SessionSummary {
            session_id: stem.to_string(),
            last_modified: mtime,
            first_message: first_user_message(&path),
            title: titles.get(stem),
        });
    }
    // Newest first; break ties on session_id for a stable, deterministic order
    // (so the ETag is stable across calls with unchanged inputs).
    out.sort_by(|a, b| {
        b.last_modified
            .cmp(&a.last_modified)
            .then_with(|| a.session_id.cmp(&b.session_id))
    });
    out
}

/// Compute a strong ETag over the serialized response body: a quoted lowercase hex
/// SHA-256. Strong (no `W/` prefix) because it's an exact hash of the exact bytes.
pub fn strong_etag(body: &str) -> String {
    let digest = ring::digest::digest(&ring::digest::SHA256, body.as_bytes());
    let mut hex = String::with_capacity(2 + digest.as_ref().len() * 2);
    hex.push('"');
    for b in digest.as_ref() {
        hex.push_str(&format!("{b:02x}"));
    }
    hex.push('"');
    hex
}

/// Whether an `If-None-Match` header value matches our ETag. Honors the `*`
/// wildcard and a comma-separated list of candidates (RFC 7232).
pub fn if_none_match_matches(header: &str, etag: &str) -> bool {
    header
        .split(',')
        .map(str::trim)
        .any(|candidate| candidate == "*" || candidate == etag)
}

/// Query params for `GET /jesse/sessions`.
#[derive(Deserialize)]
pub struct SessionsQuery {
    /// Only sessions with mtime strictly greater than this (unix seconds).
    #[serde(default)]
    pub since: Option<u64>,
}

/// `GET /jesse/sessions` — list the vault's Claude Code sessions, newest first.
/// Same bearer auth and rate limiter as `/jesse`. `?since=<unix seconds>` returns
/// only sessions modified after that. Honors `If-None-Match` with a strong ETag
/// over the body (`304 Not Modified`, empty body, when it matches). A missing
/// projects dir yields an empty list, not an error.
pub async fn jesse_sessions(
    State(st): State<AppState>,
    headers: HeaderMap,
    Query(params): Query<SessionsQuery>,
) -> Result<Response, ApiError> {
    check_auth(&headers, &st.cfg.token)?;
    if !st.limiter.allow() {
        return Err((
            StatusCode::TOO_MANY_REQUESTS,
            "rate limit exceeded".to_string(),
        ));
    }

    let dir = st.sessions_dir();
    let sessions = list_sessions(&dir, params.since, &st.titles);
    let body = serde_json::to_string(&json!({ "sessions": sessions }))
        .unwrap_or_else(|_| r#"{"sessions":[]}"#.to_string());
    let etag = strong_etag(&body);

    // If-None-Match → 304 with the ETag and no body.
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

    Ok((
        StatusCode::OK,
        [
            (axum::http::header::ETAG, etag),
            (
                axum::http::header::CONTENT_TYPE,
                "application/json".to_string(),
            ),
        ],
        body,
    )
        .into_response())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escape_matches_the_verified_convention() {
        // Pinned against the real dirs verified on this machine (claude 2.1.208):
        // every non-alphanumeric char → '-', existing '-' kept, no run-collapsing.
        assert_eq!(
            escape_project_path("/Users/u/devel/tag1/jesse-app"),
            "-Users-u-devel-tag1-jesse-app"
        );
        // '_' and '.' both map to '-'.
        assert_eq!(
            escape_project_path("/private/tmp/jt_esc.mix-dir"),
            "-private-tmp-jt-esc-mix-dir"
        );
        // '/.' becomes '--' (no collapsing).
        assert_eq!(escape_project_path("/a/.claude/x"), "-a--claude-x");
    }

    #[test]
    fn vault_sessions_dir_joins_home_projects_and_escaped_vault() {
        let d = vault_sessions_dir("/home/bob", "/vault/notes");
        assert_eq!(d, PathBuf::from("/home/bob/.claude/projects/-vault-notes"));
    }

    #[test]
    fn extract_user_text_handles_string_and_block_array() {
        // Plain string content.
        let v: Value =
            serde_json::from_str(r#"{"type":"user","message":{"content":"hello there"}}"#).unwrap();
        assert_eq!(extract_user_text(&v).as_deref(), Some("hello there"));

        // Array-of-blocks content: join text blocks, ignore non-text blocks.
        let v: Value = serde_json::from_str(
            r#"{"type":"user","message":{"content":[
                 {"type":"text","text":"first"},
                 {"type":"tool_result","content":"noise"},
                 {"type":"text","text":"second"}]}}"#,
        )
        .unwrap();
        assert_eq!(extract_user_text(&v).as_deref(), Some("first\nsecond"));

        // A non-user line yields None.
        let v: Value =
            serde_json::from_str(r#"{"type":"assistant","message":{"content":"hi"}}"#).unwrap();
        assert_eq!(extract_user_text(&v), None);

        // A user line with only non-text blocks yields None.
        let v: Value = serde_json::from_str(
            r#"{"type":"user","message":{"content":[{"type":"image","source":{}}]}}"#,
        )
        .unwrap();
        assert_eq!(extract_user_text(&v), None);
    }

    fn temp_dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!("jesse-sessions-{}", random_hex()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn write(dir: &Path, name: &str, contents: &str) {
        std::fs::write(dir.join(name), contents).unwrap();
    }

    #[test]
    fn missing_dir_lists_empty_not_error() {
        let missing = std::env::temp_dir().join(format!("jesse-nope-{}", random_hex()));
        let titles = TitleStore::new(None);
        assert!(list_sessions(&missing, None, &titles).is_empty());
    }

    #[test]
    fn first_user_message_reads_first_user_turn_only() {
        let dir = temp_dir();
        // A system line, then two user turns — the FIRST user turn is the snippet.
        let jsonl = concat!(
            r#"{"type":"system","subtype":"init","cwd":"/v"}"#,
            "\n",
            r#"{"type":"user","message":{"content":"the very first question"}}"#,
            "\n",
            r#"not valid json — must be skipped"#,
            "\n",
            r#"{"type":"user","message":{"content":"a later turn"}}"#,
            "\n",
        );
        write(&dir, "sess-1.jsonl", jsonl);
        let got = first_user_message(&dir.join("sess-1.jsonl"));
        assert_eq!(got.as_deref(), Some("the very first question"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn first_message_truncates_on_char_boundary_at_120() {
        let dir = temp_dir();
        let long = "é".repeat(200); // multibyte, well over 120 chars
        let line = format!(r#"{{"type":"user","message":{{"content":"{long}"}}}}"#);
        write(&dir, "s.jsonl", &format!("{line}\n"));
        let got = first_user_message(&dir.join("s.jsonl")).unwrap();
        assert_eq!(got.chars().count(), FIRST_MESSAGE_CHARS);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn no_user_turn_within_bound_is_null_not_error() {
        let dir = temp_dir();
        // Only non-user lines → first_message None, never an error.
        write(
            &dir,
            "s.jsonl",
            "{\"type\":\"system\"}\n{\"type\":\"assistant\",\"message\":{\"content\":\"hi\"}}\n",
        );
        assert_eq!(first_user_message(&dir.join("s.jsonl")), None);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn list_orders_newest_first_fills_titles_and_honors_since() {
        let dir = temp_dir();
        // Three sessions. Set distinct mtimes via filetime-free approach: write in
        // order and then bump mtimes explicitly.
        for (name, content) in [
            (
                "old.jsonl",
                r#"{"type":"user","message":{"content":"old q"}}"#,
            ),
            (
                "mid.jsonl",
                r#"{"type":"user","message":{"content":"mid q"}}"#,
            ),
            (
                "new.jsonl",
                r#"{"type":"user","message":{"content":"new q"}}"#,
            ),
        ] {
            write(&dir, name, &format!("{content}\n"));
        }
        // Also a non-jsonl file and a subdir — both must be ignored.
        write(&dir, "notes.txt", "ignore me");
        std::fs::create_dir_all(dir.join("subdir.jsonl")).unwrap();

        // Force a strict mtime ordering old < mid < new.
        set_mtime(&dir.join("old.jsonl"), 1_000);
        set_mtime(&dir.join("mid.jsonl"), 2_000);
        set_mtime(&dir.join("new.jsonl"), 3_000);

        let titles = TitleStore::new(None);
        titles.set("mid", "Middle Session");

        let all = list_sessions(&dir, None, &titles);
        let ids: Vec<&str> = all.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(
            ids,
            ["new", "mid", "old"],
            "newest first, non-jsonl/subdir ignored"
        );
        // Titles filled from the store; absent ones are null.
        let mid = all.iter().find(|s| s.session_id == "mid").unwrap();
        assert_eq!(mid.title.as_deref(), Some("Middle Session"));
        assert_eq!(mid.first_message.as_deref(), Some("mid q"));
        assert!(all
            .iter()
            .find(|s| s.session_id == "new")
            .unwrap()
            .title
            .is_none());

        // ?since strictly greater: since=2000 keeps only "new" (mtime 3000).
        let delta = list_sessions(&dir, Some(2_000), &titles);
        let ids: Vec<&str> = delta.iter().map(|s| s.session_id.as_str()).collect();
        assert_eq!(ids, ["new"], "since is strictly greater-than");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn etag_is_stable_and_input_sensitive() {
        let a = strong_etag(r#"{"sessions":[]}"#);
        let b = strong_etag(r#"{"sessions":[]}"#);
        let c = strong_etag(r#"{"sessions":[{"session_id":"x"}]}"#);
        assert_eq!(a, b, "same body → same strong ETag");
        assert_ne!(a, c, "different body → different ETag");
        assert!(
            a.starts_with('"') && a.ends_with('"'),
            "strong ETag is quoted"
        );
        assert!(!a.starts_with("W/"), "strong, not weak");
    }

    #[test]
    fn if_none_match_honors_exact_and_wildcard() {
        let tag = strong_etag("body");
        assert!(if_none_match_matches(&tag, &tag));
        assert!(if_none_match_matches("*", &tag));
        assert!(if_none_match_matches(&format!("\"other\", {tag}"), &tag));
        assert!(!if_none_match_matches("\"nope\"", &tag));
    }

    /// Set a file's mtime to exactly `secs` since the unix epoch, dependency-free,
    /// via `std::fs::File::set_modified` — so the `since` filter and `last_modified`
    /// field can be asserted against known values.
    fn set_mtime(path: &Path, secs: u64) {
        let f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
        f.set_modified(UNIX_EPOCH + Duration::from_secs(secs))
            .unwrap();
    }
}
