//! **A fixture tool set** — three filesystem tools over one directory, so a real multi-step
//! turn can be run end to end without a vault.
//!
//! **THIS IS A TEST FIXTURE. D3 REPLACES IT WITH THE REAL VAULT TOOL SET BEHIND THE SAME
//! TRAIT.** It is in the library rather than in `tests/` because the CLI (`src/bin/`) needs
//! it to prove a turn by hand, and a binary cannot reach an integration test's helpers.
//!
//! What it is for is the loop, not the filesystem: `fs_list`, `fs_read` and `fs_write` are
//! the smallest set that makes a genuine three-step turn possible (find something, read it,
//! answer) and that spans two [`ActionClass`]es, so "a write tool is absent at `Level::Read`"
//! is a claim with something to be true about.
//!
//! ---- THE JAIL ---------------------------------------------------------------
//!
//! Every path argument is resolved against the root and refused if it lands outside, and
//! the resolution is done with [`std::fs::canonicalize`] — which follows symlinks — rather
//! than by string manipulation. That order is the whole point:
//!
//!   * A `..` component is refused BEFORE resolution, on the raw argument. Refusing it
//!     first means the error names what the model actually asked for.
//!   * The resolved path is then checked to be under the resolved root. This is the check
//!     that catches a symlink inside the root pointing out of it, which no amount of string
//!     inspection can see. A jail built on `path.starts_with(root)` over unresolved paths is
//!     the classic hole: `root/link-to-etc/passwd` starts with the root and is `/etc/passwd`.
//!   * For a write, the PARENT is resolved (the file may not exist yet) and the final
//!     component is required to be a plain name. Resolving the parent is what stops
//!     `link-to-etc/passwd` being created through a symlinked directory.
//!
//! A jail violation is [`ToolError::Refused`], never `Failed`: the boundary worked.

use std::path::{Component, Path, PathBuf};

use serde_json::{json, Value};

use crate::provider::BoxFuture;
use crate::scope::Scope;
use crate::tools::{
    ActionClass, ExposedClass, Level, ResultBlock, StaticToolSet, Tool, ToolContext, ToolError,
    ToolOk, ToolResult, ToolSetBuilder, ToolSetError,
};

/// Cap on what `fs_read` returns, in bytes. Below the framing layer's own cap so a normal
/// read is never truncated twice, and low enough that a fixture cannot be used to pull a
/// large file into a prompt by accident.
pub const FIXTURE_READ_MAX_BYTES: usize = 16_000;

/// Cap on how many entries `fs_list` returns.
pub const FIXTURE_LIST_MAX_ENTRIES: usize = 500;

/// Build the fixture tool set over `root`, at `level`.
///
/// The three tools are added at every level and the level decides which survive — see
/// [`ToolSetBuilder::build`]. That is the arrangement being demonstrated: one definition,
/// several postures, and the posture applied once at construction.
pub fn fixture_tool_set(root: impl Into<PathBuf>, level: Level) -> Result<StaticToolSet, String> {
    let root = root.into();
    let root =
        std::fs::canonicalize(&root).map_err(|e| format!("tool root {}: {e}", root.display()))?;
    if !root.is_dir() {
        return Err(format!("tool root {} is not a directory", root.display()));
    }
    ToolSetBuilder::new(level)
        .add(
            ExposedClass::Read,
            std::sync::Arc::new(FsList { root: root.clone() }),
        )
        .add(
            ExposedClass::Read,
            std::sync::Arc::new(FsRead { root: root.clone() }),
        )
        .add(
            ExposedClass::VaultWrite,
            std::sync::Arc::new(FsWrite { root }),
        )
        .build()
        .map_err(|e: ToolSetError| e.to_string())
}

// ===========================================================================
// The jail
// ===========================================================================

