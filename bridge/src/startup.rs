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

/// Whether the plaintext bearer token should be printed at startup. Off by default
/// so the raw token stays out of terminal scrollback and launchd logs; opt in with
/// the `--show-token` CLI flag or a truthy `JESSE_SHOW_TOKEN` env var. `token_env`
/// is the already-evaluated env decision (passed in so this stays pure/testable).
pub fn show_token_opt_in(args: &[String], token_env: bool) -> bool {
    token_env || args.iter().any(|a| a == "--show-token")
}

/// Tri-state parse of `JESSE_SHOW_QR`'s raw value. An explicit truthy
/// (`1`/`true`/`yes`/`on`) forces the QR on; an explicit falsy
/// (`0`/`false`/`no`/`off`) PINS IT OFF; unset or unrecognized leaves the
/// decision to the TTY check. The pin-off exists because "terminal" and "log
/// stream" are not mutually exclusive: `docker run -t`, a pod spec's
/// `tty: true`, and script(1)/unbuffer wrappers all put a PTY on stdout while
/// the container log driver still collects it — there the TTY heuristic reads
/// "someone is watching" but every byte lands in aggregation, and this is the
/// operator's lever to keep the token-bearing QR out anyway. The value sets
/// match `env_truthy` and the `resolve_context_carry` falsy set.
pub fn qr_env_tristate(value: Option<&str>) -> Option<bool> {
    let v = value?.trim().to_ascii_lowercase();
    match v.as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

/// Whether the pairing QR should be printed at startup. The QR encodes the FULL
/// bearer token (`jesse://pair?…&token=…` — a QR is an encoding, not an
/// obfuscation), so by default it is printed only when stdout is a terminal:
/// someone is there to scan it, and the pixels die with the session. When
/// stdout is a pipe — a container, launchd, `| tee` — stdout is a LOG STREAM,
/// and every restart would republish the token into whatever aggregation is
/// attached. Those runs get the manual-pairing lines only.
///
/// `qr_env` is the tri-state [`qr_env_tristate`] read of `JESSE_SHOW_QR`: an
/// explicit falsy value pins the QR OFF and wins over everything, including a
/// TTY and `--show-qr` — that guarantee is the point, since it exists for the
/// PTY-that-is-still-log-collected case. A truthy value (or `--show-qr`)
/// forces the QR onto a non-TTY stdout a human is actually reading.
/// `stdout_is_tty` is the already-evaluated terminal check (passed in so this
/// stays pure/testable, matching `show_token_opt_in`).
pub fn show_qr_opt_in(args: &[String], qr_env: Option<bool>, stdout_is_tty: bool) -> bool {
    match qr_env {
        Some(false) => false,
        Some(true) => true,
        None => stdout_is_tty || args.iter().any(|a| a == "--show-qr"),
    }
}

/// Whether `manual_pairing_lines` prints the plaintext `token=` value. A
/// dedicated type rather than a bare bool because the function also takes the
/// QR state: two adjacent same-typed bools let a transposed call site compile
/// silently, and a transposition here prints the token while the wording
/// claims it is hidden.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TokenVisibility {
    Hidden,
    Shown,
}

/// Whether the pairing QR was actually RENDERED above the manual-pairing
/// lines. `Suppressed` covers both the TTY gate and a failed render, so the
/// wording never references a QR that isn't there. Same bare-bool rationale
/// as [`TokenVisibility`].
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum QrArt {
    Shown,
    Suppressed,
}

