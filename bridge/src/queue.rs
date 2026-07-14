use crate::*;

// ---- Bounded turn queue in front of the concurrency semaphore --------------
//
// The concurrency semaphore (`AppState.sem`, sized from `max_concurrency`) bounds
// how many turns run at once. With the single-writer default (`max_concurrency`
// = 1) a second client's turn must WAIT for the first to finish rather than be
// rejected — so it can't clobber the vault while another turn is mid-write. This
// gate bounds that wait queue so a burst of clients can't pile up unboundedly:
// `max_queued` turns may wait; beyond that, load is shed with 429 exactly as
// before. `max_queued == 0` reproduces the old immediate-429 behavior (no queue).

/// Activity hint broadcast on a queued turn's live stream while it waits for a
/// permit. Reuses the existing `activity` SSE frame (no new frame type); the app
/// renders it as a coarse status line under the spinner.
pub const QUEUED_ACTIVITY: &str = "queued behind another turn";

/// A turn's admission decision, returned by [`QueueGate::admit`] on the request
/// path and carried into the spawned turn task.
pub enum Admission {
    /// A permit was free right now — the turn runs immediately. Holds the owned
    /// permit; move it into the turn task and keep it for the turn's life.
    Ready(OwnedSemaphorePermit),
    /// No permit was free, but the wait queue had room — the turn is queued. The
    /// task must `await` [`QueueTicket::wait_for_permit`] before spawning `claude`;
    /// the turn/timeout clock only starts then, never while queued.
    Queued(QueueTicket),
}

/// Bounds concurrent turns (via the semaphore) AND the queue of turns waiting for
/// a permit (via `max_queued`). Cheaply clonable behind an `Arc`.
pub struct QueueGate {
    sem: Arc<Semaphore>,
    // Number of turns currently WAITING for a permit (admitted to the queue but
    // not yet running). A turn holding a permit is not counted here.
    waiting: Mutex<usize>,
    max_queued: usize,
}

impl QueueGate {
    /// Build a gate over the shared concurrency semaphore. `max_queued` is the
    /// depth of the wait queue in front of it (0 → no queue: an unavailable permit
    /// sheds 429 immediately, the pre-queue behavior).
    pub fn new(sem: Arc<Semaphore>, max_queued: usize) -> Arc<Self> {
        Arc::new(QueueGate {
            sem,
            waiting: Mutex::new(0),
            max_queued,
        })
    }

    /// Turns currently waiting for a permit. For tests/introspection only.
    pub fn waiting(&self) -> usize {
        *self.waiting.lock_ok()
    }

    /// Decide whether to run a new turn now, queue it, or shed it:
    /// - a permit is free right now → `Some(Ready(permit))` (run immediately);
    /// - no free permit but `waiting < max_queued` → `Some(Queued(ticket))`
    ///   (spawn the turn and `await` a permit inside it);
    /// - no free permit and the queue is full → `None` (shed with 429).
    ///
    /// A `Queued` admission reserves its queue slot synchronously here (increments
    /// `waiting`); the returned [`QueueTicket`] releases it exactly once — when the
    /// turn acquires a permit (`wait_for_permit`) OR when the ticket is dropped
    /// unused (the turn was cancelled or errored out before running). So a
    /// cancelled queued turn always frees its slot and never leaks it.
    ///
    /// Fairness note: `try_acquire` can barge ahead of an already-queued waiter
    /// when a permit frees, so admission is not strictly FIFO. That's harmless for
    /// this single-user bridge (every admitted turn still runs and completes, and
    /// the queue depth is bounded); it is not a scheduler.
    pub fn admit(self: &Arc<Self>) -> Option<Admission> {
        // Fast path: a permit is free right now — run without queuing.
        if let Ok(permit) = self.sem.clone().try_acquire_owned() {
            return Some(Admission::Ready(permit));
        }
        // No permit. Admit to the bounded wait queue if it has room.
        let mut waiting = self.waiting.lock_ok();
        if *waiting >= self.max_queued {
            return None; // queue full → shed (429)
        }
        *waiting += 1;
        Some(Admission::Queued(QueueTicket {
            gate: self.clone(),
            counted: true,
        }))
    }

    fn release_waiter(&self) {
        let mut waiting = self.waiting.lock_ok();
        *waiting = waiting.saturating_sub(1);
    }
}

/// A reserved slot in the wait queue. Drop-safe: while `counted`, it holds one
/// unit of `waiting`; releasing (on permit acquisition or on drop) is idempotent
/// and happens exactly once.
pub struct QueueTicket {
    gate: Arc<QueueGate>,
    counted: bool,
}

impl QueueTicket {
    /// Block until a concurrency permit is free, then leave the wait queue (we're
    /// about to run, not wait) and return the owned permit. If the turn task is
    /// aborted (a cancel) while this future is pending, the ticket is dropped
    /// instead — its `Drop` frees the queue slot and no permit is ever taken, so a
    /// cancelled queued turn spawns no `claude` and releases nothing it doesn't
    /// hold.
    pub async fn wait_for_permit(mut self) -> OwnedSemaphorePermit {
        let permit = self
            .gate
            .sem
            .clone()
            .acquire_owned()
            .await
            .expect("concurrency semaphore is never closed");
        // We hold a permit now — leave the wait queue exactly once. (No `.await`
        // between acquiring and this decrement, so a cancel can't interpose here.)
        self.counted = false;
        self.gate.release_waiter();
        permit
    }
}

