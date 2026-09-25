import SwiftUI
import SwiftData
import JesseCore
import JesseTodayDisplay
import JesseVault

// The Mac's Vault tab: a thin shell around the SHARED vault browser (`VaultBrowserView` in
// JesseVault), holding the one thing that screen cannot hold for itself, and the peer of the
// iPhone's `VaultTabView` in every respect.
//
// A `Strands/` row in that browser offers `Discuss this strand` on a secondary click, and a
// discussion is a CONVERSATION: a `JesseThread` staged against this window's coordinator and
// held while its sheet is up. JesseVault knows nothing about threads by design, and the tab
// shell above must not hold one either — a thread held there makes every save to it
// re-evaluate a body that builds all four tabs. So it lives HERE, exactly as `MacTodayView`
// holds the thread for its own Discuss.
struct MacVaultTabView: View {
    /// Owned by `MacShellView`, because the indexer it carries is driven by the window
    /// becoming active rather than by this tab being shown.
    let model: VaultBrowserModel

    @Environment(MacCoordinator.self) private var coordinator

    /// The conversation a `Discuss this strand` opened, if any. A sheet, as on the Today
    /// tab: the Chats tab is a separate view tree whose selection `MacRootView` owns
    /// privately, and closing the sheet returns Jeremy to the row he clicked.
    @State private var openedThread: JesseThread?

    /// The thread that discussion STAGED, held only so its attached context can be dropped
    /// if the sheet is closed without a send.
    @State private var stagedThreadID: UUID?

    var body: some View {
        VaultBrowserView(model: model)
            .environment(\.strandDiscuss, StrandDiscussAction { target in discuss(target) })
            .sheet(item: $openedThread, onDismiss: dropUnsentContext) { thread in
                MacTodayConversationSheet(thread: thread) { openedThread = nil }
            }
    }

    /// **Discuss one strand**: open a conversation about it and start nothing. The strand's
    /// frozen prompt rides along as ATTACHED context and reaches the bridge with Jeremy's
    /// own first message, exactly as an item discussion does.
    private func discuss(_ target: StrandMenuTarget) {
        let thread = MacTodayThreadOpener.stage(.discuss(strand: target),
                                                coordinator: coordinator)
        stagedThreadID = thread.id
        openedThread = thread
    }

    /// Closing a staged discussion without sending drops the context with it — a no-op once
    /// the first send has consumed it.
    private func dropUnsentContext() {
        if let id = stagedThreadID { coordinator.clearAttachedContext(for: id) }
        stagedThreadID = nil
    }
}
