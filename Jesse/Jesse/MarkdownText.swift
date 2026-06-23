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

/// One renderable block of a markdown reply.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case numbered(number: Int, text: String)
    case code(String)
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
    let lines = raw.components(separatedBy: "\n")

    for line in lines {
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
            continue
        }

        if inCode {
            codeLines.append(line)
            continue
        }

        // Blank line: paragraph separator.
        if trimmed.isEmpty {
            flushParagraph()
            continue
        }

        // Heading: 1–3 leading '#' followed by a space.
        if let heading = parseHeading(trimmed) {
            flushParagraph()
            blocks.append(heading)
            continue
        }

        // Bullet: '- ', '* ', or '+ '.
        if let bulletText = parseBullet(trimmed) {
            flushParagraph()
            blocks.append(.bullet(text: bulletText))
            continue
        }

        // Numbered: leading digits, then '.', then a space.
        if let numbered = parseNumbered(trimmed) {
            flushParagraph()
            blocks.append(numbered)
            continue
        }

        // Plain text line — part of the current paragraph.
        paragraphLines.append(trimmed)
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

/// Renders parsed markdown blocks as native SwiftUI views.
struct MarkdownText: View {
    let blocks: [MarkdownBlock]

    init(_ raw: String) {
        self.blocks = parseMarkdownBlocks(raw)
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

        case let .paragraph(text):
            inline(text)
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
