import Foundation
import os
import XCTest

/// THE MEASUREMENT behind the unread-badge render fix: how many SwiftUI body evaluations
/// one conversation-touching save costs, on a store with 300 conversations, for the four
/// moments that produce them.
///
/// It is a UI test rather than a unit test because the thing being measured only exists in
/// a running view tree: a `@Query`'s refetch-and-reevaluate on save is SwiftUI's behavior,
/// not the store's, and no amount of driving the model layer reproduces it. The app logs
/// one `notice` per body evaluation (see `RenderProbe`, armed by `JESSE_RENDER_PROBE=1`),
/// this test logs a `mark` line around each action, and `scripts/render-probe.sh` reads the
/// two back out of the simulator's log and counts the lines between marks.
///
/// NOTHING HERE ASSERTS A NUMBER. The counts belong in a PR description, not in a test that
/// has to pass on a busy CI simulator — a body evaluation is a legitimate consequence of a
/// great many things, and pinning a count would fail on an unrelated view change. What the
/// test asserts is that the run it is measuring actually happened: the conversations
/// arrived, the row opened, the reply landed. The regression guards for the fix itself are
/// count assertions in `UnreadCounterTests` (JesseCoreTests), which need no simulator.
final class UnreadBadgeRenderUITests: XCTestCase {

    /// How many conversations the store holds for the measurement. The plan's floor is 300
    /// ("300 or more"); a real device has had more.
    private static let conversationCount = 300

    private var stub: ConversationsStub!
    private let log = Logger(subsystem: "com.tag1.jesse", category: "render")

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        stub = try ConversationsStub(count: Self.conversationCount)
    }

    override func tearDownWithError() throws {
        stub?.stop()
        stub = nil
        try super.tearDownWithError()
    }

    /// The four windows, in one run so they share one store and one process:
    ///
    ///  1. `launch` — a cold launch that adopts 300 conversations (the biggest save burst
    ///     the app ever does).
    ///  2. `foreground` — home, then activate, with the conversation list UNCHANGED. The
    ///     everyday case: a pull that decides nothing has changed and saves nothing.
    ///  3. `open-unread` — tapping the newest conversation, which holds an unread reply, so
    ///     opening it marks it read and saves.
    ///  4. `reply-lands` — the stub now reports a newer reply on another conversation, and
    ///     a foreground pull applies it: one thread mutated, one save.
    func testBodyEvaluationsForTheFourMomentsThatTouchAThread() throws {
        let app = XCUIApplication()
        app.launchEnvironment["JESSE_UITEST_BRIDGE"] = "127.0.0.1,\(stub.port),stub-token"
        app.launchEnvironment["JESSE_RENDER_PROBE"] = "1"

        mark("launch-begin")
        app.launch()

        let chats = app.tabBars.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 60), "the Chats tab")

        // The adoption burst is asynchronous: wait for the newest conversation's row rather
        // than for a fixed time, so the launch window closes when the store is actually
        // populated.
        let newest = app.staticTexts[ConversationsStub.newestTitle]
        XCTAssertTrue(newest.waitForExistence(timeout: 120),
                      "300 adopted conversations, newest first: \(stub.requestSummary)")
        settle()
        mark("launch-end")
        // The badge itself, kept as an image: UIKit exposes a tab's badge through neither
        // `label` nor `value`, so "the Chats tab reads 1" is only assertable by eye. One
        // conversation of the three hundred holds an unseen reply (the archived unread one
        // is excluded), so the tab carries a 1 here, nothing after it is read, and a 1
        // again once a reply lands.
        attach(app, "1-after-launch-badge-should-read-1")

        // ── 2. Foreground, nothing changed ────────────────────────────────────────────
        mark("foreground-begin")
        XCUIDevice.shared.press(.home)
        settle()
        app.activate()
        XCTAssertTrue(newest.waitForExistence(timeout: 60), "back on the list")
        settle()
        mark("foreground-end")

        // ── 3. Open the unread conversation ───────────────────────────────────────────
        mark("open-unread-begin")
        newest.tap()
        // The transcript is empty (the stub serves no turns), so the composer's send button
        // is what says the detail view is up.
        let composer = app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 60), "the conversation opened")
        settle()
        mark("open-unread-end")

        // ── 4. A reply lands on another conversation ──────────────────────────────────
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(newest.waitForExistence(timeout: 60), "back on the list")
        settle()
        attach(app, "2-after-reading-badge-should-be-gone")

        stub.landAReply()
        mark("reply-lands-begin")
        XCUIDevice.shared.press(.home)
        settle()
        app.activate()
        XCTAssertTrue(newest.waitForExistence(timeout: 60), "back on the list")
        settle()
        mark("reply-lands-end")
        attach(app, "3-after-a-reply-landed-badge-should-read-1")

        XCTAssertTrue(stub.servedConversationsAtLeast(2),
                      "the app pulled the list more than once: \(stub.requestSummary)")
    }

    // MARK: - Driving

    /// Log a window boundary into the same subsystem the app's probe uses, so the log the
    /// script reads back is one interleaved timeline.
    private func mark(_ label: String) {
        log.notice("mark \(label, privacy: .public)")
    }

    /// Keep a screenshot in the result bundle. The badge is the one thing this test cannot
    /// assert (see the call sites), so it is kept as evidence instead.
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Let the run loop (and the app's animations, fetches and autosaves) finish before the
    /// next mark. Deliberately generous: a window that closes early undercounts, and this
    /// test is measuring, not racing.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(3))
    }
}

