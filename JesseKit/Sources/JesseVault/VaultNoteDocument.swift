import Foundation

// ONE NOTE, READY TO DRAW.
//
// The app already has two markdown renderers — the iPhone's `NSAttributedString` path
// for assistant replies, and `MacMarkdownView` on the Mac — and NEITHER is used here,
// for one reason that is worth stating plainly rather than hiding in a commit message:
//
//     A vault note's most important construct is `[[a wiki link]]`, and neither
//     renderer knows what one is. Handed a note, both draw literal double brackets and
//     give the view no way to know a link was there, which is exactly the argument
//     `TodayNoteMarkdown` already makes for the day file's notes. A reader whose links
//     are not links is a reader you cannot follow a thought through.
//
// Both renderers also live where this target cannot reach them (one is in the iOS app
// target, the other in the Mac app target) and this target depends on nothing by design,
// so "use the platform's renderer" would mean either inverting that or copying a file.
// Instead the block model below is the same SMALL model `TodayNoteMarkdown` settled on —
// headings, bullets, quotes, fences, rules, paragraphs, nothing dropped ever — with two
// things the day file's notes never needed: frontmatter, and read-only checkboxes.
//
// Pure. A document is decided from a path and a string, so every rule here is asserted
// directly rather than read off a screenshot.

/// One drawable block of a note.
public struct VaultNoteBlock: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case bullet(depth: Int)
        /// A `- [ ] ` / `- [x] ` line. Drawn as a GLYPH and never as a control: this is
        /// somebody's note, opened read-only, and a tappable box would promise a write
        /// the offline reader does not do.
        case checkbox(depth: Int, checked: Bool)
        case quote
        case code
        case rule
        case paragraph
    }

    /// Position in the note — the only stable identity a block has, since two identical
    /// lines are two blocks and keying by text would collapse them.
    public let id: Int
    public let kind: Kind
    /// The text to draw. Markdown decoration is LEFT IN for inline rendering (emphasis,
    /// links) except that a checkbox's own `[ ]` marker is removed, having become a glyph.
    public let text: String
    /// The wiki targets this block carries, in source order.
    public let wikiTargets: [String]
    /// The 1-based line the block came from, so a hit's line can be scrolled to.
    public let line: Int

    public init(id: Int, kind: Kind, text: String, wikiTargets: [String] = [], line: Int = 0) {
        self.id = id
        self.kind = kind
        self.text = text
        self.wikiTargets = wikiTargets
        self.line = line
    }
}

/// A whole note as the reader shows it.
public struct VaultNoteDocument: Equatable, Sendable {
    public let path: String
    public let title: String
    /// The frontmatter block's lines, fences excluded. Empty when there is none.
    public let frontmatter: [String]
    public let blocks: [VaultNoteBlock]
    /// Every wiki target in the note, de-duplicated, in source order.
    public let wikiTargets: [String]
    /// The file was longer than `byteLimit` and what is here is a prefix.
    public let truncated: Bool
    /// The file's modification time, when the caller knew it.
    public let modified: Date?

    public init(path: String, title: String, frontmatter: [String], blocks: [VaultNoteBlock],
                wikiTargets: [String], truncated: Bool, modified: Date? = nil) {
        self.path = path
        self.title = title
        self.frontmatter = frontmatter
        self.blocks = blocks
        self.wikiTargets = wikiTargets
        self.truncated = truncated
        self.modified = modified
    }

    /// The file's name, which is what a title bar shows. The path is a caption: a vault
    /// path is too long to be a heading.
    public var fileName: String { VaultWikiLink.basename(path) }

    /// Notes are read whole and drawn whole, so there has to be a ceiling. 256 KB is
    /// about four times the largest note in this vault and still renders without a
    /// visible pause; beyond it the reader shows the first 256 KB and SAYS SO, because
    /// silently showing two thirds of a note is the kind of quiet lie that costs a
    /// reader an afternoon.
    public static let byteLimit = 256 * 1024

