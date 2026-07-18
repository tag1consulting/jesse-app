import XCTest
import SwiftData
@testable import Jesse

/// `JesseThread.orderedTurns` is read in the transcript's hot path, which
/// re-evaluates ~10Hz during a streaming reply. It must sort the thread's turns
/// only when the set of turns actually changes — not on every read — so a long
/// stream doesn't re-sort the whole thread hundreds of times. This pins the
/// memoization: repeated reads with no mutation perform exactly one sort, and an
/// append invalidates the cache so ordering stays correct.
@MainActor
final class ThreadOrderedTurnsTests: XCTestCase {

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    func testOrderedTurnsSortsOnceAcrossReadsAndInvalidatesOnAppend() throws {
        let context = try makeContext()
        let thread = JesseThread(mode: .ask)
        context.insert(thread)

        // Insert turns OUT of chronological order so a real sort is observable.
        let base = Date(timeIntervalSince1970: 1_000_000)
        let second = Turn(role: .jesse, text: "second", createdAt: base.addingTimeInterval(20))
        let first = Turn(role: .user, text: "first", createdAt: base)
        let middle = Turn(role: .jesse, text: "middle", createdAt: base.addingTimeInterval(10))
        for t in [second, first, middle] {
            t.thread = thread
            context.insert(t)
        }

        // First read sorts once and yields chronological order.
        XCTAssertEqual(thread.orderedTurns.map(\.text), ["first", "middle", "second"])
        XCTAssertEqual(thread.orderedSortCount, 1, "the first read sorts exactly once")

        // Repeated reads with no mutation return the cache — no further sorts.
        _ = thread.orderedTurns
        _ = thread.orderedTurns
        XCTAssertEqual(thread.orderedSortCount, 1,
                       "repeated reads must reuse the cache, not re-sort")

        // Appending a turn changes the count → the cache invalidates → exactly one
        // more sort, and the new turn lands in order.
        let third = Turn(role: .user, text: "third", createdAt: base.addingTimeInterval(30))
        third.thread = thread
        context.insert(third)
        XCTAssertEqual(thread.orderedTurns.map(\.text),
                       ["first", "middle", "second", "third"])
        XCTAssertEqual(thread.orderedSortCount, 2,
                       "an append invalidates the cache — one additional sort")

        // And reads settle back to cached after the append.
        _ = thread.orderedTurns
        XCTAssertEqual(thread.orderedSortCount, 2, "post-append reads are cached again")
    }
}
