import UIKit

// One completed reply, composed into ONE attributed-text document.
//
// ── THE BUG THIS EXISTS TO FIX ────────────────────────────────────────────────
//
// `MarkdownText`'s selectable path used to render a `VStack` with a separate
// `SelectableText` — and therefore a separate `UITextView` — per block. A
// `UITextView`'s selection lives in its own `NSTextStorage`: `UITextInteraction`
// resolves handle drags against that one text view's layout, and both ends of a
// selection are `UITextPosition`s belonging to it. Two sibling text views cannot
// hold one selection between them, and nothing in UIKit joins them.
//
// So every paragraph, heading, bullet, numbered item and code block was its own
// SELECTION ISLAND. Long-press picked a word inside one block; dragging a handle
// past that block's last glyph clamped there instead of continuing into the next
// block; and `Select All` — which UIKit routes to `-selectAll:` on the *first
// responder*, i.e. one text view — selected only the block that was touched. That
// is exactly the reported symptom: a word works, a paragraph works, more than a
// paragraph is impossible. Tables were worse than an island: they rendered as a
// SwiftUI `Grid` of `Text`, outside any text view, so their contents took part in
// no selection at all.
//
// ── THE FIX ───────────────────────────────────────────────────────────────────
//
// Compose the whole reply into a single `NSAttributedString` and render it in a
// single text view. Selection is then a plain character range over one text
// storage, so it spans blocks by construction, `Select All` covers the reply, and
// the native gestures (long-press, double-tap-for-word, handle drag, the system
// edit menu) keep working because they are the same gestures on the same kind of
// view — there is just one of it now.
//
// What used to be *view structure* has to become *typography*, and that is the
// bulk of this file:
//
//   - block spacing 8pt   → `paragraphSpacing` on the LAST line of each block
//                           (not on every line — a code block's interior newlines
//                           are paragraph breaks too, and would otherwise get 8pt
//                           of air between every line of code)
//   - list marker column  → `•\t` / `1.\t` with a hanging `headIndent`
//   - code / table cards  → recorded as `decorations` and drawn behind the text
//                           by the text view; the padding is real layout
//                           (`headIndent` / `tailIndent` / paragraph spacing) so
//                           the card can be sized from the line fragments
//   - table grid          → per-column `NSTextTab` stops measured from content
//
// Everything here is pure: blocks in, an `NSAttributedString` plus two maps out.
// No view, no layout, no width — which is what makes it unit-testable.

/// A decoration drawn *behind* a range of the document (the shaded cards that
/// `codeBlock` / `tableView` used to get from a SwiftUI `background` modifier).
struct MarkdownDecoration: Equatable {
    enum Kind: Equatable {
        case code
        /// A table card. `headerRange` is the header row, under which a rule is
        /// drawn — the `Divider()` the old `Grid` had.
        case table(headerRange: NSRange)
    }

    let range: NSRange
    let kind: Kind
}

/// Where each source block ended up in the document. Used by copy, which needs to
/// know block boundaries (and their kinds) to choose separators — see
/// `plainText(for:)`.
struct MarkdownDocumentBlock: Equatable {
    enum Kind: Equatable {
        case heading
        case paragraph
        case listItem
        case code
        case table
    }

    /// Range of the block's own text, EXCLUDING the `\n` that separates it from
    /// the next block.
    let range: NSRange
    let kind: Kind
}

/// A reply as one selectable document.
struct MarkdownDocument: Equatable {
    let attributed: NSAttributedString
    let blocks: [MarkdownDocumentBlock]
    let decorations: [MarkdownDecoration]

    static let empty = MarkdownDocument(
        attributed: NSAttributedString(), blocks: [], decorations: [])

    // MARK: - Copy

