import XCTest
@testable import JesseVault

// Where a message goes, what the reply says, and what a citation link is.

/// Counts how often it is asked whether a model exists — the cost the short-circuit is
/// there to avoid.
private final class CountingGeneration: VaultAnswerGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var asks = 0
    var availabilityAsks: Int { lock.withLock { asks } }
    var isAvailable: Bool {
        lock.withLock { asks += 1 }
        return true
    }
    func generate(question: String, chunks: [RetrievedChunk]) async throws -> VaultAnswerDraft {
        throw VaultAnswerGenerationError.failed("not used")
    }
}

final class OfflineLookupRoutingTests: XCTestCase {

    // MARK: - The route

    func testAReachableBridgeAlwaysWins() {
        XCTAssertEqual(OfflineLookupRouting.route(reachability: .reachable,
                                                  hasVaultFolder: true,
                                                  isEnabled: true,
                                                  modelAvailable: true),
                       .bridge)
    }

    func testUnreachableWithAFolderAndAModelGoesToTheDevice() {
        XCTAssertEqual(OfflineLookupRouting.route(reachability: .unreachable,
                                                  hasVaultFolder: true,
                                                  isEnabled: true,
                                                  modelAvailable: true),
                       .onDevice)
    }

    func testUnreachableWithoutAFolderStillGoesToTheBridge() {
        XCTAssertEqual(OfflineLookupRouting.route(reachability: .unreachable,
                                                  hasVaultFolder: false,
                                                  isEnabled: true,
                                                  modelAvailable: true),
                       .bridge)
    }

    func testTheToggleOffIsTheBehaviourThatExistedBefore() {
        XCTAssertEqual(OfflineLookupRouting.route(reachability: .unreachable,
                                                  hasVaultFolder: true,
                                                  isEnabled: false,
                                                  modelAvailable: true),
                       .bridge)
    }

    /// No usable model means the composer cannot tell this feature was ever written.
    func testNoModelIsTheBehaviourThatExistedBefore() {
        XCTAssertEqual(OfflineLookupRouting.route(reachability: .unreachable,
                                                  hasVaultFolder: true,
                                                  isEnabled: true,
                                                  modelAvailable: false),
                       .bridge)
    }

    /// `.unknown` is the PRE-PROBE state of a cold launch. Answering from a possibly
    /// stale local copy because no probe has finished yet would be the worst of both.
    func testTheUnknownStateIsNotOffline() {
        XCTAssertEqual(OfflineLookupRouting.route(reachability: .unknown,
                                                  hasVaultFolder: true,
                                                  isEnabled: true,
                                                  modelAvailable: true),
                       .bridge)
    }

