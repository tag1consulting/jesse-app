//! **The vault tool set** — the typed tools the product's agent has instead of a shell.
//!
//! ---- WHAT REPLACES WHAT ------------------------------------------------------
//!
//! The bridge's CLI child is granted a tool ALLOWLIST (`bridge/src/config.rs`'s
//! `DEFAULT_ALLOWED_TOOLS`) and reaches the vault through general-purpose file and shell
//! verbs. These eight tools are the direct loop's answer, and they are deliberately NOT a
//! reimplementation of that surface: they are the operations the product actually needs,
//! each with a schema, a refusal story and a class the level system understands.
//!
//! The asymmetry is real and is written down rather than glossed — see the report and
//! `README.md`. A shelled child can do many things these cannot; the point of a typed set
//! is that what it CAN do is enumerable, and every one of them is a function a reviewer can
//! read.
//!
//! ---- THE DESCRIPTIONS ARE PART OF THE PRODUCT'S API --------------------------
//!
//! A tool's `description` is the only documentation the model ever reads, and changing it
//! changes behaviour for every user at once with no migration. So each one says three
//! things: what the tool does, **what it refuses**, and that an id is a vault-relative
//! path. The refusals are documented because a model that knows a refusal is possible asks
//! for something else, and a model that does not retries the same call until a budget stops
//! it.
//!
//! ---- SCHEMAS ARE STRICT ------------------------------------------------------
//!
//! Every schema sets `additionalProperties: false`. A model that invents an argument is a
//! model that believes it did something it did not — `vault_read {id, raw: true}` silently
//! ignoring `raw` is worse than refusing it, because the model then reasons about output it
//! thinks is raw.

use std::sync::Arc;

use serde_json::{json, Value};

use crate::index::{SearchIndex, SearchMode, DEFAULT_SEARCH_LIMIT, MAX_SEARCH_LIMIT};
use crate::provider::BoxFuture;
use crate::scope::Scope;
use crate::store::{
    ContentHash, DocumentId, DocumentStore, Guarded, LineRange, ListRequest, StoreError,
    Visibility, WriteGuard, DEFAULT_PAGE_SIZE,
};
use crate::tools::{
    ActionClass, ExposedClass, Level, ResultBlock, StaticToolSet, Tool, ToolContext, ToolError,
    ToolOk, ToolResult, ToolSetBuilder,
};

pub mod fetch;

pub use fetch::{FetchConfig, FetchUrl};

/// Cap on one delivered artifact, in bytes.
pub const ARTIFACT_MAX_BYTES: usize = 4 * 1024 * 1024;

// ===========================================================================
// Shared argument helpers
// ===========================================================================

fn str_arg(args: &Value, name: &str) -> Result<String, ToolError> {
    match args.get(name) {
        Some(Value::String(s)) => Ok(s.clone()),
        Some(other) => Err(ToolError::InvalidArgs(format!(
            "`{name}` must be a string, got {}",
            type_name(other)
        ))),
        None => Err(ToolError::InvalidArgs(format!("`{name}` is required"))),
    }
}

fn opt_str_arg(args: &Value, name: &str) -> Result<Option<String>, ToolError> {
    match args.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(other) => Err(ToolError::InvalidArgs(format!(
            "`{name}` must be a string, got {}",
            type_name(other)
        ))),
    }
}

fn opt_usize_arg(args: &Value, name: &str) -> Result<Option<usize>, ToolError> {
    match args.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(n)) => n
            .as_u64()
            .map(|v| Some(v as usize))
            .ok_or_else(|| ToolError::InvalidArgs(format!("`{name}` must be a whole number >= 0"))),
        Some(other) => Err(ToolError::InvalidArgs(format!(
            "`{name}` must be a number, got {}",
            type_name(other)
        ))),
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

