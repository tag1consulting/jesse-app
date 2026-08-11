use crate::*;

/// One inbound attachment: a base64 blob with a client-declared name and MIME.
/// All three fields are untrusted — the filename is never used as an on-disk
/// name (path traversal), and the MIME is cross-checked against a magic-byte
/// sniff (see `validate_and_decode_attachments`) rather than believed.
#[derive(Deserialize)]
pub struct Attachment {
    #[allow(dead_code)] // accepted for forward-compat; on-disk names are randomized
    #[serde(default)]
    pub filename: String,
    pub mime: String,
    pub data_base64: String,
}

// ---- Attachments ----------------------------------------------------------
//
// New file-input attack surface, so everything here is defensive: the body is
// size-bounded before it's buffered (`attachment_body_limit`), each blob is
// decoded and its real type sniffed from magic bytes and cross-checked against
// a MIME whitelist, the client filename is never used on disk, files land in a
// per-request 0700 scratch dir with randomized 0600 names, and that dir is
// removed by a Drop guard on every exit path (success, error, timeout).

/// Decode standard (RFC 4648) base64. Tolerates ASCII whitespace between
/// groups; rejects any other invalid character, data after padding, over-long
/// padding, or a truncated final group. Hand-rolled to keep the bridge
/// dependency-light — the magic-byte sniff downstream is the real content gate,
/// so this only has to be correct, not trusting.
pub fn base64_decode(s: &str) -> Result<Vec<u8>, &'static str> {
    pub fn sextet(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(s.len() / 4 * 3 + 3);
    let mut quad = [0u8; 4];
    let mut n = 0usize; // sextets buffered in `quad` (data or padding slots)
    let mut pad = 0usize; // '=' seen in the current group
    let mut done = false; // a full padded group ended the stream
    for &c in s.as_bytes() {
        if matches!(c, b'\n' | b'\r' | b' ' | b'\t') {
            continue;
        }
        if done {
            return Err("base64: trailing data after padding");
        }
        if c == b'=' {
            quad[n] = 0;
            n += 1;
            pad += 1;
        } else if pad > 0 {
            return Err("base64: data after padding");
        } else {
            match sextet(c) {
                Some(v) => {
                    quad[n] = v;
                    n += 1;
                }
                None => return Err("base64: invalid character"),
            }
        }
        if n == 4 {
            if pad > 2 {
                return Err("base64: over-long padding");
            }
            out.push((quad[0] << 2) | (quad[1] >> 4));
            if pad < 2 {
                out.push((quad[1] << 4) | (quad[2] >> 2));
            }
            if pad < 1 {
                out.push((quad[2] << 6) | quad[3]);
            }
            if pad > 0 {
                done = true;
            }
            n = 0;
            pad = 0;
        }
    }
    if n != 0 {
        return Err("base64: truncated group (length not a multiple of 4)");
    }
    Ok(out)
}

/// Encode bytes to standard (RFC 4648) base64 with padding — the inverse of
/// [`base64_decode`]. Used by the vision layer to inline an image as a base64 data
/// part in the Anthropic `/v1/messages` body. Hand-rolled for the same reason the
/// decoder is: keep the bridge dependency-light (no base64 crate). No line wrapping —
/// the Anthropic surface accepts one unbroken string.
pub fn base64_encode(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0];
        let b1 = *chunk.get(1).unwrap_or(&0);
        let b2 = *chunk.get(2).unwrap_or(&0);
        out.push(T[(b0 >> 2) as usize] as char);
        out.push(T[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 {
            T[(((b1 & 0x0F) << 2) | (b2 >> 6)) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            T[(b2 & 0x3F) as usize] as char
        } else {
            '='
        });
    }
    out
}

/// Sniff the real content type from leading bytes. Returns `(canonical_mime,
/// on_disk_extension)` for whitelisted types only, or `None` for anything
/// unrecognized. This — not the client's declared MIME — decides what a file is.
pub fn sniff_attachment(b: &[u8]) -> Option<(&'static str, &'static str)> {
    if b.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        return Some(("image/png", "png"));
    }
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some(("image/jpeg", "jpg"));
    }
    if b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a") {
        return Some(("image/gif", "gif"));
    }
    if b.starts_with(b"%PDF-") {
        return Some(("application/pdf", "pdf"));
    }
    if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        return Some(("image/webp", "webp"));
    }
    // HEIC/HEIF: an ISO-BMFF `ftyp` box carrying a HEIF-family major brand.
    if b.len() >= 12 && &b[4..8] == b"ftyp" {
        let brand: &[u8] = &b[8..12];
        const HEIF_BRANDS: [&[u8]; 8] = [
            b"heic", b"heix", b"hevc", b"hevx", b"heim", b"heis", b"mif1", b"msf1",
        ];
        if HEIF_BRANDS.contains(&brand) {
            return Some(("image/heic", "heic"));
        }
    }
    None
}

/// Normalize a client-declared MIME for comparison: lowercased, parameters
/// (`; charset=…`) stripped, and the common `image/jpg` spelling folded to the
/// canonical `image/jpeg`.
pub fn normalize_mime(m: &str) -> String {
    let base = m
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    if base == "image/jpg" {
        "image/jpeg".to_string()
    } else {
        base
    }
}

/// A decoded, validated attachment ready to write: raw bytes plus the canonical
/// extension chosen from the sniffed type.
#[derive(Debug)]
pub struct DecodedAttachment {
    pub bytes: Vec<u8>,
    pub ext: &'static str,
}

