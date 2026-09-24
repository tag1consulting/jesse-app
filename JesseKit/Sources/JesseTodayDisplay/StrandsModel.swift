import Foundation
import JesseNetworking

// The strand board's state: one conditional `GET`, the last board on disk, and a lens.
//
// Far smaller than `TodayDashboardModel` and deliberately so. There is no optimistic
// overlay, no pending queue, no reconciliation and no ETagged mutation, because this
// screen WRITES NOTHING: a strand's queue is edited by ticking a box in the note
// itself, which the vault reader already does through the guarded write. Everything
// this model has, it has for the same reason the day model has it — a cold launch with
// no network must draw the last board the device was given rather than a spinner that
// resolves into an error.

@MainActor
@Observable
public final class StrandsModel {
    // A @MainActor class's synthesized deinit is MainActor-isolated; a unit-test host
    // releases the model off the main actor, which would route through the
    // isolated-deinit executor hop and abort. The same pattern every model in this
    // package uses.
    nonisolated deinit {}

    /// What the bridge last said. Nil until the first load or the first cache prime.
    public private(set) var snapshot: StrandsSnapshot?

    /// The ETag the next poll carries.
    public private(set) var etag: String?

    public private(set) var isLoading = false

    /// The last call failed. The board keeps rendering what it has behind a caption,
    /// because a board the user was reading a second ago is still the best answer.
    public private(set) var isOffline = false
    public private(set) var lastErrorMessage: String?

    /// Whether what is on screen came off DISK and has not been confirmed live since.
    public private(set) var isShowingCachedSnapshot = false

    /// When the board on screen was last confirmed against the bridge.
    public private(set) var lastFetchedAt: Date?

    /// The lens. Per device and per session: which order a board is shown in is a view
    /// choice, and the day screen deliberately does not persist its own either.
    public var sortKey: StrandsSortKey = .mostRecent

    private let makeClient: @MainActor () -> any StrandsProviding
    private let now: @Sendable () -> Date
    private let cache: SnapshotCache?

    public init(makeClient: @escaping @MainActor () -> any StrandsProviding,
                now: @escaping @Sendable () -> Date = { Date() },
                cache: SnapshotCache? = nil) {
        self.makeClient = makeClient
        self.now = now
        self.cache = cache
    }

    // MARK: - What the view reads

    public enum DisplayState: Equatable, Sendable {
        case loading
        case empty
        case unavailable(String)
        case offline
        case content([StrandsGroup])
    }

    /// The board, under the lens, as groups.
    public var groups: [StrandsGroup] {
        guard let snapshot else { return [] }
        return StrandsSemantics.grouped(snapshot.strands, by: sortKey)
    }

    public var displayState: DisplayState {
        guard let snapshot else {
            if isOffline, lastErrorMessage != nil { return .offline }
            return isLoading ? .loading : (lastErrorMessage.map { .unavailable($0) } ?? .loading)
        }
        guard !snapshot.strands.isEmpty else { return .empty }
        return .content(groups)
    }

    /// The day every `updated` stamp is measured against.
    ///
    /// The BRIDGE's day when it sent one, because the board's stamps are the vault's and
    /// the vault's clock is the Studio's — a phone in another zone must not read a note
    /// touched this morning as "1d". This device's day is the fallback, which is right
    /// for a cached board old enough that the stamp it carried is no longer today.
    public var referenceDay: String {
        if let stamped = snapshot?.generatedAt, stamped.count >= 10 {
            let day = String(stamped.prefix(10))
            if StrandsSemantics.dayNumber(day) != nil { return day }
        }
        return Self.isoDay(now())
    }

    /// "Showing the last board loaded, fetched 12 minutes ago." Present whenever the
    /// screen knows when its board arrived. No dash anywhere in it: no user facing
    /// string in this app carries one.
    public var stalenessLine: String? {
        guard let lastFetchedAt else { return nil }
        let seconds = max(0, now().timeIntervalSince(lastFetchedAt))
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        guard seconds >= 60, let span = formatter.string(from: seconds) else {
            return "Showing the last board loaded, fetched just now."
        }
        return "Showing the last board loaded, fetched \(span) ago."
    }

    /// Whether the board on screen is a cached one behind an offline caption.
    public var isReadOnly: Bool { isOffline }

    // MARK: - The cache

    /// Render the last board this device was given, before any network call. A no-op
    /// once anything has loaded, so a cache can never overwrite a live answer.
    public func primeFromCache() {
        guard snapshot == nil, let cache,
              let entry = cache.load(key: SnapshotCacheKey.strands, now: now()),
              var snap = try? StrandsSnapshot.decode(from: entry.body) else { return }
        if snap.etag == nil || snap.etag?.isEmpty == true { snap.etag = entry.etag }
        snapshot = snap
        if let tag = snap.etag, !tag.isEmpty { etag = tag }
        lastFetchedAt = entry.fetchedAt
        isShowingCachedSnapshot = true
    }

    // MARK: - Loading

    /// Fetch conditionally. A `304` costs one round trip and changes nothing on screen.
    public func load() async {
        await fetch(conditional: true)
    }

    /// Pull to refresh: unconditional, so a user who suspects the board is wrong can
    /// force a full answer rather than be told nothing changed.
    public func refresh() async {
        await fetch(conditional: false)
    }

    private func fetch(conditional: Bool) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await makeClient().getStrands(
                ifNoneMatch: conditional ? etag : nil)
            switch result {
            case .notModified:
                // The round trip succeeded, which is what clears the caption AND
                // confirms a primed cache: the bridge was asked about this exact tag
                // and said the board still stands.
                confirmFresh()
                clearFailure()
            case .snapshot(let snap):
                snapshot = snap
                if let tag = snap.etag, !tag.isEmpty { etag = tag }
                confirmFresh()
                clearFailure()
            }
        } catch {
            isOffline = true
            lastErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    /// One note's markdown from the bridge — the fallback for a device that has no
    /// local copy of the vault, or has one that does not hold this note yet.
    ///
    /// Not cached and not held: it is read once, into a sheet the user closes. Caching
    /// it would mean a second, quieter copy of a note the vault reader already shows
    /// from disk on every device that has the folder.
    public func markdown(forSlug slug: String) async -> String? {
        guard let detail = try? await makeClient().getStrand(slug: slug) else { return nil }
        return detail.markdown.isEmpty ? nil : detail.markdown
    }

    private func confirmFresh() {
        lastFetchedAt = now()
        isShowingCachedSnapshot = false
    }

    private func clearFailure() {
        isOffline = false
        lastErrorMessage = nil
    }

    /// `yyyy-MM-dd` in the device's own zone. A fixed-format formatter with the POSIX
    /// locale, because a user on a non-Gregorian calendar must still get the spelling
    /// the vault writes.
    static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