/// Parse an id argument, mapping its refusal onto the right tool error.
///
/// **A TRAVERSAL IS `Refused`, A TYPO IS `InvalidArgs`.** `../outside/x.md` and `/etc/passwd`
/// are the jail holding and belong in the trace's refusal count; an empty id is the model
/// getting the shape wrong and belongs in the failure count. Mapping every parse failure to
/// `InvalidArgs` — which is what this did first — made the battery report a path-traversal
/// attempt as `failed`, so the number that is supposed to mean "the boundary was probed"
/// counted none of them.
fn doc_id(args: &Value, name: &str) -> Result<DocumentId, ToolError> {
    let raw = str_arg(args, name)?;
    DocumentId::parse(&raw).map_err(|e| {
        if e.is_containment() {
            ToolError::Refused(e.to_string())
        } else {
            ToolError::InvalidArgs(e.to_string())
        }
    })
}

/// Map a store error onto a tool error.
///
/// **THE ONE PLACE THE TWO VOCABULARIES MEET**, so the mapping is stated once and cannot
/// drift per tool. `NotFound` stays `NotFound` (which is also what an EXCLUDED document
/// answers — see [`crate::store::StoreError`] for why that is deliberate), `Refused` stays
/// `Refused` so the trace counts it as a boundary holding, and everything else is a failure.
fn map_store_error(e: StoreError) -> ToolError {
    match e {
        StoreError::NotFound => ToolError::NotFound,
        StoreError::Refused(m) => ToolError::Refused(m),
        StoreError::InvalidArgs(m) => ToolError::InvalidArgs(m),
        StoreError::Conflict { .. } => {
            // **A CONFLICT IS A REFUSAL**, not a failure and not bad arguments. The
            // compare-and-swap held: a write that would have overwritten a change the model
            // had not seen did not happen. `ToolError::InvalidArgs` was the first instinct
            // and it is wrong, because `InvalidArgs` traces as `failed` — which would file
            // every prevented blind overwrite under "a tool broke" and understate the one
            // number an operator reads as "the boundary is working".
            ToolError::Refused(e.to_string())
        }
        StoreError::Io(m) => ToolError::Failed(m),
    }
}

/// Everything the vault tools share.
pub struct VaultContext {
    pub store: Arc<dyn DocumentStore>,
    pub index: Arc<dyn SearchIndex>,
    pub guard: Arc<dyn WriteGuard>,
}

impl VaultContext {
    /// The guard bundle for one call.
    fn guarded<'a>(&'a self, ctx: &'a ToolContext) -> Guarded<'a> {
        Guarded::new(
            self.guard.as_ref(),
            &ctx.turn_id,
            &ctx.conversation_id,
            &ctx.call_id,
        )
    }
}

// ===========================================================================
// vault_list
// ===========================================================================

/// List documents.
pub struct VaultList(pub Arc<VaultContext>);

impl Tool for VaultList {
    fn name(&self) -> &str {
        "vault_list"
    }

    fn description(&self) -> &str {
        "List documents in the vault, newest page first. `prefix` restricts to a folder \
         (a vault-relative path, e.g. \"Projects/Diet\"); `depth` limits how many folder \
         levels below it to descend; `page` walks further through a long listing. Results \
         are paged, never complete — follow `next_page` when it is present. Documents \
         marked cold appear with their title and `visibility: \"cold\"` but cannot be read \
         or searched. Folders the operator has excluded do not appear at all."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "prefix": {"type": "string", "description": "Folder, relative to the vault root. Omit for the whole vault."},
                "depth": {"type": "integer", "minimum": 1, "description": "Folder levels below the prefix to descend. Omit for unlimited."},
                "page": {"type": "integer", "minimum": 0, "description": "Zero-based page number; use next_page from a prior call."}
            },
            "required": [],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::Read
    }

    fn call<'a>(
        &'a self,
        scope: &'a Scope,
        args: Value,
        _ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let req = ListRequest {
                prefix: opt_str_arg(&args, "prefix")?,
                depth: opt_usize_arg(&args, "depth")?,
                page: opt_usize_arg(&args, "page")?.unwrap_or(0) as u32,
                page_size: DEFAULT_PAGE_SIZE,
            };
            let page = self
                .0
                .store
                .list(scope, req)
                .await
                .map_err(map_store_error)?;
            let items: Vec<Value> = page
                .items
                .iter()
                .map(|m| {
                    json!({
                        "id": m.id.as_str(),
                        "title": m.title,
                        "kind": m.kind,
                        "bytes": m.size_bytes,
                        "modified": m.modified_at,
                        "visibility": m.visibility.to_string(),
                    })
                })
                .collect();
            Ok(ToolOk {
                content: vec![ResultBlock::Json(json!({
                    "documents": items,
                    "total": page.total,
                    "next_page": page.next_page,
                }))],
                summary_for_trace: "listed documents",
            })
        })
    }
}

