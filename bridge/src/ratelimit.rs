use crate::*;

// ---- Rate limit (C3) ------------------------------------------------------
//
// A single-token bridge needs only one bucket. A classic token bucket: capacity
// == refill == `rate_per_min` tokens, refilled continuously over a 60s window.
// One Mutex around two small numbers — lock-light, no background task.

pub struct RateLimiter {
    capacity: f64,
    // Tokens added per second (capacity / 60).
    refill_per_sec: f64,
    inner: Mutex<RateState>,
}

pub struct RateState {
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    pub fn new(per_min: u32) -> Self {
        let capacity = per_min.max(1) as f64;
        RateLimiter {
            capacity,
            refill_per_sec: capacity / 60.0,
            inner: Mutex::new(RateState {
                tokens: capacity,
                last: Instant::now(),
            }),
        }
    }

    /// Try to consume one token. Returns true if allowed, false if the caller
    /// should be rejected with 429.
    pub fn allow(&self) -> bool {
        let now = Instant::now();
        let mut s = self.inner.lock_ok();
        let elapsed = now.saturating_duration_since(s.last).as_secs_f64();
        s.tokens = (s.tokens + elapsed * self.refill_per_sec).min(self.capacity);
        s.last = now;
        if s.tokens >= 1.0 {
            s.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rate_limiter_sheds_burst_beyond_capacity() {
        // Capacity 3: first three allowed, fourth shed.
        let rl = RateLimiter::new(3);
        assert!(rl.allow());
        assert!(rl.allow());
        assert!(rl.allow());
        assert!(!rl.allow(), "burst beyond capacity must be rejected");
    }
}
