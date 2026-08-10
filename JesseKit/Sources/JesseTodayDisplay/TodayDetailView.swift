import SwiftUI
import JesseNetworking

// The note behind one item, rendered. Pure SwiftUI, like every other view in this
// target: no UIKit, no AppKit, no platform conditional, every colour either a semantic
// one or a role out of `TodayProjectPalette`.
//
// It knows nothing about navigation. Whether this arrives as a sheet, a push, or the
// detail half of a Mac split view is the shell's business (R3) — this takes a model and
// an item and draws, which is what lets the same file serve a phone, a Mac window and a
// preview.

/// The note behind one day-file item.
public struct TodayDetailView: View {
    @Environment(\.colorScheme) private var scheme
    @Bindable private var model: TodayDetailModel

    /// The item this is about. Carried in full rather than by id because the header
    /// wants its lead and its project, and the day file is the authority on both — the
    /// note does not know which item linked it.
    private let item: TodayItem
    private let onOpenLink: (TodayLinkOrigin) -> Void

    public init(model: TodayDetailModel, item: TodayItem,
                onOpenLink: @escaping (TodayLinkOrigin) -> Void = { _ in }) {
        self.model = model
        self.item = item
        self.onOpenLink = onOpenLink
    }

    private var role: TodayProjectRole { TodayProjectPalette.role(for: item.project) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.isOffline {
                    Label(model.lastErrorMessage ?? "Showing the note as it was last read.",
                          systemImage: "wifi.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .task(id: item.id) { await model.load(id: item.id) }
        .refreshable { await model.load(id: item.id, force: true) }
    }

    // MARK: - Header

    /// The item this note belongs to, and where the note came from.
    ///
    /// The project accent is a RULE down the leading edge rather than a tinted
    /// background: a full wash of colour behind body text is what pushes contrast under
    /// the threshold the palette was chosen to clear, and an unfiled item would have to
    /// be washed grey, which reads as disabled.
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(role.color(scheme))
                .opacity(role.isNeutral ? 0.3 : 1)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.lead.isEmpty ? "This item" : item.lead)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TodayProjectChip(project: item.project)
                    if let note = model.note {
                        Text(note.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .accessibilityLabel("From \(note.path)")
                    }
                }
                if model.note?.truncated == true {
                    // Said out loud, and not in a `footer:` — a long footer ellipsises on
                    // macOS. A reader who does not know the note was cut will act on two
                    // thirds of it.
                    Label("This note is long; only the first part is shown.",
                          systemImage: "text.append")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
        case .loaded(let note):
            TodayNoteView(markdown: note.markdown, onOpenLink: onOpenLink)
        case .noDetail(let reason):
            empty(symbol: "doc.plaintext",
                  title: "No note behind this item",
                  message: TodayDetailModel.noDetailMessage(reason))
        case .removed:
            empty(symbol: "questionmark.folder",
                  title: "This item is gone",
                  message: "It's no longer in today's day file — the morning rebuild dropped it, or its wording changed.")
        case .unavailable(let message):
            empty(symbol: "wifi.exclamationmark",
                  title: "Can't reach the bridge",
                  message: message)
        }
    }

    private func empty(symbol: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }
}

// MARK: - The note itself

/// A vault note's markdown, as blocks. Split out from `TodayDetailView` so it can be
/// rendered anywhere a note's text is in hand — and so it can be previewed and tested
/// without a model.
public struct TodayNoteView: View {
    private let blocks: [TodayNoteBlock]
    private let onOpenLink: (TodayLinkOrigin) -> Void

    public init(markdown: String, onOpenLink: @escaping (TodayLinkOrigin) -> Void = { _ in }) {
        self.blocks = TodayNoteMarkdown.blocks(markdown)
        self.onOpenLink = onOpenLink
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if blocks.isEmpty {
                Text("The note is empty.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            ForEach(blocks) { block in
                VStack(alignment: .leading, spacing: 6) {
                    row(block)
                    // The same chips the day rows use, under the block that carries
                    // them — one link treatment for the whole feature, and the origin
                    // carries the block's RAW source so a conversation about a linked
                    // note has the line that referenced it.
                    TodayLinkChips(links: block.links, sourceText: block.source,
                                   onOpen: onOpenLink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func row(_ block: TodayNoteBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(level <= 1 ? .title3 : (level == 2 ? .headline : .subheadline))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .bullet(let depth):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                Text(block.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(.quaternary).frame(width: 3)
                Text(block.text)
                    .font(.body)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code:
            Text(block.text)
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary, in: .rect(cornerRadius: 6))
        case .rule:
            Divider()
        case .paragraph:
            Text(block.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