// ===========================================================================
// vault_search
// ===========================================================================

/// Search documents.
pub struct VaultSearch(pub Arc<VaultContext>);

impl Tool for VaultSearch {
    fn name(&self) -> &str {
        "vault_search"
    }

    fn description(&self) -> &str {
        "Search the vault and get back matching documents with line snippets. Each hit's \
         `id` is a vault-relative path you can pass to vault_read, and each snippet's \
         `line` can be used as vault_read's from_line. `mode` is \"lexical\" (keywords) or \
         \"hybrid\" (keywords plus meaning); if hybrid is unavailable the results say so \
         and are keyword results. Cold documents and excluded folders never appear in \
         results, so a search finding nothing does not prove the vault has nothing."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "What to search for."},
                "limit": {"type": "integer", "minimum": 1, "maximum": MAX_SEARCH_LIMIT, "description": "Documents to return."},
                "mode": {"type": "string", "enum": ["lexical", "hybrid"], "description": "Search mode."}
            },
            "required": ["query"],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::Read
    }

    fn call<'a>(
        &'a self,
        scope: &'a Scope,
        args: Value,
        _ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let query = str_arg(&args, "query")?;
            if query.trim().is_empty() {
                return Err(ToolError::InvalidArgs("`query` is empty".into()));
            }
            let limit = opt_usize_arg(&args, "limit")?
                .unwrap_or(DEFAULT_SEARCH_LIMIT)
                .clamp(1, MAX_SEARCH_LIMIT);
            let mode = match opt_str_arg(&args, "mode")? {
                Some(m) => m.parse::<SearchMode>().map_err(ToolError::InvalidArgs)?,
                None => SearchMode::Lexical,
            };
            let hits = self
                .0
                .index
                .search(scope, &query, limit, mode)
                .await
                .map_err(map_store_error)?;
            Ok(ToolOk {
                content: vec![ResultBlock::Json(json!({
                    "hits": hits.hits.iter().map(|h| json!({
                        "id": h.id.as_str(),
                        "title": h.title,
                        "score": h.score,
                        "snippets": h.snippets.iter().map(|s| json!({"line": s.line, "text": s.text})).collect::<Vec<_>>(),
                    })).collect::<Vec<_>>(),
                    "served_by": hits.served_by.to_string(),
                    "note": hits.degraded,
                }))],
                summary_for_trace: "searched the vault",
            })
        })
    }
}

// ===========================================================================
// vault_read
// ===========================================================================

/// Read a document.
pub struct VaultRead(pub Arc<VaultContext>);

impl Tool for VaultRead {
    fn name(&self) -> &str {
        "vault_read"
    }

