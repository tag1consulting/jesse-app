import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseNetworking
import JesseDietDisplay

/// **Start-new-day through the real `HealthTurn`**, from the button and from the weigh-in.
///
/// Both record the diet day in `HealthNewDay.lastFiredDayKey`, and only the automatic
/// weigh-in is stopped by it. A tap is deliberate and always runs the refresh, online or held
/// offline; the day it records is what keeps a later weigh-in from firing a second one. The
/// route is `HealthTurnRoute`'s test in JesseCore. What only this file can show is which
/// caller turns the day guard on.
@MainActor
final class HealthTurnTests: XCTestCase {

    private static let day = "2026-08-22"

    // MARK: - Fixtures

    private static func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private static func coordinator(_ client: PromptCountingClient) -> RunCoordinator {
        RunCoordinator(config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
                       makeClient: { _ in client })
    }

    /// A loaded dashboard, so `captureDay` is known, then marked offline or not.
    private static func model(offline: Bool,
                              pending: HeldRuns? = nil) async -> HealthDashboardModel {
        let model = HealthDashboardModel(makeClient: { OneDietDay(day: day) }, pending: pending)
        await model.load()
        model.isNetworkUnreachable = offline
        return model
    }

    /// A defaults domain of this test's own, so the real last-fired day is never touched.
    private func freshDefaults() -> UserDefaults {
        let suite = "HealthTurnTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    /// Let the coordinator's detached send task run.
    private static func settle() async {
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    // MARK: - The button

    /// Today's refresh already ran from this device, and a tap runs it again.
    func testATapSendsEvenWhenTodaysRefreshAlreadyRan() async throws {
        let defaults = freshDefaults()
        defaults.set(Self.day, forKey: HealthNewDay.lastFiredDayKey)
        let context = try Self.makeContext()
        let client = PromptCountingClient()
        let coordinator = Self.coordinator(client)
        let model = await Self.model(offline: false)

        let outcome = HealthTurn.startNewDay(model: model, coordinator: coordinator,
                                             context: context, origin: .phone,
                                             dietDay: Self.day, oncePerDay: false,
                                             defaults: defaults)

        XCTAssertEqual(outcome, .sent)
        await Self.settle()
        XCTAssertEqual(client.count(of: HealthNewDay.prompt), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1)
    }

    /// Offline, the same tap is held rather than refused as a repeat.
    func testATapOfflineOnADayThatAlreadyRanIsHeld() async throws {
        let defaults = freshDefaults()
        defaults.set(Self.day, forKey: HealthNewDay.lastFiredDayKey)
        let store = HeldRuns()
        let client = PromptCountingClient()
        let coordinator = Self.coordinator(client)
        let model = await Self.model(offline: true, pending: store)

        let outcome = HealthTurn.startNewDay(model: model, coordinator: coordinator,
                                             context: try Self.makeContext(), origin: .phone,
                                             dietDay: Self.day, oncePerDay: false,
                                             defaults: defaults)

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(store.all().map(\.kind), [.startNewDay])
        await Self.settle()
        XCTAssertEqual(client.count(of: HealthNewDay.prompt), 0, "held, not sent")
    }

    // MARK: - The weigh-in

    /// A tap records the day, so the first weigh-in after it fires nothing: one refresh.
    func testAWeighInAfterATapFiresNothing() async throws {
        let defaults = freshDefaults()
        let context = try Self.makeContext()
        let client = PromptCountingClient()
        let coordinator = Self.coordinator(client)
        let model = await Self.model(offline: false)

        XCTAssertEqual(HealthTurn.startNewDay(model: model, coordinator: coordinator,
                                              context: context, origin: .phone,
                                              dietDay: Self.day, oncePerDay: false,
                                              defaults: defaults), .sent)
        XCTAssertEqual(defaults.string(forKey: HealthNewDay.lastFiredDayKey), Self.day)

        XCTAssertEqual(HealthTurn.startNewDay(model: model, coordinator: coordinator,
                                              context: context, origin: .automatic,
                                              dietDay: Self.day, oncePerDay: true,
                                              capturedDay: Self.day,
                                              defaults: defaults), .alreadyRan)

        await Self.settle()
        XCTAssertEqual(client.count(of: HealthNewDay.prompt), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<JesseThread>()).count, 1)
    }
}

// MARK: - Doubles

/// Records the text of every send without touching the network.
@MainActor
private final class PromptCountingClient: JesseClientProtocol {
    private(set) var sent: [String] = []

    func count(of text: String) -> Int { sent.filter { $0 == text }.count }

    func send(mode: JesseMode, text: String, sessionId: String?,
              conversationId: String, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment], requestId: UUID,
              model: String?, effort: String?) async throws -> JesseSendResult {
        sent.append(text)
        return .reply(JesseReply(text: "ok", sessionId: "s-1"), jobId: nil, conversationId: nil)
    }

    func result(jobId: String) async throws -> JesseResultState { .running }
    func cancelJob(jobId: String) async throws {}
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// One diet day with nothing in it, so the model has a `captureDay` to hold a run against.
private struct OneDietDay: DietSnapshotProviding {
    let day: String

    func fetchDietSnapshot(date: String?) async throws -> DietSnapshot {
        try DietSnapshot.decode(from: Data("""
        {"asOf":"\(day)T07:00:00Z","dietDay":"\(day)",
         "today":{"date":"\(day)","exercise":[],"meals":[],"targets":{"calories":2100}},
         "errors":[]}
        """.utf8))
    }
}

/// An in-memory capture queue.
private final class HeldRuns: PendingIntentStoring {
    nonisolated deinit {}
    private(set) var records: [PendingIntentRecord] = []
    func all() -> [PendingIntentRecord] { records.sorted { $0.createdAt < $1.createdAt } }
    func append(_ record: PendingIntentRecord) { records.append(record) }
    func update(_ record: PendingIntentRecord) {
        guard let i = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[i] = record
    }
    func delete(id: UUID) { records.removeAll { $0.id == id } }
}