    /// The plain text to put on the pasteboard for `selected`.
    ///
    /// The document's own backing string separates blocks with a single `\n`,
    /// because the *visual* gap between blocks is `paragraphSpacing`, not a blank
    /// line — putting real blank lines in the storage would double the gap on
    /// screen. That is right for layout and wrong for the pasteboard: pasting two
    /// paragraphs into a plain-text field should give a blank line between them,
    /// the way the Markdown that produced them did.
    ///
    /// So copy re-joins the selected slice of each block with the separator that
    /// block boundary implies: one newline between consecutive list items (they
    /// are one list), a blank line everywhere else. Nothing but the selected text
    /// goes on the pasteboard — no role prefix, no timestamp, no citation.
    func plainText(for selected: NSRange) -> String {
        let ns = attributed.string as NSString
        let bounded = NSIntersectionRange(selected, NSRange(location: 0, length: ns.length))
        guard bounded.length > 0 else { return "" }

        var pieces: [(text: String, kind: MarkdownDocumentBlock.Kind)] = []
        for block in blocks {
            let hit = NSIntersectionRange(block.range, bounded)
            guard hit.length > 0 else { continue }
            var slice = ns.substring(with: hit)
            if block.kind == .table {
                // Table rows are stored with a leading tab (it is what positions
                // the first column against its own tab stop). It is layout, not
                // content, so it never reaches the pasteboard.
                slice = slice
                    .components(separatedBy: "\n")
                    .map { $0.hasPrefix("\t") ? String($0.dropFirst()) : $0 }
                    .joined(separator: "\n")
            }
            pieces.append((slice, block.kind))
        }
        guard !pieces.isEmpty else {
            // A selection that fell entirely inside the inter-block separators.
            return ns.substring(with: bounded)
        }

        var out = pieces[0].text
        for i in 1..<pieces.count {
            let bothListItems = pieces[i - 1].kind == .listItem && pieces[i].kind == .listItem
            out += bothListItems ? "\n" : "\n\n"
            out += pieces[i].text
        }
        return out
    }

    // MARK: - Build

    /// Layout constants, kept together because the text view needs two of them
    /// (`cardPadding` to size a card, `cardCornerRadius` to round it) and the
    /// tests assert against the rest.
    enum Metrics {
        /// The old `VStack(spacing: 8)`.
        static let blockSpacing: CGFloat = 8
        /// The old `.padding(8)` inside a code / table card.
        static let cardPadding: CGFloat = 8
        static let cardCornerRadius: CGFloat = 6
        /// The old table cell `.padding(.horizontal, 6)`.
        static let cellInset: CGFloat = 6
        /// The old table cell `.padding(.vertical, 2)`, top and bottom.
        static let rowSpacing: CGFloat = 4
        /// Hanging indent for `•` / `1.` list items — matches `MarkdownInline`.
        static let listIndent: CGFloat = 20
    }

    /// Compose `blocks` into one document.
    ///
    /// `traits` selects the Dynamic Type size the fonts are resolved at, so the
    /// caller can rebuild the document when the content size category changes
    /// (the fonts are baked into the storage; they cannot re-resolve themselves).
    static func build(blocks: [MarkdownBlock],
                      traits: UITraitCollection? = nil) -> MarkdownDocument {
        var builder = Builder(traits: traits)
        for (index, block) in blocks.enumerated() {
            builder.append(block, isLast: index == blocks.count - 1)
        }
        return builder.finish()
    }

    /// Convenience for a raw reply.
    static func build(_ raw: String, traits: UITraitCollection? = nil) -> MarkdownDocument {
        build(blocks: parseMarkdownBlocks(raw), traits: traits)
    }
}

// MARK: - Builder

/// Accumulates blocks into the storage while tracking the two maps.
///
/// The unit it appends is a LINE, not a block, because paragraph attributes in
/// TextKit are per-paragraph: a block's interior newlines are paragraph breaks
/// whether we want them to be or not, so the block's trailing spacing has to be
/// attached to its last line specifically.
private struct Builder {
    private let traits: UITraitCollection?
    private let result = NSMutableAttributedString()
    private var blocks: [MarkdownDocumentBlock] = []
    private var decorations: [MarkdownDecoration] = []

