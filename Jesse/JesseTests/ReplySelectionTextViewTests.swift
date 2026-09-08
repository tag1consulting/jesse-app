import XCTest
import SwiftUI
import UIKit
@testable import Jesse

/// Selection and copy at the REAL text view, driven through the real SwiftUI view.
///
/// The document tests next door prove `plainText(for:)` turns a range into good
/// pasteboard text; they say nothing about whether such a range can exist. That is
/// the whole bug: a range spanning three paragraphs was unrepresentable, because
/// no single text view held three paragraphs. So these tests render
/// `MarkdownText` through a `UIHostingController`, find the text views UIKit
/// actually created, and drive `selectedRange` / `selectAll(_:)` / `copy(_:)` on
/// them — the same properties and actions the native handles and the system edit
/// menu drive.
///
/// WHY THESE FAIL AGAINST THE ORIGINAL: `testACompletedReplyIsOneTextView` fails
/// outright (the old renderer produced one text view per block — fourteen for this
/// fixture). `testSelectionSpansParagraphs` fails because no text view in the
/// hierarchy contains both the first paragraph and the third, so the range cannot
/// be formed at all. `testSelectAllCoversTheWholeReply` fails because `selectAll:`
/// on any one of those views reaches only its own block.
@MainActor
final class ReplySelectionTextViewTests: XCTestCase {

