import XCTest
@testable import JesseCore

/// The unread-reply rule and the two marks that move it.
///
/// Everything here is value-in / value-out: two integers for the rule, two booleans for
/// the gate, and a `JesseThread` with no store behind it for the marks. That is the whole
/// point of keeping the definition in one pure function — the behaviour that decides
/// whether a dot appears is pinned without a view host, a simulator or a server.
@MainActor
final class UnreadReplyTests: XCTestCase {

    private func makeThread() -> JesseThread {
        let t = JesseThread(title: "t", mode: .ask)
        t.conversationId = "c1"
        return t
    }

    // MARK: - The rule

    /// A table over the interesting shapes of (lastReply, readThrough). STRICTLY greater:
    /// equality is read, which is what makes "read exactly through the last reply" stable
    /// and what makes the zero/zero upgrade case read rather than unread.
    func testTheUnreadRuleIsStrictlyGreater() {
        let cases: [(last: Int, read: Int, unread: Bool, why: String)] = [
            (0, 0, false, "a brand-new conversation, and every row written before these fields existed"),
            (1, 0, true, "a reply nobody has marked"),
            (5, 5, false, "read exactly through the last reply"),
            (6, 5, true, "a reply newer than the mark"),
            (5, 6, false, "a mark past the last reply (a marked-read race) stays read"),
            (0, 9, false, "a mark with no reply behind it is still read"),
        ]
        for c in cases {
            XCTAssertEqual(jesseHasUnreadReply(lastReplyMs: c.last, readThroughMs: c.read), c.unread,
                           "lastReply=\(c.last) readThrough=\(c.read): \(c.why)")
        }
    }

    /// The thread's computed property is the same rule, not a second copy of it.
    func testThreadUnreadMatchesTheRule() {
        let t = makeThread()
        XCTAssertFalse(t.hasUnreadReply, "a fresh thread is read")
        t.noteReply(atUnixMillis: 1_000)
        XCTAssertTrue(t.hasUnreadReply)
        XCTAssertTrue(t.markRead(nowMs: 50))
        XCTAssertFalse(t.hasUnreadReply)
    }

    // MARK: - The marks

    /// Marking read copies the REPLY time, never the device's now. That is what keeps both
    /// sides of the comparison on the bridge's clock.
    func testMarkReadCopiesTheReplyTimeNotNow() {
        let t = makeThread()
        t.noteReply(atUnixMillis: 1_000)
        XCTAssertTrue(t.markRead(nowMs: 9_999_999))
        XCTAssertEqual(t.readThroughMs, 1_000, "the reply time, not `now`")
        XCTAssertEqual(t.readUpdatedMs, 9_999_999, "`now` is the LWW clock, and only that")
    }

    /// A no-op mark writes NOTHING and says so, so opening an already-read conversation
    /// costs no save and no flag push. This runs on every appear and every foreground.
    func testMarkReadIsANoOpWhenAlreadyRead() {
        let t = makeThread()
        t.noteReply(atUnixMillis: 1_000)
        XCTAssertTrue(t.markRead(nowMs: 100))
        XCTAssertFalse(t.markRead(nowMs: 200), "already read — nothing to do")
        XCTAssertEqual(t.readThroughMs, 1_000)
        XCTAssertEqual(t.readUpdatedMs, 100, "the clock did NOT move on the no-op")
    }

    func testMarkUnreadIsANoOpWhenAlreadyUnread() {
        let t = makeThread()
        t.noteReply(atUnixMillis: 1_000)
        XCTAssertFalse(t.markUnread(nowMs: 200), "readThroughMs is already 0")
        XCTAssertEqual(t.readUpdatedMs, 0, "the clock did NOT move on the no-op")

        // And from a read state it does move, back to 0, with its clock stamped.
        XCTAssertTrue(t.markRead(nowMs: 300))
        XCTAssertTrue(t.markUnread(nowMs: 400))
        XCTAssertEqual(t.readThroughMs, 0)
        XCTAssertEqual(t.readUpdatedMs, 400)
        XCTAssertTrue(t.hasUnreadReply, "the dot is back")
    }

