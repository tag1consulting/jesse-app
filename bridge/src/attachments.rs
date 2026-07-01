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
    let base = m.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
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

/// A per-request scratch directory under `base` (the system temp dir by
/// default, or `JESSE_SCRATCH_DIR`) — NOT the vault, so attachments never
/// pollute it; verified that headless `claude` reads paths here via its Read
/// tool with no `--add-dir`. Removed by `Drop` on every exit path — success,
/// error, or timeout — so decoded files never outlive the turn.
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

/// The prompt fragment that points the agent at the written attachment paths.
/// Names the on-disk paths only (never the untrusted client filename) so a
/// crafted filename can't ride into the prompt.
pub fn attachment_prompt_suffix(paths: &[PathBuf]) -> String {
    let list = paths
        .iter()
        .map(|p| p.display().to_string())
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "\n\n(The user attached {} file(s) with this message, saved at these \
         path(s) — read them with the Read tool as needed to answer: {list})",
        paths.len()
    )
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
        assert!(base64_decode("TQ==X").is_err(), "trailing data after padding");
        assert!(base64_decode("T=Fu").is_err(), "data after padding mid-group");
        assert!(base64_decode("====").is_err(), "over-long padding");
    }
    #[test]
    fn sniff_identifies_whitelisted_types() {
        assert_eq!(sniff_attachment(PNG_BYTES), Some(("image/png", "png")));
        assert_eq!(sniff_attachment(JPEG_BYTES), Some(("image/jpeg", "jpg")));
        assert_eq!(sniff_attachment(PDF_BYTES), Some(("application/pdf", "pdf")));
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
        assert_eq!(normalize_mime("application/pdf; charset=binary"), "application/pdf");
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
    #[test]
    fn attachment_prompt_suffix_names_paths_only() {
        let paths = vec![PathBuf::from("/tmp/jesse-attach-ab/01-cd.png")];
        let s = attachment_prompt_suffix(&paths);
        assert!(s.contains("/tmp/jesse-attach-ab/01-cd.png"));
        assert!(s.contains("Read tool"));
        assert!(s.contains("1 file"));
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
        assert_eq!(base64_decode("TWF").unwrap_err(), "base64: truncated group (length not a multiple of 4)");
        assert_eq!(base64_decode("****").unwrap_err(), "base64: invalid character");
        assert_eq!(base64_decode("T=Fu").unwrap_err(), "base64: data after padding");
        assert_eq!(base64_decode("====").unwrap_err(), "base64: over-long padding");
        assert_eq!(base64_decode("TQ==X").unwrap_err(), "base64: trailing data after padding");
    }
}
