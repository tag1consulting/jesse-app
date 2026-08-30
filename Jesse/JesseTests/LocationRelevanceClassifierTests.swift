import XCTest
@testable import Jesse

/// The keyword floor that decides whether a turn is about WHERE HE IS, the gate that
/// decides whether to attach at all, and the resolver that wires the two together.
/// All pure — no CoreLocation.
@MainActor
final class LocationRelevanceClassifierTests: XCTestCase {

    private func matches(_ s: String) -> Bool { LocationKeywordClassifier.matches(s) }

    // MARK: - What must fire

    func testEnglishPhrasesFire() {
        for text in [
            "anywhere for coffee near me?",
            "what's nearby?",
            "anything good around here",
            "which is the closest pharmacy",
            "where's the nearest post office",
            "how far is the gym",
            "how long to get to the airport",
            "give me directions",
            "is that within walking distance",
            "can I walk to it",
            "should I drive to the station or cycle to it",
            "is the deli open now",
            "is it still open",
            "where am I",
            "anything worth seeing in this area",
            "there's a place around the corner, what is it",
            "what's on my way home",
            "how long from here",
        ] {
            XCTAssertTrue(matches(text), "must fire: \(text)")
        }
    }

    /// The owner is often in Italy, so the same question in Italian has to reach the
    /// same channel — otherwise the feature silently stops working on holiday.
    func testItalianPhrasesFire() {
        for text in [
            "un bar vicino a me",
            "cosa c'è qui vicino",
            "qual è il più vicino",
            "quanto dista la stazione",
            "quanto è lontano il museo",
            "quanto ci vuole ad arrivarci",
            "ci arrivo a piedi?",
            "meglio in macchina?",
            "è aperto adesso?",
            "dove sono",
            "dove mi trovo",
            "cosa c'è in zona",
            "qualcosa qui intorno",
            "quanto manca da qui",
            "mi dai le indicazioni",
            "cosa c'è nei dintorni",
        ] {
            XCTAssertTrue(matches(text), "must fire: \(text)")
        }
    }

    /// Accents are folded on BOTH sides, so a hurried "piu vicino" matches the table's
    /// "più vicino" and vice versa.
    func testAccentsAreFoldedBothWays() {
        XCTAssertTrue(matches("qual e il piu vicino"))
        XCTAssertTrue(matches("qual è il più vicino"))
        XCTAssertTrue(matches("QUANTO DISTA"), "matching is case-insensitive")
    }

    // MARK: - What must NOT fire

    /// The location classifier is deliberately tighter than the health one: a
    /// spurious health attach costs tokens, a spurious location attach sends a
    /// coordinate the turn had no use for. These are the near-misses that prove it.
    func testOrdinaryMessagesDoNotFire() {
        for text in [
            "I walked 8km this morning",
            "log my run",
            "drive the project forward this week",
            "keep the door open for now",
            "what's on Today.md",
            "summarise the rest of it",
            // "how far" without its preposition: a progress question, and a health
            // question. Both would otherwise have attached a coordinate.
            "how far along is the migration",
            "how far did I run this morning",
            "quindi cosa faccio",
            "requiescat",
            "clear my calendar",
        ] {
            XCTAssertFalse(matches(text), "must NOT fire: \(text)")
        }
    }

    /// Word-boundary awareness for the single-word triggers, so a trigger buried
    /// inside another word does not attach a coordinate.
    func testSingleWordTriggersAreWholeWordsOnly() {
        XCTAssertTrue(matches("what's nearby"))
        XCTAssertFalse(matches("nearbyish"), "a trigger inside a longer token is not a hit")
        XCTAssertTrue(matches("qui vicino"))
        XCTAssertFalse(matches("quindi vediamo"), "'qui' must not fire inside 'quindi'")
        XCTAssertFalse(matches("acquired"), "nor inside an English word that contains it")
    }

    func testEmptyAndWhitespaceDoNotFire() {
        XCTAssertFalse(matches(""))
        XCTAssertFalse(matches("   \n  "))
    }

    // MARK: - The gate

    /// Both consents are required, and they are independent. This is the table that
    /// keeps a revoked system permission from producing a mid-turn prompt.
    func testGateRequiresToggleAuthorizationAndRelevance() {
        for enabled in [true, false] {
            for authorized in [true, false] {
                for relevant in [true, false] {
                    let attach = LocationContextGate.shouldAttach(
                        enabled: enabled, authorized: authorized, relevant: relevant)
                    XCTAssertEqual(attach, enabled && authorized && relevant,
                                   "enabled=\(enabled) authorized=\(authorized) relevant=\(relevant)")
                }
            }
        }
    }

    /// Fulfilment drops the relevance test — a directive IS the relevance signal —
    /// but keeps BOTH consents.
    func testMayFulfillKeepsBothConsentsAndDropsRelevance() {
        XCTAssertTrue(LocationContextGate.mayFulfill(enabled: true, authorized: true))
        XCTAssertFalse(LocationContextGate.mayFulfill(enabled: false, authorized: true))
        XCTAssertFalse(LocationContextGate.mayFulfill(enabled: true, authorized: false))
        XCTAssertFalse(LocationContextGate.mayFulfill(enabled: false, authorized: false))
    }

    // MARK: - The resolver (send-path wiring)

