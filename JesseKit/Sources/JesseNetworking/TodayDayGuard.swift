import Foundation

/// The bridge's answer when a change was aimed at a day the file no longer is.
///
/// `POST /jesse/today/items/{id}/check` (and `move`, and `defer`) accept an optional
/// `day` — the `date` of the snapshot the change was MADE against. When it names a
/// different day from the live file's, the bridge refuses with `409` and this body,
/// **before any edit** (bridge 0.96.0, `day_mismatch`).
///
/// ## Why this is not just another `conflict`
///
/// `TodayMutationResult.conflict` already carries a `409`, and the day mismatch arrives
/// as one — but the two mean opposite things to a caller. A structural `409` ("the lead
/// item cannot be moved") is about the request. This is about the DOCUMENT: whatever the
/// change was about is gone, and no amount of refetching brings it back. A replay that
/// treated it as an ordinary conflict would show the user a JSON blob and then try again
/// tomorrow.
///
/// ## Why the app parses a body rather than reading a header
///
/// Because the bridge's error channel for this family is the response body, and a second
/// channel for one status would be a second thing to keep in step. The parse is total: a
/// body that is not this shape is not a day mismatch, which is exactly the right reading
/// of a `409` from an older bridge that has never heard of the field.
public struct TodayDayMismatch: Equatable, Sendable {
    /// The day the file actually carries now. Empty when the bridge could not name one
    /// — there is no day file at all — which is still a refusal, just a less specific
    /// one.
    public let liveDate: String

    public init(liveDate: String) {
        self.liveDate = liveDate
    }

    /// The reason string the bridge sends. Matched exactly; a different reason is a
    /// different refusal.
    static let reason = "day-mismatch"

    /// Parse a `409` body. `nil` for anything that is not a day mismatch — including
    /// every `409` this app already handled before the guard existed.
    public static func decode(_ body: String) -> TodayDayMismatch? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["reason"] as? String == reason
        else { return nil }
        return TodayDayMismatch(liveDate: object["live_date"] as? String ?? "")
    }

    /// What a person is told when a replay is refused for this reason. Written to be
    /// read by someone who ticked a box on a boat and is now looking at tomorrow.
    public var notice: String {
        guard !liveDate.isEmpty else {
            return "The day file has moved on since you made that change, so it wasn't applied."
        }
        return "The day file is now \(liveDate), so that change wasn't applied to it."
    }
}

public extension TodayMutationResult {
    /// The day mismatch this result carries, if it is one. `nil` for every other
    /// outcome, so a caller reads as `if let`.
    var dayMismatch: TodayDayMismatch? {
        guard case .conflict(let message) = self else { return nil }
        return TodayDayMismatch.decode(message)
    }
}
