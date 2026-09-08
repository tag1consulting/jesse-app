import SwiftUI
import UIKit

// The one text view a completed reply is rendered in.
//
// `SelectableText` (still used for the user bubble, which is a single run of
// plain text) renders an `NSAttributedString` and nothing else. A reply needs two
// things it does not have: the shaded cards behind code blocks and tables, which
// used to come from a SwiftUI `.background` on a per-block view and now have no
// view to hang off; and a copy that puts sensible separators on the pasteboard
// rather than the storage's own single newlines. Both are properties of the
// document as a whole, so they live here with it.
//
// See `MarkdownDocument` for why a reply is one document at all.

/// A non-editable, non-scrolling text view that renders a `MarkdownDocument`:
/// its text, its decorations, and its copy semantics.
///
/// TextKit 1 on purpose. The cards are drawn from line-fragment geometry, which
/// `NSLayoutManager` gives directly; the initializer takes an explicit TextKit 1
/// stack rather than relying on the implicit downgrade that touching
/// `.layoutManager` triggers on a TextKit 2 view, because that downgrade is a
/// documented fallback and not something to build on deliberately.
final class MarkdownDocumentTextView: UITextView {
    /// The document currently rendered. Set through `apply(_:)`.
    private(set) var document: MarkdownDocument = .empty

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        // Fonts are baked into the document at the caller's Dynamic Type size and
        // the document is rebuilt when that size changes (`SelectableDocumentText`
        // reads `\.dynamicTypeSize`). Letting UIKit also rescale them would apply
        // the change twice, and would do it without the column widths measured
        // into the table's tab stops being recomputed.
        adjustsFontForContentSizeCategory = false
        // Links come from `.link` attributes only — no data-detector guessing.
        dataDetectorTypes = []
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The card fills resolve against the trait collection at draw time, so a
        // light/dark switch needs nothing but a redraw.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: MarkdownDocumentTextView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Install `document`, preserving nothing — callers must decide whether a
    /// change is real before calling, because assigning the storage necessarily
    /// drops any live selection.
    func apply(_ document: MarkdownDocument) {
        self.document = document
        attributedText = document.attributed
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    // MARK: - Decorations

    override func draw(_ rect: CGRect) {
        drawDecorations()
        super.draw(rect)
    }

    private func drawDecorations() {
        guard !document.decorations.isEmpty, let context = UIGraphicsGetCurrentContext() else {
            return
        }
        let pad = MarkdownDocument.Metrics.cardPadding
        let radius = MarkdownDocument.Metrics.cardCornerRadius
        let fill = UIColor.secondaryLabel.withAlphaComponent(0.12)
            .resolvedColor(with: traitCollection)
        let rule = UIColor.separator.resolvedColor(with: traitCollection)

        for decoration in document.decorations {
            guard let body = usedRect(for: decoration.range) else { continue }
            let card = CGRect(x: 0,
                              y: body.minY - pad,
                              width: bounds.width,
                              height: body.height + pad * 2)
            context.setFillColor(fill.cgColor)
            UIBezierPath(roundedRect: card, cornerRadius: radius).fill()

            // The rule under a table's header row — the old `Grid`'s `Divider()`.
            if case let .table(headerRange) = decoration.kind,
               let header = usedRect(for: headerRange) {
                let y = (header.maxY + MarkdownDocument.Metrics.rowSpacing / 2).rounded()
                let thickness = 1 / max(traitCollection.displayScale, 1)
                context.setFillColor(rule.cgColor)
                context.fill(CGRect(x: pad, y: y,
                                    width: max(bounds.width - pad * 2, 0),
                                    height: thickness))
            }
        }
    }

    /// The union of the *used* line-fragment rects for a character range, in view
    /// coordinates.
    ///
    /// Used rects, not `boundingRect(forGlyphRange:in:)`: a line fragment rect
    /// includes the paragraph spacing around it, and the whole point of the card
    /// padding being real paragraph spacing is that the card is drawn INTO it. A
    /// bounding rect would swallow the padding and the card would come out one
    /// block-gap too tall.
    private func usedRect(for range: NSRange) -> CGRect? {
        guard range.length > 0 else { return nil }
        let manager = layoutManager
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }

        var union: CGRect?
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            union = union.map { $0.union(used) } ?? used
        }
        guard var rect = union else { return nil }
        rect.origin.x += textContainerInset.left
        rect.origin.y += textContainerInset.top
        return rect
    }

    // MARK: - Copy

    /// Copy the selection as the document says it should read.
    ///
    /// `UITextView`'s own copy hands over the backing string verbatim, and the
    /// backing string separates blocks with a single newline because the visible
    /// gap between them is `paragraphSpacing` rather than a blank line. Pasting
    /// that into a plain-text field would run the paragraphs together. The
    /// document knows where its blocks start and end, so it can put the blank
    /// lines back — and strip the layout-only leading tab off table rows.
    override func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else {
            super.copy(sender)
            return
        }
        UIPasteboard.general.string = document.plainText(for: selectedRange)
    }
}

