import SwiftUI
import JesseNetworking
import JesseVault

// A strand and today's items, joined in both directions.
//
// The bridge derives one strand per Today item (`TodayItem.strand`); this file is
// everything the app does with that answer, and none of it derives anything. A Today row
// shows a chip for its strand, the strand's note opens with the open items that name it,
// and a Strands row says how many there are. All three read `strand.slug` and nothing
// else, so the phone can never disagree with the nightly audit about which item belongs
// where: there is one derivation, and it is not here.
//
// ## One opener, one sheet
//
// Opening a strand used to live inside the Strands segment, reachable only from a board
// row. It is now reached from a Today row, from the item detail and from the board, so it
// is ONE object the shell owns (`StrandOpener`) and ONE sheet the shell attaches
// (`strandNoteSheet`). Two sheet modifiers bound to the same opener would race to present
// the same note, and a second definition of "open a strand" is how the board and the chip
// would end up opening different things.

/// Where the bridge's copy of a strand note comes from. `StrandsModel` in the app; a fake
/// in a test.
@MainActor
public protocol StrandMarkdownProviding: AnyObject {
    func markdown(forSlug slug: String) async -> String?
}

extension StrandsModel: StrandMarkdownProviding {}

/// **What opening a strand means**, in one place: the vault reader on the strand's note,
/// which shows the Studio's copy whenever the device's is behind; the strands endpoint's
/// copy for a bridge too old to serve notes by path; and an honest line when neither
/// answered.
@MainActor
@Observable
public final class StrandOpener {
    nonisolated deinit {}

    /// The note on screen, if any. Bound to the one sheet `strandNoteSheet` attaches.
    public var openedNote: StrandNoteSource?
    /// The slug being resolved right now, so the control that asked can say it is working
    /// and a second tap cannot start a second resolve.
    public private(set) var opening: String?
    /// The one line answer to a tap that could not open anything.
    public var notice: String?

    private let localNotes: (any TodayLocalNoteProviding)?
    private weak var remote: (any StrandMarkdownProviding)?
    private let opener: VaultNoteOpener

    public init(localNotes: (any TodayLocalNoteProviding)? = nil,
                remote: (any StrandMarkdownProviding)? = nil,
                opener: VaultNoteOpener = .shared) {
        self.localNotes = localNotes
        self.remote = remote
        self.opener = opener
    }

    /// Open a strand from a tap. Returns at once; the note arrives on `openedNote`.
    public func open(slug: String, title: String) {
        guard opening == nil else { return }
        Task { await resolve(slug: slug, title: title) }
    }

    /// Open the strand a Today item names.
    public func open(_ strand: TodayItemStrand) {
        open(slug: strand.slug, title: strand.title)
    }

    /// The whole resolve, awaited: what a tap runs, and what a test drives.
    public func resolve(slug: String, title: String) async {
        guard opening == nil else { return }
        opening = slug
        notice = nil
        defer { opening = nil }
        // `Strands/<slug>` is an exact relative path, so the resolver's first step settles
        // it; the basename steps below it are what cover a vault whose folder is one level
        // in from the workspace root.
        //
        // THE READER DECIDES WHICH COPY, not this. `.local` opens the vault reader, and the
        // reader asks the Studio first (`VaultNoteOpener`): the device's copy only when it
        // is the Studio's, the Studio's copy with a line saying the device is behind
        // otherwise. A strand note the device does not have at all still opens there,
        // from the Studio, by the Studio's own path. The strands endpoint's markdown is
        // what is left for a bridge too old to serve a note by path.
        let target = "\(Strand.directory)/\(slug)"
        if let local = await localNotes?.localNote(forTargets: [target]) {
            openedNote = .local(path: local.path, slug: slug, title: title)
            return
        }
        if case .path(let path) = await opener.resolve(target: target, localPath: nil) {
            openedNote = .local(path: path, slug: slug, title: title)
            return
        }
        if let markdown = await remote?.markdown(forSlug: slug) {
            openedNote = .remote(slug: slug, title: title, markdown: markdown)
            return
        }
        notice = Self.couldNotOpen(title)
    }

    /// What a tap says when neither the device nor the bridge could produce the note. It
    /// names both halves, because which one failed is what tells the reader what to do
    /// about it.
    public static func couldNotOpen(_ title: String) -> String {
        "\(title) isn't in this copy of the vault, and the bridge couldn't be reached for it."
    }
}

// MARK: - Today's items on a strand

/// The client half of the join: a filter over the snapshot the app already holds, by the
/// bridge's `strand.slug`, and nothing more clever than that.
public enum StrandOnToday {
    /// The OPEN items of `snapshot` whose strand is exactly `slug`, in file order: the lead
    /// items, then each section. A checked item is finished and is not "on today" any more;
    /// a postponed one is still open and still listed.
    public static func items(forSlug slug: String, in snapshot: TodaySnapshot?) -> [TodayItem] {
        guard let snapshot else { return [] }
        let all = snapshot.leadItems + snapshot.sections.flatMap(\.items)
        return all.filter { !$0.checked && $0.strand?.slug == slug }
    }