/// A loopback `GET /jesse/conversations` serving a configurable list, in the test runner.
///
/// BSD sockets rather than `NWListener`, for the reason `StubBridge` states: a
/// Network.framework listener on iOS goes through the local-network privacy gate, which in
/// a UI-test runner has nobody to grant it.
final class ConversationsStub: @unchecked Sendable {

    let port: UInt16

    /// The newest conversation's first message, which becomes its row title. The row the
    /// test taps, and the one carrying an unread reply.
    static let newestTitle = "Newest conversation"

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private var conversationServes = 0
    private var paths: [String] = []
    private var body: String

    /// The clock the whole fixture is dated from, read ONCE. Re-reading it per payload
    /// would move every conversation's `last_reply_ms` forward on the second serve, which
    /// reads to the app as a reply landing on all three hundred of them — the second pull
    /// must change exactly one conversation and nothing else.
    private let baseSeconds = UInt64(Date().timeIntervalSince1970)

    /// `count` conversations, newest first, all of them replied-to and READ except the
    /// newest, which holds an unread reply (the badge is 1 and the row the test opens has
    /// a dot). One archived-and-unread conversation is in there too, because the count's
    /// rule excludes it and a measurement of the wrong number is worse than none.
    init(count: Int) throws {
        body = Self.payload(count: count, extraReplyIndex: nil, nowSeconds: baseSeconds)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.err("socket() failed: \(errno)") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw Self.err("bind() failed: \(errno)") }
        guard listen(fd, 16) == 0 else { close(fd); throw Self.err("listen() failed: \(errno)") }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { close(fd); throw Self.err("getsockname() failed: \(errno)") }

        port = UInt16(bigEndian: actual.sin_port)
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    /// Report a newer reply on conversation 7 — one thread mutated by the next pull, which
    /// is exactly the shape of a reply that landed while this device was away.
    func landAReply() {
        lock.lock()
        body = Self.payload(count: Self.count(of: body), extraReplyIndex: 7,
                            nowSeconds: baseSeconds)
        lock.unlock()
    }

    func servedConversationsAtLeast(_ n: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return conversationServes >= n
    }

