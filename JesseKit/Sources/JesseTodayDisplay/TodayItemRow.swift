import SwiftUI
import JesseNetworking

// One task row, and the pieces it is built from. Pure SwiftUI: no UIKit, no AppKit,
// no platform conditionals. Every color is a semantic one that exists on both
// platforms (`.secondary`, `.tint`, the material fills), which is what lets this
// file — and this whole target — compile for macOS with no PlatformCompat seam at
// all.

// MARK: - The checkbox

/// The tap target. Deliberately a `Button` with a plain style rather than a `Toggle`:
/// a checked row can also open the evidence sheet, and a toggle's binding would fire
/// on the way in AND on the way back out when the sheet is dismissed.
struct TodayCheckbox: View {
    let checked: Bool
    let pending: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: checked)
                // A tap that has not landed yet reads as slightly withdrawn rather than
                // as a spinner: the state is committed locally, it is just not
                // acknowledged, and a spinner would suggest it might not stick.
                .opacity(pending ? 0.55 : 1)
                .contentShape(.rect)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(checked ? "Completed" : "Not completed")
        .accessibilityAddTraits(checked ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Link chips

/// A tapped link together with the row it came from.
///
/// The row travels with the link because the two kinds of link want opposite
/// things. A URL opens in a browser and the row is irrelevant. A `[[wiki]]` target
/// addresses a vault note the app cannot render — there is no in-app viewer — so the
/// only useful thing a tap can do is start a conversation ABOUT that note, and a
/// conversation needs the line that referenced it, verbatim, or the agent is left
/// guessing why the file came up. `sourceText` is that line's RAW markdown, which is
/// exactly what the discuss prompt builder embeds.
public struct TodayLinkOrigin: Equatable, Sendable {
    public var link: TodayLink
    public var sourceText: String

    public init(link: TodayLink, sourceText: String) {
        self.link = link
        self.sourceText = sourceText
    }
}

/// One link as a tappable chip. Wiki targets show their leaf name, URLs their host —
/// a full vault path would not fit and would not help.
public struct TodayLinkChip: View {
    let link: TodayLink
    let sourceText: String
    let onOpen: (TodayLinkOrigin) -> Void

    public init(link: TodayLink, sourceText: String,
                onOpen: @escaping (TodayLinkOrigin) -> Void) {
        self.link = link
        self.sourceText = sourceText
        self.onOpen = onOpen
    }

    public var body: some View {
        Button { onOpen(TodayLinkOrigin(link: link, sourceText: sourceText)) } label: {
            Label(link.chipLabel, systemImage: link.isWiki ? "doc.text" : "link")
                // Explicit, not inherited: run on a phone, this chip rendered as a
                // bare glyph in an otherwise empty capsule — the label style a
                // `Button` inside a `List` row resolves to drops the title. The row's
                // evidence line carries the same modifier for the same reason. A chip
                // that shows only an icon says a link exists but not to what.
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Open \(link.chipLabel)")
    }
}

/// An item's links, wrapped so a row with many of them grows downward instead of
/// truncating. Nothing renders when there are none.
struct TodayLinkChips: View {
    let links: [TodayLink]
    let sourceText: String
    let onOpen: (TodayLinkOrigin) -> Void

    var body: some View {
        if !links.isEmpty {
            // `Layout`-free wrapping: a flexible grid with a minimum column width lets
            // chips flow onto as many rows as they need on a phone and a Mac window
            // alike, with no measurement pass of our own.
            FlowRow(spacing: 6) {
                ForEach(links, id: \.target) {
                    TodayLinkChip(link: $0, sourceText: sourceText, onOpen: onOpen)
                }
            }
        }
    }
}

/// A minimal wrapping row. SwiftUI has no built-in flow layout, and the alternative
/// — a horizontal `ScrollView` — hides links behind a scroll gesture that competes
/// with the list's own.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, max(widest, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - The row

/// One task line: its checkbox, its bold lead with the detail after it, its
/// continuations, its links, its dates, and the evidence a completion recorded.
public struct TodayItemRow: View {
    let item: TodayItem
    let pending: Bool
    let evidence: String?
    let availableMoves: [TodayMoveOp]
    let focusActions: [TodayFocus]
    /// Whether opening the item takes TWO clicks instead of one.
    ///
    /// A parameter rather than a `#if os(macOS)`, because it is not really about the
    /// operating system: it is about whether the list this row sits in has a
    /// SELECTION. Where a single click selects a row (a Mac window, where selection is
    /// what the keyboard then acts on), a single click cannot also open it — so the
    /// open moves to the double click, which is what a Mac user reaches for anyway.
    /// Where there is no selection, as on the phone, a single tap opens and this stays
    /// false. The shell knows which of those it built; this file must not guess.
    let opensOnDoubleTap: Bool
    let onToggle: (Bool) -> Void
    let onMove: (TodayMoveOp) -> Void
    let onFocus: (TodayFocus) -> Void
    let onOpen: () -> Void
    let onDiscuss: () -> Void
    let onPropagate: () -> Void
    let onOpenLink: (TodayLinkOrigin) -> Void

    public init(item: TodayItem, pending: Bool = false, evidence: String? = nil,
                availableMoves: [TodayMoveOp] = [],
                focusActions: [TodayFocus] = [],
                opensOnDoubleTap: Bool = false,
                onToggle: @escaping (Bool) -> Void,
                onMove: @escaping (TodayMoveOp) -> Void = { _ in },
                onFocus: @escaping (TodayFocus) -> Void = { _ in },
                onOpen: @escaping () -> Void = {},
                onDiscuss: @escaping () -> Void = {},
                onPropagate: @escaping () -> Void = {},
                onOpenLink: @escaping (TodayLinkOrigin) -> Void = { _ in }) {
        self.item = item
        self.pending = pending
        self.evidence = evidence
        self.availableMoves = availableMoves
        self.focusActions = focusActions
        self.opensOnDoubleTap = opensOnDoubleTap
        self.onToggle = onToggle
        self.onMove = onMove
        self.onFocus = onFocus
        self.onOpen = onOpen
        self.onDiscuss = onDiscuss
        self.onPropagate = onPropagate
        self.onOpenLink = onOpenLink
    }

    private var parts: (lead: String, detail: String) { TodaySemantics.leadAndDetail(item) }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The project, as a rule down the leading edge. Never the only cue: the
            // caption under the text names the project in words.
            TodayProjectAccentBar(project: item.project)
            TodayCheckbox(checked: item.checked, pending: pending) { onToggle(!item.checked) }
            VStack(alignment: .leading, spacing: 4) {
                text
                ForEach(TodaySemantics.continuationLines(item), id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TodayLinkChips(links: item.links, sourceText: item.text, onOpen: onOpenLink)
                if let evidence {
                    Label(evidence, systemImage: "text.quote")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                caption
            }
            Spacer(minLength: 0)
            TodayItemMenu(item: item, availableMoves: availableMoves,
                          focusActions: focusActions, onMove: onMove, onFocus: onFocus,
                          onDiscuss: onDiscuss, onPropagate: onPropagate)
        }
        .padding(.vertical, 4)
        // Tapping the row opens the item. A GESTURE rather than a `Button` or a
        // `NavigationLink` wrapping the row, because the row already contains three
        // controls — the checkbox, the link chips, the ellipsis — and a button wrapping
        // buttons either swallows their taps or renders them inert. A child `Button`
        // handles its own tap before this ever sees it, which is exactly the division
        // wanted: the checkbox ticks, a chip opens its link, the rest of the row opens
        // the item.
        //
        // One tap or two, per `opensOnDoubleTap`: in a selectable list the single click
        // belongs to the selection, so the open moves to the second one.
        .contentShape(.rect)
        .onTapGesture(count: opensOnDoubleTap ? 2 : 1, perform: onOpen)
        // The same actions the ellipsis menu offers, on a long press. Two ways in
        // rather than two menus: `TodayItemActions` is the single list, so an action
        // added to it appears in both without either falling behind the other.
        .contextMenu {
            TodayItemActions(item: item, availableMoves: availableMoves,
                             focusActions: focusActions, onMove: onMove, onFocus: onFocus,
                             onDiscuss: onDiscuss, onPropagate: onPropagate)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open item", onOpen)
    }

    /// The bookkeeping line under a row: which project the item rolls up to, then its
    /// dates.
    ///
    /// The project is named IN WORDS, never by colour alone — the palette is chosen to
    /// survive colour blindness, but no palette says anything to a screen reader, and a
    /// row whose only project cue is a hue is a row that loses it under Grayscale. The
    /// stripe down the row's edge is the fast cue; this is the one that survives.
    ///
    /// No dot here any more: the stripe carries the colour, and a dot beside the label
    /// would be the same claim made twice on every row. An `unfiled` item shows nothing
    /// at all — "no project" is an absence, and the words "No project" under the large
    /// minority of items that have none would be the most repeated text on the screen.
    @ViewBuilder
    private var caption: some View {
        let dates = TodaySemantics.dateCaption(item)
        if !item.project.isUnfiled || dates != nil {
            HStack(spacing: 6) {
                if !item.project.isUnfiled {
                    Text(TodayProjectPalette.role(for: item.project).label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            TodayProjectPalette.role(for: item.project).accessibilityLabel)
                }
                if let dates {
                    Text(dates)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The bold lead and the rest of the line as one string, so it wraps as a
    /// paragraph rather than as two stacked blocks. A completed row is struck through
    /// and dimmed; the text stays readable because a done item is still evidence of
    /// what the day held.
    private var text: some View {
        Text(attributed)
            .font(.body)
            .strikethrough(item.checked, color: .secondary)
            .foregroundStyle(item.checked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One attributed string rather than two concatenated `Text`s, so the lead and
    /// the detail wrap as a single paragraph — and because `Text + Text` is deprecated
    /// on the platforms this targets.
    private var attributed: AttributedString {
        let (lead, detail) = parts
        var out = AttributedString(lead)
        out.font = .body.weight(.semibold)
        guard !detail.isEmpty else { return out }
        out.append(AttributedString(" " + detail))
        return out
    }
}

// MARK: - The per-item menu

/// The row's overflow menu: the moves that would actually do something, plus the two
/// conversation actions. Rendered as nothing at all when there is nothing to offer —
/// which is the case for the standing lead item, whose every move the bridge refuses.
/// The complete set of actions for one row, as menu buttons. Rendered by the
/// ellipsis menu AND by the row's context menu, so the two can never disagree.
struct TodayItemActions: View {
    let item: TodayItem
    let availableMoves: [TodayMoveOp]
    let focusActions: [TodayFocus]
    let onMove: (TodayMoveOp) -> Void
    let onFocus: (TodayFocus) -> Void
    let onDiscuss: () -> Void
    let onPropagate: () -> Void

    var body: some View {
        // Focus first, and above the divider: "work on this next" is what a user
        // actually wants from a row, and it stays in the same place whatever the view
        // sort is doing — unlike the relative moves below it, which the list withholds
        // while a sort is on because their direction would be meaningless.
        ForEach(focusActions) { focus in
            Button { onFocus(focus) } label: {
                Label(focus.label, systemImage: focus.symbol)
            }
        }
        if !focusActions.isEmpty { Divider() }
        Button { onDiscuss() } label: {
            Label("Discuss this item", systemImage: "bubble.left.and.text.bubble.right")
        }
        // Propagation closes an item AT SOURCE — in its project file and its
        // Dashboard — so it is only offered for something already completed.
        // Offering it on an open item would invite a turn that closes work the
        // user has not done.
        if item.checked {
            Button { onPropagate() } label: {
                Label("Close it at source", systemImage: "arrow.up.forward.square")
            }
        }
        // The moves a focus button already covers are dropped rather than listed twice:
        // "Focus — move to Do Now" and "Move to Do Now" are the same write, and a menu
        // that offers both invites the reading that they differ.
        let focused = Set(focusActions.map(\.moveOp))
        let remaining = availableMoves.filter { !focused.contains($0) }
        if !remaining.isEmpty {
            Divider()
            ForEach(remaining, id: \.self) { op in
                Button { onMove(op) } label: {
                    Label(TodaySemantics.label(for: op),
                          systemImage: TodaySemantics.symbol(for: op))
                }
            }
        }
    }
}

struct TodayItemMenu: View {
    let item: TodayItem
    let availableMoves: [TodayMoveOp]
    let focusActions: [TodayFocus]
    let onMove: (TodayMoveOp) -> Void
    let onFocus: (TodayFocus) -> Void
    let onDiscuss: () -> Void
    let onPropagate: () -> Void

    var body: some View {
        Menu {
            TodayItemActions(item: item, availableMoves: availableMoves,
                             focusActions: focusActions, onMove: onMove, onFocus: onFocus,
                             onDiscuss: onDiscuss, onPropagate: onPropagate)
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        // No `.menuStyle` here on purpose: the borderless-button style is a macOS
        // spelling, and this file must compile unchanged for both platforms. The
        // automatic style plus a hidden indicator gives the same bare-glyph result.
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(item.lead)")
    }
}
