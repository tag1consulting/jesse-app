//! `inbound` — documents that are NOT on the phone: an attachment sitting in a mailbox or a
//! chat thread, reached by the BRIDGE and staged where the turn's child can read it.
//!
//! # The defect this exists to remove
//!
//! The composer path (`attachments`) has always worked: the phone uploads bytes, they are
//! sniffed, written to a per-request scratch dir and named in the prompt. But the common
//! case is that the document was never on the phone at all. It is the PDF invoice in this
//! week's mail from the accountant, or the one a spouse sent on WhatsApp. Asked about one of
//! those, a turn could reach no byte of it, and the failure was silent: the model answered
//! from the message text around the attachment and the answer read as though it had looked
//! at the document. **That — an answer that sounds like a reading and is not one — is the
//! defect. Every design decision below is downstream of removing it.**
//!
//! # THE FETCH IS THE BRIDGE'S, NOT THE CHILD'S, AND THAT IS THE WHOLE SHAPE
//!
//! The obvious design is to grant the child the two attachment tools its MCP servers
//! already advertise — `mcp__whatsapp__download_media` and
//! `mcp__google__get_gmail_attachment_content` — and let it fetch for itself. **That design
//! is wrong here and the repository already decided so**, for a reason that has nothing to
//! do with this feature: both tools WRITE FETCHED BYTES TO A PATH OF THEIR OWN CHOOSING ON
//! THE HOST, out of a child that also holds a write grant on the vault. They are named in
//! [`crate::DEFAULT_ALLOWED_TOOLS`]'s commentary as deliberate omissions, and a test in
//! `harness::claude_code` FAILS THE BUILD if `download_media` ever appears in a granted set.
//!
//! So the fetch moved rather than the boundary. Every resolver below runs IN THE BRIDGE,
//! writes only into one directory the bridge owns, and hands the child a path. The child
//! gains the ability to READ ONE DIRECTORY it could already almost reach; it gains no
//! ability to put bytes anywhere. The two ungranted tools stay ungranted and the assertion
//! that holds them out stays exactly as it was.
//!
//! # iMESSAGE IS ABSENT ON PURPOSE, AND SAYS SO OUT LOUD
//!
//! There is no iMessage resolver here, and [`InboundChannel::IMessage`] resolves to a
//! refusal that names the reason. Reading an iMessage attachment means reading
//! `~/Library/Messages/chat.db`, and `SECURITY.md` forbids the bridge holding the Full Disk
//! Access that would take: **the bridge's cdhash changes on every rebuild, so the grant
//! would lapse at the next deploy** — silently, because a launchd job cannot answer a TCC
//! prompt. A capability that works until the next deploy and then quietly stops is a worse
//! version of the defect at the top of this file, not a fix for it. The iMessage server the
//! bridge does run (`imcp`) advertises no attachment tool of any kind, so there is nothing
//! to grant either. The refusal is therefore the honest answer, and it is worded so the
//! model repeats it instead of inventing a summary.
//!
//! # What is staged, and for how long
//!
//! Everything lands in [`INBOUND_DIR_NAME`] under the turn's working directory, through the
//! SAME gate the composer path uses ([`crate::validate_one_blob`]) — one whitelist, not two
//! that drift. On-disk names are randomized and carry only the sniffed extension: a filename
//! from a mail header or a chat message is attacker-controlled and never becomes a path.

use crate::*;

// ---------------------------------------------------------------------------------------
// Piece 1 — the staging directory
// ---------------------------------------------------------------------------------------

/// The staging directory's name, relative to the turn's working directory.
///
/// **UNDER THE WORKING DIRECTORY, not the system temp dir, and that is the entire point of
/// Piece 1.** A read-capable child is scoped to its working directory — `Read(./**)` for a
/// [`Capability::Read`] child, `Read(//${WORKSPACE}/**)` for a `Write` one — so a file in
/// `/tmp` is refused at the permission layer no matter who fetched it. Staging inside the
/// workspace puts the file inside the scope that already exists rather than widening it.
pub const INBOUND_DIR_NAME: &str = ".jesse-inbound";

/// How long a staged document survives. See [`InboundStaging`] for why there is a TTL here
/// and a `Drop` guard on the composer's scratch dir instead.
pub const DEFAULT_INBOUND_TTL_SECS: u64 = 24 * 60 * 60;

/// The per-file cap for a STAGED DOCUMENT, separate from and larger than the composer's
/// per-photo cap.
///
/// The composer cap is sized for a camera-roll snapshot. This path's typical file is a
/// forty-page contract or a scanned bank statement, which clears that cap routinely — and a
/// document refused for being document-sized would be the same silent failure in a new
/// costume. Two caps, because they bound two different things; the photo cap is untouched.
pub const DEFAULT_MAX_INBOUND_DOCUMENT_BYTES: usize = 32 * 1024 * 1024;

/// The persistent staging directory a resolver writes into.
///
/// # Why this has a sweep and the composer's scratch dir has a `Drop`
///
/// [`crate::ScratchDir`] removes itself when the turn ends, which is right for bytes the
/// user just uploaded: the turn that needed them is over. It is WRONG here, and deliberately
/// so. "What is the total on that invoice?" is followed by "and when is it due?", and a
/// second fetch of the same document costs a second round trip to a mail server for bytes
/// that are already on disk.
///
/// **THE TRADE IS EXPLICIT: a staged document outlives its turn, and the sweep is the only
/// thing that bounds it.** There is no guard to lean on, so the sweep runs on every bridge
/// start AND before every staging write — not on a timer, which would stop bounding the
/// directory the moment the timer task died. A file older than the TTL is removed wherever
/// the next write or the next boot finds it.
pub struct InboundStaging {
    pub path: PathBuf,
    pub ttl: Duration,
}

impl InboundStaging {
    /// Open (creating if absent) the staging directory under `workspace`, and sweep it.
    ///
    /// Created 0700 like [`crate::ScratchDir`]: these are tax records and medical results,
    /// and the directory sits inside a working tree rather than in a private temp dir, so
    /// the mode is doing real work. `create_dir_all` is not used — the parent is the
    /// workspace and must already exist; a missing workspace is a deployment fault worth
    /// hearing about rather than a tree to conjure.
    pub fn open(workspace: &Path, ttl: Duration) -> std::io::Result<Self> {
        let path = workspace.join(INBOUND_DIR_NAME);
        match std::fs::DirBuilder::new().mode(0o700).create(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        let s = Self { path, ttl };
        s.sweep();
        Ok(s)
    }

    /// Write one validated blob under a randomized, sniffed-extension name and return its
    /// path. Sweeps first, so the directory is bounded by every write and not only by boot.
    ///
    /// **THE SOURCE'S FILENAME IS NEVER AN ON-DISK NAME.** It arrives from a mail header or
    /// a chat message, both attacker-controlled, and it reaches the model only as the
    /// `display_name` on [`StagedDocument`] — a string in a JSON field, never a path
    /// component. This is the same rule, for the same reason, as `ScratchDir::write_all`'s.
    pub fn stage(&self, d: &DecodedAttachment) -> std::io::Result<PathBuf> {
        self.sweep();
        let p = self.path.join(format!("{}.{}", random_hex(), d.ext));
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&p)?;
        f.write_all(&d.bytes)?;
        Ok(p)
    }

    /// Remove every entry older than the TTL. Returns how many were removed.
    ///
    /// **IT DOES NOT FOLLOW SYMLINKS OUT OF THE DIRECTORY.** `symlink_metadata` reads the
    /// LINK's own timestamps rather than its target's, and removal is always `remove_file`
    /// on the entry itself, so an expired symlink is unlinked and whatever it pointed at is
    /// untouched. A sweep that resolved links would be a delete-anything primitive rooted in
    /// a directory a resolver writes to.
    ///
    /// Best-effort by construction: a file that will not stat or will not unlink is skipped
    /// rather than propagated. The sweep runs on the path to a fetch, and failing a user's
    /// question because a stale file could not be removed would be the wrong trade.
    pub fn sweep(&self) -> usize {
        let Ok(entries) = std::fs::read_dir(&self.path) else {
            return 0;
        };
        let now = SystemTime::now();
        let mut removed = 0usize;
        for entry in entries.flatten() {
            let p = entry.path();
            let Ok(md) = std::fs::symlink_metadata(&p) else {
                continue;
            };
            // A DIRECTORY IS NOT SWEPT AND NOT DESCENDED INTO. Nothing here creates one, so
            // one appearing is somebody else's file; recursing would make this a tree
            // remover rooted in a directory whose contents are fetched from the network.
            if md.is_dir() {
                continue;
            }
            let age = md
                .modified()
                .ok()
                .and_then(|m| now.duration_since(m).ok())
                .unwrap_or_default();
            if age > self.ttl && std::fs::remove_file(&p).is_ok() {
                removed += 1;
            }
        }
        removed
    }
}

// ---------------------------------------------------------------------------------------
// The channels
// ---------------------------------------------------------------------------------------

/// The staging TTL this deployment runs, from `JESSE_INBOUND_TTL_SECS`.
///
/// A free function rather than a `Config` field because BOTH sides need it and they are
/// different processes: the bridge sweeps at boot, and the `jesse-inbound-mcp` child sweeps
/// before every write. One reader of one variable is what keeps the two agreeing.
pub fn inbound_ttl() -> Duration {
    Duration::from_secs(env_parse(
        "JESSE_INBOUND_TTL_SECS",
        DEFAULT_INBOUND_TTL_SECS,
    ))
}

/// Open (and sweep) the staging directory this deployment stages into.
pub fn open_inbound_staging(cfg: &Config) -> std::io::Result<InboundStaging> {
    InboundStaging::open(Path::new(&cfg.vault), inbound_ttl())
}

/// The four places a document can arrive from. A closed enum, so an unknown channel name is
/// an error rather than a silently-empty answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InboundChannel {
    Fastmail,
    Gmail,
    WhatsApp,
    /// Present so the refusal has somewhere to live. See the module docs.
    IMessage,
}

impl InboundChannel {
    pub const ALL: [InboundChannel; 4] = [
        InboundChannel::Fastmail,
        InboundChannel::Gmail,
        InboundChannel::WhatsApp,
        InboundChannel::IMessage,
    ];

    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "fastmail" => Some(InboundChannel::Fastmail),
            "gmail" => Some(InboundChannel::Gmail),
            "whatsapp" => Some(InboundChannel::WhatsApp),
            "imessage" | "messages" => Some(InboundChannel::IMessage),
            _ => None,
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            InboundChannel::Fastmail => "fastmail",
            InboundChannel::Gmail => "gmail",
            InboundChannel::WhatsApp => "whatsapp",
            InboundChannel::IMessage => "imessage",
        }
    }
}

/// THE iMESSAGE REFUSAL, as one const so the tool description, the resolver and the test all
/// quote the same words.
///
/// It names the channel, what is missing, and what the user can do instead — the three
/// things every failure on this path owes, because the alternative is a model that fills the
/// gap with a plausible summary of a document nobody read.
pub const IMESSAGE_UNREACHABLE: &str = "iMessage attachments cannot be read by this bridge. \
The Messages database is behind macOS Full Disk Access, which the bridge deliberately does \
not hold (its code signature changes on every rebuild, so such a grant would lapse silently \
at the next deploy), and the iMessage server it does run exposes no attachment tool at all. \
Nothing was read. Say so plainly rather than describing the document: to work with a file \
someone texted, open the thread on the phone and share the file into this chat, and it will \
arrive as an ordinary attachment.";

