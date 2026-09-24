import XCTest
import SwiftData
@testable import Jesse
import JesseCore

/// WHICH TAB A LANDING SELECTS.
///
/// Opening a conversation used to be one write — the navigation path — and that was the
/// defect. `ThreadDetailView` hides the root TabView's bar for the whole shell, so a push
/// made from a notification tap (or Siri, or the wake capture, or a shared recording)
/// while the user was on Today took the bar away under Today, with the conversation
/// unreachable behind it and a force quit as the only way out.
///
/// The landing is therefore a pair of writes, and this pins the pair for EVERY tab the
/// app has rather than for the one that happened to reproduce it.
@MainActor
final class ThreadLandingTests: XCTestCase {

    private func makeThread() throws -> JesseThread {
        let container = try ModelContainer(
            for: JesseThread.self, Turn.self, OutboxItem.self, OutboxAttachment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let thread = JesseThread(title: "A conversation", mode: .ask)
        context.insert(thread)
        return thread
    }

    /// From anywhere: Chats is selected and the conversation is the whole path.
    func testALandingSelectsChatsFromEveryTab() throws {
        for tab in RootTabView.Tab.allCases {
            let thread = try makeThread()
            var selection = tab
            var path: [JesseThread] = []

            ThreadLanding.apply(thread: thread, selection: &selection, path: &path)

            XCTAssertEqual(selection, .chats, "landing from \(tab.rawValue) must select Chats")
            XCTAssertEqual(path.count, 1, "landing from \(tab.rawValue) pushes exactly one")
            XCTAssertIdentical(path.first, thread, "landing from \(tab.rawValue) pushes the thread")
        }
    }

    /// A landing REPLACES whatever was on the stack rather than pushing onto it, which is
    /// what the four entry points did with their bare `path = [thread]` and what the back
    /// swipe's one-step pop to the list depends on.
    func testALandingReplacesAnExistingPath() throws {
        let previous = try makeThread()
        let thread = try makeThread()
        var selection = RootTabView.Tab.vault
        var path = [previous]

        ThreadLanding.apply(thread: thread, selection: &selection, path: &path)

        XCTAssertEqual(selection, .chats)
        XCTAssertEqual(path.count, 1)
        XCTAssertIdentical(path.first, thread)
    }

    /// The seam that drives the UI test is OFF unless its variable is set — this process
    /// has no launch environment, so it reads as nil and `arm` does nothing.
    func testTheUITestSeamIsOffWithoutItsEnvironmentVariable() {
        XCTAssertNil(ProcessInfo.processInfo.environment["JESSE_UITEST_THREAD_LANDING"],
                     "the unit-test process must not be running with the seam armed")
        XCTAssertNil(ThreadLandingUITestSeam.startTab)
    }
}
