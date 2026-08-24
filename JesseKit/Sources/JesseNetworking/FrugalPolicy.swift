import Foundation

/// What the app does differently when the network is metered or the user has asked for
/// less. One value, decided once from the current path plus the Settings toggle, read at
/// each of the six sites that spend bytes or wake the radio.
///
/// # Why a policy object and not six `if isExpensive` checks
///
/// The six decisions are not independent — they are one answer to one question, and the
/// question has two inputs (what the network says, and what the user said). Scattering
/// the check meant each site could disagree about what "frugal" means, and none of them
/// could be tested without a radio. This is pure: `decide` is a function of two values,
/// every decision is a stored property, and the whole table is a unit test.
///
/// # What it deliberately does NOT do
///
/// It never blocks anything. Every decision here makes a thing cheaper — a smaller image,
/// a slower poll, a skipped prefetch of data already on disk — and not one of them refuses
/// a turn, drops a message, or hides a reply. Frugal mode on a phone with one bar must
/// still be able to send.
public struct FrugalPolicy: Equatable, Sendable {
    /// Whether the cheap path is in force.
    public let isActive: Bool
    /// Why, so the composer's glyph can explain itself in one sentence rather than saying
    /// "frugal mode" and leaving the user to guess which of the two it is.
    public let reason: Reason

    public enum Reason: Equatable, Sendable {
        /// Not active.
        case none
        /// The interface is metered — cellular, or a hotspot.
        case expensive
        /// iOS Low Data Mode is on for this network.
        case constrained
        /// The Settings toggle is on, regardless of what the network costs.
        case forced
    }

    // MARK: - The decisions

    /// Skip the pre-send diet snapshot fetch when the cached one is younger than this.
    /// `0` off the frugal path — the fetch always runs, exactly as it did before.
    ///
    /// Twelve hours because the rollup this feeds is a MULTI-WINDOW nutrient trend: what
    /// it says about the last fortnight does not change between breakfast and lunch, and
    /// the whole-snapshot GET it costs is the largest single body on the send path.
    public var skipDietPrefetchIfCacheYoungerThan: TimeInterval { isActive ? 12 * 3600 : 0 }

    /// Longest edge, in pixels, an outgoing image attachment is re-encoded to. `nil` off
    /// the frugal path — the existing cap-driven downscale is untouched, so a photo under
    /// the size cap is still staged byte-verbatim.
    public var attachmentMaxLongEdge: Int? { isActive ? 1280 : nil }

    /// JPEG quality for that re-encode. `nil` off the frugal path (the downscaler's own
    /// 0.85 stands).
    public var attachmentJPEGQuality: Double? { isActive ? 0.7 : nil }

    /// Floor, in seconds, under which the completion poll never runs. `0` off the frugal
    /// path, which leaves the existing 2s → 30s backoff exactly as it was.
    public var pollFloorSeconds: TimeInterval { isActive ? 5 : 0 }

    /// Frames per second the send button's fill sweep animates at. The sweep is pure
    /// decoration on a screen whose content is not changing, and on a metered link the
    /// phone is better off asleep between whole seconds.
    public var sendSweepFPS: Double { isActive ? 1 : 30 }

    /// Whether Settings keeps re-polling `/jesse/models` while it is open. Off on the
    /// frugal path: the list is already shown, and it is a round trip every 25 seconds for
    /// a change that almost never happens while someone is looking at the screen.
    public var modelListPollingEnabled: Bool { !isActive }

    // MARK: - Deciding

    /// Frugal when the network says it costs (expensive or constrained) OR the user has
    /// forced it on. The toggle can only turn it ON — there is deliberately no "off even
    /// on cellular" setting, because the decisions above are all cheap-and-still-correct
    /// and the one that would matter (a full-resolution photo over cell) is a thing to
    /// want rarely and pay for knowingly, not a default to leave armed.
    public static func decide(path: NetworkPathSnapshot, forcedOn: Bool) -> FrugalPolicy {
        if path.isConstrained { return FrugalPolicy(isActive: true, reason: .constrained) }
        if path.isExpensive { return FrugalPolicy(isActive: true, reason: .expensive) }
        if forcedOn { return FrugalPolicy(isActive: true, reason: .forced) }
        return .off
    }

    /// The inactive policy — every decision at its pre-frugal value.
    public static let off = FrugalPolicy(isActive: false, reason: .none)

    public init(isActive: Bool, reason: Reason) {
        self.isActive = isActive
        self.reason = reason
    }

    /// One sentence naming what is being saved and why, for the composer glyph's
    /// explanation. Empty when inactive.
    public var explanation: String {
        switch reason {
        case .none:
            return ""
        case .expensive:
            return "You’re on cellular, so Jesse is sending smaller photos, checking for the reply less often, and reusing the health summary it already has."
        case .constrained:
            return "Low Data Mode is on for this network, so Jesse is sending smaller photos, checking for the reply less often, and reusing the health summary it already has."
        case .forced:
            return "Frugal mode is switched on in Settings, so Jesse is sending smaller photos, checking for the reply less often, and reusing the health summary it already has."
        }
    }
}
