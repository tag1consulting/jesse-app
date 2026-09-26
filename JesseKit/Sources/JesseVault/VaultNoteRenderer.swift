import Foundation
import SwiftUI
import JesseMarkdown

// INLINE TEXT, AND THE CONSTRUCTS THAT MAKE A VAULT A VAULT.
//
// A note's line is markdown — emphasis, code spans, ordinary `[text](url)` links — plus
// four things Foundation's markdown parser has never heard of: `[[wiki links]]`,
// `![[embeds]]`, `==highlights==` and `#tags`. So a line is SPLIT here into runs and each
// run is treated by whoever knows how: the plain runs go to `AttributedString(markdown:)`
// for emphasis, and the rest become what they are.
//
// The scanning is `JesseMarkdown`'s and knows nothing about a vault. What is here is the
// half that does: which target a `[[link]]` names, whether that note exists on this
// device, and what a link that does not resolve should look like.
//
// The split is pure and `Equatable`, which is the point: "the second link in this line
// points at Projects/Perseido" is asserted directly, rather than inferred from whether a
// tap in a screenshot went somewhere.
//
// A LINK THE VAULT CANNOT RESOLVE IS NOT A LINK. It renders as its own words, plainly,
// with the target named underneath — because a tappable link that cannot go anywhere is a
// promise the reader is entitled to be annoyed about, and because "that note does not
// exist yet" is a useful thing to learn while reading.
//
// A MARK IS SOMETHING SOMEBODY LEFT FOR SOMEBODY. The five CriticMarkup forms (a
// highlight, a comment, a rewrite, an insertion, a deletion) are the only constructs in a
// note that are addressed to a reader rather than describing the world, and until now they
// rendered as their own braces and tildes: readable, and invisible. They are styled here,
// by colour alone, so a glance at a marked-up note shows what was marked and a rewrite
// shows which half is the old wording and which is the proposed one.
//
// AN IMAGE IS NAMED, NEVER LOADED. Not a network fetch, not a file read, not a thumbnail:
// the reader's whole budget is "open a 250 KB note without a visible pause", and a picture
// is the one thing in a note that can cost a second. The alt text and the target are shown
// and the reader can decide.

/// One run of a note's line.
public enum VaultInlineSegment: Equatable, Sendable {
    /// Markdown to be rendered as-is (emphasis, code, ordinary links).
    case text(String)
    /// A `[[wiki link]]`: its normalized target and the words to show for it.
    case wikiLink(target: String, label: String)
    /// A `![[embed]]`. Resolved and opened exactly as a wiki link is; the embedded note's
    /// CONTENT is not inlined, because inlining it is a second file read per embed and
    /// a cycle away from a reader that never finishes loading.
    case embed(target: String, label: String)
    /// `==highlighted==` words.
    case highlight(String)
    /// A `#tag`, leading hash included. Shown, never tappable: there is no tag index on
    /// this device to send anybody to.
    case tag(String)
    /// A bare URL the markdown pass would have left as plain text.
    case autoLink(String)
    /// An inline `![alt](target)`, named rather than loaded.
    case image(alt: String, target: String)
    /// CriticMarkup `{==marked==}` words.
    case criticHighlight(String)
    /// CriticMarkup `{>>a note<<}`, its text as written, the `Jesse ` prefix of a reply
    /// included, because who wrote it is part of what it says.
    case criticComment(String)
    /// CriticMarkup `{~~old~>new~~}`: both halves, so the reader can show which is which.
    case criticSubstitution(old: String, new: String)
    /// CriticMarkup `{++added++}` words.
    case criticInsertion(String)
    /// CriticMarkup deleted words, markers removed.
    case criticDeletion(String)
}

public enum VaultNoteRenderer {