// ---------------------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------------------

/// One attachment a channel is holding, as reported by [`list_attachments`].
///
/// `id` is whatever that channel's fetch takes back — a JMAP `blobId`, a Gmail
/// `attachmentId` — so a caller never has to know the shape, only to pass it back.
#[derive(Debug, Clone, PartialEq)]
pub struct AttachmentListing {
    pub id: String,
    /// The source's own filename, FOR DISPLAY ONLY. Never a path component anywhere.
    pub display_name: String,
    /// The type the SOURCE claims. Not believed: the fetch re-sniffs the bytes and refuses a
    /// mismatch. Listed because it is what lets a caller pick the PDF out of five files.
    pub declared_mime: String,
    pub bytes: usize,
}

/// A document fetched, validated and written into the staging directory.
#[derive(Debug, Clone, PartialEq)]
pub struct StagedDocument {
    /// Where the child reads it. Inside [`INBOUND_DIR_NAME`], randomized name.
    pub path: PathBuf,
    /// The SNIFFED type, which is the only one that decides anything.
    pub mime: &'static str,
    pub bytes: usize,
    /// Page count for a PDF, `None` for anything else and for a PDF that would not open.
    pub pages: Option<usize>,
    /// The source's filename, for the model to say "the invoice.pdf you asked about". Never
    /// used on disk.
    pub display_name: String,
}

// ---------------------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------------------

/// Everything the resolvers read from the environment.
///
/// Read in the MCP server process rather than carried on [`Config`], for the same reason
/// [`crate::PlacesConfig`] is: this capability runs as its own binary spawned by the turn's
/// child, and it inherits the bridge's process environment — which is where
/// `export_mcp_server_env` has already put `JMAP_TOKEN` and `JMAP_SESSION_URL`. There is no
/// new credential store here; there are the two the deployment already has.
#[derive(Clone, Debug)]
pub struct InboundConfig {
    /// The workspace the staging directory lives under — the turn's working directory, which
    /// is the vault.
    pub workspace: PathBuf,
    pub ttl: Duration,
    /// Per-file cap for a staged document. See [`DEFAULT_MAX_INBOUND_DOCUMENT_BYTES`].
    pub max_document_bytes: usize,
    pub http_timeout: Duration,

    /// The WhatsApp Go bridge's loopback REST base, e.g. `http://127.0.0.1:8080/api`. This
    /// is the endpoint `download_media` itself calls; the bridge calls it directly so that
    /// tool can stay ungranted.
    pub whatsapp_api_base: String,
    /// The Go bridge's media store. The path that comes back from `/download` is checked
    /// against this by canonicalized prefix before a byte is read. See
    /// [`path_inside_root`] for why that check is load-bearing rather than tidy.
    pub whatsapp_media_root: Option<PathBuf>,

    /// `workspace-mcp`'s OAuth token cache, whose per-account JSON carries the refresh token
    /// the Gmail fetch renews with. Set by `export_mcp_server_env` on every deployment.
    pub gmail_credentials_dir: Option<PathBuf>,
    /// The Perseido instance's own cache, so the second Google account resolves too.
    pub gmail_perseido_credentials_dir: Option<PathBuf>,

    pub jmap_session_url: String,
    pub jmap_token: Option<String>,
}

impl Default for InboundConfig {
    fn default() -> Self {
        Self {
            workspace: PathBuf::from("."),
            ttl: Duration::from_secs(DEFAULT_INBOUND_TTL_SECS),
            max_document_bytes: DEFAULT_MAX_INBOUND_DOCUMENT_BYTES,
            http_timeout: Duration::from_secs(60),
            whatsapp_api_base: "http://127.0.0.1:8080/api".to_string(),
            whatsapp_media_root: None,
            gmail_credentials_dir: None,
            gmail_perseido_credentials_dir: None,
            jmap_session_url: "https://api.fastmail.com/jmap/session".to_string(),
            // NOT read from the environment by `Default`, on the same rule
            // `PlacesConfig::default` follows: a default that picked up a live token would
            // let a unit test reach a real mailbox.
            jmap_token: None,
        }
    }
}

impl InboundConfig {
    /// Read the environment, falling back to the defaults for anything absent or
    /// unparseable. A bad value is treated as absent rather than fatal — this server is a
    /// child of a turn, and refusing to start over a mistyped duration takes the capability
    /// out for the whole conversation.
    pub fn from_env() -> Self {
        let d = Self::default();
        let home = std::env::var("HOME").unwrap_or_default();
        Self {
            workspace: env_str("JESSE_VAULT")
                .map(|s| PathBuf::from(expand_tilde(&s, &home)))
                .or_else(|| std::env::current_dir().ok())
                .unwrap_or(d.workspace),
            ttl: env_str("JESSE_INBOUND_TTL_SECS")
                .and_then(|s| s.parse::<u64>().ok())
                .map(Duration::from_secs)
                .unwrap_or(d.ttl),
            max_document_bytes: env_str("JESSE_INBOUND_MAX_DOCUMENT_BYTES")
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(d.max_document_bytes),
            http_timeout: env_str("JESSE_INBOUND_HTTP_TIMEOUT_SECS")
                .and_then(|s| s.parse::<u64>().ok())
                .map(Duration::from_secs)
                .unwrap_or(d.http_timeout),
            whatsapp_api_base: env_str("JESSE_INBOUND_WHATSAPP_API")
                .map(|s| s.trim_end_matches('/').to_string())
                .unwrap_or(d.whatsapp_api_base),
            whatsapp_media_root: env_str("JESSE_INBOUND_WHATSAPP_MEDIA_ROOT")
                .map(|s| PathBuf::from(expand_tilde(&s, &home))),
            gmail_credentials_dir: env_str("WORKSPACE_MCP_CREDENTIALS_DIR")
                .map(|s| PathBuf::from(expand_tilde(&s, &home))),
            gmail_perseido_credentials_dir: env_str("JESSE_INBOUND_GMAIL_PERSEIDO_CREDS")
                .map(|s| PathBuf::from(expand_tilde(&s, &home))),
            jmap_session_url: env_str("JMAP_SESSION_URL").unwrap_or(d.jmap_session_url),
            jmap_token: env_str("JMAP_TOKEN"),
        }
    }
}

fn env_str(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|v| !v.trim().is_empty())
}

// ---------------------------------------------------------------------------------------
// The prefix check
// ---------------------------------------------------------------------------------------

/// Refuse any path that is not really inside `root`, and return the canonical form of one
/// that is.
///
/// # This is a security boundary, not a tidiness check
///
/// The WhatsApp path arrives in the body of a tool RESULT, which is model-influenced data.
/// A resolver that copied whatever path it was handed into a directory the child can read
/// would be an arbitrary-file-read primitive with extra steps: name `/etc/…` or a vault
/// secret and it is staged, sniffed and handed over.
///
/// `canonicalize` is what makes the check real rather than textual. It resolves `..` and it
/// resolves SYMLINKS, so a link inside the media root pointing anywhere else fails the
/// `starts_with` after resolution — which a string comparison on the raw path would pass.
/// The root is canonicalized too, so a symlinked root is not itself an escape.
pub fn path_inside_root(root: &Path, candidate: &Path) -> Result<PathBuf, String> {
    let root = root
        .canonicalize()
        .map_err(|e| format!("the configured media root cannot be resolved: {e}"))?;
    let real = candidate
        .canonicalize()
        .map_err(|e| format!("that file is not on this machine: {e}"))?;
    if !real.starts_with(&root) {
        // The refused path is NOT echoed. It is attacker-influenced text and this message
        // reaches a model's context; naming it would carry the payload the check just
        // stopped.
        return Err(
            "refused: the file the channel named is outside the directory that channel is \
             allowed to serve files from. Nothing was read."
                .to_string(),
        );
    }
    Ok(real)
}

// ---------------------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------------------

/// The resolvers, their HTTP client and their staging directory.
pub struct InboundClient {
    pub cfg: InboundConfig,
    pub staging: InboundStaging,
    http: reqwest::Client,
}

impl InboundClient {
    pub fn new(cfg: InboundConfig) -> Result<Arc<Self>, String> {
        let staging = InboundStaging::open(&cfg.workspace, cfg.ttl)
            .map_err(|e| format!("could not open the staging directory: {e}"))?;
        let http = reqwest::Client::builder()
            .timeout(cfg.http_timeout)
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        Ok(Arc::new(Self { cfg, staging, http }))
    }

    /// Run bytes through the shared gate and write them out.
    ///
    /// Both halves matter and neither is duplicated here: the gate is
    /// [`crate::validate_one_blob`], the same function the composer path calls, so the MIME
    /// whitelist and the magic-byte cross-check cannot drift between the two ways a file
    /// reaches a model. The cap it is given is this path's document cap, not the photo cap.
    fn stage_bytes(
        &self,
        bytes: Vec<u8>,
        declared_mime: &str,
        display_name: &str,
        label: &str,
    ) -> Result<StagedDocument, String> {
        let n = bytes.len();
        let decoded = validate_one_blob(bytes, declared_mime, self.cfg.max_document_bytes, label)
            .map_err(|(_, msg)| msg)?;
        let pages = if decoded.ext == "pdf" {
            pdf_page_count(&decoded.bytes)
        } else {
            None
        };
        let mime = sniff_attachment(&decoded.bytes)
            .map(|(m, _)| m)
            .unwrap_or("application/octet-stream");
        let path = self
            .staging
            .stage(&decoded)
            .map_err(|e| format!("could not stage the document: {e}"))?;
        // THE LOG LINE CARRIES NO CONTENT AND NO FILENAME. These are tax records, medical
        // results and contracts; what is worth recording is that a fetch happened, on which
        // channel, how big and of what type. The display filename is deliberately absent —
        // "Biopsy-results-2026.pdf" is itself sensitive.
        eprintln!("jesse-inbound: staged {label} {mime} {n} bytes");
        Ok(StagedDocument {
            path,
            mime,
            bytes: n,
            pages,
            display_name: display_name.to_string(),
        })
    }
}

/// A PDF's page count, without rendering a page: `render_pdf_pages` with a cap of zero opens
/// the document, reports its length and renders nothing. `None` for a PDF that will not open
/// (encrypted, malformed) — a page count is a nicety, and failing the whole fetch over one
/// would trade a readable document for a tidy field.
pub fn pdf_page_count(bytes: &[u8]) -> Option<usize> {
    cgpdf::render_pdf_pages(bytes, 72, 0).ok().map(|(_, n)| n)
}

// ---------------------------------------------------------------------------------------
// WhatsApp
// ---------------------------------------------------------------------------------------