    var requestSummary: String {
        lock.lock(); defer { lock.unlock() }
        return "\(paths.count) requests, \(conversationServes) of them for the list"
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    // MARK: - The payload

    private static func count(of body: String) -> Int {
        body.components(separatedBy: "\"conversation_id\"").count - 1
    }

    /// Conversation `i` is `…-0000-4000-8000-<i>`, replied to `i` minutes (for the first
    /// eight) or `i` days (for the rest) ago and read through the same millisecond, so
    /// every one of them is READ. Index 0 is the newest, carries `Newest conversation` as
    /// its first message and title, and is the one left UNREAD. Index 1 is archived AND
    /// unread, so the count has something to exclude. `extraReplyIndex`, when given, gets a
    /// reply an hour NEWER than its read mark — the shape of a reply that landed while this
    /// device was away.
    ///
    /// THE FIRST EIGHT ARE TODAY'S. The shared list layout files anything older than the
    /// last few days into a collapsed month folder, so a list of three hundred
    /// two-year-old conversations renders as a handful of shut folders and the test can
    /// tap nothing. Eight loose rows on top, and the remaining 292 in folders, is both
    /// tappable and what a real list looks like.
    private static func payload(count: Int, extraReplyIndex: Int?,
                                nowSeconds: UInt64) -> String {
        var rows: [String] = []
        for i in 0..<count {
            let secondsBack = UInt64(i < 8 ? i * 60 : i * 86_400)
            let modified = nowSeconds - secondsBack
            // The read mark is where this conversation stood on the FIRST payload; the
            // reply moves an hour past it for `extraReplyIndex`, and nowhere else. Moving
            // the reply forward rather than the mark backwards is what makes it a reply
            // landing: `noteReply` takes the max, so only a newer reply changes anything.
            let readThrough: UInt64 = (i == 0 || i == 1) ? 0 : modified * 1000
            let replied = modified * 1000 + (i == extraReplyIndex ? 3_600_000 : 0)
            let title = i == 0 ? newestTitle : "Conversation \(i)"
            rows.append("""
            {"conversation_id":"\(cid(i))","session_id":"sess-\(i)","session_ids":["sess-\(i)"],
             "last_modified":\(modified),
             "first_message":"\(title)","title":"\(title)",
             "favorite":false,"favorite_updated_ms":0,
             "archived":\(i == 1 ? "true" : "false"),"archived_updated_ms":\(i == 1 ? 1 : 0),
             "last_reply_ms":\(replied),"read_through_ms":\(readThrough),
             "read_updated_ms":\(readThrough),
             "registered_ms":\(modified * 1000)}
            """)
        }
        return "{\"conversations\":[\(rows.joined(separator: ","))],\"deleted\":[]}"
    }

    private static func cid(_ i: Int) -> String {
        String(format: "%08x-0000-4000-8000-555555555555", i)
    }

    // MARK: - The socket

    private static func err(_ message: String) -> NSError {
        NSError(domain: "ConversationsStub", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            lock.lock(); let done = stopped; lock.unlock()
            if done { if conn >= 0 { close(conn) }; return }
            guard conn >= 0 else { return }
            serve(conn)
            close(conn)
        }
    }

    private func serve(_ conn: Int32) {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let n = recv(conn, &buf, buf.count, 0)
        let request = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""

        let responseBody: String
        lock.lock()
        paths.append(request.split(separator: "\r\n").first.map(String.init) ?? "?")
        if request.contains("/jesse/conversations") {
            conversationServes += 1
            responseBody = body
        } else if request.contains("/jesse/models") {
            responseBody = #"{"active":"opus","models":[]}"#
        } else {
            responseBody = #"{"ok":true,"version":"0.144.1"}"#
        }
        lock.unlock()

        let bytes = Array(responseBody.utf8)
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(bytes.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Array(head.utf8)
        out.append(contentsOf: bytes)
        var sent = 0
        while sent < out.count {
            let wrote = out.withUnsafeBytes {
                send(conn, $0.baseAddress!.advanced(by: sent), out.count - sent, 0)
            }
            if wrote <= 0 { return }
            sent += wrote
        }
    }
}
