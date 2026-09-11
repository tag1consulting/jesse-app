//! THE ONE DOOR: how a recording gets into the bridge's custody, and how it leaves.
//!
//! The turn attachment path (`crate::attachments`) is the precedent for the discipline — the
//! type is sniffed from magic bytes and cross-checked against what the client declared, the
//! client's filename never touches disk, files are 0600 in a 0700 directory with a random
//! name, and a `Drop` removes them — and the `inbound` staging directory is the precedent for
//! a directory the BRIDGE owns with a stated deletion rule. What differs is the size and the
//! transport:
//!
//! * **Size.** An hour of speech is tens to a few hundred megabytes, far past the photo and
//!   document caps (sized for a camera-roll snapshot and a forty-page contract). Audio has its
//!   own cap, [`DEFAULT_MAX_AUDIO_BYTES`]; the other two are untouched.
//! * **Transport.** Not base64 in a JSON body, which would hold an hour of audio in memory
//!   twice. The request body IS the recording, streamed to disk chunk by chunk through
//!   [`UploadGate`], so memory is bounded by one chunk however long the recording is.

use crate::*;
use std::os::unix::fs::PermissionsExt;

/// How many leading bytes the sniff needs: the longest signature (an `ftyp` box's brand)
/// ends at byte 12.
pub const SNIFF_BYTES: usize = 12;

/// The per-recording cap, 1 GiB. An hour of Voice Memos AAC is about 30 MB; an hour of
/// 48 kHz stereo WAV is about 660 MB. Override with `JESSE_SPEECH_MAX_AUDIO_BYTES`.
pub const DEFAULT_MAX_AUDIO_BYTES: u64 = 1024 * 1024 * 1024;

/// The ISO-BMFF brands an audio file in an MP4 box carries. Disjoint from the HEIF family
/// `sniff_attachment` admits, and a test holds them apart.
const MP4_AUDIO_BRANDS: [&[u8]; 10] = [
    b"M4A ", b"M4B ", b"M4P ", b"mp41", b"mp42", b"isom", b"iso2", b"3gp4", b"3gp5", b"3gp6",
];

/// Sniff an AUDIO container from its leading bytes. Returns `(canonical_mime, extension)`
/// for the containers the capture side produces and the system decoder reads — Voice Memos'
/// M4A, and the WAV / AIFF / CAF / MP3 / FLAC a file picker can hand over — and `None` for
/// everything else, images and documents included.
pub fn sniff_audio(b: &[u8]) -> Option<(&'static str, &'static str)> {
    if b.len() >= 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WAVE" {
        return Some(("audio/wav", "wav"));
    }
    if b.len() >= 12 && &b[0..4] == b"FORM" && (&b[8..12] == b"AIFF" || &b[8..12] == b"AIFC") {
        return Some(("audio/aiff", "aiff"));
    }
    if b.starts_with(b"caff") {
        return Some(("audio/x-caf", "caf"));
    }
    if b.starts_with(b"fLaC") {
        return Some(("audio/flac", "flac"));
    }
    if b.starts_with(b"ID3") {
        return Some(("audio/mpeg", "mp3"));
    }
    // A bare MPEG audio frame: 11 sync bits, then a version that is not the reserved `01`
    // and a layer that is not the reserved `00`. The layer check is what keeps raw ADTS AAC
    // (layer `00`) out, and the sync check what keeps JPEG's `FF D8` out.
    if b.len() >= 2
        && b[0] == 0xFF
        && (b[1] & 0xE0) == 0xE0
        && (b[1] & 0x18) != 0x08
        && (b[1] & 0x06) != 0
    {
        return Some(("audio/mpeg", "mp3"));
    }
    if b.len() >= 12 && &b[4..8] == b"ftyp" && MP4_AUDIO_BRANDS.contains(&&b[8..12]) {
        return Some(("audio/mp4", "m4a"));
    }
    None
}

/// Normalize a declared audio MIME for comparison with the sniff: lowercased, parameters
/// stripped, and the common aliases folded onto the canonical names [`sniff_audio`] returns.
pub fn normalize_audio_mime(m: &str) -> String {
    let base = m
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    match base.as_str() {
        "audio/x-wav" | "audio/wave" | "audio/vnd.wave" => "audio/wav".to_string(),
        "audio/x-aiff" | "audio/aif" | "audio/aifc" | "audio/x-aifc" => "audio/aiff".to_string(),
        "audio/x-m4a" | "audio/m4a" => "audio/mp4".to_string(),
        "audio/mp3" | "audio/x-mp3" | "audio/mpeg3" | "audio/x-mpeg" => "audio/mpeg".to_string(),
        "audio/x-flac" => "audio/flac".to_string(),
        "audio/caf" => "audio/x-caf".to_string(),
        _ => base,
    }
}

