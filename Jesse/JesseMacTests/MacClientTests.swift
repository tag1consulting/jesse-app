import XCTest
@testable import Jesse_Mac

// Unit coverage for the macOS client's pure logic: SSE framing, host sanitizing, URL
// building, the Markdown block parser, and the pairing-link parser. These are the parts
// with real branching that a wire/format change could silently break.

final class MacSSEParserTests: XCTestCase {
    func testResetThenDeltasThenDone() {
        let lines = [
            "event: reset", #"data: {"text":"Hel"}"#, "",
            "event: delta", #"data: {"text":"lo"}"#, "",
            "event: done", #"data: {"response":"Hello","session_id":"abc"}"#, "",
        ]
        XCTAssertEqual(MacSSEParser.frames(lines), [
            .reset("Hel"), .delta("lo"), .done(text: "Hello", sessionId: "abc"),
        ])
    }

    func testEventLineFlushesWhenBlankLineSwallowed() {
        // URLSession.AsyncBytes.lines swallows blank lines — a new `event:` must flush
        // the prior frame. No blank separators here.
        let lines = [
            "event: delta", #"data: {"text":"a"}"#,
            "event: delta", #"data: {"text":"b"}"#,
            "event: cancelled", #"data: {}"#,
        ]
        XCTAssertEqual(MacSSEParser.frames(lines), [.delta("a"), .delta("b"), .cancelled])
    }

    func testKeepAliveCommentIgnored() {
        let lines = [":", ": keep-alive", "event: delta", #"data: {"text":"x"}"#, ""]
        XCTAssertEqual(MacSSEParser.frames(lines), [.delta("x")])
    }

    func testActivityAndError() {
        XCTAssertEqual(
            MacSSEParser.frames(["event: activity", #"data: {"name":"Read"}"#, ""]),
            [.activity("Read")])
        XCTAssertEqual(
            MacSSEParser.frames(["event: error", #"data: {"error":"boom"}"#, ""]),
            [.failed("boom")])
    }

    func testMissingDataFieldsFallBackToDefaults() {
        // A done frame with no response yields empty text, not a crash.
        XCTAssertEqual(
            MacSSEParser.frames(["event: done", "data: {}", ""]),
            [.done(text: "", sessionId: nil)])
    }
}

final class MacBridgeConfigTests: XCTestCase {
    func testSanitizeFullURLLiftsPort() {
        let (host, port) = MacBridgeConfig.sanitize("http://Studio.tailnet.ts.net:9000/health")
        XCTAssertEqual(host, "studio.tailnet.ts.net")
        XCTAssertEqual(port, 9000)
    }

    func testSanitizeHostPort() {
        let (host, port) = MacBridgeConfig.sanitize("100.64.0.1:8765")
        XCTAssertEqual(host, "100.64.0.1")
        XCTAssertEqual(port, 8765)
    }

    func testSanitizeBareHostNoPort() {
        let (host, port) = MacBridgeConfig.sanitize("  box.ts.net  ")
        XCTAssertEqual(host, "box.ts.net")
        XCTAssertNil(port)
    }

    func testSanitizeStripsProtocolRelativeAndPath() {
        let (host, port) = MacBridgeConfig.sanitize("//box.ts.net/jesse/sessions")
        XCTAssertEqual(host, "box.ts.net")
        XCTAssertNil(port)
    }

    func testEndpointBuildsURL() {
        let cfg = MacBridgeConfig(host: "box.ts.net", port: 8765, token: "t")
        XCTAssertEqual(cfg.endpoint("/jesse/sessions")?.absoluteString,
                       "http://box.ts.net:8765/jesse/sessions")
    }

    func testEndpointNilForEmptyHost() {
        XCTAssertNil(MacBridgeConfig.empty.endpoint("/jesse"))
    }

    func testIsConfiguredRequiresHostAndToken() {
        XCTAssertFalse(MacBridgeConfig(host: "", port: 8765, token: "t").isConfigured)
        XCTAssertFalse(MacBridgeConfig(host: "h", port: 8765, token: "").isConfigured)
        XCTAssertTrue(MacBridgeConfig(host: "h", port: 8765, token: "t").isConfigured)
    }
}

final class MacMarkdownTests: XCTestCase {
    func testHeadingLevel() {
        XCTAssertEqual(MacMarkdownBlock.headingLevel("## Title"), 2)
        XCTAssertNil(MacMarkdownBlock.headingLevel("###nospace"))
        XCTAssertNil(MacMarkdownBlock.headingLevel("####### too many"))
        XCTAssertNil(MacMarkdownBlock.headingLevel("no hash"))
    }

    func testBulletAndOrdered() {
        XCTAssertEqual(MacMarkdownBlock.bulletContent("- item"), "item")
        XCTAssertEqual(MacMarkdownBlock.bulletContent("* item"), "item")
        XCTAssertNil(MacMarkdownBlock.bulletContent("-nospace"))
        XCTAssertEqual(MacMarkdownBlock.orderedContent("1. first"), "first")
        XCTAssertEqual(MacMarkdownBlock.orderedContent("42) x"), "x")
        XCTAssertNil(MacMarkdownBlock.orderedContent("1.nospace"))
        XCTAssertNil(MacMarkdownBlock.orderedContent("word. x"))
    }

    func testParseMixedBlocks() {
        let md = """
        # Heading

        A paragraph.

        - one
        - two

        ```
        code line
        ```
        """
        let blocks = MacMarkdownBlock.parse(md)
        guard case .heading(level: 1, _) = blocks[0] else { return XCTFail("expected heading") }
        guard case .paragraph = blocks[1] else { return XCTFail("expected paragraph") }
        guard case let .bullet(items) = blocks[2] else { return XCTFail("expected bullet") }
        XCTAssertEqual(items.count, 2)
        guard case let .code(src) = blocks[3] else { return XCTFail("expected code") }
        XCTAssertEqual(src, "code line")
    }

    func testOrderedRun() {
        let blocks = MacMarkdownBlock.parse("1. a\n2. b\n3. c")
        guard case let .ordered(items) = blocks[0] else { return XCTFail("expected ordered") }
        XCTAssertEqual(items.count, 3)
    }
}

final class MacPairLinkTests: XCTestCase {
    func testValidLink() {
        let parsed = MacPairLink.parse("jesse://pair?url=box.ts.net:8765&token=secret")
        XCTAssertEqual(parsed?.host, "box.ts.net")
        XCTAssertEqual(parsed?.port, 8765)
        XCTAssertEqual(parsed?.token, "secret")
    }

    func testRejectsWrongSchemeOrMissingToken() {
        XCTAssertNil(MacPairLink.parse("https://pair?url=box&token=t"))
        XCTAssertNil(MacPairLink.parse("jesse://pair?url=box"))
        XCTAssertNil(MacPairLink.parse("not a url"))
    }
}

final class MacNotifierSnippetTests: XCTestCase {
    func testCollapsesAndTruncates() {
        XCTAssertEqual(MacNotifier.snippet("line one\nline two"), "line one line two")
        let long = String(repeating: "a", count: 200)
        XCTAssertEqual(MacNotifier.snippet(long, limit: 10).count, 11)  // 10 chars + ellipsis
    }
}