    /// A provider that records what it was asked for, so the tests can assert the
    /// resolver never touches it when a consent is missing.
    private final class FakeProvider: LocationContextProviding, @unchecked Sendable {
        var authorized: Bool
        var readingToReturn: LocationReading
        private(set) var authorizationChecks = 0
        private(set) var readings: [(LocationPrecision, Int, Bool)] = []
        /// The budget each call was given, so the tests can assert that the two call
        /// sites really do spend different ones rather than sharing a constant.
        private(set) var budgets: [LocationFixBudget] = []

        init(authorized: Bool, reading: LocationReading = .empty) {
            self.authorized = authorized
            self.readingToReturn = reading
        }

        func authorizationState() async -> LocationAuthorizationState {
            authorizationChecks += 1
            return authorized ? .authorized : .unauthorized
        }

        func reading(precision: LocationPrecision, maxAgeSeconds: Int,
                     wantsPlacemark: Bool,
                     budget: LocationFixBudget) async -> LocationReadingResult {
            readings.append((precision, maxAgeSeconds, wantsPlacemark))
            budgets.append(budget)
            return .got(readingToReturn)
        }
    }

    private var somewhere: LocationReading {
        LocationReading(latitude: 55.94, longitude: -3.21, accuracyMeters: 900,
                        placemark: "Fountainbridge, Edinburgh EH3",
                        timestamp: Date(timeIntervalSince1970: 1_780_000_000))
    }

    func testResolverAttachesWhenBothConsentsAndRelevanceHold() async {
        let provider = FakeProvider(authorized: true, reading: somewhere)
        let block = await LocationContextResolver.resolve(
            enabled: true, relevant: true, provider: provider,
            now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("Near: Fountainbridge, Edinburgh EH3"))
        XCTAssertEqual(provider.readings.count, 1)
    }

    /// The PROACTIVE attach is the most conservative request the channel can make:
    /// coarse, placemark-led, from a fix up to five minutes old. It must never be
    /// `precise` — the agent has asked for nothing at this point, and precise can
    /// cost a full-accuracy prompt.
    func testProactiveAttachIsAlwaysCoarseAndNeverAsksForCoordinates() async {
        let provider = FakeProvider(authorized: true, reading: somewhere)
        let block = await LocationContextResolver.resolve(
            enabled: true, relevant: true, provider: provider,
            now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(LocationContextResolver.proactiveRequest.precision, .coarse)
        XCTAssertEqual(LocationContextResolver.proactiveRequest.maxAgeSeconds, 300)
        XCTAssertFalse(LocationContextResolver.proactiveRequest.fields.contains(.coordinates),
                       "an unasked-for attach carries a place, not a coordinate")
        XCTAssertEqual(provider.readings.first?.0, .coarse)
        XCTAssertFalse(block!.contains("Coordinates"))
    }

    func testResolverAttachesNothingWhenTheToggleIsOff() async {
        let provider = FakeProvider(authorized: true, reading: somewhere)
        let block = await LocationContextResolver.resolve(
            enabled: false, relevant: true, provider: provider, now: Date())
        XCTAssertNil(block)
        XCTAssertEqual(provider.authorizationChecks, 0,
                       "a switched-off channel never even asks CoreLocation anything")
        XCTAssertTrue(provider.readings.isEmpty)
    }

    func testResolverAttachesNothingWhenNotRelevant() async {
        let provider = FakeProvider(authorized: true, reading: somewhere)
        let block = await LocationContextResolver.resolve(
            enabled: true, relevant: false, provider: provider, now: Date())
        XCTAssertNil(block)
        XCTAssertTrue(provider.readings.isEmpty)
    }

    /// The one that matters most: an unauthorized device is checked and then left
    /// alone. No reading is taken, so there is nothing for iOS to prompt about.
    func testResolverNeverReadsWhenUnauthorized() async {
        let provider = FakeProvider(authorized: false, reading: somewhere)
        let block = await LocationContextResolver.resolve(
            enabled: true, relevant: true, provider: provider, now: Date())
        XCTAssertNil(block)
        XCTAssertGreaterThan(provider.authorizationChecks, 0, "it did check")
        XCTAssertTrue(provider.readings.isEmpty, "and then took no reading")
    }

    /// A device with no fix at all — the simulator's default state — resolves to nil
    /// rather than an empty block, so the turn simply goes out without one.
    func testResolverAttachesNothingWhenTheDeviceHasNoFix() async {
        let provider = FakeProvider(authorized: true, reading: .empty)
        let block = await LocationContextResolver.resolve(
            enabled: true, relevant: true, provider: provider, now: Date())
        XCTAssertNil(block)
    }

    // MARK: - Settings

    func testTheToggleDefaultsOff() {
        let suite = UserDefaults(suiteName: "location-settings-\(UUID().uuidString)")!
        let previous = LocationContextSettings.defaults
        LocationContextSettings.defaults = suite
        defer { LocationContextSettings.defaults = previous }

        XCTAssertFalse(LocationContextSettings.isEnabled, "a fresh install never attaches")
        LocationContextSettings.setEnabled(true)
        XCTAssertTrue(LocationContextSettings.isEnabled)
        LocationContextSettings.setEnabled(false)
        XCTAssertFalse(LocationContextSettings.isEnabled)
    }
}