impl Drop for QueueTicket {
    fn drop(&mut self) {
        if self.counted {
            self.gate.release_waiter();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gate(permits: usize, max_queued: usize) -> Arc<QueueGate> {
        QueueGate::new(Arc::new(Semaphore::new(permits)), max_queued)
    }

    #[test]
    fn admit_ready_when_a_permit_is_free() {
        let g = gate(1, 4);
        match g.admit() {
            Some(Admission::Ready(_permit)) => {}
            _ => panic!("a free permit must admit Ready"),
        }
        // The Ready arm didn't touch the wait queue.
        assert_eq!(g.waiting(), 0);
    }

    #[test]
    fn admit_queues_when_no_permit_but_room() {
        let g = gate(1, 4);
        // Take the only permit and hold it.
        let _held = match g.admit() {
            Some(Admission::Ready(p)) => p,
            _ => panic!("first admit should be Ready"),
        };
        // No permit free now → the next turn is queued and counted. Keep the
        // ticket alive (a dropped ticket would immediately free the slot).
        let _ticket = match g.admit() {
            Some(Admission::Queued(t)) => t,
            _ => panic!("no permit + room must admit Queued"),
        };
        assert_eq!(g.waiting(), 1, "a queued turn counts toward the wait queue");
    }

    #[test]
    fn admit_sheds_when_queue_full() {
        // One permit, queue depth 1.
        let g = gate(1, 1);
        let _held = match g.admit() {
            Some(Admission::Ready(p)) => p,
            _ => panic!("first admit should be Ready"),
        };
        let _queued = match g.admit() {
            Some(Admission::Queued(t)) => t,
            _ => panic!("second admit should be Queued"),
        };
        assert_eq!(g.waiting(), 1);
        // Queue is now full (waiting == max_queued) → shed.
        assert!(g.admit().is_none(), "a full queue must shed (429)");
    }

    #[test]
    fn zero_max_queued_sheds_instead_of_queuing() {
        // max_queued 0 == the pre-queue behavior: no permit → immediate 429.
        let g = gate(1, 0);
        let _held = match g.admit() {
            Some(Admission::Ready(p)) => p,
            _ => panic!("first admit should be Ready"),
        };
        assert!(
            g.admit().is_none(),
            "with max_queued=0 an unavailable permit sheds immediately"
        );
        assert_eq!(g.waiting(), 0);
    }

    #[test]
    fn dropping_an_unused_ticket_frees_the_queue_slot() {
        let g = gate(1, 1);
        let _held = match g.admit() {
            Some(Admission::Ready(p)) => p,
            _ => panic!("Ready"),
        };
        let ticket = match g.admit() {
            Some(Admission::Queued(t)) => t,
            _ => panic!("Queued"),
        };
        assert_eq!(g.waiting(), 1);
        // A cancelled queued turn drops its ticket without ever acquiring a permit.
        drop(ticket);
        assert_eq!(g.waiting(), 0, "dropping an unused ticket frees the slot");
        // The freed slot is reusable: a new turn can queue again (keep it alive).
        let _reuse = match g.admit() {
            Some(Admission::Queued(t)) => t,
            _ => panic!("the freed slot must admit a new Queued turn"),
        };
        assert_eq!(g.waiting(), 1);
    }

    #[tokio::test]
    async fn wait_for_permit_yields_once_a_permit_frees_and_leaves_the_queue() {
        let g = gate(1, 2);
        let held = match g.admit() {
            Some(Admission::Ready(p)) => p,
            _ => panic!("Ready"),
        };
        let ticket = match g.admit() {
            Some(Admission::Queued(t)) => t,
            _ => panic!("Queued"),
        };
        assert_eq!(g.waiting(), 1);
        // Spawn the waiter; it blocks until we drop the held permit.
        let gc = g.clone();
        let waiter = tokio::spawn(async move {
            let _permit = ticket.wait_for_permit().await;
            // Once we hold the permit we've left the wait queue.
            assert_eq!(gc.waiting(), 0);
        });
        // Give the waiter a moment to park on the semaphore, then free the permit.
        tokio::time::sleep(Duration::from_millis(50)).await;
        drop(held);
        waiter.await.unwrap();
        assert_eq!(g.waiting(), 0, "acquiring a permit leaves the wait queue");
    }

    #[tokio::test]
    async fn aborting_a_waiting_ticket_frees_the_slot_and_takes_no_permit() {
        let g = gate(1, 2);
        let _held = match g.admit() {
            Some(Admission::Ready(p)) => p,
            _ => panic!("Ready"),
        };
        let ticket = match g.admit() {
            Some(Admission::Queued(t)) => t,
            _ => panic!("Queued"),
        };
        assert_eq!(g.waiting(), 1);
        // A queued turn's task, parked in wait_for_permit, is aborted (cancel).
        let handle = tokio::spawn(async move {
            let _permit = ticket.wait_for_permit().await;
            unreachable!("the permit never frees; this task is aborted first");
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        handle.abort();
        let _ = handle.await;
        // The dropped ticket freed its slot, and it never took the held permit.
        assert_eq!(g.waiting(), 0, "aborting a waiting ticket frees the slot");
        assert_eq!(
            g.sem.available_permits(),
            0,
            "the aborted waiter never acquired the held permit"
        );
    }
}