/// What the gate concluded about a finished upload.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SniffedUpload {
    pub mime: &'static str,
    pub ext: &'static str,
    pub bytes: u64,
}

/// THE GATE, fed the upload one chunk at a time.
///
/// It refuses as early as it can: the cap on the chunk that crosses it, and the type the
/// moment the first [`SNIFF_BYTES`] have arrived — before the caller has written the chunk
/// that carried them, so a rejected upload leaves nothing on disk beyond what an earlier
/// chunk already put there, and the custody `Drop` takes that.
pub struct UploadGate {
    declared: String,
    cap: u64,
    received: u64,
    head: Vec<u8>,
    sniffed: Option<(&'static str, &'static str)>,
}

impl UploadGate {
    pub fn new(declared_mime: &str, cap: u64) -> Self {
        UploadGate {
            declared: declared_mime.to_string(),
            cap,
            received: 0,
            head: Vec::with_capacity(SNIFF_BYTES),
            sniffed: None,
        }
    }

    /// Account one chunk. Call BEFORE writing it.
    pub fn accept(&mut self, chunk: &[u8]) -> Result<(), ApiError> {
        self.received = self.received.saturating_add(chunk.len() as u64);
        if self.received > self.cap {
            return Err(over_cap(self.cap));
        }
        if self.sniffed.is_none() && self.head.len() < SNIFF_BYTES {
            let take = (SNIFF_BYTES - self.head.len()).min(chunk.len());
            self.head.extend_from_slice(&chunk[..take]);
            if self.head.len() == SNIFF_BYTES {
                self.check()?;
            }
        }
        Ok(())
    }

    fn check(&mut self) -> Result<(), ApiError> {
        let (mime, ext) = sniff_audio(&self.head).ok_or((
            StatusCode::BAD_REQUEST,
            "the upload is not a recording this bridge can read (it reads M4A/MP4 audio, WAV, \
             AIFF, CAF, MP3 and FLAC)"
                .to_string(),
        ))?;
        if normalize_audio_mime(&self.declared) != mime {
            return Err((
                StatusCode::BAD_REQUEST,
                format!(
                    "declared type {:?} does not match the detected type {mime:?}",
                    self.declared
                ),
            ));
        }
        self.sniffed = Some((mime, ext));
        Ok(())
    }

    /// The upload is complete. An empty body is refused; one shorter than the sniff window
    /// is sniffed on what arrived.
    pub fn finish(mut self) -> Result<SniffedUpload, ApiError> {
        if self.received == 0 {
            return Err((
                StatusCode::BAD_REQUEST,
                "the recording is empty".to_string(),
            ));
        }
        if self.sniffed.is_none() {
            self.check()?;
        }
        let (mime, ext) = self.sniffed.expect("check() sets it or returns an error");
        Ok(SniffedUpload {
            mime,
            ext,
            bytes: self.received,
        })
    }
}

/// The 413 the cap produces, from the declared length or from the stream.
pub fn over_cap(cap: u64) -> ApiError {
    (
        StatusCode::PAYLOAD_TOO_LARGE,
        format!(
            "the recording is larger than this bridge's cap of {} MB \
             (JESSE_SPEECH_MAX_AUDIO_BYTES)",
            cap / (1024 * 1024)
        ),
    )
}

/// The name every custody directory starts with.
pub const CUSTODY_PREFIX: &str = "run-";

/// A recording in the bridge's custody: one private directory per run under the intake root.
///
/// **EVERY AUDIO BYTE ON THE STUDIO LIVES IN ONE OF THESE**, and the directory is removed when
/// the value is dropped. The run holds it until it ends, so success, every failure, a cancel
/// and a panic's unwind all delete the audio by the same one line. What a killed process
/// leaves behind, [`purge_intake`] removes at the next boot.
#[derive(Debug)]
pub struct AudioCustody {
    dir: PathBuf,
}

impl AudioCustody {
    /// Create a fresh 0700 run directory under `root` (itself created, and tightened, to 0700).
    pub fn open(root: &Path) -> std::io::Result<Self> {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(root)?;
        // An existing root keeps whatever mode it was created with; these are private
        // recordings, so tighten it every time rather than trusting it.
        std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700))?;
        let dir = root.join(format!("{CUSTODY_PREFIX}{}", random_hex()));
        std::fs::DirBuilder::new().mode(0o700).create(&dir)?;
        Ok(AudioCustody { dir })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// A path inside the run directory. Names are the bridge's own, never the client's.
    pub fn file(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }
}

