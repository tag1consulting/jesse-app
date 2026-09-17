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
    private let onCloseAsStale: (TodayItem, String) -> Void

    /// The source note starts CLOSED. That is the whole change in posture: this page used
    /// to be the note, and the note is now the citation under the answer.
    @State private var isNoteExpanded = false

    public init(model: TodayDetailModel, item: TodayItem,
                onOpenLink: @escaping (TodayLinkOrigin) -> Void = { _ in },
                onCloseAsStale: @escaping (TodayItem, String) -> Void = { _, _ in }) {
        self.model = model
        self.item = item
        self.onOpenLink = onOpenLink
        self.onCloseAsStale = onCloseAsStale
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
        case .removed:
            empty(symbol: "questionmark.folder",
                  title: "This item is gone",
                  message: "It's no longer in today's day file — the morning rebuild dropped it, or its wording changed.")
        case .unavailable(let message):
            empty(symbol: "wifi.exclamationmark",
                  title: "Can't reach the bridge",
                  message: message)
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 24)
        case .loaded, .noDetail:
            // THE ORDER IS THE POINT. The answers about this item come first; the
            // document they were drawn from is below them, closed.
            VStack(alignment: .leading, spacing: 16) {
                briefBody
                noteBody
            }
        }
    }

    // MARK: - The seven answers

    /// The seven headings, in the order the brief answers them.
    private static let headings = ["What it is", "Where it came from", "Due", "Priority",
                                   "Done so far", "Done means", "Who knows more"]

    @ViewBuilder
    private var briefBody: some View {
        switch model.brief?.status {
        case .ok:
            if let brief = model.brief?.brief {
                VStack(alignment: .leading, spacing: 14) {
                    verdictLine(brief.relevance)
                    messageEvidence(brief)
                    ForEach(Array(brief.sections.enumerated()), id: \.offset) { _, section in
                        answer(section.heading, section.answer)
                    }
                    people(brief.people)
                    more(brief.more)
                    staleButton(brief)
                }
            }
        case .pending:
            // The headings with a spinner, not a spinner alone: the page keeps its shape
            // while it fills in, and the note below stays reachable the whole time.
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Writing the summary…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Writing the summary")
                ForEach(Self.headings, id: \.self) { heading in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(heading)
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("—")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        case .failed:
            Label(model.brief?.failure.map { "The summary couldn't be written: \($0)" }
                    ?? "The summary couldn't be written.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unknown, .none:
            // A bridge that sends no brief at all. The note below is the whole page,
            // exactly as it was before this feature existed.
            EmptyView()
        }
    }

    /// One answer under its heading. An answer the notes could not support renders in a
    /// secondary style, so "the vault doesn't say" is visibly different from an answer.
    private func answer(_ heading: String, _ value: TodayBriefAnswer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(heading)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            // PLAIN TEXT, never markdown: these are sentences the bridge validated, and
            // rendering them as markdown would let a stray asterisk from a note change
            // how an answer looks.
            Text(value.text)
                .font(.body)
                .foregroundStyle(value.known ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The verdict, in one line, and only when it is not the ordinary "still yours".
    @ViewBuilder
    private func verdictLine(_ relevance: TodayBriefRelevance) -> some View {
        if relevance.verdict != .open && relevance.verdict != .unknown {
            let word = switch relevance.verdict {
            case .done: "Looks done"
            case .moot: "Looks no longer needed"
            case .overdue: "Overdue"
            default: ""
            }
            Label("\(word). \(relevance.reason)", systemImage: relevance.verdict == .overdue
                    ? "clock.badge.exclamationmark" : "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The message evidence under the verdict: WHERE it is, never what it says.
    ///
    /// Channel, account or chat, and date — in the same secondary style a note source gets.
    /// The one-sentence summary the bridge validated is deliberately NOT shown: the body is
    /// the owner's private correspondence, and a to-do list read over a shoulder should not
    /// also be a mailbox read over a shoulder. The id is what makes the message findable,
    /// and it is carried in the accessibility label rather than the line, which would
    /// otherwise be mostly punctuation.
    @ViewBuilder
    private func messageEvidence(_ brief: TodayItemBrief) -> some View {
        if !brief.messageCitations.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(brief.messageCitations) { citation in
                    Text("\(citation.channel.label) · \(citation.account) · \(citation.date)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(
                            "\(citation.channel.label), \(citation.account), \(citation.date)")
                }
            }
        }
        if let gap = Self.unsearchedNote(brief) {
            Text(gap)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What to say when the sent-message search did not happen, or did not cover everything.
    ///
    /// A brief that searched nothing and a brief that searched four of six are different
    /// claims, and neither may be left to look like "there was nothing to find". `nil` only
    /// when all six were searched.
    private static func unsearchedNote(_ brief: TodayItemBrief) -> String? {
        guard brief.messagesSearchedAt != nil else { return "Sent messages were not searched." }
        let missing = TodayMessageChannel.searchable
            .filter { !brief.channelsSearched.contains($0) }
        guard !missing.isEmpty else { return nil }
        return "Not searched: " + missing.map(\.label).joined(separator: ", ") + "."
    }

    @ViewBuilder
    private func people(_ contacts: [TodayBriefContact]) -> some View {
        if !contacts.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(contacts) { person in
                    Text("\(person.name) — \(person.role). \(person.knows)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func more(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Also worth knowing")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One button, on the items the bridge suspected but would not close itself.
    @ViewBuilder
    private func staleButton(_ brief: TodayItemBrief) -> some View {
        if item.relevance?.stale == true && !item.checked {
            Button {
                onCloseAsStale(item, brief.relevance.reason)
            } label: {
                Label("Close as stale", systemImage: "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Ticks this item off, recording why")
        }
    }

    // MARK: - The source note, below the answers

    @ViewBuilder
    private var noteBody: some View {
        switch model.state {
        case .loaded(let note):
            DisclosureGroup(isExpanded: $isNoteExpanded) {
                TodayNoteView(markdown: note.markdown, onOpenLink: onOpenLink)
                    .padding(.top, 6)
            } label: {
                Label(note.fileName, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Source note, \(note.path)")
            }
        case .noDetail(let reason):
            empty(symbol: "doc.plaintext",
                  title: "No note behind this item",
                  message: TodayDetailModel.noDetailMessage(reason))
        default:
            EmptyView()
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
