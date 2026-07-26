import Foundation

// The bounded retry both model pickers (iOS `ModelPickerMenu`, macOS `MacModelPickerMenu`)
// use to fill their model list.
//
// The bug this replaces: both pickers ran
//
//     while !Task.isCancelled && state == nil {
//         if config.isConfigured { state = try? await fetchModels(); if state != nil { break } }
//         try? await Task.sleep(for: .seconds(3))
//     }
//
// whose only exit other than cancellation is SUCCESS. A bridge that cannot serve
// `GET /jesse/models` — the laptop asleep, off the tailnet, an older bridge, a probe
// failure — makes the condition permanently false, so the loop re-fetches every 3
// seconds for as long as a conversation is open. Measured on an idle open conversation:
// 44 requests in 135 s (19.6/min, one every 3.07 s) with no backoff and no end, and a
// network wake is the expensive part of that on a phone. Worse, an UNPAIRED app skips
// the fetch and still sleeps-and-loops forever, spinning on a condition no amount of
// retrying can satisfy.
//
// The doc comment on the old loop said "a slow or briefly-unreachable bridge fills in
// without user action" — "briefly" was the intent all along; only the code was
// unbounded. So: a short, backed-off, FINITE burst of attempts, then stop. The picker
// keeps showing the resolved model either way (`ModelSelectionResolver.resolvedLabel`
// is defined for a nil state), and reopening the conversation starts a fresh burst.

/// The retry cadence for filling the model list: a bounded, backed-off burst.
///
/// Pure and `nonisolated` so the whole policy — how many attempts, how far apart, and
/// crucially *that it terminates* — is unit-testable with no network, no clock, and no UI.
public enum ModelListRetry {
    /// Delay before the *next* attempt, given how many attempts have already been made
    /// (1 = one attempt done). `nil` means "stop": the burst is over.
    ///
    /// 1 → 2 → 4 → 8 s, then stop. Four attempts spanning ~15 s, which covers the case
    /// the retry exists for (a bridge that is slow to answer, or reachable a moment from
    /// now) without turning a permanently-unreachable bridge into a standing poll.
    public static func delay(afterAttempt attempts: Int) -> TimeInterval? {
        guard attempts >= 1, attempts < maxAttempts else { return nil }
        return firstDelay * pow(backoffFactor, Double(attempts - 1))
    }

    /// The total number of fetch attempts one burst makes.
    public static let maxAttempts = 4
    /// The wait after the first failed attempt; each later wait multiplies by `backoffFactor`.
    public static let firstDelay: TimeInterval = 1
    public static let backoffFactor: Double = 2

    /// Every delay one full burst waits, in order — the sequence a test can assert
    /// against, and whose finiteness IS the fix.
    public static var delays: [TimeInterval] {
        (1...).lazy.map { delay(afterAttempt: $0) }
            .prefix { $0 != nil }
            .map { $0! }
    }
}

/// Drives one bounded burst of model-list fetches.
///
/// Everything it touches is injected — whether the app is paired, the fetch, and the
/// sleep — so the loop itself (not just its cadence) is testable: that it stops after
/// `ModelListRetry.maxAttempts` failures, that it stops on the first success, and that
/// an unpaired app performs **no** attempts and **no** sleeps rather than spinning.
///
/// - Parameters:
///   - isConfigured: whether the bridge is paired. Unpaired short-circuits: there is
///     nothing to fetch, and no amount of retrying while this view is up can change
///     that (pairing tears the conversation down and comes back through Settings).
///   - fetch: one attempt; `nil` means it failed.
///   - sleep: how to wait between attempts. Injected so a test drives the cadence with
///     no real time, and records what was waited.
/// - Returns: the loaded list, or `nil` when the burst ran out of attempts.
@MainActor
public func loadModelList(
    isConfigured: Bool,
    fetch: @MainActor () async -> ModelSwitchState?,
    sleep: @MainActor (TimeInterval) async -> Void
) async -> ModelSwitchState? {
    guard isConfigured else { return nil }
    var attempts = 0
    while !Task.isCancelled {
        if let state = await fetch() { return state }
        attempts += 1
        guard !Task.isCancelled, let wait = ModelListRetry.delay(afterAttempt: attempts) else {
            return nil
        }
        await sleep(wait)
    }
    return nil
}
