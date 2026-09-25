import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif
import JesseMarkdown

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
//
// TWO THINGS ABOUT HOW IT DRAWS, and both are performance rather than taste:
//
//   * A `LazyVStack`, not a `VStack`. A 2,400-line note is a couple of thousand blocks,
//     and a `VStack` builds every one of them before the first frame can be shown. Lazily,
//     the cost of opening a note stops depending on how long the note is.
//   * A table is the exception the lazy list cannot cover, because a `Grid` builds all of
//     its cells at once. A table past `VaultTableWindow.initialRows` shows its first rows
//     and a button; see that type for why the number is what it is.

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
    /// How long the last load took, end to end, in milliseconds. Logged rather than shown:
    /// this is the number the performance budget is written against, and it has to be
    /// readable from a device that is not attached to a debugger.
    public private(set) var lastLoadMilliseconds: Double?
    /// Bumped once per finished load. The reader watches THIS rather than `state`:
    /// `.onChange(of:)` compares old against new on every body pass, and `State` carries a
    /// whole `VaultNoteDocument` — a quarter of a megabyte of raw lines — which is not a
    /// thing to run `==` over sixty times a second.
    public private(set) var generation: Int = 0

    /// The note's text as read, and the stamp of the bytes it came from.
    ///
    /// HELD, rather than re-read when a box is tapped, and that is the point of the pair:
    /// a tick is an edit to the text this screen is showing, and the stamp is the proof
    /// that the file still holds exactly that. Re-reading at tap time would tick whatever
    /// arrived since, which is how a tap lands on the wrong line of a note that syncing
    /// has shifted under it.
    public private(set) var text: String = ""
    public private(set) var stamp: VaultFileStamp?
    /// A box that has been tapped and not yet agreed with by the document, by block id.
    /// The glyph follows this while the write is in flight, so the tick is instant and the
    /// truth catches up — or the entry is removed and the glyph goes back.
    public private(set) var optimistic: [Int: Bool] = [:]
    /// What to say under one block, by block id. Only ever set by a tick that failed.
    public private(set) var messages: [Int: String] = [:]

    /// The path this model is showing. Held because a tick and a reload both need it and
    /// only `load` is handed it.
    public private(set) var route: String = ""

    private let source: VaultIndexSource
    private let ticker: VaultNoteTicker

    public init(source: VaultIndexSource = .shared,
                writer: (any VaultNoteWriting)? = nil) {
        self.source = source
        self.ticker = VaultNoteTicker(writer: writer ?? VaultNoteWriter(source: source))
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
        route = path
        state = .loading
        // A strand tick that could not reach the bridge when it was made goes now. Free
        // when the outbox is empty, and never in the way of the read: it is not awaited.
        Task { await StrandTickOutbox.shared.flush() }
        let started = ContinuousClock.now
        let source = self.source
        let outcome = await Self.read(path: path, source: source)

        lastLoadMilliseconds = VaultRenderBenchmark.milliseconds(ContinuousClock.now - started)
        switch outcome {
        case .success(let read):
            let (document, map, url, text, stamp) = read
            resolved = map
            fileURL = url
            self.text = text
            self.stamp = stamp
            optimistic = [:]
            messages = [:]
            state = .loaded(document)
            generation &+= 1
            VaultReaderLog.loaded(path: path, blocks: document.blocks.count,
                                  bytes: document.rawLines.count,
                                  milliseconds: lastLoadMilliseconds ?? 0)
        case .failure(let error):
            state = .failed(VaultIndexer.describe(error))
            generation &+= 1
        }
    }

    /// One coordinated stamped read, parsed and resolved, entirely off the main actor.
    ///
    /// Factored out of `load` because `reload` needs exactly the same work and a second
    /// copy of it is a second place for the parse to drift onto the main actor.
    private static func read(
        path: String, source: VaultIndexSource
    ) async -> Result<(VaultNoteDocument, [String: String], URL?, String, VaultFileStamp), Error> {
        await Task.detached {
            do {
                let folder = source.vaultFolder
                let index = try? source.index()
                let loaded = try folder.withAccess {
                    root -> (VaultNoteDocument, URL?, String, VaultFileStamp) in
                    let read = try VaultFile(root: root).readStamped(relativePath: path)
                    let url = root.appendingPathComponent(path)
                    let attributes = try? FileManager.default
                        .attributesOfItem(atPath: url.path)
                    let modified = attributes?[.modificationDate] as? Date
                    return (VaultNoteDocument.parse(path: path, text: read.text,
                                                    modified: modified),
                            url, read.text, read.stamp)
                }
                var map: [String: String] = [:]
                for target in loaded.0.wikiTargets {
                    if let resolved = index?.resolve(target: target) {
                        map[target] = resolved
                    }
                }
                return .success((loaded.0, map, loaded.1, loaded.2, loaded.3))
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// Read the note again WITHOUT going back to `.loading`.
    ///
    /// What the editor's Save calls on the way out. `load` would blank the screen to a
    /// spinner and animate the whole note back in, which after saving an edit reads as the
    /// app having lost the note for a moment.
    public func reload() async {
        guard case .loaded = state else {
            await load(path: route)
            return
        }
        if case .success(let read) = await Self.read(path: route, source: source) {
            let (document, map, url, text, stamp) = read
            resolved = map
            fileURL = url
            self.text = text
            self.stamp = stamp
            optimistic = [:]
            messages = [:]
            state = .loaded(document)
        }
    }

    /// Tick or untick one box.
    ///
    /// OPTIMISTIC, then true. The glyph flips on the tap because a checkbox that waits for
    /// a file write before it moves is a checkbox people tap twice; the write follows, and
    /// either the document catches up with the glyph or the glyph goes back and says why.
    public func tick(block: VaultNoteBlock, to checked: Bool) async {
        guard case .checkbox = block.kind, let stamp else { return }
        guard !VaultWriteExemption.isReadOnly(path: route) else { return }
        optimistic[block.id] = checked
        messages[block.id] = nil

        let outcome = await ticker.tick(path: route, line: block.line, to: checked,
                                        text: text, stamp: stamp)
        switch outcome {
        case .written(let newText, let newStamp):
            text = newText
            self.stamp = newStamp
            // OFF THE MAIN ACTOR, like every other parse in this type. A 250 KB note is
            // milliseconds, and milliseconds on the actor that draws is a dropped frame on
            // the animation the tap itself started.
            let modified = fileURL.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
            }
            let path = route
            let reparsed = await Task.detached {
                VaultNoteDocument.parse(path: path, text: newText, modified: modified)
            }.value
            state = .loaded(reparsed)
            // The document now says what the glyph has been saying, so the override goes.
            // NOT bumping `generation`: that is the signal to scroll to a search hit, and
            // re-landing on it because somebody ticked a box further down would throw the
            // page away from under them.
            optimistic[block.id] = nil
        default:
            optimistic[block.id] = nil
            messages[block.id] = outcome.message
        }
    }

    /// The state a checkbox block should DRAW as: the tap's, while one is in flight,
    /// otherwise the document's.
    public func isChecked(_ block: VaultNoteBlock, documentSays checked: Bool) -> Bool {
        optimistic[block.id] ?? checked
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
    /// The capture sheet, and the one line that confirms a capture landed.
    @State private var isCapturing = false
    @State private var captured: String?
    /// The editor, presented over this screen.
    @State private var isEditing = false
    /// Formatted or raw, seeded from the remembered preference and written back on every
    /// change so the choice survives the next note and the next launch.
    @State private var mode: VaultReaderMode
    /// The block a search hit sent the reader to, tinted briefly so the eye lands.
    @State private var landedOn: Int?
    /// Which oversized tables the reader has asked to see in full, by block id.
    @State private var expandedTables: Set<Int> = []
    /// The review request, and the one line it leaves behind.
    @State private var review = VaultNoteReviewModel()
    @Environment(\.openURL) private var openURL
    /// How this shell starts a conversation, and whether its bridge is there. Nil in a
    /// preview and in any window nobody wired, where a review request goes to the vault
    /// instead of nowhere.
    @Environment(\.vaultReview) private var reviewAction
    private let preferences: VaultReaderPreferences
    /// Pushing another note is the STACK's business, not this view's: it is handed a way to
    /// navigate so the same view works in a `NavigationStack`, in a Mac window and in a
    /// preview.
    private let onOpenNote: (VaultNoteRoute) -> Void

    public init(route: VaultNoteRoute,
                model: VaultNoteReaderModel? = nil,
                preferences: VaultReaderPreferences = VaultReaderPreferences(),
                onOpenNote: @escaping (VaultNoteRoute) -> Void = { _ in }) {
        self.route = route
        _model = State(initialValue: model ?? VaultNoteReaderModel())
        self.preferences = preferences
        _mode = State(initialValue: preferences.mode)
        self.onOpenNote = onOpenNote
    }

    public var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    header
                    if let document = model.document, document.annotationCount > 0,
                       !isReadOnly {
                        reviewRow(count: document.annotationCount)
                    }
                    // WHERE THE CAPTURE WENT, in the same badge the composer's local turn
                    // uses. A sheet that simply closes is indistinguishable from a sheet
                    // that was cancelled, and a capture is exactly the thing a person needs
                    // to believe happened.
                    if let captured {
                        Label(captured, systemImage: "tray.and.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                        if mode == .raw {
                            rawBody(document)
                        } else {
                            formattedBody(document)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .onChange(of: model.generation) { _, _ in
                guard case .loaded(let document) = model.state else { return }
                land(on: document, with: scroller)
            }
            .onChange(of: mode) { _, _ in
                guard case .loaded(let document) = model.state else { return }
                land(on: document, with: scroller)
            }
        }
        .navigationTitle(model.document?.fileName ?? VaultWikiLink.basename(route.path))
        .toolbar {
            // `.primaryAction`, explicitly. An item left to `.secondaryAction` collapses
            // into the overflow "More" ellipsis on iOS, which is where a one-tap capture
            // would go to be never used again — the trap PR #33 already paid for once.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCapturing = true
                } label: {
                    Label("Capture about this note", systemImage: "tray.and.arrow.down")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    mode = mode.toggled
                    preferences.mode = mode
                } label: {
                    Label(mode.buttonLabel, systemImage: mode.buttonSymbol)
                }
            }
            // `.primaryAction` for the same reason the capture button is: an edit action in
            // the overflow ellipsis is an edit action nobody finds.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isEditing = true
                } label: {
                    Label("Edit", systemImage: "square.and.pencil")
                }
                .disabled(editRefusal != nil)
                .help(editRefusal ?? "Edit this note")
            }
            ToolbarItem {
                Button {
                    reveal()
                } label: {
                    Label(Self.revealLabel, systemImage: "folder")
                }
                .disabled(model.fileURL == nil)
            }
        }
        // `about` is the OPEN note's path, so the captured line carries it in a code span
        // and the morning triage can file the thought against the note without guessing.
        .sheet(isPresented: $isCapturing) {
            VaultCaptureSheet(about: route.path) { write in
                isCapturing = false
                if let write { captured = InboxCaptureReply.badge(path: write.relativePath) }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 260)
            #endif
        }
        // A SHEET rather than a push, deliberately. The reader's stack carries
        // `VaultNoteRoute`s and every one of them is a note to read; giving it a second
        // destination type so the editor could be pushed would mean every shell that
        // presents a reader learns about editing. A sheet is modal, which is what editing
        // a file is, and "pops back to the reader" is its dismissal.
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                VaultNoteEditorView(path: route.path) {
                    Task { await model.reload() }
                }
            }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 420)
            #endif
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

    /// Scroll to the line a search hit named, and tint what is there for a moment.
    ///
    /// The tint is the whole reason this is not just a `scrollTo`: a note scrolled to its
    /// middle with no indication of why looks like a note that failed to open at the top.
    private func land(on document: VaultNoteDocument, with scroller: ScrollViewProxy) {
        guard let line = route.line else { return }
        let anchor: Int?
        if mode == .raw {
            anchor = document.rawLines.isEmpty ? nil : min(line, document.rawLines.count)
        } else {
            anchor = VaultNoteDocument.blockID(forLine: line, in: document.blocks)
        }
        guard let anchor else { return }
        let id = Self.anchorID(anchor, raw: mode == .raw)
        landedOn = anchor
        Task {
            // One turn of the run loop before scrolling. The blocks are built lazily, and
            // asking a `LazyVStack` to scroll to an id in the same pass that first
            // presents it is asking it to find something it has not made yet.
            await Task.yield()
            withAnimation { scroller.scrollTo(id, anchor: .top) }
            try? await Task.sleep(for: .seconds(2))
            if landedOn == anchor { landedOn = nil }
        }
    }

    /// Scroll identity. Raw lines and formatted blocks are both numbered from zero-ish, so
    /// the two spaces are kept apart by a prefix rather than colliding silently.
    static func anchorID(_ value: Int, raw: Bool) -> String {
        (raw ? "raw-" : "block-") + String(value)
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
            // ONE note gets one extra line. Said where the boxes are about to look
            // untappable, so the difference reads as a rule rather than as a bug.
            if let caption = VaultWriteExemption.caption(path: route.path) {
                Label(caption, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// HOW MANY MARKS ARE WAITING, and the one button that asks for them to be answered.
    ///
    /// Shown only when there is something to answer and the note is one this app may write
    /// to. `Today.md` is rewritten by the bridge (`VaultWriteExemption`), so a review
    /// request against it would ask for edits to a file whose next regeneration would
    /// discard them.
    @ViewBuilder
    private func reviewRow(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label(VaultAnnotationMarkup.countCaption(count), systemImage: "quote.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Send to Jesse") {
                    Task {
                        await review.send(path: route.path, review: reviewAction)
                        if let badge = review.badge { captured = badge }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(review.busy)
                .accessibilityIdentifier(Self.sendIdentifier)
            }
            if let status = review.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The Send button's UI-test handle.
    public static let sendIdentifier = "vault.reader.sendAnnotations"

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

    // MARK: - The two bodies

    @ViewBuilder
    private func formattedBody(_ document: VaultNoteDocument) -> some View {
        if !document.frontmatter.isEmpty {
            frontmatter(document.frontmatter)
        }
        if document.truncated {
            truncationNotice
        }
        ForEach(document.blocks) { block in
            blockView(block)
                .id(Self.anchorID(block.id, raw: false))
                .background(landedOn == block.id ? Color.accentColor.opacity(0.15) : .clear)
        }
    }

    /// The file, as text.
    ///
    /// One `Text` PER LINE inside the lazy stack, never one `Text` holding the whole file:
    /// a single 256 KB string is one text-layout pass that the frame budget cannot absorb,
    /// and it is the slow path this prompt exists to avoid. Frontmatter is shown here as
    /// part of the file rather than folded away — in raw, the file is the file.
    @ViewBuilder
    private func rawBody(_ document: VaultNoteDocument) -> some View {
        if document.truncated {
            truncationNotice
        }
        let width = String(document.rawLines.count).count
        ForEach(document.rawLines.indices, id: \.self) { offset in
            let line = document.rawLines[offset]
            HStack(alignment: .top, spacing: 8) {
                Text(String(format: "%\(width)d", offset + 1))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(line.isEmpty ? " " : line)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(Self.anchorID(offset + 1, raw: true))
            .background(landedOn == offset + 1 ? Color.accentColor.opacity(0.15) : .clear)
        }
    }

    /// Why only part of the note is here, AND why Edit is off.
    ///
    /// The second half says itself here rather than only in the toolbar button's `.help`,
    /// because `.help` is a hover tooltip: on the iPhone, which is the platform this
    /// feature is mostly for, it renders nothing at all. A disabled button with an
    /// invisible explanation is a button that looks broken.
    private var truncationNotice: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("This note is long; only the first \(VaultNoteDocument.byteLimit / 1024) KB is shown.",
                  systemImage: "text.append")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(VaultNoteEditorModel.tooLongCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Blocks

    @ViewBuilder
    private func blockView(_ block: VaultNoteBlock) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch block.kind {
            case .heading(let level):
                Text(inline(block.text))
                    .font(Self.headingFont(level))
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, level <= 2 ? 8 : 2)
            case .paragraph:
                Text(inline(block.text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .bullet(let depth):
                marker(depth: depth) {
                    Text("•").foregroundStyle(.secondary)
                } content: {
                    Text(inline(block.text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .ordered(let depth, let number):
                marker(depth: depth) {
                    // Monospaced digits so a list that reaches double figures does not
                    // shuffle its own text sideways at item ten.
                    Text("\(number).")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                } content: {
                    Text(inline(block.text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .checkbox(let depth, let parsed):
                let checked = model.isChecked(block, documentSays: parsed)
                marker(depth: depth) {
                    checkboxControl(block, checked: checked)
                } content: {
                    Text(inline(block.text))
                        .strikethrough(checked, color: .secondary)
                        .foregroundStyle(checked ? AnyShapeStyle(.secondary)
                                                 : AnyShapeStyle(.primary))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .quote:
                HStack(spacing: 8) {
                    Rectangle().fill(.secondary.opacity(0.4)).frame(width: 3)
                    Text(inline(block.text))
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .callout(let type, let title):
                calloutView(type: type, title: title, body: block.text)
            case .code:
                codeView(block)
            case .rule:
                Divider().padding(.vertical, 4)
            case .table(let headers, let rows, let alignments):
                tableView(block: block, headers: headers, rows: rows, alignments: alignments)
            case .image(let alt, let target):
                imageView(alt: alt, target: target)
            }
            if let missing = Self.missingCaption(block, resolved: model.resolved) {
                Text(missing)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // WHY THE TICK DID NOT STICK, under the block it did not stick to. One line,
            // where the tap was, rather than a banner at the top of the note: a person who
            // tapped a box two screens down will never see a banner they cannot see.
            if let message = model.messages[block.id] {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A box that can be tapped — unless this is the one note the app does not write.
    ///
    /// THE TAP TARGET IS 44 POINTS, which is four times the glyph. A checkbox in a note is
    /// a small square in a dense list of small squares, and a target the size of the
    /// drawing is how a tap ticks the line below the one somebody meant.
    ///
    /// AND THE ROW GROWS TO MATCH, rather than the target being hung off a small row with
    /// negative padding. That was the first shape and it is wrong in a way worth writing
    /// down: a checkbox row is about 30 points tall, so 44-point targets held inside it
    /// would overlap their neighbours by a dozen points, and a tap in the overlap goes to
    /// whichever row SwiftUI drew last — reintroducing exactly the mis-tap the big target
    /// exists to prevent, while looking like it had been fixed. Only the HORIZONTAL half
    /// is pulled back in, because nothing beside the box in that column is tappable.
    @ViewBuilder
    private func checkboxControl(_ block: VaultNoteBlock, checked: Bool) -> some View {
        if isReadOnly {
            // `Today.md` only. A GLYPH, exactly as before this prompt, because the bridge
            // rewrites that file and the caption at the top says where the real control is.
            Image(systemName: checked ? "checkmark.square" : "square")
                .foregroundStyle(.secondary)
                .accessibilityLabel(checked ? "Done" : "Not done")
        } else {
            Button {
                Task { await model.tick(block: block, to: !checked) }
            } label: {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.secondary))
                    .frame(width: Self.tapTarget, height: Self.tapTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // The row is inside a scroll view that is itself inside a navigation stack;
            // without this the whole block reads as one control to VoiceOver and the text
            // stops being selectable.
            .accessibilityLabel(checked ? "Done" : "Not done")
            .accessibilityHint("Double tap to \(checked ? "untick" : "tick") this item")
            .padding(.horizontal, -Self.tapTarget / 4)
        }
    }

    /// Apple's minimum, and the number the prompt asks for.
    static let tapTarget: CGFloat = 44

    /// Why Edit is disabled, or nil when it is not.
    ///
    /// TWO reasons, and they are asked in this order: the exemption is a property of the
    /// path and is known before anything is read, while the length is a property of the
    /// note and is only known once it is. Both defer to the rules the editor itself
    /// enforces — `VaultNoteEditorModel.refusal` and the same `byteLimit` the reader
    /// truncates at — rather than restating them, so the button and the screen behind it
    /// cannot come to disagree.
    private var editRefusal: String? {
        if let refused = VaultNoteEditorModel.refusal(path: route.path) { return refused }
        if model.document?.truncated == true { return VaultNoteEditorModel.tooLongCaption }
        return nil
    }

    /// True for the one note the reader shows but never writes.
    private var isReadOnly: Bool { VaultWriteExemption.isReadOnly(path: route.path) }

    /// A list row: its marker, its text, and the indent its depth earns.
    @ViewBuilder
    private func marker<M: View, C: View>(depth: Int,
                                          @ViewBuilder _ mark: () -> M,
                                          @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            mark()
            content()
        }
        .padding(.leading, CGFloat(depth) * 14)
    }

    @ViewBuilder
    private func calloutView(type: String, title: String, body: String) -> some View {
        let style = VaultCalloutStyle.style(for: type)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(style.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: style.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.color)
                    .fixedSize(horizontal: false, vertical: true)
                if !body.isEmpty {
                    Text(inline(body))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(style.color.opacity(0.08), in: .rect(cornerRadius: 6))
    }

    @ViewBuilder
    private func codeView(_ block: VaultNoteBlock) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language = block.language {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
            }
            // Horizontal scroll rather than wrapping: a wrapped line of code is a line of
            // code you have to reassemble in your head before you can read it.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(block.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 5))
    }

    @ViewBuilder
    private func imageView(alt: String, target: String) -> some View {
        // NOT LOADED. See `VaultNoteRenderer`: the reader's budget is "open a 250 KB note
        // without a visible pause", and a picture is the one thing in a note that can cost
        // a second all by itself.
        VStack(alignment: .leading, spacing: 2) {
            Label(alt.isEmpty ? VaultWikiLink.basename(target) : alt, systemImage: "photo")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(target)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 5))
    }

    @ViewBuilder
    private func tableView(block: VaultNoteBlock, headers: [String], rows: [[String]],
                           alignments: [TableAlignment]) -> some View {
        let expanded = expandedTables.contains(block.id)
        let window = VaultTableWindow.window(rowCount: rows.count, expanded: expanded)
        VStack(alignment: .leading, spacing: 4) {
            // Horizontal scroll so a six-column table never squeezes its text into one
            // character per line.
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { column, cell in
                            self.cell(cell, alignment: Self.alignment(alignments, column))
                                .fontWeight(.semibold)
                        }
                    }
                    Divider()
                    ForEach(Array(rows.prefix(window.shown).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                                self.cell(cell, alignment: Self.alignment(alignments, column))
                            }
                        }
                    }
                }
                .padding(8)
            }
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 5))
            if window.hidden > 0 {
                Button("Show all \(rows.count) rows") {
                    expandedTables.insert(block.id)
                }
                .font(.caption)
            }
        }
    }

    private func cell(_ text: String, alignment: Alignment) -> some View {
        Text(inline(text))
            .textSelection(.enabled)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    static func alignment(_ alignments: [TableAlignment], _ column: Int) -> Alignment {
        switch column < alignments.count ? alignments[column] : .leading {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    private func inline(_ text: String) -> AttributedString {
        VaultNoteRenderer.attributed(text, resolved: model.resolved)
    }

    /// What to say under a block that links a note this vault does not have.
    static func missingCaption(_ block: VaultNoteBlock,
                               resolved: [String: String]) -> String? {
        var missing: [String] = []
        for piece in block.inlineTexts {
            for target in VaultNoteRenderer.unresolvedTargets(in: piece, resolved: resolved)
            where !missing.contains(target) {
                missing.append(target)
            }
        }
        return VaultWikiLink.missingCaption(targets: missing)
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
