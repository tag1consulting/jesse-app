import XCTest
import SwiftData
@testable import Jesse
import JesseCore
import JesseNetworking
import JesseDietDisplay

/// The iOS half of the Health tab's "Ask about this": what a long-press actually opens,
/// what the first send carries, and when a second ask RESUMES rather than forking.
///
/// The context model, the serializers and the frozen prompt are the package's tests
/// (`HealthAskTests`, `HealthAskPromptTests`) and are not re-tested here. What is only
/// true on iOS is what this file pins: that an ask STAGES and fires nothing, that the
/// snapshot rides the user's own first message through `RunCoordinator`, that the
/// transcript shows their half and not the snapshot, and that resume is keyed on the
/// reading rather than on the area.
@MainActor
final class HealthAskTabTests: XCTestCase {

    // MARK: - Fixtures

    private static func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private static func coordinator(_ client: CapturingAskClient) -> RunCoordinator {
        RunCoordinator(config: { JesseConfig(host: "studio", port: 8765, token: "tok") },
                       makeClient: { _ in client })
    }

    /// A day with one meal and a scrap of nutrient history, so a real snapshot has
    /// something in it AND the rolling-window read is available (which is what makes two
    /// different readings of the same day reachable through the public surface).
    private static func snapshot() -> DietSnapshot {
        let json = """
        { "asOf": "2026-08-22T14:00:00Z",
          "today": { "date": "2026-08-22", "exercise": [], "targets": { "calories": 2200 },
            "meals": [{ "name": "Lunch", "time": "12:30", "items": [
              { "item": "Chicken thigh", "amount": "200 g", "cal": 330, "p": 38, "f": 19, "c": 0, "fiber": 0 }
            ]}] },
          "nutrientSeries": [
            { "date": "2026-08-21", "nutrients": { "cal": { "sum": 2100, "known": 4, "unknown": 0 } },
              "targets": { "calories": 2200 } },
            { "date": "2026-08-22", "nutrients": { "cal": { "sum": 330, "known": 1, "unknown": 0 } },
              "targets": { "calories": 2200 } }
          ],
          "errors": [] }
        """
        return try! DietSnapshot.decode(from: Data(json.utf8))
    }

    private static func modelContext(_ model: HealthDashboardModel) -> HealthAskContext {
        // The page context is the one the shell's toolbar entry uses, and the only ask
        // context reachable without a view — which makes it the right one to drive these.
        model.pageAskContext!
    }

    private static func loadedModel() async -> HealthDashboardModel {
        let model = HealthDashboardModel(makeClient: { StubDietClient(snapshot()) })
        await model.load()
        return model
    }

    /// Let the coordinator's detached send task run.
    private static func settle() async {
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    // MARK: - An ask stages; it does not fire

    func testAnAskOpensAThreadAndStartsNoTurn() async throws {
        let store = try Self.makeContext()
        let client = CapturingAskClient()
        let coordinator = Self.coordinator(client)
        let ask = Self.modelContext(await Self.loadedModel())
        let before = try store.fetch(FetchDescriptor<JesseThread>()).count

        let thread = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)

        XCTAssertEqual(thread.mode, JesseMode.ask.rawValue,
                       "an ask is an ASK — the floor that forbids unrequested task work")
        XCTAssertTrue(thread.turns.isEmpty, "an empty composer, not a fired snapshot")
        XCTAssertFalse(coordinator.isRunning(thread.id))
        XCTAssertEqual(try store.fetch(FetchDescriptor<JesseThread>()).count, before,
                       "an abandoned ask leaves no empty conversation behind")
        await Self.settle()
        XCTAssertTrue(client.sent.isEmpty)
    }

    /// The conversation is named after the SCOPE, not after a page of serialized
    /// numbers — which is what makes the chat header say what "this" refers to.
    func testTheThreadIsNamedAfterTheScope() async throws {
        let store = try Self.makeContext()
        let ask = Self.modelContext(await Self.loadedModel())
        let thread = HealthAskOpener.open(ask, coordinator: Self.coordinator(CapturingAskClient()),
                                          modelContext: store)
        XCTAssertEqual(thread.title, ask.title)
        XCTAssertEqual(thread.askScopeTitle, ask.title)
        XCTAssertEqual(thread.askScopeKey, ask.scopeKey)
    }

