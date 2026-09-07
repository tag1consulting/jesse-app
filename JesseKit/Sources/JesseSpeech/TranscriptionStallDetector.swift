import Foundation

/// The give-up rule for a long transcription, expressed over PROGRESS rather than over
/// the clock.
///
/// The phone's existing watch-relay transcriber bounds its wait at 30 seconds of wall
/// time and cancels the recognition task when that fires. For a few seconds of dictation
/// that is a sensible guard against a wedged recognizer. For an hour of audio it is a
/// guarantee of failure: transcribing sixty minutes takes many minutes of real time, so
/// a fixed deadline fires on every single long recording and throws away work that was
/// going perfectly well.
///
/// The question a watchdog should be asking is not "has this taken long?" but "has this
/// stopped?" — so this type times the gap since the last time progress ADVANCED, and
/// resets that clock on every advance. A sixty-minute file that keeps producing results
/// never trips it however long it runs; a recognizer that wedges trips it in
/// `limit` seconds whether it wedged at minute one or minute fifty.
///
/// Pure and clock-free: the caller passes the current time in. That is what lets the
/// policy be tested exactly — an hour of progress in a few microseconds of test — with
/// no sleeping and no flakiness.
public struct TranscriptionStallDetector: Sendable, Equatable {
    /// Seconds without an advance before the work is judged stalled.
    ///
    /// Two minutes, not thirty seconds. The gaps this must tolerate are real and
    /// blameless: a stretch of silence or music in the recording produces no results,
    /// and a speech model being fetched for a language used for the first time reports
    /// its own progress on its own schedule. Two minutes is far longer than either and
    /// still far shorter than a person's patience with a screen that has stopped moving.
    public static let defaultLimit: TimeInterval = 120

    public let limit: TimeInterval

    /// The largest progress marker seen so far, in whatever unit the current phase
    /// measures. Markers from different phases are not comparable — see `restart`.
    public private(set) var marker: Double
    /// When `marker` last increased.
    public private(set) var lastAdvanceAt: TimeInterval

    public init(limit: TimeInterval = TranscriptionStallDetector.defaultLimit,
                startedAt: TimeInterval) {
        self.limit = limit
        self.marker = -.infinity
        self.lastAdvanceAt = startedAt
    }

    /// Record a progress marker observed at `now`.
    ///
    /// Only an INCREASE counts. A recognizer that keeps emitting results for the same
    /// audio range is not making progress, and a run of identical markers must trip the
    /// detector exactly as silence from the engine would.
    ///
    /// - Returns: true iff this marker advanced the work.
    @discardableResult
    public mutating func note(marker newMarker: Double, at now: TimeInterval) -> Bool {
        guard newMarker > marker else { return false }
        marker = newMarker
        lastAdvanceAt = now
        return true
    }

    /// Begin measuring a new phase: the clock restarts and the marker is forgotten.
    ///
    /// Needed because the phases measure different things — a model download reports a
    /// 0...1 fraction, transcription reports seconds of audio consumed — so carrying a
    /// marker across the boundary would either suppress a real stall (0.9 > 0.0 seconds
    /// of audio, forever) or invent one.
    public mutating func restart(at now: TimeInterval) {
        marker = -.infinity
        lastAdvanceAt = now
    }

    /// Has the work stopped making progress for longer than `limit`?
    public func isStalled(at now: TimeInterval) -> Bool {
        now - lastAdvanceAt > limit
    }
}
