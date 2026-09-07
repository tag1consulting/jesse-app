import XCTest
@testable import JesseSpeech

// The two decisions that used to be hardcoded and now are not: which language a
// recording is read in, and when a long transcription is judged dead.
//
// Both are pure over values the caller supplies, which is the point — the language list
// really comes from `SpeechTranscriber.supportedLocales` and the clock really comes from
// `ProcessInfo.systemUptime`, and neither is available to a test that has to be fast,
// offline and deterministic.

final class TranscriptionLocalePolicyTests: XCTestCase {

    /// A plausible slice of what the framework offers.
    private let supported = [
        Locale(identifier: "en-US"),
        Locale(identifier: "en-GB"),
        Locale(identifier: "it-IT"),
        Locale(identifier: "de-DE"),
        Locale(identifier: "fr-FR"),
    ]

    // MARK: - resolve

    func testRememberedLanguageWins() {
        // The whole reason the choice is remembered: someone who records in Italian
        // chooses Italian once, not once per recording, even though the phone is English.
        let chosen = TranscriptionLocalePolicy.resolve(remembered: "it-IT",
                                                       preferred: ["en-US", "it-IT"],
                                                       supported: supported)
        XCTAssertEqual(chosen, Locale(identifier: "it-IT"))
    }

    func testRememberedLanguageSurvivesADifferentSpelling() {
        // `Locale.preferredLanguages` says "it-IT", a UserDefaults round trip can hand
        // back "it_IT", and the framework offers its own spelling. All one language.
        for spelling in ["it_IT", "IT-it", "it"] {
            XCTAssertEqual(
                TranscriptionLocalePolicy.resolve(remembered: spelling,
                                                  preferred: ["en-US"],
                                                  supported: supported),
                Locale(identifier: "it-IT"),
                "remembered “\(spelling)” should resolve to the supported Italian")
        }
    }

    func testRememberedLanguageNoLongerSupportedFallsBackToTheDevice() {
        // A remembered language the device can no longer transcribe must not produce an
        // empty picker or a locale nothing supports.
        let chosen = TranscriptionLocalePolicy.resolve(remembered: "ja-JP",
                                                       preferred: ["en-GB", "it-IT"],
                                                       supported: supported)
        XCTAssertEqual(chosen, Locale(identifier: "en-GB"))
    }

    func testFirstSupportedDevicePreferenceWinsWhenNothingIsRemembered() {
        // "Default sensibly from the device's configured languages": the FIRST configured
        // language that is actually supported, not merely the first one configured.
        let chosen = TranscriptionLocalePolicy.resolve(remembered: nil,
                                                       preferred: ["ja-JP", "it-IT", "en-US"],
                                                       supported: supported)
        XCTAssertEqual(chosen, Locale(identifier: "it-IT"))
    }

    func testFallsBackToAnySupportedLocale() {
        let chosen = TranscriptionLocalePolicy.resolve(remembered: nil,
                                                       preferred: ["ja-JP"],
                                                       supported: supported)
        XCTAssertEqual(chosen, Locale(identifier: "en-US"))
    }

    func testNoSupportedLocalesResolvesToNothing() {
        // The caller turns this into `localeUnavailable`, which is a sentence. An empty
        // picker would be a shrug.
        XCTAssertNil(TranscriptionLocalePolicy.resolve(remembered: "it-IT",
                                                       preferred: ["en-US"],
                                                       supported: []))
    }

    // MARK: - menu

    func testMenuPutsTheDevicesOwnLanguagesFirstInPreferenceOrder() {
        let menu = TranscriptionLocalePolicy.menu(supported: supported,
                                                  preferred: ["it-IT", "en-GB"],
                                                  in: Locale(identifier: "en-US"))
        XCTAssertEqual(Array(menu.prefix(2)),
                       [Locale(identifier: "it-IT"), Locale(identifier: "en-GB")])
    }

    func testMenuListsEveryLocaleExactlyOnce() {
        let menu = TranscriptionLocalePolicy.menu(supported: supported,
                                                  preferred: ["it-IT", "it-CH", "en-GB"],
                                                  in: Locale(identifier: "en-US"))
        XCTAssertEqual(menu.count, supported.count)
        XCTAssertEqual(Set(menu.map(TranscriptionLocalePolicy.key)),
                       Set(supported.map(TranscriptionLocalePolicy.key)))
    }