    /// Keeps the window alive for the duration of a test — a hosting controller's
    /// view laid out with no window does not reliably build its UIKit children.
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// Render the real reply view at a phone-ish width and return every
    /// `UITextView` UIKit made for it.
    private func renderReply(_ raw: String = MarkdownReplyFixture.raw,
                             typeSize: DynamicTypeSize = .large) -> [UITextView] {
        let host = UIHostingController(rootView:
            MarkdownText(raw)
                .frame(width: 340, alignment: .leading)
                .environment(\.dynamicTypeSize, typeSize))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 340, height: 4000))
        window.rootViewController = host
        window.isHidden = false
        self.window = window

        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return Self.textViews(in: host.view)
    }

    private static func textViews(in view: UIView) -> [UITextView] {
        var found: [UITextView] = []
        if let text = view as? UITextView { found.append(text) }
        for subview in view.subviews { found.append(contentsOf: textViews(in: subview)) }
        return found
    }

    private func copyText(from view: UITextView) -> String? {
        UIPasteboard.general.string = ""
        view.copy(nil)
        return UIPasteboard.general.string
    }

    // MARK: - The structural fix

    /// ONE text view for the whole reply. This is the fix stated as a property: a
    /// selection cannot cross two text views, so "select across paragraphs" and
    /// "one text view per reply" are the same requirement.
    func testACompletedReplyIsOneTextView() {
        let views = renderReply()
        XCTAssertEqual(views.count, 1,
                       "a completed reply must be a single selection surface, not \(views.count) islands")
    }

    /// The streaming partial is deliberately NOT this path — it stays on the
    /// lightweight SwiftUI renderer and builds no text view at all.
    func testTheStreamingPartialDoesNotBuildTheDocumentView() {
        let host = UIHostingController(rootView:
            MarkdownText(blocks: parseMarkdownBlocks(MarkdownReplyFixture.raw), selectable: false)
                .frame(width: 340, alignment: .leading))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 340, height: 4000))
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        host.view.layoutIfNeeded()

        XCTAssertTrue(Self.textViews(in: host.view).allSatisfy { !($0 is MarkdownDocumentTextView) },
                      "streaming must not pay for the document text view")
    }

    // MARK: - Selection

    /// Select from inside the first paragraph to inside the third and copy. The
    /// span crosses a paragraph boundary, a three-item bullet list, and another
    /// paragraph boundary.
    func testSelectionSpansParagraphs() throws {
        let view = try XCTUnwrap(renderReply().first)
        let ns = view.text as NSString

        let start = ns.range(of: MarkdownReplyFixture.crossParagraphStart)
        let anchor = ns.range(of: MarkdownReplyFixture.crossParagraphEndAnchor)
        XCTAssertNotEqual(start.location, NSNotFound,
                          "the first paragraph is not in this text view")
        XCTAssertNotEqual(anchor.location, NSNotFound,
                          "the third paragraph is not in the SAME text view — selection islands")
        // Both failures above are already recorded; bail out rather than build a
        // range out of NSNotFound.
        guard start.location != NSNotFound, anchor.location != NSNotFound else { return }

        let end = anchor.location + (MarkdownReplyFixture.crossParagraphEndPrefix as NSString).length
        view.selectedRange = NSRange(location: start.location, length: end - start.location)

        XCTAssertEqual(view.selectedRange.length, end - start.location,
                       "the text view refused a range spanning three paragraphs")
        XCTAssertEqual(copyText(from: view),
                       MarkdownReplyFixture.expectedCrossParagraphCopy)
    }

    /// Precise word selection still works — the thing that was already right and
    /// must not regress. This is the range a double-tap produces.
    func testSingleWordSelection() throws {
        let view = try XCTUnwrap(renderReply().first)
        let ns = view.text as NSString
        let word = ns.range(of: MarkdownReplyFixture.singleWord)
        XCTAssertNotEqual(word.location, NSNotFound)

        view.selectedRange = word
        XCTAssertEqual(copyText(from: view), MarkdownReplyFixture.singleWord)
    }

    /// Select All covers the reply — every block, in reading order, including the
    /// code block and both table rows.
    func testSelectAllCoversTheWholeReply() throws {
        let view = try XCTUnwrap(renderReply().first)
        view.selectAll(nil)

        XCTAssertEqual(view.selectedRange,
                       NSRange(location: 0, length: (view.text as NSString).length))
        XCTAssertEqual(copyText(from: view), MarkdownReplyFixture.expectedFullCopy)
    }

    /// Table cells and code lines are inside the document's selection, in reading
    /// order — not attachments, not images, not a separate view.
    func testTableAndCodeParticipateInSelection() throws {
        let view = try XCTUnwrap(renderReply().first)
        let ns = view.text as NSString

        let code = ns.range(of: "SELECT day")
        let cell = ns.range(of: "❌")
        XCTAssertNotEqual(code.location, NSNotFound, "code is not in the document")
        XCTAssertNotEqual(cell.location, NSNotFound, "a table cell is not in the document")
        XCTAssertLessThan(code.location, cell.location, "code must precede the table it precedes")

        view.selectedRange = NSRange(location: code.location,
                                     length: cell.location + cell.length - code.location)
        let copied = try XCTUnwrap(copyText(from: view))
        XCTAssertTrue(copied.hasPrefix("SELECT day, SUM(protein_g)\n  FROM meals\n GROUP BY day"),
                      "code lost its whitespace on the way to the pasteboard")
        XCTAssertTrue(copied.hasSuffix("Day\tProtein\tMet\nMon\t128 g\t✅\nTue\t96 g\t❌"),
                      "table cells did not copy as a tab-separated grid: \(copied)")
    }

    /// A long reply lays out taller than the viewport, and the whole of it is one
    /// text view — which is what makes extending a selection past the bottom of the
    /// screen possible at all. (Whether the *handle drag* auto-scrolls is a device
    /// behaviour this cannot assert; see the PR's verification notes.)
    func testALongReplyIsOneTextViewTallerThanTheViewport() throws {
        let long = (1...40)
            .map { "Paragraph number \($0) of a deliberately long reply that wraps." }
            .joined(separator: "\n\n")
        let views = renderReply(long)
        XCTAssertEqual(views.count, 1)
        let view = try XCTUnwrap(views.first)
        XCTAssertGreaterThan(view.bounds.height, 900, "fixture is not long enough to test with")

        let ns = view.text as NSString
        let first = ns.range(of: "Paragraph number 1 ")
        let last = ns.range(of: "Paragraph number 40 ")
        view.selectedRange = NSRange(location: first.location,
                                     length: last.location + last.length - first.location)
        XCTAssertGreaterThan(view.selectedRange.length, 1000)
        XCTAssertTrue(try XCTUnwrap(copyText(from: view)).contains("Paragraph number 40"))
    }

    // MARK: - Dynamic Type

    /// At a large accessibility size the reply is STILL one text view and still
    /// selectable end to end. The document's fonts are baked in, so this is the
    /// check that the rebuild-on-size-change path actually fires — if it did not,
    /// the reply would render at the default size and this height would not move.
    func testLargeAccessibilityTextKeepsOneSelectableReply() throws {
        let normalHeight = try XCTUnwrap(renderReply().first).bounds.height

        let views = renderReply(typeSize: .accessibility3)
        XCTAssertEqual(views.count, 1, "accessibility sizing must not split the reply")
        let view = try XCTUnwrap(views.first)
        XCTAssertGreaterThan(view.bounds.height, normalHeight,
                             "the reply did not grow — Dynamic Type never reached the document")

        view.selectAll(nil)
        XCTAssertEqual(copyText(from: view), MarkdownReplyFixture.expectedFullCopy,
                       "the text is the same text however large it is set")
    }

    /// SwiftUI's size is carried to UIKit as the category the fonts resolve at.
    func testDynamicTypeSizeMapsToAContentSizeCategory() {
        XCTAssertEqual(SelectableDocumentText.contentSizeCategory(.xSmall), .extraSmall)
        XCTAssertEqual(SelectableDocumentText.contentSizeCategory(.large), .large)
        XCTAssertEqual(SelectableDocumentText.contentSizeCategory(.accessibility5),
                       .accessibilityExtraExtraExtraLarge)
    }

    // MARK: - Selection stability

    /// An unrelated SwiftUI update must not reset the selection. The wrapper only
    /// reassigns the storage when the reply text or the Dynamic Type size changed;
    /// a body re-evaluation for any other reason has to leave it alone.
    func testUnrelatedUpdateKeepsTheSelection() throws {
        let host = UIHostingController(rootView:
            ReplyHarness(text: MarkdownReplyFixture.raw, unrelated: 0))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 340, height: 4000))
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        host.view.layoutIfNeeded()

        let view = try XCTUnwrap(Self.textViews(in: host.view).first)
        let word = (view.text as NSString).range(of: MarkdownReplyFixture.singleWord)
        view.selectedRange = word

        // Something else in the view tree changes; the reply did not.
        host.rootView = ReplyHarness(text: MarkdownReplyFixture.raw, unrelated: 1)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        let after = try XCTUnwrap(Self.textViews(in: host.view).first)
        XCTAssertEqual(after.selectedRange, word,
                       "an unrelated SwiftUI update dropped the selection")
    }

    /// A view that re-evaluates its body for a reason that has nothing to do with
    /// the reply, so the test above can trigger one.
    private struct ReplyHarness: View {
        let text: String
        let unrelated: Int

        var body: some View {
            VStack(alignment: .leading) {
                MarkdownText(text)
                Text("unrelated \(unrelated)")
            }
            .frame(width: 340, alignment: .leading)
        }
    }
}