impl Drop for AudioCustody {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Delete everything under the intake root. Safe at boot, and ONLY at boot: runs are held in
/// memory, so nothing on disk here can belong to a live one.
///
/// Symlinks are unlinked, never followed — a purge that resolved them would be a
/// delete-anything primitive rooted in a directory that takes uploads. Returns how many
/// entries were removed; the caller logs the count and never a name.
pub fn purge_intake(root: &Path) -> usize {
    let Ok(entries) = std::fs::read_dir(root) else {
        return 0;
    };
    let mut removed = 0;
    for entry in entries.flatten() {
        let p = entry.path();
        let Ok(md) = std::fs::symlink_metadata(&p) else {
            continue;
        };
        let gone = if md.is_dir() {
            std::fs::remove_dir_all(&p).is_ok()
        } else {
            std::fs::remove_file(&p).is_ok()
        };
        if gone {
            removed += 1;
        }
    }
    removed
}

#[cfg(test)]
mod tests {
    use super::*;

    const M4A: &[u8] = b"\x00\x00\x00\x1cftypM4A \x00\x00\x00\x00M4A mp42isom";
    const WAV: &[u8] = b"RIFF\x24\x00\x00\x00WAVEfmt ";
    const AIFF: &[u8] = b"FORM\x00\x00\x00\x00AIFFCOMM";
    const CAF: &[u8] = b"caff\x00\x01\x00\x00desc";
    const FLAC: &[u8] = b"fLaC\x00\x00\x00\x22";
    const MP3_ID3: &[u8] = b"ID3\x04\x00\x00\x00\x00";
    const MP3_FRAME: &[u8] = &[0xFF, 0xFB, 0x90, 0x64];
    const ADTS_AAC: &[u8] = &[0xFF, 0xF1, 0x50, 0x80];