/// Decode and validate every attachment, enforcing the count / per-file / total
/// caps and the MIME-whitelist-plus-magic-byte-match rule. Any failure is a
/// `400` — bad input, never a server fault. Nothing is written to disk here.
pub fn validate_and_decode_attachments(
    cfg: &Config,
    atts: &[Attachment],
) -> Result<Vec<DecodedAttachment>, ApiError> {
    if atts.len() > cfg.max_attachments {
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "too many attachments: {} (max {})",
                atts.len(),
                cfg.max_attachments
            ),
        ));
    }
    let mut decoded = Vec::with_capacity(atts.len());
    let mut total = 0usize;
    for (i, a) in atts.iter().enumerate() {
        let label = i + 1;
        // Reject before decoding if the base64 length alone already implies an
        // over-cap file (4 base64 chars per 3 bytes); avoids decoding a blob we
        // would only throw away.
        if base64_decoded_len_bound(a.data_base64.len()) > cfg.max_attachment_bytes {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "attachment {label} exceeds the per-file cap of {} bytes",
                    cfg.max_attachment_bytes
                ),
            ));
        }
        let bytes = base64_decode(&a.data_base64)
            .map_err(|e| (StatusCode::BAD_REQUEST, format!("attachment {label}: {e}")))?;
        if bytes.is_empty() {
            return Err((
                StatusCode::BAD_REQUEST,
                format!("attachment {label} is empty"),
            ));
        }
        if bytes.len() > cfg.max_attachment_bytes {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "attachment {label} is {} bytes (per-file cap {})",
                    bytes.len(),
                    cfg.max_attachment_bytes
                ),
            ));
        }
        let (sniffed, ext) = sniff_attachment(&bytes).ok_or((
            StatusCode::BAD_REQUEST,
            format!("attachment {label}: unsupported or unrecognized file type"),
        ))?;
        let claimed = normalize_mime(&a.mime);
        if claimed != sniffed {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "attachment {label}: declared type {:?} does not match detected type {:?}",
                    a.mime, sniffed
                ),
            ));
        }
        total += bytes.len();
        if total > cfg.max_attachments_total_bytes {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "attachments exceed the combined cap of {} bytes",
                    cfg.max_attachments_total_bytes
                ),
            ));
        }
        decoded.push(DecodedAttachment { bytes, ext });
    }
    Ok(decoded)
}

/// Exact base64-ENCODED length of `decoded_len` raw bytes, including padding:
/// each 3-byte group becomes 4 chars, and a partial final group is padded up to
/// 4. Used to size the request body limit so the base64-inflated payload fits.
pub fn base64_encoded_len(decoded_len: usize) -> usize {
    decoded_len.div_ceil(3) * 4
}

/// Upper bound on the DECODED byte count implied by an `encoded_len`-char base64
/// string (4 chars decode to at most 3 bytes). Used to reject an over-cap
/// attachment from its declared base64 length before spending work decoding it.
/// Both directions of the 4:3 inflation live here, so the two call sites (the
/// per-file pre-check and the body-limit sizing) can never derive it differently.
pub fn base64_decoded_len_bound(encoded_len: usize) -> usize {
    encoded_len / 4 * 3
}

/// Max request body axum will buffer for `/jesse`. Sized to the total decoded
/// attachment cap inflated for base64 (4/3) plus headroom for the JSON envelope
/// and prompt text. This is the outermost bound on memory per request.
pub fn attachment_body_limit(cfg: &Config) -> usize {
    base64_encoded_len(cfg.max_attachments_total_bytes) + 256 * 1024
}

/// WHICH OF TWO MUTUALLY EXCLUSIVE ROUTES this turn's attachments take.
///
/// There are exactly two ways an attachment reaches a model, and a turn takes ONE. Stated
/// as a type rather than left as a chain of `if`s because the failure mode of getting it
/// wrong is silent and expensive: wire both and the image is transcribed by the helper AND
/// written to disk for the child, so the model is sent the same picture twice, pays for it
/// twice, and may describe it twice.
///
/// The order below is the decision order, and it is not arbitrary. [`Self::VisionHelper`]
/// is tried first because it is the route for a model that CANNOT read an image at all —
/// a text-only model with a resolving vision partner. Only a model that can see for itself
/// falls through to [`Self::ChildReadsFiles`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentRoute {
    /// No attachments on this turn. No scratch dir, no prompt suffix, no read grant —
    /// byte-for-byte an ordinary turn, which is nearly all of them.
    None,
    /// The BRIDGE reads the images and hands the model text. The decoded bytes ride into
    /// the turn task and are transcribed by the resolving vision partner; nothing is
    /// written to disk, so there is no directory for a child to be granted.
    VisionHelper,
    /// THE CHILD reads the files itself. The bytes are written to a per-request scratch
    /// dir, their paths are named in the prompt, and the harness is told where they are
    /// (Claude Code needs `--add-dir`; Codex's sandbox already permits the read).
    ChildReadsFiles,
}

/// Decide the route. Pure, so the exclusivity is a property the tests can hold rather than
/// a shape a reader has to re-derive from the handler.
///
/// `vision_resolves` must mean RESOLVABLE, not merely configured: a model paired with a
/// broken helper falls through to the child-reads-files route rather than dropping the
/// attachment on the floor.
pub fn attachment_route(has_attachments: bool, vision_resolves: bool) -> AttachmentRoute {
    match (has_attachments, vision_resolves) {
        (false, _) => AttachmentRoute::None,
        (true, true) => AttachmentRoute::VisionHelper,
        (true, false) => AttachmentRoute::ChildReadsFiles,
    }
}

/// A per-request scratch directory under `base` (the system temp dir by
/// default, or `JESSE_SCRATCH_DIR`) — NOT the vault, so attachments never
/// pollute it. Removed by `Drop` on every exit path — success, error, or
/// timeout — so decoded files never outlive the turn.
///
/// THIS DIRECTORY IS OUTSIDE THE CLAUDE CODE CHILD'S READ SCOPE, and the turn must
/// hand it over explicitly. This comment used to claim the opposite — "verified that
/// headless `claude` reads paths here via its Read tool with no `--add-dir`" — which
/// was true when it was written and was made false by the 2026-07-29 scoping change
/// (`Read` → `Read(./**)`, commit 98ad92e). Between those two dates every attachment
/// read on this harness was refused at the permission layer. The turn now passes the
/// path as [`TurnRequest::attachment_dir`] and the Claude Code builder emits
/// `--add-dir`; Codex's OS sandbox leaves reads broad and needs nothing.
pub struct ScratchDir {
    pub path: PathBuf,
}

impl ScratchDir {
    pub fn create(base: &Path) -> std::io::Result<ScratchDir> {
        let path = base.join(format!("jesse-attach-{}", random_hex()));
        std::fs::DirBuilder::new()
            .recursive(false)
            .mode(0o700)
            .create(&path)?;
        Ok(ScratchDir { path })
    }

