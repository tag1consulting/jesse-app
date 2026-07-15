//! **Circuit breaker** (Piece 4) — a tiny, shared, clock-injectable gate that stops
//! the bridge from hammering a hosted backend that is clearly down. After
//! [`BREAKER_THRESHOLD`] CONSECUTIVE transport-class hosted failures ([`failclass`])
//! it OPENS: for [`BREAKER_COOLDOWN_SECS`] the bridge goes local-first (skips the
//! hosted attempt entirely and serves the emergency local path), then the next turn
//! retries hosted. Any hosted SUCCESS resets it.
//!
//! It only changes behavior when the emergency fallback is armed — skipping hosted is
//! only safe when there is a local path to serve instead — so `handlers::jesse` gates
//! `should_skip_hosted` behind `cfg.emergency_local && cfg.vaultqa_backend.is_some()`.
//!
//! All timing goes through an injected `Instant` (`now`) so the cooldown is tested
//! deterministically without sleeping.

use crate::*;

/// Consecutive transport-class hosted failures that trip the breaker.
pub const BREAKER_THRESHOLD: u32 = 2;

/// How long the breaker stays open (local-first) before the next turn retries hosted.
pub const BREAKER_COOLDOWN_SECS: u64 = 300;

#[derive(Debug)]
struct BreakerState {
    /// Consecutive transport-class failures since the last success.
    consecutive: u32,
    /// While `Some(t)`, the breaker is open until `t` (local-first).
    open_until: Option<Instant>,
}

/// Shared breaker state, cheaply clonable behind an `Arc` (held in `AppState`).
#[derive(Debug)]
pub struct CircuitBreaker {
    inner: Mutex<BreakerState>,
}

impl Default for CircuitBreaker {
    fn default() -> Self {
        Self::new()
    }
}

impl CircuitBreaker {
    pub fn new() -> Self {
        CircuitBreaker {
            inner: Mutex::new(BreakerState {
                consecutive: 0,
                open_until: None,
            }),
        }
    }

    /// Whether the hosted attempt should be SKIPPED right now (breaker open). When the
    /// cooldown has elapsed this returns `false` (the next turn retries hosted); the
    /// counter is left intact, so if that retry fails transport-class again the breaker
    /// re-opens immediately, and only a success clears it.
    pub fn should_skip_hosted(&self, now: Instant) -> bool {
        self.inner
            .lock_ok()
            .open_until
            .is_some_and(|t| now < t)
    }

    /// Record a hosted SUCCESS — resets the breaker completely (closed, counter 0).
    pub fn record_success(&self) {
        let mut s = self.inner.lock_ok();
        s.consecutive = 0;
        s.open_until = None;
    }

    /// Record a transport-class hosted FAILURE. Increments the consecutive counter and,
    /// once it reaches [`BREAKER_THRESHOLD`], opens the breaker for the cooldown from
    /// `now`.
    pub fn record_transport_failure(&self, now: Instant) {
        let mut s = self.inner.lock_ok();
        s.consecutive = s.consecutive.saturating_add(1);
        if s.consecutive >= BREAKER_THRESHOLD {
            s.open_until = Some(now + Duration::from_secs(BREAKER_COOLDOWN_SECS));
        }
    }

    /// Consecutive transport-failure count (tests / introspection).
    pub fn consecutive(&self) -> u32 {
        self.inner.lock_ok().consecutive
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cd() -> Duration {
        Duration::from_secs(BREAKER_COOLDOWN_SECS)
    }

    #[test]
    fn stays_closed_below_the_threshold() {
        let b = CircuitBreaker::new();
        let t0 = Instant::now();
        b.record_transport_failure(t0);
        assert_eq!(b.consecutive(), 1);
        assert!(!b.should_skip_hosted(t0), "one failure must not open the breaker");
    }

    #[test]
    fn opens_after_the_threshold_and_skips_within_cooldown() {
        let b = CircuitBreaker::new();
        let t0 = Instant::now();
        b.record_transport_failure(t0);
        b.record_transport_failure(t0);
        assert!(b.should_skip_hosted(t0), "two consecutive transport failures open it");
        // Still open partway through the cooldown.
        assert!(b.should_skip_hosted(t0 + cd() - Duration::from_secs(1)));
    }

    #[test]
    fn retries_hosted_after_the_cooldown_elapses() {
        let b = CircuitBreaker::new();
        let t0 = Instant::now();
        b.record_transport_failure(t0);
        b.record_transport_failure(t0);
        assert!(b.should_skip_hosted(t0));
        // One second past the cooldown → the next turn retries hosted.
        assert!(!b.should_skip_hosted(t0 + cd() + Duration::from_secs(1)));
    }

    #[test]
    fn a_success_resets_the_breaker() {
        let b = CircuitBreaker::new();
        let t0 = Instant::now();
        b.record_transport_failure(t0);
        b.record_transport_failure(t0);
        assert!(b.should_skip_hosted(t0));
        b.record_success();
        assert_eq!(b.consecutive(), 0);
        assert!(!b.should_skip_hosted(t0), "success closes the breaker immediately");
    }

    #[test]
    fn a_success_between_failures_prevents_tripping() {
        let b = CircuitBreaker::new();
        let t0 = Instant::now();
        b.record_transport_failure(t0);
        b.record_success(); // breaks the "consecutive" streak
        b.record_transport_failure(t0);
        assert_eq!(b.consecutive(), 1);
        assert!(!b.should_skip_hosted(t0), "non-consecutive failures must not open it");
    }

    #[test]
    fn re_opens_when_a_post_cooldown_retry_also_fails() {
        let b = CircuitBreaker::new();
        let t0 = Instant::now();
        b.record_transport_failure(t0);
        b.record_transport_failure(t0);
        let later = t0 + cd() + Duration::from_secs(1);
        assert!(!b.should_skip_hosted(later), "cooldown elapsed → retry hosted");
        // The retry also fails transport-class → the breaker re-opens from `later`.
        b.record_transport_failure(later);
        assert!(b.should_skip_hosted(later), "a failed retry re-opens the breaker");
    }
}
