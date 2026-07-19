import XCTest
@testable import Jesse

/// The pure end-of-speech detector. Pins the start/stop/timeout boundaries with
/// crafted metering samples — no audio hardware. `power` is dBFS: values at/above
/// the threshold are "speech", below are "silence".
@MainActor
final class SilenceDetectorTests: XCTestCase {

    private let det = SilenceDetector(speechThreshold: -30, trailingSilence: 1.5, maxDuration: 12)

    private func samples(_ pairs: [(TimeInterval, Float)]) -> [MeterSample] {
        pairs.map { MeterSample(t: $0.0, power: $0.1) }
    }

    func testNoSamplesKeepsListening() {
        XCTAssertEqual(det.decide(samples: []), .listening)
    }

    func testSilenceBeforeAnySpeechKeepsListening() {
        // The user hasn't spoken yet — trailing silence must NOT cut them off before
        // their first word (only the max cap can end a never-spoke take).
        let s = samples([(0.0, -50), (0.5, -55), (1.0, -48), (2.0, -60)])
        XCTAssertEqual(det.decide(samples: s), .listening)
    }

    func testSpeechThenShortSilenceKeepsListening() {
        // Spoke, then only 1.0 s of quiet (< 1.5 s trailing) — still listening.
        let s = samples([(0.0, -50), (0.5, -12), (1.0, -10), (1.5, -55), (2.0, -58)])
        XCTAssertEqual(det.decide(samples: s), .listening)
    }

    func testSpeechThenTrailingSilenceStops() {
        // Spoke at 1.0 s, then continuous quiet through 2.6 s (1.6 s ≥ 1.5 s) — stop.
        let s = samples([(0.0, -50), (0.5, -12), (1.0, -10), (1.6, -50), (2.2, -55), (2.6, -58)])
        XCTAssertEqual(det.decide(samples: s), .stopSilence(at: 2.6))
    }

    func testTrailingSilenceExactlyAtThresholdStops() {
        // Last speech at 1.0 s, latest sample at 2.5 s → exactly 1.5 s of silence.
        let s = samples([(1.0, -10), (2.5, -55)])
        XCTAssertEqual(det.decide(samples: s), .stopSilence(at: 2.5))
    }

    func testStillSpeakingKeepsListening() {
        let s = samples([(0.0, -50), (0.5, -12), (1.0, -8), (1.5, -9), (2.0, -7)])
        XCTAssertEqual(det.decide(samples: s), .listening)
    }

    func testMaxDurationStopsEvenWhileSpeaking() {
        // Loud right up to the cap — the hard ceiling still ends it.
        let s = samples([(0.0, -10), (6.0, -8), (12.0, -9)])
        XCTAssertEqual(det.decide(samples: s), .stopMaxDuration(at: 12.0))
    }

    func testMaxDurationStopsWhenUserNeverSpoke() {
        // Silence throughout — the cap is also the never-spoke timeout.
        let s = samples([(0.0, -60), (6.0, -58), (12.5, -60)])
        XCTAssertEqual(det.decide(samples: s), .stopMaxDuration(at: 12.5))
    }

    func testMaxDurationWinsOverTrailingSilence() {
        // Both conditions true at the cap; the max-duration reason takes precedence.
        let s = samples([(0.0, -10), (1.0, -12), (12.0, -60)])
        XCTAssertEqual(det.decide(samples: s), .stopMaxDuration(at: 12.0))
    }
}
