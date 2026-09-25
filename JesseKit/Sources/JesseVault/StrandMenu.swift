import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// ONE MENU FOR A STRAND, WHEREVER A STRAND IS LISTED.
//
// A strand is listed in two places that share no code at all: the Today tab's board
// (`StrandsListView`, JesseTodayDisplay) and the Vault tab's Strands scope
// (`VaultBrowserView`, here). Before this, a row in either place answered exactly one
// gesture — a tap, which opens the note — so discussing a strand, or giving the agent an
// update on one, meant typing its name into a fresh chat and hoping the agent found the
// right note.
//
// The menu is therefore ONE definition and not two, and the definition is a list of CASES
// rather than a sequence of `Button`s: `StrandMenuAction.allCases` is the menu, in order,
// and both surfaces render it by iterating that. An action added to the enum appears on
// both surfaces in the same place, and neither surface can grow one the other lacks —
// which is the failure this shape exists to make impossible, and which a test pins by
// comparing the two surfaces' own menus.
//
// ## Why it lives in JesseVault
//
// Because this is the one target both surfaces can reach. JesseTodayDisplay depends on
// JesseVault (a day row falls back to the local copy of a note); nothing depends on
// JesseTodayDisplay. The alternative — a third target for five buttons — buys nothing.
//
// It costs this target no new knowledge: the menu holds CLOSURES, so nothing here knows
// what a conversation, a coordinator or a bridge is. The dependency arrow this target's
// `Package.swift` comment guards still points nowhere.
//
// ## What each surface supplies, and what the shell supplies
//
// Two of the five actions are things a screen can do for itself (open the note, copy the
// link) and two are things it cannot: starting a conversation needs the app's coordinator,
// and showing the record from the BOARD needs the Vault tab, which is a different tab.
// Those arrive as environment actions the shell injects, exactly as `VaultReviewAction`
// does for a marked up note — see `VaultAnnotationReview`. The Vault tab itself needs no
// injection for the record: it narrows its own model in place.

// MARK: - Which strand

/// The strand a menu is about: enough to open it, to talk about it, and to link to it.
public struct StrandMenuTarget: Equatable, Hashable, Sendable, Identifiable {
    /// The note's file name without `.md` (`Jesse`), which is how the rest of the vault
    /// refers to this strand.
    public let slug: String
    /// The title as the surface that was pressed shows it.
    public let title: String
    /// The note's vault relative path, the archive included.
    public let path: String

    public var id: String { path }

    /// The board's case: it holds a wire `Strand`, which already knows its own note path
    /// (`Strand.notePath`), so the convention `Strands/<slug>.md` is spelled ONCE, over
    /// there, and never derived a second time here.
    public init(slug: String, title: String, path: String) {
        self.slug = slug
        self.title = title
        self.path = path
    }

    /// The target for a note at `path` — a Vault row's own case, where the path is the
    /// fact and the slug is derived from it.
    ///
    /// Nil for a path that is not a strand note, which is what keeps the menu off the
    /// 7,600 rows in this tab that are not strands. `Strands/archive/` is IN: a finished
    /// strand is still a strand, and its record is the reason the scope reaches the
    /// archive at all.
    public static func note(path: String, title: String) -> StrandMenuTarget? {
        guard path.hasPrefix(VaultStrandRecord.folder) else { return nil }
        return StrandMenuTarget(slug: VaultStrandRecord.slug(of: path), title: title,
                                path: path)
    }

    /// The wiki link that addresses this strand from anywhere in the vault.
    ///
    /// Always the LIVE spelling (`todo-list/Strands/<slug>`), even for a note that is
    /// currently archived. That is how the vault's own notes link a strand, and a link
    /// pasted into a project file should keep working when the strand is revived; the
    /// resolver treats the archive as a fallback for exactly this reason.
    public var wikiLink: String { "[[todo-list/\(VaultStrandRecord.folder)\(slug)]]" }
}

// MARK: - The five actions

/// **The strand menu, as data**: the five things a strand offers, in the order it offers
/// them. Both surfaces render this list and neither adds to it.
///
/// The order is read top to bottom as "what am I looking at" then "what do I want to say
/// about it": the note first (the one thing the row's tap already does, so the menu never
/// reads as though opening is not something a row does), the conversation second, the two
/// record views third, and the link last, because copying one is bookkeeping.
public enum StrandMenuAction: String, CaseIterable, Identifiable, Equatable, Sendable {
    case openNote
    case discuss
    case search
    case decisions
    case copyLink

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openNote: return "Open note"
        case .discuss: return "Discuss this strand"
        case .search: return "Search this strand"
        case .decisions: return "Decisions"
        case .copyLink: return "Copy link"
        }
    }

    public var symbol: String {
        switch self {
        case .openNote: return "doc.text"
        // The glyph a Today row's Discuss carries, because it is the same act.
        case .discuss: return "bubble.left.and.text.bubble.right"
        case .search: return "magnifyingglass"
        case .decisions: return "checkmark.seal"
        case .copyLink: return "link"
        }
    }

    /// The section of the record this action shows, or nil for an action that shows no
    /// record. `Search` is the whole note; `Decisions` is the same view with the chip on.
    public var recordSection: VaultStrandSection? {
        switch self {
        case .search: return .all
        case .decisions: return .decisions
        case .openNote, .discuss, .copyLink: return nil
        }
    }
}

// MARK: - The shell's two actions

