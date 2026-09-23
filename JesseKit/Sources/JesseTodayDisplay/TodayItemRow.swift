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
    /// Whether the claim is being HELD for replay rather than sent. Distinct from
    /// `pending`, which means "sent, not yet acknowledged" — the box is committed
    /// either way, and the difference is whether the bridge has heard about it at all.
    let queued: Bool
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
                // A QUEUED claim wears a dotted ring — the visual grammar of "this is
                // real but not yet delivered", and a cue that survives Grayscale because
                // it is a shape rather than a hue. The row's caption says it in words
                // too; neither is the only cue.
                .overlay {
                    if queued {
                        Circle()
                            .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                            .frame(width: 26, height: 26)
                    }
                }
                .contentShape(.rect)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(checked ? [.isSelected, .isButton] : .isButton)
    }

    private var accessibilityLabel: String {
        let state = checked ? "Completed" : "Not completed"
        return queued ? "\(state), saved offline and waiting to send" : state
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
    /// This row's change is HELD for replay — captured while the bridge was out of
    /// reach. See `TodayCheckbox.queued`.
    let queued: Bool
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
    /// Whether a pointer hovering this row reveals a chevron that opens it.
    ///
    /// A parameter for the same reason `opensOnDoubleTap` is one, and it is the same
    /// fact seen from the other side: where opening costs two clicks, nothing on screen
    /// says so, and the gesture was undiscoverable — the person who wrote the spec could
    /// not find it. The Mac shell passes true; the phone passes false, because a tap
    /// already opens the row and a hover is not a gesture a finger has.
    let revealsOpenOnHover: Bool
    let onToggle: (Bool) -> Void
    let onMove: (TodayMoveOp) -> Void
    let onFocus: (TodayFocus) -> Void
    let onPostpone: () -> Void
    let onOpen: () -> Void
    let onDiscuss: () -> Void
    let onPropagate: () -> Void
    let onOpenLink: (TodayLinkOrigin) -> Void

    public init(item: TodayItem, pending: Bool = false, queued: Bool = false,
                evidence: String? = nil,
                availableMoves: [TodayMoveOp] = [],
                focusActions: [TodayFocus] = [],
                opensOnDoubleTap: Bool = false,
                revealsOpenOnHover: Bool = false,
                onToggle: @escaping (Bool) -> Void,
                onMove: @escaping (TodayMoveOp) -> Void = { _ in },
                onFocus: @escaping (TodayFocus) -> Void = { _ in },
                onPostpone: @escaping () -> Void = {},
                onOpen: @escaping () -> Void = {},
                onDiscuss: @escaping () -> Void = {},
                onPropagate: @escaping () -> Void = {},
                onOpenLink: @escaping (TodayLinkOrigin) -> Void = { _ in }) {
        self.item = item
        self.pending = pending
        self.queued = queued
        self.evidence = evidence
        self.availableMoves = availableMoves
        self.focusActions = focusActions
        self.opensOnDoubleTap = opensOnDoubleTap
        self.revealsOpenOnHover = revealsOpenOnHover
        self.onToggle = onToggle
        self.onMove = onMove
        self.onFocus = onFocus
        self.onPostpone = onPostpone
        self.onOpen = onOpen
        self.onDiscuss = onDiscuss
        self.onPropagate = onPropagate
        self.onOpenLink = onOpenLink
    }

    /// Whether a pointer is over this row. Only ever true where there IS a pointer, and
    /// only ever read together with `revealsOpenOnHover`, so on a phone it is dead
    /// weight rather than a behaviour.
    @State private var isHovering = false

    private var parts: (lead: String, detail: String) { TodaySemantics.leadAndDetail(item) }

    /// Whether the chevron is on screen right now. Pure, and the reason the rule is
    /// assertable without a pointer: reveal only where the shell asked for it, and only
    /// under a pointer.
    static func showsOpenControl(reveals: Bool, hovering: Bool) -> Bool {
        reveals && hovering
    }

    /// The tooltip, or nothing. A row that opens on a single tap needs no sentence about
    /// how to open it, and `.help` on a phone would be a string nobody ever sees.
    static func openHelp(reveals: Bool) -> String? {
        reveals ? "Double-click to open" : nil
    }

    /// The row's complete action list, built ONCE and handed to both the ellipsis menu and
    /// the context menu. Two constructions would be two places for an action to go
    /// missing, and this one is also the seam a test reads to prove the row's own `onOpen`
    /// is what the menu's Open entry calls.
    var actions: TodayItemActions {
        TodayItemActions(item: item, availableMoves: availableMoves,
                         focusActions: focusActions, onOpen: onOpen, onMove: onMove,
                         onFocus: onFocus, onPostpone: onPostpone, onDiscuss: onDiscuss,
                         onPropagate: onPropagate)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The project, as a rule down the leading edge. Never the only cue: the
            // caption under the text names the project in words.
            TodayProjectAccentBar(project: item.project)
            TodayCheckbox(checked: item.checked, pending: pending,
                          queued: queued) { onToggle(!item.checked) }
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
            // The chevron a pointer reveals: one click, no selection needed, and the
            // only thing on the row that SAYS it opens. It sits before the ellipsis so
            // the pair reads left to right as "open this" then "everything else", and it
            // keeps its space when hidden — revealing it must not re-lay out the row
            // under the pointer that is about to click it. Hidden from VoiceOver
            // throughout: the row already publishes an "Open item" action, and a control
            // no pointer-less user can reveal would be a second, unreachable copy of it.
            let showsChevron = Self.showsOpenControl(reveals: revealsOpenOnHover,
                                                     hovering: isHovering)
            TodayOpenChevron(onOpen: onOpen)
                .opacity(showsChevron ? 1 : 0)
                .allowsHitTesting(showsChevron)
                .accessibilityHidden(true)
            TodayItemMenu(item: item, actions: actions)
        }
        .padding(.vertical, 4)
        .onHover { isHovering = $0 }
        .help(ifPresent: Self.openHelp(reveals: revealsOpenOnHover))
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
        .contextMenu { actions }
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
        let maybeStale = item.relevance?.stale == true
        if !item.project.isUnfiled || dates != nil || TodaySemantics.isPostponed(item) || queued
            || maybeStale {
            HStack(spacing: 6) {
                // The words behind the dotted ring. A ring alone says "something about
                // this is different"; only the caption says what, and it is the half a
                // screen reader gets.
                if queued {
                    Text("Queued")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Saved offline, waiting to send")
                }
                // The chip is the cue that survives. Dimming alone says "postponed"
                // only to someone who can see the row beside an undimmed one, which
                // is nobody using VoiceOver and nobody looking at a section where
                // everything is set aside.
                if TodaySemantics.isPostponed(item) {
                    Text("Postponed")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Postponed until tomorrow")
                }
                // The brief suspects this is finished (or its deadline has passed) but
                // could not clear the bar to close it. A WORD, not a colour: this is the
                // one row cue that invites an action, and it has to reach a reader who
                // cannot see the row beside an unmarked one. The reason rides in the
                // accessibility label rather than the chip — the chip has to stay short
                // enough to sit beside a project label and a date on a phone.
                if let relevance = item.relevance, relevance.stale {
                    let overdue = relevance.verdict == .overdue
                    Text(overdue ? "Overdue" : "Maybe done")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(overdue
                            ? "Overdue. \(relevance.reason)"
                            : "May already be done. \(relevance.reason)")
                }
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
    ///
    /// A POSTPONED row is dimmed and NOT struck through, and the distinction is the
    /// whole reason postponing exists: a strikethrough says "done", and saying that
    /// about work nobody did is exactly the lie a checkbox tap was being used to
    /// tell. Set aside reads as set aside — quieter than the live rows, still there.
    private var text: some View {
        Text(attributed)
            .font(.body)
            .strikethrough(item.checked, color: .secondary)
            .foregroundStyle(item.checked || item.deferred || queued
                             ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
            // Prefixed rather than appended: a screen reader reaches the row's state
            // before the sentence it applies to, which is the order the sighted cue
            // arrives in too.
            .accessibilityLabel(TodaySemantics.isPostponed(item)
                                ? "Postponed until tomorrow. \(String(attributed.characters))"
                                : String(attributed.characters))
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

/// The trailing chevron a pointer reveals. A single click opens the row, whatever the
/// row's own tap count is: a control is not a gesture and does not need the selection
/// click that forced the double tap in the first place.
struct TodayOpenChevron: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open this item")
    }
}

extension View {
    /// `.help` only when there is something to say, so a platform with no pointer never
    /// carries a tooltip string it cannot show.
    @ViewBuilder
    func help(ifPresent text: String?) -> some View {
        if let text { self.help(text) } else { self }
    }
}

// MARK: - The per-item menu

/// The row's overflow menu: the moves that would actually do something, plus the two
/// conversation actions. Rendered as nothing at all when there is nothing to offer —
/// which is the case for the standing lead item, whose every move the bridge refuses.
/// The complete set of actions for one row, as menu buttons. Rendered by the
/// ellipsis menu AND by the row's context menu, so the two can never disagree.
struct TodayItemActions: View {
    /// What the Open entry says. One constant, because the accessibility action, the
    /// tooltip and this button are three ways of saying the same thing and a test reads
    /// it rather than a literal.
    static let openLabel = "Open"

    let item: TodayItem
    let availableMoves: [TodayMoveOp]
    let focusActions: [TodayFocus]
    let onOpen: () -> Void
    let onMove: (TodayMoveOp) -> Void
    let onFocus: (TodayFocus) -> Void
    let onPostpone: () -> Void
    let onDiscuss: () -> Void
    let onPropagate: () -> Void

    var body: some View {
        // OPEN FIRST, and it is the reason this list starts here rather than at Focus.
        // The row's main action was the one thing the menu did not offer: the Mac opened
        // on a double click nothing advertised, and a menu that lists move, focus,
        // postpone, discuss and propagate but not "open" reads as though opening is not
        // a thing a row does. On the phone it duplicates the tap, which costs a line and
        // settles the question for anyone who goes looking.
        Button { onOpen() } label: {
            Label(Self.openLabel, systemImage: "doc.text.magnifyingglass")
        }
        Divider()
        // Focus first among the WRITES, and above the second divider: "work on this
        // next" is what a user actually wants from a row, and it stays in the same
        // place whatever the view sort is doing — unlike the relative moves below it,
        // which the list withholds while a sort is on because their direction would be
        // meaningless.
        ForEach(focusActions) { focus in
            Button { onFocus(focus) } label: {
                Label(focus.label, systemImage: focus.symbol)
            }
        }
        // Beside the focus actions, and above the Discuss divider: postponing is a
        // decision about the WORK ("not today"), which is the same kind of thing as
        // "this next" and a different kind of thing from starting a conversation
        // about it. The one slot says both halves of the toggle, because a row that
        // is already set aside needs the way back more than it needs the way in.
        Button { onPostpone() } label: {
            Label(item.deferred ? "Bring back to today" : "Postpone until tomorrow",
                  systemImage: item.deferred ? "arrow.uturn.backward" : "moon.zzz")
        }
        // Unconditional now: the postpone toggle above is offered for every row,
        // including the standing lead item, so there is always something above this
        // line to separate the conversation actions from.
        Divider()
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
        // The cross-section moves are gathered into a submenu of their own: a day
        // file has eight or nine headings, and nine more buttons in a flat list would
        // bury the four that are about this row's own position.
        let sections = remaining.filter { $0.destinationSection != nil }
        let reorders = remaining.filter { $0.destinationSection == nil }
        if !reorders.isEmpty || !sections.isEmpty {
            Divider()
            ForEach(reorders, id: \.self) { op in
                Button { onMove(op) } label: {
                    Label(TodaySemantics.label(for: op),
                          systemImage: TodaySemantics.symbol(for: op))
                }
            }
            if !sections.isEmpty {
                Menu {
                    // Each entry is its section's FULL name, verbatim. The day file
                    // carries both a `Do Now` and a `Do Now (carried, owed replies and
                    // decisions)`, so shortening them would produce two entries that
                    // read alike and a menu nobody can use.
                    ForEach(sections, id: \.self) { op in
                        Button(TodaySemantics.label(for: op)) { onMove(op) }
                    }
                } label: {
                    Label(TodaySemantics.moveToSectionLabel, systemImage: "folder")
                }
            }
        }
    }
}

struct TodayItemMenu: View {
    let item: TodayItem
    /// The row's one action list, handed in rather than rebuilt: this menu and the
    /// context menu must be the same list, and the only way to guarantee that is for
    /// there to be one.
    let actions: TodayItemActions

    var body: some View {
        Menu {
            actions
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
