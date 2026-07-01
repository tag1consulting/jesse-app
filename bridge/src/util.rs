use crate::*;

// ---- Poison-tolerant locking (M3) -----------------------------------------
//
// Every `std::sync::Mutex` in the bridge guards a plain collection or flag — a
// HashMap of jobs/streams/aborts, a rate-bucket, a token-bucket, the cached
// APNs JWT, the notify set, the device token. None of them carry an invariant
// that a panic mid-update could leave half-applied in a way the next caller
// can't cope with. So if a thread panics while holding one of these locks, the
// guarded value is still structurally valid and recovering it is the right move
// — far better than the default `.lock_ok()`, where one panicked turn
// poisons the mutex and every subsequent lock panics too, cascading a single
// failure into a bridge-wide outage. `lock_ok` recovers the guard from a
// poisoned lock (`PoisonError::into_inner`) instead of unwrapping.
pub trait MutexExt<T> {
    fn lock_ok(&self) -> std::sync::MutexGuard<'_, T>;
}

impl<T> MutexExt<T> for Mutex<T> {
    fn lock_ok(&self) -> std::sync::MutexGuard<'_, T> {
        self.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// A short, OS-seeded random hex string for scratch dir / file names. Not a
/// security boundary (the dir is 0700 and single-user); `create_new` below is
/// what actually guarantees no collision.
pub fn random_hex() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let r = std::collections::hash_map::RandomState::new().hash_one(n);
    format!("{r:016x}")
}
