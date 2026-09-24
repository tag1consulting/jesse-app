import Foundation
import SwiftData
import JesseCore

/// The UI-test seam for `ThreadLanding`, and nothing else.
///
/// The bug `ThreadLanding` closes only exists in a running app: it is a shared tab bar
/// disappearing under a tab that is not the one the push landed on, which no unit test
/// can see and no view host reproduces. Driving it needs three things a UI test cannot
/// reach from outside the process — a conversation in the local store for the tap to
/// resolve against, the app starting on a tab that is NOT Chats, and a
/// `PushRouter.pendingTap` arriving once the shell is up — so the app supplies them
/// itself, behind one launch-environment variable.
///
/// `JESSE_UITEST_THREAD_LANDING=<tab>` arms it, where `<tab>` is a `RootTabView.Tab` raw
/// value (`chats`, `today`, `health`, `vault`) naming the tab to start on. ABSENT, which
/// is every ordinary launch, and every one of these is nil or a no-op: the variable is
/// read exactly once, into `startTab`, and `arm(context:)` returns immediately when that
/// is nil. Compiled out of Release entirely, and a launch environment can only be set by
/// a debugger or an XCTest runner, never by anything a shipped build meets — the same
/// terms `ConfigStore`'s `JESSE_UITEST_BRIDGE` override runs on.
///
/// What it does NOT do is route. The tap it posts goes through `PushRouter`,
/// `ContentView.openThread(for:)` and `RunCoordinator.thread(forTap:liveThreadID:context:)`
/// exactly as a tapped notification's does — otherwise the test would be asserting about
/// the seam rather than about the app.
@MainActor
enum ThreadLandingUITestSeam {

    /// The tab the app should start on, or nil in every ordinary launch. Read ONCE.
    static let startTab: RootTabView.Tab? = {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["JESSE_UITEST_THREAD_LANDING"] else {
            return nil
        }
        return RootTabView.Tab(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        #else
        return nil
        #endif
    }()

    /// The seeded conversation's name, in the navigation bar and in the list row.
    static let threadTitle = "Landing Probe"

    /// Whether the seed and the tap have already been done, so a second appearance of the
    /// shell cannot plant a second conversation.
    private static var armed = false

    /// Seed one local conversation and post a tap for it, as if a notification had been
    /// tapped the instant the shell finished coming up.
    ///
    /// The conversation id is a canonical lowercase UUID because that is what the bridge
    /// mints and what the resolver's second step compares against — an uppercase one would
    /// miss locally and fall through to a network sync the test has no bridge for.
    static func arm(context: ModelContext) {
        guard startTab != nil, !armed else { return }
        armed = true
        let thread = JesseThread(title: threadTitle, mode: .ask)
        let conversationId = JesseThread.mintConversationId()
        thread.conversationId = conversationId
        context.insert(thread)
        let turn = Turn(role: .user, text: "Does landing select the Chats tab?")
        turn.thread = thread
        context.insert(turn)
        try? context.save()
        PushRouter.shared.pendingTap = PushTap(jobId: nil, conversationId: conversationId)
    }
}
