import Foundation

/// Why a send is refused — the ONE definition of the send gate, read by the composer (which
/// enables or disables Send) and by the coordinator's staging (which refuses, and now says
/// why).
///
/// It exists because those were two separate gates that disagreed. The composer asked "is a
/// turn running IN THIS CONVERSATION"; staging asked "is a turn running ANYWHERE on this
/// Mac". So in every conversation but the running one the button was live, Return reached
/// `send`, and staging returned nil having written nothing and said nothing: a message that
/// would not send, with no error, no spinner, and no way to tell what was wrong. A pure
/// function both sides call is what turns that class of disagreement into something a test
/// can pin, and the reason every refusal here carries the sentence the user reads.
enum MacSendGate {

    /// The reasons a send does not go through.
    ///
    /// `nothingToSend` is the only silent one, and deliberately: an empty composer is not an
    /// error, it is simply nothing to send, and the button is already disabled. Every other
    /// refusal MUST reach the screen.
    enum Refusal: Equatable {
        case nothingToSend
        case alreadyRunning
        case notPaired

        /// What the person is told, or nil when there is nothing worth telling them.
        var message: String? {
            switch self {
            case .nothingToSend:
                return nil
            case .alreadyRunning:
                return "A reply is still coming in this conversation."
            case .notPaired:
                return "This Mac isn't paired with the bridge — pair it in Settings."
            }
        }
    }

    /// Whether this send may go, given what the composer holds and what THIS CONVERSATION —
    /// never the app as a whole — is doing. nil means go.
    ///
    /// `hasAttachment` is what makes an empty composer a real turn on a conversation a screen
    /// opened with context attached ("just look at it"), which is why emptiness alone is not
    /// the question.
    static func refusal(typed: String, hasAttachment: Bool, isConfigured: Bool,
                        isRunningInThisConversation: Bool) -> Refusal? {
        if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachment {
            return .nothingToSend
        }
        if isRunningInThisConversation { return .alreadyRunning }
        if !isConfigured { return .notPaired }
        return nil
    }
}
