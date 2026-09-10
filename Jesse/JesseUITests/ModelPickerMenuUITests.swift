import Foundation
import XCTest

/// The `UserDefaults` key `LastUsedModelStore` reads, duplicated here because a UI-test
/// target links no app code. `ModelPickerUITestContractTests` (JesseTests) pins it against
/// the real one, so a rename cannot quietly turn these tests into no-ops.
enum LastUsedModelStoreKey {
    static let defaults = "jesse.lastUsedModelID"
}

/// The model picker's MENU, as UIKit actually presents it.
///
/// The sibling of `ChatsToolbarUITests`, and here for the same reason: what is asserted is
/// invisible to a unit test. `ModelMenuTests` (JesseKit) checks `ModelMenuLayout` — the
/// struct that DECIDES what a row says — and it was green through two defects that only a
/// presented menu can show:
///
///   1. The resolved row's harness/version second line never reached the screen on iOS.
///      `Label { Text(title); Text(subtitle) } icon: { … }` puts the second `Text` inside
///      the label's TITLE builder, where UIKit's menu-item conversion drops it. Only the
///      flat `Text` / `Text` / `Image` form, as siblings of the Button's own label, is
///      mapped to `UIAction.subtitle`.
///   2. `Section("Effort")`'s header did not render, because an inline `Picker` in a menu
///      supplies its own section and replaces the enclosing one. On screen the effort
///      values sat under a bare divider with nothing saying what they were.
///
/// In both cases `ModelMenuLayout` produced exactly the right value and the view threw it
/// away, which is why a layout test could not fail. These assert the rendered menu.
///
/// **No bridge, no network, no real pairing.** `StubBridge` below is a loopback HTTP
/// listener in the TEST RUNNER serving one fixed `GET /jesse/models`. The simulator shares
/// the host's network stack, so the app reaches it at `127.0.0.1`. The payload is
/// deliberate: `glm` declares BOTH a harness and a version, so its detail line is exactly
/// `claude-code · 5.3`, and it is a family of one while `opus`/`fable` share `Claude`.
final class ModelPickerMenuUITests: XCTestCase {