/// Fetch one WhatsApp attachment and stage it.
///
/// # Why this calls the Go bridge's REST API and not `download_media`
///
/// The bytes are end-to-end encrypted and the Go half of `whatsapp-mcp` is what holds the
/// keys, so the download itself is genuinely not reimplementable here and is not
/// reimplemented — `POST <api>/download` is exactly the endpoint the ungranted
/// `download_media` tool calls. What changes is WHO calls it: the bridge, so the tool that
/// writes files stays out of the child's allowlist.
///
/// The returned path is then checked by [`path_inside_root`] before a byte is read.
pub async fn fetch_whatsapp(
    client: &InboundClient,
    message_id: &str,
    chat_jid: &str,
) -> Result<StagedDocument, String> {
    if message_id.trim().is_empty() || chat_jid.trim().is_empty() {
        return Err("whatsapp: both message_id and chat_jid are required".to_string());
    }
    let url = format!("{}/download", client.cfg.whatsapp_api_base);
    let body = json!({"message_id": message_id, "chat_jid": chat_jid}).to_string();
    let resp = client
        .http
        .post(&url)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(body)
        .send()
        .await
        .map_err(|e| {
            format!(
                "whatsapp: the local WhatsApp bridge did not answer ({e}). Nothing was read. \
                 It is a separate process and it has to be running for any attachment to be \
                 reachable."
            )
        })?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("whatsapp: could not read the bridge's reply ({e})"))?;
    if !status.is_success() {
        return Err(format!(
            "whatsapp: the local WhatsApp bridge refused the download (HTTP {}). Nothing was \
             read.",
            status.as_u16()
        ));
    }
    let v: Value = serde_json::from_str(&text)
        .map_err(|e| format!("whatsapp: the bridge's reply was not JSON ({e})"))?;
    if !v.get("success").and_then(|s| s.as_bool()).unwrap_or(false) {
        return Err(
            "whatsapp: the local WhatsApp bridge could not download that attachment. Nothing \
             was read. The message may carry no media, or the media may have expired on \
             WhatsApp's servers."
                .to_string(),
        );
    }
    let raw = v
        .get("path")
        .and_then(|p| p.as_str())
        .ok_or("whatsapp: the bridge reported success but named no file. Nothing was read.")?;
    let root = client.cfg.whatsapp_media_root.as_deref().ok_or(
        "whatsapp: no media root is configured, so the path the bridge returned cannot \
                be checked and will not be read. Set JESSE_INBOUND_WHATSAPP_MEDIA_ROOT.",
    )?;
    let path = path_inside_root(root, Path::new(raw)).map_err(|e| format!("whatsapp: {e}"))?;
    let display_name = v
        .get("filename")
        .and_then(|f| f.as_str())
        .unwrap_or("attachment")
        .to_string();
    let bytes = std::fs::read(&path)
        .map_err(|e| format!("whatsapp: the file the bridge named could not be read ({e})"))?;
    // THE DECLARED TYPE IS THE SNIFFED TYPE HERE, and that is not a hole. The Go bridge
    // reports no MIME, so there is nothing to cross-check against; the whitelist still
    // applies in full, and a type outside it is refused exactly as it would be anywhere
    // else. What is lost is only the "the source lied about the type" signal, which needs
    // two independent claims and this channel supplies one.
    let sniffed = sniff_attachment(&bytes)
        .map(|(m, _)| m)
        .unwrap_or("application/octet-stream");
    client.stage_bytes(bytes, sniffed, &display_name, "the WhatsApp attachment")
}

// ---------------------------------------------------------------------------------------
// Gmail
// ---------------------------------------------------------------------------------------

/// One Google account's cached OAuth credentials, as `workspace-mcp` writes them.
#[derive(Debug, Clone, PartialEq)]
pub struct GoogleCredentials {
    pub access_token: String,
    pub refresh_token: String,
    pub token_uri: String,
    pub client_id: String,
    pub client_secret: String,
    /// RFC 3339, as written by the Python client. Absent means "assume stale and refresh",
    /// which is the safe direction: a needless refresh costs one request, a skipped one
    /// costs the fetch.
    pub expiry: Option<String>,
}

/// Parse the credential JSON `workspace-mcp` caches per account.
///
/// Read-only, and NEVER written back. The refresh below keeps its new access token in
/// memory for the one call that needs it: writing the file would race the server that owns
/// it, and a corrupted token cache takes Gmail out until somebody re-consents by hand — the
/// one thing a headless bridge cannot do.
pub fn parse_google_credentials(text: &str) -> Result<GoogleCredentials, String> {
    let v: Value = serde_json::from_str(text)
        .map_err(|e| format!("the Google credential cache is not readable JSON ({e})"))?;
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
    let refresh_token = s("refresh_token");
    if refresh_token.is_empty() {
        return Err(
            "the Google credential cache holds no refresh token, so this account cannot be \
             renewed without an interactive consent a headless turn cannot perform."
                .to_string(),
        );
    }
    Ok(GoogleCredentials {
        access_token: s("token"),
        refresh_token,
        token_uri: {
            let t = s("token_uri");
            if t.is_empty() {
                "https://oauth2.googleapis.com/token".to_string()
            } else {
                t
            }
        },
        client_id: s("client_id"),
        client_secret: s("client_secret"),
        expiry: v
            .get("expiry")
            .and_then(|x| x.as_str())
            .map(|x| x.to_string()),
    })
}

/// Resolve an account name to its credential FILE, refusing anything that is not a plain
/// filename.
///
/// The account is a caller-supplied string reaching a path join, so it is checked the same
/// way any other such string is: no separator, no `..`, no absolute form. `workspace-mcp`
/// makes the same check on its side; making it again here means this function is safe on its
/// own terms rather than because another process happens to be careful.
pub fn google_credential_path(dir: &Path, account: &str) -> Result<PathBuf, String> {
    let a = account.trim();
    if a.is_empty()
        || a.contains('/')
        || a.contains('\\')
        || a.contains('\0')
        || a == "."
        || a == ".."
    {
        return Err("gmail: that is not a usable account name".to_string());
    }
    Ok(dir.join(format!("{a}.json")))
}

/// Decode Gmail's base64url payload by translating it into the standard alphabet and
/// re-padding, then handing it to the decoder the composer path already uses.
///
/// One decoder, not two. A second hand-rolled base64 would be a second place for a padding
/// bug to live, in a codec whose failures are silent corruption rather than errors.
pub fn base64url_decode(s: &str) -> Result<Vec<u8>, &'static str> {
    let mut t: String = s
        .chars()
        .filter(|c| !c.is_ascii_whitespace())
        .map(|c| match c {
            '-' => '+',
            '_' => '/',
            other => other,
        })
        .collect();
    while !t.len().is_multiple_of(4) {
        t.push('=');
    }
    base64_decode(&t)
}

impl InboundClient {
    fn gmail_credentials_dir(&self, account: &str) -> Result<&Path, String> {
        // The Perseido account has its own cache because it is a second instance of the same
        // server against a different account; one directory for both would authenticate as
        // whichever account wrote last.
        let perseido = self.cfg.gmail_perseido_credentials_dir.as_deref();
        if let Some(dir) = perseido {
            if google_credential_path(dir, account)
                .map(|p| p.exists())
                .unwrap_or(false)
            {
                return Ok(dir);
            }
        }
        self.cfg.gmail_credentials_dir.as_deref().ok_or_else(|| {
            "gmail: no Google credential cache is configured on this deployment, so no Gmail \
             attachment can be reached. Nothing was read."
                .to_string()
        })
    }

    /// A usable access token for `account`: the cached one when it is still valid, otherwise
    /// a freshly refreshed one held in memory only.
    async fn gmail_access_token(&self, account: &str) -> Result<String, String> {
        let dir = self.gmail_credentials_dir(account)?;
        let path = google_credential_path(dir, account)?;
        let text = std::fs::read_to_string(&path).map_err(|_| {
            format!(
                "gmail: no cached Google credentials for {account}. Nothing was read. That \
                 account has to be consented once, interactively, before a headless turn can \
                 read anything from it."
            )
        })?;
        let creds = parse_google_credentials(&text).map_err(|e| format!("gmail: {e}"))?;
        if !google_token_expired(creds.expiry.as_deref(), SystemTime::now())
            && !creds.access_token.is_empty()
        {
            return Ok(creds.access_token);
        }
        let form = [
            ("client_id", creds.client_id.as_str()),
            ("client_secret", creds.client_secret.as_str()),
            ("refresh_token", creds.refresh_token.as_str()),
            ("grant_type", "refresh_token"),
        ]
        .iter()
        .map(|(k, v)| format!("{}={}", k, percent_encode(v)))
        .collect::<Vec<_>>()
        .join("&");
        let resp = self
            .http
            .post(&creds.token_uri)
            .header(
                reqwest::header::CONTENT_TYPE,
                "application/x-www-form-urlencoded",
            )
            .body(form)
            .send()
            .await
            .map_err(|e| format!("gmail: the token refresh could not be sent ({e})"))?;
        let ok = resp.status().is_success();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("gmail: the token refresh reply could not be read ({e})"))?;
        if !ok {
            return Err(
                "gmail: Google refused to renew this account's access. Nothing was read. The \
                 account needs to be consented again, interactively."
                    .to_string(),
            );
        }
        let v: Value = serde_json::from_str(&text)
            .map_err(|e| format!("gmail: the token refresh reply was not JSON ({e})"))?;
        v.get("access_token")
            .and_then(|t| t.as_str())
            .map(|t| t.to_string())
            .ok_or_else(|| "gmail: the token refresh returned no access token".to_string())
    }

    async fn gmail_get(&self, account: &str, url: &str) -> Result<Value, String> {
        let token = self.gmail_access_token(account).await?;
        let resp = self
            .http
            .get(url)
            .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
            .send()
            .await
            .map_err(|e| format!("gmail: the request could not be sent ({e})"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("gmail: the reply could not be read ({e})"))?;
        if !status.is_success() {
            return Err(format!(
                "gmail: Gmail refused the request (HTTP {}). Nothing was read.",
                status.as_u16()
            ));
        }
        serde_json::from_str(&text).map_err(|e| format!("gmail: the reply was not JSON ({e})"))
    }
}

/// Whether a cached Google access token has expired, from the `expiry` string the Python
/// client writes. An unparseable or absent expiry counts as EXPIRED: refreshing needlessly
/// costs one request, and treating a stale token as fresh costs the fetch.
pub fn google_token_expired(expiry: Option<&str>, now: SystemTime) -> bool {
    let Some(raw) = expiry else {
        return true;
    };
    let Some(secs) = parse_rfc3339_secs(raw) else {
        return true;
    };
    let now_secs = now
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    // A minute of slack, so a token that expires mid-flight is renewed before the call
    // rather than during it.
    secs - 60 <= now_secs
}

/// Seconds since the epoch from an RFC 3339 / ISO 8601 timestamp, tolerating the two shapes
/// the Google client emits: with a `Z`, and with no zone at all (which it writes as UTC).
/// Returns `None` for anything else, which every caller treats as "assume expired".
pub fn parse_rfc3339_secs(raw: &str) -> Option<i64> {
    let s = raw.trim();
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let num = |a: usize, b: usize| s.get(a..b)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, sec) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    // Days from the civil date, Howard Hinnant's algorithm — the standard closed form, and
    // the reason no date crate is pulled in for one field.
    let y2 = y - i64::from(mo <= 2);
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let doy = (153 * (mo + if mo > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + h * 3_600 + mi * 60 + sec)
}

/// Percent-encode a form value. Only the unreserved set survives unescaped, which is more
/// than strictly needed and is the correct direction for a value that carries a client
/// secret and a refresh token.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