    /// Write each decoded attachment under a randomized, sniffed-extension name
    /// (the client filename is deliberately ignored) and return the on-disk
    /// paths to name in the prompt.
    pub fn write_all(&self, decoded: &[DecodedAttachment]) -> std::io::Result<Vec<PathBuf>> {
        let mut paths = Vec::with_capacity(decoded.len());
        for (i, d) in decoded.iter().enumerate() {
            let p = self
                .path
                .join(format!("{:02}-{}.{}", i + 1, random_hex(), d.ext));
            let mut f = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&p)?;
            f.write_all(&d.bytes)?;
            paths.push(p);
        }
        Ok(paths)
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

/// WHAT A HARNESS'S OWN ATTACHMENT TOOL CAN ACTUALLY TAKE, and what to tell its model.
///
/// The two harnesses reach an attachment by different tools with different appetites, and
/// a prompt fragment that names the wrong one is worse than none: it sends the model
/// looking for a tool it does not have. So the fragment and the format list travel
/// together, behind [`Harness::attachment_support`], and the bridge's job is to convert
/// anything the serving harness cannot take into something it can.
///
/// Both lists are MEASURED, not read off documentation. See the per-harness constants.
pub struct AttachmentSupport {
    /// On-disk extensions this harness's attachment tool renders as an IMAGE (or, for
    /// Claude Code, as a document). Anything else must be converted before the path is
    /// named in the prompt, or the turn fails loudly.
    pub native: &'static [&'static str],
    /// The sentence that tells this harness's model how to reach the files. Named
    /// per harness because the tool is: Claude Code has `Read`, Codex has `view_image`.
    pub instruction: &'static str,
}

impl AttachmentSupport {
    /// Whether a file with this sniffed extension can be handed over as-is.
    pub fn takes(&self, ext: &str) -> bool {
        self.native.contains(&ext)
    }
}

/// This turn's attachments, converted where the serving harness needed it: the paths to
/// NAME IN THE PROMPT, plus any note the user must see about what was dropped.
#[derive(Debug)]
pub struct PreparedAttachments {
    pub paths: Vec<PathBuf>,
    /// Human-readable notes appended to the prompt fragment — today only PDF page-cap
    /// truncation. Never silent: a dropped page the user is not told about is a wrong
    /// answer they have no way to detect.
    pub notes: Vec<String>,
}

/// Convert this turn's written attachments into files the SERVING HARNESS can actually
/// read, in place in the same per-request scratch dir so the existing `Drop` covers every
/// byte written here.
///
/// # Why this exists at all
///
/// The permission fix alone leaves a second, quieter defect: a file can be perfectly
/// readable and still not become an IMAGE. Both harnesses dispatch on what the file is, and
/// both have a hole, measured on the installed binaries:
///
/// * **HEIC fails on BOTH.** claude 2.1.223 returned a `.heic` holding valid image bytes as
///   raw binary rather than as an image. codex-cli 0.146.0's `view_image` refused it with
///   "image content omitted because it could not be processed". This is the common case,
///   not an exotic one: a photo straight from the iOS camera roll is HEIC, and the composer
///   uploads a picked photo's own bytes verbatim — only the over-cap path re-encodes.
/// * **PDF fails on Codex only.** claude 2.1.223 read a PDF directly with `Read`, unprompted.
///   Codex never called `view_image` for one at all: it went straight to the shell
///   (`pdftotext`, absent; then `strings`; then a hand-rolled zlib inflate through `python3`)
///   and only got the text because the fixture had a text layer and an interpreter happened
///   to be on PATH. That is not a route, so a PDF is rasterized for Codex.
///
/// # Conversions
///
/// HEIC → JPEG through `sips`, which ships with macOS: no new dependency, no supply chain,
/// and it runs in the BRIDGE process rather than in a sandboxed child. A decoding library
/// would mean adding a HEIF decoder (the `image` crate has none), which is a native codec
/// on the attachment attack surface — the wrong trade for one format macOS already decodes.
///
/// PDF → PNG pages through [`vision::rasterize_pdf`], the rasterizer that is already here,
/// honouring `JESSE_VISION_PDF_DPI` and `JESSE_VISION_PDF_PAGE_CAP` and carrying the same
/// truncation note. A second rasterizer would be a second set of page/DPI semantics to keep
/// in step.
///
/// # No viable route fails LOUDLY
///
/// A silent drop is the failure this whole change exists to eliminate, so an attachment
/// that cannot be converted returns an error naming the type and what to do about it —
/// never a turn that quietly proceeds as if the user had sent nothing.
pub fn prepare_attachments_for_harness(
    cfg: &Config,
    scratch: &ScratchDir,
    paths: &[PathBuf],
    support: &AttachmentSupport,
) -> Result<PreparedAttachments, ApiError> {
    let mut out = Vec::with_capacity(paths.len());
    let mut notes = Vec::new();
    for (i, p) in paths.iter().enumerate() {
        let label = i + 1;
        let ext = p
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        if support.takes(&ext) {
            out.push(p.clone());
            continue;
        }
        match ext.as_str() {
            "heic" => {
                let jpg = scratch
                    .path
                    .join(format!("{label:02}-{}.jpg", random_hex()));
                convert_heic_to_jpeg(p, &jpg).map_err(|e| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        format!(
                            "attachment {label}: could not convert the HEIC photo to JPEG ({e}). \
                             The model cannot read HEIC on either harness, so the photo would \
                             have been silently dropped. `sips` ships with macOS — check it is \
                             on the bridge's PATH."
                        ),
                    )
                })?;
                // The original is not named in the prompt once a converted file exists;
                // it stays on disk only until the scratch dir's `Drop` removes it.
                out.push(jpg);
            }
            "pdf" => {
                let bytes = std::fs::read(p).map_err(|e| {
                    (
                        StatusCode::INTERNAL_SERVER_ERROR,
                        format!("attachment {label}: could not re-read the PDF ({e})"),
                    )
                })?;
                let r = vision::rasterize_pdf(&bytes, cfg.vision.pdf_dpi, cfg.vision.pdf_page_cap)
                    .map_err(|e| {
                        (
                            StatusCode::INTERNAL_SERVER_ERROR,
                            format!(
                                "attachment {label}: this harness cannot read a PDF directly, so \
                                 the bridge must rasterize it, and that failed ({e}). Send the \
                                 pages as images, or ask on a Claude Code model, whose Read tool \
                                 takes a PDF as-is."
                            ),
                        )
                    })?;
                for (n, page) in r.pages.iter().enumerate() {
                    let png =
                        scratch
                            .path
                            .join(format!("{label:02}-p{:02}-{}.png", n + 1, random_hex()));
                    write_scratch_file(&png, page).map_err(|e| {
                        (
                            StatusCode::INTERNAL_SERVER_ERROR,
                            format!(
                                "attachment {label}: could not write PDF page {} ({e})",
                                n + 1
                            ),
                        )
                    })?;
                    out.push(png);
                }
                if r.truncated {
                    notes.push(format!(
                        "attachment {label} is a {}-page PDF; only the first {} page(s) are \
                         attached as images",
                        r.total_pages,
                        r.pages.len()
                    ));
                }
            }
            other => {
                // Unreachable while the sniff whitelist and the native lists agree, which is
                // exactly what the per-type tests hold. If they ever drift, this is the loud
                // failure rather than an attachment that vanishes.
                return Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    format!(
                        "attachment {label}: no way to show a {other:?} file to this model, and \
                         the bridge knows no conversion for it — the file was NOT sent. Convert \
                         it to a PNG or JPEG and attach that."
                    ),
                ));
            }
        }
    }
    Ok(PreparedAttachments { paths: out, notes })
}