    private var stub: StubBridge!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        stub = try StubBridge()
    }

    override func tearDownWithError() throws {
        stub?.stop()
        stub = nil
        try super.tearDownWithError()
    }

    // MARK: - The two regressions

    /// The resolved row renders a SECOND LINE — its harness and version.
    ///
    /// Asserted as geometry, not as text, and that is a deliberate limitation worth
    /// stating: **UIKit does not expose a menu item's subtitle to accessibility at all.**
    /// `UIAction.subtitle` reaches the screen but appears in neither the element's `label`
    /// nor its `value`, so no string query can see it — the first version of this test
    /// looked for "claude-code · 5.3" and failed against a build where the screenshot
    /// plainly showed it.
    ///
    /// What IS observable is that the row got taller: every model row holds one line of
    /// similar length, and only the resolved one carries a subtitle, so the resolved row
    /// being strictly taller than every other model row is exactly the second line. That
    /// is the property the defect broke — the old `Label { Text; Text } icon:` form
    /// rendered the resolved row at the same single-line height as its neighbours.
    func testTheResolvedRowRendersItsHarnessAndVersionAsASecondLine() throws {
        let app = try openTheModelMenu()
        attachScreenshot(app, "menu-with-glm-resolved")

        let rows = modelRowHeights(app)
        guard let resolved = rows["GLM 5.3"] else {
            return XCTFail("no GLM 5.3 row in the menu; menu held \(menuText(app))")
        }
        let others = rows.filter { $0.key != "GLM 5.3" }
        XCTAssertFalse(others.isEmpty, "there are other model rows to compare against")

        for (label, height) in others {
            XCTAssertGreaterThan(
                resolved, height,
                """
                the resolved row carries a second line (its harness and version) and so \
                stands taller than "\(label)". Resolved height \(resolved), \(label) \
                height \(height). Equal heights mean the subtitle was dropped: a second \
                `Text` nested inside `Label`'s title builder does not become a menu \
                item's subtitle — it must be a sibling of the Button's own label.
                """
            )
        }
    }

    func testTheEffortSectionRendersItsHeader() throws {
        let app = try openTheModelMenu()

        // The values are there either way — this is about the header that says what they are.
        XCTAssertTrue(menuContains(app, "low"), "the effort values render")
        XCTAssertTrue(menuContains(app, "max"), "the effort values render")

        XCTAssertTrue(
            menuContains(app, "Effort"),
            """
            the effort section is labelled, so its values are not bare rows.
            The menu held: \(menuText(app).joined(separator: " | "))
            """
        )
    }

    /// The header the menu already got right, pinned so a fix to the Effort header cannot
    /// quietly cost the family header. `Claude` is a family of two; `GLM` a family of one
    /// and so correctly headerless.
    func testTheFamilyHeaderStillRendersAndAFamilyOfOneStillHasNone() throws {
        let app = try openTheModelMenu()
        XCTAssertTrue(menuContains(app, "Claude"), "the two-model family keeps its header")
        XCTAssertFalse(
            menuText(app).contains("GLM"),
            "a family of one renders no header — only the row label 'GLM 5.3'"
        )
    }

    // MARK: - Driving the app

    /// Point the app at the stub, open a new conversation on `glm` (which declares both a
    /// harness/version and a three-value effort scale), and leave the model menu open.
    private func openTheModelMenu() throws -> XCUIApplication {
        let app = XCUIApplication()
        // Point the app at the stub through the DEBUG-only config seam rather than
        // through Settings. An unsigned build (CODE_SIGNING_ALLOWED=NO, which is what
        // both ios-ci.yml and local-ci-macos.sh use) cannot write the Keychain, so
        // pairing through the UI fails with "your token couldn't be saved" and the
        // picker never leaves its unloaded state. Everything downstream of the config
        // — the client, the request, the decode, the retry policy, the layout, the
        // menu — is the real thing.
        app.launchEnvironment["JESSE_UITEST_BRIDGE"] = "127.0.0.1,\(stub.port),stub-token"
        // Resolve to `glm` without tapping anything. `-key value` launch arguments land
        // in NSArgumentDomain, which `UserDefaults.standard` reads first, so this sets
        // the per-device default model the way the app itself would. Tapping the row
        // instead made the test order-dependent: once a run had picked GLM the device
        // default persisted, and on the next run "GLM 5.3" matched both the menu row
        // and the toolbar button.
        app.launchArguments += ["-\(LastUsedModelStoreKey.defaults)", "glm"]
        app.launch()

        let chats = app.tabBars.buttons["Chats"]
        XCTAssertTrue(chats.waitForExistence(timeout: 30), "Chats tab")
        chats.tap()

        let newConversation = app.navigationBars.buttons["New conversation"]
        XCTAssertTrue(newConversation.waitForExistence(timeout: 30), "New conversation")
        newConversation.tap()

        // GLM is now the resolved model, so the detail line and the three-value effort
        // control are both properties of what this menu shows.
        openMenu(app)
        XCTAssertTrue(menuContains(app, "GLM 5.3"), "the stub's GLM row is in the menu")
        return app
    }

    /// Tap the composer's model button: the one navigation-bar button in the CONVERSATION's
    /// bar that is neither Back nor one of the fixed affordances. Its label is the model
    /// name, which is what is under test, so it cannot be matched by label.
    private func openMenu(_ app: XCUIApplication) {
        let fixed = ["Favorite", "Unfavorite", "Share conversation", "Settings"]
        var picker: XCUIElement?
        for bar in app.navigationBars.allElementsBoundByIndex.reversed() {
            let buttons = bar.buttons.allElementsBoundByIndex
            guard buttons.contains(where: { $0.identifier == "BackButton" }) else { continue }
            picker = buttons.first {
                !$0.label.isEmpty && !fixed.contains($0.label) && $0.identifier != "BackButton"
            }
            if picker != nil { break }
        }
        guard let picker else {
            attachScreenshot(app, "no-picker-button")
            add({ let a = XCTAttachment(string: app.debugDescription)
                  a.name = "no-picker-tree"; a.lifetime = .keepAlways; return a }())
            return XCTFail("""
                no model picker button in the conversation bar. \
                Stub saw \(stub.requestPaths.joined(separator: ", ")) — \
                if /jesse/models is absent the app never reached the stub, so the menu is \
                the non-expandable "list has not loaded" label rather than a Menu.
                """)
        }
        picker.tap()
        // The menu is a presented popover; give UIKit a beat to put it up.
        // Fable is never the resolved model in these tests, so its row appears once, in
        // the menu — a stable signal that the popover is up.
        XCTAssertTrue(app.buttons["Claude Fable 5.1"].waitForExistence(timeout: 15),
                      "the model menu is presented")
    }

    // MARK: - Reading the presented menu

    /// Every non-empty label and value on screen. A menu item's subtitle surfaces through
    /// one of the two depending on how UIKit renders it, so both are collected and the
    /// assertions look for a substring rather than pinning the exact composition.
    private func menuText(_ app: XCUIApplication) -> [String] {
        var out: [String] = []
        for el in app.descendants(matching: .any).allElementsBoundByIndex {
            if !el.label.isEmpty { out.append(el.label) }
            if let v = el.value as? String, !v.isEmpty { out.append(v) }
        }
        return out
    }

    /// Height of each model row currently on screen, keyed by label. Scoped to the three
    /// the stub serves so the composer's own controls cannot be mistaken for menu rows.
    private func modelRowHeights(_ app: XCUIApplication) -> [String: CGFloat] {
        let wanted = Set(["Claude Opus", "Claude Fable 5.1", "GLM 5.3"])
        var out: [String: CGFloat] = [:]
        for el in app.buttons.allElementsBoundByIndex where wanted.contains(el.label) {
            let f = el.frame
            // The toolbar button carries the resolved model's name too. Menu rows are the
            // wide ones; the toolbar button is a compact glyph-width control.
            guard f.width > 120 else { continue }
            out[el.label] = max(out[el.label] ?? 0, f.height)
        }
        return out
    }

    private func menuContains(_ app: XCUIApplication, _ needle: String) -> Bool {
        menuText(app).contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}