    fn description(&self) -> &str {
        "Read a document. `id` is a vault-relative path, exactly as vault_list and \
         vault_search report it. Use from_line/to_line (1-based, inclusive) for a slice of \
         a long document. The result begins with the document's content_hash — pass that \
         back as expected_hash when you write or edit, so your change cannot silently \
         overwrite someone else's. Refuses a cold document, and reports a document in an \
         excluded folder as not found."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Vault-relative path of the document."},
                "from_line": {"type": "integer", "minimum": 1, "description": "First line to return (1-based)."},
                "to_line": {"type": "integer", "minimum": 1, "description": "Last line to return (1-based, inclusive)."}
            },
            "required": ["id"],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::Read
    }

    fn call<'a>(
        &'a self,
        scope: &'a Scope,
        args: Value,
        ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let id = doc_id(&args, "id")?;
            let range = match (
                opt_usize_arg(&args, "from_line")?,
                opt_usize_arg(&args, "to_line")?,
            ) {
                (None, None) => None,
                // One end given is the other end open, which is what a person means by
                // "from line 40" — refusing it would be pedantry the model has to work
                // around by guessing a large number.
                (Some(f), None) => Some(
                    LineRange::new(f, usize::MAX)
                        .map_err(|e| ToolError::InvalidArgs(e.to_string()))?,
                ),
                (None, Some(t)) => {
                    Some(LineRange::new(1, t).map_err(|e| ToolError::InvalidArgs(e.to_string()))?)
                }
                (Some(f), Some(t)) => {
                    Some(LineRange::new(f, t).map_err(|e| ToolError::InvalidArgs(e.to_string()))?)
                }
            };
            let doc = self
                .0
                .store
                .read(scope, &id, range)
                .await
                .map_err(map_store_error)?;

            // THE READ FEEDS THE COMPARE-AND-SWAP BASELINE. The store cannot do this — it
            // has no conversation id — so the tool layer, which does, is where it happens.
            // Without it, D4's broker would have no record that this conversation had seen
            // the document, and the bridge's own hook would treat the turn's later write as
            // blind.
            self.0
                .guarded(ctx)
                .note_read(std::path::Path::new(id.as_str()), &doc.meta.content_hash);

            // The hash leads the block, so the model meets it before the body rather than
            // after however many kilobytes of prose — a header it has to scroll back for is
            // a header it does not use.
            let header = format!(
                "document: {}\ncontent_hash: {}\nvisibility: {}\nlines: {} of {}\n\
                 (pass content_hash as expected_hash when you write or edit this document)\n\
                 ----",
                doc.meta.id,
                doc.meta.content_hash,
                doc.meta.visibility,
                match doc.range {
                    Some(r) if r.to == usize::MAX => format!("{}-end", r.from),
                    Some(r) => r.to_string(),
                    None => format!("1-{}", doc.total_lines),
                },
                doc.total_lines,
            );
            Ok(ToolOk {
                content: vec![ResultBlock::Text(format!("{header}\n{}", doc.body))],
                summary_for_trace: "read a document",
            })
        })
    }
}

// ===========================================================================
// vault_write
// ===========================================================================

/// Create or replace a document.
pub struct VaultWrite(pub Arc<VaultContext>);

impl Tool for VaultWrite {
    fn name(&self) -> &str {
        "vault_write"
    }

    fn description(&self) -> &str {
        "Create a document, or replace one completely. `id` is a vault-relative path; its \
         folder must already exist. When replacing an existing document you must pass \
         expected_hash — the content_hash from your most recent vault_read of it — and the \
         write is refused if the document changed since then; read it again and decide \
         whether your change still applies. Refuses cold documents and anything outside \
         the vault. Prefer vault_edit for a small change: this replaces the whole file."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Vault-relative path of the document."},
                "body": {"type": "string", "description": "The complete new contents."},
                "expected_hash": {"type": "string", "description": "content_hash from your most recent read. Required when the document already exists."}
            },
            "required": ["id", "body"],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::VaultWrite
    }

    fn call<'a>(
        &'a self,
        scope: &'a Scope,
        args: Value,
        ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let id = doc_id(&args, "id")?;
            let body = str_arg(&args, "body")?;
            let expected = match opt_str_arg(&args, "expected_hash")? {
                Some(h) => Some(
                    ContentHash::parse(&h).map_err(|e| ToolError::InvalidArgs(e.to_string()))?,
                ),
                None => None,
            };

            // ONE `stat`, AND COLD IS DECIDED FIRST. The order matters for the message the
            // model gets: checked the other way round, an attempt to overwrite a cold
            // document answers "it already exists, read it first" — advice the model cannot
            // take, because reading it is exactly what it may not do. It would then read,
            // be refused, and try again.
            let existing = match self.0.store.stat(scope, &id).await {
                Ok(meta) => Some(meta),
                // Not found is the create case, and it is also what an EXCLUDED document
                // answers — deliberately indistinguishable. The store refuses the write.
                Err(StoreError::NotFound) => None,
                Err(e) => return Err(map_store_error(e)),
            };
            if let Some(meta) = &existing {
                if meta.visibility == Visibility::Cold {
                    return Err(ToolError::Refused(
                        "cold document; not writable by the assistant".into(),
                    ));
                }
            }

            // **A BLIND OVERWRITE IS REFUSED HERE, IN THE TOOL, NOT IN THE STORE.** The
            // store takes `Option<ContentHash>` because a create legitimately has no prior
            // hash; deciding that an EXISTING document must have one is a policy about how
            // this product's assistant should behave, and policy belongs at the tool
            // boundary where the model can be told about it in a description.
            if expected.is_none() && existing.is_some() {
                return Err(ToolError::InvalidArgs(format!(
                    "{id} already exists. Read it first and pass its content_hash as \
                     expected_hash, so you do not overwrite a change you have not seen."
                )));
            }

            let guarded = self.0.guarded(ctx);
            let receipt = self
                .0
                .store
                .write(scope, &id, body, expected, &guarded)
                .await
                .map_err(map_store_error)?;
            Ok(ToolOk {
                content: vec![ResultBlock::Json(json!({
                    "id": receipt.id.as_str(),
                    "created": receipt.created,
                    "bytes": receipt.size_bytes,
                    "content_hash": receipt.new_hash.as_str(),
                }))],
                summary_for_trace: "wrote a document",
            })
        })
    }
}

