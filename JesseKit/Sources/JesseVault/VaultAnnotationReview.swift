import Foundation
import Observation
import SwiftUI

// ASKING FOR THE MARKS TO BE ANSWERED, WITH OR WITHOUT A STUDIO.
//
// A marked up note is half a conversation. The other half is somebody reading the marks,
// applying the rewrites and answering the questions, and that somebody is the agent on the
// Studio. So the reader needs one button, and the button needs to work in both of the
// worlds this app lives in.
//
// THE SENTENCE IS FIXED, and it is fixed here rather than composed at the call site. It
// names the note by its vault relative path and says nothing else, because the agent's own
// rules already say what to do with a file full of marks; a chattier request would be this
// app inventing instructions for a routine it does not own. One string, one place, so the
// bridge path and the Inbox path ask for exactly the same thing.
//
// WHICH PATH IS REACHABILITY'S CALL, through the rule the composers already use: with the
// bridge unreachable and a vault folder held, the request is written into the vault's own
// Inbox and the morning routine picks it up, and in every other state a conversation is
// started. That is the same asymmetry `InboxCaptureRouting` was written for, reused rather
// than restated: a second copy of "when is the bridge worth waiting for" is a second copy
// that can disagree.

/// Where a review request goes.
public enum VaultAnnotationDestination: Equatable, Sendable {
    /// A conversation with the agent, starting with the fixed sentence.
    case conversation
    /// A line in the vault's Inbox, for the morning routine.
    case capture
}

/// The request, and the rule that routes it.
public enum VaultAnnotationReview {

    /// What the agent is asked, verbatim.
    public static func sentence(path: String) -> String {
        "Review my annotations in " + path
    }

    /// Bridge or vault.
    ///
    /// `canStartConversation` is false where no shell has injected a way to open one (a
    /// preview, a test, a window that was never wired). It routes to the vault rather than
    /// to nothing: a button that silently did nothing would be worse than an Inbox line
    /// somebody has to read tomorrow.
    public static func destination(offer: InboxCaptureOffer,
                                   canStartConversation: Bool) -> VaultAnnotationDestination {
        if offer.isOffered { return .capture }
        return canStartConversation ? .conversation : .capture
    }

    /// The one line under the row, per path. Short, past tense, and different enough that
    /// the two cannot be confused at a glance.
    public static let sentStatus = "Sent"
    public static let queuedStatus = "Queued for the morning routine"
}

/// The narrow half of `InboxCaptureService` a review request needs.
///
/// A seam for the reason every seam in this target is one: "unreachable writes one Inbox
/// line carrying the sentence and the path" is a sentence a test states in four lines, and
/// against the real service it is a folder, a bookmark and a synced provider.
@MainActor
public protocol VaultInboxCapturing: AnyObject {
    func offer(reachability: BridgeReachabilityState) -> InboxCaptureOffer
    func capture(_ text: String, about: String?) async -> Result<InboxCaptureWrite, InboxCaptureFailure>
}

extension InboxCaptureService: VaultInboxCapturing {}

/// What a shell can do about a review request: say whether the bridge is there, and start
/// the conversation.
///
/// An environment value, exactly as `AskAction` is one, and for the same reason: the reader
/// is presented from seven places across two apps (a tab, three sheets, two Mac windows and
/// the browser's own stack), and threading a closure through three view initializers to
/// reach all of them would put this feature's plumbing in files that have nothing to do
/// with it. A shell injects one value where it owns its conversation store; every reader
/// below finds it.
///
/// REACHABILITY IS A CLOSURE, not a value, and that is deliberate. Reading the shared
/// reachability model into an environment value would make the app's root body depend on
/// it, and that root builds every tab: a probe landing would re-render the Health and Today
/// screens while somebody was reading a note. Asked at the moment of the tap, it costs
/// nothing and is more current than anything a render could have captured.
public struct VaultReviewAction {
    private let reachabilityHandler: @MainActor () -> BridgeReachabilityState
    private let startHandler: @MainActor (String) -> Void

    public init(reachability: @escaping @MainActor () -> BridgeReachabilityState,
                start: @escaping @MainActor (String) -> Void) {
        self.reachabilityHandler = reachability
        self.startHandler = start
    }

    @MainActor
    public func reachability() -> BridgeReachabilityState { reachabilityHandler() }

    /// Open a conversation whose first message is `sentence`.
    @MainActor
    public func start(_ sentence: String) { startHandler(sentence) }
}

private struct VaultReviewActionKey: EnvironmentKey {
    // `nonisolated(unsafe)` on a nil default, for the reason `AskActionKey` carries the
    // same annotation: the value holds MainActor closures and so is not Sendable, but nil
    // is trivially safe to read from anywhere.
    nonisolated(unsafe) static let defaultValue: VaultReviewAction? = nil
}

public extension EnvironmentValues {
    /// The shell's "start a conversation about this note" action, or nil where none is
    /// injected, in which case a review request is written into the vault instead.
    var vaultReview: VaultReviewAction? {
        get { self[VaultReviewActionKey.self] }
        set { self[VaultReviewActionKey.self] = newValue }
    }
}

/// One review request, performed and reported.
///
/// A model rather than two pieces of view state, because the interesting behaviour is the
/// routing and it is worth asserting without a screen: which destination each reachability
/// produces, that the sentence and the path both reach the capture, and that a refusal
/// leaves a caption a person can read rather than a silent no-op.
@MainActor
@Observable
public final class VaultNoteReviewModel {
    /// See the GOTCHA in this target's `Package.swift` comment.
    nonisolated deinit {}

    /// The one line under the row: "Sent", "Queued for the morning routine", or why not.
    public private(set) var status: String?
    /// The capture badge, when the request went to the vault, in the words the capture
    /// sheet uses for the same write.
    public private(set) var badge: String?
    public private(set) var busy = false
    /// What the last request asked for, so a test can read it back.
    public private(set) var lastSentence: String?
    public private(set) var destination: VaultAnnotationDestination?

    private let capture: any VaultInboxCapturing

    public init(capture: any VaultInboxCapturing = InboxCaptureService.shared) {
        self.capture = capture
    }

    /// Send the request for `path`.
    ///
    /// The whole of the decision is `VaultAnnotationReview.destination`; everything here is
    /// the doing of it. The conversation path is synchronous and cannot fail from here (the
    /// shell owns the store and the queue, and an offline send is the queue's business);
    /// the vault path can, and says so in the failure's own words.
    public func send(path: String, review: VaultReviewAction?) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        status = nil
        badge = nil
        let sentence = VaultAnnotationReview.sentence(path: path)
        lastSentence = sentence
        let offer = capture.offer(reachability: review?.reachability() ?? .unknown)
        let destination = VaultAnnotationReview.destination(offer: offer,
                                                           canStartConversation: review != nil)
        self.destination = destination
        switch destination {
        case .conversation:
            review?.start(sentence)
            status = VaultAnnotationReview.sentStatus
        case .capture:
            switch await capture.capture(sentence, about: path) {
            case .success(let write):
                badge = InboxCaptureReply.badge(path: write.relativePath)
                status = VaultAnnotationReview.queuedStatus
            case .failure(let failure):
                status = failure.description
            }
        }
    }
}
