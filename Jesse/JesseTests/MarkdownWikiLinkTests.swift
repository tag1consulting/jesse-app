import XCTest
import UIKit
import JesseVault
@testable import Jesse

/// A `[[WIKI LINK]]` IN A REPLY, rendered by the real iOS renderer.
///
/// `VaultWikiMarkdownTests` asserts the rewrite as a string; this asserts that the run
/// which comes out of `MarkdownInline.attributed` is an actual tappable link carrying a
/// URL the app's own `onOpenURL` will recognise — which is the half a pure test of the
/// rewrite cannot reach, because it is the parser's behaviour and not the rewrite's.
@MainActor
final class MarkdownWikiLinkTests: XCTestCase {

    private let base = UIFont.preferredFont(forTextStyle: .body)

    /// The whole feature in one assertion: the ALIAS is what the reader sees, and the
    /// run under it is a link whose target resolves to the note's vault path.
    func testAnAliasedWikiLinkRendersTheAliasAsATappableLink() throws {
        let rendered = MarkdownInline.attributed(
            "See [[todo-list/Strands/Strands-System|the strands note]] for where it stands.",
            font: base, color: .label)

        XCTAssertEqual(rendered.string,
                       "See the strands note for where it stands.",
                       "the alias is the text, and the brackets are gone")

        let url = try XCTUnwrap(linkURL(in: rendered), "expected a tappable run")
        let route = try XCTUnwrap(VaultWikiRoute.parse(url))
        XCTAssertEqual(route.target, "todo-list/Strands/Strands-System")
        XCTAssertEqual(
            VaultWikiLink.resolve(target: route.target,
                                  among: ["Strands/Strands-System.md", "Today.md"]),
            "Strands/Strands-System.md")
    }

    /// With no alias, the file name. A reply is a narrow column of text.
    func testAPlainWikiLinkRendersTheFileName() throws {
        let rendered = MarkdownInline.attributed("[[todo-list/Projects/Perseido/Perseido]]",
                                                 font: base, color: .label)
        XCTAssertEqual(rendered.string, "Perseido")
        XCTAssertEqual(try XCTUnwrap(linkURL(in: rendered)).absoluteString,
                       "jesse://wiki?target=todo-list/Projects/Perseido/Perseido")
    }

    /// An ordinary markdown link is untouched: the rewrite runs before the parse and
    /// must not have opinions about anything but double brackets.
    func testAnOrdinaryLinkIsUnaffected() throws {
        let rendered = MarkdownInline.attributed("see [the site](https://example.com) now",
                                                 font: base, color: .label)
        XCTAssertEqual(rendered.string, "see the site now")
        XCTAssertEqual(try XCTUnwrap(linkURL(in: rendered)).absoluteString, "https://example.com")
    }

    /// And a reply that merely contains brackets keeps every character of them.
    func testTextWithBracketsIsNotEaten() {
        let rendered = MarkdownInline.attributed("An unclosed [[bracket, and prose after it.",
                                                 font: base, color: .label)
        XCTAssertEqual(rendered.string, "An unclosed [[bracket, and prose after it.")
        XCTAssertNil(linkURL(in: rendered))
    }

    private func linkURL(in s: NSAttributedString) -> URL? {
        var found: URL?
        s.enumerateAttribute(.link, in: NSRange(location: 0, length: s.length)) { value, _, stop in
            if let url = value as? URL { found = url; stop.pointee = true }
            if let string = value as? String, let url = URL(string: string) {
                found = url
                stop.pointee = true
            }
        }
        return found
    }
}
