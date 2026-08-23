use super::*;
use serde::Serialize;

// ---- The watchdog's memory ----------------------------------------------------
//
// `<state_dir>/state.json`, rewritten after every tick. Everything here exists because the
// watchdog's rules are stated over TIME, not over an instant: "three consecutive misses",
// "more than five kickstarts in a rolling hour", "stuck for over two hours", "once per
// 24 h". A sentinel that forgot all of that on restart would re-push every dedupe window
// and, worse, would forget it had already given up on a bridge that keeps dying and start
// kickstarting it again — which is the exact loop the give-up rule exists to stop.
//
// Corruption is tolerated the way the scheduler tolerates it: an unreadable or unparseable
// file yields the default, which behaves like a first-ever boot. That can cost one duplicate
// push. The alternative — refusing to start — costs the whole service.

/// The alert kinds, which are also the dedupe keys and the `sentinel.kind` field of every
/// push. One kind per rule, so a disk alert never suppresses a tailnet alert.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AlertKind {
    BridgeDown,
    Autocommit,
    Lock,
    Disk,
    Tailscale,
    Qmd,
    Silence,
}

pub const ALERT_KINDS: [AlertKind; 7] = [
    AlertKind::BridgeDown,
    AlertKind::Autocommit,
    AlertKind::Lock,
    AlertKind::Disk,
    AlertKind::Tailscale,
    AlertKind::Qmd,
    AlertKind::Silence,
];

impl AlertKind {
    pub fn key(self) -> &'static str {
        match self {
            AlertKind::BridgeDown => "bridge-down",
            AlertKind::Autocommit => "autocommit",
            AlertKind::Lock => "lock",
            AlertKind::Disk => "disk",
            AlertKind::Tailscale => "tailscale",
            AlertKind::Qmd => "qmd",
            AlertKind::Silence => "silence",
        }
    }
}

/// One hour, in milliseconds — the kickstart budget's window and several dedupe windows.
pub const HOUR_MS: u64 = 60 * 60 * 1000;

/// More than this many bridge kickstarts inside a rolling hour and the watchdog STOPS
/// restarting it. Five restarts in an hour is not a transient; it is a bridge that cannot
/// stay up, and the sixth kickstart would only bury the evidence deeper.
pub const MAX_KICKSTARTS_PER_HOUR: usize = 5;

/// Consecutive failed `/health` ticks before the watchdog kickstarts the bridge. Three, at a
/// 60 s tick, is three minutes — long enough that a slow boot or one dropped connection
/// never triggers a restart.
pub const BRIDGE_MISSES_BEFORE_KICKSTART: u32 = 3;

/// Everything the watchdog carries across ticks and across its own restarts.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct WatchState {
    /// When the last tick completed, so `/sentinel/status` can show that the watchdog is
    /// itself alive — a status document whose watchdog block is an hour stale is the one
    /// case a green page would be lying.
    pub last_tick_ms: Option<u64>,
    /// Consecutive `/health` failures. Reset to zero by any success.
    pub bridge_misses: u32,
    /// Epoch-ms of each bridge kickstart the watchdog performed, pruned to the last hour.
    pub kickstarts: Vec<u64>,
    /// Set when the kickstart budget was spent and the watchdog stopped restarting the
    /// bridge; cleared the moment the bridge answers again. While set, the give-up push
    /// repeats at most hourly.
    pub bridge_gave_up_ms: Option<u64>,
    /// The last error text `/health` produced, so the give-up push can name it.
    pub bridge_last_error: Option<String>,
    /// When the autocommit log first showed `UNPUBLISHED:` / `CONFLICT` continuously.
    /// Cleared by any `PUBLISHED:` line.
    pub autocommit_bad_since_ms: Option<u64>,
    /// When the unlock rule last removed a stale `index.lock`, so a recurrence inside the
    /// hour is distinguishable from the first one.
    pub last_unlock_ms: Option<u64>,
    /// When the tailnet was first seen offline. Cleared by any online reading.
    pub tailscale_down_since_ms: Option<u64>,
    /// When the watchdog last ran `tailscale up`, so it runs it ONCE per outage.
    pub tailscale_up_ms: Option<u64>,
    /// Last push per [`AlertKind::key`], for the per-kind dedupe windows.
    pub last_push_ms: HashMap<String, u64>,
}

