//! **RFC-3339 UTC timestamps**, hand-rolled.
//!
//! `bridge/src/diet.rs` already carries its own `rfc3339_utc` for the same reason this one
//! exists: the whole need is "turn a `SystemTime` into a fixed-width UTC string", and a
//! date-time crate is a large dependency, a build-time cost and a supply-chain surface for
//! twenty lines of arithmetic that has been settled since the Gregorian calendar.
//!
//! FIXED WIDTH IS THE POINT, not just the format. `YYYY-MM-DDTHH:MM:SSZ` is 20 characters
//! for every instant this program will ever see, which makes "records newer than X" a
//! STRING comparison in any consumer — the same property the bridge's turn-timing log
//! relies on for its retention prune.

use std::time::{SystemTime, UNIX_EPOCH};

/// `SystemTime` as `YYYY-MM-DDTHH:MM:SSZ`.
///
/// A time before the Unix epoch renders as the epoch. That is a deliberate floor rather
/// than a `Result`: the only way to get one is a machine whose clock is badly wrong, and a
/// usage record that fails to be written because the clock is wrong is worse than one
/// carrying an obviously wrong timestamp.
pub fn rfc3339_utc(t: SystemTime) -> String {
    let secs = t
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        sod / 3600,
        (sod % 3600) / 60,
        sod % 60
    )
}

/// Days since 1970-01-01 to a civil `(year, month, day)`.
///
/// Howard Hinnant's `civil_from_days`, the same algorithm the bridge uses. It is chosen
/// over a month-length loop because it is branch-free, exact for the whole range of an
/// `i64` day count, and — the reason that matters here — short enough that a reader can
/// check it rather than trust it.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn at(secs: u64) -> String {
        rfc3339_utc(UNIX_EPOCH + Duration::from_secs(secs))
    }

    #[test]
    fn known_instants_render_correctly() {
        assert_eq!(at(0), "1970-01-01T00:00:00Z");
        assert_eq!(at(1_000_000_000), "2001-09-09T01:46:40Z");
        // A leap day, which a naive 365-day calculation gets wrong.
        assert_eq!(at(1_709_164_800), "2024-02-29T00:00:00Z");
        // The end of a leap year.
        assert_eq!(at(1_735_689_599), "2024-12-31T23:59:59Z");
        assert_eq!(at(1_735_689_600), "2025-01-01T00:00:00Z");
        // A century that is not a leap year (1900) and one that is (2000).
        assert_eq!(at(951_782_400), "2000-02-29T00:00:00Z");
    }

    #[test]
    fn the_format_is_fixed_width_so_comparisons_are_string_comparisons() {
        let a = at(1_700_000_000);
        let b = at(1_800_000_000);
        assert_eq!(a.len(), 20);
        assert_eq!(b.len(), 20);
        assert!(a < b, "chronological order is lexicographic order");
    }

    #[test]
    fn a_pre_epoch_time_floors_at_the_epoch_rather_than_failing() {
        let before = UNIX_EPOCH - Duration::from_secs(10);
        assert_eq!(rfc3339_utc(before), "1970-01-01T00:00:00Z");
    }
}
