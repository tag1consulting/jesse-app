import XCTest
@testable import Jesse
import JesseCore
import JesseConversations

/// The DETAIL surface's own title, pinned where the defect lived.
///
/// The bug this file exists for: the thread list drew each row through the shared
/// `displayTitle(for:)` (AI title first), while `ThreadDetailView`'s
/// `.navigationTitle` read `thread.title` directly with an inline empty check. So
/// a conversation was "Dentist appointment" in the list and "some long first
/// message that seeds a derived title" the instant you opened it — the useful name
/// disappearing exactly when the screen had room for it.
///
/// These assertions go through the real `ThreadDetailView` value (its
/// `navigationTitleText`, which is what the modifier is given) rather than calling
/// the helper again: re-testing `displayTitle` in isolation is what ThreadTitleTests
/// already does, and it is precisely the test that would NOT have caught this.
@MainActor
final class ThreadDetailTitleTests: XCTestCase {

    /// A thread as it exists after one send plus a title refresh: a derived `title`
    /// holding the whole first message, and a short good `aiTitle`.
    private func namedThread(title: String, aiTitle: String?) -> JesseThread {
        let t = JesseThread(mode: .ask)
        t.title = title
        t.aiTitle = aiTitle
        t.turns = [Turn(role: .user, text: title,
                        createdAt: Date(timeIntervalSince1970: 0))]
        return t
    }

    private func detailTitle(_ thread: JesseThread) -> String {
        ThreadDetailView(thread: thread).navigationTitleText
    }

    // MARK: - The regression

    func testDetailShowsAITitleNotTheDerivedFirstMessage() {
        let thread = namedThread(title: "some long first message that seeds a derived title",
                                 aiTitle: "Dentist appointment")
        XCTAssertEqual(detailTitle(thread), "Dentist appointment",
                       "the open conversation must show the AI title")
        XCTAssertNotEqual(detailTitle(thread), thread.title,
                          "the derived first message must not be what the nav bar shows")
    }

    func testDetailAndListRowNameTheSameThreadTheSameWay() {
        // The whole point: one thread, one name. The list row draws
        // `displayTitle(for:)`; the detail must resolve to the identical string.
        let thread = namedThread(title: "what should I make for dinner tonight",
                                 aiTitle: "Dinner ideas")
        XCTAssertEqual(detailTitle(thread), displayTitle(for: thread))
    }

    // MARK: - The rest of the shared chain, as the detail surface sees it

    func testDetailFallsBackToTheDerivedTitleWithoutAnAITitle() {
        let thread = namedThread(title: "hi", aiTitle: nil)
        XCTAssertEqual(detailTitle(thread), "hi")
    }

    func testDetailIgnoresAWhitespaceOnlyAITitle() {
        // The inline check the modifier used to carry was `isEmpty`, which a title of
        // three spaces passes; the shared resolution trims first.
        let thread = namedThread(title: "hi", aiTitle: "   ")
        XCTAssertEqual(detailTitle(thread), "hi")
    }

    func testDetailNamesAThreadWithNothingToNameItBy() {
        let thread = namedThread(title: "", aiTitle: nil)
        thread.turns = []
        XCTAssertEqual(detailTitle(thread), "New conversation")
    }

    // MARK: - The other surface that read the raw title

    func testLiveActivityAttributesCarryTheAITitle() {
        // The Lock Screen activity built its own inline fallback the same way the nav
        // bar did, so a running turn was announced under the first message too.
        let thread = namedThread(title: "some long first message that seeds a derived title",
                                 aiTitle: "Dentist appointment")
        let attributes = RunCoordinator().liveActivityAttributes(for: thread)
        XCTAssertEqual(attributes.threadTitle, "Dentist appointment")
        XCTAssertEqual(attributes.threadID, thread.id)
    }
}