    /// Split one line into its runs, in source order.
    ///
    /// `[[target|alias]]` shows the ALIAS and points at the target — the alias is what the
    /// writer chose to read well in the sentence. `[[target#heading]]` shows the target
    /// (heading included, as written) and points at the note.
    public static func segments(_ text: String) -> [VaultInlineSegment] {
        var out: [VaultInlineSegment] = []
        var plain = ""

        func flush() {
            guard !plain.isEmpty else { return }
            out.append(.text(plain))
            plain = ""
        }

        for span in MarkdownInline.scan(text) {
            switch span {
            case .text(let s):
                plain += s
            case .codeSpan(let s):
                // Backticks and all, straight back into the markdown run: it renders as
                // code, and nothing above ever looked inside it.
                plain += s
            case .wikiLink(let inner):
                let target = VaultWikiLink.normalized(inner)
                if target.isEmpty {
                    plain += "[[" + inner + "]]"
                } else {
                    flush()
                    out.append(.wikiLink(target: target, label: displayLabel(inner)))
                }
            case .embed(let inner):
                let target = VaultWikiLink.normalized(inner)
                if target.isEmpty {
                    plain += "![[" + inner + "]]"
                } else {
                    flush()
                    out.append(.embed(target: target, label: displayLabel(inner)))
                }
            case .highlight(let s):
                flush()
                out.append(.highlight(s))
            case .tag(let s):
                flush()
                out.append(.tag(s))
            case .autoLink(let s):
                flush()
                out.append(.autoLink(s))
            case .image(let alt, let target):
                flush()
                out.append(.image(alt: alt, target: target))
            case .criticHighlight(let s):
                flush()
                out.append(.criticHighlight(s))
            case .criticComment(let s):
                flush()
                out.append(.criticComment(s))
            case .criticSubstitution(let old, let new):
                flush()
                out.append(.criticSubstitution(old: old, new: new))
            case .criticInsertion(let s):
                flush()
                out.append(.criticInsertion(s))
            case .criticDeletion(let s):
                flush()
                out.append(.criticDeletion(s))
            }
        }
        flush()
        return out
    }

    /// The words a wiki link shows: its alias when it has one, else the target as written
    /// minus its path, so a line is not four folder names wide.
    public static func displayLabel(_ inner: String) -> String {
        if let pipe = inner.firstIndex(of: "|") {
            let alias = inner[inner.index(after: pipe)...].trimmingCharacters(in: .whitespaces)
            if !alias.isEmpty { return alias }
        }
        let head = inner.split(separator: "|").first.map(String.init) ?? inner
        let leaf = head.split(separator: "/").last.map(String.init) ?? head
        return leaf.trimmingCharacters(in: .whitespaces)
    }

    /// The URL a resolved wiki link carries, so the reader can intercept a tap without
    /// every block needing a closure of its own.
    ///
    /// A private scheme, never registered with the system: it exists only to be caught by
    /// the reader's own `OpenURLAction`, and anything it does not catch falls through to
    /// the system exactly as before.
    public static let linkScheme = "jesse-vault-note"

    /// What an embed shows before its label.
    ///
    /// A character rather than an SF Symbol, and that is a deliberate trade: a symbol
    /// would mean an `NSTextAttachment`, which would mean UIKit and AppKit inside a pure,
    /// unit-tested function. U+29C9 is not in the system font on either platform but both
    /// fall back to Apple Symbols for it, which was measured with CoreText rather than
    /// assumed.
    public static let embedGlyph = "⧉\u{00A0}"

    /// Likewise for an image: named, not drawn. U+25A8, measured the same way — an SF
    /// Symbol's private-use codepoint falls back to the LastResort font in plain text,
    /// which draws a box, so a symbol is not an option inside an `AttributedString`.
    public static let imageGlyph = "▨"

    /// What a CriticMarkup comment shows before its words, with the no-break space that
    /// keeps the two on one line.
    ///
    /// Chosen the way `embedGlyph` was, and measured rather than assumed: CoreText reports
    /// U+275D present in the system font itself at both the body and the caption size, on
    /// macOS and on iOS, so unlike the other two glyphs here it needs no fallback font at
    /// all. An SF Symbol is still not an option: a symbol's private-use codepoint falls
    /// back to LastResort inside plain text and draws a box.
    public static let commentGlyph = "❝\u{00A0}"

