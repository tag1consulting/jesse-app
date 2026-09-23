import Foundation

// WHAT A LINE OF MARKDOWN IS MADE OF, BEFORE ANYBODY DECIDES WHAT IT MEANS.
//
// `AttributedString(markdown:)` handles bold, italic, code spans, strikethrough and
// ordinary `[text](url)` links, and it has never heard of the four constructs an Obsidian
// note leans on hardest: `[[wiki links]]`, `![[embeds]]`, `==highlights==` and `#tags`.
// So a line is SCANNED here first, once, left to right, and cut into spans; whoever owns
// a span's meaning then decides what to do with it. The vault renderer turns a wiki span
// into a tappable link because it knows how to resolve one; this file does not, and that
// is deliberate — nothing here knows a vault exists.
//
// ONE RULE ABOVE ALL THE OTHERS: a code span is opaque. `` `[[not a link]]` `` is a code
// span containing four characters that happen to be brackets, and turning it into a link
// would be the reader helpfully breaking the one construct whose whole purpose is "show
// this exactly as I typed it". The scanner therefore consumes a code span whole, before
// any other rule gets to look inside it.
//
// THE FAST PATH IS THE POINT. The overwhelming majority of a note's lines contain none of
// these constructs, and a scanner that allocated a `String` per character would make the
// reader slower in exchange for features most lines do not use. `mayContainSpans` is one
// pass over the UTF-8 bytes with no allocation at all, and a line that fails it is
// returned whole.

/// One run of a line, as the scanner found it.
public enum MarkdownSpan: Equatable, Sendable {
    /// Ordinary markdown, to be handed to `AttributedString(markdown:)` by whoever owns it.
    case text(String)
    /// A code span INCLUDING its backticks, so it round-trips through the markdown pass
    /// and renders as code. Held as its own span only so nothing else can look inside it.
    case codeSpan(String)
    /// `[[inner]]` — the raw inner text, alias and heading included. Normalizing it is a
    /// vault concept and belongs to the caller.
    case wikiLink(inner: String)
    /// `![[inner]]` — a transclusion. The content is NOT fetched by anybody; it names a
    /// note and links to it.
    case embed(inner: String)
    /// `==inner==`, markers removed.
    case highlight(String)
    /// `#tag`, INCLUDING the leading `#`, which is how a person recognises one.
    case tag(String)
    /// A bare `http://` or `https://` URL that the markdown pass would have left as text.
    case autoLink(String)
    /// `![alt](target)`. The target is NEVER fetched — see `VaultNoteRenderer` for why a
    /// reader that loads pictures is a reader that misses its frame budget.
    case image(alt: String, target: String)
}

public enum MarkdownInline {

    /// Cut one line into spans, in source order.
    ///
    /// Adjacent plain text is one span. An unterminated construct (`[[` with no `]]`, an
    /// opening `==` with no close, an opening backtick with no close) is TEXT, because the
    /// alternative is silently swallowing the rest of the line.
    public static func scan(_ text: String) -> [MarkdownSpan] {
        guard mayContainSpans(text) else {
            return text.isEmpty ? [] : [.text(text)]
        }

        var out: [MarkdownSpan] = []
        var plainStart = text.startIndex
        var i = text.startIndex

        // Plain runs are emitted as SLICES, never built character by character: appending
        // to a `String` once per character is what made the first version of this scanner
        // the most expensive thing in the reader.
        func flush(_ upTo: String.Index) {
            guard plainStart < upTo else { return }
            out.append(.text(String(text[plainStart..<upTo])))
        }

        while i < text.endIndex {
            let character = text[i]
            var consumed: String.Index?

            switch character {
            case "`":
                if let end = codeSpanEnd(text, from: i) {
                    flush(i)
                    out.append(.codeSpan(String(text[i..<end])))
                    consumed = end
                }
            case "!":
                if let found = bracketLink(text, from: text.index(after: i)) {
                    flush(i)
                    out.append(.embed(inner: found.inner))
                    consumed = found.end
                } else if let found = imageLink(text, from: i) {
                    flush(i)
                    out.append(.image(alt: found.alt, target: found.target))
                    consumed = found.end
                }
            case "[":
                if let found = bracketLink(text, from: i) {
                    flush(i)
                    out.append(.wikiLink(inner: found.inner))
                    consumed = found.end
                }
            case "=":
                if let found = highlight(text, from: i) {
                    flush(i)
                    out.append(.highlight(found.inner))
                    consumed = found.end
                }
            case "#":
                if atWordStart(text, i), let end = tagEnd(text, from: i) {
                    flush(i)
                    out.append(.tag(String(text[i..<end])))
                    consumed = end
                }
            case "h":
                if atLineOrWordBoundary(text, i), let end = urlEnd(text, from: i) {
                    flush(i)
                    out.append(.autoLink(String(text[i..<end])))
                    consumed = end
                }
            default:
                break
            }

            if let consumed {
                i = consumed
                plainStart = i
            } else {
                i = text.index(after: i)
            }
        }
        flush(text.endIndex)
        return out
    }