/// Transcode a HEIC to JPEG with macOS's own `sips`. Separate so the test for it names the
/// tool it is really exercising.
fn convert_heic_to_jpeg(src: &Path, dst: &Path) -> Result<(), String> {
    let out = std::process::Command::new("/usr/bin/sips")
        .args(["-s", "format", "jpeg"])
        .arg(src)
        .arg("--out")
        .arg(dst)
        .output()
        .map_err(|e| format!("could not run sips: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "sips exited {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    // `sips` can exit 0 having written nothing useful; the file is the proof.
    match std::fs::metadata(dst) {
        Ok(m) if m.len() > 0 => Ok(()),
        _ => Err("sips wrote no output file".to_string()),
    }
}

/// Write one derived file into the scratch dir with the same 0600 posture `write_all` uses.
fn write_scratch_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(bytes)
}

/// The prompt fragment that points the agent at the written attachment paths.
/// Names the on-disk paths only (never the untrusted client filename) so a
/// crafted filename can't ride into the prompt.
///
/// `instruction` is the SERVING HARNESS's own, from [`AttachmentSupport`]. This fragment
/// used to tell every model to "read them with the Read tool", which is right for Claude
/// Code and wrong for Codex, whose route is `view_image` and which has no `Read` tool at
/// all. One fragment, harness-parameterised — not two fragments to keep in step.
pub fn attachment_prompt_suffix(prepared: &PreparedAttachments, instruction: &str) -> String {
    let list = prepared
        .paths
        .iter()
        .map(|p| p.display().to_string())
        .collect::<Vec<_>>()
        .join(", ");
    let mut s = format!(
        "\n\n(The user attached {} file(s) with this message, saved at these \
         path(s) — {instruction} Paths: {list}",
        prepared.paths.len()
    );
    for n in &prepared.notes {
        s.push_str(&format!(". Note: {n}"));
    }
    s.push(')');
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;
    /// A standalone base64 *encoder* used only by the tests, so the decoder is
    /// exercised against an independent implementation rather than itself.
    fn b64(data: &[u8]) -> String {
        const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in data.chunks(3) {
            let b0 = chunk[0];
            let b1 = *chunk.get(1).unwrap_or(&0);
            let b2 = *chunk.get(2).unwrap_or(&0);
            out.push(T[(b0 >> 2) as usize] as char);
            out.push(T[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            out.push(if chunk.len() > 1 {
                T[(((b1 & 0x0F) << 2) | (b2 >> 6)) as usize] as char
            } else {
                '='
            });
            out.push(if chunk.len() > 2 {
                T[(b2 & 0x3F) as usize] as char
            } else {
                '='
            });
        }
        out
    }
    const PNG_BYTES: &[u8] = &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
    const JPEG_BYTES: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F'];
    const PDF_BYTES: &[u8] = b"%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj\n";
    const GIF_BYTES: &[u8] = b"GIF89a\x01\x00\x01\x00\x00\x00\x00";
    const WEBP_BYTES: &[u8] = b"RIFF\x24\x00\x00\x00WEBPVP8 ";
    const HEIC_BYTES: &[u8] = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00";
    #[test]
    fn base64_round_trips_against_independent_encoder() {
        // Cover all three tail lengths (0/1/2 trailing bytes) plus all byte values.
        for len in [0usize, 1, 2, 3, 4, 5, 6, 255, 256, 257] {
            let data: Vec<u8> = (0..len).map(|i| (i * 7 % 256) as u8).collect();
            let enc = b64(&data);
            let dec = base64_decode(&enc).expect("valid base64 decodes");
            assert_eq!(dec, data, "round trip failed at len {len}");
        }
        // Known vectors.
        assert_eq!(base64_decode("TWFu").unwrap(), b"Man");
        assert_eq!(base64_decode("TWE=").unwrap(), b"Ma");
        assert_eq!(base64_decode("TQ==").unwrap(), b"M");
        // Whitespace between groups is tolerated.
        assert_eq!(base64_decode("TW\nFu").unwrap(), b"Man");
    }
    #[test]
    fn base64_rejects_malformed_input() {
        assert!(base64_decode("TWF").is_err(), "truncated group");
        assert!(base64_decode("****").is_err(), "invalid character");
        assert!(
            base64_decode("TQ==X").is_err(),
            "trailing data after padding"
        );
        assert!(
            base64_decode("T=Fu").is_err(),
            "data after padding mid-group"
        );
        assert!(base64_decode("====").is_err(), "over-long padding");
    }
    #[test]
    fn sniff_identifies_whitelisted_types() {
        assert_eq!(sniff_attachment(PNG_BYTES), Some(("image/png", "png")));
        assert_eq!(sniff_attachment(JPEG_BYTES), Some(("image/jpeg", "jpg")));
        assert_eq!(
            sniff_attachment(PDF_BYTES),
            Some(("application/pdf", "pdf"))
        );
        assert_eq!(sniff_attachment(GIF_BYTES), Some(("image/gif", "gif")));
        assert_eq!(sniff_attachment(WEBP_BYTES), Some(("image/webp", "webp")));
        assert_eq!(sniff_attachment(HEIC_BYTES), Some(("image/heic", "heic")));
    }
    #[test]
    fn sniff_rejects_unknown_and_short_input() {
        assert_eq!(sniff_attachment(b"not a real file"), None);
        assert_eq!(sniff_attachment(b""), None);
        assert_eq!(sniff_attachment(&[0xFF, 0xD8]), None); // too short for JPEG
                                                           // A ZIP/Office doc is deliberately NOT on the whitelist.
        assert_eq!(sniff_attachment(b"PK\x03\x04"), None);
    }
    #[test]
    fn normalize_mime_folds_jpg_and_strips_params() {
        assert_eq!(normalize_mime("image/jpg"), "image/jpeg");
        assert_eq!(normalize_mime("IMAGE/PNG"), "image/png");
        assert_eq!(
            normalize_mime("application/pdf; charset=binary"),
            "application/pdf"
        );
    }
    #[test]
    fn validate_accepts_well_formed_attachments() {
        let cfg = test_config();
        let atts = vec![
            Attachment {
                filename: "shot.png".into(),
                mime: "image/png".into(),
                data_base64: b64(PNG_BYTES),
            },
            Attachment {
                filename: "doc.pdf".into(),
                mime: "application/pdf".into(),
                data_base64: b64(PDF_BYTES),
            },
        ];
        let decoded = validate_and_decode_attachments(&cfg, &atts).expect("valid");
        assert_eq!(decoded.len(), 2);
        assert_eq!(decoded[0].ext, "png");
        assert_eq!(decoded[1].ext, "pdf");
        assert_eq!(decoded[0].bytes, PNG_BYTES);
    }
    #[test]
    fn validate_rejects_mime_magic_mismatch() {
        let cfg = test_config();
        // PDF bytes declared as a PNG — the classic extension/MIME lie.
        let atts = vec![Attachment {
            filename: "evil.png".into(),
            mime: "image/png".into(),
            data_base64: b64(PDF_BYTES),
        }];
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("does not match"));
    }
    #[test]
    fn validate_rejects_unknown_type() {
        let cfg = test_config();
        let atts = vec![Attachment {
            filename: "a.bin".into(),
            mime: "application/octet-stream".into(),
            data_base64: b64(b"PK\x03\x04 zip not allowed"),
        }];
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("unsupported or unrecognized"));
    }
    #[test]
    fn validate_rejects_too_many() {
        let mut cfg = test_config();
        cfg.max_attachments = 2;
        let one = Attachment {
            filename: "p.png".into(),
            mime: "image/png".into(),
            data_base64: b64(PNG_BYTES),
        };
        let atts: Vec<Attachment> = (0..3)
            .map(|_| Attachment {
                filename: one.filename.clone(),
                mime: one.mime.clone(),
                data_base64: one.data_base64.clone(),
            })
            .collect();
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("too many"));
    }
    #[test]
    fn validate_enforces_per_file_and_total_caps() {
        // Per-file cap: a 4 KB JPEG against a 1 KB cap.
        let mut cfg = test_config();
        cfg.max_attachment_bytes = 1024;
        let mut big = JPEG_BYTES.to_vec();
        big.resize(4096, 0);
        let atts = vec![Attachment {
            filename: "big.jpg".into(),
            mime: "image/jpeg".into(),
            data_base64: b64(&big),
        }];
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("per-file cap"));

        // Total cap: two 600-byte files against a 1000-byte total cap. Per-file
        // is left high so only the *combined* size trips.
        let mut cfg = test_config();
        cfg.max_attachment_bytes = 10_000;
        cfg.max_attachments_total_bytes = 1000;
        let mut mid = JPEG_BYTES.to_vec();
        mid.resize(600, 0);
        let atts = vec![
            Attachment {
                filename: "a.jpg".into(),
                mime: "image/jpeg".into(),
                data_base64: b64(&mid),
            },
            Attachment {
                filename: "b.jpg".into(),
                mime: "image/jpeg".into(),
                data_base64: b64(&mid),
            },
        ];
        let err = validate_and_decode_attachments(&cfg, &atts).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("combined cap"));
    }
    #[test]
    fn validate_rejects_empty_and_bad_base64() {
        let cfg = test_config();
        let empty = vec![Attachment {
            filename: "e.png".into(),
            mime: "image/png".into(),
            data_base64: String::new(),
        }];
        assert_eq!(
            validate_and_decode_attachments(&cfg, &empty).unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
        let bad = vec![Attachment {
            filename: "b.png".into(),
            mime: "image/png".into(),
            data_base64: "not base64 !!!".into(),
        }];
        assert_eq!(
            validate_and_decode_attachments(&cfg, &bad).unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
    }
    #[test]
    fn scratch_dir_writes_randomized_files_and_cleans_up_on_drop() {
        use std::os::unix::fs::PermissionsExt;
        let decoded = vec![
            DecodedAttachment {
                bytes: PNG_BYTES.to_vec(),
                ext: "png",
            },
            DecodedAttachment {
                bytes: PDF_BYTES.to_vec(),
                ext: "pdf",
            },
        ];
        let dir_path;
        let file_paths;
        {
            let scratch = ScratchDir::create(&std::env::temp_dir()).expect("create scratch");
            dir_path = scratch.path.clone();
            // Dir is owner-only (0700).
            let mode = std::fs::metadata(&dir_path).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o700);

            file_paths = scratch.write_all(&decoded).expect("write");
            assert_eq!(file_paths.len(), 2);
            for (p, d) in file_paths.iter().zip(&decoded) {
                assert!(p.exists());
                // On-disk name is NOT the client filename; it carries the
                // sniffed extension and a random component.
                let name = p.file_name().unwrap().to_string_lossy().into_owned();
                assert!(name.ends_with(&format!(".{}", d.ext)));
                assert!(!name.contains("shot") && !name.contains("doc"));
                assert_eq!(std::fs::read(p).unwrap(), d.bytes);
                let fmode = std::fs::metadata(p).unwrap().permissions().mode();
                assert_eq!(fmode & 0o777, 0o600);
            }
            // The two random names differ.
            assert_ne!(file_paths[0], file_paths[1]);
        } // scratch dropped here

        assert!(!dir_path.exists(), "scratch dir must be removed on Drop");
        for p in &file_paths {
            assert!(!p.exists(), "scratch files must be gone with the dir");
        }
    }
    #[test]
    fn scratch_dir_honors_custom_base() {
        // A custom base (e.g. JESSE_SCRATCH_DIR pointing at a sandbox mount) is
        // where the per-request dir is created.
        let base = std::env::temp_dir().join(format!("jesse-base-{}", random_hex()));
        std::fs::create_dir(&base).unwrap();
        let created;
        {
            let scratch = ScratchDir::create(&base).expect("create under custom base");
            created = scratch.path.clone();
            assert_eq!(scratch.path.parent(), Some(base.as_path()));
            assert!(created.exists());
        }
        assert!(!created.exists(), "scratch dir removed on Drop");
        let _ = std::fs::remove_dir_all(&base);
    }
    /// THE HELPER ROUTE AND THE FILE ROUTE CANNOT BOTH FIRE.
    ///
    /// The property that matters is not which route wins but that exactly one does: a turn
    /// on the helper route writes NO scratch dir, and no scratch dir means the turn request
    /// carries no `attachment_dir`, so `--add-dir` cannot be emitted for it and the image
    /// cannot be sent twice. The three cases below are the whole space.
    #[test]
    fn the_vision_helper_and_the_child_file_routes_are_mutually_exclusive() {
        // No attachments at all → neither route; an ordinary turn.
        assert_eq!(attachment_route(false, false), AttachmentRoute::None);
        assert_eq!(
            attachment_route(false, true),
            AttachmentRoute::None,
            "a resolving vision partner on a turn with nothing attached is still nothing to do"
        );
        // Attachments + a RESOLVING partner → the bridge transcribes; no file is written.
        assert_eq!(attachment_route(true, true), AttachmentRoute::VisionHelper);
        // Attachments + no resolving partner (ambient opus, or a paired-but-broken helper)
        // → the child reads the files itself. This is the route the read grant serves.
        assert_eq!(
            attachment_route(true, false),
            AttachmentRoute::ChildReadsFiles
        );
    }

    #[test]
    fn attachment_prompt_suffix_names_paths_only() {
        let prepared = PreparedAttachments {
            paths: vec![PathBuf::from("/tmp/jesse-attach-ab/01-cd.png")],
            notes: Vec::new(),
        };
        let s = attachment_prompt_suffix(&prepared, CLAUDE_CODE_ATTACHMENTS.instruction);
        assert!(s.contains("/tmp/jesse-attach-ab/01-cd.png"));
        assert!(s.contains("Read tool"));
        assert!(s.contains("1 file"));
    }

    /// Write `bytes` into a fresh scratch dir under `name` and hand back both, so a route
    /// test exercises the real on-disk path rather than a synthetic one.
    fn staged(name: &str, bytes: &[u8]) -> (ScratchDir, Vec<PathBuf>) {
        let s = ScratchDir::create(&std::env::temp_dir()).expect("scratch");
        let p = s.path.join(name);
        std::fs::write(&p, bytes).expect("stage");
        (s, vec![p])
    }

    /// EVERY WHITELISTED TYPE, AND THE ROUTE IT TAKES ON EACH HARNESS.
    ///
    /// One case per type the sniffer accepts, naming the type, so a format can never be
    /// added to the whitelist without someone deciding how it reaches a model. The routes
    /// are the measured ones documented on `CLAUDE_CODE_ATTACHMENTS` and
    /// `CODEX_ATTACHMENTS`.
    #[test]
    fn png_jpeg_gif_and_webp_are_handed_over_untouched_on_both_harnesses() {
        let cfg = test_config();
        for (ext, bytes) in [
            ("png", PNG_BYTES),
            ("jpg", JPEG_BYTES),
            ("gif", GIF_BYTES),
            ("webp", WEBP_BYTES),
        ] {
            for support in [&CLAUDE_CODE_ATTACHMENTS, &CODEX_ATTACHMENTS] {
                let (s, paths) = staged(&format!("01-aa.{ext}"), bytes);
                let out = prepare_attachments_for_harness(&cfg, &s, &paths, support)
                    .unwrap_or_else(|e| panic!("{ext} must have a route: {e:?}"));
                assert_eq!(
                    out.paths, paths,
                    "{ext}: a natively-readable type must be passed through unconverted"
                );
                assert!(out.notes.is_empty(), "{ext}: nothing to warn about");
            }
        }
    }

    /// HEIC IS CONVERTED TO JPEG, ON BOTH HARNESSES, because neither can read it: claude
    /// 2.1.223 returned a `.heic` as raw binary and codex 0.146.0's `view_image` refused it
    /// with "image content omitted because it could not be processed". This is the common
    /// case — a photo straight from the iOS camera roll.
    ///
    /// Uses a REAL HEIC (built with `sips` from a PNG, skipped if the platform cannot make
    /// one) rather than the 12-byte magic-only fixture, because the thing under test is the
    /// transcode itself, not the branch that reaches it.
    #[test]
    fn heic_is_converted_to_jpeg_before_any_model_sees_it() {
        let cfg = test_config();
        let src = ScratchDir::create(&std::env::temp_dir()).expect("scratch");
        let png = src.path.join("seed.png");
        // A 1x1 PNG is enough for sips to transcode.
        const TINY_PNG: &[u8] = &[
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00,
            0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78,
            0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ];
        std::fs::write(&png, TINY_PNG).expect("seed");
        let heic = src.path.join("01-aa.heic");
        let made = std::process::Command::new("/usr/bin/sips")
            .args(["-s", "format", "heic"])
            .arg(&png)
            .arg("--out")
            .arg(&heic)
            .output();
        let have_heic = matches!(&made, Ok(o) if o.status.success())
            && std::fs::metadata(&heic)
                .map(|m| m.len() > 0)
                .unwrap_or(false);
        if !have_heic {
            eprintln!("skipping heic transcode: this platform's sips cannot write HEIC");
            return;
        }

        for support in [&CLAUDE_CODE_ATTACHMENTS, &CODEX_ATTACHMENTS] {
            let out =
                prepare_attachments_for_harness(&cfg, &src, std::slice::from_ref(&heic), support)
                    .expect("heic must have a route on every harness");
            assert_eq!(out.paths.len(), 1);
            let p = &out.paths[0];
            assert_eq!(
                p.extension().and_then(|e| e.to_str()),
                Some("jpg"),
                "heic must be handed over as JPEG"
            );
            assert_ne!(
                p, &heic,
                "the original HEIC must not be named in the prompt"
            );
            // A real JPEG, not an empty file sips exited 0 over.
            let converted = std::fs::read(p).expect("converted file");
            assert!(
                converted.starts_with(&[0xFF, 0xD8, 0xFF]),
                "the converted file must actually be a JPEG"
            );
            // In the SAME scratch dir, so the existing Drop guard cleans it.
            assert_eq!(p.parent(), Some(src.path.as_path()));
        }
    }

    /// PDF SPLITS BY HARNESS, and this is the one type where the two answers differ.
    ///
    /// Claude Code's `Read` takes a PDF directly (measured, unprompted, on 2.1.223), so it
    /// is passed through untouched. Codex never reaches `view_image` for one — it shells out
    /// to `pdftotext`/`strings`/`python3` — so the bridge must rasterize. That rasterizer is
    /// `vision::rasterize_pdf`, on macOS's own Core Graphics. The staged bytes here are a
    /// TRUNCATED PDF header, not a renderable document, so on macOS this exercises the
    /// refusal path and on Linux the no-renderer path — either way the requirement is the
    /// same and is what this asserts: LOUD, actionable, never a dropped attachment. Whole
    /// real documents are rasterized in `vision`'s own tests, against a committed fixture.
    #[test]
    fn pdf_passes_through_on_claude_code_and_is_rasterized_or_refused_on_codex() {
        let cfg = test_config();

        let (s1, paths) = staged("01-aa.pdf", PDF_BYTES);
        let cc = prepare_attachments_for_harness(&cfg, &s1, &paths, &CLAUDE_CODE_ATTACHMENTS)
            .expect("Claude Code reads a PDF directly");
        assert_eq!(
            cc.paths, paths,
            "no conversion on the harness that can read it"
        );

        let (s2, paths2) = staged("01-aa.pdf", PDF_BYTES);
        match prepare_attachments_for_harness(&cfg, &s2, &paths2, &CODEX_ATTACHMENTS) {
            // Rendered: every named path is a page image, never the PDF itself.
            Ok(out) => {
                assert!(!out.paths.is_empty(), "a rasterized PDF yields page images");
                for p in &out.paths {
                    assert_eq!(p.extension().and_then(|e| e.to_str()), Some("png"));
                }
                assert!(
                    !out.paths.contains(&paths2[0]),
                    "the PDF itself is not named"
                );
            }
            // Not rendered: LOUD, and the message must say what to do about it.
            Err((code, msg)) => {
                assert_eq!(code, StatusCode::INTERNAL_SERVER_ERROR);
                assert!(
                    msg.contains("send the pages as images") || msg.contains("Claude Code"),
                    "a failure must name the fix, got: {msg}"
                );
                assert!(
                    msg.contains("rasterize") || msg.contains("PDF"),
                    "a failure must name what failed, got: {msg}"
                );
            }
        }
    }

    /// THE SAME SPLIT, ON A REAL FOUR-PAGE DOCUMENT.
    ///
    /// The test above stages a truncated header, so it can only assert the refusal half.
    /// This one stages the committed multi-page fixture and pins what actually happens to a
    /// whole document: Claude Code, which reads a PDF natively, is handed the FILE ITSELF —
    /// no rasterization, no page images, byte-for-byte the path it always took — while Codex
    /// gets one PNG per page, all four of them. macOS-gated because the rasterizer is.
    #[test]
    #[cfg(target_os = "macos")]
    fn a_whole_pdf_is_untouched_natively_and_fully_rasterized_otherwise() {
        let cfg = test_config();
        let pdf = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../eval/vision/fixtures/multipage.pdf"
        ))
        .expect("the committed multi-page fixture");

        let (s1, paths) = staged("01-aa.pdf", &pdf);
        let native = prepare_attachments_for_harness(&cfg, &s1, &paths, &CLAUDE_CODE_ATTACHMENTS)
            .expect("Claude Code reads a PDF directly");
        assert_eq!(native.paths, paths, "the PDF itself, unconverted");
        assert!(
            native.notes.is_empty(),
            "nothing to note when nothing is done"
        );

        let (s2, paths2) = staged("01-aa.pdf", &pdf);
        let rasterized = prepare_attachments_for_harness(&cfg, &s2, &paths2, &CODEX_ATTACHMENTS)
            .expect("Codex needs page images, and macOS can render them");
        assert_eq!(rasterized.paths.len(), 4, "every page, not just the first");
        for p in &rasterized.paths {
            assert_eq!(p.extension().and_then(|e| e.to_str()), Some("png"));
            assert!(
                std::fs::read(p)
                    .expect("page image")
                    .starts_with(&[0x89, b'P', b'N', b'G']),
                "each named path is a real PNG"
            );
        }
        assert!(
            rasterized.notes.is_empty(),
            "four pages under the default cap is not truncation"
        );
    }

    /// AN ATTACHMENT WITH NO ROUTE FAILS LOUDLY RATHER THAN VANISHING.
    ///
    /// The whole point of this work: a file the model never sees must never look, to the
    /// user, like a file the model saw and had nothing to say about. A type outside both
    /// the native list and the conversion table is an error naming the type and the remedy.
    #[test]
    fn an_attachment_with_no_route_is_an_error_not_a_silent_drop() {
        let cfg = test_config();
        let (s, paths) = staged("01-aa.tiff", b"II*\x00 not a supported type");
        let err = prepare_attachments_for_harness(&cfg, &s, &paths, &CODEX_ATTACHMENTS)
            .expect_err("an unroutable type must not succeed quietly");
        assert_eq!(err.0, StatusCode::INTERNAL_SERVER_ERROR);
        assert!(err.1.contains("tiff"), "name the type: {}", err.1);
        assert!(
            err.1.contains("NOT sent"),
            "say the file did not reach the model: {}",
            err.1
        );
    }

    /// THE NATIVE LISTS AND THE SNIFF WHITELIST MUST NOT DRIFT APART.
    ///
    /// Every extension the sniffer can produce needs either a native slot or a conversion,
    /// on every harness. Without this, adding a format to `sniff_attachment` would compile,
    /// pass, deploy, and then fail at runtime on the first user who sent one.
    #[test]
    fn every_sniffable_type_has_a_route_on_every_harness() {
        const CONVERTED: &[&str] = &["heic", "pdf"];
        for ext in ["png", "jpg", "gif", "pdf", "webp", "heic"] {
            for (name, support) in [
                ("claude-code", &CLAUDE_CODE_ATTACHMENTS),
                ("codex", &CODEX_ATTACHMENTS),
            ] {
                assert!(
                    support.takes(ext) || CONVERTED.contains(&ext),
                    "{name}: {ext} has no route — either add it to `native` or give \
                     `prepare_attachments_for_harness` a conversion for it"
                );
            }
        }
    }

    /// THE FRAGMENT NAMES THE SERVING HARNESS'S OWN TOOL, and never the other one's.
    ///
    /// The old fragment told every model to "read them with the Read tool". Codex has no
    /// `Read` tool at all, so on that harness the one instruction the model was given
    /// pointed at nothing. This is the assertion that the seam is actually wired, rather
    /// than the trait method existing and the handler still hard-coding one sentence.
    #[test]
    fn the_prompt_fragment_is_per_harness() {
        let prepared = PreparedAttachments {
            paths: vec![PathBuf::from("/tmp/jesse-attach-ab/01-cd.png")],
            notes: Vec::new(),
        };
        let cc = attachment_prompt_suffix(&prepared, CLAUDE_CODE_ATTACHMENTS.instruction);
        assert!(cc.contains("Read tool"), "{cc}");
        assert!(!cc.contains("view_image"), "{cc}");

        let cx = attachment_prompt_suffix(&prepared, CODEX_ATTACHMENTS.instruction);
        assert!(cx.contains("view_image"), "{cx}");
        assert!(!cx.contains("Read tool"), "{cx}");
    }

    /// A TRUNCATED PDF SAYS SO IN THE PROMPT. Dropped pages the user is never told about
    /// are a wrong answer they have no way to detect.
    #[test]
    fn a_page_cap_truncation_note_reaches_the_prompt() {
        let prepared = PreparedAttachments {
            paths: vec![PathBuf::from("/tmp/a/01-p01-x.png")],
            notes: vec![
                "attachment 1 is a 30-page PDF; only the first 10 page(s) are attached \
                         as images"
                    .to_string(),
            ],
        };
        let s = attachment_prompt_suffix(&prepared, CODEX_ATTACHMENTS.instruction);
        assert!(s.contains("30-page PDF"), "{s}");
        assert!(s.contains("only the first 10"), "{s}");
    }
    #[test]
    fn body_limit_exceeds_total_cap_for_base64_inflation() {
        let cfg = test_config();
        // Must hold the base64-inflated total (4/3) with room to spare.
        assert!(attachment_body_limit(&cfg) > cfg.max_attachments_total_bytes);
        assert!(
            attachment_body_limit(&cfg) >= cfg.max_attachments_total_bytes / 3 * 4,
            "body limit must fit base64-encoded attachments"
        );
    }

    #[test]
    fn base64_len_helpers_agree_with_encoder_and_bound_the_decode() {
        // `base64_encoded_len` must equal what the reference encoder actually
        // produces (padding included), across all three tail lengths.
        for len in [0usize, 1, 2, 3, 4, 5, 6, 100, 255, 256, 257] {
            let data: Vec<u8> = (0..len).map(|i| (i * 3 % 256) as u8).collect();
            let enc = b64(&data);
            assert_eq!(
                base64_encoded_len(len),
                enc.len(),
                "encoded_len mismatch at {len}"
            );
            // The decoded-length bound is an UPPER bound on the true decoded size
            // (never under-counts, so the per-file pre-check can't wave a big blob
            // through).
            assert!(
                base64_decoded_len_bound(enc.len()) >= len,
                "decoded bound under-counts at {len}: {} < {len}",
                base64_decoded_len_bound(enc.len())
            );
        }
        // Concrete corners.
        assert_eq!(base64_encoded_len(0), 0);
        assert_eq!(base64_encoded_len(1), 4);
        assert_eq!(base64_encoded_len(3), 4);
        assert_eq!(base64_encoded_len(4), 8);
        assert_eq!(base64_decoded_len_bound(4), 3);
        assert_eq!(base64_decoded_len_bound(8), 6);
    }

    #[test]
    fn base64_round_trips_every_byte_value_and_known_vectors() {
        // Property: every byte value survives an encode (reference `b64`) → decode
        // round-trip, in one blob covering all 256 values.
        let all: Vec<u8> = (0..=255u8).collect();
        assert_eq!(base64_decode(&b64(&all)).unwrap(), all);
        // RFC 4648 §10 reference vectors decode exactly (both tail paddings).
        assert_eq!(base64_decode("Zm9vYmE=").unwrap(), b"fooba");
        assert_eq!(base64_decode("Zm9vYmFy").unwrap(), b"foobar");
        assert_eq!(base64_decode("Zg==").unwrap(), b"f");
    }

    #[test]
    fn base64_error_branches_are_each_reported() {
        // One case per error branch of the hand-rolled decoder, pinned to its
        // message so a refactor can't silently collapse a branch.
        assert_eq!(
            base64_decode("TWF").unwrap_err(),
            "base64: truncated group (length not a multiple of 4)"
        );
        assert_eq!(
            base64_decode("****").unwrap_err(),
            "base64: invalid character"
        );
        assert_eq!(
            base64_decode("T=Fu").unwrap_err(),
            "base64: data after padding"
        );
        assert_eq!(
            base64_decode("====").unwrap_err(),
            "base64: over-long padding"
        );
        assert_eq!(
            base64_decode("TQ==X").unwrap_err(),
            "base64: trailing data after padding"
        );
    }
}