    init(traits: UITraitCollection?) {
        self.traits = traits
    }

    // Concrete UIKit fonts, resolved once at the caller's Dynamic Type size.
    // These mirror `MarkdownText`'s SwiftUI text styles one for one.
    private func font(_ style: UIFont.TextStyle) -> UIFont {
        if let traits { return UIFont.preferredFont(forTextStyle: style, compatibleWith: traits) }
        return UIFont.preferredFont(forTextStyle: style)
    }

    private var bodyFont: UIFont { font(.body) }

    private var monospacedBodyFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
    }

    private func bold(_ base: UIFont) -> UIFont {
        let merged = base.fontDescriptor.symbolicTraits.union(.traitBold)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(merged) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private func headingFont(_ level: Int) -> UIFont {
        switch level {
        case 1:  return bold(font(.title3))
        case 2:  return font(.headline)      // already semibold
        default: return bold(font(.subheadline))
        }
    }

    // MARK: Appending

    mutating func append(_ block: MarkdownBlock, isLast: Bool) {
        switch block {
        case let .heading(level, text):
            appendSimple(MarkdownInline.attributed(text, font: headingFont(level), color: .label),
                         kind: .heading, baseFont: headingFont(level), isLast: isLast)

        case let .paragraph(text):
            appendSimple(MarkdownInline.attributed(text, font: bodyFont, color: .label),
                         kind: .paragraph, baseFont: bodyFont, isLast: isLast)

        case let .bullet(text):
            appendListItem(marker: "•", text: text, isLast: isLast)

        case let .numbered(number, text):
            appendListItem(marker: "\(number).", text: text, isLast: isLast)

        case let .code(code):
            appendCode(code, isLast: isLast)

        case let .table(headers, rows, alignments):
            appendTable(headers: headers, rows: rows, alignments: alignments, isLast: isLast)
        }
    }

    /// A heading or paragraph: possibly multi-line (a paragraph joins its source
    /// lines with `\n`), no indent, no card.
    private mutating func appendSimple(_ text: NSAttributedString,
                                       kind: MarkdownDocumentBlock.Kind,
                                       baseFont: UIFont,
                                       isLast: Bool) {
        let lines = split(text)
        let styled = lines.enumerated().map { index, line -> Line in
            let style = NSMutableParagraphStyle()
            if index == lines.count - 1 { style.paragraphSpacing = MarkdownDocument.Metrics.blockSpacing }
            return Line(text: line, style: style, font: baseFont)
        }
        emit(styled, kind: kind, isLast: isLast, decoration: nil)
    }

    /// A list item. `MarkdownInline.listItem` already builds the `marker\ttext`
    /// hanging-indent form the old per-block text view used, so the marker and its
    /// indentation are literally the same bytes as before — and, being real text,
    /// the marker now copies with the item.
    private mutating func appendListItem(marker: String, text: String, isLast: Bool) {
        let item = MarkdownInline.listItem(
            marker: marker, text: text, font: bodyFont, color: .label,
            indent: MarkdownDocument.Metrics.listIndent)
        let lines = split(item)
        let styled = lines.enumerated().map { index, line -> Line in
            // `listItem` set a paragraph style (head indent + tab stop); extend a
            // COPY of it rather than replacing it, or the hanging indent is lost.
            let existing = line.length > 0
                ? line.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                : nil
            let style = (existing?.mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            if index == lines.count - 1 { style.paragraphSpacing = MarkdownDocument.Metrics.blockSpacing }
            return Line(text: line, style: style, font: bodyFont)
        }
        emit(styled, kind: .listItem, isLast: isLast, decoration: nil)
    }

    /// A fenced code block: monospaced, verbatim (every space and tab of the
    /// source survives — nothing here trims), inset inside a shaded card.
    private mutating func appendCode(_ code: String, isLast: Bool) {
        let pad = MarkdownDocument.Metrics.cardPadding
        let attrs: [NSAttributedString.Key: Any] = [
            .font: monospacedBodyFont, .foregroundColor: UIColor.label,
        ]
        let lines = code.components(separatedBy: "\n")
        let styled = lines.enumerated().map { index, line -> Line in
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = pad
            style.headIndent = pad
            style.tailIndent = -pad
            // Card padding as real vertical space, so the card drawn behind the
            // block has somewhere to be without overlapping its neighbours.
            if index == 0 { style.paragraphSpacingBefore = pad }
            if index == lines.count - 1 {
                style.paragraphSpacing = pad + MarkdownDocument.Metrics.blockSpacing
            }
            return Line(text: NSAttributedString(string: line, attributes: attrs),
                        style: style, font: monospacedBodyFont)
        }
        emit(styled, kind: .code, isLast: isLast, decoration: { range, _ in
            MarkdownDecoration(range: range, kind: .code)
        })
    }

    /// A GFM pipe table as tab-stop columns inside a shaded card.
    ///
    /// The old renderer built a SwiftUI `Grid` — real views, and therefore text
    /// that no text view owned and no selection could reach. Columns here are
    /// `NSTextTab` stops measured from the widest cell in each column, so the grid
    /// is typography and every cell is ordinary selectable text in reading order:
    /// left to right along a row, then down.
    ///
    /// Each row begins with a tab, which is what lets the FIRST column honour its
    /// column alignment (a tab stop aligns the run that follows it; without a
    /// leading tab, column 0 could only ever be leading-aligned). `plainText(for:)`
    /// strips it back off on copy.
    ///
    /// TRADE-OFF, stated plainly: the old table sat in a horizontal `ScrollView`,
    /// so an over-wide table scrolled sideways with its columns intact. A document
    /// has one text container and no sideways axis, so an over-wide table now
    /// wraps at the container edge instead. Nothing is truncated or lost, and the
    /// cells stay selectable and in order; a very wide table is just less tidy
    /// than it was. Selection islands were the worse of the two problems.
    private mutating func appendTable(headers: [String], rows: [[String]],
                                      alignments: [TableAlignment], isLast: Bool) {
        let pad = MarkdownDocument.Metrics.cardPadding
        let inset = MarkdownDocument.Metrics.cellInset
        let columns = headers.count
        guard columns > 0 else { return }

        let headerFont = bold(bodyFont)
        // Resolve every cell first: the column widths are measured from the same
        // attributed strings that get rendered, so the measurement cannot drift
        // from what is drawn.
        let headerCells = headers.map {
            MarkdownInline.attributed($0, font: headerFont, color: .label)
        }
        let bodyCells: [[NSAttributedString]] = rows.map { row in
            (0..<columns).map { col in
                MarkdownInline.attributed(col < row.count ? row[col] : "",
                                          font: bodyFont, color: .label)
            }
        }

        var widths = [CGFloat](repeating: 0, count: columns)
        for col in 0..<columns {
            var widest = ceil(headerCells[col].size().width)
            for row in bodyCells { widest = max(widest, ceil(row[col].size().width)) }
            widths[col] = widest + inset * 2
        }

        // Column c occupies [edges[c], edges[c] + widths[c]).
        var edges = [CGFloat](repeating: pad, count: columns)
        for col in 1..<max(columns, 1) { edges[col] = edges[col - 1] + widths[col - 1] }

        let tabStops: [NSTextTab] = (0..<columns).map { col in
            switch col < alignments.count ? alignments[col] : .leading {
            case .leading:
                return NSTextTab(textAlignment: .left, location: edges[col] + inset)
            case .center:
                return NSTextTab(textAlignment: .center, location: edges[col] + widths[col] / 2)
            case .trailing:
                return NSTextTab(textAlignment: .right,
                                 location: edges[col] + widths[col] - inset)
            }
        }.sorted { $0.location < $1.location }

        func rowLine(_ cells: [NSAttributedString], font: UIFont, isFirst: Bool, isFinal: Bool) -> Line {
            let line = NSMutableAttributedString()
            for cell in cells {
                line.append(NSAttributedString(string: "\t",
                                               attributes: [.font: font,
                                                            .foregroundColor: UIColor.label]))
                line.append(cell)
            }
            let style = NSMutableParagraphStyle()
            style.tabStops = tabStops
            style.defaultTabInterval = max(widths.last ?? 40, 40)
            style.paragraphSpacing = MarkdownDocument.Metrics.rowSpacing
            if isFirst { style.paragraphSpacingBefore = pad }
            if isFinal {
                style.paragraphSpacing = pad + MarkdownDocument.Metrics.blockSpacing
            }
            return Line(text: line, style: style, font: font)
        }

        var lines: [Line] = [rowLine(headerCells, font: headerFont,
                                     isFirst: true, isFinal: bodyCells.isEmpty)]
        for (index, cells) in bodyCells.enumerated() {
            lines.append(rowLine(cells, font: bodyFont, isFirst: false,
                                 isFinal: index == bodyCells.count - 1))
        }

        emit(lines, kind: .table, isLast: isLast, decoration: { range, lineRanges in
            MarkdownDecoration(range: range,
                               kind: .table(headerRange: lineRanges.first ?? range))
        })
    }

    // MARK: Emission

    private struct Line {
        let text: NSAttributedString
        let style: NSParagraphStyle
        /// Font for the paragraph terminator, so an empty line still has a height.
        let font: UIFont
    }

    /// Append one block's lines, record its range, and let the caller build a
    /// decoration from the block range plus the per-line ranges.
    private mutating func emit(_ lines: [Line],
                               kind: MarkdownDocumentBlock.Kind,
                               isLast: Bool,
                               decoration: ((NSRange, [NSRange]) -> MarkdownDecoration)?) {
        guard !lines.isEmpty else { return }
        let blockStart = result.length
        var lineRanges: [NSRange] = []

        for (index, line) in lines.enumerated() {
            let lineStart = result.length
            result.append(line.text)
            lineRanges.append(NSRange(location: lineStart, length: result.length - lineStart))
            // A paragraph terminator after every line except the document's very
            // last, and it must carry the paragraph's own style — TextKit reads a
            // paragraph's attributes from the run that ends it.
            let needsTerminator = index < lines.count - 1 || !isLast
            if needsTerminator {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [.font: line.font, .foregroundColor: UIColor.label]))
            }
            result.addAttribute(.paragraphStyle, value: line.style,
                                range: NSRange(location: lineStart,
                                               length: result.length - lineStart))
        }

        // The block's own text stops before the separator that follows it.
        let blockEnd = lineRanges.last.map { $0.location + $0.length } ?? result.length
        let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
        blocks.append(MarkdownDocumentBlock(range: blockRange, kind: kind))
        if let decoration { decorations.append(decoration(blockRange, lineRanges)) }
    }

    /// Split an attributed string at `\n`, keeping attributes, dropping the
    /// newlines themselves (they are re-added as styled paragraph terminators).
    private func split(_ text: NSAttributedString) -> [NSAttributedString] {
        let ns = text.string as NSString
        guard ns.range(of: "\n").location != NSNotFound else { return [text] }
        var parts: [NSAttributedString] = []
        var start = 0
        while start <= ns.length {
            let searchRange = NSRange(location: start, length: ns.length - start)
            let hit = ns.range(of: "\n", options: [], range: searchRange)
            if hit.location == NSNotFound {
                parts.append(text.attributedSubstring(
                    from: NSRange(location: start, length: ns.length - start)))
                break
            }
            parts.append(text.attributedSubstring(
                from: NSRange(location: start, length: hit.location - start)))
            start = hit.location + hit.length
            if start == ns.length {
                parts.append(NSAttributedString(string: ""))
                break
            }
        }
        return parts
    }

    func finish() -> MarkdownDocument {
        MarkdownDocument(attributed: NSAttributedString(attributedString: result),
                         blocks: blocks, decorations: decorations)
    }
}
