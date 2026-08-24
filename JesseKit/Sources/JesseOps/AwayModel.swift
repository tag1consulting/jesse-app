import Foundation
import Observation
import JesseNetworking

// The away profile's view model, shared by the Away mode screen and by the two thin banners
// (the Chats list's and the Today header's).
//
// The bridge validates `away` — a zone the tz database knows, an `until` in the future — and
// this deliberately does NOT re-implement those rules to pre-empt them. It passes the bridge's
// own refusal through verbatim, because a client-side copy of a server-side rule is one
// release away from refusing something the bridge would have accepted, and the failure looks
// like a bug in the phone.
//
// What it DOES enforce locally is the default: seven days ahead, in this device's zone. An
// away period that never ends is a bridge left deriving every date in the wrong place until
// someone notices.

@MainActor
@Observable
public final class AwayModel {
    nonisolated deinit {}

    public var configuration: OpsConfiguration

    public private(set) var profile: ProfileDocument?
    public private(set) var isLoading = false
    public private(set) var isSaving = false
    /// The last read's failure. Never blanks a loaded profile.
    public private(set) var loadError: String?
    /// The last write's failure — the bridge's own sentence, which names what was wrong with
    /// the zone or the deadline.
    public private(set) var saveError: String?

    /// How far ahead the picker starts. Long enough to cover the trip, short enough that
    /// forgetting to come home costs a week rather than a season.
    public static let defaultAwayDays = 7

    public init(configuration: OpsConfiguration) {
        self.configuration = configuration
    }

    /// The banner line, or nil when nothing is in force. The ONE place the two banners read.
    public var bannerText: String? { profile?.awayBannerText }

    /// What the Today header shows: the profile's name, always — `home` is an answer.
    public var profileName: String { profile?.name ?? "home" }

    public func refresh() async {
        guard configuration.bridge.isConfigured else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            profile = try ProfileDocument.decode(await configuration.bridgeClient.profileDocument())
            loadError = nil
        } catch {
            loadError = OpsModel.describe(error)
        }
    }

    /// Declare an away period. Returns true when the bridge took it, so a sheet can dismiss on
    /// success and stay up on a refusal with the reason still on screen.
    @discardableResult
    public func goAway(tz: String, until: Date, note: String) async -> Bool {
        await post(name: "away", tz: tz, until: until, note: note)
    }

    /// Come home. The bridge ignores zone, deadline and note for `home`, so none is sent —
    /// sending them would imply they meant something.
    @discardableResult
    public func goHome() async -> Bool {
        await post(name: "home", tz: nil, until: nil, note: nil)
    }

    private func post(name: String, tz: String?, until: Date?, note: String?) async -> Bool {
        guard configuration.bridge.isConfigured else {
            saveError = "Pair the bridge in Settings first."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let data = try await configuration.bridgeClient
                .setProfile(name: name, tz: tz, until: until, note: note)
            // The POST answers with the same document the GET does, so the screen is current
            // without a second call — and, more to the point, without a window in which the
            // banner and the switch disagree.
            if let fresh = try? ProfileDocument.decode(data) {
                profile = fresh
            } else {
                // Accepted, but not in a shape this build reads. Re-read rather than leave the
                // screen showing the state from before the write.
                await refresh()
            }
            saveError = nil
            return true
        } catch {
            saveError = OpsModel.describe(error)
            return false
        }
    }

    /// The default deadline a fresh Away sheet opens on.
    public static func defaultUntil(from now: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: defaultAwayDays, to: now) ?? now
    }

    /// Every zone the device knows, sorted, for the picker. `TimeZone.knownTimeZoneIdentifiers`
    /// is the same list the bridge's tz database answers from, so a name picked here is a name
    /// the bridge accepts.
    public static var zoneIdentifiers: [String] {
        TimeZone.knownTimeZoneIdentifiers.sorted()
    }

    /// The picker's search: a plain case-insensitive contains over the identifier, with the
    /// underscores that make `America/New_York` unsearchable treated as spaces.
    public static func zones(matching query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return zoneIdentifiers }
        return zoneIdentifiers.filter {
            $0.lowercased().replacingOccurrences(of: "_", with: " ").contains(q)
                || $0.lowercased().contains(q)
        }
    }
}
