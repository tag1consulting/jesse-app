import XCTest
@testable import Jesse

/// The pure app half of the JESSE_NEEDS_LOCATION channel: the validated decode of a
/// directive, and the formatter that renders a reading into the attached block.
/// Foundation-only — no CoreLocation, no simulator fix.
@MainActor
final class RequestableLocationTests: XCTestCase {

    // MARK: - NeedsLocationRequest.validated

    func testValidatedAcceptsEveryFieldAndBothPrecisions() {
        for field in RequestableLocationField.allCases {
            for precision in LocationPrecision.allCases {
                let r = NeedsLocationRequest.validated(fields: [field.rawValue],
                                                       precision: precision.rawValue,
                                                       maxAgeSeconds: 60)
                XCTAssertEqual(r?.fields, [field], "\(field) must validate")
                XCTAssertEqual(r?.precision, precision, "\(precision) must validate")
            }
        }
        // The whole whitelist at once is exactly at the cap.
        let all = RequestableLocationField.allCases.map(\.rawValue)
        let r = NeedsLocationRequest.validated(fields: all, precision: "coarse", maxAgeSeconds: 0)
        XCTAssertEqual(r?.fields, RequestableLocationField.allCases)
        XCTAssertEqual(all.count, NeedsLocationRequest.maxFields)
    }

    func testValidatedRejectsAnythingOffTheContract() {
        // Off-whitelist field, unknown precision, and the age boundaries.
        XCTAssertNil(NeedsLocationRequest.validated(fields: ["altitude"], precision: "coarse", maxAgeSeconds: 60))
        XCTAssertNil(NeedsLocationRequest.validated(fields: ["placemark"], precision: "exact", maxAgeSeconds: 60))
        XCTAssertNil(NeedsLocationRequest.validated(fields: ["placemark"], precision: "Coarse", maxAgeSeconds: 60),
                     "the precision match is exact, not case-insensitive")
        XCTAssertNil(NeedsLocationRequest.validated(fields: ["placemark"], precision: "coarse", maxAgeSeconds: 901))
        XCTAssertNil(NeedsLocationRequest.validated(fields: ["placemark"], precision: "coarse", maxAgeSeconds: -1))
        // …and the two boundaries that ARE in range.
        XCTAssertNotNil(NeedsLocationRequest.validated(fields: ["placemark"], precision: "coarse", maxAgeSeconds: 0))
        XCTAssertNotNil(NeedsLocationRequest.validated(fields: ["placemark"], precision: "coarse", maxAgeSeconds: 900))
    }

    func testValidatedRejectsEmptyOverCapAndMissingKeys() {
        XCTAssertNil(NeedsLocationRequest.validated(fields: [], precision: "coarse", maxAgeSeconds: 60),
                     "a request for nothing is not a request")
        let overCap = Array(repeating: "placemark", count: NeedsLocationRequest.maxFields + 1)
        XCTAssertNil(NeedsLocationRequest.validated(fields: overCap, precision: "coarse", maxAgeSeconds: 60),
                     "the count is checked before the whitelist, so repeats cannot get past it")
        // Every key is required — there is no default for any of the three.
        XCTAssertNil(NeedsLocationRequest.validated(fields: nil, precision: "coarse", maxAgeSeconds: 60))
        XCTAssertNil(NeedsLocationRequest.validated(fields: ["placemark"], precision: nil, maxAgeSeconds: 60))
        XCTAssertNil(NeedsLocationRequest.validated(fields: ["placemark"], precision: "coarse", maxAgeSeconds: nil))
    }

    /// The whitelist the app enforces must be exactly the one the bridge does. This
    /// asserts the app's own values; `scripts/ci-guards.sh` is what compares them
    /// against the Rust consts, since a Swift test cannot read Rust source.
    func testWhitelistValuesAreTheContractedStrings() {
        XCTAssertEqual(RequestableLocationField.allCases.map(\.rawValue),
                       ["coordinates", "placemark", "accuracy"])
        XCTAssertEqual(LocationPrecision.allCases.map(\.rawValue), ["coarse", "precise"])
    }

    // MARK: - LocationRequestFulfiller.block

