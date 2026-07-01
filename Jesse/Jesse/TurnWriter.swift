import Foundation
import SwiftData

// The persistence half of completing a turn, extracted from `RunCoordinator.finish`.
// It owns exactly three concerns: resolving the destination thread, the SwiftData
// append + save, and the idempotency-on-`jobId` key — nothing about the spinner,
// the error banner, or the spoken reply, which stay run-state concerns on the
// coordinator. `finish` is now a thin mapper from this type's `Outcome` to those
// side effects, so the "what gets written" logic lives in one testable place.

@MainActor
struct TurnWriter {
    /// How a turn's mutations are persisted. Defaults to a real `context.save()`;
    /// the coordinator passes its injected `save` seam (shared with the optimistic
    /// user-turn save) so a test can force a failure deterministically.
    let save: @MainActor (ModelContext) throws -> Void

    init(save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) {
        self.save = save
    }

    /// What writing a completed reply did. The coordinator maps each case to the
    /// run-state it owns (recoverable error + Re-check, or speak + clear), so the
    /// invariant "after a turn the app shows either the reply or a recoverable
    /// error — never a silent stop" is upheld jointly.
    enum Outcome: Equatable {
        /// The thread couldn't be resolved (held ref absent and the by-id re-fetch
        /// found nothing) — keep the job retained, surface Re-check, don't drop it.
        case unresolvableThread
        /// The reply was genuinely empty (no screen text and no spoken text) —
        /// surface Re-check rather than append a blank turn.
        case empty
        /// This job's reply was already delivered to the thread (a Re-check/resume
        /// re-polled a completed job). No second turn is appended; only the save is
        /// retried. `saved` is whether that retry succeeded.
        case alreadyDelivered(saved: Bool)
        /// A fresh `jesse` turn was appended (with the session id + idempotency key).
        /// `saved` is whether persisting it succeeded; on `false` the in-memory turn
        /// still shows and the job stays retained for a Re-check retry.
        case delivered(saved: Bool)
    }

    /// Append a completed reply as a `jesse` turn and persist it. Prefers the live
    /// `thread` reference the send path holds; falls back to a by-id fetch on the
    /// resume/recheck path (`thread == nil`). Idempotent on `jobId`: a re-entry for a
    /// job already delivered retries only the save. Never records an empty reply.
    func write(threadID: UUID, thread: JesseThread?, reply: JesseReply,
               jobId: String?, context: ModelContext) -> Outcome {
        // (1) Resolve the destination. Prefer the held reference; fall back to a
        // by-id fetch only when there isn't one (resume/recheck).
        guard let target = thread ?? fetchThread(threadID, context: context) else {
            Log.run.error("finish: reply for thread \(threadID) has no resolvable thread " +
                  "(re-fetch returned nil) — retaining job_id for Re-check, not dropping the reply")
            return .unresolvableThread
        }

        // (2) Idempotency: this exact job's reply already landed in this thread (a
        // Re-check / resume re-ran completion for a job whose save had failed). Do
        // NOT append again — just retry the persist so a previously-failed save can
        // now succeed.
        if let jobId, target.lastDeliveredJobId == jobId {
            Log.run.notice("finish: job \(jobId) already delivered to thread \(threadID) — " +
                  "retrying the save only, not re-appending")
            do {
                try save(context)
            } catch {
                Log.run.error("finish: retry save() failed for thread \(threadID): \(error.localizedDescription) — " +
                      "still retaining job_id for Re-check")
                return .alreadyDelivered(saved: false)
            }
            return .alreadyDelivered(saved: true)
        }

        // (3) Decide what to record. Prefer the screen text; when it's empty, fall
        // back to the spoken line — a spoken-only reply's content lives there and
        // must not be lost. Only when BOTH are empty is the reply genuinely empty.
        let displayText = reply.displayText
        let recordedText: String
        if !displayText.isEmpty {
            recordedText = displayText
        } else if !reply.spokenText.isEmpty {
            recordedText = reply.spokenText
        } else {
            Log.run.error("finish: genuinely empty reply for thread \(threadID) " +
                  "(no screen text, no spoken text) — surfacing Re-check rather than a blank turn")
            return .empty
        }

        let turn = Turn(role: .jesse, text: recordedText)
        target.turns.append(turn)
        target.sessionId = reply.sessionId ?? target.sessionId
        target.updatedAt = Date()
        if let jobId { target.lastDeliveredJobId = jobId }

        // (4) Real error handling, not `try?`. The in-memory append above already
        // shows the reply; on a save failure the in-memory turn + idempotency key
        // persist on the live object, so a same-session Re-check sees the key match
        // (step 2) and retries the save without re-appending.
        do {
            try save(context)
        } catch {
            Log.run.error("finish: context.save() failed for thread \(threadID): \(error.localizedDescription) — " +
                  "reply is shown but unsaved; retaining job_id for Re-check")
            return .delivered(saved: false)
        }
        return .delivered(saved: true)
    }

    private func fetchThread(_ id: UUID, context: ModelContext) -> JesseThread? {
        var descriptor = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
