import Foundation

// A PURE end-of-speech detector over audio metering samples. Given the power
// readings AVAudioRecorder produces while recording (average power in dBFS, where
// 0 dB is full-scale/loud and −160 dB is silent), it decides whether to keep
// listening or stop — and why. It holds no audio, no timers, and no AVFoundation:
// the watch recorder feeds it samples on a tick, and the tests feed it crafted
// sample arrays to pin the start/stop/timeout boundaries exactly.
//
// The rules the watch UX wants ("single tap, auto-stop on ~1.5 s of silence, with
// a hard max-record cap"):
//   * Wait for the user to actually start speaking before trailing-silence can
//     stop the take — so a slow starter isn't cut off before their first word.
//   * Once speech has been heard, stop after `trailingSilence` of continuous quiet.
//   * Always stop at `maxDuration`, whether or not speech was ever heard (the hard
//     cap and the "user never spoke" timeout are the same ceiling).

/// One metering reading: seconds since recording began and the average power in
/// dBFS at that instant.
public nonisolated struct MeterSample: Equatable, Sendable {
    public let t: TimeInterval
    public let power: Float
    public init(t: TimeInterval, power: Float) {
        self.t = t
        self.power = power
    }
}

/// Why recording stopped (or that it should keep going).
public nonisolated enum SilenceDecision: Equatable, Sendable {
    /// Keep recording.
    case listening
    /// Stop: `trailingSilence` of quiet elapsed after speech was heard.
    case stopSilence(at: TimeInterval)
    /// Stop: the hard `maxDuration` cap was reached (also the "never spoke" timeout).
    case stopMaxDuration(at: TimeInterval)
}

/// The tunable thresholds, defaulted to the values the watch app uses. Pure and
/// value-typed so a test constructs one with its own numbers.
public nonisolated struct SilenceDetector: Sendable {
    /// A sample at or above this power (dBFS) counts as speech; below it is silence.
    public let speechThreshold: Float
    /// Continuous quiet of at least this long, AFTER speech, ends the take.
    public let trailingSilence: TimeInterval
    /// Hard ceiling on the whole take, regardless of speech (and the timeout for a
    /// take where the user never spoke).
    public let maxDuration: TimeInterval

    public init(speechThreshold: Float = -30,
                trailingSilence: TimeInterval = 1.5,
                maxDuration: TimeInterval = 12) {
        self.speechThreshold = speechThreshold
        self.trailingSilence = trailingSilence
        self.maxDuration = maxDuration
    }

    /// The decision given every sample observed so far (chronological order not
    /// required — the evaluator sorts by time). Pure: same samples in, same decision
    /// out, no state retained between calls.
    public func decide(samples: [MeterSample]) -> SilenceDecision {
        guard let latest = samples.map(\.t).max() else { return .listening }

        // The hard cap / never-spoke timeout wins over everything.
        if latest >= maxDuration { return .stopMaxDuration(at: latest) }

        // Trailing silence only applies once the user has actually spoken.
        let speechTimes = samples.filter { $0.power >= speechThreshold }.map(\.t)
        guard let lastSpeech = speechTimes.max() else { return .listening }

        if latest - lastSpeech >= trailingSilence {
            return .stopSilence(at: latest)
        }
        return .listening
    }
}
