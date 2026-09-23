import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

// ONE NOTE, OPEN, FROM THE COPY ON THIS DEVICE.
//
// Everything about this screen is arranged around one honesty requirement: the reader must
// never be able to mistake this for the bridge's view of the vault. It says LOCAL COPY in
// the header, with the file's own modification time beside it, because a synced folder can
// be hours behind the Studio and a note that is quietly stale is worse than a note that is
// visibly old.
//
// Links go through the index's three-step resolution, and the ones that resolve PUSH
// another reader onto the same stack, which is what makes a vault navigable offline: a
// person's file, the project it names, the guideline that project cites, back out again.

/// What the reader is pointing at. A route rather than a document, so the stack can carry
/// half a dozen of them and each loads its own note.
public struct VaultNoteRoute: Hashable, Sendable {
    public let path: String
    /// The line a search hit pointed at, when the reader was opened from one.
    public let line: Int?

    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }
}

/// One note, loaded and resolved.
@MainActor
@Observable
public final class VaultNoteReaderModel {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    public enum State: Equatable, Sendable {
        case loading
        case loaded(VaultNoteDocument)
        case failed(String)
    }

    public private(set) var state: State = .loading
    /// Normalized wiki target to the relative path it resolves to. Targets that resolve to
    /// nothing, or to more than one file, are simply absent.
    public private(set) var resolved: [String: String] = [:]
    /// The note's absolute location, for Reveal. Held only while the folder is reachable.
    public private(set) var fileURL: URL?

    private let source: VaultIndexSource

    public init(source: VaultIndexSource = .shared) {
        self.source = source
    }

    public var document: VaultNoteDocument? {
        if case .loaded(let document) = state { return document }
        return nil
    }

    /// Read and parse one note.
    ///
    /// The read, the parse and the link resolution all happen OFF the main actor: a 200 KB
    /// note is a few milliseconds of parsing, and a few milliseconds on the main actor is a
    /// dropped frame on a push animation.
    public func load(path: String) async {
        state = .loading
        let source = self.source
        let outcome: Result<(VaultNoteDocument, [String: String], URL?), Error> =
            await Task.detached {
                do {
                    let folder = source.vaultFolder
                    let index = try? source.index()
                    let loaded = try folder.withAccess { root -> (VaultNoteDocument, URL?) in
                        let text = try VaultFile(root: root).read(relativePath: path)
                        let url = root.appendingPathComponent(path)
                        let attributes = try? FileManager.default
                            .attributesOfItem(atPath: url.path)
                        let modified = attributes?[.modificationDate] as? Date
                        return (VaultNoteDocument.parse(path: path, text: text,
                                                        modified: modified), url)
                    }
                    var map: [String: String] = [:]
                    for target in loaded.0.wikiTargets {
                        if let resolved = index?.resolve(target: target) {
                            map[target] = resolved
                        }
                    }
                    return .success((loaded.0, map, loaded.1))
                } catch {
                    return .failure(error)
                }
            }.value

        switch outcome {
        case .success(let (document, map, url)):
            resolved = map
            fileURL = url
            state = .loaded(document)
        case .failure(let error):
            state = .failed(VaultIndexer.describe(error))
        }
    }

    /// Show the file in Finder (macOS) or in Files (iOS).
    ///
    /// The iPhone has no reveal API: `shareddocuments://` is what opens the Files app at a
    /// path, and it is best effort — the button says "Show in Files" rather than promising
    /// a particular result. The Mac has a real one.
    public func revealURL() -> URL? {
        guard let fileURL else { return nil }
        #if os(macOS)
        return fileURL
        #else
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = fileURL.path
        return components.url
        #endif
    }

    #if os(macOS)
    /// Select the file in the Finder. AppKit's own call, and the only AppKit in this target
    /// outside the folder picker's panel.
    public func revealInFinder() {
        guard let fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
    #endif
}

/// The note, rendered.
public struct VaultNoteReaderView: View {
    private let route: VaultNoteRoute
    @State private var model: VaultNoteReaderModel
    @State private var isFrontmatterExpanded = false
    @Environment(\.openURL) private var openURL
    /// Pushing another note is the STACK's business, not this view's: it is handed a way to
    /// navigate so the same view works in a `NavigationStack`, in a Mac window and in a
    /// preview.
    private let onOpenNote: (VaultNoteRoute) -> Void

