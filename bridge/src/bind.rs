use crate::*;

// ---- Bind safety (C2) -----------------------------------------------------

/// Whether the bridge may bind `addr` (the host portion, e.g. "127.0.0.1").
/// True only for loopback (127.0.0.0/8, ::1) or CGNAT/tailnet space
/// (100.64.0.0/10) — the interfaces the security model assumes — unless
/// `allow_public` is set, which permits any address. A value that doesn't parse
/// as an IP (e.g. a hostname) is treated as non-loopback/non-CGNAT and refused
/// unless overridden, since we can't prove it's private.
pub fn is_bind_allowed(addr: &str, allow_public: bool) -> bool {
    if allow_public {
        return true;
    }
    match addr.parse::<IpAddr>() {
        Ok(IpAddr::V4(v4)) => {
            // Loopback 127.0.0.0/8, or CGNAT 100.64.0.0/10.
            v4.is_loopback() || (v4.octets()[0] == 100 && (64..=127).contains(&v4.octets()[1]))
        }
        Ok(IpAddr::V6(v6)) => v6.is_loopback(),
        Err(_) => false,
    }
}

/// Parse a truthy env flag (1/true/yes/on, case-insensitive).
pub fn env_truthy(name: &str) -> bool {
    std::env::var(name)
        .ok()
        .map(|v| {
            let v = v.trim().to_ascii_lowercase();
            v == "1" || v == "true" || v == "yes" || v == "on"
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bind_allows_loopback_and_tailnet_only() {
        // Loopback (v4 + v6) and CGNAT/tailnet space are allowed.
        assert!(is_bind_allowed("127.0.0.1", false));
        assert!(is_bind_allowed("127.5.6.7", false)); // all of 127.0.0.0/8
        assert!(is_bind_allowed("::1", false));
        assert!(is_bind_allowed("100.64.0.1", false)); // tailnet (100.64/10)
        assert!(is_bind_allowed("100.64.0.0", false));
        assert!(is_bind_allowed("100.127.255.255", false));

        // Public / private-LAN / wildcard / hostname are all refused.
        assert!(!is_bind_allowed("0.0.0.0", false));
        assert!(!is_bind_allowed("192.168.1.10", false));
        assert!(!is_bind_allowed("10.0.0.5", false));
        assert!(!is_bind_allowed("8.8.8.8", false));
        assert!(!is_bind_allowed("100.128.0.1", false)); // just past 100.64/10
        assert!(!is_bind_allowed("100.63.255.255", false)); // just before
        assert!(!is_bind_allowed("example.com", false)); // hostname, not an IP
    }
    #[test]
    fn bind_allow_public_permits_everything() {
        for a in ["0.0.0.0", "192.168.1.10", "8.8.8.8", "example.com", "127.0.0.1"] {
            assert!(is_bind_allowed(a, true), "{a} should be allowed when public");
        }
    }
}