/// The shell's "open a conversation about this strand" action.
///
/// It is the shell's because only the shell owns a conversation store and a coordinator.
/// Nil where none is injected (a preview, a test that does not care), in which case the
/// entry is still listed and does nothing — the alternative, hiding it, would mean the
/// two surfaces could show different menus depending on where they were mounted, which is
/// the one property this whole file exists to hold.
public struct StrandDiscussAction {
    private let startHandler: @MainActor (StrandMenuTarget) -> Void

    public init(start: @escaping @MainActor (StrandMenuTarget) -> Void) {
        self.startHandler = start
    }

    @MainActor
    public func start(_ target: StrandMenuTarget) { startHandler(target) }
}

/// The shell's "show this strand's record in the Vault tab" action.
///
/// Needed only by a surface that is NOT the Vault tab: showing the record means selecting
/// that tab and narrowing its model, and no package view can select a tab. The Vault tab's
/// own rows never read this — they narrow in place, which is both the right behaviour and
/// one fewer hop.
public struct StrandRecordAction {
    private let showHandler: @MainActor (String, VaultStrandSection) -> Void

    public init(show: @escaping @MainActor (String, VaultStrandSection) -> Void) {
        self.showHandler = show
    }

    @MainActor
    public func show(_ slug: String, section: VaultStrandSection) {
        showHandler(slug, section)
    }
}

private struct StrandDiscussActionKey: EnvironmentKey {
    // `nonisolated(unsafe)` on a nil default, for the reason `VaultReviewActionKey` carries
    // the same annotation: the value holds MainActor closures and so is not Sendable, but
    // nil is trivially safe to read from anywhere.
    nonisolated(unsafe) static let defaultValue: StrandDiscussAction? = nil
}

private struct StrandRecordActionKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: StrandRecordAction? = nil
}

public extension EnvironmentValues {
    /// The shell's "discuss this strand" action, or nil where none is injected.
    var strandDiscuss: StrandDiscussAction? {
        get { self[StrandDiscussActionKey.self] }
        set { self[StrandDiscussActionKey.self] = newValue }
    }

    /// The shell's "show this strand's record in the Vault tab" action, or nil where none
    /// is injected.
    var strandRecord: StrandRecordAction? {
        get { self[StrandRecordActionKey.self] }
        set { self[StrandRecordActionKey.self] = newValue }
    }
}

// MARK: - The pasteboard

/// Copy plain text to the system pasteboard. The peer of `AskPasteboard`, which cannot be
/// reached from here (JesseAsk is not a dependency of this target and must not become one
/// for one line).
public enum StrandPasteboard {
    /// Public because `StrandMenu`'s public initializer defaults to it, which is the one
    /// place a caller outside this module ever names it.
    public static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - The menu

/// One strand's context menu, rendered the same on a long press and on a secondary click.
///
/// Built as a value with its handlers, like `TodayItemActions`, so what a surface WIRED
/// can be read back in a test without rendering anything: the action list, and which
/// closure each entry calls.
public struct StrandMenu: View {
    public let target: StrandMenuTarget
    /// Open the note. The board resolves it through its opener; the Vault tab pushes its
    /// reader.
    let onOpenNote: () -> Void
    /// Start the conversation, if the shell gave this screen a way to.
    let onDiscuss: (() -> Void)?
    /// Show the record, narrowed to one section.
    let onShowRecord: (VaultStrandSection) -> Void
    /// The pasteboard, as a seam: the real one writes to the device, a test reads what was
    /// written. There is nothing else in this type worth faking.
    var copy: (String) -> Void = StrandPasteboard.copy

    public init(target: StrandMenuTarget,
                onOpenNote: @escaping () -> Void,
                onDiscuss: (() -> Void)?,
                onShowRecord: @escaping (VaultStrandSection) -> Void,
                copy: @escaping (String) -> Void = StrandPasteboard.copy) {
        self.target = target
        self.onOpenNote = onOpenNote
        self.onDiscuss = onDiscuss
        self.onShowRecord = onShowRecord
        self.copy = copy
    }

    /// **The menu.** One list, one order, both surfaces.
    public static let actions = StrandMenuAction.allCases

    /// What one entry does. The whole dispatch, in one place a test can drive: a menu
    /// whose buttons each closed over their own logic would be a menu whose behaviour can
    /// only be checked by tapping it.
    public func perform(_ action: StrandMenuAction) {
        switch action {
        case .openNote:
            onOpenNote()
        case .discuss:
            onDiscuss?()
        case .search, .decisions:
            guard let section = action.recordSection else { return }
            onShowRecord(section)
        case .copyLink:
            copy(target.wikiLink)
        }
    }

    public var body: some View {
        ForEach(Self.actions) { action in
            Button { perform(action) } label: {
                Label(action.label, systemImage: action.symbol)
            }
        }
    }
}

// MARK: - Attaching it

public extension View {
    /// Attach `menu` as this row's context menu, or leave the row exactly as it was when
    /// there is no strand behind it.
    ///
    /// The nil case is what keeps the menu off a Vault row that is not a strand note, and
    /// it is spelled as an absent menu rather than an empty one on purpose: an empty
    /// `.contextMenu` is a long press that visibly does nothing, and on iOS it also takes
    /// away the press and hold the row had before.
    @ViewBuilder
    func strandContextMenu(_ menu: StrandMenu?) -> some View {
        if let menu {
            self.contextMenu { menu }
        } else {
            self
        }
    }
}
