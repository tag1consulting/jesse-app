import SwiftUI

// The GESTURE half of "Ask about this": one view modifier, and the seam the app shells
// plug their existing chat into.
//
// ZERO ADDED CLUTTER IS THE WHOLE DESIGN CONSTRAINT. `.askable` attaches a native
// `contextMenu` and nothing else — no icon, no badge, no chip, no overlay, no hover
// affordance invented for the occasion. At rest the Health tab renders exactly as it did
// before; the menu exists only while a long press (iOS) or a right-click (macOS) is
// happening, and both are the platform's own gesture with the platform's own preview.
//
// macOS gets right-click from the same modifier — `contextMenu` IS the right-click menu
// there. It deliberately gets NOTHING on hover: this app has no hover-reveal affordance
// anywhere (there is not one `onHover` in either shell), and inventing one here would be
// the clutter the brief rules out. See the note in the CHANGELOG.
//
// The package cannot present the chat — the conversation store, the coordinator and the
// sheet all live in the app targets, and there are two different ones. So the action is
// injected: each shell puts a `HealthAskAction` in the environment and every askable view
// at any depth finds it. A screen with no action injected shows no menu at all, which is
// what keeps previews and tests inert.

// MARK: - The action

/// What a shell does when an ask is made: open the app's chat carrying this context.
///
/// A closure in the environment, in the shape SwiftUI's own actions (`openURL`,
/// `dismiss`) take, so a call site reads `ask(context)`.
public struct HealthAskAction {
    private let handler: @MainActor (HealthAskContext) -> Void

    public init(_ handler: @escaping @MainActor (HealthAskContext) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(_ context: HealthAskContext) { handler(context) }
}

private struct HealthAskActionKey: EnvironmentKey {
    // `nonisolated(unsafe)` on a `nil` default. `HealthAskAction` holds a MainActor
    // closure and so is not Sendable, which makes a plain `static let` of it a
    // concurrency error under Swift 6 — but the value here IS nil, which is trivially
    // safe to read from anywhere. Marking the closure `@Sendable` instead would push the
    // requirement onto every call site, where it would fail: a shell's handler captures
    // its own View (`@State` setters), and a View is not Sendable.
    nonisolated(unsafe) static let defaultValue: HealthAskAction? = nil
}

public extension EnvironmentValues {
    /// The shell's "open a chat about this" action, or nil where none is injected — in
    /// which case no askable view offers a menu.
    var healthAsk: HealthAskAction? {
        get { self[HealthAskActionKey.self] }
        set { self[HealthAskActionKey.self] = newValue }
    }
}

// MARK: - Placement & glyph

extension ToolbarItemPlacement {
    /// Where a page's own Ask entry sits. The Health sub-pages carry no other toolbar
    /// items, so this is simply the trailing action slot on both platforms; the tab ROOT
    /// declares its Ask in the shell instead, ahead of the existing buttons, so the
    /// established left-to-right-by-frequency order there is not disturbed.
    static var dietAsk: ToolbarItemPlacement {
        #if os(iOS)
        return .primaryAction
        #else
        return .automatic
        #endif
    }
}

/// The one glyph the feature uses, in the one place it is allowed to appear: a page's
/// toolbar entry. Never on a card, a row, or a chart.
enum HealthAskGlyph {
    static let name = "text.bubble"
}

// MARK: - The modifier

/// Attaches the context menu that opens a chat about this view.
private struct AskableModifier: ViewModifier {
    @Environment(\.healthAsk) private var ask
    let context: () -> HealthAskContext
    /// Text this view could previously have its long press COPY (it had
    /// `.textSelection(.enabled)`), or nil where there was nothing to preserve.
    let copyText: (() -> String)?

    func body(content: Content) -> some View {
        if let ask {
            // No `.contextMenu(menuItems:preview:)`: the system's free preview of the view
            // being pressed is exactly right, and a hand-built one would be a second
            // rendering of the same card to keep in step.
            content.contextMenu { items(ask) }
        } else {
            content
        }
    }

    /// The menu. One item where the view had no long-press behavior of its own — worded
    /// for what was actually pressed ("Ask about this meal"), and text-only, because a
    /// glyph in a one-item menu is decoration.
    ///
    /// TWO items where the view DID have one. Attaching a `contextMenu` replaces the
    /// system's press-and-hold text selection, so a row that could be selected and copied
    /// gets its Copy back here rather than silently losing it.
    @ViewBuilder
    private func items(_ ask: HealthAskAction) -> some View {
        let context = self.context()
        Button(context.menuLabel) { ask(context) }
        if let copyText {
            Button("Copy") { PlatformPasteboard.copy(copyText()) }
        }
    }
}

/// A page's own Ask entry, in the toolbar slot the app already uses for page actions.
private struct AskPageToolbarModifier: ViewModifier {
    @Environment(\.healthAsk) private var ask
    let context: () -> HealthAskContext

    func body(content: Content) -> some View {
        if let ask {
            content.toolbar {
                ToolbarItem(placement: .dietAsk) {
                    // The context is built INSIDE the action, not beside the label: a page
                    // context is the union of every section on it, and building one on
                    // every render of a screen nobody has asked about yet is work for
                    // nothing. The row-level modifier can afford to build eagerly (it
                    // needs the noun for the menu wording); this one cannot and does not
                    // need to.
                    Button { ask(context()) } label: {
                        Label("Ask", systemImage: HealthAskGlyph.name)
                    }
                    .help("Ask Jesse about this page")
                    .accessibilityLabel("Ask about this page")
                }
            }
        } else {
            content
        }
    }
}

public extension View {
    /// Make this view askable: long-press (iOS) or right-click (macOS) offers one item,
    /// "Ask about this …", which opens the app's chat already holding a snapshot of
    /// exactly what is on screen here.
    ///
    /// One line per view, and the same line whether the view is a card, a row, a chart,
    /// or a section header — which is what makes a new Health section askable for free.
    /// Nothing is drawn, nothing moves, and existing taps, swipes and navigation are
    /// untouched: a `contextMenu` composes with them rather than replacing them.
    ///
    /// `@autoclosure` so a call site stays one expression; the context is built during
    /// this view's own body evaluation, alongside the numbers it serializes.
    func askable(_ context: @autoclosure @escaping () -> HealthAskContext) -> some View {
        modifier(AskableModifier(context: context, copyText: nil))
    }

    /// Askable, for a view that ALREADY had a long press.
    ///
    /// `.textSelection(.enabled)` gives press-and-hold selection with a Copy callout, and
    /// a `contextMenu` takes that gesture over. Rather than quietly removing an
    /// affordance, those views pass the text their selection would have yielded and the
    /// menu carries a Copy of its own beside the ask.
    func askable(_ context: @autoclosure @escaping () -> HealthAskContext,
                 copyText: @autoclosure @escaping () -> String) -> some View {
        modifier(AskableModifier(context: context, copyText: copyText))
    }

    /// Give this page its own Ask entry in the toolbar, covering everything visible on it
    /// for the current time range. The aggregate entry point — "what's good and what's
    /// bad about today" has to work with nothing selected.
    func askPageToolbar(_ context: @autoclosure @escaping () -> HealthAskContext) -> some View {
        modifier(AskPageToolbarModifier(context: context))
    }
}
