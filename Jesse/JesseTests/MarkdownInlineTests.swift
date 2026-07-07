import XCTest
import UIKit
@testable import Jesse

/// Covers `MarkdownInline` — resolving semantic inline-markdown intents (bold /
/// italic / `code` / links) to the CONCRETE `UIFont` traits and attributes a
/// `UITextView` needs to render selectable message text the same way a SwiftUI
/// `Text` would.
final class MarkdownInlineTests: XCTestCase {

    private let base = UIFont.preferredFont(forTextStyle: .body)

    // MARK: - resolvedFont

    func testBoldIntentAddsBoldTrait() {
        let font = MarkdownInline.resolvedFont(base: base, intent: .stronglyEmphasized)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(font.pointSize, base.pointSize)
    }

    func testItalicIntentAddsItalicTrait() {
        let font = MarkdownInline.resolvedFont(base: base, intent: .emphasized)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    func testCodeIntentIsMonospaced() {
        let font = MarkdownInline.resolvedFont(base: base, intent: .code)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        XCTAssertEqual(font.pointSize, base.pointSize)
    }

    func testBoldItalicCombinesBothTraits() {
        let intent: InlinePresentationIntent = [.stronglyEmphasized, .emphasized]
        let font = MarkdownInline.resolvedFont(base: base, intent: intent)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    func testNoIntentReturnsBaseUnchanged() {
        let font = MarkdownInline.resolvedFont(base: base, intent: [])
        XCTAssertEqual(font, base)
    }

    // MARK: - attributed

    func testBoldMarkdownProducesABoldRun() {
        let s = MarkdownInline.attributed("normal **bold** end", font: base, color: .label)
        XCTAssertTrue(s.string.contains("bold"))
        XCTAssertFalse(s.string.contains("*"), "markdown syntax should be consumed")
        XCTAssertTrue(hasRun(in: s) { ($0[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false },
                      "expected at least one bold run")
    }

    func testCodeMarkdownProducesAMonospacedRun() {
        let s = MarkdownInline.attributed("use `code` here", font: base, color: .label)
        XCTAssertTrue(hasRun(in: s) { ($0[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) ?? false },
                      "expected a monospaced run for inline code")
    }

    func testLinkMarkdownProducesALinkAttribute() {
        let s = MarkdownInline.attributed("see [the site](https://example.com) now", font: base, color: .label)
        XCTAssertTrue(hasRun(in: s) { ($0[.link] as? URL)?.absoluteString == "https://example.com" },
                      "expected a link run pointing at the URL")
    }

    func testPlainTextIsPreservedWithBaseAttributes() {
        let s = MarkdownInline.attributed("just words", font: base, color: .label)
        XCTAssertEqual(s.string, "just words")
        let attrs = s.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(attrs[.foregroundColor] as? UIColor, .label)
    }

    // MARK: - listItem

    func testListItemStartsWithMarkerAndHangs() {
        let s = MarkdownInline.listItem(marker: "•", text: "an item", font: base, color: .label)
        XCTAssertTrue(s.string.hasPrefix("•\t"))
        XCTAssertTrue(s.string.contains("an item"))
        let style = s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertNotNil(style)
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0, "list items should hang-indent wrapped lines")
    }

    func testNumberedListItemUsesTheNumberMarker() {
        let s = MarkdownInline.listItem(marker: "3.", text: "third", font: base, color: .label)
        XCTAssertTrue(s.string.hasPrefix("3.\t"))
    }

    // MARK: - Helpers

    /// True if any attribute run in `s` satisfies `predicate`.
    private func hasRun(in s: NSAttributedString,
                        where predicate: ([NSAttributedString.Key: Any]) -> Bool) -> Bool {
        var found = false
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, _, stop in
            if predicate(attrs) { found = true; stop.pointee = true }
        }
        return found
    }
}