// MARK: - The stub bridge

/// A loopback HTTP listener serving the one endpoint the picker reads, plus a 200 for
/// anything else so the app's pairing and its other background polls do not error-spam.
///
/// Deliberately tiny and dependency-free: one loopback socket on an OS-assigned port, one fixed
/// JSON body. It runs inside the UI-test runner, so there is nothing to start or clean up
/// outside the test and nothing that can leak between runs.
/// `@unchecked Sendable` because the only mutable state is `paths` and `fd`, and every
/// read and write of them goes through `lock`.
final class StubBridge: @unchecked Sendable {

    let port: UInt16

    private let lock = NSLock()
    private var paths: [String] = []
    private var listenFD: Int32 = -1
    private var stopped = false

    /// Every request line the stub has served, so a test that finds no menu can say
    /// whether the app ever reached it.
    var requestPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    /// Three models, chosen so the picker has something to say:
    ///   * `opus` and `fable` share the family `Claude`, so the family header renders and
    ///     there is a two-member family to switch within.
    ///   * `glm` is a family of ONE (so correctly headerless), declares harness
    ///     `claude-code` AND version `5.3` — making its detail line exactly
    ///     `claude-code · 5.3` — and carries a three-value scale so the effort section is
    ///     unmistakable.
    private static let modelsJSON = """
    {
      "active": "opus",
      "models": [
        {"id":"opus","label":"Claude Opus","kind":"ambient","available":true,
         "configured":true,"healthy":true,"writes_allowed":true,"level":"write",
         "streams_text":true,"family":"Claude","harness":"claude-code",
         "effort":{"kind":"scale","values":["high","max"],"default":"high"}},
        {"id":"fable","label":"Claude Fable 5.1","kind":"subscription","available":true,
         "configured":true,"healthy":true,"writes_allowed":true,"level":"write",
         "streams_text":true,"family":"Claude","harness":"claude-code","version":"5.1",
         "effort":{"kind":"scale","values":["high","max"],"default":"high"}},
        {"id":"glm","label":"GLM 5.3","kind":"hosted","available":true,
         "configured":true,"healthy":true,"writes_allowed":true,"level":"write",
         "streams_text":true,"family":"GLM","harness":"claude-code","version":"5.3",
         "effort":{"kind":"scale","values":["low","high","max"],"default":"high"}}
      ]
    }
    """

    /// BSD sockets rather than `NWListener` on purpose: a Network.framework listener on
    /// iOS goes through the local-network privacy gate, which in a UI-test runner has no
    /// one to grant it and simply never reaches `.ready`. A plain loopback `bind`/`listen`
    /// does not, and the simulator shares the host's stack so the app under test reaches
    /// it at 127.0.0.1.
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubBridge.err("socket() failed: \(errno)") }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                   // let the OS pick
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw StubBridge.err("bind() failed: \(errno)") }
        guard listen(fd, 16) == 0 else { close(fd); throw StubBridge.err("listen() failed: \(errno)") }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { close(fd); throw StubBridge.err("getsockname() failed: \(errno)") }

        port = UInt16(bigEndian: actual.sin_port)
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
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

        lock.lock()
        paths.append(request.split(separator: "\r\n").first.map(String.init) ?? "?")
        lock.unlock()

        let body = request.contains("/jesse/models")
            ? Self.modelsJSON
            : #"{"ok":true,"version":"0.132.0"}"#
        let bytes = Array(body.utf8)
        let head = Array("""
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(bytes.count)\r
        Connection: close\r
        \r

        """.utf8)
        var out = head + bytes
        var sent = 0
        while sent < out.count {
            let k = out.withUnsafeBytes { send(conn, $0.baseAddress! + sent, out.count - sent, 0) }
            if k <= 0 { break }
            sent += k
        }
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "StubBridge", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