    /// The service's own short-circuit, which exists so a reachable device never pays
    /// for a bookmark resolution or a model availability check on every send.
    @MainActor
    func testAReachableDeviceIsRoutedWithoutAskingAboutTheFolderOrTheModel() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "offline-lookup-\(UUID())"))
        let counting = CountingGeneration()
        let service = OfflineAnswerService(classifier: NoLookupClassification(),
                                           generator: counting,
                                           settings: OfflineLookupSettings(defaults: defaults),
                                           diagnostics: OfflineLookupDiagnostics())
        XCTAssertEqual(service.route(reachability: .reachable), .bridge)
        XCTAssertEqual(service.route(reachability: .unknown), .bridge)
        XCTAssertEqual(counting.availabilityAsks, 0,
                       "a reachable device must not ask the system about the model")

        // And the toggle short-circuits before it too.
        OfflineLookupSettings(defaults: defaults).isEnabled = false
        XCTAssertEqual(service.route(reachability: .unreachable), .bridge)
        XCTAssertEqual(counting.availabilityAsks, 0)
    }

    // MARK: - The reply

    private let answer = VaultAnswer(
        text: "The spring concert is on Thursday 14 May at 18:30.",
        citations: [VaultCitation(path: "Family/School-Year.md", line: 7)])

    func testAnAnsweredReplyLeadsWithTheBadgeAndEndsWithItsSources() {
        let body = OfflineLookupReply.body(.answered(answer), queued: true)
        XCTAssertTrue(body.hasPrefix("[on-device · offline]\n\n"))
        XCTAssertTrue(body.contains("Thursday 14 May at 18:30."))
        XCTAssertTrue(body.contains("\nFrom:\n"))
        XCTAssertTrue(body.contains("[Family/School-Year.md:7](jesse://note?path=Family/School-Year.md&line=7)"))
    }

    func testAnAbstainSaysWhereTheQuestionWent() {
        XCTAssertEqual(OfflineLookupReply.body(.abstained, queued: true),
                       "[on-device · offline]\n\nNot found in the vault on this device. "
                       + "Queued for the bridge.")
    }

    /// The Mac has no send outbox, so it must not claim a queue it does not have.
    func testAnAbstainOnADeviceWithNoQueueDoesNotClaimOne() {
        XCTAssertEqual(OfflineLookupReply.body(.abstained, queued: false),
                       "[on-device · offline]\n\nNot found in the vault on this device.")
    }

    func testANotALookupIsJustQueued() {
        XCTAssertEqual(OfflineLookupReply.body(.notALookup, queued: true),
                       "[on-device · offline]\n\nQueued for the bridge.")
    }

    /// The badge is the bridge's own local-route shape.
    func testTheBadgeMatchesTheBridgesLocalRouteStyle() {
        XCTAssertEqual(OfflineLookupReply.badge, "[on-device · offline]")
    }

    // MARK: - The citation link

    func testANoteRouteRoundTripsThroughItsURL() {
        let route = VaultNoteRoute(path: "People/Marta Ruggeri.md", line: 12)
        let parsed = VaultNoteRoute.parse(route.url)
        XCTAssertEqual(parsed?.path, "People/Marta Ruggeri.md")
        XCTAssertEqual(parsed?.line, 12)
    }

    func testARouteWithNoLineRoundTrips() {
        let route = VaultNoteRoute(path: "Today.md")
        let parsed = VaultNoteRoute.parse(route.url)
        XCTAssertEqual(parsed?.path, "Today.md")
        XCTAssertNil(parsed?.line)
    }

    /// The app's OTHER user of the `jesse` scheme must not be claimed by this one.
    func testTheShareAudioURLIsNotANoteRoute() {
        XCTAssertNil(VaultNoteRoute.parse(URL(string: "jesse://share-audio")!))
        XCTAssertNil(VaultNoteRoute.parse(URL(string: "jesse://note")!))
        XCTAssertNil(VaultNoteRoute.parse(URL(string: "jesse://note?path=")!))
        XCTAssertNil(VaultNoteRoute.parse(URL(string: "https://note?path=a.md")!))
    }

    // MARK: - The settings

    func testTheToggleIsOnUntilItIsTurnedOff() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "offline-lookup-\(UUID())"))
        let settings = OfflineLookupSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled)
        settings.isEnabled = false
        XCTAssertFalse(settings.isEnabled)
        settings.isEnabled = true
        XCTAssertTrue(settings.isEnabled)
    }

    func testTheMeasuredPromptSizeIsAbsentUntilTheProbeHasRun() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "offline-lookup-\(UUID())"))
        let settings = OfflineLookupSettings(defaults: defaults)
        XCTAssertNil(settings.measuredPromptCharacters)
        XCTAssertEqual(settings.budget.chunkCount, 4)
        XCTAssertEqual(settings.budget.totalCharacters, 12_000)
        XCTAssertTrue(settings.description.contains("not measured"))

        settings.measuredPromptCharacters = 33_500
        XCTAssertEqual(settings.measuredPromptCharacters, 33_500)
        XCTAssertEqual(settings.budget.totalCharacters, 20_100)
        XCTAssertTrue(settings.description.contains("33500"))

        settings.measuredPromptCharacters = nil
        XCTAssertNil(settings.measuredPromptCharacters)
    }

    // MARK: - The diagnostics ring

    @MainActor
    func testTheDiagnosticsListKeepsTheLastTenNewestFirst() {
        let list = OfflineLookupDiagnostics()
        for index in 0..<14 {
            list.record(OfflineLookupRecord(question: "q\(index)", gateVerdict: "lookup",
                                            hitCount: 1, chunkCount: 1, characters: 10,
                                            elapsed: 0.5, outcome: "answered"))
        }
        XCTAssertEqual(list.records.count, 10)
        XCTAssertEqual(list.records.first?.question, "q13")
        XCTAssertEqual(list.records.last?.question, "q4")
    }

    @MainActor
    func testADiagnosticsRowNamesEveryNumberItPromised() {
        let row = OfflineLookupRecord(question: "when is the school concert",
                                      gateVerdict: "lookup", hitCount: 7, chunkCount: 4,
                                      characters: 3_120, elapsed: 2.5,
                                      outcome: "answered (1 cited)")
        XCTAssertTrue(row.line.contains("lookup"))
        XCTAssertTrue(row.line.contains("7 hits"))
        XCTAssertTrue(row.line.contains("4 chunks"))
        XCTAssertTrue(row.line.contains("3120 chars"))
        XCTAssertTrue(row.line.contains("2.5 s"))
        XCTAssertTrue(row.line.contains("answered (1 cited)"))
    }
}