    /// The attachment held for the first send carries the frozen prompt, the scope title
    /// and the starters — all three, or the chat cannot show what it promises.
    func testTheAttachmentCarriesThePromptTitleAndStarters() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let ask = Self.modelContext(await Self.loadedModel())
        let thread = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)

        let attachment = coordinator.attachment(for: thread.id)
        XCTAssertEqual(attachment?.body, ask.promptText)
        XCTAssertEqual(attachment?.title, ask.title)
        XCTAssertEqual(attachment?.starters, ask.suggestedQuestions)
        XCTAssertFalse(ask.suggestedQuestions.isEmpty)
    }

    // MARK: - The first send

    /// The user's question goes out with the snapshot composed AHEAD of it, through the
    /// same `TodayThreadContext.firstMessage` rule the Today tab uses — one definition of
    /// what a screen-scoped turn looks like, not two.
    func testTheFirstSendCarriesTheSnapshotAheadOfTheQuestion() async throws {
        let store = try Self.makeContext()
        let client = CapturingAskClient()
        let coordinator = Self.coordinator(client)
        let ask = Self.modelContext(await Self.loadedModel())
        let thread = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)

        coordinator.send(thread: thread, text: "What's good and bad about today?",
                         voice: false, context: store)
        await Self.settle()

        XCTAssertEqual(client.sent.count, 1)
        XCTAssertEqual(client.sent.first?.text,
                       TodayThreadContext.firstMessage(context: ask.promptText,
                                                       typed: "What's good and bad about today?"))
        XCTAssertNil(coordinator.attachment(for: thread.id), "spent by the first send")
    }

    /// The snapshot reaches the MODEL but not the transcript: `text` is the composed
    /// turn, `visibleText` is the user's own half. Pasting a page of numbers into their
    /// bubble would be both unreadable and untrue.
    func testTheTranscriptShowsTheQuestionAndNotTheSnapshot() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let ask = Self.modelContext(await Self.loadedModel())
        let thread = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)

        coordinator.send(thread: thread, text: "Why is lunch so caloric?",
                         voice: false, context: store)
        await Self.settle()

        let turn = try XCTUnwrap(thread.orderedTurns.first)
        XCTAssertTrue(turn.text.contains("Chicken thigh"), "the model gets the whole snapshot")
        XCTAssertEqual(turn.visibleText, "Why is lunch so caloric?")
        XCTAssertTrue(turn.hasAttachedContext)
        XCTAssertEqual(turn.contextLabel, ask.title)
    }

    /// An empty composer with a snapshot attached is the explicit "just look at it" send.
    /// It stays a real turn, and its transcript half is empty rather than a wall of text.
    func testAnEmptySendIsTheSnapshotAlone() async throws {
        let store = try Self.makeContext()
        let client = CapturingAskClient()
        let coordinator = Self.coordinator(client)
        let ask = Self.modelContext(await Self.loadedModel())
        let thread = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)

        coordinator.send(thread: thread, text: "", voice: false, context: store)
        await Self.settle()

        XCTAssertEqual(client.sent.first?.text, ask.promptText)
        XCTAssertEqual(thread.orderedTurns.first?.visibleText, "")
    }

    /// A turn with no attached context is unchanged in every respect — the widening must
    /// not touch the ordinary path.
    func testAnOrdinaryTurnHasNoHiddenHalf() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let thread = JesseThread(mode: .ask)
        store.insert(thread)

        coordinator.send(thread: thread, text: "Hello", voice: false, context: store)
        await Self.settle()

        let turn = try XCTUnwrap(thread.orderedTurns.first)
        XCTAssertFalse(turn.hasAttachedContext)
        XCTAssertNil(turn.contextLabel)
        XCTAssertEqual(turn.visibleText, "Hello")
        XCTAssertEqual(turn.visibleText, turn.text)
    }

    // MARK: - Resume

    /// A second ask about the SAME reading on the same day continues the conversation
    /// rather than forking a near-identical one.
    func testAsecondAskAboutTheSameReadingResumes() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let ask = Self.modelContext(await Self.loadedModel())

        let first = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)
        // Only a conversation that was actually HAD is resumable — the send is what puts
        // it in the store.
        coordinator.send(thread: first, text: "What's good about today?",
                         voice: false, context: store)
        await Self.settle()

        let second = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try store.fetch(FetchDescriptor<JesseThread>()).count, 1)
    }

    /// Resuming re-attaches a FRESH snapshot, so the next message argues from the current
    /// screen rather than from this morning's.
    func testResumingReattachesTheCurrentSnapshot() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let ask = Self.modelContext(await Self.loadedModel())

        let first = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)
        coordinator.send(thread: first, text: "First question", voice: false, context: store)
        await Self.settle()
        XCTAssertNil(coordinator.attachment(for: first.id))

        _ = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)
        XCTAssertEqual(coordinator.attachment(for: first.id)?.body, ask.promptText)
    }

    /// An ABANDONED ask leaves nothing to resume: it was never in the store, so the next
    /// press starts fresh rather than reopening an empty conversation.
    func testAnAbandonedAskIsNotResumed() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let ask = Self.modelContext(await Self.loadedModel())

        let first = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)
        let second = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)
        XCTAssertNotEqual(second.id, first.id)
    }

    /// A DIFFERENT reading gets its own conversation, even in the same area on the same
    /// day — resume is keyed on the READING, never on the area. Here the two readings are
    /// the same page in the tab's two window modes: today's numbers, and the rolling
    /// 7-day medians. They are different questions and must not share a thread.
    func testADifferentReadingOfTheSameDayDoesNotResume() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let model = await Self.loadedModel()

        let dayRead = model.pageAskContext!
        let first = HealthAskOpener.open(dayRead, coordinator: coordinator, modelContext: store)
        coordinator.send(thread: first, text: "About the day", voice: false, context: store)
        await Self.settle()

        model.nutrientWindow = .week
        let weekRead = model.pageAskContext!
        XCTAssertNotEqual(weekRead.scopeKey, dayRead.scopeKey,
                          "the window mode is part of what is being read")
        XCTAssertNil(HealthAskOpener.resumable(weekRead, modelContext: store))
    }

    /// Yesterday's conversation about "today" is not today's. The scope key carries the
    /// anchor date and the lookup is bounded to the current calendar day, so both halves
    /// have to fail before a stale conversation could be reopened.
    func testYesterdaysConversationIsNotResumed() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let ask = Self.modelContext(await Self.loadedModel())

        let thread = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)
        coordinator.send(thread: thread, text: "Yesterday's question", voice: false, context: store)
        await Self.settle()
        // Backdate it: the conversation was had, but not today.
        thread.createdAt = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        XCTAssertNil(HealthAskOpener.resumable(ask, modelContext: store))
    }

    /// An archived conversation is one the user is done with — never silently reopened.
    func testAnArchivedConversationIsNotResumed() async throws {
        let store = try Self.makeContext()
        let coordinator = Self.coordinator(CapturingAskClient())
        let ask = Self.modelContext(await Self.loadedModel())

        let thread = HealthAskOpener.open(ask, coordinator: coordinator, modelContext: store)
        coordinator.send(thread: thread, text: "A question", voice: false, context: store)
        await Self.settle()
        thread.isArchived = true

        XCTAssertNil(HealthAskOpener.resumable(ask, modelContext: store))
    }
}

// MARK: - Doubles

/// Captures what was sent without touching the network — these tests are about what
/// LEAVES the app, not about replies. Mirrors `TodayTabTests.CapturingClient`.
@MainActor
private final class CapturingAskClient: JesseClientProtocol {
    struct Sent {
        let mode: JesseMode
        let text: String
    }
    private(set) var sent: [Sent] = []

    func send(mode: JesseMode, text: String, sessionId: String?,
              conversationId: String, voice: Bool,
              instructions: String?, floorOverride: String?,
              attachments: [JesseAttachment], requestId: UUID,
              model: String?) async throws -> JesseSendResult {
        sent.append(Sent(mode: mode, text: text))
        return .reply(JesseReply(text: "ok", sessionId: "s-1"), jobId: nil, conversationId: nil)
    }

    func result(jobId: String) async throws -> JesseResultState { .running }
    func cancelJob(jobId: String) async throws {}
    func stream(jobId: String) -> AsyncThrowingStream<JesseStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct StubDietClient: DietSnapshotProviding {
    let snapshot: DietSnapshot
    init(_ snapshot: DietSnapshot) { self.snapshot = snapshot }
    func fetchDietSnapshot(date: String?) async throws -> DietSnapshot { snapshot }
}