    private let stamp = Date(timeIntervalSince1970: 1_780_000_000)

    private func reading(placemark: String? = "Fountainbridge, Edinburgh EH3, United Kingdom",
                         lat: Double? = 55.943210987,
                         lon: Double? = -3.216549876,
                         accuracy: Double? = 65,
                         timestamp: Date? = nil) -> LocationReading {
        LocationReading(latitude: lat, longitude: lon, accuracyMeters: accuracy,
                        placemark: placemark, timestamp: timestamp ?? stamp)
    }

    private func request(_ fields: [RequestableLocationField],
                         _ precision: LocationPrecision = .coarse) -> NeedsLocationRequest {
        NeedsLocationRequest(fields: fields, precision: precision, maxAgeSeconds: 300)
    }

    func testBlockRendersOnlyTheRequestedFields() {
        let placemarkOnly = LocationRequestFulfiller.block(
            request: request([.placemark]), reading: reading(),
            now: stamp, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(placemarkOnly, """
        Near: Fountainbridge, Edinburgh EH3, United Kingdom
        Taken: 20:26 (0s ago)
        """)
        // Coordinates were NOT asked for, so no coordinate appears anywhere.
        XCTAssertFalse(placemarkOnly!.contains("55."), "an unrequested coordinate is never rendered")

        let accuracyOnly = LocationRequestFulfiller.block(
            request: request([.accuracy]), reading: reading(),
            now: stamp, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(accuracyOnly!.contains("Accuracy: within about 65 m"))
        XCTAssertFalse(accuracyOnly!.contains("Near:"))
    }

    /// Precision changes the rendered decimals, and the block SAYS which it used —
    /// so a reader of the transcript can tell a coarse answer from a precise one.
    func testCoordinatePrecisionIsRoundedAndLabelled() {
        let coarse = LocationRequestFulfiller.block(
            request: request([.coordinates], .coarse), reading: reading(),
            now: stamp, timeZone: TimeZone(identifier: "UTC")!)!
        XCTAssertTrue(coarse.contains("Coordinates (coarse): 55.943, -3.217"), coarse)

        let precise = LocationRequestFulfiller.block(
            request: request([.coordinates], .precise), reading: reading(),
            now: stamp, timeZone: TimeZone(identifier: "UTC")!)!
        XCTAssertTrue(precise.contains("Coordinates (precise): 55.94321, -3.21655"), precise)
    }

    func testAccuracyReadsAsMetresUnderAKilometreAndKmAbove() {
        XCTAssertEqual(LocationRequestFulfiller.metres(65), "65 m")
        XCTAssertEqual(LocationRequestFulfiller.metres(999), "999 m")
        XCTAssertEqual(LocationRequestFulfiller.metres(1000), "1.0 km")
        XCTAssertEqual(LocationRequestFulfiller.metres(1800), "1.8 km",
                       "a coarse circle reads as km, not as false-precision metres")
    }

    func testAgeReadsToTheCoarsestUsefulUnit() {
        XCTAssertEqual(LocationRequestFulfiller.age(stamp, stamp.addingTimeInterval(45)), "45s")
        XCTAssertEqual(LocationRequestFulfiller.age(stamp, stamp.addingTimeInterval(300)), "5m")
        XCTAssertEqual(LocationRequestFulfiller.age(stamp, stamp.addingTimeInterval(7200)), "2h")
        XCTAssertEqual(LocationRequestFulfiller.age(stamp, stamp.addingTimeInterval(-10)), "0s",
                       "a clock that ran backwards reads as fresh, never as negative")
    }

    /// An empty reading — the shape every degrade path produces (denied, services
    /// off, timed out, no fix, a simulator with no location set) — is nil, which is
    /// what the coordinator reads as unfulfillable.
    func testEmptyReadingProducesNoBlock() {
        XCTAssertNil(LocationRequestFulfiller.block(
            request: request([.placemark, .coordinates, .accuracy]),
            reading: .empty, now: stamp))
    }

    /// A reading that has SOMETHING but not the requested field also produces no
    /// block, rather than a block that says nothing — a "Taken:" line on its own
    /// would tell the agent a reading succeeded while carrying no location at all.
    func testAReadingMissingTheRequestedFieldProducesNoBlock() {
        let coordsOnly = reading(placemark: nil, accuracy: nil)
        XCTAssertNil(LocationRequestFulfiller.block(request: request([.placemark]),
                                                    reading: coordsOnly, now: stamp))
        // …and the same reading DOES answer a coordinates request.
        XCTAssertNotNil(LocationRequestFulfiller.block(request: request([.coordinates]),
                                                       reading: coordsOnly, now: stamp))
    }

    func testBlankPlacemarkIsTreatedAsAbsent() {
        let blank = reading(placemark: "   ", lat: nil, lon: nil, accuracy: nil)
        XCTAssertNil(LocationRequestFulfiller.block(request: request([.placemark]),
                                                    reading: blank, now: stamp))
    }

    func testNegativeAccuracyIsDroppedRatherThanRendered() {
        // CoreLocation reports a negative horizontal accuracy for an invalid fix.
        let bad = reading(placemark: nil, lat: nil, lon: nil, accuracy: -1)
        XCTAssertNil(LocationRequestFulfiller.block(request: request([.accuracy]),
                                                    reading: bad, now: stamp))
    }

    /// The 1 KiB cap, on whole-line boundaries. A location block never approaches it
    /// in practice; this proves the bound exists rather than being aspirational.
    func testBlockIsCappedAtOneKiB() {
        XCTAssertEqual(LocationRequestFulfiller.maxBytes, 1024)
        let huge = String(repeating: "A", count: 4000)
        let block = LocationRequestFulfiller.block(
            request: request([.placemark, .coordinates, .accuracy]),
            reading: reading(placemark: huge), now: stamp)
        XCTAssertNotNil(block)
        XCTAssertLessThanOrEqual(block!.utf8.count, LocationRequestFulfiller.maxBytes)
    }

    /// The reason the placemark is clamped BEFORE the block cap rather than left to
    /// it. The cap truncates on whole lines, so one absurd place name — the single
    /// field whose length comes from outside this app — would otherwise keep nothing
    /// and drop the perfectly good coordinates and accuracy with it.
    func testAnAbsurdPlacemarkIsClampedRatherThanDroppingTheWholeReading() {
        let huge = String(repeating: "A", count: 4000)
        let block = LocationRequestFulfiller.block(
            request: request([.placemark, .coordinates, .accuracy]),
            reading: reading(placemark: huge), now: stamp,
            timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertNotNil(block, "the reading survives a hostile place name")
        XCTAssertTrue(block!.contains("Coordinates (coarse): 55.943, -3.217"),
                      "the coordinates are NOT collateral damage:\n\(block!)")
        XCTAssertTrue(block!.contains("Accuracy: within about 65 m"))
        // The place line is present, clamped, and nothing else was truncated.
        let placeLine = block!.split(separator: "\n").first { $0.hasPrefix("Near: ") }
        XCTAssertNotNil(placeLine)
        XCTAssertLessThanOrEqual(placeLine!.count,
                                 LocationRequestFulfiller.maxPlacemarkChars + "Near: ".count)
    }

    /// Fields are rendered in a FIXED order regardless of the order the directive
    /// listed them, so two identical requests always produce identical bytes.
    func testFieldOrderIsFixedNotRequestOrder() {
        let a = LocationRequestFulfiller.block(
            request: request([.accuracy, .coordinates, .placemark]),
            reading: reading(), now: stamp, timeZone: TimeZone(identifier: "UTC")!)!
        let b = LocationRequestFulfiller.block(
            request: request([.placemark, .coordinates, .accuracy]),
            reading: reading(), now: stamp, timeZone: TimeZone(identifier: "UTC")!)!
        XCTAssertEqual(a, b)
        let near = a.range(of: "Near:")!.lowerBound
        let coords = a.range(of: "Coordinates")!.lowerBound
        let acc = a.range(of: "Accuracy:")!.lowerBound
        XCTAssertTrue(near < coords && coords < acc, "placemark, coordinates, accuracy:\n\(a)")
    }
}