    public init(route: VaultNoteRoute,
                model: VaultNoteReaderModel? = nil,
                onOpenNote: @escaping (VaultNoteRoute) -> Void = { _ in }) {
        self.route = route
        _model = State(initialValue: model ?? VaultNoteReaderModel())
        self.onOpenNote = onOpenNote
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                switch model.state {
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .loaded(let document):
                    if !document.frontmatter.isEmpty {
                        frontmatter(document.frontmatter)
                    }
                    if document.truncated {
                        Label("This note is long; only the first \(VaultNoteDocument.byteLimit / 1024) KB is shown.",
                              systemImage: "text.append")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(document.blocks) { block in
                        blockView(block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle(model.document?.fileName ?? VaultWikiLink.basename(route.path))
        .toolbar {
            ToolbarItem {
                Button {
                    reveal()
                } label: {
                    Label(Self.revealLabel, systemImage: "folder")
                }
                .disabled(model.fileURL == nil)
            }
        }
        // EVERY link in this note arrives here. Ours is caught and pushed; anything else
        // (a real http link in a note) falls through to the system exactly as before.
        .environment(\.openURL, OpenURLAction { url in
            guard let path = VaultNoteRenderer.path(fromLinkURL: url) else {
                return .systemAction
            }
            onOpenNote(VaultNoteRoute(path: path))
            return .handled
        })
        .task(id: route.path) { await model.load(path: route.path) }
    }

    static var revealLabel: String {
        #if os(macOS)
        "Reveal in Finder"
        #else
        "Show in Files"
        #endif
    }

    private func reveal() {
        #if os(macOS)
        model.revealInFinder()
        #else
        if let url = model.revealURL() { openURL(url) }
        #endif
    }

    // MARK: - Header

    /// The path, and the two facts that stop this being mistaken for the bridge's copy.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Label(Self.provenance(model.document?.modified), systemImage: "externaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// "Local copy — modified 12 Sept at 09:14". Said on every note, not only a stale one:
    /// a badge that appears sometimes is a badge nobody reads.
    static func provenance(_ modified: Date?) -> String {
        guard let modified else { return "Local copy on this device" }
        return "Local copy — modified \(modified.formatted(date: .abbreviated, time: .shortened))"
    }

    @ViewBuilder
    private func frontmatter(_ lines: [String]) -> some View {
        DisclosureGroup(isExpanded: $isFrontmatterExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Note properties", systemImage: "list.bullet.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: VaultNoteBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch block.kind {
            case .heading(let level):
                Text(inline(block))
                    .font(Self.headingFont(level))
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, level <= 2 ? 8 : 2)
            case .paragraph:
                Text(inline(block))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .bullet(let depth):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(inline(block))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(depth) * 14)
            case .checkbox(let depth, let checked):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // A GLYPH, never a control: this note is open read-only, and a box
                    // that looked tappable would promise a write this screen does not do.
                    Image(systemName: checked ? "checkmark.square" : "square")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(checked ? "Done" : "Not done")
                    Text(inline(block))
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(depth) * 14)
            case .quote:
                HStack(spacing: 8) {
                    Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                    Text(inline(block))
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .code:
                Text(block.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 5))
            case .rule:
                Divider().padding(.vertical, 4)
            }
            if let missing = Self.missingCaption(block, resolved: model.resolved) {
                Text(missing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ block: VaultNoteBlock) -> AttributedString {
        VaultNoteRenderer.attributed(block.text, resolved: model.resolved)
    }

    /// What to say under a block that links a note this vault does not have.
    static func missingCaption(_ block: VaultNoteBlock,
                               resolved: [String: String]) -> String? {
        let missing = VaultNoteRenderer.unresolvedTargets(in: block.text, resolved: resolved)
        guard !missing.isEmpty else { return nil }
        let names = missing.map { VaultWikiLink.basename($0) }.joined(separator: ", ")
        return missing.count == 1
            ? "\(names) is not in this copy of the vault."
            : "Not in this copy of the vault: \(names)."
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

/// One note in a navigation stack of its own, so following a wiki link PUSHES rather than
/// replaces.
///
/// This exists so a shell can present the reader from somewhere that is not the Vault tab —
/// the day screen's "open Today.md" row does exactly that — without the shell having to own
/// a navigation path, a destination and a link callback. Three lines of plumbing in each app
/// instead of a screen in each app.
public struct VaultNoteStack: View {
    private let root: VaultNoteRoute
    /// Dismiss, when this stack is inside a sheet. The button lives HERE rather than in the
    /// shell because the shell would have to wrap this in a second `NavigationStack` to hang
    /// a toolbar on it, and nested stacks are how a toolbar quietly stops rendering.
    private let onDone: (() -> Void)?
    @State private var pushed: [VaultNoteRoute] = []

    public init(path: String, line: Int? = nil, onDone: (() -> Void)? = nil) {
        root = VaultNoteRoute(path: path, line: line)
        self.onDone = onDone
    }

    public var body: some View {
        NavigationStack(path: $pushed) {
            VaultNoteReaderView(route: root) { next in pushed.append(next) }
                .navigationDestination(for: VaultNoteRoute.self) { route in
                    VaultNoteReaderView(route: route) { next in pushed.append(next) }
                }
                .toolbar {
                    if let onDone {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDone)
                        }
                    }
                }
        }
    }
}
