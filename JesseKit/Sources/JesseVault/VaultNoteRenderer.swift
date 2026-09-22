import Foundation

// INLINE TEXT, AND THE ONE CONSTRUCT THAT MAKES A VAULT A VAULT.
//
// A note's line is markdown — emphasis, code spans, ordinary `[text](url)` links — plus
// `[[wiki links]]`, which Foundation's markdown parser has never heard of. So a line is
// SPLIT here into plain runs and link runs, and each run is treated by whoever knows how:
// the plain runs go to `AttributedString(markdown:)` for emphasis, and the link runs
// become links the reader can actually follow.
//
// The split is pure and `Equatable`, which is the point: "the second link in this line
// points at Projects/Perseido" is asserted directly, rather than inferred from whether a
// tap in a screenshot went somewhere.
//
// A LINK THE VAULT CANNOT RESOLVE IS NOT A LINK. It renders as its own words, plainly,
// with the target named underneath — because a tappable link that cannot go anywhere is a
// promise the reader is entitled to be annoyed about, and because "that note does not
// exist yet" is a useful thing to learn while reading.

/// One run of a note's line.
public enum VaultInlineSegment: Equatable, Sendable {
    /// Markdown to be rendered as-is (emphasis, code, ordinary links).
    case text(String)
    /// A `[[wiki link]]`: its normalized target and the words to show for it.
    case wikiLink(target: String, label: String)
}

public enum VaultNoteRenderer {

    /// Split one line into plain runs and wiki-link runs, in source order.
    ///
    /// `[[target|alias]]` shows the ALIAS and points at the target — the alias is what the
    /// writer chose to read well in the sentence. `[[target#heading]]` shows the target
    /// (heading included, as written) and points at the note.
    public static func segments(_ text: String) -> [VaultInlineSegment] {
        var out: [VaultInlineSegment] = []
        var plain = ""
        var rest = Substring(text)

        func flush() {
            guard !plain.isEmpty else { return }
            out.append(.text(plain))
            plain = ""
        }

        while let character = rest.first {
            guard rest.hasPrefix("[[") else {
                plain.append(character)
                rest = rest.dropFirst()
                continue
            }
            guard let close = rest.range(of: "]]") else {
                // An unclosed `[[` is text. Dropping it would silently delete the rest of
                // the line.
                plain.append(contentsOf: rest)
                rest = rest[rest.endIndex...]
                break
            }
            let inner = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound])
            let target = VaultWikiLink.normalized(inner)
            let label = displayLabel(inner)
            if target.isEmpty {
                plain += "[[" + inner + "]]"
            } else {
                flush()
                out.append(.wikiLink(target: target, label: label))
            }
            rest = rest[close.upperBound...]
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

    public static func linkURL(forPath path: String) -> URL? {
        var components = URLComponents()
        components.scheme = linkScheme
        components.host = "open"
        components.path = "/" + path
        return components.url
    }

    /// The relative path a link URL names, or nil when it is not one of ours.
    public static func path(fromLinkURL url: URL) -> String? {
        guard url.scheme == linkScheme else { return nil }
        let path = url.path
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    /// One line as an `AttributedString`: emphasis rendered, resolved wiki links carrying
    /// a tappable URL, unresolved ones plain.
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
                var run = AttributedString(label)
                if let path = resolved[target], let url = linkURL(forPath: path) {
                    run.link = url
                } else {
                    // Plain, and deliberately not styled as disabled: it is ordinary text
                    // now, and the caption under the block says the note is missing.
                    run.inlinePresentationIntent = .emphasized
                }
                out += run
            }
        }
        return out
    }

    /// Inline markdown, whitespace preserved, falling back to plain text when a fragment
    /// does not parse. The same treatment `MacMarkdownView` gives a reply's inline text.
    public static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
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
    /// names.
    public static func unresolvedTargets(in text: String,
                                         resolved: [String: String]) -> [String] {
        segments(text).compactMap { segment in
            guard case .wikiLink(let target, _) = segment, resolved[target] == nil else {
                return nil
            }
            return target
        }
    }
}