    /// Could this line hold any construct the scanner knows? One pass over the bytes, no
    /// allocation. A `false` here is the line's whole cost.
    ///
    /// `:` stands in for a bare URL's `://`, which is cheaper to look for than `http`.
    public static func mayContainSpans(_ text: String) -> Bool {
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "["), UInt8(ascii: "="), UInt8(ascii: "#"),
                 UInt8(ascii: "`"), UInt8(ascii: ":"):
                return true
            default:
                continue
            }
        }
        return false
    }

    // MARK: - The constructs

    /// The end of the code span opening at `start`, or nil when nothing closes it.
    ///
    /// A run of N backticks is closed by the next run of EXACTLY N, which is CommonMark's
    /// rule and the reason ``` `` a ` b `` ``` works.
    static func codeSpanEnd(_ text: String, from start: String.Index) -> String.Index? {
        var i = start
        var opening = 0
        while i < text.endIndex, text[i] == "`" {
            opening += 1
            i = text.index(after: i)
        }
        while i < text.endIndex {
            guard text[i] == "`" else {
                i = text.index(after: i)
                continue
            }
            var run = 0
            var j = i
            while j < text.endIndex, text[j] == "`" {
                run += 1
                j = text.index(after: j)
            }
            if run == opening { return j }
            i = j
        }
        return nil
    }

    /// A `[[…]]` beginning at `start`, or nil. `start` points at the first `[`.
    static func bracketLink(_ text: String,
                            from start: String.Index) -> (inner: String, end: String.Index)? {
        guard start < text.endIndex, text[start] == "[" else { return nil }
        let second = text.index(after: start)
        guard second < text.endIndex, text[second] == "[" else { return nil }
        let innerStart = text.index(after: second)
        guard innerStart <= text.endIndex,
              let close = text.range(of: "]]", range: innerStart..<text.endIndex) else {
            return nil
        }
        return (String(text[innerStart..<close.lowerBound]), close.upperBound)
    }

    /// An `![alt](target)` beginning at `start`, which points at the `!`. Nil when the
    /// shape is not complete: a half-written image is text, like every other half-written
    /// construct here.
    static func imageLink(_ text: String,
                          from start: String.Index) -> (alt: String, target: String, end: String.Index)? {
        let open = text.index(after: start)
        guard open < text.endIndex, text[open] == "[" else { return nil }
        let altStart = text.index(after: open)
        guard altStart <= text.endIndex,
              let altClose = text.range(of: "]", range: altStart..<text.endIndex) else {
            return nil
        }
        let parenOpen = altClose.upperBound
        guard parenOpen < text.endIndex, text[parenOpen] == "(" else { return nil }
        let targetStart = text.index(after: parenOpen)
        guard targetStart <= text.endIndex,
              let parenClose = text.range(of: ")", range: targetStart..<text.endIndex) else {
            return nil
        }
        return (String(text[altStart..<altClose.lowerBound]),
                String(text[targetStart..<parenClose.lowerBound]),
                parenClose.upperBound)
    }

    /// A `==…==` beginning at `start`, or nil. An empty `====` is not a highlight.
    static func highlight(_ text: String,
                          from start: String.Index) -> (inner: String, end: String.Index)? {
        let second = text.index(after: start)
        guard second < text.endIndex, text[second] == "=" else { return nil }
        let innerStart = text.index(after: second)
        guard innerStart < text.endIndex,
              let close = text.range(of: "==", range: innerStart..<text.endIndex),
              close.lowerBound > innerStart else {
            return nil
        }
        return (String(text[innerStart..<close.lowerBound]), close.upperBound)
    }

    /// The end of the `#tag` at `start`, or nil when what follows is not one.
    ///
    /// Obsidian's own rule, and the reason it exists: a tag may hold letters, digits, `/`,
    /// `_` and `-`, but it may not be ALL digits. Without that last clause "the trap PR
    /// #33 already paid for" acquires a tag, and so does every issue number anybody ever
    /// writes down.
    static func tagEnd(_ text: String, from start: String.Index) -> String.Index? {
        var i = text.index(after: start)
        var sawNonDigit = false
        var length = 0
        while i < text.endIndex {
            let character = text[i]
            if character.isLetter || character == "/" || character == "_" || character == "-" {
                sawNonDigit = true
            } else if !character.isNumber {
                break
            }
            length += 1
            i = text.index(after: i)
        }
        guard length > 0, sawNonDigit else { return nil }
        return i
    }

    /// The end of the bare URL at `start`, or nil. Trailing sentence punctuation is left
    /// OUT of the link: "see https://example.invalid/x." ends in a full stop, and a link
    /// that swallowed it would point somewhere that does not exist.
    static func urlEnd(_ text: String, from start: String.Index) -> String.Index? {
        let rest = text[start...]
        let scheme: String
        if rest.hasPrefix("https://") { scheme = "https://" }
        else if rest.hasPrefix("http://") { scheme = "http://" }
        else { return nil }

        var i = text.index(start, offsetBy: scheme.count)
        var end = i
        while i < text.endIndex {
            let character = text[i]
            if character.isWhitespace || character == "<" || character == ">" { break }
            i = text.index(after: i)
            if !Self.trailingPunctuation.contains(character) { end = i }
        }
        return end > text.index(start, offsetBy: scheme.count) ? end : nil
    }

    static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "'", "\""]

    /// Is `index` at the start of the line or just after whitespace or an opening bracket?
    /// A `#` in the middle of a word ("C#") is not a tag, and neither is the one in a URL
    /// fragment.
    static func atWordStart(_ text: String, _ index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        let before = text[text.index(before: index)]
        return before.isWhitespace || before == "(" || before == "["
    }

    /// The STRICTER test, and only bare URLs use it: the line start, or whitespace.
    ///
    /// An opening parenthesis does not count, and that is the whole point. The target of
    /// an ordinary markdown link sits inside one — `[a link](https://example.invalid/x)` —
    /// and treating it as a bare URL cuts the link in half before
    /// `AttributedString(markdown:)` ever sees it, so the reader draws the brackets and
    /// the parentheses as literal text. That is what it did, and it is what the
    /// screenshot of the every-construct fixture caught.
    static func atLineOrWordBoundary(_ text: String, _ index: String.Index) -> Bool {
        guard index > text.startIndex else { return true }
        return text[text.index(before: index)].isWhitespace
    }
}
