import SwiftUI

// A small, dependency-free block renderer for Jesse's markdown replies.
//
// SwiftUI's `Text` only interprets *inline* markdown and collapses newlines,
// so a multi-paragraph / bulleted answer comes out as a wall of text. Here we
// split the reply into blocks (headings, bullets, numbered items, fenced code,
// paragraphs) and render each with the right view, using Foundation's
// `AttributedString(markdown:)` for inline styling (bold/italic/code/links)
// *within* a block.
//
// Parsing is kept separate from rendering so the parser is unit-testable.

/// Per-column horizontal alignment for a GFM pipe table.
enum TableAlignment: Equatable {
    case leading, center, trailing
}

/// One renderable block of a markdown reply.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case numbered(number: Int, text: String)
    case code(String)
    case table(headers: [String], rows: [[String]], alignments: [TableAlignment])
    case paragraph(String)
}

/// Split raw markdown into blocks. Pure — no SwiftUI, fully testable.
///
/// Rules:
/// - `#`/`##`/`###` (1–3 `#` then a space) → heading.
/// - `- `, `* `, or `+ ` → bullet.
/// - `<digits>. ` → numbered item.
/// - A ```` ``` ```` fence toggles a verbatim code block; everything between
///   the open and close fence is one `.code` block with the fences removed.
/// - Otherwise, consecutive non-blank lines join into one paragraph; a blank
///   line ends the current paragraph.
func parseMarkdownBlocks(_ raw: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []

    // Buffer for the paragraph currently being accumulated.
    var paragraphLines: [String] = []
    func flushParagraph() {
        guard !paragraphLines.isEmpty else { return }
        blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        paragraphLines.removeAll()
    }

    // State for an open fenced code block.
    var inCode = false
    var codeLines: [String] = []

    // Preserve trailing empty lines so blank-line separation is detected.
    // Index-based so a table can look ahead to its delimiter row and consume
    // its data rows in one step.
    let lines = raw.components(separatedBy: "\n")

    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Fence toggles take priority over everything else.
        if trimmed.hasPrefix("```") {
            if inCode {
                // Closing fence — emit the accumulated code, fences excluded.
                blocks.append(.code(codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                inCode = false
            } else {
                // Opening fence — end any paragraph in progress first.
                flushParagraph()
                inCode = true
            }
            i += 1
            continue
        }

        if inCode {
            codeLines.append(line)
            i += 1
            continue
        }

        // Blank line: paragraph separator.
        if trimmed.isEmpty {
            flushParagraph()
            i += 1
            continue
        }

        // Heading: 1–3 leading '#' followed by a space.
        if let heading = parseHeading(trimmed) {
            flushParagraph()
            blocks.append(heading)
            i += 1
            continue
        }

        // Bullet: '- ', '* ', or '+ '.
        if let bulletText = parseBullet(trimmed) {
            flushParagraph()
            blocks.append(.bullet(text: bulletText))
            i += 1
            continue
        }

        // Numbered: leading digits, then '.', then a space.
        if let numbered = parseNumbered(trimmed) {
            flushParagraph()
            blocks.append(numbered)
            i += 1
            continue
        }

        // GFM pipe table: a row-looking line (contains '|') IMMEDIATELY followed
        // by a delimiter row (cells of only '-', ':', spaces, with at least one
        // '-'). A '|'-containing line *not* followed by a delimiter is just prose
        // with pipes and falls through to the paragraph branch below.
        if trimmed.contains("|"),
           i + 1 < lines.count,
           isTableDelimiterRow(lines[i + 1]) {
            flushParagraph()
            let headers = splitTableRow(trimmed)
            let alignments = parseTableAlignments(lines[i + 1])
            var rows: [[String]] = []
            // Consume following '|'-containing lines as data rows until a
            // blank or non-row line ends the table.
            var j = i + 2
            while j < lines.count {
                let rowLine = lines[j].trimmingCharacters(in: .whitespaces)
                guard !rowLine.isEmpty, rowLine.contains("|") else { break }
                rows.append(splitTableRow(rowLine))
                j += 1
            }
            blocks.append(.table(headers: headers, rows: rows, alignments: alignments))
            i = j
            continue
        }

        // Plain text line — part of the current paragraph.
        paragraphLines.append(trimmed)
        i += 1
    }

    // Close out anything still open.
    flushParagraph()
    if inCode {
        // Unterminated fence — still surface its content as code.
        blocks.append(.code(codeLines.joined(separator: "\n")))
    }

    return blocks
}

private func parseHeading(_ line: String) -> MarkdownBlock? {
    var level = 0
    let chars = Array(line)
    while level < chars.count && chars[level] == "#" { level += 1 }
    guard level >= 1, level <= 3, level < chars.count, chars[level] == " " else {
        return nil
    }
    let text = String(chars[(level + 1)...]).trimmingCharacters(in: .whitespaces)
    return .heading(level: level, text: text)
}

private func parseBullet(_ line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
        return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

private func parseNumbered(_ line: String) -> MarkdownBlock? {
    let chars = Array(line)
    var i = 0
    while i < chars.count && chars[i].isNumber { i += 1 }
    guard i > 0, i + 1 < chars.count, chars[i] == ".", chars[i + 1] == " " else {
        return nil
    }
    guard let number = Int(String(chars[0..<i])) else { return nil }
    let text = String(chars[(i + 2)...]).trimmingCharacters(in: .whitespaces)
    return .numbered(number: number, text: text)
}

/// True if `line` is a GFM table delimiter row: at least one cell, every cell
/// made only of `-`, `:`, and spaces, and the row contains at least one `-`.
private func isTableDelimiterRow(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|"), trimmed.contains("-") else { return false }
    let cells = splitTableRow(trimmed)
    guard !cells.isEmpty else { return false }
    for cell in cells {
        let stripped = cell.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty,
              stripped.allSatisfy({ $0 == "-" || $0 == ":" }) else {
            return false
        }
    }
    return true
}

/// Per-column alignment from a delimiter row: `:---`=leading, `:--:`=center,
/// `---:`=trailing, plain=leading.
private func parseTableAlignments(_ line: String) -> [TableAlignment] {
    splitTableRow(line.trimmingCharacters(in: .whitespaces)).map { cell in
        let c = cell.trimmingCharacters(in: .whitespaces)
        let left = c.hasPrefix(":")
        let right = c.hasSuffix(":")
        switch (left, right) {
        case (true, true):  return .center
        case (false, true): return .trailing
        default:            return .leading
        }
    }
}

/// Split one pipe-table row into trimmed cells: drop one optional leading and
/// trailing `|`, split on `|`, trim each cell. (Escaped `\|` is out of scope.)
private func splitTableRow(_ line: String) -> [String] {
    var s = Substring(line.trimmingCharacters(in: .whitespaces))
    if s.hasPrefix("|") { s = s.dropFirst() }
    if s.hasSuffix("|") { s = s.dropLast() }
    return s.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

/// Coalesces the markdown parse of a *growing* string (a live stream's partial
/// reply) to ~10 Hz. The naive `MarkdownText(partial)` re-parses the whole string
/// on every delta, so an N-delta stream parses O(N²) characters. This caps the
/// parse to at most once per `interval`: between parses it returns the last result,
/// so frequent deltas are cheap and the expensive `parseMarkdownBlocks` runs ≤10×/s
/// regardless of delta rate. The newest text always wins — the next tick past the
/// interval parses whatever the current text is — and the finished turn's persisted
/// Turn renders the complete text, so nothing is ever shown stale for long.
@MainActor
final class MarkdownStreamRenderer {
    /// ~10 Hz: at most one parse per 100 ms while deltas stream in. Also the
    /// TimelineView tick interval the streaming view drives this with. `nonisolated`
    /// so it can seed the init default argument (evaluated off the main actor).
    nonisolated static let interval: TimeInterval = 0.1

    private let interval: TimeInterval
    private let parse: @MainActor (String) -> [MarkdownBlock]
    private var cached: [MarkdownBlock] = []
    private var cachedSource: String?
    private var lastParseAt: Date?

    /// `parse` is injectable so a test can count calls; it defaults to the real
    /// `parseMarkdownBlocks`, resolved in the init body (a non-nil default argument
    /// would be formed off the main actor under MainActor-default isolation).
    init(interval: TimeInterval = MarkdownStreamRenderer.interval,
         parse: (@MainActor (String) -> [MarkdownBlock])? = nil) {
        self.interval = interval
        self.parse = parse ?? parseMarkdownBlocks
    }

    /// The blocks to render for `text` at `now`. Re-parses only when the text
    /// changed AND at least `interval` has elapsed since the last parse; otherwise
    /// returns the cached blocks unchanged (so the view diff is a no-op and no parse
    /// runs). Unchanged text never re-parses.
    func blocks(for text: String, now: Date) -> [MarkdownBlock] {
        if text == cachedSource { return cached }
        if let last = lastParseAt, now.timeIntervalSince(last) < interval {
            return cached
        }
        cached = parse(text)
        cachedSource = text
        lastParseAt = now
        return cached
    }
}

/// Renders parsed markdown blocks as native SwiftUI views.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ raw: String) {
        self.blocks = parseMarkdownBlocks(raw)
    }

    /// Render pre-parsed blocks directly — used by the throttled streaming path
    /// (`MarkdownStreamRenderer`) so the parse isn't re-run inside the view body.
    init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Selection is enabled at the container; descendant Text inherits it.
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(headingFont(level))

        case let .bullet(text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(text)
            }

        case let .numbered(number, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).")
                inline(text)
            }

        case let .code(code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                )
                .textSelection(.enabled)

        case let .table(headers, rows, alignments):
            tableView(headers: headers, rows: rows, alignments: alignments)

        case let .paragraph(text):
            inline(text)
        }
    }

    /// Render a GFM pipe table as a SwiftUI `Grid` inside a horizontal
    /// `ScrollView` so a wide table scrolls rather than truncating. Ragged rows
    /// (fewer cells than headers) pad with empties; extra cells are dropped.
    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]], alignments: [TableAlignment]) -> some View {
        let columns = headers.count
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        cell(headers[col], alignment: alignment(alignments, col))
                            .fontWeight(.semibold)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { col in
                            cell(col < row.count ? row[col] : "",
                                 alignment: alignment(alignments, col))
                        }
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
            )
        }
    }

    /// One table cell: inline-styled text, padded and aligned per its column.
    private func cell(_ text: String, alignment: Alignment) -> some View {
        inline(text)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func alignment(_ alignments: [TableAlignment], _ col: Int) -> Alignment {
        switch col < alignments.count ? alignments[col] : .leading {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title3.weight(.semibold)
        case 2:  return .headline.weight(.semibold)
        default: return .subheadline.weight(.semibold)
        }
    }

    /// Inline styling within a block. Parses bold/italic/`code`/links while
    /// preserving whitespace; falls back to the plain string on any failure.
    private func inline(_ s: String) -> Text {
        let attributed = (try? AttributedString(
            markdown: s,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(s)
        return Text(attributed)
    }
}