/// Resolve a model-supplied relative path against the root, refusing anything that escapes.
///
/// `require_existing` distinguishes a read (the file must be there) from a write (its
/// parent must be).
fn resolve(root: &Path, raw: &str, require_existing: bool) -> Result<PathBuf, ToolError> {
    if raw.is_empty() {
        return Err(ToolError::InvalidArgs("path is empty".into()));
    }
    let candidate = Path::new(raw);
    if candidate.is_absolute() {
        return Err(ToolError::Refused(format!(
            "path must be relative to the tool root: {raw:?}"
        )));
    }
    for component in candidate.components() {
        match component {
            Component::Normal(_) | Component::CurDir => {}
            // `..` is refused on the RAW argument, before any resolution, so the message
            // names what was asked rather than where it would have landed.
            Component::ParentDir => {
                return Err(ToolError::Refused(format!(
                    "path may not contain `..`: {raw:?}"
                )))
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(ToolError::Refused(format!(
                    "path must be relative to the tool root: {raw:?}"
                )))
            }
        }
    }

    let joined = root.join(candidate);
    let resolved = if require_existing {
        std::fs::canonicalize(&joined).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => ToolError::NotFound,
            _ => ToolError::Failed(format!("cannot resolve {raw:?}: {e}")),
        })?
    } else {
        // A write: the file may not exist, so the PARENT is what gets resolved — which is
        // what closes the symlinked-directory case.
        let parent = joined.parent().unwrap_or(root);
        let name = joined
            .file_name()
            .ok_or_else(|| ToolError::InvalidArgs(format!("{raw:?} names no file")))?;
        let parent = std::fs::canonicalize(parent).map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => ToolError::NotFound,
            _ => ToolError::Failed(format!("cannot resolve the parent of {raw:?}: {e}")),
        })?;
        parent.join(name)
    };

    // The check that actually holds: the RESOLVED path, symlinks and all, is under the
    // RESOLVED root.
    if !resolved.starts_with(root) {
        return Err(ToolError::Refused(format!(
            "path escapes the tool root: {raw:?}"
        )));
    }
    Ok(resolved)
}

/// Pull a required string argument out of the model's object.
fn string_arg(args: &Value, name: &str) -> Result<String, ToolError> {
    match args.get(name) {
        Some(Value::String(s)) => Ok(s.clone()),
        Some(other) => Err(ToolError::InvalidArgs(format!(
            "{name} must be a string, got {}",
            type_name(other)
        ))),
        None => Err(ToolError::InvalidArgs(format!("{name} is required"))),
    }
}

fn type_name(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

// ===========================================================================
// fs_list
// ===========================================================================

/// List a directory under the root.
struct FsList {
    root: PathBuf,
}

impl Tool for FsList {
    fn name(&self) -> &str {
        "fs_list"
    }

    fn description(&self) -> &str {
        "List the files and directories inside a directory of the workspace. \
         `path` is relative to the workspace root; use \".\" for the root itself."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "Directory relative to the workspace root; \".\" for the root."
                }
            },
            "required": ["path"],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::Read
    }

    fn call<'a>(
        &'a self,
        _scope: &'a Scope,
        args: Value,
        _ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let raw = string_arg(&args, "path")?;
            let dir = resolve(&self.root, &raw, true)?;
            let read = std::fs::read_dir(&dir).map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => ToolError::NotFound,
                _ => ToolError::Failed(format!("cannot list {raw:?}: {e}")),
            })?;
            let mut entries: Vec<Value> = Vec::new();
            let mut truncated = false;
            for entry in read {
                let entry = entry.map_err(|e| ToolError::Failed(e.to_string()))?;
                if entries.len() >= FIXTURE_LIST_MAX_ENTRIES {
                    truncated = true;
                    break;
                }
                let meta = entry.metadata().ok();
                entries.push(json!({
                    "name": entry.file_name().to_string_lossy(),
                    "kind": if meta.as_ref().is_some_and(|m| m.is_dir()) { "dir" } else { "file" },
                    "bytes": meta.as_ref().map(|m| m.len()),
                }));
            }
            // Sorted, so the same directory lists identically on two machines. A `read_dir`
            // order is the filesystem's and is not stable across them.
            entries.sort_by_key(|e| e["name"].as_str().unwrap_or_default().to_string());
            Ok(ToolOk {
                content: vec![ResultBlock::Json(json!({
                    "path": raw,
                    "entries": entries,
                    "truncated": truncated,
                }))],
                summary_for_trace: "listed a directory",
            })
        })
    }
}

// ===========================================================================
// fs_read
// ===========================================================================

/// Read a file under the root.
struct FsRead {
    root: PathBuf,
}