// ===========================================================================
// vault_edit
// ===========================================================================

/// Replace one occurrence inside a document.
pub struct VaultEdit(pub Arc<VaultContext>);

impl Tool for VaultEdit {
    fn name(&self) -> &str {
        "vault_edit"
    }

    fn description(&self) -> &str {
        "Change part of a document by replacing text. `find` must appear EXACTLY ONCE in \
         the document — if it matches zero times or more than once the edit is refused and \
         the count is reported, so include enough surrounding text to be unique. \
         expected_hash is required: it is the content_hash from your most recent \
         vault_read, and the edit is refused if the document changed since then. `id` is a \
         vault-relative path. Refuses cold documents."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "Vault-relative path of the document."},
                "find": {"type": "string", "description": "Exact text to replace. Must occur exactly once."},
                "replace": {"type": "string", "description": "What to put in its place. May be empty to delete."},
                "expected_hash": {"type": "string", "description": "content_hash from your most recent read of this document."}
            },
            "required": ["id", "find", "replace", "expected_hash"],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::VaultWrite
    }

    fn call<'a>(
        &'a self,
        scope: &'a Scope,
        args: Value,
        ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let id = doc_id(&args, "id")?;
            let find = str_arg(&args, "find")?;
            // `replace` may be empty — that is a deletion, and requiring a non-empty value
            // would mean the only way to delete a line is to rewrite the whole document.
            let replace = str_arg(&args, "replace")?;
            let expected = ContentHash::parse(&str_arg(&args, "expected_hash")?)
                .map_err(|e| ToolError::InvalidArgs(e.to_string()))?;
            let guarded = self.0.guarded(ctx);
            let receipt = self
                .0
                .store
                .edit(scope, &id, find, replace, expected, &guarded)
                .await
                .map_err(map_store_error)?;
            Ok(ToolOk {
                content: vec![ResultBlock::Json(json!({
                    "id": receipt.id.as_str(),
                    "bytes": receipt.size_bytes,
                    "content_hash": receipt.new_hash.as_str(),
                }))],
                summary_for_trace: "edited a document",
            })
        })
    }
}

// ===========================================================================
// vault_move
// ===========================================================================

/// Move a document.
pub struct VaultMove(pub Arc<VaultContext>);

impl Tool for VaultMove {
    fn name(&self) -> &str {
        "vault_move"
    }

