import Foundation

// The formatting the three Ops screens share, in one place because they must agree.
//
// Two rules run through all of it. Every instant the bridge sends is unix MILLISECONDS, not
// seconds — a screen that divides by the wrong thousand is off by five decades and looks
// plausible. And an instant is shown in a NAMED zone, never a bare offset: the schedule's
// "HH:MM" is resolved in the bridge's `tz`, and "+02:00" is Rome in August and something else
// in January.

public enum OpsFormat {

    /// Unix milliseconds → `Date`. The one conversion, so nothing else has to remember which
    /// unit the bridge speaks.
    public static func date(fromMs ms: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    /// `"Tue 3 Sep, 06:00"` in a named zone.
    public static func dayAndTime(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("EEE d MMM HH:mm")
        return f.string(from: date)
    }

    /// The same instant in the phone's zone and in the bridge's, shown together whenever they
    /// differ. THE WHOLE POINT of the Schedule screen's time column: a job fires at 03:30
    /// where the bridge stands, and while its owner is away that is not 03:30 where they are.
    /// One line when the two zones agree, because repeating a time is noise.
    public static func inBothZones(_ ms: UInt64?, bridgeTz: String?) -> String {
        guard let ms else { return "—" }
        let date = date(fromMs: ms)
        let local = TimeZone.current
        let bridge = bridgeTz.flatMap(TimeZone.init(identifier:))
        let here = dayAndTime(date, in: local)
        guard let bridge, bridge.identifier != local.identifier else { return here }
        return "\(here) · \(dayAndTime(date, in: bridge)) \(bridge.identifier)"
    }

    /// `"1m 30s"`, matching the bridge's own `human_ms` so a duration reads the same in the
    /// app and in the ledger.
    public static func duration(ms: UInt64?) -> String? {
        guard let ms else { return nil }
        let total = ms / 1000
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        if m < 60 { return "\(m)m \(s)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// `"3.4 GB"`. `ByteCountFormatter`'s `.file` count style, which is what the Finder shows,
    /// so a free-space figure agrees with the machine it describes.
    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: value),
                                         countStyle: .file)
    }

    /// A commit, short. Seven characters, git's own default, and never a truncation of
    /// something that is not a sha.
    public static func shortSha(_ sha: String?) -> String {
        guard let sha, !sha.isEmpty else { return "unknown" }
        return String(sha.prefix(7))
    }

    /// `"4 minutes ago"`, or nil when there is no instant. Relative, because every use of it
    /// here answers "is this recent" rather than "when exactly".
    public static func relative(fromMs ms: UInt64?, now: Date = Date()) -> String? {
        guard let ms else { return nil }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date(fromMs: ms), relativeTo: now)
    }

    /// An RFC 3339 instant, which is what both `until` fields take.
    public static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// `running · pid 15818 · 7 runs`, or the reason there is no such line.
    ///
    /// Here rather than on the view that draws it because the Services card AND the ask
    /// snapshot both print this line, and two builders for it would be two answers to
    /// "what state is the bridge job in". It is also why it is a plain function: a `static`
    /// on a `View` is MainActor-isolated, and the serializers are not.
    public static func serviceState(_ row: ServiceRow) -> String {
        var parts: [String] = [row.state ?? "unknown"]
        if let pid = row.pid { parts.append("pid \(pid)") }
        // `(never exited)` is not zero — the sentinel sends null for it, and printing "exit 0"
        // would tell an operator a KeepAlive job had exited cleanly when it never exited.
        if let code = row.lastExitCode { parts.append("last exit \(code)") }
        if let runs = row.runs { parts.append("\(runs) runs") }
        return parts.joined(separator: " · ")
    }

    /// "off until Sun 7 Sep, 09:00", or "off, no deadline" — and lapsed overrides say so,
    /// because "it was disabled until Sunday and Sunday has passed" is a thing someone asks.
    public static func overrideLine(_ ov: ScheduleRow.EnableOverride) -> String {
        let state = ov.enabled ? "on" : "off"
        let lapsed = (ov.active == false) ? " (lapsed)" : ""
        guard let until = ov.untilMs else { return "\(state), no deadline\(lapsed)" }
        return "\(state) until \(dayAndTime(date(fromMs: until), in: .current))\(lapsed)"
    }

    /// The colour a schedule outcome wears. `fired` is the only green one: `fired-no-output`
    /// ran and produced nothing, which is a different alarm, and a `skipped` is neither a
    /// success nor a failure.
    public static func outcomeHealth(_ outcome: String?) -> OpsHealth {
        switch outcome {
        case "fired": return .green
        case "failed", "fired-no-output": return .red
        case "skipped", "day-skipped", "profile-skip": return .amber
        case nil, "": return .grey
        default: return .grey
        }
    }
}
