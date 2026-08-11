import Foundation

// Where the watch app leaves the pushed day so the COMPLICATION can read it.
//
// A widget extension is its own process with its own sandbox: it cannot hold a
// `WCSession` (there is one per app, and the watch app owns it) and it cannot reach
// into the app's container. An app group is the only shared ground, so the watch app
// writes the last context here on receipt and the timeline provider reads it.
//
// Deliberately the SAME payload the wire carries, serialized with the SAME codec.
// A second, store-only shape would be a second definition of what a day is, and the
// two would drift the first time a field was added — which is exactly what happened
// to the `doNowOpenCount` this store exists to surface.
//
// ## It degrades rather than fails
//
// The app group needs an entitlement, and an entitlement needs a signature. An
// UNSIGNED simulator build (`CODE_SIGNING_ALLOWED=NO`, which is how CI and the local
// gate build) has neither, so `containerURL` answers nil. That is not an error
// worth propagating: the watch app carries on with its in-memory day and the
// complication renders its placeholder. Every path here returns an optional or does
// nothing, and no caller is expected to handle a failure.

nonisolated enum WatchTodayStore {
    /// The app group shared by the watch app and its widget extension.
    static let appGroupIdentifier = "group.com.tag1.Jesse"

    /// One file, overwritten in place. Latest-wins, matching the transport that
    /// feeds it: there is no history of days worth keeping on a watch.
    private static let fileName = "today-context.plist"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName)
    }

    /// Write the day for the complication to find. Silent on failure, by the
    /// argument above.
    static func save(_ summary: WatchTodaySummary) {
        guard let url = fileURL else { return }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: summary.encode(), format: .binary, options: 0) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The last day written, or nil when there is none (or no container to look in).
    static func load() -> WatchTodaySummary? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return WatchTodaySummary.decode(plist)
    }
}