    fn description(&self) -> &str {
        "Move or rename a document. Both `from` and `to` are vault-relative paths, and the \
         destination folder must already exist. Never overwrites: if `to` already exists \
         the move is refused. Refuses cold documents and anything outside the vault."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "from": {"type": "string", "description": "Current vault-relative path."},
                "to": {"type": "string", "description": "New vault-relative path."}
            },
            "required": ["from", "to"],
            "additionalProperties": false
        })
    }

    fn action_class(&self) -> ActionClass {
        ActionClass::VaultWrite
    }

    fn call<'a>(
        &'a self,
        scope: &'a Scope,
        args: Value,
        ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let from = doc_id(&args, "from")?;
            let to = doc_id(&args, "to")?;
            let guarded = self.0.guarded(ctx);
            let receipt = self
                .0
                .store
                .rename(scope, &from, &to, &guarded)
                .await
                .map_err(map_store_error)?;
            Ok(ToolOk {
                content: vec![ResultBlock::Json(json!({
                    "from": from.as_str(),
                    "to": receipt.id.as_str(),
                    "bytes": receipt.size_bytes,
                }))],
                summary_for_trace: "moved a document",
            })
        })
    }
}

// ===========================================================================
// deliver_artifact
// ===========================================================================

/// Put a file in the turn's staging directory.
///
/// **THE ONLY WRITE THAT IS NOT A DOCUMENT**, and it goes to the one place the bridge
/// already sweeps: a per-job directory inside the working directory, carrying a `.gitignore`
/// of `*` so it never reaches the repository (`bridge/src/artifacts.rs`). Everything about
/// this tool follows from that: it refuses when no staging directory is set, because a tool
/// that chose its own location would be writing where nothing sweeps; and it refuses a
/// filename with a path separator, because the directory is flat by contract and a
/// subdirectory would survive a sweep that only unlinks files.
pub struct DeliverArtifact;

impl Tool for DeliverArtifact {
    fn name(&self) -> &str {
        "deliver_artifact"
    }

    fn description(&self) -> &str {
        "Deliver a file to the person you are talking to — a chart, an export, a document \
         they asked for as a file rather than as text. `filename` is a plain name with no \
         folders (e.g. \"summary.csv\"). Give either `text` or `base64`, not both. This is \
         NOT how you save something to the vault: use vault_write for that. Artifacts are \
         handed over when the turn ends and are not kept."
    }