    /// The Strands row's caption, or nil at zero so the row says nothing rather than
    /// "0 on Today".
    public static func caption(count: Int) -> String? {
        count > 0 ? "\(count) on Today" : nil
    }

    /// The item's links without the one that points at its own strand note, which the
    /// strand chip already stands for: a row must never show the strand twice.
    public static func linksWithoutStrand(_ item: TodayItem) -> [TodayLink] {
        guard let strand = item.strand else { return item.links }
        return item.links.filter { !isStrandNote($0, slug: strand.slug) }
    }

    /// Whether `link` is a wiki link to `Strands/<slug>`, in any of the spellings the
    /// bridge accepts (`todo-list/`, `vault/`, `.md`, a heading).
    static func isStrandNote(_ link: TodayLink, slug: String) -> Bool {
        guard link.isWiki else { return false }
        var path = link.target.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        for prefix in ["todo-list/", "vault/"] where path.hasPrefix(prefix) {
            path.removeFirst(prefix.count)
        }
        if path.lowercased().hasSuffix(".md") { path.removeLast(3) }
        return path.caseInsensitiveCompare("\(Strand.directory)/\(slug)") == .orderedSame
    }
}

// MARK: - The chip

/// A Today item's strand, as a chip that opens the strand's note.
///
/// Drawn like a link chip so it sits in the same flow, with the board's own symbol so it
/// reads as a strand rather than as one more file.
public struct TodayStrandChip: View {
    let strand: TodayItemStrand
    let isOpening: Bool
    let onOpen: (TodayItemStrand) -> Void

    public init(strand: TodayItemStrand, isOpening: Bool = false,
                onOpen: @escaping (TodayItemStrand) -> Void) {
        self.strand = strand
        self.isOpening = isOpening
        self.onOpen = onOpen
    }

    /// The board's empty state symbol, shared so the two read as one object.
    public static let symbol = "point.3.connected.trianglepath.dotted"

    public var body: some View {
        Button { onOpen(strand) } label: {
            HStack(spacing: 4) {
                Label(strand.title, systemImage: Self.symbol)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                if isOpening {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.14), in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityLabel("Open strand \(strand.title)")
    }
}

// MARK: - The block above the note

/// `On Today`: the open items that name this strand, one line each. Nothing at all when
/// there are none, not an empty header.
struct StrandOnTodayBlock: View {
    let items: [TodayItem]
    let onSelect: (TodayItem) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("On Today")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    Button { onSelect(item) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(item.lead.isEmpty ? item.text : item.lead)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the item on Today")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }
}

// MARK: - The one sheet

extension View {
    /// Present the strand note `opener` opens, with its `On Today` block, from wherever
    /// the shell attaches this. Attach it ONCE per screen.
    ///
    /// `day` is the snapshot the block filters. Tapping a line closes the sheet, puts the
    /// Today segment on screen and, once the sheet is gone, hands the item to
    /// `onSelectItem`, which opens its detail: navigating while a sheet is still going is
    /// how a push gets dropped.
    public func strandNoteSheet(_ opener: StrandOpener,
                                day: TodaySnapshot?,
                                onOpenLink: @escaping (TodayLinkOrigin) -> Void,
                                onSelectItem: @escaping (TodayItem) -> Void) -> some View {
        modifier(StrandNoteSheetModifier(opener: opener, day: day, onOpenLink: onOpenLink,
                                         onSelectItem: onSelectItem))
    }
}

private struct StrandNoteSheetModifier: ViewModifier {
    @Bindable var opener: StrandOpener
    let day: TodaySnapshot?
    let onOpenLink: (TodayLinkOrigin) -> Void
    let onSelectItem: (TodayItem) -> Void

    /// The same key `TodayListView` reads, so selecting Today here is selecting it there.
    @AppStorage(TodayViewPreferences.segmentKey) private var storedSegment = TodaySegment.today.rawValue
    /// The line tapped, held until the sheet has finished leaving.
    @State private var selected: TodayItem?

    func body(content: Content) -> some View {
        content.sheet(item: $opener.openedNote, onDismiss: {
            guard let item = selected else { return }
            selected = nil
            onSelectItem(item)
        }) { source in
            sheet(source)
        }
    }

    private func onToday(_ slug: String) -> some View {
        StrandOnTodayBlock(items: StrandOnToday.items(forSlug: slug, in: day)) { item in
            selected = item
            storedSegment = TodaySegment.today.rawValue
            opener.openedNote = nil
        }
    }

    @ViewBuilder
    private func sheet(_ source: StrandNoteSource) -> some View {
        switch source {
        case .local(let path, let slug, _):
            // The reader the Vault tab pushes, in a stack of its own, so following a wiki
            // link out of a strand note PUSHES rather than replaces. Checkboxes and the
            // editor come with it.
            VaultNoteStack(path: path, rootAccessory: AnyView(onToday(slug))) {
                opener.openedNote = nil
            }
        case .remote(let slug, let title, let markdown):
            StrandRemoteNoteView(title: title, markdown: markdown,
                                 onToday: AnyView(onToday(slug)),
                                 onOpenLink: onOpenLink) { opener.openedNote = nil }
        }
    }
}
