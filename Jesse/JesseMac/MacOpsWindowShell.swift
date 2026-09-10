import SwiftUI
import SwiftData
import JesseAsk
import JesseCore

/// The two Ops WINDOWS' shared shell: the navigation stack they need, the "Ask about this"
/// action injected for everything inside them, and the sheet an ask opens.
///
/// It exists because the Ops screens on this platform are `Window` scenes rather than tabs,
/// and a scene starts with nothing: the coordinator and the model container reach it only
/// because `JesseMacApp` hands them to each scene explicitly. Wrapping the content is what
/// lets both windows get the same three things from one place — and it is why `OpsView`
/// itself still brings no stack of its own, which is what keeps it shared with iOS.
///
/// The placement of `.environment(\.jesseAsk, …)` matters and is the same choice the Mac
/// Health view writes down: it goes ON THE STACK, not on the content, because a view pushed
/// by a `NavigationLink` (the Schedule sub-page) is presented BY the stack rather than
/// rendered as a child of its root.
struct MacOpsWindowShell<Content: View>: View {
    @Environment(MacCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var context

    /// The conversation an ask opened, presented modally over the window — the same
    /// reasoning the Health tab records: `MacRootView` owns the Chats selection privately,
    /// so reaching across to it would mean lifting that binding into the shell and
    /// switching windows under the user mid-gesture. The conversation is a real thread in
    /// the store, so it is in the sidebar afterwards either way.
    @State private var askThread: JesseThread?
    /// The thread an ask STAGED, remembered only so its attached context can be dropped if
    /// the sheet is closed without a send.
    @State private var stagedAskID: UUID?

    @ViewBuilder var content: () -> Content

    var body: some View {
        NavigationStack { content() }
            .environment(\.jesseAsk, AskAction { openAsk($0) })
            .sheet(item: $askThread, onDismiss: dropUnsentAsk) { thread in
                MacAskSheet(thread: thread) { askThread = nil }
            }
    }

    /// Open the chat about whatever was right-clicked: today's conversation about that
    /// exact reading if there is one, else a fresh one carrying the snapshot. The same
    /// `MacAskOpener` the Health tab uses — it knows nothing about which screen a context
    /// came from, which is why there is one of it.
    private func openAsk(_ ask: AskContext) {
        let thread = MacAskOpener.open(ask, coordinator: coordinator, modelContext: context)
        // Only a STAGED thread has an attachment worth dropping on dismissal.
        stagedAskID = thread.modelContext == nil ? thread.id : nil
        askThread = thread
    }

    /// Closing an ask without sending drops its context with it — a no-op once the first
    /// send has consumed it.
    private func dropUnsentAsk() {
        if let id = stagedAskID { coordinator.clearAttachedContext(for: id) }
        stagedAskID = nil
    }
}