    const PNG: &[u8] = &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13];
    const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, b'J', b'F', b'I', b'F'];
    const PDF: &[u8] = b"%PDF-1.7\n";
    const HEIC: &[u8] = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00";
    const WEBP: &[u8] = b"RIFF\x24\x00\x00\x00WEBPVP8 ";

    #[test]
    fn every_container_the_capture_side_produces_is_recognised() {
        assert_eq!(sniff_audio(M4A), Some(("audio/mp4", "m4a")));
        assert_eq!(sniff_audio(WAV), Some(("audio/wav", "wav")));
        assert_eq!(sniff_audio(AIFF), Some(("audio/aiff", "aiff")));
        assert_eq!(sniff_audio(CAF), Some(("audio/x-caf", "caf")));
        assert_eq!(sniff_audio(FLAC), Some(("audio/flac", "flac")));
        assert_eq!(sniff_audio(MP3_ID3), Some(("audio/mpeg", "mp3")));
        assert_eq!(sniff_audio(MP3_FRAME), Some(("audio/mpeg", "mp3")));
    }

    #[test]
    fn images_documents_and_raw_aac_are_not_audio_here() {
        for (name, b) in [
            ("png", PNG),
            ("jpeg", JPEG),
            ("pdf", PDF),
            ("heic", HEIC),
            ("webp", WEBP),
            ("adts", ADTS_AAC),
            ("zip", b"PK\x03\x04".as_slice()),
            ("empty", b"".as_slice()),
        ] {
            assert_eq!(sniff_audio(b), None, "{name} must not be admitted as audio");
        }
    }

    /// THE TWO DOORS NEVER OPEN FOR THE SAME BYTES.
    ///
    /// The turn attachment gate leads to places audio must not go — a hosted vision helper,
    /// a hosted child reading a scratch file — so it must refuse every audio container, and
    /// this door must refuse every image and document. If a later change teaches either
    /// sniffer the other's format, this is where it fails.
    #[test]
    fn the_turn_attachment_gate_and_the_audio_door_never_agree() {
        for audio in [M4A, WAV, AIFF, CAF, FLAC, MP3_ID3, MP3_FRAME] {
            assert!(sniff_audio(audio).is_some());
            assert_eq!(
                crate::sniff_attachment(audio),
                None,
                "the turn attachment gate admitted an audio container: {audio:02x?}"
            );
        }
        for doc in [PNG, JPEG, PDF, HEIC, WEBP] {
            assert!(crate::sniff_attachment(doc).is_some());
            assert_eq!(sniff_audio(doc), None, "the audio door admitted {doc:02x?}");
        }
    }

    #[test]
    fn declared_aliases_fold_onto_the_sniffed_names() {
        assert_eq!(normalize_audio_mime("audio/x-m4a"), "audio/mp4");
        assert_eq!(normalize_audio_mime("audio/M4A; codecs=mp4a"), "audio/mp4");
        assert_eq!(normalize_audio_mime("audio/x-wav"), "audio/wav");
        assert_eq!(normalize_audio_mime("audio/mp3"), "audio/mpeg");
        assert_eq!(normalize_audio_mime("audio/x-aiff"), "audio/aiff");
        assert_eq!(normalize_audio_mime("audio/caf"), "audio/x-caf");
        assert_eq!(normalize_audio_mime("image/png"), "image/png");
    }

    #[test]
    fn the_gate_sniffs_across_a_chunk_boundary() {
        let mut g = UploadGate::new("audio/x-m4a", 1_000);
        g.accept(&M4A[..5]).expect("too early to judge");
        g.accept(&M4A[5..]).expect("an M4A declared as M4A");
        let s = g.finish().expect("complete");
        assert_eq!(
            (s.mime, s.ext, s.bytes),
            ("audio/mp4", "m4a", M4A.len() as u64)
        );
    }

    #[test]
    fn the_gate_refuses_a_lie_on_the_chunk_that_tells_it() {
        let mut g = UploadGate::new("audio/wav", 1_000);
        let err = g.accept(M4A).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("does not match"), "{}", err.1);

        let mut g = UploadGate::new("audio/mp4", 1_000);
        let err = g.accept(PNG).unwrap_err();
        assert_eq!(err.0, StatusCode::BAD_REQUEST);
        assert!(err.1.contains("not a recording"), "{}", err.1);
    }

    #[test]
    fn the_gate_enforces_its_own_cap_not_the_photo_one() {
        let mut g = UploadGate::new("audio/wav", 20);
        g.accept(WAV).expect("12 bytes under a 20-byte cap");
        let err = g.accept(&[0u8; 9]).unwrap_err();
        assert_eq!(err.0, StatusCode::PAYLOAD_TOO_LARGE);
        // And the audio cap is its own number, far past the photo cap, on purpose.
        let cfg = crate::testutil::test_config();
        assert!(DEFAULT_MAX_AUDIO_BYTES > cfg.max_attachment_bytes as u64 * 10);
    }

    #[test]
    fn empty_and_short_uploads_are_judged_on_what_arrived() {
        assert_eq!(
            UploadGate::new("audio/wav", 10).finish().unwrap_err().0,
            StatusCode::BAD_REQUEST
        );
        let mut g = UploadGate::new("audio/mpeg", 10);
        g.accept(MP3_FRAME).unwrap();
        assert_eq!(
            g.finish().unwrap().ext,
            "mp3",
            "four bytes of a frame header suffice"
        );
    }

    #[test]
    fn custody_is_private_and_its_drop_takes_every_byte() {
        let root = std::env::temp_dir().join(format!("jesse-intake-{}", random_hex()));
        let dir;
        {
            let c = AudioCustody::open(&root).expect("open");
            dir = c.dir().to_path_buf();
            std::fs::write(c.file("upload.m4a"), b"audio").unwrap();
            std::fs::write(c.file("decoded-16k.wav"), b"pcm").unwrap();
            let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode(&root), 0o700);
            assert_eq!(mode(&dir), 0o700);
            assert!(dir
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with(CUSTODY_PREFIX));
        }
        assert!(
            !dir.exists(),
            "dropping custody deletes the upload and its working copy"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_boot_purge_empties_the_root_and_follows_no_link_out_of_it() {
        let root = std::env::temp_dir().join(format!("jesse-intake-{}", random_hex()));
        let outside = std::env::temp_dir().join(format!("jesse-outside-{}", random_hex()));
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("keep.txt"), b"not ours").unwrap();

        let abandoned = AudioCustody::open(&root).unwrap();
        std::fs::write(abandoned.file("upload.m4a"), b"audio").unwrap();
        let abandoned_dir = abandoned.dir().to_path_buf();
        std::mem::forget(abandoned); // a process killed mid-run never ran its Drop
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();

        assert_eq!(purge_intake(&root), 2);
        assert!(!abandoned_dir.exists());
        assert!(!root.join("link").exists());
        assert!(
            outside.join("keep.txt").exists(),
            "the link's target is untouched"
        );
        assert_eq!(purge_intake(&root.join("absent")), 0);
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&outside);
    }
}