    /// Parse one note.
    public static func parse(path: String, text rawText: String, modified: Date? = nil,
                             byteLimit: Int = VaultNoteDocument.byteLimit) -> VaultNoteDocument {
        let (text, truncated) = truncate(rawText, byteLimit: byteLimit)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let front = VaultChunker.frontmatter(lines)
        let frontmatterLines: [String] = front.lineCount > 1
            ? Array(lines[1..<(front.lineCount - 1)])
            : []

        var blocks: [VaultNoteBlock] = []
        var firstH1: String?
        var inCode = false
        var lineNumber = front.lineCount

        for line in lines.dropFirst(front.lineCount) {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode {
                // Verbatim, indentation included: a code block stripped of its markdown
                // is a code block that no longer compiles.
                blocks.append(VaultNoteBlock(id: blocks.count, kind: .code, text: line,
                                             line: lineNumber))
                continue
            }
            if trimmed.isEmpty { continue }
            blocks.append(block(id: blocks.count, line: line, trimmed: trimmed,
                                lineNumber: lineNumber, firstH1: &firstH1))
        }

        return VaultNoteDocument(
            path: path,
            title: VaultChunker.title(relativePath: path, frontmatterTitle: front.title,
                                      firstHeading: firstH1),
            frontmatter: frontmatterLines,
            blocks: blocks,
            wikiTargets: VaultWikiLink.targets(in: text),
            truncated: truncated,
            modified: modified)
    }

    /// The first `byteLimit` UTF-8 bytes, cut on a CHARACTER boundary.
    ///
    /// Cutting on a byte boundary would be how a reader gets a replacement glyph in the
    /// middle of an Italian street name.
    public static func truncate(_ text: String, byteLimit: Int) -> (String, Bool) {
        guard text.utf8.count > byteLimit else { return (text, false) }
        var out = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            if used + width > byteLimit { break }
            out.append(character)
            used += width
        }
        return (out, true)
    }

    private static func block(id: Int, line: String, trimmed: String, lineNumber: Int,
                              firstH1: inout String?) -> VaultNoteBlock {
        let targets = VaultWikiLink.targets(in: line)

        if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "-" }) {
            return VaultNoteBlock(id: id, kind: .rule, text: "", line: lineNumber)
        }
        let hashes = trimmed.prefix { $0 == "#" }.count
        if hashes >= 1, hashes <= 6, trimmed.dropFirst(hashes).hasPrefix(" ") {
            let body = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
            if hashes == 1, firstH1 == nil { firstH1 = body }
            return VaultNoteBlock(id: id, kind: .heading(level: hashes), text: body,
                                  wikiTargets: targets, line: lineNumber)
        }
        if trimmed.hasPrefix("> ") || trimmed == ">" {
            return VaultNoteBlock(id: id, kind: .quote,
                                  text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces),
                                  wikiTargets: targets, line: lineNumber)
        }
        if let body = bulletBody(trimmed) {
            let depth = indentDepth(line)
            if let box = checkbox(body) {
                return VaultNoteBlock(id: id, kind: .checkbox(depth: depth, checked: box.checked),
                                      text: box.text, wikiTargets: targets, line: lineNumber)
            }
            return VaultNoteBlock(id: id, kind: .bullet(depth: depth), text: body,
                                  wikiTargets: targets, line: lineNumber)
        }
        return VaultNoteBlock(id: id, kind: .paragraph, text: trimmed, wikiTargets: targets,
                              line: lineNumber)
    }

    /// A bullet or numbered-list line's body, or nil when the line is neither.
    static func bulletBody(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty, trimmed.dropFirst(digits.count).hasPrefix(". ") {
            return String(trimmed.dropFirst(digits.count + 2))
        }
        return nil
    }

    /// A task box at the head of a bullet body: whether it is ticked, and the text after
    /// it. Nil when the bullet is an ordinary one.
    static func checkbox(_ body: String) -> (checked: Bool, text: String)? {
        guard body.count >= 3, body.hasPrefix("[") else { return nil }
        let mark = body[body.index(body.startIndex, offsetBy: 1)]
        guard body[body.index(body.startIndex, offsetBy: 2)] == "]" else { return nil }
        let checked: Bool
        switch mark {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        let rest = String(body.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return (checked, rest)
    }

    /// Indent depth by leading whitespace: a tab, or every two spaces, is one level.
    /// The vault's own notes use tabs; a markdown editor produces two spaces.
    static func indentDepth(_ line: String) -> Int {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return min(indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2, 4)
    }
}