/// Every attachment on one Gmail message, walked out of the MIME part tree.
pub fn gmail_attachments_from_message(msg: &Value) -> Vec<AttachmentListing> {
    fn walk(part: &Value, out: &mut Vec<AttachmentListing>) {
        let filename = part
            .get("filename")
            .and_then(|f| f.as_str())
            .unwrap_or_default();
        let id = part
            .get("body")
            .and_then(|b| b.get("attachmentId"))
            .and_then(|a| a.as_str());
        if let Some(id) = id {
            // A part with an attachment id and no filename is an inline image (a signature
            // logo, a tracking pixel). Listing those buries the one file the user means.
            if !filename.is_empty() {
                out.push(AttachmentListing {
                    id: id.to_string(),
                    display_name: filename.to_string(),
                    declared_mime: part
                        .get("mimeType")
                        .and_then(|m| m.as_str())
                        .unwrap_or_default()
                        .to_string(),
                    bytes: part
                        .get("body")
                        .and_then(|b| b.get("size"))
                        .and_then(|s| s.as_u64())
                        .unwrap_or(0) as usize,
                });
            }
        }
        if let Some(parts) = part.get("parts").and_then(|p| p.as_array()) {
            for p in parts {
                walk(p, out);
            }
        }
    }
    let mut out = Vec::new();
    if let Some(payload) = msg.get("payload") {
        walk(payload, &mut out);
    }
    out
}

/// List the attachments on one Gmail message.
pub async fn list_gmail_attachments(
    client: &InboundClient,
    account: &str,
    message_id: &str,
) -> Result<Vec<AttachmentListing>, String> {
    let url = format!(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/{}?format=full",
        url_path_segment(message_id)?
    );
    let msg = client.gmail_get(account, &url).await?;
    Ok(gmail_attachments_from_message(&msg))
}

/// Fetch one Gmail attachment and stage it.
///
/// The bytes come straight from `users.messages.attachments.get`, base64url-encoded, over
/// the account's own read-only OAuth grant. Nothing is written anywhere but the staging
/// directory — which is the difference between this and the ungranted tool that does the
/// same fetch and then saves the file wherever it likes.
pub async fn fetch_gmail(
    client: &InboundClient,
    account: &str,
    message_id: &str,
    attachment_id: &str,
) -> Result<StagedDocument, String> {
    // The declared type and the filename live on the MESSAGE, not on the attachment
    // response, so the listing is fetched first. That is also what gives the gate a second,
    // independent claim about the type to cross-check the magic bytes against.
    let listed = list_gmail_attachments(client, account, message_id).await?;
    let meta = listed.iter().find(|a| a.id == attachment_id);
    let url = format!(
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/{}/attachments/{}",
        url_path_segment(message_id)?,
        url_path_segment(attachment_id)?
    );
    let v = client.gmail_get(account, &url).await?;
    let data = v
        .get("data")
        .and_then(|d| d.as_str())
        .ok_or("gmail: the attachment came back with no data. Nothing was read.")?;
    let bytes = base64url_decode(data).map_err(|e| format!("gmail: {e}"))?;
    let declared = meta
        .map(|m| m.declared_mime.clone())
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| {
            sniff_attachment(&bytes)
                .map(|(m, _)| m.to_string())
                .unwrap_or_default()
        });
    let display = meta
        .map(|m| m.display_name.clone())
        .unwrap_or_else(|| "attachment".to_string());
    client.stage_bytes(bytes, &declared, &display, "the Gmail attachment")
}

/// Refuse a path segment that could leave the path it is joined into. Gmail's ids are
/// URL-safe base64 in practice, so this rejects rather than escapes: a legitimate id never
/// trips it, and quietly encoding a hostile one would hide that something odd arrived.
pub fn url_path_segment(s: &str) -> Result<&str, String> {
    if s.is_empty()
        || s.contains('/')
        || s.contains('?')
        || s.contains('#')
        || s.contains('\\')
        || s.contains("..")
    {
        return Err("that identifier is not usable".to_string());
    }
    Ok(s)
}

// ---------------------------------------------------------------------------------------
// Fastmail (JMAP)
// ---------------------------------------------------------------------------------------

/// What one JMAP session gives this module: where to call, who to call as, and the template
/// a blob is downloaded through.
#[derive(Debug, Clone, PartialEq)]
pub struct JmapSession {
    pub api_url: String,
    pub download_url: String,
    pub account_id: String,
}

/// Pull the three fields out of a JMAP session object.
///
/// `primaryAccounts["urn:ietf:params:jmap:mail"]` is the account the token is for; taking
/// the first account in the map instead would pick a contacts or calendar account on a
/// server that offers them.
pub fn parse_jmap_session(text: &str) -> Result<JmapSession, String> {
    let v: Value = serde_json::from_str(text)
        .map_err(|e| format!("the JMAP session reply was not JSON ({e})"))?;
    let s = |k: &str| {
        v.get(k)
            .and_then(|x| x.as_str())
            .map(|x| x.to_string())
            .ok_or_else(|| format!("the JMAP session carries no {k}"))
    };
    let account_id = v
        .get("primaryAccounts")
        .and_then(|p| p.get("urn:ietf:params:jmap:mail"))
        .and_then(|a| a.as_str())
        .ok_or("the JMAP session names no primary mail account")?
        .to_string();
    Ok(JmapSession {
        api_url: s("apiUrl")?,
        download_url: s("downloadUrl")?,
        account_id,
    })
}

/// Fill a JMAP `downloadUrl` template. The four placeholders are the spec's; `type` and
/// `name` are what the server uses for the response headers, so they are filled with
/// deliberately neutral values — the real name never rides in a URL and the real type is
/// decided by the sniff, not by what is asked for.
pub fn jmap_download_url(template: &str, account_id: &str, blob_id: &str) -> String {
    template
        .replace("{accountId}", &url_encode_component(account_id))
        .replace("{blobId}", &url_encode_component(blob_id))
        .replace("{type}", "application%2Foctet-stream")
        .replace("{name}", "download")
}

fn url_encode_component(s: &str) -> String {
    percent_encode(s)
}

/// The attachments on one email, from a JMAP `Email/get` response.
pub fn jmap_attachments_from_response(v: &Value) -> Vec<AttachmentListing> {
    let mut out = Vec::new();
    let Some(list) = v
        .get("methodResponses")
        .and_then(|m| m.as_array())
        .and_then(|a| a.first())
        .and_then(|r| r.get(1))
        .and_then(|r| r.get("list"))
        .and_then(|l| l.as_array())
    else {
        return out;
    };
    for email in list {
        let Some(atts) = email.get("attachments").and_then(|a| a.as_array()) else {
            continue;
        };
        for a in atts {
            let Some(id) = a.get("blobId").and_then(|b| b.as_str()) else {
                continue;
            };
            out.push(AttachmentListing {
                id: id.to_string(),
                display_name: a
                    .get("name")
                    .and_then(|n| n.as_str())
                    .unwrap_or("attachment")
                    .to_string(),
                declared_mime: a
                    .get("type")
                    .and_then(|t| t.as_str())
                    .unwrap_or_default()
                    .to_string(),
                bytes: a.get("size").and_then(|s| s.as_u64()).unwrap_or(0) as usize,
            });
        }
    }
    out
}

impl InboundClient {
    fn jmap_token(&self) -> Result<&str, String> {
        self.cfg.jmap_token.as_deref().ok_or_else(|| {
            "fastmail: no JMAP token is configured on this deployment, so no Fastmail \
             attachment can be reached. Nothing was read."
                .to_string()
        })
    }

    async fn jmap_session(&self) -> Result<JmapSession, String> {
        let token = self.jmap_token()?;
        let resp = self
            .http
            .get(&self.cfg.jmap_session_url)
            .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
            .send()
            .await
            .map_err(|e| format!("fastmail: the JMAP session could not be fetched ({e})"))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| format!("fastmail: the JMAP session reply could not be read ({e})"))?;
        if !status.is_success() {
            return Err(format!(
                "fastmail: the mail server refused the session request (HTTP {}). Nothing was \
                 read.",
                status.as_u16()
            ));
        }
        parse_jmap_session(&text).map_err(|e| format!("fastmail: {e}"))
    }
}

/// List the attachments on one Fastmail email.
///
/// This is the whole reason Fastmail needed a resolver at all rather than a read-scope fix:
/// the JMAP MCP server the deployment runs exposes `search_emails`, `get_mailboxes` and
/// `get_email_content`, and NONE of them enumerates an attachment or downloads one. The
/// personal mail account was simply blind to attachments.
pub async fn list_fastmail_attachments(
    client: &InboundClient,
    email_id: &str,
) -> Result<Vec<AttachmentListing>, String> {
    let session = client.jmap_session().await?;
    let token = client.jmap_token()?;
    let body = json!({
        "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"],
        "methodCalls": [[
            "Email/get",
            {
                "accountId": session.account_id,
                "ids": [email_id],
                "properties": ["id", "subject", "attachments"]
            },
            "0"
        ]]
    })
    .to_string();
    let resp = client
        .http
        .post(&session.api_url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(body)
        .send()
        .await
        .map_err(|e| format!("fastmail: the attachment listing could not be sent ({e})"))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("fastmail: the listing reply could not be read ({e})"))?;
    if !status.is_success() {
        return Err(format!(
            "fastmail: the mail server refused the listing (HTTP {}). Nothing was read.",
            status.as_u16()
        ));
    }
    let v: Value = serde_json::from_str(&text)
        .map_err(|e| format!("fastmail: the listing reply was not JSON ({e})"))?;
    Ok(jmap_attachments_from_response(&v))
}

/// Fetch one Fastmail attachment by `blobId` and stage it.
pub async fn fetch_fastmail(
    client: &InboundClient,
    email_id: &str,
    blob_id: &str,
) -> Result<StagedDocument, String> {
    // Listed first for the same reason Gmail's is: the declared type and the display name
    // live on the email, and the gate wants a second claim to check the bytes against.
    let listed = list_fastmail_attachments(client, email_id).await?;
    let meta = listed
        .iter()
        .find(|a| a.id == blob_id)
        .ok_or("fastmail: that email carries no attachment with that id. Nothing was read.")?;
    let session = client.jmap_session().await?;
    let token = client.jmap_token()?;
    let url = jmap_download_url(&session.download_url, &session.account_id, blob_id);
    let resp = client
        .http
        .get(&url)
        .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
        .send()
        .await
        .map_err(|e| format!("fastmail: the download could not be sent ({e})"))?;
    let status = resp.status();
    let bytes = resp
        .bytes()
        .await
        .map_err(|e| format!("fastmail: the download could not be read ({e})"))?;
    if !status.is_success() {
        return Err(format!(
            "fastmail: the mail server refused the download (HTTP {}). Nothing was read.",
            status.as_u16()
        ));
    }
    client.stage_bytes(
        bytes.to_vec(),
        &meta.declared_mime,
        &meta.display_name,
        "the Fastmail attachment",
    )
}

// ---------------------------------------------------------------------------------------
// The two entry points
// ---------------------------------------------------------------------------------------

/// List what a channel is holding for one message.
pub async fn list_attachments(
    client: &InboundClient,
    channel: InboundChannel,
    args: &Value,
) -> Result<Vec<AttachmentListing>, String> {
    let s = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or_default();
    match channel {
        InboundChannel::Fastmail => list_fastmail_attachments(client, s("message_id")).await,
        InboundChannel::Gmail => {
            let account = s("account");
            if account.is_empty() {
                return Err("gmail: `account` is required — name the mailbox address.".to_string());
            }
            list_gmail_attachments(client, account, s("message_id")).await
        }
        // WhatsApp has no listing of its own AND does not need one: the granted read tools
        // (`list_messages`, `get_message_context`) already show which message carries media,
        // and their message id is exactly what the fetch takes. Inventing a second listing
        // here would be a second, divergent view of the same thread.
        InboundChannel::WhatsApp => Err(
            "whatsapp: there is no separate attachment listing. Find the message with \
             list_messages or get_message_context, then fetch with its message_id and \
             chat_jid."
                .to_string(),
        ),
        InboundChannel::IMessage => Err(IMESSAGE_UNREACHABLE.to_string()),
    }
}

