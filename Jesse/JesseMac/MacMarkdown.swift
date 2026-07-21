import SwiftUI

// A small, dependency-free Markdown renderer for Jesse's replies on macOS. The iOS app
// renders through a UIKit/`NSAttributedString` path (`MarkdownText`/`MarkdownInline`)
// that doesn't exist on the Mac; this renders the same reply shapes with pure SwiftUI:
// paragraphs, ATX headings, bullet/ordered lists, blockquotes, and fenced code blocks.
// Inline emphasis (bold/italic/code/links) is handled by `AttributedString(markdown:)`.

struct MacMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MacMarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
    }
}

/// One rendered block of a reply.
enum MacMarkdownBlock {
    case heading(level: Int, AttributedString)
    case paragraph(AttributedString)
    case bullet([AttributedString])
    case ordered([AttributedString])
    case quote(AttributedString)
    case code(String)

    @ViewBuilder var view: some View {
        switch self {
        case let .heading(level, s):
            Text(s).font(Self.headingFont(level)).fontWeight(.semibold)
                .textSelection(.enabled)
        case let .paragraph(s):
            Text(s).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case let .bullet(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .ordered(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(item).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case let .quote(s):
            HStack(spacing: 8) {
                Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                Text(s).italic().foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .code(src):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(src)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    /// Inline emphasis via the system Markdown parser, preserving whitespace. Falls back
    /// to plain text if the fragment doesn't parse.
    nonisolated static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// ATX heading level (1–6) if `s` starts with that many `#` then a space, else nil.
    nonisolated static func headingLevel(_ s: String) -> Int? {
        var count = 0
        for ch in s {
            if ch == "#" { count += 1; if count > 6 { return nil } } else { break }
        }
        guard (1...6).contains(count) else { return nil }
        let markEnd = s.index(s.startIndex, offsetBy: count)
        guard markEnd < s.endIndex, s[markEnd] == " " else { return nil }
        return count
    }

    /// Content after a `-`/`*`/`+` bullet marker + space, or nil if `s` isn't a bullet.
    nonisolated static func bulletContent(_ s: String) -> String? {
        guard let first = s.first, first == "-" || first == "*" || first == "+" else { return nil }
        let rest = s.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    /// Content after an ordered marker (`1.` / `1)` + space), or nil.
    nonisolated static func orderedContent(_ s: String) -> String? {
        var digits = 0
        for ch in s { if ch.isNumber { digits += 1 } else { break } }
        guard digits > 0 else { return nil }
        let markEnd = s.index(s.startIndex, offsetBy: digits)
        guard markEnd < s.endIndex, s[markEnd] == "." || s[markEnd] == ")" else { return nil }
        let afterMark = s.index(after: markEnd)
        guard afterMark < s.endIndex, s[afterMark] == " " else { return nil }
        return String(s[s.index(after: afterMark)...])
    }

    /// Split a reply into blocks. Line-oriented: fenced code (```), ATX headings,
    /// contiguous bullet/ordered runs, blockquotes, and paragraph runs.
    nonisolated static func parse(_ text: String) -> [MacMarkdownBlock] {
        var blocks: [MacMarkdownBlock] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(inline(joined))) }
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1  // consume the closing fence
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            // Blank line → paragraph boundary.
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }

            // ATX heading.
            if let level = Self.headingLevel(trimmed) {
                flushParagraph()
                let content = String(trimmed.dropFirst(level + 1))
                blocks.append(.heading(level: level, inline(content)))
                i += 1; continue
            }

            // Blockquote.
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst().trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.quote(inline(quoted.joined(separator: "\n"))))
                continue
            }

            // Unordered list run.
            if Self.bulletContent(trimmed) != nil {
                flushParagraph()
                var items: [AttributedString] = []
                while i < lines.count,
                      let content = Self.bulletContent(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(inline(content)); i += 1
                }
                blocks.append(.bullet(items))
                continue
            }

            // Ordered list run.
            if Self.orderedContent(trimmed) != nil {
                flushParagraph()
                var items: [AttributedString] = []
                while i < lines.count,
                      let content = Self.orderedContent(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(inline(content)); i += 1
                }
                blocks.append(.ordered(items))
                continue
            }

            // Plain paragraph line.
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }
}
