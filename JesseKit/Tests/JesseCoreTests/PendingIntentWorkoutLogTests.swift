import XCTest
import SwiftData
@testable import JesseCore

/// The `logWorkouts` intent kind and the payload's `origin`, at the storage layer.
@MainActor
final class PendingIntentWorkoutLogTests: XCTestCase {

    func testLogWorkoutsOpensAConversationRatherThanWritingTheDayFile() {
        XCTAssertFalse(PendingIntentKind.logWorkouts.isDayFileWrite)
        XCTAssertNil(PendingIntentKind.logWorkouts.asserts)
        XCTAssertEqual(PendingIntentKind.logWorkouts.label, "Log workouts")
    }

    /// The vocabulary is closed and decoded by name, so the new case must round-trip by its
    /// raw string — a name the enum did not know would be read back as something else.
    func testLogWorkoutsRoundTripsThroughTheStore() throws {
        let container = try ModelContainer(for: PendingIntent.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = PendingIntentStore(context: ModelContext(container))
        store.append(PendingIntentRecord(kind: .logWorkouts, dayDate: "2026-09-08",
                                         payload: PendingIntentPayload(origin: "automatic")))
        let back = try XCTUnwrap(store.all().first)
        XCTAssertEqual(back.kind, .logWorkouts)
        XCTAssertEqual(back.payload.origin, "automatic")
    }

    /// A payload stored before `origin` existed still decodes, with no origin.
    func testAPayloadWrittenBeforeOriginExistedStillDecodes() {
        let old = PendingIntentPayload.decode(#"{"text":"Log a meal: eggs"}"#)
        XCTAssertEqual(old.text, "Log a meal: eggs")
        XCTAssertNil(old.origin)
    }
}