impl Tool for FsRead {
    fn name(&self) -> &str {
        "fs_read"
    }

    fn description(&self) -> &str {
        "Read a UTF-8 text file from the workspace. `path` is relative to the workspace root."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File relative to the workspace root."
                }
            },
            "required": ["path"],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::Read
    }

    fn call<'a>(
        &'a self,
        _scope: &'a Scope,
        args: Value,
        _ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let raw = string_arg(&args, "path")?;
            let path = resolve(&self.root, &raw, true)?;
            let bytes = std::fs::read(&path).map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => ToolError::NotFound,
                _ => ToolError::Failed(format!("cannot read {raw:?}: {e}")),
            })?;
            // LOSSY, not an error on invalid UTF-8. A tool that refuses a file because one
            // byte is not valid UTF-8 makes the model retry the same call forever; the
            // replacement character is legible and the failure mode is bounded.
            let text = String::from_utf8_lossy(&bytes);
            let truncated = text.len() > FIXTURE_READ_MAX_BYTES;
            let shown: String = if truncated {
                text.chars()
                    .scan(0usize, |n, c| {
                        *n += c.len_utf8();
                        (*n <= FIXTURE_READ_MAX_BYTES).then_some(c)
                    })
                    .collect()
            } else {
                text.to_string()
            };
            let mut body = shown;
            if truncated {
                body.push_str(&format!(
                    "\n…[fs_read stopped at {FIXTURE_READ_MAX_BYTES} bytes; the file is {} bytes]",
                    bytes.len()
                ));
            }
            Ok(ToolOk {
                content: vec![ResultBlock::Text(body)],
                summary_for_trace: "read a file",
            })
        })
    }
}

// ===========================================================================
// fs_write
// ===========================================================================

/// Write a file under the root.
struct FsWrite {
    root: PathBuf,
}

impl Tool for FsWrite {
    fn name(&self) -> &str {
        "fs_write"
    }