/// SwiftUI wrapper for `MarkdownDocumentTextView`.
///
/// It takes the parsed BLOCKS rather than a built document: building the document
/// resolves fonts and measures every table cell, and SwiftUI re-evaluates a body
/// for reasons that have nothing to do with this reply's text. Holding the blocks
/// (cheap to compare) lets the wrapper rebuild — and reassign the storage, which
/// would drop a live selection — only when the reply or the Dynamic Type size
/// actually changed.
struct SelectableDocumentText: UIViewRepresentable {
    let blocks: [MarkdownBlock]
    let typeSize: DynamicTypeSize

    final class Coordinator {
        /// Identity of the document currently in the text view's storage.
        var applied: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MarkdownDocumentTextView {
        let view = MarkdownDocumentTextView()
        install(into: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: MarkdownDocumentTextView, context: Context) {
        install(into: view, coordinator: context.coordinator)
    }

    /// Rebuild and reassign the storage only when the reply or the Dynamic Type
    /// size really changed. Every other SwiftUI update — a sibling turn arriving,
    /// a scroll-position state change, an unrelated `@State` flip in the detail
    /// view — leaves the storage untouched, and a selection in progress with it.
    private func install(into view: MarkdownDocumentTextView, coordinator: Coordinator) {
        let category = Self.contentSizeCategory(typeSize)
        let key = category.rawValue + "\u{0}" + fingerprint
        guard coordinator.applied != key else { return }
        coordinator.applied = key
        view.apply(MarkdownDocument.build(
            blocks: blocks,
            traits: UITraitCollection(preferredContentSizeCategory: category)))
    }

    /// A stable identity for the block list, cheaper to compare than the built
    /// `NSAttributedString`. Two replies sharing a fingerprint have identical text.
    private var fingerprint: String {
        blocks.map(Self.describe).joined(separator: "\u{1}")
    }

    private static func describe(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(level, text):   return "h\(level)\u{2}\(text)"
        case let .bullet(text):           return "b\u{2}\(text)"
        case let .numbered(number, text): return "n\(number)\u{2}\(text)"
        case let .code(code):             return "c\u{2}\(code)"
        case let .paragraph(text):        return "p\u{2}\(text)"
        case let .table(headers, rows, alignments):
            let cells = ([headers] + rows).map { $0.joined(separator: "\u{3}") }
                .joined(separator: "\u{4}")
            return "t\u{2}\(alignments.map(String.init(describing:)).joined(separator: ","))\u{2}\(cells)"
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: MarkdownDocumentTextView,
                      context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? .greatestFiniteMagnitude
        let fitting = view.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(fitting.width, width), height: ceil(fitting.height))
    }

    /// SwiftUI's `DynamicTypeSize` as the UIKit category the fonts resolve at.
    static func contentSizeCategory(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall:            return .extraSmall
        case .small:             return .small
        case .medium:            return .medium
        case .large:             return .large
        case .xLarge:            return .extraLarge
        case .xxLarge:           return .extraExtraLarge
        case .xxxLarge:          return .extraExtraExtraLarge
        case .accessibility1:    return .accessibilityMedium
        case .accessibility2:    return .accessibilityLarge
        case .accessibility3:    return .accessibilityExtraLarge
        case .accessibility4:    return .accessibilityExtraExtraLarge
        case .accessibility5:    return .accessibilityExtraExtraExtraLarge
        @unknown default:        return .large
        }
    }
}