    /// `noteReply` never moves the stamp backwards. Hydration can carry history hours old,
    /// and a list pull can be built a moment before a reply the app already delivered
    /// locally; either one assigning rather than max-ing would make a read thread unread.
    func testNoteReplyNeverGoesBackwards() {
        let t = makeThread()
        XCTAssertTrue(t.noteReply(atUnixMillis: 5_000))
        XCTAssertFalse(t.noteReply(atUnixMillis: 4_000), "an older reply changes nothing")
        XCTAssertEqual(t.lastReplyMs, 5_000)
        XCTAssertFalse(t.noteReply(atUnixMillis: 5_000), "an equal stamp changes nothing")
        XCTAssertTrue(t.noteReply(atUnixMillis: 6_000))
        XCTAssertEqual(t.lastReplyMs, 6_000)
    }

    // MARK: - Clock skew

    /// THE REASON THE BRIDGE OWNS THE CLOCK. With the device an hour AHEAD of the bridge,
    /// a naive implementation would stamp `readThroughMs` at the device's now — an hour in
    /// the bridge's future — and the next real reply, stamped by the bridge, would land
    /// BEHIND that mark and never show a dot. Copying `lastReplyMs` instead makes the
    /// device's clock irrelevant to the comparison.
    func testADeviceAnHourAheadStillSeesTheNextReply() {
        let hour = 3_600_000
        let bridgeNow = 1_000_000
        let t = makeThread()

        // A reply on the bridge's clock, read on a device running an hour fast.
        t.noteReply(atUnixMillis: bridgeNow)
        XCTAssertTrue(t.markRead(nowMs: bridgeNow + hour))
        XCTAssertFalse(t.hasUnreadReply)

        // The next reply, one second later on the BRIDGE's clock, is unread.
        t.noteReply(atUnixMillis: bridgeNow + 1_000)
        XCTAssertTrue(t.hasUnreadReply, "a new reply is visible despite the device's skew")
    }

    /// The other direction: a device an hour BEHIND would, stamping its own now, leave the
    /// mark an hour in the past and make a reply it has just read pop straight back to
    /// unread. It does not, for the same reason.
    func testADeviceAnHourBehindKeepsAReadReplyRead() {
        let hour = 3_600_000
        let bridgeNow = 1_000_000
        let t = makeThread()

        t.noteReply(atUnixMillis: bridgeNow)
        XCTAssertTrue(t.markRead(nowMs: bridgeNow - hour))
        XCTAssertFalse(t.hasUnreadReply, "reading it made it read, whatever this clock says")

        // Re-marking is a no-op, so nothing can drift it back.
        XCTAssertFalse(t.markRead(nowMs: bridgeNow - hour + 1))
        XCTAssertFalse(t.hasUnreadReply)
    }

    // MARK: - The badge count

    /// The number three badges share (the Chats tab, the app icon, the Dock tile), and the
    /// same rule the bridge counts by.
    func testTheBadgeCountExcludesArchivedAndReadConversations() {
        let unread = makeThread()
        unread.noteReply(atUnixMillis: 5_000)

        let read = makeThread()
        read.noteReply(atUnixMillis: 5_000)
        read.markRead(nowMs: 1)

        // ARCHIVED and unread: it keeps its dot inside the Archived view, but archiving is
        // the gesture for "stop showing me this", so it must not put a number on the home
        // screen.
        let archived = makeThread()
        archived.noteReply(atUnixMillis: 5_000)
        archived.setArchived(true, now: Date(timeIntervalSince1970: 1))

        let neverReplied = makeThread()

        XCTAssertTrue(archived.hasUnreadReply, "still unread in its own right")
        XCTAssertEqual(jesseUnreadCount([unread, read, archived, neverReplied]), 1)
        XCTAssertEqual(jesseUnreadCount([]), 0)

        // Reading the last one empties the badge.
        unread.markRead(nowMs: 2)
        XCTAssertEqual(jesseUnreadCount([unread, read, archived, neverReplied]), 0)

        // And marking one unread by hand brings it back.
        read.markUnread(nowMs: 3)
        XCTAssertEqual(jesseUnreadCount([unread, read, archived, neverReplied]), 1)
    }

    // MARK: - The gate

    /// Only a transcript actually on screen, in a frontmost app, marks anything read.
    func testTheMarkReadGateNeedsBothHalves() {
        XCTAssertTrue(jesseShouldMarkRead(isVisible: true, isActive: true))
        XCTAssertFalse(jesseShouldMarkRead(isVisible: true, isActive: false),
                       "a reply landing while the phone is in a pocket stays unread")
        XCTAssertFalse(jesseShouldMarkRead(isVisible: false, isActive: true),
                       "a conversation open behind another screen is not being read")
        XCTAssertFalse(jesseShouldMarkRead(isVisible: false, isActive: false))
    }
}