    fn description(&self) -> &str {
        "Write a UTF-8 text file into the workspace, replacing it if it exists. \
         `path` is relative to the workspace root and its directory must already exist."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File relative to the workspace root."
                },
                "content": {
                    "type": "string",
                    "description": "The complete new contents of the file."
                }
            },
            "required": ["path", "content"],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::VaultWrite
    }

    fn call<'a>(
        &'a self,
        _scope: &'a Scope,
        args: Value,
        _ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let raw = string_arg(&args, "path")?;
            let content = string_arg(&args, "content")?;
            let path = resolve(&self.root, &raw, false)?;
            std::fs::write(&path, content.as_bytes())
                .map_err(|e| ToolError::Failed(format!("cannot write {raw:?}: {e}")))?;
            Ok(ToolOk {
                content: vec![ResultBlock::Json(json!({
                    "path": raw,
                    "bytes_written": content.len(),
                }))],
                summary_for_trace: "wrote a file",
            })
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::{SystemClock, ToolSet};
    use std::sync::Arc;
    use tokio_util::sync::CancellationToken;

    fn workspace(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "jesse-agent-fixture-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(root.join("notes")).unwrap();
        std::fs::write(root.join("notes/a.md"), "the answer is 42").unwrap();
        std::fs::write(root.join("README.md"), "hello").unwrap();
        std::fs::canonicalize(&root).unwrap()
    }

    fn ctx() -> ToolContext {
        ToolContext {
            turn_id: "t".into(),
            conversation_id: "c".into(),
            cancel: CancellationToken::new(),
            clock: Arc::new(SystemClock::new()),
        }
    }

    async fn call(set: &StaticToolSet, name: &str, args: Value) -> ToolResult {
        let scope = Scope::new("t", "u", "w");
        set.get(name)
            .unwrap_or_else(|| panic!("{name} is not exposed"))
            .call(&scope, args, &ctx())
            .await
    }

    fn text_of(ok: &ToolOk) -> String {
        ok.content
            .iter()
            .map(|b| match b {
                ResultBlock::Text(t) => t.clone(),
                ResultBlock::Json(v) => v.to_string(),
                ResultBlock::Image { .. } => String::new(),
            })
            .collect()
    }

    #[tokio::test]
    async fn read_and_list_work_and_write_is_absent_at_read_level() {
        let root = workspace("read");
        let set = fixture_tool_set(&root, Level::Read).unwrap();
        let names: Vec<String> = set.manifest().into_iter().map(|t| t.name).collect();
        assert_eq!(names, ["fs_list", "fs_read"]);
        assert!(set.get("fs_write").is_none(), "structurally absent");

        let ok = call(&set, "fs_read", json!({"path": "notes/a.md"}))
            .await
            .unwrap();
        assert_eq!(text_of(&ok), "the answer is 42");

        let ok = call(&set, "fs_list", json!({"path": "."})).await.unwrap();
        let listing = text_of(&ok);
        assert!(listing.contains("README.md") && listing.contains("notes"));
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn write_works_at_write_level() {
        let root = workspace("write");
        let set = fixture_tool_set(&root, Level::Write).unwrap();
        call(
            &set,
            "fs_write",
            json!({"path": "new.md", "content": "written"}),
        )
        .await
        .unwrap();
        assert_eq!(
            std::fs::read_to_string(root.join("new.md")).unwrap(),
            "written"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[tokio::test]
    async fn the_jail_refuses_dot_dot_and_absolute_paths_on_every_tool() {
        let root = workspace("jail");
        let set = fixture_tool_set(&root, Level::Write).unwrap();
        for path in ["../etc/passwd", "notes/../../etc/passwd", "/etc/passwd"] {
            for (tool, args) in [
                ("fs_read", json!({"path": path})),
                ("fs_list", json!({"path": path})),
                ("fs_write", json!({"path": path, "content": "x"})),
            ] {
                match call(&set, tool, args).await {
                    Err(ToolError::Refused(m)) => assert!(m.contains(path)),
                    other => panic!("{tool} on {path:?} must be Refused, got {other:?}"),
                }
            }
        }
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_symlink_out_of_the_root_is_refused_though_its_path_looks_inside() {
        // The case string-only jails get wrong: the path starts with the root and resolves
        // outside it.
        let root = workspace("symlink");
        let outside = root
            .parent()
            .unwrap()
            .join(format!("jesse-agent-outside-{}.txt", std::process::id()));
        std::fs::write(&outside, "secret").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("escape.txt")).unwrap();

        match call(&set_of(&root), "fs_read", json!({"path": "escape.txt"})).await {
            Err(ToolError::Refused(m)) => assert!(m.contains("escapes the tool root")),
            other => panic!("a symlink out of the root must be Refused, got {other:?}"),
        }

        // And a write THROUGH a symlinked directory, which is what resolving the parent
        // rather than the whole path is for.
        std::os::unix::fs::symlink(root.parent().unwrap(), root.join("up")).unwrap();
        match call(
            &set_of(&root),
            "fs_write",
            json!({"path": "up/planted.txt", "content": "x"}),
        )
        .await
        {
            Err(ToolError::Refused(m)) => assert!(m.contains("escapes the tool root")),
            other => panic!("a write through a symlinked dir must be Refused, got {other:?}"),
        }

        std::fs::remove_file(&outside).ok();
        std::fs::remove_dir_all(&root).ok();
    }

    #[cfg(unix)]
    fn set_of(root: &Path) -> StaticToolSet {
        fixture_tool_set(root, Level::Write).unwrap()
    }

    #[tokio::test]
    async fn a_missing_file_is_not_found_and_bad_arguments_are_invalid_args() {
        let root = workspace("errors");
        let set = fixture_tool_set(&root, Level::Read).unwrap();
        assert!(matches!(
            call(&set, "fs_read", json!({"path": "nope.md"})).await,
            Err(ToolError::NotFound)
        ));
        assert!(matches!(
            call(&set, "fs_read", json!({})).await,
            Err(ToolError::InvalidArgs(_))
        ));
        assert!(matches!(
            call(&set, "fs_read", json!({"path": 7})).await,
            Err(ToolError::InvalidArgs(_))
        ));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn every_fixture_schema_survives_the_scope_argument_check() {
        // The check runs at build time; this asserts the fixture is not the thing that
        // would make it fire, so a failure of that test in the future is a new tool's fault.
        let root = workspace("schemas");
        assert!(fixture_tool_set(&root, Level::Write).is_ok());
        std::fs::remove_dir_all(&root).ok();
    }
}
