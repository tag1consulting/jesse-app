import XCTest
@testable import JesseVault

// The capacity measurement, driven entirely through the `ProbeSessioning` seam.
//
// THE REAL MODEL IS NEVER CALLED HERE. `FoundationModelProbeSession` is the one
// implementation that touches `SystemLanguageModel`, and nothing in this file
// constructs it — the same containment `FilterExpansionTermsTests` keeps around the
// search expander. What is asserted is the part that can be wrong in a way a device
// run would not reveal: where the doubling stops, where the bisection lands, and
// what happens when the model says no at every size.
final class ModelProbeTests: XCTestCase {

    func testFindsTheLimitToTheNearestFiveHundredCharacters() async {
        // A session that refuses anything over 5,300 characters. The honest answer
        // to the nearest 500 is 5,000: the largest multiple of the resolution that
        // is known to fit.
        let session = CeilingSession(limit: 5_300)
        let report = await ModelProbe(session: session).run()

        let largest = report.largestPromptCharacters
        XCTAssertNotNil(largest)
        XCTAssertLessThanOrEqual(largest ?? 0, 5_300, "it must never report a size that was refused")
        XCTAssertGreaterThan(largest ?? 0, 5_300 - ModelProbe.resolution,
                             "and it must get within one resolution step of the true limit")
    }

    func testFindsALargeLimitJustAsPrecisely() async {
        let session = CeilingSession(limit: 41_200)
        let report = await ModelProbe(session: session).run()

        let largest = report.largestPromptCharacters
        XCTAssertLessThanOrEqual(largest ?? 0, 41_200)
        XCTAssertGreaterThan(largest ?? 0, 41_200 - ModelProbe.resolution)
    }

    func testASmallLimitJustAboveTheStartingSizeIsStillFound() async {
        let session = CeilingSession(limit: 1_600)
        let report = await ModelProbe(session: session).run()

        XCTAssertEqual(report.largestPromptCharacters, 1_500)
    }

    func testAModelThatRefusesEvenTheSmallestPromptReportsNoNumberAndSaysSo() async {
        let report = await ModelProbe(session: CeilingSession(limit: 10)).run()

        XCTAssertNil(report.largestPromptCharacters)
        XCTAssertNil(report.roundTripSeconds)
        XCTAssertEqual(report.note, "Even a 1000-character prompt was refused. The timed round trip failed: refused")
    }

    func testAnUnavailableModelIsAResultRatherThanAThrow() async {
        let session = UnavailableSession()
        let report = await ModelProbe(session: session).run()

        XCTAssertEqual(report.availability, "unavailable — this device is not eligible")
        XCTAssertNil(report.largestPromptCharacters)
        XCTAssertNil(report.roundTripSeconds)
        XCTAssertEqual(session.calls, 0, "an unavailable model must never be asked anything")
        XCTAssertEqual(report.lines.first, "Availability: unavailable — this device is not eligible")
    }

    func testTheCeilingIsReportedRatherThanPassedOffAsTheAnswer() async {
        let report = await ModelProbe(session: AlwaysYesSession()).run()

        XCTAssertNotNil(report.largestPromptCharacters)
        XCTAssertEqual(report.note,
                       "Every prompt up to the \(ModelProbe.ceiling)-character ceiling was accepted; the real limit is higher.")
    }

    func testTheTimedRoundTripIsMeasuredAndReported() async {
        let report = await ModelProbe(session: CeilingSession(limit: 8_000)).run()
        XCTAssertNotNil(report.roundTripSeconds)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("2,000-character round trip: ") })
    }

    func testEverySessionUsedForTheProbeIsAskedWithAFullSizePrompt() async {
        let session = CeilingSession(limit: 4_000)
        _ = await ModelProbe(session: session).run()

        // The prompts must actually BE the size being probed, or the number means
        // nothing. The first is the 1,000-character starting probe.
        XCTAssertEqual(session.promptLengths.first, 1_000)
        XCTAssertTrue(session.promptLengths.contains(2_000))
    }

    // MARK: - The pure helpers

    func testFillerIsExactlyTheLengthAskedForAndIsProse() {
        for length in [0, 1, 17, 500, 1_000, 12_345] {
            XCTAssertEqual(ModelProbe.filler(characters: length).count, length)
        }
        XCTAssertTrue(ModelProbe.filler(characters: 200).contains(" "),
                      "a tokenizer packs repeated characters very differently from prose")
    }

    func testAFillerPromptIsExactlyTheRequestedSize() {
        for size in [1_000, 2_000, 4_000, 64_000] {
            XCTAssertEqual(ModelProbe.fillerPrompt(characters: size).count, size)
        }
    }

    func testTheTimingPromptIsTwoThousandCharacters() {
        XCTAssertEqual(ModelProbe.timingPrompt().count, 2_000)
        XCTAssertTrue(ModelProbe.timingPrompt().hasPrefix("Summarise the notes below in about twenty words."))
    }

    func testTheMidpointSnapsDownToTheResolutionGrid() {
        XCTAssertEqual(ModelProbe.midpoint(lo: 1_000, hi: 2_000), 1_500)
        XCTAssertEqual(ModelProbe.midpoint(lo: 1_000, hi: 1_999), 1_000)
        XCTAssertEqual(ModelProbe.midpoint(lo: 4_000, hi: 8_000), 6_000)
        XCTAssertEqual(ModelProbe.midpoint(lo: 0, hi: 999), 0)
    }
}

// MARK: - Fakes

private struct ProbeRefused: Error, LocalizedError {
    var errorDescription: String? { "refused" }
}

/// Accepts a prompt up to `limit` characters and throws above it — the shape a real
/// context-window error has, without a real model.
private final class CeilingSession: ProbeSessioning, @unchecked Sendable {
    let limit: Int
    private(set) var promptLengths: [Int] = []

    init(limit: Int) { self.limit = limit }

    var availability: String { "available" }
    var isAvailable: Bool { true }

    func respond(to prompt: String) async throws -> String {
        promptLengths.append(prompt.count)
        if prompt.count > limit { throw ProbeRefused() }
        return "OK"
    }
}

private final class AlwaysYesSession: ProbeSessioning, @unchecked Sendable {
    var availability: String { "available" }
    var isAvailable: Bool { true }
    func respond(to prompt: String) async throws -> String { "OK" }
}

private final class UnavailableSession: ProbeSessioning, @unchecked Sendable {
    private(set) var calls = 0
    var availability: String { "unavailable — this device is not eligible" }
    var isAvailable: Bool { false }
    func respond(to prompt: String) async throws -> String {
        calls += 1
        throw ProbeRefused()
    }
}