/// Fetch one attachment from a channel and stage it for reading.
pub async fn fetch_attachment(
    client: &InboundClient,
    channel: InboundChannel,
    args: &Value,
) -> Result<StagedDocument, String> {
    let s = |k: &str| args.get(k).and_then(|v| v.as_str()).unwrap_or_default();
    match channel {
        InboundChannel::Fastmail => {
            fetch_fastmail(client, s("message_id"), s("attachment_id")).await
        }
        InboundChannel::Gmail => {
            let account = s("account");
            if account.is_empty() {
                return Err("gmail: `account` is required — name the mailbox address.".to_string());
            }
            fetch_gmail(client, account, s("message_id"), s("attachment_id")).await
        }
        InboundChannel::WhatsApp => fetch_whatsapp(client, s("message_id"), s("chat_jid")).await,
        InboundChannel::IMessage => Err(IMESSAGE_UNREACHABLE.to_string()),
    }
}

// ---------------------------------------------------------------------------------------
// Piece 3 — handing a staged file to the model
// ---------------------------------------------------------------------------------------

/// Convert a staged document into what the SERVING HARNESS can actually read, and say what
/// to tell the model about it.
///
/// This calls [`crate::prepare_attachments_for_harness`] rather than reimplementing the
/// routing, and that is the whole point: that function holds the one piece of knowledge that
/// matters — Claude Code's `Read` takes a PDF directly, Codex's does not and needs the Core
/// Graphics rasterizer, HEIC needs `sips` on both, and a type with no route is a loud error
/// and never a silent drop. A staged PDF on a Claude Code turn is therefore handed over as
/// the PDF; on a harness that cannot read one it becomes page images under the existing page
/// cap, carrying the existing truncation note.
///
/// **THE TRUNCATION NOTE IS RETURNED, NOT SWALLOWED.** A forty-page contract of which the
/// model saw twelve pages produces an answer that is right about twelve pages and silent
/// about the rest, which is the family of failure this module exists to remove.
pub fn prepare_staged_document(
    vision: &VisionConfig,
    staging: &InboundStaging,
    doc: &StagedDocument,
    support: &AttachmentSupport,
) -> Result<PreparedAttachments, String> {
    prepare_attachments_for_harness(
        vision,
        &staging.path,
        std::slice::from_ref(&doc.path),
        support,
    )
    .map_err(|(_, msg)| msg)
}

/// The sentence that tells the model a fetched document is now readable and where.
///
/// The counterpart to [`crate::attachment_prompt_suffix`], and deliberately the same shape:
/// the on-disk paths and the SERVING HARNESS's own instruction, never the source's filename
/// as a path. The display name appears only as prose, so a crafted mail header cannot ride
/// into the prompt as something that looks like a path.
pub fn staged_prompt_fragment(
    prepared: &PreparedAttachments,
    display_name: &str,
    instruction: &str,
) -> String {
    let list = prepared
        .paths
        .iter()
        .map(|p| p.display().to_string())
        .collect::<Vec<_>>()
        .join(", ");
    let mut s = format!(
        "\n\n(The document you asked about has been fetched and is now readable as {} \
         file(s) — {instruction} Paths: {list}. It was sent with the name {}",
        prepared.paths.len(),
        sanitize_display_name(display_name)
    );
    for n in &prepared.notes {
        s.push_str(&format!(". Note: {n}"));
    }
    s.push(')');
    s
}

/// Flatten a source-supplied filename to something safe to put in a prompt: one line, no
/// control characters, bounded length. It is display text arriving from a mail header, so it
/// is treated as hostile prose rather than trusted metadata.
pub fn sanitize_display_name(raw: &str) -> String {
    let cleaned: String = raw
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        return "an unnamed file".to_string();
    }
    if trimmed.chars().count() > 120 {
        let short: String = trimmed.chars().take(120).collect();
        format!("{short}…")
    } else {
        trimmed.to_string()
    }
}

// ---------------------------------------------------------------------------------------
// The tool surface
// ---------------------------------------------------------------------------------------

/// Which harness's `Read` a staged file is being prepared for.
///
/// The `inbound` server ships in **Claude Code's** MCP set only, on the same reasoning that
/// kept `build` and `places` off Codex: giving Codex a server moves ITS containment row
/// labels and demands a live Codex battery nothing here runs. So the default is the harness
/// that actually loads this server, and the override exists so the conversion table is
/// exercised rather than assumed for the harnesses that do not.
pub fn attachment_support_for(harness_id: &str) -> &'static AttachmentSupport {
    match harness_id {
        CODEX_ID => &CODEX_ATTACHMENTS,
        DIRECT_ID => &DIRECT_ATTACHMENTS,
        _ => &CLAUDE_CODE_ATTACHMENTS,
    }
}

/// The two tools, as a closed enum. Same shape as [`crate::PlacesTool`]: `tools/call`
/// dispatches a NAME onto this, and an unknown name is an error rather than anything else.
///
/// # Why two names and not eight
///
/// One tool per channel would read more naturally and would cost four times as much. Every
/// tool NAME has to be granted in [`crate::DEFAULT_ALLOWED_TOOLS`], and any change to that
/// list changes `capability_args`, which the containment record commits and compares by
/// strict equality at boot — so the number of names here is a number of things a future
/// change has to re-certify. The channel is therefore an ARGUMENT, exactly as
/// [`crate::DetailLevel`] is on the places tools and for exactly the same reason.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InboundTool {
    List,
    Fetch,
}

impl InboundTool {
    pub const ALL: [InboundTool; 2] = [InboundTool::List, InboundTool::Fetch];

    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "list_attachments" => Some(InboundTool::List),
            "fetch_attachment" => Some(InboundTool::Fetch),
            _ => None,
        }
    }

    pub fn tool_name(&self) -> &'static str {
        match self {
            InboundTool::List => "list_attachments",
            InboundTool::Fetch => "fetch_attachment",
        }
    }

    pub fn description(&self) -> String {
        match self {
            InboundTool::List => "List the files attached to one email, so you can see what is \
                 there before fetching anything. Takes `channel` (\"fastmail\" or \"gmail\"), \
                 the `message_id` of the email, and for gmail the `account` address. Returns \
                 each attachment's `id`, `display_name`, `declared_mime` and `bytes`. Pass an \
                 `id` back to fetch_attachment to actually read one. WhatsApp has no separate \
                 listing: use the WhatsApp message tools to find the message, then fetch with \
                 its message_id and chat_jid."
                .to_string(),
            InboundTool::Fetch => format!(
                "Fetch one attachment that is sitting in an email or a chat thread, and make \
                 it readable. THIS IS HOW YOU READ A DOCUMENT THAT IS NOT ATTACHED TO THE \
                 CHAT: a PDF invoice in an email, a contract someone sent on WhatsApp. It \
                 downloads the file, checks it, and writes it into a directory you can read; \
                 the reply names the path, so read that path to see the contents. Takes \
                 `channel` plus that channel's identifiers: fastmail needs `message_id` and \
                 `attachment_id`; gmail needs `account`, `message_id` and `attachment_id` \
                 (get the ids from list_attachments); whatsapp needs `message_id` and \
                 `chat_jid`. If it fails it says so and NOTHING was read — report the reason \
                 rather than describing the document. iMessage: {IMESSAGE_UNREACHABLE}"
            ),
        }
    }

    pub fn input_schema(&self) -> Value {
        let channel = json!({
            "type": "string",
            "enum": ["fastmail", "gmail", "whatsapp", "imessage"],
            "description": "Which account or app the document is sitting in."
        });
        match self {
            InboundTool::List => json!({
                "type": "object",
                "properties": {
                    "channel": channel,
                    "message_id": {"type": "string", "description": "The email's id, as the mail tools report it."},
                    "account": {"type": "string", "description": "Gmail only: which mailbox address to read as."}
                },
                "required": ["channel", "message_id"]
            }),
            InboundTool::Fetch => json!({
                "type": "object",
                "properties": {
                    "channel": channel,
                    "message_id": {"type": "string", "description": "The email or chat message holding the file."},
                    "attachment_id": {"type": "string", "description": "Mail only: the id list_attachments gave for the file you want."},
                    "account": {"type": "string", "description": "Gmail only: which mailbox address to read as."},
                    "chat_jid": {"type": "string", "description": "WhatsApp only: the chat the message is in."}
                },
                "required": ["channel", "message_id"]
            }),
        }
    }
}

