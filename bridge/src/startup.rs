use crate::*;

// ---- Startup --------------------------------------------------------------

/// Percent-encode a query-parameter value, keeping only RFC 3986 unreserved
/// characters literal. Host/port/token are simple today, but encoding keeps the
/// payload well-formed for whatever a future advertise-host might contain.
pub fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Build the `jesse://pair?…` payload the app scans. MUST match the app's
/// `JesseConfig.fromPairing` parser exactly.
pub fn pairing_payload(host: &str, port: u16, token: &str) -> String {
    format!(
        "jesse://pair?host={}&port={}&token={}",
        percent_encode(host),
        port,
        percent_encode(token)
    )
}

/// A regular file with at least one execute bit set (`mode & 0o111`). The point
/// of the startup check is "can we actually run this as `claude`?", so a plain,
/// non-executable file (a stray `claude.txt`, a checked-out but un-`chmod +x`ed
/// script) must NOT count — `is_file()` alone accepted it.
fn is_executable_file(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

pub fn binary_exists(bin: &str) -> bool {
    let p = Path::new(bin);
    if p.is_absolute() || bin.contains('/') {
        return is_executable_file(p);
    }
    if let Ok(path) = std::env::var("PATH") {
        return path
            .split(':')
            .any(|dir| is_executable_file(&Path::new(dir).join(bin)));
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::*;
    #[test]
    fn binary_exists_absolute_path() {
        assert!(binary_exists("/bin/sh"));
        assert!(!binary_exists("/no/such/bin"));
    }
    #[test]
    fn binary_exists_searches_path() {
        let _guard = ENV_LOCK.lock_ok();
        let saved = std::env::var("PATH").ok();
        std::env::set_var("PATH", "/bin");
        assert!(binary_exists("sh"));
        match saved {
            Some(p) => std::env::set_var("PATH", p),
            None => std::env::remove_var("PATH"),
        }
    }
    #[test]
    fn binary_exists_rejects_non_executable_file() {
        use std::os::unix::fs::PermissionsExt;
        // A real, present file that is NOT executable must be rejected — the old
        // `is_file()`-only check accepted it (a stray non-`+x` `claude`).
        let dir = std::env::temp_dir().join(format!("jesse-binexists-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let non_exec = dir.join("claude");
        std::fs::write(&non_exec, b"#!/bin/sh\necho hi\n").unwrap();
        std::fs::set_permissions(&non_exec, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(
            !binary_exists(non_exec.to_str().unwrap()),
            "a non-executable file must not count as the claude binary"
        );
        // The same file with the execute bit set is accepted.
        std::fs::set_permissions(&non_exec, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            binary_exists(non_exec.to_str().unwrap()),
            "the file is accepted once it is executable"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn pairing_payload_matches_app_format() {
        let p = pairing_payload("100.64.0.1", 8765, "deadbeef");
        assert_eq!(p, "jesse://pair?host=100.64.0.1&port=8765&token=deadbeef");
    }
    #[test]
    fn pairing_payload_percent_encodes_reserved() {
        // A host with a reserved char must be escaped, not left raw.
        let p = pairing_payload("a b/c", 80, "t&k");
        assert!(p.contains("host=a%20b%2Fc"));
        assert!(p.contains("token=t%26k"));
    }
}
