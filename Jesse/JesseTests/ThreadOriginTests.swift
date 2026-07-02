import XCTest
import SwiftData
@testable import Jesse

/// Item 1 — the `origin` tag on `JesseThread`. A default thread is `.phone`; the
/// raw value round-trips through `ThreadOrigin`; and a store migrated from before
/// `origin` existed (an unknown/absent raw value) reads back as `.phone` with no
/// loss, mirroring how `modeValue` defaults an unknown mode to `.ask`.
final class ThreadOriginTests: XCTestCase {

    func testDefaultThreadIsPhone() {
        let thread = JesseThread(mode: .ask)
        XCTAssertEqual(thread.originValue, .phone)
        XCTAssertEqual(thread.origin, ThreadOrigin.phone.rawValue)
    }

    func testWatchRawValueDecodes() {
        let thread = JesseThread(mode: .ask)
        thread.origin = ThreadOrigin.watch.rawValue
        XCTAssertEqual(thread.originValue, .watch)
    }

    /// The lightweight-migration guarantee: a row whose `origin` is unknown/absent
    /// (what an old store, or a corrupted value, presents) must NOT crash or read
    /// as watch — it reads as `.phone`.
    func testUnknownOriginReadsAsPhone() {
        let thread = JesseThread(mode: .ask)
        thread.origin = ""            // an old row with no meaningful origin value
        XCTAssertEqual(thread.originValue, .phone)
        thread.origin = "bogus"
        XCTAssertEqual(thread.originValue, .phone)
    }

    /// Persisting and re-fetching a `.watch` thread through a real (in-memory)
    /// SwiftData store keeps the origin — proving it's a stored property, not just
    /// an in-memory flag.
    @MainActor
    func testOriginPersistsThroughStore() throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let thread = JesseThread(mode: .ask)
        thread.origin = ThreadOrigin.watch.rawValue
        let id = thread.id
        context.insert(thread)
        try context.save()

        var descriptor = FetchDescriptor<JesseThread>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let fetched = try XCTUnwrap(context.fetch(descriptor).first)
        XCTAssertEqual(fetched.originValue, .watch)
    }
}