    fn schema(&self) -> Value {
        json!({
            "type": "object",
            "properties": {
                "filename": {"type": "string", "description": "A plain file name, no folders."},
                "text": {"type": "string", "description": "The file's contents, as text."},
                "base64": {"type": "string", "description": "The file's contents, base64-encoded, for binary files."}
            },
            "required": ["filename"],
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
        ctx: &'a ToolContext,
    ) -> BoxFuture<'a, ToolResult> {
        Box::pin(async move {
            let Some(dir) = ctx.artifact_dir.clone() else {
                return Err(ToolError::Refused(
                    "artifact delivery is not enabled for this turn; there is nowhere to put a \
                     file. Give the content in your answer instead."
                        .into(),
                ));
            };
            let filename = str_arg(&args, "filename")?;
            let filename = check_artifact_name(&filename)?;

            let text = opt_str_arg(&args, "text")?;
            let b64 = opt_str_arg(&args, "base64")?;
            let bytes: Vec<u8> = match (text, b64) {
                (Some(t), None) => t.into_bytes(),
                (None, Some(b)) => decode_base64(&b)?,
                (Some(_), Some(_)) => {
                    return Err(ToolError::InvalidArgs(
                        "give either `text` or `base64`, not both".into(),
                    ))
                }
                (None, None) => {
                    return Err(ToolError::InvalidArgs(
                        "give either `text` or `base64`".into(),
                    ))
                }
            };
            if bytes.len() > ARTIFACT_MAX_BYTES {
                return Err(ToolError::InvalidArgs(format!(
                    "{} bytes is over the {ARTIFACT_MAX_BYTES}-byte artifact cap",
                    bytes.len()
                )));
            }

            // The staging directory is resolved and the target is required to be directly
            // inside it — the same resolved-path containment the store's jail uses, for the
            // same reason: the directory could itself contain a symlink.
            let dir = std::fs::canonicalize(&dir).map_err(|e| {
                ToolError::Failed(format!("the artifact directory is unusable: {e}"))
            })?;
            let target = dir.join(&filename);
            if target.parent() != Some(dir.as_path()) {
                return Err(ToolError::Refused(
                    "the artifact must be a plain file directly in the delivery directory".into(),
                ));
            }
            std::fs::write(&target, &bytes)
                .map_err(|e| ToolError::Failed(format!("cannot deliver {filename}: {e}")))?;

            Ok(ToolOk {
                content: vec![ResultBlock::Json(json!({
                    "filename": filename,
                    "bytes": bytes.len(),
                    "delivered": true,
                }))],
                summary_for_trace: "delivered an artifact",
            })
        })
    }
}

/// A plain file name and nothing else.
///
/// Refuses separators on BOTH platforms' conventions, `..`, a leading dot, and anything with
/// a control character. The leading dot is refused because a delivered `.gitignore` would
/// change how the staging directory itself behaves — the artifact channel's containment
/// depends on the `.gitignore` the bridge wrote, and a turn must not be able to replace it.
fn check_artifact_name(raw: &str) -> Result<String, ToolError> {
    let name = raw.trim();
    if name.is_empty() {
        return Err(ToolError::InvalidArgs("`filename` is empty".into()));
    }
    if name.len() > 120 {
        return Err(ToolError::InvalidArgs(
            "`filename` is longer than 120 characters".into(),
        ));
    }
    if name.contains('/') || name.contains('\\') || name.contains('\0') {
        return Err(ToolError::Refused(format!(
            "`filename` must be a plain name with no folders: {raw:?}"
        )));
    }
    if name == "." || name == ".." || name.starts_with('.') {
        return Err(ToolError::Refused(format!(
            "`filename` may not start with a dot: {raw:?}"
        )));
    }
    if name.chars().any(|c| c.is_control()) {
        return Err(ToolError::Refused(
            "`filename` contains a control character".into(),
        ));
    }
    Ok(name.to_string())
}

/// Standard base64 with optional padding.
///
/// HAND-ROLLED, and it is twenty lines: the alternative is a dependency for one decode on a
/// path that already exists to move bytes the model produced. It is strict — an invalid
/// character is an error rather than being skipped — because silently dropping bytes from a
/// binary artifact produces a file that is subtly corrupt instead of obviously rejected.
fn decode_base64(s: &str) -> Result<Vec<u8>, ToolError> {
    const BAD: u8 = 255;
    fn val(c: u8) -> u8 {
        match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => BAD,
        }
    }
    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    let mut acc: u32 = 0;
    let mut bits = 0u32;
    for c in s.bytes() {
        if c == b'=' || c.is_ascii_whitespace() {
            continue;
        }
        let v = val(c);
        if v == BAD {
            return Err(ToolError::InvalidArgs(
                "`base64` contains a character that is not base64".into(),
            ));
        }
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Ok(out)
}

// ===========================================================================
// The set
// ===========================================================================

/// Build the vault tool set at a level.
///
/// The eight tools are added at every level and the level decides which survive — see
/// [`ToolSetBuilder::build`]. `fetch_url` is present in the manifest at `Read` because it is
/// an [`ActionClass::Egress`] tool; whether it can actually reach anything is its own
/// allowlist's business, and by default that list is EMPTY. See [`fetch`].
pub fn vault_tool_set(
    vault: Arc<VaultContext>,
    fetch: FetchConfig,
    level: Level,
) -> Result<StaticToolSet, String> {
    ToolSetBuilder::new(level)
        .add(ExposedClass::Read, Arc::new(VaultList(vault.clone())))
        .add(ExposedClass::Read, Arc::new(VaultSearch(vault.clone())))
        .add(ExposedClass::Read, Arc::new(VaultRead(vault.clone())))
        .add(ExposedClass::Egress, Arc::new(FetchUrl::new(fetch)))
        .add(
            ExposedClass::VaultWrite,
            Arc::new(VaultWrite(vault.clone())),
        )
        .add(ExposedClass::VaultWrite, Arc::new(VaultEdit(vault.clone())))
        .add(ExposedClass::VaultWrite, Arc::new(VaultMove(vault)))
        .add(ExposedClass::VaultWrite, Arc::new(DeliverArtifact))
        .build()
        .map_err(|e| e.to_string())
}

/// The names this set exposes at each level, for a report or a banner.
pub fn expected_names(level: Level) -> Vec<&'static str> {
    match level {
        Level::Basic => Vec::new(),
        Level::Read => vec!["vault_list", "vault_search", "vault_read", "fetch_url"],
        Level::Write => vec![
            "vault_list",
            "vault_search",
            "vault_read",
            "fetch_url",
            "vault_write",
            "vault_edit",
            "vault_move",
            "deliver_artifact",
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artifact_names_must_be_plain_files() {
        assert_eq!(check_artifact_name("summary.csv").unwrap(), "summary.csv");
        assert_eq!(check_artifact_name("  chart.png ").unwrap(), "chart.png");
        for hostile in [
            "../escape.txt",
            "sub/dir.txt",
            "sub\\dir.txt",
            "..",
            ".",
            // The one that matters most: replacing the `.gitignore` that makes the staging
            // directory invisible to git.
            ".gitignore",
            ".hidden",
            "with\0nul",
        ] {
            assert!(
                check_artifact_name(hostile).is_err(),
                "{hostile:?} must be refused"
            );
        }
        assert!(check_artifact_name("").is_err());
        assert!(check_artifact_name(&"a".repeat(200)).is_err());
    }

    #[test]
    fn base64_decodes_strictly() {
        assert_eq!(decode_base64("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(
            decode_base64("aGVs bG8=\n").unwrap(),
            b"hello",
            "whitespace is skipped"
        );
        assert_eq!(decode_base64("").unwrap(), Vec::<u8>::new());
        // Strict: a bad character is an error, not a silently dropped byte.
        assert!(decode_base64("aGVs!bG8=").is_err());
        assert!(decode_base64("héllo").is_err());
    }

    #[test]
    fn every_schema_is_strict_and_declares_no_scope_argument() {
        // The second half is enforced at build time by `ToolSetBuilder`; this asserts the
        // first, which nothing else would catch.
        let vault = Arc::new(VaultContext {
            store: Arc::new(crate::store::FsVaultStore::open(std::env::temp_dir()).unwrap()),
            index: Arc::new(crate::index::GrepIndex::new(
                crate::store::FsVaultStore::open(std::env::temp_dir()).unwrap(),
            )),
            guard: Arc::new(crate::store::NoGuard),
        });
        let set = vault_tool_set(vault, FetchConfig::default(), Level::Write).unwrap();
        for spec in crate::tools::ToolSet::manifest(&set) {
            assert_eq!(
                spec.input_schema.get("additionalProperties"),
                Some(&json!(false)),
                "{}'s schema must refuse invented arguments",
                spec.name
            );
            assert_eq!(
                spec.input_schema.get("type"),
                Some(&json!("object")),
                "{}'s schema must be an object",
                spec.name
            );
            assert!(
                !spec.description.is_empty() && spec.description.len() > 80,
                "{} needs a description written for the model",
                spec.name
            );
        }
    }

    #[test]
    fn the_level_decides_which_tools_exist() {
        let vault = Arc::new(VaultContext {
            store: Arc::new(crate::store::FsVaultStore::open(std::env::temp_dir()).unwrap()),
            index: Arc::new(crate::index::GrepIndex::new(
                crate::store::FsVaultStore::open(std::env::temp_dir()).unwrap(),
            )),
            guard: Arc::new(crate::store::NoGuard),
        });
        for level in [Level::Basic, Level::Read, Level::Write] {
            let set = vault_tool_set(vault.clone(), FetchConfig::default(), level).unwrap();
            let mut names: Vec<String> = crate::tools::ToolSet::manifest(&set)
                .into_iter()
                .map(|t| t.name)
                .collect();
            let mut want: Vec<String> = expected_names(level)
                .into_iter()
                .map(String::from)
                .collect();
            names.sort();
            want.sort();
            assert_eq!(names, want, "at level {level}");
        }
    }
}
