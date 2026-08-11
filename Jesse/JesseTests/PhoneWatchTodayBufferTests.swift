import XCTest
import SwiftData
import JesseCore
@testable import Jesse

/// The launch-order race between a queued wrist check and the view that can apply it.
///
/// This is not an exotic case, it is the ORDINARY one: `WCSession` activates in
/// `didFinishLaunchingWithOptions`, and a `transferUserInfo` queued while the phone
/// was in another room is delivered immediately after — a beat before `RootTabView`
/// exists to hand over the day model. Dropping the intent there meant the exact
/// situation the reliable queue exists for was the one that silently did nothing.
@MainActor
final class PhoneWatchTodayBufferTests: XCTestCase {

    private func makeDelegate() throws -> PhoneWatchConnectivity {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let relay = WatchRelay(coordinator: RunCoordinator())
        let handler = WatchTurnHandler(transcriber: SpeechFrameworkTranscriber(), relay: relay)
        return PhoneWatchConnectivity(handler: handler, context: ModelContext(container))
    }

    func testAnIntentArrivingBeforeTheHandlerIsHeldAndThenDelivered() throws {
        let phone = try makeDelegate()
        let check = WatchTodayCheck(intentId: UUID(), itemId: "abc", checked: true)
        phone.receiveTodayCheck(check)

        var seen: [WatchTodayCheck] = []
        phone.onTodayCheck = { seen.append($0) }

        XCTAssertEqual(seen, [check])
    }

    func testIntentsAreDeliveredInArrivalOrder() throws {
        let phone = try makeDelegate()
        let first = WatchTodayCheck(intentId: UUID(), itemId: "one", checked: true)
        let second = WatchTodayCheck(intentId: UUID(), itemId: "two", checked: false)
        phone.receiveTodayCheck(first)
        phone.receiveTodayCheck(second)

        var seen: [WatchTodayCheck] = []
        phone.onTodayCheck = { seen.append($0) }

        XCTAssertEqual(seen, [first, second])
    }

    func testOnceWiredAnIntentGoesStraightThrough() throws {
        let phone = try makeDelegate()
        var seen: [WatchTodayCheck] = []
        phone.onTodayCheck = { seen.append($0) }

        let check = WatchTodayCheck(intentId: UUID(), itemId: "abc", checked: true)
        phone.receiveTodayCheck(check)
        XCTAssertEqual(seen, [check])
    }

    /// The buffer is emptied by the flush, so a second wiring (the view rebuilding)
    /// does not replay a check that has already been applied.
    func testTheBufferIsNotReplayedOnASecondWiring() throws {
        let phone = try makeDelegate()
        phone.receiveTodayCheck(WatchTodayCheck(intentId: UUID(), itemId: "abc", checked: true))
        phone.onTodayCheck = { _ in }

        var second: [WatchTodayCheck] = []
        phone.onTodayCheck = { second.append($0) }
        XCTAssertTrue(second.isEmpty)
    }

    /// A phone that never shows its UI must not accumulate intents without bound.
    /// Losing the oldest is the right end to lose from: the newest claim about an
    /// item is the one the user made most recently.
    func testTheBufferIsBounded() throws {
        let phone = try makeDelegate()
        let checks = (0..<40).map {
            WatchTodayCheck(intentId: UUID(), itemId: "item-\($0)", checked: true)
        }
        checks.forEach(phone.receiveTodayCheck)

        var seen: [WatchTodayCheck] = []
        phone.onTodayCheck = { seen.append($0) }

        XCTAssertEqual(seen.count, 32)
        XCTAssertEqual(seen.last, checks.last)
    }
}
