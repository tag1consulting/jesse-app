import Foundation

// `GET /jesse/profile` — what profile is in force, in what zone, until when.
//
// The one subtlety, and the reason `effective` exists as its own field: the STORED period and
// the period IN FORCE are different things. A profile whose `until` has passed is still on
// disk, so `since_ms`/`until_ms`/`note` describe it while `name` has already gone back to
// `home`. That is what makes "it was away until Sunday and Sunday has passed" answerable from
// one request, and it is also what a screen gets wrong if it reads `until_ms` as proof of
// being away.

public struct ProfileDocument: Decodable, Sendable, Equatable {
    /// The EFFECTIVE name — `home` whenever nothing is in force, including a period that has
    /// expired but whose record is still on disk.
    public var name: String
    /// The zone dates are actually derived in right now.
    public var tz: String?
    public var sinceMs: UInt64?
    public var untilMs: UInt64?
    public var note: String
    /// Whether the stored period is the one in force — the field that tells the two cases
    /// above apart, and the ONLY thing the away banner keys off.
    public var effective: Bool
    /// The host's own zone, always, so a reader can see what `away` is a departure FROM.
    public var processTz: String?
    /// When the `[profile].on_return` chain last fired for the stored period, or nil while it
    /// is still owed.
    public var returnedMs: UInt64?

    enum CodingKeys: String, CodingKey {
        case name, tz, note, effective
        case sinceMs = "since_ms"
        case untilMs = "until_ms"
        case processTz = "process_tz"
        case returnedMs = "returned_ms"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `name` and `effective` are the document. Everything else is context around them.
        name = try c.decode(String.self, forKey: .name)
        effective = (try? c.decode(Bool.self, forKey: .effective)) ?? (name == "away")
        tz = try? c.decodeIfPresent(String.self, forKey: .tz)
        sinceMs = try? c.decodeIfPresent(UInt64.self, forKey: .sinceMs)
        untilMs = try? c.decodeIfPresent(UInt64.self, forKey: .untilMs)
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        processTz = try? c.decodeIfPresent(String.self, forKey: .processTz)
        returnedMs = try? c.decodeIfPresent(UInt64.self, forKey: .returnedMs)
    }

    public init(name: String, tz: String?, sinceMs: UInt64?, untilMs: UInt64?, note: String,
                effective: Bool, processTz: String?, returnedMs: UInt64?) {
        self.name = name
        self.tz = tz
        self.sinceMs = sinceMs
        self.untilMs = untilMs
        self.note = note
        self.effective = effective
        self.processTz = processTz
        self.returnedMs = returnedMs
    }

    public static func decode(_ data: Data) throws -> ProfileDocument {
        try JSONDecoder().decode(ProfileDocument.self, from: data)
    }

    /// `home` when nothing is in force. Deliberately derived from `effective` rather than from
    /// `name`: they agree today, and if a future bridge ever reported a third name the banner
    /// must still key off "is a period in force".
    public var isAway: Bool { effective }

    public var until: Date? { untilMs.map(OpsFormat.date(fromMs:)) }
    public var since: Date? { sinceMs.map(OpsFormat.date(fromMs:)) }

    /// The banner's one line: "Away until 3 Sep 2026 (Europe/Rome)". Nil when nothing is in
    /// force, so a view can bind straight to it.
    public var awayBannerText: String? {
        guard isAway else { return nil }
        let zone = tz ?? processTz ?? TimeZone.current.identifier
        guard let until else { return "Away (\(zone))" }
        return "Away until \(OpsFormat.dayAndTime(until, in: TimeZone.current)) (\(zone))"
    }
}