impl WatchState {
    /// Load, tolerating everything. An absent file is a first boot; a corrupt one is treated
    /// as a first boot too, and says so.
    pub fn load(path: &Path) -> WatchState {
        let Ok(text) = std::fs::read_to_string(path) else {
            return WatchState::default();
        };
        match serde_json::from_str(&text) {
            Ok(s) => s,
            Err(e) => {
                eprintln!(
                    "jesse-sentinel: WARNING — {} is unreadable ({e}); starting from a clean \
                     watchdog state. Dedupe windows are reset, so one duplicate alert per \
                     kind is possible.",
                    path.display()
                );
                WatchState::default()
            }
        }
    }

    /// Write atomically (temp + rename), 0600 — the same discipline as the device token.
    /// Best-effort: the watchdog must keep working on a read-only state dir.
    pub fn persist(&self, path: &Path) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent);
        }
        let Ok(text) = serde_json::to_string_pretty(self) else {
            return;
        };
        let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
        let written = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)
            .and_then(|mut f| f.write_all(text.as_bytes()))
            .and_then(|_| std::fs::rename(&tmp, path));
        if let Err(e) = written {
            let _ = std::fs::remove_file(&tmp);
            eprintln!(
                "jesse-sentinel: WARNING — could not persist {} ({e}); the watchdog keeps \
                 running but will forget its windows if it restarts",
                path.display()
            );
        }
    }

    /// Record a bridge kickstart and drop everything older than the rolling hour.
    pub fn note_kickstart(&mut self, at_ms: u64) {
        self.kickstarts.push(at_ms);
        self.prune_kickstarts(at_ms);
    }

    /// Kickstarts still inside the rolling hour ending at `now_ms`.
    pub fn prune_kickstarts(&mut self, now_ms: u64) {
        self.kickstarts
            .retain(|t| now_ms.saturating_sub(*t) < HOUR_MS);
    }

    pub fn kickstarts_last_hour(&self, now_ms: u64) -> usize {
        self.kickstarts
            .iter()
            .filter(|t| now_ms.saturating_sub(**t) < HOUR_MS)
            .count()
    }

    /// Whether the kickstart budget is spent. Strictly MORE than the max, so the fifth
    /// restart in an hour is still allowed and the sixth is not.
    pub fn budget_spent(&self, now_ms: u64) -> bool {
        self.kickstarts_last_hour(now_ms) > MAX_KICKSTARTS_PER_HOUR
    }

    /// Whether an alert of this kind may fire now, given its window. Records the push when
    /// it returns true, so the caller cannot forget to.
    pub fn allow_push(&mut self, kind: AlertKind, now_ms: u64, window_ms: u64) -> bool {
        let last = self.last_push_ms.get(kind.key()).copied();
        let due = match last {
            Some(t) => now_ms.saturating_sub(t) >= window_ms,
            None => true,
        };
        if due {
            self.last_push_ms.insert(kind.key().to_string(), now_ms);
        }
        due
    }

    /// The `watchdog` block of `GET /sentinel/status`.
    pub fn report(&self, now_ms: u64) -> Value {
        json!({
            "last_tick_ms": self.last_tick_ms,
            "bridge_misses": self.bridge_misses,
            "kickstarts_last_hour": self.kickstarts_last_hour(now_ms),
            // Not in the spec's minimum, and the single most important field on the page
            // when it is set: it is the difference between "the bridge is down" and "the
            // bridge is down AND nothing is trying to fix it any more".
            "gave_up_ms": self.bridge_gave_up_ms,
            "last_error": self.bridge_last_error,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kickstart_budget_allows_five_and_stops_at_six() {
        let mut s = WatchState::default();
        let t0 = 1_000_000_000_000u64;
        for i in 0..MAX_KICKSTARTS_PER_HOUR {
            s.note_kickstart(t0 + i as u64 * 1000);
            assert!(
                !s.budget_spent(t0 + 10_000),
                "{} kickstart(s) must still be within budget",
                i + 1
            );
        }
        s.note_kickstart(t0 + 6000);
        assert!(s.budget_spent(t0 + 10_000), "the sixth spends the budget");
    }

    #[test]
    fn kickstarts_age_out_of_the_rolling_hour() {
        let mut s = WatchState::default();
        let t0 = 1_000_000_000_000u64;
        for i in 0..6 {
            s.note_kickstart(t0 + i * 1000);
        }
        assert!(s.budget_spent(t0 + 10_000));
        // The window is measured from each attempt, so it empties gradually: an hour after
        // the FIRST one only the later five are left, and the budget is no longer spent.
        assert_eq!(s.kickstarts_last_hour(t0 + HOUR_MS), 5);
        assert!(!s.budget_spent(t0 + HOUR_MS));
        // An hour past the LAST one they are all gone, and the watchdog is free to try
        // again — that is what "rolling" has to mean, or a bridge that died six times at
        // breakfast is never restarted again.
        let later = t0 + 5000 + HOUR_MS;
        assert_eq!(s.kickstarts_last_hour(later), 0);
        assert!(!s.budget_spent(later));
    }

    #[test]
    fn push_dedupe_respects_each_kind_window() {
        let mut s = WatchState::default();
        let t = 1_000_000_000_000u64;
        let day = 24 * HOUR_MS;
        assert!(s.allow_push(AlertKind::Qmd, t, day), "first push always");
        assert!(!s.allow_push(AlertKind::Qmd, t + HOUR_MS, day));
        assert!(!s.allow_push(AlertKind::Qmd, t + 23 * HOUR_MS, day));
        assert!(s.allow_push(AlertKind::Qmd, t + day, day), "window elapsed");
        // Kinds are independent: a suppressed qmd alert must not suppress a disk alert.
        assert!(s.allow_push(AlertKind::Disk, t + HOUR_MS, day));
    }

    #[test]
    fn state_round_trips_through_the_file() {
        let dir = std::env::temp_dir().join(format!("jesse-sentinel-state-{}", random_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("state.json");
        // A missing file is a clean first boot, not an error.
        assert_eq!(WatchState::load(&path).bridge_misses, 0);

        let mut s = WatchState {
            bridge_misses: 2,
            bridge_last_error: Some("connection refused".to_string()),
            ..Default::default()
        };
        s.note_kickstart(1_700_000_000_000);
        s.last_push_ms.insert("disk".to_string(), 42);
        s.persist(&path);

        let back = WatchState::load(&path);
        assert_eq!(back.bridge_misses, 2);
        assert_eq!(back.kickstarts, vec![1_700_000_000_000]);
        assert_eq!(
            back.bridge_last_error.as_deref(),
            Some("connection refused")
        );
        assert_eq!(back.last_push_ms.get("disk"), Some(&42));

        // Corruption degrades to a clean state rather than taking the service down.
        std::fs::write(&path, b"{not json").unwrap();
        assert_eq!(WatchState::load(&path).bridge_misses, 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_forward_compatible_file_keeps_the_fields_it_understands() {
        // `#[serde(default)]` on the struct: a state file written by an older sentinel (or
        // by a newer one with extra keys) must load, not reset every window to zero.
        let s: WatchState =
            serde_json::from_str(r#"{"bridge_misses":4,"future_key":{"a":1}}"#).unwrap();
        assert_eq!(s.bridge_misses, 4);
        assert!(s.kickstarts.is_empty());
    }

    #[test]
    fn alert_keys_are_unique_and_stable() {
        // The keys are the persisted dedupe map's keys AND the `sentinel.kind` on the wire.
        // A collision would make one rule silence another across a restart.
        let mut seen = std::collections::HashSet::new();
        for k in ALERT_KINDS {
            assert!(seen.insert(k.key()), "duplicate alert key {}", k.key());
        }
        assert_eq!(seen.len(), ALERT_KINDS.len());
    }
}
