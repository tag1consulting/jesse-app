import Foundation

// Pure, SwiftUI-free follow-logic for the thread transcript's auto-scroll. Kept
// in its own Foundation-only file so the "stick to bottom" decision is
// unit-testable without a view host, mirroring ThreadSectioning / ThreadFolders
// / ThreadSearch / ThreadTitle.
//
// The transcript auto-scrolls to the newest text, but only while the user is
// actually parked at the bottom. Once they scroll up (to review older replies,
// even mid-stream), auto-follow is suppressed so the view stays put — the reply
// keeps streaming off-screen and a "jump to latest" affordance brings them back.
// Two events always win regardless of scroll position: the user sending a turn
// (they just spoke; show it) and the thread first appearing (land at newest).

/// What prompted a potential auto-scroll. Each of the view's scroll triggers
/// maps to one case so the follow decision lives here, not in the view.
enum ScrollTrigger {
    /// The local user just sent a turn — always scroll and re-enable follow.
    case userSentTurn
    /// A finished Jesse turn was appended to the transcript.
    case jesseTurnAppended
    /// A streamed delta grew the live partial reply.
    case streamDelta
    /// The `running` flag flipped (stream started or finished).
    case runningChanged
    /// The thread view first appeared — land at the newest message.
    case appeared
}

enum TranscriptScroll {
    /// Whether an auto-scroll to the bottom should fire for `trigger`, given
    /// whether the user is currently parked at the bottom.
    ///
    /// `.userSentTurn` and `.appeared` always scroll — the user either just
    /// spoke or just opened the thread, so the newest content is what they want.
    /// Every other trigger (stream deltas, appended replies, running changes)
    /// only scrolls when the user is already at the bottom; if they've scrolled
    /// up we leave them there and let the "jump to latest" button bring them back.
    static func shouldAutoScroll(isAtBottom: Bool, trigger: ScrollTrigger) -> Bool {
        switch trigger {
        case .userSentTurn, .appeared:
            return true
        case .jesseTurnAppended, .streamDelta, .runningChanged:
            return isAtBottom
        }
    }

    /// Whether the scroll view is parked at (or within `threshold` of) the
    /// bottom, from raw scroll geometry. The threshold tolerates rubber-banding
    /// and the constantly-growing partial reply so a user who hasn't
    /// deliberately scrolled up still counts as "following".
    static func isAtBottom(contentOffsetY: CGFloat,
                           contentHeight: CGFloat,
                           containerHeight: CGFloat,
                           threshold: CGFloat = 40) -> Bool {
        // Content shorter than the viewport is trivially "at the bottom".
        let maxOffset = contentHeight - containerHeight
        guard maxOffset > 0 else { return true }
        return contentOffsetY >= maxOffset - threshold
    }
}
