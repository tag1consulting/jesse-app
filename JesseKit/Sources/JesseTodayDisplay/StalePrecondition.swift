import Foundation
import JesseNetworking

/// What a `412` means once the day has been read again.
///
/// **One definition, two callers**, and that is the whole reason this exists. The
/// offline replayer has always refetched and retried a stale precondition once; the
/// live path used to drop the tap on the floor, which is how a ticked box with an
/// evidence note typed into it sprang back open and lost the note (2026-09-23). Two
/// pieces of code deciding what "stale" means is how they came to disagree, so the
/// decision is made here and each caller only carries it out.
enum StalePrecondition {

    /// The verdict, given the document as it now stands.
    enum Verdict: Equatable {
        /// The day and the item are both still what the tap was aimed at, so it was
        /// only the tag that moved. Send it again, once, under this tag.
        case retry(writeTag: String)
        /// The day was rebuilt, or the item's words were rewritten into a different
        /// id. Re-sending now would apply the user's intent to a line they never saw.
        case dayMovedOn
        /// The refetch itself did not answer, or answered without a tag. There is
        /// nothing to retry against and nothing to conclude — the caller keeps what it
        /// has rather than deciding on no evidence.
        case noAnswer
    }

    /// Judge one stale precondition.
    ///
    /// - Parameters:
    ///   - live: the snapshot the refetch returned, or nil if it failed.
    ///   - day: the `date` of the document the tap was made against.
    ///   - itemId: the id the tap addressed.
    ///
    /// The day is compared BEFORE the item, because a different day changes the
    /// question rather than the answer: an id is a hash of content, so on a rebuilt
    /// day it proves nothing even when it happens to still resolve.
    static func verdict(after live: TodaySnapshot?, day: String?, itemId: String) -> Verdict {
        guard let live, let tag = live.writeTag, !tag.isEmpty else { return .noAnswer }
        guard (live.date ?? "") == (day ?? ""), live.item(id: itemId) != nil else {
            return .dayMovedOn
        }
        return .retry(writeTag: tag)
    }
}
