import Foundation

// A `[[wiki link]]` IN A CHAT REPLY, made tappable.
//
// ## The problem
//
// The agent writes vault links the way the vault writes them, so a reply routinely
// names `[[todo-list/Strands/Strands-System]]`. Both markdown renderers hand their
// inline fragments to Foundation's parser, which knows `[text](url)` and knows nothing
// about double brackets, so the link arrived as literal brackets around a path: the one
// part of a reply that names a real file on the device, and the one part you could not
// act on.
//
// ## Why this is a rewrite and not a renderer change
//
// The obvious fix is to teach the renderer about the syntax. There are TWO renderers —
// `MarkdownInline` (UIKit, `NSAttributedString`) on iOS and `MacMarkdownBlock.inline`
// (`AttributedString`) on macOS — and teaching both means two scanners, two link
// attributions, and two chances to disagree about what `[[a#b|c]]` means.
//
// So instead the wiki link is rewritten into a link the parsers ALREADY render, before
// either of them sees it: `[[todo-list/X|alias]]` becomes `[alias](jesse://wiki?target=todo-list/X)`.
// One pure function, one scanner, two callers, and the tap handling is the
// `onOpenURL` both apps already have for `jesse://note`.
//
// ## Why a second host and not `jesse://note`
//
// `jesse://note?path=…` carries a path that ALREADY EXISTS: it is minted from a
// citation or a search hit, which resolved a file before building the URL. A wiki
// target has not been resolved and may resolve to nothing — the whole point of the
// three-step resolver is that `[[Overview]]` on a vault with two of them is an honest
// nil. Folding the two into one host would mean either resolving at render time (an
// index query per link, on the main actor, while a reply streams) or teaching the note
// route to sometimes mean "a guess". A second host keeps the citation path exactly as
// it was and says out loud that this one needs resolving.

/// A tap on a wiki link in a rendered reply: the TARGET, not a path.
public struct VaultWikiRoute: Hashable, Sendable, Identifiable {
    /// The normalized wiki target, alias and `#heading` dropped — what
    /// `VaultIndex.resolve(target:)` takes.
    public let target: String

    public init(target: String) {
        self.target = VaultWikiLink.normalized(target)
    }

    public var id: String { target }

    /// The scheme the app already registers. Reusing it is deliberate: a second scheme
    /// would be a second Info.plist entry, on two platforms, for a link that never
    /// leaves the app.
    public static let urlScheme = VaultNoteRoute.urlScheme
    public static let urlHost = "wiki"

    /// `jesse://wiki?target=todo-list/Strands/Strands-System`
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = Self.urlHost
        components.queryItems = [URLQueryItem(name: "target", value: target)]
        return components.url ?? URL(string: "\(Self.urlScheme)://\(Self.urlHost)")!
    }

    /// The route a `jesse://wiki?…` URL names, or nil for any other URL — including
    /// `jesse://note` and `jesse://share-audio`, neither of which this may claim.
    public static func parse(_ url: URL) -> VaultWikiRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == urlScheme,
              components.host?.lowercased() == urlHost
        else { return nil }
        guard let target = (components.queryItems ?? [])
            .first(where: { $0.name == "target" })?.value,
              !VaultWikiLink.normalized(target).isEmpty
        else { return nil }
        return VaultWikiRoute(target: target)
    }
}

/// The rewrite itself.
public enum VaultWikiMarkdown {