/// The manual-pairing fallback lines printed beneath the QR (or alone, when the
/// QR is suppressed — `qr` keeps the wording from referencing a QR that isn't
/// there). The plaintext `token=` line is included ONLY when `token_line` is
/// `Shown` — by default it is omitted so the raw token never lands in
/// scrollback, launchd logs, or a container's log stream. With the QR shown it
/// still encodes the token, so pairing is unaffected; without it, the operator
/// already holds the token (they set `JESSE_TOKEN`).
pub fn manual_pairing_lines(
    host: &str,
    port: u16,
    token: &str,
    token_line: TokenVisibility,
    qr: QrArt,
) -> Vec<String> {
    let mut lines = vec![match qr {
        QrArt::Shown => "Pair by scanning the QR above, or enter manually:".to_string(),
        QrArt::Suppressed => "Pair from the app's Settings by entering these manually:".to_string(),
    }];
    match token_line {
        TokenVisibility::Shown => lines.push(format!("  host={host}  port={port}  token={token}")),
        TokenVisibility::Hidden => {
            lines.push(format!("  host={host}  port={port}"));
            lines.push(match qr {
                QrArt::Shown => {
                    "  (token hidden — it's encoded in the QR above; pass --show-token or set \
                     JESSE_SHOW_TOKEN=1 to also print it)"
                        .to_string()
                }
                // Deliberately NO --show-token nudge here. This branch prints only
                // when the QR was suppressed, i.e. when stdout is NOT a terminal —
                // exactly when stdout is a log stream, the one place the plaintext
                // token must not be advertised into. The operator already holds the
                // value (they set JESSE_TOKEN); the --show-qr recovery hint goes to
                // stderr in main.rs instead, where it stays out of this output.
                QrArt::Suppressed => {
                    "  (token hidden — it is the value of JESSE_TOKEN)".to_string()
                }
            });
        }
    }
    lines
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
    fn manual_pairing_lines_hide_token_by_default() {
        let lines = manual_pairing_lines(
            "100.64.0.1",
            8765,
            "deadbeef",
            TokenVisibility::Hidden,
            QrArt::Shown,
        );
        let joined = lines.join("\n");
        assert!(
            !joined.contains("deadbeef"),
            "the plaintext token must NOT appear by default"
        );
        assert!(
            joined.contains("host=100.64.0.1") && joined.contains("port=8765"),
            "host/port are still printed for manual entry"
        );
        assert!(
            !joined.contains("token="),
            "no token= line is printed by default"
        );
    }

    #[test]
    fn manual_pairing_lines_show_token_when_opted_in() {
        let lines = manual_pairing_lines(
            "100.64.0.1",
            8765,
            "deadbeef",
            TokenVisibility::Shown,
            QrArt::Shown,
        );
        let joined = lines.join("\n");
        assert!(
            joined.contains("token=deadbeef"),
            "the token IS printed once opted in"
        );
    }

    #[test]
    fn manual_pairing_lines_no_qr_wording() {
        // With the QR suppressed, no line may CLAIM a QR is present ("the QR
        // above", "scanning") — and the token stays hidden exactly as in the
        // QR case.
        let lines = manual_pairing_lines(
            "100.64.0.1",
            8765,
            "deadbeef",
            TokenVisibility::Hidden,
            QrArt::Suppressed,
        );
        let joined = lines.join("\n");
        assert!(
            !joined.contains("QR above") && !joined.contains("scanning"),
            "suppressed-QR output must not claim a QR is present: {joined}"
        );
        assert!(
            !joined.contains("deadbeef"),
            "the token stays hidden with the QR suppressed"
        );
        assert!(
            joined.contains("host=100.64.0.1") && joined.contains("port=8765"),
            "host/port are still printed for manual entry"
        );
        // This branch prints only when stdout is a log stream, so it must not
        // advertise the switches that would write the plaintext token there.
        assert!(
            !joined.contains("show-token") && !joined.contains("JESSE_SHOW_TOKEN"),
            "suppressed-QR output must not nudge toward printing the token: {joined}"
        );
        // The opt-in for showing the token still works without the QR.
        let shown = manual_pairing_lines(
            "100.64.0.1",
            8765,
            "deadbeef",
            TokenVisibility::Shown,
            QrArt::Suppressed,
        );
        assert!(shown.join("\n").contains("token=deadbeef"));
    }

    #[test]
    fn show_token_opt_in_honors_flag_and_env() {
        let none: Vec<String> = vec![];
        // Neither flag nor env → off.
        assert!(!show_token_opt_in(&none, false));
        // CLI flag → on.
        assert!(show_token_opt_in(&["--show-token".to_string()], false));
        // Env decision → on, even with no flag.
        assert!(show_token_opt_in(&none, true));
        // An unrelated arg alone doesn't enable it.
        assert!(!show_token_opt_in(&["--verbose".to_string()], false));
    }

    #[test]
    fn show_qr_opt_in_tty_gates_with_overrides() {
        let none: Vec<String> = vec![];
        // Interactive terminal → QR, no flags needed (the laptop case, unchanged UX).
        assert!(show_qr_opt_in(&none, None, true));
        // No TTY, no override → suppressed (the container/pipe case: stdout is logs).
        assert!(!show_qr_opt_in(&none, None, false));
        // Explicit overrides bring it back on a non-TTY stdout.
        assert!(show_qr_opt_in(&["--show-qr".to_string()], None, false));
        assert!(show_qr_opt_in(&none, Some(true), false));
        // An explicit falsy PINS the QR off, beating both a TTY and the flag —
        // the PTY-that-is-still-log-collected escape hatch must be absolute.
        assert!(!show_qr_opt_in(&none, Some(false), true));
        assert!(!show_qr_opt_in(
            &["--show-qr".to_string()],
            Some(false),
            true
        ));
        // An unrelated arg alone doesn't enable it.
        assert!(!show_qr_opt_in(&["--verbose".to_string()], None, false));
    }

    #[test]
    fn qr_env_tristate_parses_all_three_states() {
        // Unset → None (the TTY check decides).
        assert_eq!(qr_env_tristate(None), None);
        // Truthy set, case-insensitive, trimmed.
        for v in ["1", "true", "YES", " on "] {
            assert_eq!(qr_env_tristate(Some(v)), Some(true), "{v:?} forces on");
        }
        // Falsy set — the pin-off.
        for v in ["0", "false", "No", " OFF "] {
            assert_eq!(qr_env_tristate(Some(v)), Some(false), "{v:?} pins off");
        }
        // Unrecognized garbage falls back to the TTY default rather than
        // guessing a direction.
        assert_eq!(qr_env_tristate(Some("maybe")), None);
        assert_eq!(qr_env_tristate(Some("")), None);
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
