import SwiftUI
import SwiftData
import JesseCore
import JesseTodayDisplay
import JesseVault

// The iOS Vault tab: a thin shell around the SHARED vault browser (`VaultBrowserView` in
// JesseVault), holding the one thing that screen cannot hold for itself.
//
// A `Strands/` row in that browser offers `Discuss this strand`, and a discussion is a
// CONVERSATION: a `JesseThread` staged against the coordinator, held while its sheet is up.
// JesseVault knows nothing about threads (by design — see that target's note in
// `Package.swift`), and `RootTabView` must hold no model objects at all, which
// `UnreadBadgeShellTests` asserts: a thread held on the app's root view makes every save to
// it re-evaluate a body that builds all four tabs. So the thread lives HERE, one level down,
// exactly as the Today tab holds its own.
//
// Everything else about the Vault tab is unchanged: the index, the search, the reader and
// the folder all belong to the model `RootTabView` owns (the indexer is driven by app
// activation, which is a fact about the app rather than about this tab).
struct VaultTabView: View {
    /// Owned by `RootTabView`, because the indexer it carries is driven by activation.
    let model: VaultBrowserModel

    @Environment(RunCoordinator.self) private var coordinator

    /// The conversation a `Discuss this strand` opened, if any.
    ///
    /// A SHEET, and modal from this tab rather than a push into the Chats tab's stack, for
    /// the reason the Today tab's own Discuss is one: `ContentView` owns its navigation path
    /// privately, and reaching across would mean lifting that binding into the shell and
    /// switching tabs under the user mid-gesture. Dismissing returns them to the row they
    /// pressed; the thread is in the Chats list either way once they send.
    @State private var openedThread: JesseThread?

    /// The thread a discussion STAGED, held only so its attached context can be dropped if
    /// the sheet is dismissed without a send. `.sheet(item:)` nils its binding before
    /// calling `onDismiss`, so the id cannot be read from there.
    @State private var stagedThreadID: UUID?

    var body: some View {
        VaultBrowserView(model: model)
            .environment(\.strandDiscuss, StrandDiscussAction { target in discuss(target) })
            .sheet(item: $openedThread, onDismiss: dropUnsentContext) { thread in
                // `hidesTabBar: false`: a sheet already covers the bar, and asking the
                // detail view to hide it would leave it hidden after the sheet has gone.
                NavigationStack { ThreadDetailView(thread: thread, hidesTabBar: false) }
            }
    }

    /// **Discuss one strand**: open a conversation about it and start nothing.
    ///
    /// The strand's frozen prompt — which names the note, says to read it first, and grants
    /// the bounded permission to record an update Jeremy gives — rides along as ATTACHED
    /// context and reaches the bridge with his own first message, exactly as an item
    /// discussion does (`TodayThreadOpener.stage`). Never gated on reachability: it starts
    /// nothing, and the conversation it opens is the one screen in this app where the send
    /// outbox and its per-message Retry are visible.
    private func discuss(_ target: StrandMenuTarget) {
        let thread = TodayThreadOpener.stage(.discuss(strand: target), coordinator: coordinator)
        stagedThreadID = thread.id
        openedThread = thread
    }

    /// Dismissing a staged discussion without sending drops the context with it — a no-op
    /// once the first send has consumed it.
    private func dropUnsentContext() {
        if let id = stagedThreadID { coordinator.clearAttachedContext(for: id) }
        stagedThreadID = nil
    }
}