    /// One inline markdown fragment with every `[[wiki link]]` turned into a tappable
    /// markdown link.
    ///
    /// The label is the ALIAS when the link has one and the target's last path component
    /// otherwise, because a chat reply is a column of text about 30 characters wide and
    /// `todo-list/Projects/Tag1/Scolta/Engineering/Composer-Advisory-Blocking-Runbook`
    /// is not a label. The `#heading` is dropped from the label for the same reason and
    /// from the target because the resolver takes a file, not a section.
    ///
    /// Pure, total, and loss free: a fragment with no wiki link comes back identical,
    /// and an UNCLOSED `[[` is left exactly as it was rather than swallowing the rest of
    /// the line. A reply that mentions brackets must not lose its text to this.
    public nonisolated static func linked(_ text: String) -> String {
        guard text.contains("[[") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[[") {
            guard let close = rest[open.upperBound...].range(of: "]]") else { break }
            let inner = rest[open.upperBound..<close.lowerBound]
            let target = VaultWikiLink.normalized(String(inner))
            if target.isEmpty {
                // `[[]]`, or a target that normalizes away. Left verbatim: it is not a
                // link, and rewriting it to an empty one would delete the characters.
                out += rest[rest.startIndex..<close.upperBound]
            } else {
                out += rest[rest.startIndex..<open.lowerBound]
                out += "[\(escaped(label(for: String(inner))))](\(VaultWikiRoute(target: target).url.absoluteString))"
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }

    /// What the link reads as: the alias, else the target's file name.
    public nonisolated static func label(for rawInner: String) -> String {
        if let pipe = rawInner.firstIndex(of: "|") {
            let alias = rawInner[rawInner.index(after: pipe)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty { return alias }
        }
        let target = VaultWikiLink.normalized(rawInner)
        return VaultWikiLink.basename(target)
    }

    /// Markdown link text cannot carry a bare `[` or `]`, and a vault note is entitled
    /// to have one in its name. Escaped rather than stripped: the label is what the
    /// reader sees, and silently renaming a note in a reply is worse than a backslash
    /// the parser eats.
    nonisolated static func escaped(_ label: String) -> String {
        var out = ""
        for character in label {
            if character == "[" || character == "]" || character == "\\" { out.append("\\") }
            out.append(character)
        }
        return out
    }
}

// MARK: - Following one

/// **What tapping a wiki link does**, in one place, for both shells.
///
/// Resolution is not free and it is not synchronous: it is an index query, and on a
/// device that has never opened the Vault tab it is a walk of the folder. So it cannot
/// happen while the reply is being rendered — a reply streams, and an index query per
/// link per redraw is the kind of thing that turns a chat into a slideshow. It happens
/// on the TAP, once, which is also the only moment the answer matters.
///
/// A target that resolves to nothing, or to more than one file, opens NOTHING and says
/// so with the reader's own sentence. It deliberately does not fall back to starting a
/// conversation about the link: the user asked to read a note, and a turn they did not
/// ask for is a worse answer than "that note is not on this device".
@MainActor
@Observable
public final class VaultWikiOpener {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    /// The note to present, once a tap has resolved.
    public var opened: VaultNoteRoute?

    /// The one line about a tap that resolved to nothing. Cleared by the next tap and
    /// by the alert's dismissal.
    public var missing: String?

    /// A resolve is in flight. Held so a second tap cannot start a second one.
    public private(set) var isResolving = false

    private let source: VaultIndexSource

    public init(source: VaultIndexSource = .shared) {
        self.source = source
    }

    /// Resolve `route` against the copy of the vault on this device and either open the
    /// note or explain why it could not.
    public func follow(_ route: VaultWikiRoute) async {
        guard !isResolving else { return }
        isResolving = true
        defer { isResolving = false }
        missing = nil
        let target = route.target
        let source = self.source
        // OFF THE MAIN ACTOR: an index query, and on a cold index a walk of the folder.
        let path = await Task.detached { () -> String? in
            guard source.folderStatus.isReady else { return nil }
            if let resolved = try? source.index()?.resolve(target: target) { return resolved }
            // A COLD INDEX is worth one walk: the app may never have been on the Vault
            // tab, and "open the note" must not answer "index the vault first". The same
            // fallback `VaultLocalNoteProvider` pays for the day screen's notes.
            guard let all = try? source.vaultFolder.withAccess({
                VaultScanner().scan(root: $0).files.map(\.relativePath)
            }) else { return nil }
            return VaultWikiLink.resolve(target: target, among: all)
        }.value
        if let path {
            opened = VaultNoteRoute(path: path)
        } else {
            missing = VaultWikiLink.missingCaption(targets: [target])
        }
    }
}