    func testMenuSortsTheRestByTheNameBeingShown() {
        // Alphabetical by the DISPLAYED name, so an English UI reads
        // German/French/... rather than de/fr/... — the identifiers sort differently
        // from the names in both directions.
        let ui = Locale(identifier: "en-US")
        let menu = TranscriptionLocalePolicy.menu(supported: supported, preferred: [], in: ui)
        let names = menu.map { TranscriptionLocalePolicy.displayName($0, in: ui) }
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testDisplayNameIsNeverEmpty() {
        for locale in supported {
            XCTAssertFalse(TranscriptionLocalePolicy.displayName(locale, in: Locale(identifier: "en-US")).isEmpty)
        }
        // Even for something the system has no name for, so a picker row can never
        // render blank.
        XCTAssertFalse(TranscriptionLocalePolicy.displayName(Locale(identifier: "zz-ZZ"),
                                                             in: Locale(identifier: "en-US")).isEmpty)
    }
}

final class TranscriptionStallDetectorTests: XCTestCase {

    /// The regression this whole type exists for: an hour of audio, transcribed at
    /// nowhere near real time, must never be given up on. Under the old fixed 30-second
    /// wall-clock bound this is precisely the case that failed every time.
    func testAnHourOfSteadyProgressNeverStalls() {
        var detector = TranscriptionStallDetector(limit: 120, startedAt: 0)
        // 3600 seconds of audio, arriving in 10-second result chunks, each taking 20
        // seconds of real time — a 2x-slower-than-realtime engine, 7200 seconds of wall
        // clock in total, 60 times the old deadline.
        var now: TimeInterval = 0
        for chunk in stride(from: 10.0, through: 3600.0, by: 10.0) {
            now += 20
            detector.note(marker: chunk, at: now)
            XCTAssertFalse(detector.isStalled(at: now),
                           "progress at audio second \(chunk) must never read as stalled")
        }
        XCTAssertEqual(now, 7200)
    }

    func testNoProgressTripsTheDetectorAtTheLimit() {
        var detector = TranscriptionStallDetector(limit: 120, startedAt: 0)
        detector.note(marker: 5, at: 10)
        XCTAssertFalse(detector.isStalled(at: 130), "exactly the limit is not yet over it")
        XCTAssertTrue(detector.isStalled(at: 130.5))
    }

    func testRepeatingTheSameMarkerIsNotProgress() {
        // A recognizer that keeps re-emitting the same range is wedged, and looks
        // identical to one emitting nothing. Both must trip.
        var detector = TranscriptionStallDetector(limit: 60, startedAt: 0)
        XCTAssertTrue(detector.note(marker: 42, at: 1), "the first sighting is an advance")
        for tick in stride(from: 2.0, through: 200.0, by: 1.0) {
            let advanced = detector.note(marker: 42, at: tick)
            XCTAssertFalse(advanced, "re-emitting the same range is not progress")
        }
        XCTAssertTrue(detector.isStalled(at: 200))
    }

    func testGoingBackwardsIsNotProgress() {
        var detector = TranscriptionStallDetector(limit: 60, startedAt: 0)
        XCTAssertTrue(detector.note(marker: 100, at: 1))
        XCTAssertFalse(detector.note(marker: 90, at: 50))
        XCTAssertTrue(detector.isStalled(at: 62), "the clock still runs from the last real advance")
    }

    func testRestartForgetsTheMarkerSoANewPhaseCanStartFromZero() {
        // Model download reports 0...1; transcription reports seconds of audio. Carrying
        // a 0.9 across the boundary would suppress every stall for the first 0.9 seconds
        // of audio — and carrying seconds back the other way would suppress a download
        // stall entirely.
        var detector = TranscriptionStallDetector(limit: 60, startedAt: 0)
        detector.note(marker: 0.9, at: 10)
        detector.restart(at: 20)
        XCTAssertTrue(detector.note(marker: 0.5, at: 21),
                      "a smaller marker in a new phase is still an advance")
        XCTAssertFalse(detector.isStalled(at: 60))
        XCTAssertTrue(detector.isStalled(at: 82))
    }

    func testAStartedRunWithNoProgressAtAllStallsFromTheStartTime() {
        // An engine that never produces a single result must still be given up on.
        var detector = TranscriptionStallDetector(limit: 120, startedAt: 1000)
        XCTAssertFalse(detector.isStalled(at: 1100))
        XCTAssertTrue(detector.isStalled(at: 1121))
        detector.restart(at: 1200)
        XCTAssertFalse(detector.isStalled(at: 1300))
    }

    func testTheDefaultLimitIsGenerousEnoughForSilenceAndAModelFetch() {
        XCTAssertEqual(TranscriptionStallDetector.defaultLimit, 120)
    }
}
