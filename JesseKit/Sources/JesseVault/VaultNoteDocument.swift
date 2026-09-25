import Foundation
import JesseMarkdown

// ONE NOTE, READY TO DRAW.
//
// The app already has two markdown renderers — the iPhone's `NSAttributedString` path for
// assistant replies, and `MacMarkdownView` on the Mac — and NEITHER is used here, for one
// reason that is worth stating plainly rather than hiding in a commit message:
//
//     A vault note's most important construct is `[[a wiki link]]`, and neither renderer
//     knows what one is. Handed a note, both draw literal double brackets and give the
//     view no way to know a link was there, which is exactly the argument
//     `TodayNoteMarkdown` already makes for the day file's notes. A reader whose links are
//     not links is a reader you cannot follow a thought through.
//
// Both renderers also live where this target cannot reach them (one is in the iOS app
// target, the other in the Mac app target) and this target depends on nothing by design.
//
// WHAT CHANGED, AND WHY IT HAD TO. The first version of this file was a line-per-block
// model: every non-blank line was its own block. That proved a reader could exist and then
// failed every real note opened through it — a soft-wrapped paragraph came out as a stack
// of short lines, a numbered list lost its numbers, a table came out as rows of pipe
// characters, a callout came out as a quote with `[!note]` showing. The grammar now lives
// in `JesseMarkdown`, which knows nothing about vaults, and this file is what sits ON TOP
// of it: frontmatter, wiki targets, and the read-only task box. One copy of every rule.
//
// Pure. A document is decided from a path and a string, so every rule here is asserted
// directly rather than read off a screenshot.