/// Run one tool call and return the JSON body of its result.
///
/// The fetch arm does the whole job in one call — download, validate, stage, AND convert for
/// the serving harness — so what comes back is a path the model can read right now. Splitting
/// the conversion into a second tool would leave a window in which the model has a path to a
/// file its own `Read` cannot make sense of, which is the shape of the original defect.
pub async fn run_inbound_tool(
    client: &InboundClient,
    vision: &VisionConfig,
    support: &AttachmentSupport,
    tool: InboundTool,
    args: &Value,
) -> Result<Value, String> {
    let channel_name = args
        .get("channel")
        .and_then(|c| c.as_str())
        .unwrap_or_default();
    let channel = InboundChannel::parse(channel_name).ok_or_else(|| {
        format!(
            "unknown channel {channel_name:?} — it must be one of: {}",
            InboundChannel::ALL
                .iter()
                .map(|c| c.label())
                .collect::<Vec<_>>()
                .join(", ")
        )
    })?;
    match tool {
        InboundTool::List => {
            let listed = list_attachments(client, channel, args).await?;
            Ok(json!({
                "channel": channel.label(),
                "attachments": listed.iter().map(|a| json!({
                    "id": a.id,
                    "display_name": a.display_name,
                    "declared_mime": a.declared_mime,
                    "bytes": a.bytes,
                })).collect::<Vec<_>>(),
                // An empty list is stated rather than left to be read as "there is nothing
                // there" when it might mean "this message was not the one".
                "note": if listed.is_empty() {
                    "This message carries no attachments."
                } else {
                    "Pass an id back to fetch_attachment to read one."
                },
            }))
        }
        InboundTool::Fetch => {
            let doc = fetch_attachment(client, channel, args).await?;
            let prepared = prepare_staged_document(vision, &client.staging, &doc, support)?;
            let paths: Vec<String> = prepared
                .paths
                .iter()
                .map(|p| p.display().to_string())
                .collect();
            Ok(json!({
                "channel": channel.label(),
                "read_these_paths": paths,
                "mime": doc.mime,
                "bytes": doc.bytes,
                "pages": doc.pages,
                "display_name": sanitize_display_name(&doc.display_name),
                "instruction": support.instruction,
                // THE SENTENCE THE MODEL IS ACTUALLY TOLD, built by the counterpart to
                // `attachment_prompt_suffix`. It rides the TOOL RESULT rather than the
                // prompt for a reason that is not a shortcut: a resolver stages mid-turn,
                // and the prompt was assembled before the turn began. The tool result is
                // the only channel that exists at the moment the file becomes readable.
                "summary": staged_prompt_fragment(
                    &prepared,
                    &doc.display_name,
                    support.instruction,
                ),
                // NEVER SWALLOWED. A page cap that dropped 28 of 40 pages must reach the
                // user's answer, not just this JSON — so it is a field of its own rather
                // than a line buried in a prose blob.
                "truncation_notes": prepared.notes,
                "must_tell_the_user": if prepared.notes.is_empty() {
                    Value::Null
                } else {
                    json!("Some of this document was not attached. Say so in your answer.")
                },
            }))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;
    use std::os::unix::fs::PermissionsExt;

    const PNG_BYTES: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
    const PDF_BYTES: &[u8] = b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n";

    /// A throwaway workspace with a staging directory in it. Removed by the caller; nothing
    /// here writes outside the temp dir.
    fn temp_workspace() -> PathBuf {
        let p = std::env::temp_dir().join(format!("jesse-inbound-test-{}", random_hex()));
        std::fs::create_dir(&p).expect("workspace");
        p
    }

    fn staging_in(ws: &Path) -> InboundStaging {
        InboundStaging::open(ws, Duration::from_secs(3600)).expect("staging")
    }

    fn client_in(ws: &Path) -> Arc<InboundClient> {
        InboundClient::new(InboundConfig {
            workspace: ws.to_path_buf(),
            ..InboundConfig::default()
        })
        .expect("client")
    }

    /// Gated to macOS because its only callers are: the two PDF-routing tests below need
    /// Core Graphics to rasterize, so they are macOS-only, and an ungated helper is dead code
    /// on a Linux CI runner (where `-D warnings` makes that a build failure rather than a
    /// note).
    #[cfg(target_os = "macos")]
    fn read_fixture(name: &str) -> Vec<u8> {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../eval/vision/{name}"));
        std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
    }

    // ---- Piece 1: the staging directory ------------------------------------------------

    /// The posture, all three parts: 0700 on the directory, 0600 on the file, and a name that
    /// carries nothing the source chose.
    ///
    /// The last part is the one worth a test rather than a comment. The filename arrives from
    /// a mail header or a chat message and is attacker-controlled; used on disk it is a path
    /// traversal, and echoed into a prompt as a path it is an instruction. Here it must not
    /// appear at all.
    #[test]
    fn a_staged_file_is_private_and_its_name_carries_nothing_the_source_chose() {
        let ws = temp_workspace();
        let s = staging_in(&ws);

        let dir_mode = std::fs::metadata(&s.path).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700, "the staging directory is owner-only");

        let d = DecodedAttachment {
            bytes: PDF_BYTES.to_vec(),
            ext: "pdf",
        };
        let p = s.stage(&d).expect("stage");
        let mode = std::fs::metadata(&p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "a staged document is owner-only");
        assert_eq!(std::fs::read(&p).unwrap(), PDF_BYTES);

        let name = p.file_name().unwrap().to_string_lossy().to_string();
        assert!(
            name.ends_with(".pdf"),
            "the SNIFFED extension, not a claimed one"
        );
        for forbidden in ["invoice", "..", "/", "Biopsy"] {
            assert!(
                !name.contains(forbidden),
                "a staged name must carry nothing from the source: {name}"
            );
        }
        // Two stagings of identical bytes are two distinct files, so one fetch can never
        // clobber another's document mid-turn.
        let q = s.stage(&d).expect("stage again");
        assert_ne!(p, q);

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// Retention: expired goes, fresh stays.
    ///
    /// This is the ONLY thing bounding the directory — there is no `Drop` guard here, because
    /// a staged document deliberately outlives the turn that fetched it. So the sweep is
    /// tested for both directions: a sweep that removed nothing would leak documents, and one
    /// that removed everything would refetch on every follow-up question.
    #[test]
    fn retention_removes_what_is_past_the_ttl_and_keeps_what_is_not() {
        let ws = temp_workspace();
        // A TTL of zero makes "older than the TTL" true for anything with a measurable age,
        // which is what lets this test assert the rule without sleeping for a day.
        let s = InboundStaging::open(&ws, Duration::from_secs(0)).expect("staging");
        let old = s.path.join("old.pdf");
        std::fs::write(&old, PDF_BYTES).unwrap();
        // Make its age unambiguous rather than racing the clock's resolution.
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert_eq!(s.sweep(), 1, "an expired file is removed");
        assert!(!old.exists());

        let fresh = InboundStaging::open(&ws, Duration::from_secs(3600)).expect("staging");
        let keep = fresh.path.join("keep.pdf");
        std::fs::write(&keep, PDF_BYTES).unwrap();
        assert_eq!(fresh.sweep(), 0, "a file inside the TTL survives");
        assert!(keep.exists());

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// THE SWEEP MUST NOT BE A DELETE-ANYTHING PRIMITIVE.
    ///
    /// It runs over a directory that a resolver writes into, so if it followed links it would
    /// be reachable deletion of any path a link could name. `symlink_metadata` reads the
    /// LINK's timestamps and `remove_file` unlinks the LINK, so an expired symlink goes and
    /// its target stays.
    #[test]
    fn the_sweep_unlinks_a_symlink_without_touching_what_it_points_at() {
        let ws = temp_workspace();
        let outside = ws.join("precious.txt");
        std::fs::write(&outside, b"do not delete me").unwrap();

        let s = InboundStaging::open(&ws, Duration::from_secs(0)).expect("staging");
        let link = s.path.join("link.pdf");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));

        s.sweep();
        assert!(!link.exists(), "the expired link is unlinked");
        assert!(
            outside.exists(),
            "the sweep must never reach through a link to what it points at"
        );

        // A directory that somehow appears is skipped rather than descended into, for the
        // same reason.
        let sub = s.path.join("someone-elses-dir");
        std::fs::create_dir(&sub).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        s.sweep();
        assert!(sub.exists(), "the sweep is not a tree remover");

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// The staging directory really is inside the scope a child is already granted, and the
    /// belt-and-braces `--add-dir` really is emitted for a READ-capability child too.
    ///
    /// Asserted rather than assumed, which is the whole reason this test exists: `Read` is
    /// scoped to the working directory, so a staged file outside it is refused at the
    /// permission layer and the model narrates around a document it was told it could open.
    #[test]
    fn a_staged_path_is_inside_the_read_scope_a_child_is_granted() {
        let cfg = test_config();
        let dir = cfg.inbound_dir();
        assert!(
            dir.starts_with(&cfg.vault),
            "the staging directory must be under the workspace the read scope names: {dir:?}"
        );
        assert_eq!(dir.file_name().unwrap(), INBOUND_DIR_NAME);

        for capability in [Capability::Read, Capability::Write] {
            let args = build_claude_args(
                &cfg,
                "PROMPT",
                None,
                capability,
                main_mcp_config(&cfg, &ClaudeCode),
                None,
                None,
            );
            let at = args
                .iter()
                .position(|a| a == "--add-dir")
                .unwrap_or_else(|| panic!("{capability:?}: the staging grant must be emitted"));
            assert_eq!(args[at + 1], dir.display().to_string());
        }

        // …and NOT for a child whose MCP set has no `inbound` server to stage with. The grant
        // and the thing that writes there travel together or neither is trustworthy.
        let none = build_claude_args(
            &cfg,
            "PROMPT",
            None,
            Capability::Read,
            EMPTY_MCP_CONFIG,
            None,
            None,
        );
        assert!(
            !none.iter().any(|a| a == "--add-dir"),
            "a child that loads no inbound server gets no staging grant: {none:?}"
        );
    }

    /// A config that will not parse must NOT be read as "inbound is loaded", and a server
    /// whose name merely contains the word must not be either.
    #[test]
    fn the_staging_grant_is_gated_on_a_parsed_server_name_not_a_substring() {
        assert!(mcp_config_loads_inbound(MAIN_CHILD_MCP_CONFIG));
        assert!(!mcp_config_loads_inbound(MESSAGES_BUILD_PLACES_MCP_CONFIG));
        assert!(!mcp_config_loads_inbound(EMPTY_MCP_CONFIG));
        assert!(!mcp_config_loads_inbound("not json at all"));
        assert!(
            !mcp_config_loads_inbound(
                r#"{"mcpServers":{"outbound-inbound-helper":{"type":"stdio","command":"x","args":[]}}}"#
            ),
            "a substring match would hand out a read grant nothing asked for"
        );
    }

    // ---- The prefix check --------------------------------------------------------------

    /// The check that stops a channel's returned path from becoming an arbitrary file read.
    ///
    /// All four cases matter and the last two are the reason `canonicalize` is used rather
    /// than a string comparison: `..` and a symlink both pass a textual `starts_with` and
    /// both fail this.
    #[test]
    fn only_a_path_really_inside_the_media_root_is_accepted() {
        let ws = temp_workspace();
        let root = ws.join("media");
        std::fs::create_dir(&root).unwrap();
        let inside = root.join("ok.pdf");
        std::fs::write(&inside, PDF_BYTES).unwrap();
        let outside = ws.join("secret.pdf");
        std::fs::write(&outside, PDF_BYTES).unwrap();

        assert!(
            path_inside_root(&root, &inside).is_ok(),
            "a file really inside the root is served"
        );

        let dotdot = root.join("../secret.pdf");
        assert!(
            path_inside_root(&root, &dotdot).is_err(),
            "a `..` escape is refused"
        );
        assert!(
            path_inside_root(&root, Path::new("/etc/hosts")).is_err(),
            "an absolute path elsewhere is refused"
        );

        let link = root.join("escape.pdf");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        assert!(
            path_inside_root(&root, &link).is_err(),
            "a symlink out of the root is refused — this is why the check canonicalizes"
        );

        // THE REFUSAL MUST NOT ECHO THE PATH. It is attacker-influenced text heading for a
        // model's context, so the message says what happened and names nothing.
        let msg = path_inside_root(&root, &link).unwrap_err();
        assert!(!msg.contains("secret.pdf"), "{msg}");
        assert!(msg.contains("Nothing was read"), "{msg}");

        let _ = std::fs::remove_dir_all(&ws);
    }

    // ---- The shared gate ---------------------------------------------------------------

    /// The gate is the composer's, reused — so a lying type and an unwhitelisted type are
    /// refused here for the same reason and in the same words they are refused there.
    #[test]
    fn a_staged_document_meets_the_same_gate_a_composer_attachment_does() {
        let ws = temp_workspace();
        let c = client_in(&ws);

        // PDF bytes declared as a PNG — the classic extension/MIME lie.
        let err = c
            .stage_bytes(
                PDF_BYTES.to_vec(),
                "image/png",
                "invoice.pdf",
                "the fixture",
            )
            .unwrap_err();
        assert!(err.contains("does not match"), "{err}");

        // A ZIP is deliberately not on the whitelist, on either path.
        let err = c
            .stage_bytes(
                b"PK\x03\x04 not allowed".to_vec(),
                "application/zip",
                "a.zip",
                "the fixture",
            )
            .unwrap_err();
        assert!(err.contains("unsupported or unrecognized"), "{err}");

        // Nothing was written for either refusal.
        assert_eq!(
            std::fs::read_dir(&c.staging.path).unwrap().count(),
            0,
            "a refused document must leave no file behind"
        );

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// AN IMAGE RIDES THE SAME RAILS AS A DOCUMENT, and that is why there is no second,
    /// narrower path for one. The sniffer and the harness conversion table already cover PNG,
    /// JPEG, GIF, WebP and HEIC; building a PDF-only channel beside them would have meant two
    /// whitelists and two sets of failure messages for the same job.
    #[test]
    fn an_image_stages_through_the_same_path_a_pdf_does() {
        let ws = temp_workspace();
        let c = client_in(&ws);
        let doc = c
            .stage_bytes(
                PNG_BYTES.to_vec(),
                "image/png",
                "scan.png",
                "the WhatsApp attachment",
            )
            .expect("an image is not a special case");
        assert_eq!(doc.mime, "image/png");
        assert_eq!(doc.pages, None, "only a PDF reports pages");
        assert!(doc.path.extension().unwrap() == "png");

        // And it is native on both harnesses, so nothing is converted for it.
        let vision = VisionConfig::default();
        for support in [&CLAUDE_CODE_ATTACHMENTS, &CODEX_ATTACHMENTS] {
            let prepared =
                prepare_staged_document(&vision, &c.staging, &doc, support).expect("prepares");
            assert_eq!(prepared.paths, vec![doc.path.clone()]);
            assert!(prepared.notes.is_empty());
        }

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// The document cap is its own, larger number — and it is enforced.
    ///
    /// The photo cap is untouched, which is the point: a forty-page contract clears it
    /// routinely, and a document refused for being document-sized would be the same silent
    /// failure in a new costume.
    #[test]
    fn the_document_cap_is_larger_than_the_photo_cap_and_is_enforced() {
        let cfg = test_config();
        assert!(
            DEFAULT_MAX_INBOUND_DOCUMENT_BYTES > cfg.max_attachment_bytes,
            "a document cap sized like a photo cap would refuse ordinary contracts"
        );

        let ws = temp_workspace();
        let c = InboundClient::new(InboundConfig {
            workspace: ws.clone(),
            max_document_bytes: 8,
            ..InboundConfig::default()
        })
        .expect("client");
        let err = c
            .stage_bytes(
                PDF_BYTES.to_vec(),
                "application/pdf",
                "big.pdf",
                "the fixture",
            )
            .unwrap_err();
        assert!(err.contains("per-file cap"), "{err}");

        let _ = std::fs::remove_dir_all(&ws);
    }

    // ---- Fastmail (JMAP) ---------------------------------------------------------------

    /// A recorded session response parses into the three fields the resolver needs, and the
    /// account comes from the MAIL capability rather than from whatever is first in the map.
    #[test]
    fn a_jmap_session_parses_and_takes_its_account_from_the_mail_capability() {
        let recorded = r#"{
            "apiUrl": "https://api.fastmail.com/jmap/api/",
            "downloadUrl": "https://api.fastmail.com/jmap/download/{accountId}/{blobId}/{name}?type={type}",
            "uploadUrl": "https://api.fastmail.com/jmap/upload/{accountId}/",
            "primaryAccounts": {
                "urn:ietf:params:jmap:submission": "uSUBMIT",
                "urn:ietf:params:jmap:mail": "u33e5d4f2",
                "urn:ietf:params:jmap:vacationresponse": "uVAC"
            }
        }"#;
        let s = parse_jmap_session(recorded).expect("parses");
        assert_eq!(s.api_url, "https://api.fastmail.com/jmap/api/");
        assert_eq!(
            s.account_id, "u33e5d4f2",
            "the MAIL account, not the first one in the map"
        );

        assert!(
            parse_jmap_session(r#"{"apiUrl":"x","downloadUrl":"y","primaryAccounts":{}}"#).is_err(),
            "a session with no mail account is an error, not a silent empty result"
        );
    }

    /// The `Email/get` response's attachments parse, with the id the fetch takes back.
    #[test]
    fn a_recorded_email_get_yields_its_attachments() {
        let recorded = r#"{
            "methodResponses": [[
                "Email/get",
                {
                    "accountId": "u33e5d4f2",
                    "list": [{
                        "id": "M1234",
                        "subject": "Fattura 2026-08",
                        "attachments": [
                            {"blobId": "Gbb1", "name": "fattura-agosto.pdf", "type": "application/pdf", "size": 84213},
                            {"blobId": "Gbb2", "name": "logo.png", "type": "image/png", "size": 900}
                        ]
                    }]
                },
                "0"
            ]]
        }"#;
        let v: Value = serde_json::from_str(recorded).unwrap();
        let found = jmap_attachments_from_response(&v);
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].id, "Gbb1");
        assert_eq!(found[0].display_name, "fattura-agosto.pdf");
        assert_eq!(found[0].declared_mime, "application/pdf");
        assert_eq!(found[0].bytes, 84213);

        // A message with no attachments is an empty list, not a parse failure — the tool
        // states the emptiness rather than erroring.
        let none: Value = serde_json::from_str(
            r#"{"methodResponses":[["Email/get",{"list":[{"id":"M1"}]},"0"]]}"#,
        )
        .unwrap();
        assert!(jmap_attachments_from_response(&none).is_empty());
    }

    /// The download URL is filled from the template, and the SOURCE'S FILENAME NEVER ENTERS
    /// IT. The `{name}` placeholder only decides a response header, so putting the real name
    /// there would send attacker-controlled text into a URL for no benefit at all.
    #[test]
    fn the_jmap_download_url_carries_ids_and_never_the_source_filename() {
        let url = jmap_download_url(
            "https://api.fastmail.com/jmap/download/{accountId}/{blobId}/{name}?type={type}",
            "u33e5d4f2",
            "Gbb1",
        );
        assert!(url.contains("/u33e5d4f2/"), "{url}");
        assert!(url.contains("/Gbb1/"), "{url}");
        assert!(
            url.ends_with("/download?type=application%2Foctet-stream"),
            "{url}"
        );

        // An id carrying URL syntax is percent-encoded rather than spliced raw.
        let hostile = jmap_download_url("https://x/{accountId}/{blobId}", "a", "../../etc/passwd");
        assert!(
            !hostile.contains("../"),
            "a traversal must not survive into the path: {hostile}"
        );
        assert!(!hostile.contains("/etc/passwd"), "{hostile}");
    }

    /// A staged Fastmail document keeps its randomized on-disk name, and the source filename
    /// survives only as display prose.
    #[test]
    fn a_staged_blob_gets_a_randomized_name_that_does_not_contain_the_sent_one() {
        let ws = temp_workspace();
        let c = client_in(&ws);
        let doc = c
            .stage_bytes(
                PDF_BYTES.to_vec(),
                "application/pdf",
                "fattura-agosto.pdf",
                "the Fastmail attachment",
            )
            .expect("stages");
        let name = doc.path.file_name().unwrap().to_string_lossy().to_string();
        assert!(!name.contains("fattura"), "{name}");
        assert!(name.ends_with(".pdf"), "{name}");
        assert_eq!(doc.display_name, "fattura-agosto.pdf");
        assert_eq!(doc.mime, "application/pdf");
        assert_eq!(doc.bytes, PDF_BYTES.len());

        let _ = std::fs::remove_dir_all(&ws);
    }

    // ---- Gmail -------------------------------------------------------------------------

    /// The part tree is walked, and a part with an attachment id but NO FILENAME is skipped.
    ///
    /// That is not tidiness: an inline signature logo and a tracking pixel both carry
    /// attachment ids, and listing them buries the one file the user actually means.
    #[test]
    fn the_gmail_listing_walks_the_part_tree_and_skips_inline_parts() {
        let msg: Value = serde_json::from_str(
            r#"{
                "id": "18f0",
                "payload": {
                    "mimeType": "multipart/mixed",
                    "parts": [
                        {"mimeType": "text/plain", "filename": "", "body": {"size": 12}},
                        {"mimeType": "multipart/related", "parts": [
                            {"mimeType": "image/png", "filename": "", "body": {"attachmentId": "INLINE", "size": 40}}
                        ]},
                        {"mimeType": "application/pdf", "filename": "invoice.pdf",
                         "body": {"attachmentId": "ANGjd", "size": 51200}}
                    ]
                }
            }"#,
        )
        .unwrap();
        let found = gmail_attachments_from_message(&msg);
        assert_eq!(found.len(), 1, "only the real attachment: {found:?}");
        assert_eq!(found[0].id, "ANGjd");
        assert_eq!(found[0].display_name, "invoice.pdf");
        assert_eq!(found[0].declared_mime, "application/pdf");
        assert_eq!(found[0].bytes, 51200);
    }

    /// Gmail's payload is base64URL and usually unpadded, and it is decoded by translating
    /// into the standard alphabet and handing it to the one decoder this crate has.
    #[test]
    fn base64url_decodes_gmails_alphabet_through_the_shared_decoder() {
        // "%PDF-1.7" in base64url, unpadded.
        assert_eq!(base64url_decode("JVBERi0xLjc").unwrap(), b"%PDF-1.7");
        // The two substituted characters really are handled.
        let raw: Vec<u8> = vec![0xFB, 0xEF, 0xBE];
        let std_form = base64_encode(&raw);
        let url_form: String = std_form
            .chars()
            .map(|c| match c {
                '+' => '-',
                '/' => '_',
                o => o,
            })
            .filter(|c| *c != '=')
            .collect();
        assert!(url_form.contains('-') || url_form.contains('_'));
        assert_eq!(base64url_decode(&url_form).unwrap(), raw);
    }

    /// The credential file's expiry decides whether a refresh runs, and ANYTHING unreadable
    /// counts as expired — refreshing needlessly costs one request, treating a stale token as
    /// fresh costs the fetch.
    #[test]
    fn an_unreadable_or_absent_token_expiry_counts_as_expired() {
        let now = UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        assert!(google_token_expired(None, now));
        assert!(google_token_expired(Some("not a timestamp"), now));
        assert!(google_token_expired(Some("2020-01-01T00:00:00Z"), now));
        assert!(
            !google_token_expired(Some("2100-01-01T00:00:00Z"), now),
            "a token good for another 70 years is not refreshed"
        );
        // The epoch arithmetic itself, against a known value.
        assert_eq!(parse_rfc3339_secs("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            parse_rfc3339_secs("2026-09-04T00:00:00Z"),
            Some(1_788_480_000)
        );
    }

    /// Google's credential cache is READ and never written back, and its per-account file is
    /// resolved by a name that cannot leave the directory.
    #[test]
    fn a_credential_path_refuses_an_account_name_that_could_leave_the_directory() {
        let dir = Path::new("/creds");
        assert_eq!(
            google_credential_path(dir, "jeremy@tag1consulting.com").unwrap(),
            PathBuf::from("/creds/jeremy@tag1consulting.com.json")
        );
        for hostile in ["../../etc/passwd", "a/b", "", "..", "."] {
            assert!(
                google_credential_path(dir, hostile).is_err(),
                "{hostile:?} must be refused"
            );
        }

        let creds = parse_google_credentials(
            r#"{"token":"ya29.x","refresh_token":"1//r","token_uri":"https://oauth2.googleapis.com/token",
                "client_id":"cid","client_secret":"sec","scopes":["gmail.readonly"],
                "expiry":"2026-09-04T09:00:00.000000Z"}"#,
        )
        .expect("parses");
        assert_eq!(creds.refresh_token, "1//r");
        assert_eq!(creds.expiry.as_deref(), Some("2026-09-04T09:00:00.000000Z"));

        // A cache with no refresh token cannot be renewed headlessly, and says so rather than
        // failing later with a bare 401.
        let err = parse_google_credentials(r#"{"token":"ya29.x"}"#).unwrap_err();
        assert!(err.contains("refresh token"), "{err}");
    }

    /// Gmail's ids reach a URL path, so a hostile one is REFUSED rather than escaped: a real
    /// id never trips this, and quietly encoding a hostile one would hide that something odd
    /// arrived.
    #[test]
    fn a_hostile_identifier_is_refused_before_it_reaches_a_url() {
        assert!(url_path_segment("ANGjd9dfj-_x").is_ok());
        for hostile in ["", "a/b", "..", "a?b", "a#b", "a\\b"] {
            assert!(url_path_segment(hostile).is_err(), "{hostile:?}");
        }
    }

    // ---- iMessage ----------------------------------------------------------------------

    /// iMessage refuses on BOTH tools, in the same words, and those words are actionable.
    ///
    /// This is the test for the decision rather than for the code: the channel is not
    /// unimplemented, it is unreachable, and the difference has to survive into what the
    /// model is told. A missing capability teaches a model nothing and it fills the gap with
    /// a plausible summary of a document nobody read — which is the exact failure this whole
    /// module exists to remove.
    #[tokio::test]
    async fn imessage_refuses_on_both_tools_with_words_the_user_can_act_on() {
        let ws = temp_workspace();
        let c = client_in(&ws);
        let args = json!({"channel": "imessage", "message_id": "at_0_ABCD"});

        for err in [
            list_attachments(&c, InboundChannel::IMessage, &args)
                .await
                .unwrap_err(),
            fetch_attachment(&c, InboundChannel::IMessage, &args)
                .await
                .unwrap_err(),
        ] {
            assert_eq!(err, IMESSAGE_UNREACHABLE);
        }

        // The three things every failure on this path owes.
        assert!(
            IMESSAGE_UNREACHABLE.contains("iMessage"),
            "names the channel"
        );
        assert!(
            IMESSAGE_UNREACHABLE.contains("Full Disk Access"),
            "names what is missing"
        );
        assert!(
            IMESSAGE_UNREACHABLE.contains("share the file into this chat"),
            "names the remedy"
        );
        assert!(
            IMESSAGE_UNREACHABLE.contains("Nothing was read"),
            "leaves no room to answer as though it had looked"
        );

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// NOTHING IN THIS MODULE CAN MUTATE A CHANNEL.
    ///
    /// Enumerated from the module's own source rather than asserted in prose, so a public
    /// function that could send, delete, mark read or label is a TEST FAILURE rather than
    /// something a reviewer has to notice. The allowlist is exact for the same reason the
    /// iMCP tool grant is: a denylist of verbs would only ever catch the ones somebody
    /// thought to write down, and the point is to fail on anything new.
    #[test]
    fn no_public_function_in_this_module_can_mutate_a_channel() {
        const SOURCE: &str = include_str!("inbound.rs");
        let mut found: Vec<String> = Vec::new();
        for line in SOURCE.lines() {
            let t = line.trim_start();
            for prefix in ["pub fn ", "pub async fn "] {
                if let Some(rest) = t.strip_prefix(prefix) {
                    let name: String = rest
                        .chars()
                        .take_while(|c| c.is_alphanumeric() || *c == '_')
                        .collect();
                    found.push(name);
                }
            }
        }
        // Every public function this module has, and every one of them reads, parses,
        // validates, stages or refuses. Adding a name here is the deliberate act.
        let mut expected = vec![
            "inbound_ttl",
            "open_inbound_staging",
            "open",
            "stage",
            "sweep",
            "parse",
            "label",
            "from_env",
            "path_inside_root",
            "new",
            "pdf_page_count",
            "fetch_whatsapp",
            "parse_google_credentials",
            "google_credential_path",
            "base64url_decode",
            "google_token_expired",
            "parse_rfc3339_secs",
            "gmail_attachments_from_message",
            "list_gmail_attachments",
            "fetch_gmail",
            "url_path_segment",
            "parse_jmap_session",
            "jmap_download_url",
            "jmap_attachments_from_response",
            "list_fastmail_attachments",
            "fetch_fastmail",
            "list_attachments",
            "fetch_attachment",
            "prepare_staged_document",
            "staged_prompt_fragment",
            "sanitize_display_name",
            "attachment_support_for",
            "tool_name",
            "description",
            "input_schema",
            "run_inbound_tool",
        ];
        expected.sort_unstable();
        let mut found_sorted: Vec<&str> = found.iter().map(|s| s.as_str()).collect();
        found_sorted.sort_unstable();
        found_sorted.dedup();
        expected.dedup();
        assert_eq!(
            found_sorted, expected,
            "the module's public surface changed — every function here must READ, and a new \
             one that sends, deletes, marks read or labels must never pass silently"
        );
        for name in &found {
            // Specific enough to name a channel mutation and nothing else: `label` alone
            // would fire on `InboundChannel::label`, which returns a display string.
            for verb in [
                "send",
                "delete",
                "remove_message",
                "mark_read",
                "mark_seen",
                "archive_",
                "add_label",
                "set_label",
                "reply",
                "forward",
                "trash",
                "spam",
                "move_",
                "update_",
                "write_message",
            ] {
                assert!(
                    !name.contains(verb),
                    "a public function named {name:?} looks like a mutation"
                );
            }
        }
    }

    // ---- Piece 3: reaching the model ---------------------------------------------------

    /// A staged PDF goes to Claude Code WHOLE and to a harness that cannot read one as page
    /// images — the same per-harness split the composer path already makes, because it is
    /// literally the same function doing it.
    #[test]
    #[cfg(target_os = "macos")]
    fn a_staged_pdf_is_native_on_claude_code_and_rasterized_for_a_harness_that_cannot_read_one() {
        let ws = temp_workspace();
        let c = client_in(&ws);
        let vision = VisionConfig::default();
        let bytes = read_fixture("fixtures/statement.pdf");

        let doc = c
            .stage_bytes(bytes, "application/pdf", "statement.pdf", "the fixture")
            .expect("stages");
        assert_eq!(doc.pages, Some(1), "a PDF reports its page count");

        let native = prepare_staged_document(&vision, &c.staging, &doc, &CLAUDE_CODE_ATTACHMENTS)
            .expect("claude code takes a PDF as-is");
        assert_eq!(native.paths, vec![doc.path.clone()]);
        assert!(native.notes.is_empty());

        let rasterized = prepare_staged_document(&vision, &c.staging, &doc, &CODEX_ATTACHMENTS)
            .expect("a harness that cannot read a PDF gets pages");
        assert_eq!(rasterized.paths.len(), 1, "one page in, one page out");
        assert!(rasterized.paths[0].extension().unwrap() == "png");
        // The derived page lands in the STAGING dir, so it is swept on the same TTL as the
        // document it came from rather than living forever beside it.
        assert!(rasterized.paths[0].starts_with(&c.staging.path));

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// THE PAGE-CAP NOTE REACHES THE CALLER. A forty-page contract of which the model saw
    /// twelve produces an answer that is right about twelve pages and silent about the rest,
    /// which is the family of failure this module exists to remove.
    #[test]
    #[cfg(target_os = "macos")]
    fn a_truncated_pdf_carries_its_note_out_to_the_caller() {
        let ws = temp_workspace();
        let c = client_in(&ws);
        let bytes = read_fixture("fixtures/multipage.pdf");
        let doc = c
            .stage_bytes(bytes, "application/pdf", "contract.pdf", "the fixture")
            .expect("stages");
        assert!(doc.pages.unwrap_or(0) > 1, "the fixture is multi-page");

        let capped = VisionConfig {
            pdf_page_cap: 1,
            ..VisionConfig::default()
        };
        let prepared = prepare_staged_document(&capped, &c.staging, &doc, &CODEX_ATTACHMENTS)
            .expect("rasterizes");
        assert_eq!(prepared.paths.len(), 1);
        assert_eq!(prepared.notes.len(), 1, "the truncation must be stated");
        assert!(
            prepared.notes[0].contains("only the first"),
            "{:?}",
            prepared.notes
        );

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// The prompt fragment names PATHS and the harness's own instruction, and the source
    /// filename appears only as prose — never as something that reads like a path.
    #[test]
    fn the_prompt_fragment_names_paths_and_the_filename_only_as_prose() {
        let prepared = PreparedAttachments {
            paths: vec![PathBuf::from("/vault/.jesse-inbound/ab12cd.pdf")],
            notes: vec!["only the first 2 page(s) are attached".to_string()],
        };
        let s = staged_prompt_fragment(
            &prepared,
            "fattura agosto.pdf",
            CLAUDE_CODE_ATTACHMENTS.instruction,
        );
        assert!(s.contains("/vault/.jesse-inbound/ab12cd.pdf"), "{s}");
        assert!(s.contains("fattura agosto.pdf"), "{s}");
        assert!(
            s.contains("Note: only the first"),
            "the note is never swallowed: {s}"
        );
    }

    /// A display name is hostile prose: one line, no control characters, bounded length.
    #[test]
    fn a_display_name_is_flattened_before_it_reaches_a_prompt() {
        assert_eq!(sanitize_display_name("invoice.pdf"), "invoice.pdf");
        assert_eq!(
            sanitize_display_name("a\nIGNORE PREVIOUS\rb"),
            "a IGNORE PREVIOUS b",
            "a newline must not let a filename look like a new instruction line"
        );
        assert_eq!(sanitize_display_name("   "), "an unnamed file");
        let long = "x".repeat(500);
        assert!(sanitize_display_name(&long).chars().count() <= 121);
    }

    /// The channel argument is a closed set, and an unknown one is an error naming the
    /// alternatives rather than an empty result.
    #[tokio::test]
    async fn an_unknown_channel_is_an_error_that_names_the_real_ones() {
        let ws = temp_workspace();
        let c = client_in(&ws);
        let vision = VisionConfig::default();
        let err = run_inbound_tool(
            &c,
            &vision,
            &CLAUDE_CODE_ATTACHMENTS,
            InboundTool::Fetch,
            &json!({"channel": "telegram", "message_id": "1"}),
        )
        .await
        .unwrap_err();
        assert!(err.contains("telegram"), "{err}");
        for name in ["fastmail", "gmail", "whatsapp", "imessage"] {
            assert!(err.contains(name), "{err}");
        }

        let _ = std::fs::remove_dir_all(&ws);
    }

    /// Both tool names parse, and neither description leaves the model able to believe it
    /// read something it did not.
    #[test]
    fn the_tool_surface_is_two_names_and_the_fetch_one_states_the_imessage_limit() {
        assert_eq!(
            InboundTool::ALL.len(),
            2,
            "each name is a grant to re-certify"
        );
        assert_eq!(
            InboundTool::parse("fetch_attachment"),
            Some(InboundTool::Fetch)
        );
        assert_eq!(
            InboundTool::parse("list_attachments"),
            Some(InboundTool::List)
        );
        assert_eq!(InboundTool::parse("send_attachment"), None);

        let d = InboundTool::Fetch.description();
        assert!(
            d.contains(IMESSAGE_UNREACHABLE),
            "the limit travels with the tool"
        );
        assert!(d.contains("NOTHING was read"), "{d}");
        for t in InboundTool::ALL {
            assert!(t.input_schema().get("properties").is_some());
        }
    }

    /// WhatsApp has no listing of its own, and says which tools to use instead rather than
    /// answering with an empty list that reads as "there is nothing there".
    #[tokio::test]
    async fn whatsapp_has_no_listing_and_points_at_the_tools_that_do() {
        let ws = temp_workspace();
        let c = client_in(&ws);
        let err = list_attachments(&c, InboundChannel::WhatsApp, &json!({"message_id": "3EB0"}))
            .await
            .unwrap_err();
        assert!(err.contains("list_messages"), "{err}");

        // And a fetch with no configured media root refuses rather than reading whatever path
        // it is handed.
        let err = fetch_whatsapp(&c, "3EB0", "39333@s.whatsapp.net")
            .await
            .unwrap_err();
        assert!(err.contains("whatsapp:"), "{err}");

        let _ = std::fs::remove_dir_all(&ws);
    }
}
