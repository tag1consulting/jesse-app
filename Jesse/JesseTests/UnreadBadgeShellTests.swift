import XCTest
import SwiftData
import SwiftUI
@testable import Jesse
import JesseCore

/// The SHELL's side of the unread badge: what the app's root view is allowed to hold, and
/// what one save used to cost the badge against what it costs now.
///
/// `UnreadCounterTests` (JesseKit) pins the counter's behavior. What can only be checked
/// here is the thing that actually made the app hitch: that the root view no longer holds
/// every conversation.
@MainActor
final class UnreadBadgeShellTests: XCTestCase {

    // MARK: - The root holds no conversations

    /// THE REGRESSION THIS PR EXISTS FOR, stated structurally.
    ///
    /// `RootTabView` is the app's root: its body builds all three tabs, so anything it
    /// depends on, all three tabs depend on. A `@Query` over `JesseThread` there — which is
    /// what the unread badge arrived with — is refetched on every save that touches any
    /// conversation, and every refetch rebuilds the Health and Today screens whether or not
    /// anyone is looking at them.
    ///
    /// Reflection over the view's stored properties is the smallest mechanism that can say
    /// so: a `@Query` is a stored `Query<JesseThread, [JesseThread]>` and a plain array is
    /// `[JesseThread]`, and both name the model in their type. It fails against a build
    /// where either is reintroduced, whatever it is called.
    func testTheRootShellHoldsNoConversationRows() {
        let offenders = threadShapedProperties(of: RootTabView())
        XCTAssertTrue(
            offenders.isEmpty,
            """
            `RootTabView` holds \(offenders.joined(separator: ", ")). The app's ROOT view \
            must not depend on conversation rows: a query there is refetched on every save \
            that touches a thread, and its body rebuilds all three tabs. The badge's number \
            comes from `UnreadCounter` (a count query, coalesced, published only when it \
            changes); the per-row dot belongs to `ThreadListView`, which owns its own query \
            and is entitled to re-render.
            """
        )
    }

    /// And the number it shows really is the counter's, not a second count of its own.
    /// Asserted through the one public seam there is: the counter for a container is a
    /// single object, so the tab badge, the icon and (on the Mac) the Dock tile are reading
    /// one value rather than three.
    func testTheShellsShareOneCounterPerStore() throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let first = UnreadCounter.shared(for: container)
        let second = UnreadCounter.shared(for: container)
        XCTAssertTrue(first === second, "one counter per store, not one per view")
    }

    /// Every stored property of `view` whose type names `JesseThread` — a `@Query`, a bare
    /// array, or anything else that would put the conversation set on the view.
    private func threadShapedProperties(of view: some View) -> [String] {
        Mirror(reflecting: view).children.compactMap { child in
            let type = String(describing: type(of: child.value))
            guard type.contains("JesseThread") else { return nil }
            return "\(child.label ?? "an unnamed property") of type \(type)"
        }
    }

    // MARK: - What a save costs the badge

    /// THE MEASUREMENT, as a test: the two roads to the same number, over a store the size
    /// of a real one.
    ///
    /// The old road is what a root-level `@Query` plus `jesseUnreadCount` did on EVERY save
    /// that touched a conversation: fetch every row, then walk them. The new road is one
    /// count query, at most once per coalescing window. Both answers must agree — that is
    /// the assertion — and the elapsed times are printed for the PR rather than asserted,
    /// because a CI simulator's clock is not evidence of anything.
    func testTheOldAndNewRoadsToTheBadgeAgree() throws {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for i in 0..<300 {
            let t = JesseThread(title: "c\(i)", mode: .ask)
            t.noteReply(atUnixMillis: 1_000 + i)
            // Every tenth conversation holds an unseen reply.
            if !i.isMultiple(of: 10) { t.markRead(nowMs: 1) }
            context.insert(t)
        }
        try context.save()

        // The old road, timed the way the app paid for it: once per save.
        let oldStart = Date()
        let rows = try context.fetch(FetchDescriptor<JesseThread>())
        let oldCount = jesseUnreadCount(rows)
        let oldMs = Date().timeIntervalSince(oldStart) * 1000

        // The new road.
        let counter = UnreadCounter(container: container, sleep: { _ in })
        let newStart = Date()
        counter.recountNow()
        let newMs = Date().timeIntervalSince(newStart) * 1000

        XCTAssertEqual(rows.count, 300, "the old road materialized every row — that is the cost")
        XCTAssertEqual(oldCount, 30)
        XCTAssertEqual(counter.unreadCount, oldCount, "the same number, by a cheaper road")

        print("""
        unread badge, 300 conversations: \
        fetch-all + rule = \(String(format: "%.2f", oldMs)) ms (300 rows materialized), \
        count query = \(String(format: "%.2f", newMs)) ms (0 rows materialized)
        """)
    }
}