/// One drawable block of a note.
public struct VaultNoteBlock: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case bullet(depth: Int)
        /// A numbered item. `number` is what RENDERS — see `MarkdownBlockParser`.
        case ordered(depth: Int, number: Int)
        /// A `- [ ] ` / `- [x] ` line. Drawn as a GLYPH and never as a control: this is
        /// somebody's note, opened read-only, and a tappable box would promise a write
        /// the offline reader does not do.
        case checkbox(depth: Int, checked: Bool)
        case quote
        /// `> [!warning] Mind the arch`. The type is lowercased and mapped to a symbol and
        /// a tint by `VaultCalloutStyle`; an unknown type gets the note style rather than
        /// nothing, because a callout nobody styled is still a callout.
        case callout(type: String, title: String)
        case code
        case rule
        case table(headers: [String], rows: [[String]], alignments: [TableAlignment])
        /// `![alt](target)`. The target is NAMED, never fetched — see the reader.
        case image(alt: String, target: String)
        case paragraph
    }

    /// Position in the note — the only stable identity a block has, since two identical
    /// lines are two blocks and keying by text would collapse them.
    public let id: Int
    public let kind: Kind
    /// The text to draw. Markdown decoration is LEFT IN for inline rendering (emphasis,
    /// links) except that a checkbox's own `[ ]` marker is removed, having become a glyph,
    /// and a construct's own markers (`#`, `>`, `-`, the fences) are gone.
    public let text: String
    /// The wiki targets this block carries, in source order. Table cells count.
    public let wikiTargets: [String]
    /// The 1-based line the block came from, so a hit's line can be scrolled to.
    public let line: Int
    /// A code block's language, when the fence named one.
    ///
    /// A STORED PROPERTY rather than a payload on `.code`, deliberately: the language is
    /// something a code block HAS, not something that makes it a different kind of block,
    /// and a `.code(language:)` case would mean every `case .code` in the app and its
    /// tests had to learn about a string it does not care about.
    public let language: String?

    public init(id: Int, kind: Kind, text: String, wikiTargets: [String] = [], line: Int = 0,
                language: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.wikiTargets = wikiTargets
        self.line = line
        self.language = language
    }

    /// Every string in this block that can carry inline markdown, in source order: the
    /// text, and a table's headers and cells.
    ///
    /// The reader asks for this rather than reaching into the kind, so a link inside a
    /// table cell is a link like any other and the "not in this copy of the vault" caption
    /// notices it.
    public var inlineTexts: [String] {
        guard case .table(let headers, let rows, _) = kind else { return [text] }
        return headers + rows.flatMap { $0 }
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
    /// The note's own lines, as read (after any truncation), so the RAW view can show the
    /// file as text with line numbers without re-reading or re-splitting it. Frontmatter
    /// included: in raw, the file is the file.
    public let rawLines: [String]
    /// How many CriticMarkup marks are waiting in this note: the count the reader offers to
    /// send for review, and the reason it offers at all.
    ///
    /// Computed ONCE, at parse, over the same block texts the renderer scans and with the
    /// same scanner, so the number and the page cannot tell two stories. Not a computed
    /// property: the reader's body reads it, and a full scan of a 200 KB note on every
    /// evaluation of that body would be a scroll the annotations feature paid for.
    ///
    /// Defaulted, so a hand-built document (a test, a preview) is unchanged.
    public let annotationCount: Int

    public init(path: String, title: String, frontmatter: [String], blocks: [VaultNoteBlock],
                wikiTargets: [String], truncated: Bool, modified: Date? = nil,
                rawLines: [String] = [], annotationCount: Int = 0) {
        self.path = path
        self.title = title
        self.frontmatter = frontmatter
        self.blocks = blocks
        self.wikiTargets = wikiTargets
        self.truncated = truncated
        self.modified = modified
        self.rawLines = rawLines
        self.annotationCount = annotationCount
    }

    /// The file's name, which is what a title bar shows. The path is a caption: a vault
    /// path is too long to be a heading.
    public var fileName: String { VaultWikiLink.basename(path) }

    /// Notes are read whole and drawn whole, so there has to be a ceiling. 256 KB is about
    /// four times the largest note in this vault and still renders without a visible
    /// pause; beyond it the reader shows the first 256 KB and SAYS SO, because silently
    /// showing two thirds of a note is the kind of quiet lie that costs a reader an
    /// afternoon.
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

        let source = MarkdownBlockParser.parse(lines: Array(lines.dropFirst(front.lineCount)),
                                               firstLine: front.lineCount + 1)
        var blocks: [VaultNoteBlock] = []
        blocks.reserveCapacity(source.count)
        var firstH1: String?
        for block in source {
            let converted = vaultBlock(block, id: blocks.count)
            if case .heading(let level) = converted.kind, level == 1, firstH1 == nil {
                firstH1 = converted.text
            }
            blocks.append(converted)
        }

        return VaultNoteDocument(
            path: path,
            title: VaultChunker.title(relativePath: path, frontmatterTitle: front.title,
                                      firstHeading: firstH1),
            frontmatter: frontmatterLines,
            blocks: blocks,
            wikiTargets: VaultWikiLink.targets(in: text),
            truncated: truncated,
            modified: modified,
            rawLines: lines,
            annotationCount: VaultAnnotationMarkup.count(in: markable(blocks)))
    }

    /// Every string in this note that can carry a mark.
    ///
    /// A code block's text is EXCLUDED, and for the reason its links are: a brace inside a
    /// fence is a character somebody typed, the renderer draws it as code rather than as a
    /// mark, and counting it would offer to send a Blade template for review.
    static func markable(_ blocks: [VaultNoteBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            if case .code = block.kind { return [] }
            return block.inlineTexts
        }
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

    /// One generic block as a vault block: the task box recognised, the wiki targets
    /// gathered, the language carried.
    static func vaultBlock(_ block: MarkdownSourceBlock, id: Int) -> VaultNoteBlock {
        switch block.kind {
        case .paragraph:
            return make(id: id, kind: .paragraph, block: block)
        case .heading(let level):
            return make(id: id, kind: .heading(level: level), block: block)
        case .bullet(let depth):
            // THE ONE VAULT CONCEPT THE GRAMMAR DOES NOT HAVE. A `[x]` at the head of a
            // bullet is a task; any other mark is not, and its text keeps the mark rather
            // than losing it to a glyph that would be a lie.
            if let box = checkbox(block.text) {
                return VaultNoteBlock(id: id,
                                      kind: .checkbox(depth: depth, checked: box.checked),
                                      text: box.text,
                                      wikiTargets: VaultWikiLink.targets(in: box.text),
                                      line: block.line)
            }
            return make(id: id, kind: .bullet(depth: depth), block: block)
        case .ordered(let depth, let number):
            return make(id: id, kind: .ordered(depth: depth, number: number), block: block)
        case .quote:
            return make(id: id, kind: .quote, block: block)
        case .callout(let type, let title):
            return VaultNoteBlock(id: id, kind: .callout(type: type, title: title),
                                  text: block.text,
                                  wikiTargets: VaultWikiLink.targets(in: title + " " + block.text),
                                  line: block.line)
        case .code(let language):
            // A code block's own text is NOT scanned for links: `[[this]]` inside a fence
            // is four characters somebody typed, not a link.
            return VaultNoteBlock(id: id, kind: .code, text: block.text, wikiTargets: [],
                                  line: block.line,
                                  language: language.isEmpty ? nil : language)
        case .rule:
            return VaultNoteBlock(id: id, kind: .rule, text: "", line: block.line)
        case .table(let headers, let rows, let alignments):
            let cells = (headers + rows.flatMap { $0 }).joined(separator: "\n")
            return VaultNoteBlock(id: id,
                                  kind: .table(headers: headers, rows: rows,
                                               alignments: alignments),
                                  text: "",
                                  wikiTargets: VaultWikiLink.targets(in: cells),
                                  line: block.line)
        case .image(let alt, let target):
            return VaultNoteBlock(id: id, kind: .image(alt: alt, target: target),
                                  text: alt, line: block.line)
        }
    }

    private static func make(id: Int, kind: VaultNoteBlock.Kind,
                             block: MarkdownSourceBlock) -> VaultNoteBlock {
        VaultNoteBlock(id: id, kind: kind, text: block.text,
                       wikiTargets: VaultWikiLink.targets(in: block.text), line: block.line)
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

    /// The id of the block a search hit at `line` should scroll to: the FIRST block that
    /// starts at or after it, and the last block when the hit is past the end.
    ///
    /// "At or after" rather than "containing" because a hit's line is where the CHUNK
    /// began, which is frequently a heading, and landing on the heading above the answer
    /// is the right place to land.
    public static func blockID(forLine line: Int, in blocks: [VaultNoteBlock]) -> Int? {
        guard !blocks.isEmpty else { return nil }
        if let hit = blocks.first(where: { $0.line >= line }) { return hit.id }
        return blocks.last?.id
    }
}
