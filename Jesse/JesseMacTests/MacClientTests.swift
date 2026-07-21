import XCTest
@testable import Jesse_Mac

// Mac-app-specific unit coverage: the Markdown block parser, the pairing-link parser, and
// the notification snippet formatter. The SSE framing and host-sanitizing tests that used
// to live here moved into the JesseNetworking package (SSEParserTests, JesseConfigTests)
// when those duplicated implementations were unified into the shared client.

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