    /// Is this comment an answer rather than a question?
    ///
    /// The rule is the prefix and nothing cleverer, because the file is the only record: a
    /// note carries no authorship, so "who wrote this mark" can only be what the mark says.
    /// A reply is tinted differently and is otherwise the same comment.
    public static func isReply(_ comment: String) -> Bool {
        comment.hasPrefix("Jesse ")
    }

    /// The opacity every mark's background is drawn at, in BOTH appearances.
    ///
    /// One number, for the reason written on the highlight case below: a tint that is
    /// legible over light text and a solid bar over dark text is a tint somebody turns off.
    static let markOpacity = 0.2

    public static func linkURL(forPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = linkScheme
        components.host = "open"
        components.path = "/" + path
        return components.url
    }

    /// The host of a link that names a wiki TARGET rather than a path: one in the Studio's
    /// copy of a note that the local index could not resolve, which the Studio resolves
    /// when it is tapped.
    static let targetHost = "wiki"

    public static func linkURL(forTarget target: String) -> URL? {
        var components = URLComponents()
        components.scheme = linkScheme
        components.host = targetHost
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        return components.url
    }

    /// The wiki target a link URL names, or nil when it names a path or is not ours.
    public static func target(fromLinkURL url: URL) -> String? {
        guard url.scheme == linkScheme, url.host == targetHost else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "target" })?.value
    }

    /// The relative path a link URL names, or nil when it is not one of ours.
    public static func path(fromLinkURL url: URL) -> String? {
        guard url.scheme == linkScheme, url.host != targetHost else { return nil }
        let path = url.path
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// One line as an `AttributedString`: emphasis rendered, resolved wiki links and
    /// embeds carrying a tappable URL, unresolved ones plain.
    ///
    /// `resolved` maps a normalized target to the relative path it resolves to. A target
    /// absent from the map is a link to a note that is not in this vault.
    public static func attributed(_ text: String,
                                  resolved: [String: String]) -> AttributedString {
        var out = AttributedString()
        for segment in segments(text) {
            switch segment {
            case .text(let markdown):
                out += inline(markdown)
            case .wikiLink(let target, let label):
                out += link(label: label, target: target, resolved: resolved)
            case .embed(let target, let label):
                out += link(label: embedGlyph + label, target: target, resolved: resolved)
            case .highlight(let s):
                var run = AttributedString(s)
                // 30 percent, and the same 30 percent in both appearances: a highlight
                // that is legible in light mode and a solid yellow bar in dark mode is a
                // highlight that has to be turned off.
                run.backgroundColor = .yellow.opacity(0.3)
                out += run
            case .tag(let s):
                var run = AttributedString(s)
                // Colour only. NOT a font: this run can sit inside a heading, and an
                // explicit font attribute would override the heading's own and leave one
                // word of it at body size.
                run.foregroundColor = .secondary
                out += run
            case .autoLink(let s):
                var run = AttributedString(s)
                run.link = URL(string: s)
                out += run
            case .image(let alt, let target):
                out += AttributedString(imageCaption(alt: alt, target: target))
            case .criticHighlight(let s):
                var run = AttributedString(s)
                run.backgroundColor = .yellow.opacity(0.3)
                out += run
            case .criticComment(let s):
                var run = AttributedString(commentGlyph + s)
                // Blue for an answer, orange for the question it answers, so a note that
                // has been gone through reads as a conversation rather than as a list.
                run.backgroundColor = (isReply(s) ? Color.blue : .orange)
                    .opacity(markOpacity)
                run.foregroundColor = .secondary
                run.inlinePresentationIntent = .emphasized
                out += run
            case .criticSubstitution(let old, let new):
                out += struck(old)
                // A NO-BREAK space, so a rewrite never wraps between the words being
                // replaced and the words replacing them.
                out += AttributedString("\u{00A0}")
                out += added(new)
            case .criticInsertion(let s):
                out += added(s)
            case .criticDeletion(let s):
                out += struck(s)
            }
        }
        return out
    }

    /// An inline image as words. Named, not loaded.
    public static func imageCaption(alt: String, target: String) -> String {
        let name = alt.trimmingCharacters(in: .whitespaces).isEmpty
            ? VaultWikiLink.basename(target)
            : alt
        return imageGlyph + "\u{00A0}" + name
    }

    /// Words on their way OUT: struck through and red, which is the same treatment a
    /// deletion mark gets and the old half of a rewrite gets, because they mean the same
    /// thing.
    ///
    /// Colour and a line, never a font: a mark can sit inside a heading, and an explicit
    /// font attribute would leave one word of that heading at body size. The same reason
    /// the `.tag` case gives.
    private static func struck(_ s: String) -> AttributedString {
        var run = AttributedString(s)
        run.strikethroughStyle = .single
        run.foregroundColor = .red
        return run
    }

    /// Words on their way IN: italic on green, which is what an insertion and the new half
    /// of a rewrite both are. `inlinePresentationIntent` rather than `.italic()` for the
    /// reason above: it asks for emphasis and leaves the font alone.
    private static func added(_ s: String) -> AttributedString {
        var run = AttributedString(s)
        run.backgroundColor = .green.opacity(markOpacity)
        run.inlinePresentationIntent = .emphasized
        return run
    }

    private static func link(label: String, target: String,
                             resolved: [String: String]) -> AttributedString {
        var run = AttributedString(label)
        // An EMPTY path is a target the Studio resolves on the tap (see `linkURL(forTarget:)`).
        if let path = resolved[target],
           let url = path.isEmpty ? linkURL(forTarget: target) : linkURL(forPath: path) {
            run.link = url
        } else {
            // Plain, and deliberately not styled as disabled: it is ordinary text now,
            // and the caption under the block says the note is missing.
            run.inlinePresentationIntent = .emphasized
        }
        return run
    }

    /// Inline markdown, whitespace preserved, falling back to plain text when a fragment
    /// does not parse. The same treatment `MacMarkdownView` gives a reply's inline text.
    ///
    /// THE FAST PATH IS WHY THE READER IS NOT SLOWER than the line-per-block model it
    /// replaced. `AttributedString(markdown:)` is the most expensive thing in the render
    /// pass by a wide margin, and the overwhelming majority of runs in a note contain not
    /// one character it could do anything with. One pass over the bytes decides.
    public static func inline(_ s: String) -> AttributedString {
        guard mayContainMarkdown(s) else { return AttributedString(s) }
        return (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// Could `AttributedString(markdown:)` do anything at all with this run? Emphasis,
    /// code, links, escapes, entities and HTML are the whole list.
    static func mayContainMarkdown(_ s: String) -> Bool {
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "*"), UInt8(ascii: "_"), UInt8(ascii: "`"),
                 UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "\\"),
                 UInt8(ascii: "<"), UInt8(ascii: "&"), UInt8(ascii: "~"),
                 UInt8(ascii: "!"):
                return true
            default:
                continue
            }
        }
        return false
    }

    /// A search snippet as an `AttributedString`, with FTS5's own markers turned into bold
    /// runs and removed from the text.
    public static func snippet(_ raw: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(raw)
        while let open = rest.range(of: VaultSearchHit.markStart) {
            out += AttributedString(String(rest[rest.startIndex..<open.lowerBound]))
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: VaultSearchHit.markEnd) else { break }
            var hit = AttributedString(String(rest[rest.startIndex..<close.lowerBound]))
            hit.inlinePresentationIntent = .stronglyEmphasized
            out += hit
            rest = rest[close.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }

    /// The targets in `text` that `resolved` has no path for — what the block's caption
    /// names. An embed counts: it goes to the same place a link would.
    public static func unresolvedTargets(in text: String,
                                         resolved: [String: String]) -> [String] {
        segments(text).compactMap { segment in
            switch segment {
            case .wikiLink(let target, _), .embed(let target, _):
                return resolved[target] == nil ? target : nil
            default:
                return nil
            }
        }
    }
}
